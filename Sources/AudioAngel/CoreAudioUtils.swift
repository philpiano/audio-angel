import CoreAudio
import Foundation

/// Thin, typed wrappers over the Core Audio HAL property API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func addr(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func get<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var address = address
        var value = value
        return withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
    }

    static func getArray<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ zero: T) -> [T] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let stride = MemoryLayout<T>.stride
        var array = [T](repeating: zero, count: Int(size) / stride)
        let status = array.withUnsafeMutableBufferPointer {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return Array(array.prefix(Int(size) / stride))
    }

    /// Properties that return a CFString hand us a +1 reference.
    static func getString(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    static func getStringArray(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [String]? {
        var address = address
        var ref: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as? [String]
    }

    /// Channels per buffer, in the exact order an IOProc on this device sees them.
    static func streamLayout(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [Int] {
        var address = addr(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let bytes = max(Int(size), MemoryLayout<AudioBufferList>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        defer { raw.deallocate() }
        memset(raw, 0, bytes)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    static func deviceIDs() -> [AudioObjectID] {
        getArray(system, addr(kAudioHardwarePropertyDevices), AudioObjectID(0))
    }

    static func uid(of device: AudioObjectID) -> String? {
        getString(device, addr(kAudioDevicePropertyDeviceUID))
    }

    static func deviceID(forUID uid: String) -> AudioObjectID? {
        deviceIDs().first { self.uid(of: $0) == uid }
    }

    static func nominalRate(_ device: AudioObjectID) -> Double? {
        get(device, addr(kAudioDevicePropertyNominalSampleRate), Float64(0))
    }

    static func isAlive(_ device: AudioObjectID) -> Bool {
        (get(device, addr(kAudioDevicePropertyDeviceIsAlive), UInt32(0)) ?? 0) != 0
    }

    /// Sets a device's nominal rate and waits for the change to land (it is asynchronous).
    @discardableResult
    static func setNominalRate(_ device: AudioObjectID, _ rate: Double, timeout: TimeInterval = 1.5) -> Bool {
        let address = addr(kAudioDevicePropertyNominalSampleRate)
        if let current = nominalRate(device), abs(current - rate) < 0.5 { return true }
        guard supportsRate(device, rate) else { return false }
        guard set(device, address, Float64(rate)) == noErr else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let current = nominalRate(device), abs(current - rate) < 0.5 { return true }
            usleep(10_000)
        }
        return false
    }

    /// Whether the device lists this rate at all. (An empty list is taken as "maybe".)
    static func supportsRate(_ device: AudioObjectID, _ rate: Double) -> Bool {
        let ranges = getArray(device, addr(kAudioDevicePropertyAvailableNominalSampleRates), AudioValueRange())
        return ranges.isEmpty || ranges.contains { rate >= $0.mMinimum - 0.5 && rate <= $0.mMaximum + 0.5 }
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        get(system, addr(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0)).flatMap { $0 == 0 ? nil : $0 }
    }

    @discardableResult
    static func setDefaultOutputDevice(_ device: AudioObjectID) -> Bool {
        set(system, addr(kAudioHardwarePropertyDefaultOutputDevice), device) == noErr
    }
}

/// A snapshot of one audio device, as the app needs to see it.
struct AudioDeviceInfo: Identifiable, Hashable {
    var id: String { uid }
    let objectID: AudioObjectID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let transport: UInt32
    let sampleRate: Double

    var isVirtual: Bool { transport == kAudioDeviceTransportTypeVirtual }
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    var isBlackHole: Bool { name.localizedCaseInsensitiveContains("blackhole") }
    var isExternalHardware: Bool {
        [kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire,
         kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypePCI].contains(transport)
    }

    var transportName: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity"
        default: return "other"
        }
    }

    /// Every device a user could route to or from. Aggregates (including our own
    /// private engine device and Multi-Output Devices) are excluded: they can't be
    /// nested inside the engine's aggregate.
    static func all() -> [AudioDeviceInfo] {
        CA.deviceIDs().compactMap { id -> AudioDeviceInfo? in
            guard let uid = CA.uid(of: id), !uid.hasPrefix(EngineController.aggregateUIDPrefix) else { return nil }
            let transport = CA.get(id, CA.addr(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0
            if transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeAutoAggregate {
                return nil
            }
            let inputs = CA.streamLayout(id, kAudioObjectPropertyScopeInput).reduce(0, +)
            let outputs = CA.streamLayout(id, kAudioObjectPropertyScopeOutput).reduce(0, +)
            guard inputs + outputs > 0 else { return nil }
            return AudioDeviceInfo(
                objectID: id,
                uid: uid,
                name: CA.getString(id, CA.addr(kAudioObjectPropertyName)) ?? uid,
                inputChannels: inputs,
                outputChannels: outputs,
                transport: transport,
                sampleRate: CA.nominalRate(id) ?? 0
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
