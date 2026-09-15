import AppKit
import CoreAudio
import Foundation
import RouterCore

/// Audio Angel's flight recorder: one JSON Lines file per launch (`.jsonl`, one
/// event per line), written to `logs/` in the project folder when the app runs
/// from its build folder, otherwise to ~/Library/Logs/Audio Angel.
///
/// It exists to answer one question with evidence: when the sound stopped, why?
/// So it records every decision the engine makes, what triggered it, and how long
/// the audio was actually silent, measured on the audio thread's own clock.
///
/// Every line starts with the same three fields:
///   "t"  wall-clock time, local, to the millisecond
///   "s"  seconds since the app launched (monotonic, for exact durations)
///   "ev" the event name
///
/// Nothing here runs on the audio thread. Events are stamped where they happen and
/// written on a low-priority queue, so logging can't cause a dropout.
final class DiagnosticLog {
    static let shared = DiagnosticLog()

    private let queue = DispatchQueue(label: "com.philipwarda.audioangel.log", qos: .utility)
    private let started = mach_absolute_time()
    private let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()
    private var handle: FileHandle?
    private let lock = NSLock()
    private var _fileURL: URL?

    var fileURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return _fileURL
    }

    /// Where logs go: the project's `logs/` folder if this app was built there.
    static func defaultDirectory() -> URL {
        let project = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: project.appendingPathComponent("build.sh").path) {
            return project.appendingPathComponent("logs", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Audio Angel", isDirectory: true)
    }

    /// Opens a new log file. Keeps the newest 60 sessions in the folder.
    func start(directory: URL = DiagnosticLog.defaultDirectory()) {
        let names = DateFormatter()
        names.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = directory.appendingPathComponent("audio-angel-\(names.string(from: Date())).jsonl")
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
            let h = try FileHandle(forWritingTo: url)
            queue.sync { handle = h }
            lock.lock(); _fileURL = url; lock.unlock()
        } catch {
            NSLog("Audio Angel: couldn't open diagnostic log at \(url.path): \(error)")
            return
        }
        if let old = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let logs = old.filter { $0.lastPathComponent.hasPrefix("audio-angel-") && $0.pathExtension == "jsonl" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for stale in logs.dropFirst(60) { try? fm.removeItem(at: stale) }
        }
    }

    func stop() {
        queue.sync {
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
        }
    }

    /// Records one event, stamped with when it happened (by default, now).
    /// Safe from any thread except the audio thread.
    func event(_ name: String, _ fields: [String: Any] = [:],
               at now: Date = Date(), ticks: UInt64 = mach_absolute_time()) {
        queue.async {
            guard let handle = self.handle else { return }
            var line = "{\"t\":\"\(self.stamp.string(from: now))\",\"s\":\(String(format: "%.6f", Self.seconds(ticks - self.started))),\"ev\":\(Self.quote(name))"
            let clean = Self.sanitize(fields) as? [String: Any] ?? [:]
            if !clean.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys, .withoutEscapingSlashes]),
               var body = String(data: data, encoding: .utf8) {
                body.removeFirst() // "{"
                line += "," + body
            } else {
                line += "}"
            }
            handle.write((line + "\n").data(using: .utf8)!)
        }
    }

    // MARK: - Time

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    static func ms(_ ticks: UInt64) -> Double { (seconds(ticks) * 1e6).rounded() / 1e3 }

    /// Milliseconds between two mach times, or nil if either is missing.
    static func ms(from a: UInt64, to b: UInt64) -> Double? {
        guard a != 0, b != 0, b >= a else { return nil }
        return ms(b - a)
    }

    // MARK: - JSON

    private static func quote(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
        let wrapped = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"?\"]"
        return String(wrapped.dropFirst().dropLast())
    }

    /// JSONSerialization only takes plain JSON types, and rejects NaN and infinity.
    private static func sanitize(_ value: Any) -> Any {
        switch value {
        case let d as Double: return d.isFinite ? d : NSNull()
        case let f as Float: return f.isFinite ? Double(f) : NSNull()
        case let v as Bool: return v
        case let v as Int: return v
        case let v as Int32: return Int(v)
        case let v as UInt32: return Int(v)
        case let v as UInt64: return v
        case let v as String: return v
        case let v as [Any]: return v.map(sanitize)
        case let v as [String: Any]: return v.mapValues(sanitize)
        case is NSNull: return NSNull()
        default: return String(describing: value)
        }
    }
}

// MARK: - What to record about the Mac and its devices

enum DiagnosticInfo {
    static func dbfs(_ level: Float) -> Double? {
        level > 0 ? (Double(20 * log10(level)) * 10).rounded() / 10 : nil
    }

    static func fourCC(_ code: UInt32) -> String {
        let bytes = withUnsafeBytes(of: code.bigEndian, Array.init)
        let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        return printable ? String(decoding: bytes, as: UTF8.self) : String(format: "0x%08x", code)
    }

    /// Readable names for the Core Audio properties that matter here. Anything else
    /// is logged by its four-character code.
    static let propertyNames: [AudioObjectPropertySelector: String] = [
        kAudioHardwarePropertyDevices: "Devices",
        kAudioHardwarePropertyDefaultInputDevice: "DefaultInputDevice",
        kAudioHardwarePropertyDefaultOutputDevice: "DefaultOutputDevice",
        kAudioHardwarePropertyDefaultSystemOutputDevice: "DefaultSystemOutputDevice",
        kAudioHardwarePropertyServiceRestarted: "ServiceRestarted",
        kAudioDevicePropertyNominalSampleRate: "NominalSampleRate",
        kAudioDevicePropertyDeviceIsAlive: "DeviceIsAlive",
        kAudioDevicePropertyDeviceIsRunning: "DeviceIsRunning",
        kAudioDevicePropertyDeviceIsRunningSomewhere: "DeviceIsRunningSomewhere",
        kAudioDeviceProcessorOverload: "ProcessorOverload",
        kAudioDevicePropertyBufferFrameSize: "BufferFrameSize",
        kAudioDevicePropertyStreamConfiguration: "StreamConfiguration",
        kAudioDevicePropertyStreams: "Streams",
        kAudioDevicePropertyHogMode: "HogMode",
        kAudioDevicePropertyLatency: "Latency",
        kAudioDevicePropertySafetyOffset: "SafetyOffset",
        kAudioDevicePropertyClockDomain: "ClockDomain",
        kAudioDevicePropertyAvailableNominalSampleRates: "AvailableNominalSampleRates",
        kAudioDevicePropertyDeviceHasChanged: "DeviceHasChanged",
        kAudioDevicePropertyJackIsConnected: "JackIsConnected",
        kAudioDevicePropertyVolumeScalar: "VolumeScalar",
        kAudioDevicePropertyMute: "Mute",
        kAudioDevicePropertyDataSource: "DataSource",
        kAudioObjectPropertyName: "Name",
        kAudioObjectPropertyOwnedObjects: "OwnedObjects",
        kAudioAggregateDevicePropertyActiveSubDeviceList: "ActiveSubDeviceList",
        kAudioAggregateDevicePropertyFullSubDeviceList: "FullSubDeviceList",
        kAudioAggregateDevicePropertyMainSubDevice: "MainSubDevice",
    ]

    static func propertyName(_ selector: AudioObjectPropertySelector) -> String {
        propertyNames[selector] ?? fourCC(selector)
    }

    /// The current value of a property that just changed, when it's one we can read simply.
    static func value(of selector: AudioObjectPropertySelector, on object: AudioObjectID) -> Any? {
        switch selector {
        case kAudioDevicePropertyNominalSampleRate:
            return CA.nominalRate(object)
        case kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyDeviceIsRunning,
             kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioDevicePropertyBufferFrameSize,
             kAudioDevicePropertyJackIsConnected:
            return CA.get(object, CA.addr(selector), UInt32(0)).map { Int($0) }
        case kAudioDevicePropertyHogMode:
            return CA.get(object, CA.addr(selector), pid_t(0)).map { Int($0) }
        case kAudioDevicePropertyStreamConfiguration:
            return ["in": CA.streamLayout(object, kAudioObjectPropertyScopeInput),
                    "out": CA.streamLayout(object, kAudioObjectPropertyScopeOutput)]
        case kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice,
             kAudioHardwarePropertyDefaultSystemOutputDevice:
            return CA.get(object, CA.addr(selector), AudioObjectID(0)).map(deviceName)
        case kAudioHardwarePropertyDevices:
            return CA.deviceIDs().map(deviceName)
        case kAudioAggregateDevicePropertyActiveSubDeviceList:
            return CA.getArray(object, CA.addr(selector), AudioObjectID(0)).map(deviceName)
        default:
            return nil
        }
    }

    static func deviceName(_ id: AudioObjectID) -> String {
        if id == CA.system { return "system" }
        return CA.getString(id, CA.addr(kAudioObjectPropertyName)) ?? "#\(id)"
    }

    /// Everything about one device that could bear on a dropout.
    static func device(_ id: AudioObjectID) -> [String: Any] {
        func u32(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Int? {
            CA.get(id, CA.addr(s, scope), UInt32(0)).map { Int($0) }
        }
        let rates = CA.getArray(id, CA.addr(kAudioDevicePropertyAvailableNominalSampleRates), AudioValueRange())
            .map { $0.mMinimum == $0.mMaximum ? "\(Int($0.mMinimum))" : "\(Int($0.mMinimum))-\(Int($0.mMaximum))" }
        var info: [String: Any] = [
            "name": deviceName(id),
            "uid": CA.uid(of: id) ?? "",
            "id": Int(id),
            "transport": fourCC(u32(kAudioDevicePropertyTransportType).map(UInt32.init) ?? 0),
            "in_ch": CA.streamLayout(id, kAudioObjectPropertyScopeInput).reduce(0, +),
            "out_ch": CA.streamLayout(id, kAudioObjectPropertyScopeOutput).reduce(0, +),
            "rate": CA.nominalRate(id) ?? 0,
            "rates": rates,
            "buffer": u32(kAudioDevicePropertyBufferFrameSize) ?? 0,
            "alive": u32(kAudioDevicePropertyDeviceIsAlive) ?? 0,
            "running_somewhere": u32(kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0,
            "hog_pid": Int(CA.get(id, CA.addr(kAudioDevicePropertyHogMode), pid_t(0)) ?? -1),
            "clock_domain": u32(kAudioDevicePropertyClockDomain) ?? 0,
        ]
        for (label, scope) in [("in", kAudioObjectPropertyScopeInput), ("out", kAudioObjectPropertyScopeOutput)] {
            guard (info["\(label)_ch"] as? Int ?? 0) > 0 else { continue }
            let stream = CA.getArray(id, CA.addr(kAudioDevicePropertyStreams, scope), AudioObjectID(0)).first
            info["\(label)_latency_frames"] = [
                "device": u32(kAudioDevicePropertyLatency, scope) ?? 0,
                "safety": u32(kAudioDevicePropertySafetyOffset, scope) ?? 0,
                "stream": stream.flatMap { CA.get($0, CA.addr(kAudioStreamPropertyLatency), UInt32(0)).map { Int($0) } } ?? 0,
            ]
            if let stream, let f = CA.get(stream, CA.addr(kAudioStreamPropertyPhysicalFormat), AudioStreamBasicDescription()) {
                info["\(label)_physical_format"] = "\(Int(f.mSampleRate)) Hz, \(f.mChannelsPerFrame) ch, \(f.mBitsPerChannel) bit, \(fourCC(f.mFormatID))"
            }
        }
        return info
    }

    static func allDevices() -> [[String: Any]] {
        CA.deviceIDs().map(device)
    }

    static func session() -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var model = [CChar](repeating: 0, count: 64)
        var size = model.count
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return [
            "app_version": info["CFBundleShortVersionString"] as? String ?? "dev",
            "app_build": info["CFBundleVersion"] as? String ?? "",
            "app_path": Bundle.main.bundlePath,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "macos": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "mac_model": String(cString: model),
            "cpu_count": ProcessInfo.processInfo.activeProcessorCount,
            "uptime_s": Int(ProcessInfo.processInfo.systemUptime),
            "thermal_state": thermal(),
            "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "running_apps": runningApps(),
        ]
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func runningApps() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
            .sorted()
    }

    static func config(_ c: RouterConfig) -> [String: Any] {
        func slot(_ s: SlotConfig) -> [String: Any] {
            [
                "name": s.name, "device": s.deviceName ?? NSNull(), "uid": s.deviceUID ?? NSNull(),
                "channels": s.stereo ? "\(s.firstChannel + 1)+\(s.firstChannel + 2)" : "\(s.firstChannel + 1)",
                "gain_db": s.gainDB, "muted": s.muted,
                "lowcut": s.lowCut, "compressor": s.compressor, "limiter": s.limiter,
            ]
        }
        var routes: [[String: Any]] = []
        for input in c.inputs {
            for output in c.outputs {
                let r = c.route(input.id, output.id)
                if r.on { routes.append(["from": input.name, "to": output.name, "gain_db": r.gainDB]) }
            }
        }
        return [
            "sample_rate": c.sampleRate, "buffer_frames": c.bufferFrames,
            "clock_uid": c.clockDeviceUID ?? "auto",
            "inputs": c.inputs.map(slot), "outputs": c.outputs.map(slot), "sends": routes,
        ]
    }
}

// MARK: - Heartbeat

/// Every two seconds: is audio flowing on time, how loud is each strip, and has
/// any strip gone to exact digital silence? This is what shows, after the fact,
/// whether a gap was the whole engine stopping or one device going quiet.
final class DiagnosticHeartbeat {
    static let interval: TimeInterval = 2

    private let engine: EngineController
    private let model: RouterModel?
    private var timer: Timer?
    private var lastCallbacks: UInt64 = 0
    private var lastMissing: UInt64 = 0
    private var lastClips: UInt64 = 0
    private var lastOverloads = 0

    init(engine: EngineController, model: RouterModel?) {
        self.engine = engine
        self.model = model
    }

    func start() {
        let core = engine.core
        lastCallbacks = ar_engine_callback_count(core)
        lastMissing = ar_engine_missing_buffer_count(core)
        lastClips = ar_engine_clip_count(core)
        _ = ar_engine_take_max_callback_interval(core)
        _ = ar_engine_take_max_process_time(core)
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.beat() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate() }

    private func beat() {
        let core = engine.core
        let callbacks = ar_engine_callback_count(core)
        let missing = ar_engine_missing_buffer_count(core)
        let clips = ar_engine_clip_count(core)
        let status = engine.currentStatus
        let rate = status.sampleRate > 0 ? status.sampleRate : 48000
        var fields: [String: Any] = [
            "state": status.state.rawValue,
            "callbacks": Int(callbacks &- lastCallbacks),
            "callbacks_expected": status.bufferFrames > 0 ? Int((rate / Double(status.bufferFrames) * Self.interval).rounded()) : 0,
            "max_callback_gap_ms": DiagnosticLog.ms(ar_engine_take_max_callback_interval(core)),
            "max_callback_work_ms": DiagnosticLog.ms(ar_engine_take_max_process_time(core)),
            "missing_buffer_callbacks": Int(missing &- lastMissing),
            "clips": Int(clips &- lastClips),
        ]
        lastCallbacks = callbacks
        lastMissing = missing
        lastClips = clips

        let msPerFrame = 1000 / rate
        if let model {
            fields["overloads"] = model.overloads >= lastOverloads ? model.overloads - lastOverloads : model.overloads
            lastOverloads = model.overloads
            let levels = model.meters.takeLogLevels()
            fields["in"] = model.config.inputs.prefix(RouterConfig.maxInputs).enumerated().map { i, s -> [String: Any] in
                [
                    "name": s.name,
                    "peak_dbfs": DiagnosticInfo.dbfs(levels.inputs[i]) ?? NSNull(),
                    "silent_ms": (Double(ar_engine_take_input_zero_run(core, Int32(i))) * msPerFrame).rounded(),
                    "limiter_db": (Double(levels.limiting[i]) * 10).rounded() / 10,
                    "compressor_db": (Double(levels.compressing[i]) * 10).rounded() / 10,
                ]
            }
            fields["out"] = model.config.outputs.prefix(RouterConfig.maxOutputs).enumerated().map { o, s -> [String: Any] in
                [
                    "name": s.name,
                    "peak_dbfs": DiagnosticInfo.dbfs(levels.outputs[o]) ?? NSNull(),
                    "silent_ms": (Double(ar_engine_take_output_zero_run(core, Int32(o))) * msPerFrame).rounded(),
                ]
            }
        }
        DiagnosticLog.shared.event("heartbeat", fields)
    }
}
