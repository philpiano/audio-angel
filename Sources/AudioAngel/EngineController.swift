import CoreAudio
import Foundation
import RouterCore

struct EngineStatus: Equatable {
    enum State: String { case stopped, waiting, starting, running, error }

    var state: State = .stopped
    var message = "Not started"
    var sampleRate: Double = 0
    var bufferFrames = 0
    var inputLatencyMs: Double = 0
    var outputLatencyMs: Double = 0
    var clockDeviceName = ""
    var devicesInUse: [String] = []
    /// Needs the user: a device missing, one that couldn't be set up.
    var warnings: [String] = []
    /// Worth knowing, needs nothing: e.g. a device converted from its only rate.
    var notes: [String] = []
}

private func khz(_ rate: Double) -> String {
    rate.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(rate / 1000)) kHz" : String(format: "%.1f kHz", rate / 1000)
}

/// Owns the private aggregate device and the C engine running on it.
///
/// Everything here runs on one serial queue (`hal`), so Core Audio calls never
/// race each other and never block the UI. The design goal is that it heals on
/// its own: devices coming and going, sample-rate changes, sleep/wake and a
/// stalled audio thread all end in an automatic rebuild.
final class EngineController {
    static let aggregateUIDPrefix = "com.philipwarda.audioangel.engine"
    static let maxInputs = Int(AR_MAX_INPUTS)
    static let maxOutputs = Int(AR_MAX_OUTPUTS)

    let core: OpaquePointer

    /// All callbacks are delivered on the main queue.
    var onStatus: ((EngineStatus) -> Void)?
    var onOverload: (() -> Void)?
    var onSystemDevicesChanged: (() -> Void)?

    private let hal = DispatchQueue(label: "com.philipwarda.audioangel.hal", qos: .userInteractive)

    private struct Topology: Equatable {
        struct End: Equatable { var uid: String?; var first: Int; var width: Int }
        var inputs: [End]
        var outputs: [End]
        var sampleRate: Double
        var bufferFrames: Int
        var clockUID: String?

        init(_ c: RouterConfig) {
            inputs = c.inputs.map { End(uid: $0.deviceUID, first: $0.firstChannel, width: $0.width) }
            outputs = c.outputs.map { End(uid: $0.deviceUID, first: $0.firstChannel, width: $0.width) }
            sampleRate = c.sampleRate
            bufferFrames = c.bufferFrames
            clockUID = c.clockDeviceUID
        }
    }

    /// What we check to decide whether a device-list change affects us.
    private struct DeviceSignature: Equatable {
        var uid: String
        var objectID: AudioObjectID
        var inputs: Int
        var outputs: Int
    }

    /// The aggregate as built, and where each device's channels ended up in it.
    private struct Graph {
        var aggregate: AudioObjectID
        var order: [String]
        var inOffsets: [String: Int]
        var outOffsets: [String: Int]
        var inCounts: [String: Int]
        var outCounts: [String: Int]
        var inLayout: [Int]
        var outLayout: [Int]
        var requestedRate: Double
        var requestedBuffer: Int
        var requestedClock: String?
    }

    private struct Listener {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var config: RouterConfig?
    private var graph: Graph?
    private var aggregateID: AudioObjectID = 0
    private var builtTopology: Topology?
    private var builtSignature: [DeviceSignature] = []
    private var virtualUIDs: Set<String> = []
    private var rebuildItem: DispatchWorkItem?
    private var deviceListeners: [Listener] = []
    private var systemListeners: [Listener] = []
    private var watchdog: DispatchSourceTimer?
    private var lastCallbacks: UInt64 = 0
    private var stalledTicks = 0
    private var failures = 0
    private var started = false
    /// Bumped on every teardown. Device notifications from an older build can
    /// arrive late (destroying the old aggregate itself fires "not alive"); they
    /// carry their generation and are ignored if it's stale.
    private var generation = 0
    /// When audio last (re)started; overloads just after it aren't counted.
    private var runningSince = Date.distantPast

    private var status = EngineStatus() {
        didSet {
            guard status != oldValue else { return }
            let snapshot = status
            DispatchQueue.main.async { self.onStatus?(snapshot) }
        }
    }

    init() {
        guard let core = ar_engine_create() else { fatalError("Could not allocate the audio engine") }
        self.core = core
    }

    // MARK: - Public API (any thread)

    func start() {
        hal.async {
            guard !self.started else { return }
            self.started = true
            self.installSystemListeners()
            self.startWatchdog()
            self.scheduleRebuild(after: 0)
        }
    }

    /// Call on every config change. Gain/mute/route edits apply instantly; changes
    /// to which devices or channels are used trigger a remap or a rebuild.
    func update(config newConfig: RouterConfig) {
        hal.async {
            self.config = newConfig
            guard self.started else { return }
            if Topology(newConfig) == self.builtTopology {
                self.pushParams()
            } else if !self.tryRemap() {
                self.silenceRoutes()
                self.scheduleRebuild(after: 0.25)
            }
        }
    }

    func restart(after delay: TimeInterval = 0) {
        hal.async {
            guard self.started else { return }
            self.scheduleRebuild(after: delay)
        }
    }

    /// Stops audio and destroys the aggregate. Blocks until done.
    func shutdown() {
        hal.sync {
            self.started = false
            self.rebuildItem?.cancel()
            self.watchdog?.cancel()
            self.watchdog = nil
            self.systemListeners.forEach(self.remove)
            self.systemListeners = []
            self.teardown()
            self.status = EngineStatus(state: .stopped, message: "Stopped")
        }
    }

    // MARK: - Parameters

    private func pushParams() {
        guard let cfg = config else { return }
        let isVirtual: (String) -> Bool = { self.virtualUIDs.contains($0) }
        for i in 0..<Self.maxInputs {
            if i < cfg.inputs.count {
                let s = cfg.inputs[i]
                ar_engine_set_input_gain(core, Int32(i), linearGain(s.gainDB))
                ar_engine_set_input_mute(core, Int32(i), s.muted)
                var fx: UInt32 = 0
                if s.limiter { fx |= AR_FX_LIMITER }
                if s.compressor { fx |= AR_FX_COMPRESSOR }
                if s.lowCut { fx |= AR_FX_LOWCUT }
                ar_engine_set_input_effects(core, Int32(i), fx)
            }
            for o in 0..<Self.maxOutputs {
                var gain: Float = 0
                if i < cfg.inputs.count, o < cfg.outputs.count {
                    let r = cfg.route(cfg.inputs[i].id, cfg.outputs[o].id)
                    let feedback = RouterConfig.isFeedback(cfg.inputs[i], cfg.outputs[o], isVirtual: isVirtual)
                    if r.on && !feedback { gain = linearGain(r.gainDB) }
                }
                ar_engine_set_route(core, Int32(i), Int32(o), gain)
            }
        }
        for o in 0..<min(cfg.outputs.count, Self.maxOutputs) {
            ar_engine_set_output_gain(core, Int32(o), linearGain(cfg.outputs[o].gainDB))
            ar_engine_set_output_mute(core, Int32(o), cfg.outputs[o].muted)
        }
    }

    /// Slot indices are about to change meaning; make sure nothing plays in the wrong place meanwhile.
    private func silenceRoutes() {
        for i in 0..<Self.maxInputs {
            for o in 0..<Self.maxOutputs { ar_engine_set_route(core, Int32(i), Int32(o), 0) }
        }
    }

    // MARK: - Building

    private func scheduleRebuild(after delay: TimeInterval) {
        rebuildItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.rebuild() }
        rebuildItem = item
        hal.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Devices in use, in slot order, that are present and have the channels asked for.
    private func usedDevices(_ cfg: RouterConfig, _ byUID: [String: AudioDeviceInfo]) -> [String] {
        var used: [String] = []
        func consider(_ slot: SlotConfig, _ channels: (AudioDeviceInfo) -> Int) {
            guard let uid = slot.deviceUID, let d = byUID[uid], slot.firstChannel + slot.width <= channels(d) else { return }
            if !used.contains(uid) { used.append(uid) }
        }
        cfg.inputs.prefix(Self.maxInputs).forEach { consider($0, \.inputChannels) }
        cfg.outputs.prefix(Self.maxOutputs).forEach { consider($0, \.outputChannels) }
        return used
    }

    private func signature(_ cfg: RouterConfig, _ byUID: [String: AudioDeviceInfo]) -> [DeviceSignature] {
        let uids = Set((cfg.inputs + cfg.outputs).compactMap(\.deviceUID)).sorted()
        return uids.map { uid in
            let d = byUID[uid]
            return DeviceSignature(uid: uid, objectID: d?.objectID ?? 0, inputs: d?.inputChannels ?? 0, outputs: d?.outputChannels ?? 0)
        }
    }

    private func pickClock(_ cfg: RouterConfig, _ used: [String], _ byUID: [String: AudioDeviceInfo]) -> String {
        if let chosen = cfg.clockDeviceUID, used.contains(chosen) { return chosen }
        let devices = used.compactMap { byUID[$0] }
        return (devices.first { $0.isExternalHardware }
            ?? devices.first { !$0.isVirtual }
            ?? devices[0]).uid
    }

    private func rebuild() {
        rebuildItem = nil
        guard started, let cfg = config else { return }
        teardown()

        let devices = AudioDeviceInfo.all()
        let byUID = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        virtualUIDs = Set(devices.filter(\.isVirtual).map(\.uid))
        builtTopology = Topology(cfg)
        builtSignature = signature(cfg, byUID)

        var warnings: [String] = []
        for slot in cfg.inputs + cfg.outputs {
            guard let uid = slot.deviceUID else { continue }
            if byUID[uid] == nil { warnings.append("\(slot.name): \(slot.deviceName ?? "device") is not connected") }
        }
        if cfg.inputs.count > Self.maxInputs || cfg.outputs.count > Self.maxOutputs {
            warnings.append("Only the first \(Self.maxInputs) inputs and \(Self.maxOutputs) outputs are used")
        }

        let used = usedDevices(cfg, byUID)
        guard !used.isEmpty else {
            status = EngineStatus(state: .waiting,
                                  message: cfg.inputs.isEmpty && cfg.outputs.isEmpty ? "Add an input and an output" : "Waiting for devices…",
                                  warnings: warnings)
            return
        }
        status = EngineStatus(state: .starting, message: "Starting…", warnings: warnings)

        let clock = pickClock(cfg, used, byUID)
        var notes: [String] = []
        for uid in used {
            guard let d = byUID[uid] else { continue }
            if !CA.setNominalRate(d.objectID, cfg.sampleRate) {
                if CA.supportsRate(d.objectID, cfg.sampleRate) {
                    warnings.append("\(d.name) couldn't switch to \(khz(cfg.sampleRate)). Another app may be holding it.")
                } else {
                    // The aggregate's drift compensation resamples it; this is fine.
                    notes.append("\(d.name) only runs at \(khz(d.sampleRate)), so macOS converts it to \(khz(cfg.sampleRate)) on the way in. Nothing to fix.")
                }
            }
        }

        let order = [clock] + used.filter { $0 != clock }
        let subDevices: [[String: Any]] = order.map { uid in
            [kAudioSubDeviceUIDKey: uid,
             kAudioSubDeviceDriftCompensationKey: uid == clock ? 0 : 1]
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Audio Angel Engine",
            kAudioAggregateDeviceUIDKey: "\(Self.aggregateUIDPrefix).\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: clock,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
        ]
        var agg: AudioObjectID = 0
        let createStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg)
        guard createStatus == noErr, agg != 0 else {
            return fail("Couldn't create the routing device (error \(createStatus))", warnings)
        }
        aggregateID = agg

        let expectedIn = order.reduce(0) { $0 + (byUID[$1]?.inputChannels ?? 0) }
        let expectedOut = order.reduce(0) { $0 + (byUID[$1]?.outputChannels ?? 0) }
        guard waitForAggregate(agg, inputs: expectedIn, outputs: expectedOut, timeout: 3) else {
            return fail("The routing device didn't come up — a device may be busy or unplugging", warnings)
        }

        CA.setNominalRate(agg, cfg.sampleRate)
        let range = CA.get(agg, CA.addr(kAudioDevicePropertyBufferFrameSizeRange), AudioValueRange())
        var frames = Double(cfg.bufferFrames)
        if let range { frames = min(max(frames, range.mMinimum), range.mMaximum) }
        CA.set(agg, CA.addr(kAudioDevicePropertyBufferFrameSize), UInt32(frames))

        guard streamsAreFloat32(agg) else {
            return fail("A device uses a sample format Audio Angel can't handle", warnings)
        }

        // The aggregate lays channels out device by device, in sub-device order.
        let actualOrder: [String] = {
            let full = CA.getStringArray(agg, CA.addr(kAudioAggregateDevicePropertyFullSubDeviceList)) ?? []
            return Set(full) == Set(order) ? full : order
        }()
        var inOffsets: [String: Int] = [:], outOffsets: [String: Int] = [:]
        var inCounts: [String: Int] = [:], outCounts: [String: Int] = [:]
        var inAcc = 0, outAcc = 0
        for uid in actualOrder {
            let d = byUID[uid]
            inOffsets[uid] = inAcc; inCounts[uid] = d?.inputChannels ?? 0; inAcc += d?.inputChannels ?? 0
            outOffsets[uid] = outAcc; outCounts[uid] = d?.outputChannels ?? 0; outAcc += d?.outputChannels ?? 0
        }
        let inLayout = CA.streamLayout(agg, kAudioObjectPropertyScopeInput)
        let outLayout = CA.streamLayout(agg, kAudioObjectPropertyScopeOutput)
        guard inLayout.reduce(0, +) == inAcc, outLayout.reduce(0, +) == outAcc else {
            return fail("Channel layout mismatch (in \(inLayout.reduce(0, +))/\(inAcc), out \(outLayout.reduce(0, +))/\(outAcc))", warnings)
        }

        let g = Graph(aggregate: agg, order: actualOrder,
                      inOffsets: inOffsets, outOffsets: outOffsets, inCounts: inCounts, outCounts: outCounts,
                      inLayout: inLayout, outLayout: outLayout,
                      requestedRate: cfg.sampleRate, requestedBuffer: cfg.bufferFrames, requestedClock: cfg.clockDeviceUID)
        let actualRate = CA.nominalRate(agg) ?? cfg.sampleRate
        ar_engine_set_sample_rate(core, actualRate)
        applyMaps(cfg, g)
        pushParams()

        let startStatus = ar_engine_start(core, agg)
        guard startStatus == noErr else {
            return fail("Couldn't start audio (error \(startStatus))", warnings)
        }
        graph = g
        runningSince = Date()
        installDeviceListeners(g, byUID)

        failures = 0
        stalledTicks = 0
        lastCallbacks = ar_engine_callback_count(core)
        let actualFrames = Int(CA.get(agg, CA.addr(kAudioDevicePropertyBufferFrameSize), UInt32(0)) ?? UInt32(frames))
        status = EngineStatus(
            state: .running,
            message: "Routing \(order.count) device\(order.count == 1 ? "" : "s")",
            sampleRate: actualRate,
            bufferFrames: actualFrames,
            inputLatencyMs: latencyMs(agg, kAudioObjectPropertyScopeInput, frames: actualFrames, rate: actualRate),
            outputLatencyMs: latencyMs(agg, kAudioObjectPropertyScopeOutput, frames: actualFrames, rate: actualRate),
            clockDeviceName: byUID[clock]?.name ?? "",
            devicesInUse: actualOrder.compactMap { byUID[$0]?.name },
            warnings: warnings,
            notes: notes
        )
    }

    /// Channel choices changed but the same devices are in use: just re-point the
    /// slots. A few milliseconds of silence instead of a full rebuild.
    private func tryRemap() -> Bool {
        guard let cfg = config, let g = graph, ar_engine_is_running(core) else { return false }
        guard cfg.sampleRate == g.requestedRate, cfg.bufferFrames == g.requestedBuffer,
              cfg.clockDeviceUID == g.requestedClock else { return false }
        let devices = AudioDeviceInfo.all()
        let byUID = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        guard Set(usedDevices(cfg, byUID)) == Set(g.order) else { return false }

        ar_engine_stop(core)
        applyMaps(cfg, g)
        pushParams()
        guard ar_engine_start(core, g.aggregate) == noErr else { return false }
        runningSince = Date()
        builtTopology = Topology(cfg)
        builtSignature = signature(cfg, byUID)
        lastCallbacks = ar_engine_callback_count(core)
        return true
    }

    private func applyMaps(_ cfg: RouterConfig, _ g: Graph) {
        ar_engine_clear_topology(core)

        func ref(_ global: Int, _ layout: [Int]) -> (Int32, Int32)? {
            var g = global
            for (buffer, channels) in layout.enumerated() {
                if g < channels { return (Int32(buffer), Int32(g)) }
                g -= channels
            }
            return nil
        }
        func map(_ slot: SlotConfig, offsets: [String: Int], counts: [String: Int], layout: [Int]) -> (Int32, Int32, Int32, Int32, Int32)? {
            guard let uid = slot.deviceUID, let base = offsets[uid], let count = counts[uid],
                  slot.firstChannel >= 0, slot.firstChannel + slot.width <= count,
                  let a = ref(base + slot.firstChannel, layout) else { return nil }
            if slot.stereo {
                guard let b = ref(base + slot.firstChannel + 1, layout) else { return nil }
                return (2, a.0, a.1, b.0, b.1)
            }
            return (1, a.0, a.1, -1, -1)
        }

        for (i, slot) in cfg.inputs.prefix(Self.maxInputs).enumerated() {
            if let m = map(slot, offsets: g.inOffsets, counts: g.inCounts, layout: g.inLayout) {
                ar_engine_set_input_map(core, Int32(i), m.0, m.1, m.2, m.3, m.4)
            }
        }
        for (o, slot) in cfg.outputs.prefix(Self.maxOutputs).enumerated() {
            if let m = map(slot, offsets: g.outOffsets, counts: g.outCounts, layout: g.outLayout) {
                ar_engine_set_output_map(core, Int32(o), m.0, m.1, m.2, m.3, m.4)
            }
        }
    }

    private func fail(_ message: String, _ warnings: [String]) {
        teardown()
        failures += 1
        let retry = min(pow(2, Double(failures)), 15)
        status = EngineStatus(state: .error, message: "\(message). Retrying in \(Int(retry)) s", warnings: warnings)
        scheduleRebuild(after: retry)
    }

    private func teardown() {
        generation += 1
        deviceListeners.forEach(remove)
        deviceListeners = []
        if ar_engine_is_running(core) { ar_engine_stop(core) }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        graph = nil
    }

    private func waitForAggregate(_ agg: AudioObjectID, inputs: Int, outputs: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let i = CA.streamLayout(agg, kAudioObjectPropertyScopeInput).reduce(0, +)
            let o = CA.streamLayout(agg, kAudioObjectPropertyScopeOutput).reduce(0, +)
            if i == inputs && o == outputs && CA.isAlive(agg) { return true }
            usleep(20_000)
        } while Date() < deadline
        return false
    }

    private func streamsAreFloat32(_ device: AudioObjectID) -> Bool {
        for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
            for stream in CA.getArray(device, CA.addr(kAudioDevicePropertyStreams, scope), AudioObjectID(0)) {
                guard let f = CA.get(stream, CA.addr(kAudioStreamPropertyVirtualFormat), AudioStreamBasicDescription()) else { continue }
                if f.mFormatID != kAudioFormatLinearPCM || f.mFormatFlags & kAudioFormatFlagIsFloat == 0 || f.mBitsPerChannel != 32 {
                    return false
                }
            }
        }
        return true
    }

    private func latencyMs(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope, frames: Int, rate: Double) -> Double {
        let device32 = CA.get(device, CA.addr(kAudioDevicePropertyLatency, scope), UInt32(0)) ?? 0
        let safety = CA.get(device, CA.addr(kAudioDevicePropertySafetyOffset, scope), UInt32(0)) ?? 0
        let streams = CA.getArray(device, CA.addr(kAudioDevicePropertyStreams, scope), AudioObjectID(0))
        let stream = streams.first.flatMap { CA.get($0, CA.addr(kAudioStreamPropertyLatency), UInt32(0)) } ?? 0
        let total = Double(device32) + Double(safety) + Double(stream) + Double(frames)
        return rate > 0 ? total / rate * 1000 : 0
    }

    // MARK: - Listening

    /// Core Audio delivers notifications with dispatch_sync onto the listener's
    /// queue, and some HAL calls (creating an aggregate, for one) wait for those
    /// notifications to be delivered. If listeners ran on `hal` while `hal` was
    /// inside such a call, both would wait on each other forever. So listeners get
    /// their own queue and only ever hand work to `hal` asynchronously.
    private let notifyQueue = DispatchQueue(label: "com.philipwarda.audioangel.notify")

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ handler: @escaping () -> Void) -> Listener? {
        var address = CA.addr(selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [hal] _, _ in hal.async(execute: handler) }
        guard AudioObjectAddPropertyListenerBlock(object, &address, notifyQueue, block) == noErr else { return nil }
        return Listener(object: object, address: address, block: block)
    }

    private func remove(_ listener: Listener) {
        var address = listener.address
        AudioObjectRemovePropertyListenerBlock(listener.object, &address, notifyQueue, listener.block)
    }

    private func installSystemListeners() {
        systemListeners = [
            listen(CA.system, kAudioHardwarePropertyDevices) { [weak self] in self?.systemDevicesChanged() },
            listen(CA.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                DispatchQueue.main.async { self?.onSystemDevicesChanged?() }
            },
        ].compactMap { $0 }
    }

    private func systemDevicesChanged() {
        DispatchQueue.main.async { self.onSystemDevicesChanged?() }
        guard started, let cfg = config else { return }
        let devices = AudioDeviceInfo.all()
        let byUID = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        if signature(cfg, byUID) != builtSignature {
            // USB devices often appear before they're ready; give them a moment.
            status.message = "Devices changed — reconnecting…"
            scheduleRebuild(after: 0.75)
        }
    }

    private func installDeviceListeners(_ g: Graph, _ byUID: [String: AudioDeviceInfo]) {
        var listeners: [Listener?] = []
        listeners.append(listen(g.aggregate, kAudioDeviceProcessorOverload) { [weak self] in
            // Devices settling in the first moments after a start can trip this;
            // that isn't a dropout during playing, so it isn't counted.
            guard let self, Date().timeIntervalSince(self.runningSince) > 2 else { return }
            DispatchQueue.main.async { self.onOverload?() }
        })
        let watched = [g.aggregate] + g.order.compactMap { byUID[$0]?.objectID }
        let gen = generation
        for object in watched {
            listeners.append(listen(object, kAudioDevicePropertyDeviceIsAlive) { [weak self] in
                guard let self, gen == self.generation, !CA.isAlive(object) else { return }
                self.status.message = "A device went away — reconnecting…"
                self.scheduleRebuild(after: 0.5)
            })
            listeners.append(listen(object, kAudioDevicePropertyNominalSampleRate) { [weak self] in
                guard let self, gen == self.generation,
                      let rate = CA.nominalRate(object), abs(rate - g.requestedRate) > 0.5 else { return }
                self.status.message = "Sample rate changed elsewhere — resetting…"
                self.scheduleRebuild(after: 1.0)
            })
        }
        deviceListeners = listeners.compactMap { $0 }
    }

    /// If the audio thread stops calling us while we think we're running, rebuild.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: hal)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        timer.resume()
        watchdog = timer
    }

    private func watchdogTick() {
        guard status.state == .running, ar_engine_is_running(core) else {
            stalledTicks = 0
            return
        }
        let count = ar_engine_callback_count(core)
        if count == lastCallbacks {
            stalledTicks += 1
            if stalledTicks >= 3 {
                stalledTicks = 0
                status.message = "Audio stalled — restarting…"
                scheduleRebuild(after: 0)
            }
        } else {
            stalledTicks = 0
        }
        lastCallbacks = count
    }
}
