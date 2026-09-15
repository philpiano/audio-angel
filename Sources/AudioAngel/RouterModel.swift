import AppKit
import AVFoundation
import RouterCore
import SwiftUI

enum SlotHealth {
    case unassigned, offline, badChannels, ok

    var color: Color {
        switch self {
        case .ok: return .green
        case .unassigned: return .gray
        case .offline: return .orange
        case .badChannels: return .red
        }
    }

    var help: String {
        switch self {
        case .ok: return "Connected"
        case .unassigned: return "No device chosen"
        case .offline: return "Device not connected — it will reconnect automatically"
        case .badChannels: return "That device doesn't have these channels"
        }
    }
}

/// The app's state: the saved routing config, the device list, and the engine.
final class RouterModel: ObservableObject {
    static weak var current: RouterModel?

    @Published var config: RouterConfig {
        didSet {
            guard config != oldValue else { return }
            engine.update(config: config)
            scheduleSave()
        }
    }
    private var heartbeat: DiagnosticHeartbeat?
    private var observers: [NSObjectProtocol] = []
    @Published private(set) var devices: [AudioDeviceInfo] = []
    @Published private(set) var status = EngineStatus()
    @Published private(set) var overloads = 0
    @Published private(set) var defaultOutputUID: String?
    @Published private(set) var micPermission: AVAuthorizationStatus = .notDetermined

    let engine = EngineController()
    let meters: MeterStore
    private var saveItem: DispatchWorkItem?
    private var activity: NSObjectProtocol?

    /// `live: false` builds the model for a UI snapshot: no audio, no permission
    /// prompt, nothing saved.
    init(live: Bool = true) {
        meters = MeterStore(core: engine.core)
        let found = AudioDeviceInfo.all()
        devices = found
        config = RouterConfig.load() ?? RouterConfig.makeDefault(devices: found)
        defaultOutputUID = CA.defaultOutputDevice().flatMap(CA.uid(of:))
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio) // reading it never prompts
        guard live else { return }
        RouterModel.current = self

        DiagnosticLog.shared.start()
        DiagnosticLog.shared.event("session_start", DiagnosticInfo.session())
        DiagnosticLog.shared.event("config", DiagnosticInfo.config(config))
        DiagnosticLog.shared.event("devices", ["devices": DiagnosticInfo.allDevices()])
        lastLoggedConfig = config

        engine.onStatus = { [weak self] in self?.status = $0 }
        engine.onOverload = { [weak self] in self?.overloads += 1 }
        engine.onSystemDevicesChanged = { [weak self] in self?.refreshDevices() }

        // Audio must never be throttled by App Nap, even with the window hidden.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Routing live audio")

        let workspace = NSWorkspace.shared.notificationCenter
        // USB devices re-enumerate after sleep; rebuild once they're back.
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DiagnosticLog.shared.event("mac_woke")
            self?.engine.restart(after: 2, reason: "Mac woke from sleep")
        })
        observeForLog()

        config.save()
        engine.update(config: config)
        engine.start()
        checkMicPermission()

        let beat = DiagnosticHeartbeat(engine: engine, model: self)
        beat.start()
        heartbeat = beat
    }

    func shutdown() {
        saveItem?.perform()
        config.save()
        heartbeat?.stop()
        engine.shutdown()
        meters.stop()
        DiagnosticLog.shared.event("app_quit", ["overloads": overloads, "clips": Int(clamping: meters.clips)])
        DiagnosticLog.shared.stop()
    }

    // MARK: - Diagnostic log

    private var lastLoggedConfig: RouterConfig?

    /// Things outside Audio Angel that can disturb audio, recorded when they happen.
    private func observeForLog() {
        let log = DiagnosticLog.shared
        let workspace = NSWorkspace.shared.notificationCenter
        let simple: [(Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, "mac_will_sleep"),
            (NSWorkspace.screensDidSleepNotification, "screens_slept"),
            (NSWorkspace.screensDidWakeNotification, "screens_woke"),
            (NSWorkspace.sessionDidResignActiveNotification, "user_session_inactive"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "user_session_active"),
        ]
        for (name, event) in simple {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in log.event(event) })
        }
        for (name, event) in [(NSWorkspace.didLaunchApplicationNotification, "app_launched"),
                              (NSWorkspace.didTerminateApplicationNotification, "app_terminated")] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                log.event(event, ["name": app?.localizedName ?? "?", "bundle_id": app?.bundleIdentifier ?? "?"])
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            log.event("thermal_state", ["state": DiagnosticInfo.thermal()])
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            log.event("low_power_mode", ["on": ProcessInfo.processInfo.isLowPowerModeEnabled])
        })
    }

    // MARK: - Devices

    func resetOverloads() { overloads = 0 }

    /// README screenshots only (`--snapshot FILE --demo`): show the desk as it looks on
    /// a working rig, with every assigned device switched on. No audio is started.
    func showForScreenshot(_ status: EngineStatus) {
        self.status = status
        micPermission = .authorized
        // Stand in for assigned devices that happen to be switched off right now.
        var present = Set(devices.map(\.uid))
        for (slot, isInput) in config.inputs.map({ ($0, true) }) + config.outputs.map({ ($0, false) }) {
            guard let uid = slot.deviceUID, !present.contains(uid) else { continue }
            present.insert(uid)
            let channels = max(slot.firstChannel + slot.width, 2)
            devices.append(AudioDeviceInfo(
                objectID: 0, uid: uid, name: slot.deviceName ?? slot.name,
                inputChannels: isInput ? channels : 0, outputChannels: isInput ? 0 : channels,
                transport: kAudioDeviceTransportTypeUSB, sampleRate: 48000))
        }
    }

    func refreshDevices() {
        devices = AudioDeviceInfo.all()
        defaultOutputUID = CA.defaultOutputDevice().flatMap(CA.uid(of:))
    }

    func device(_ uid: String?) -> AudioDeviceInfo? {
        guard let uid else { return nil }
        return devices.first { $0.uid == uid }
    }

    var inputDevices: [AudioDeviceInfo] { devices.filter { $0.inputChannels > 0 } }
    var outputDevices: [AudioDeviceInfo] { devices.filter { $0.outputChannels > 0 } }

    func setSystemOutput(_ uid: String) {
        guard let d = device(uid) else { return }
        CA.setDefaultOutputDevice(d.objectID)
        refreshDevices()
    }

    func health(_ slot: SlotConfig, isInput: Bool) -> SlotHealth {
        guard let uid = slot.deviceUID else { return .unassigned }
        guard let d = device(uid) else { return .offline }
        let channels = isInput ? d.inputChannels : d.outputChannels
        return slot.firstChannel + slot.width <= channels ? .ok : .badChannels
    }

    func isFeedback(_ input: SlotConfig, _ output: SlotConfig) -> Bool {
        RouterConfig.isFeedback(input, output) { uid in self.device(uid)?.isVirtual ?? true }
    }

    // MARK: - Slots

    func index(of id: UUID, isInput: Bool) -> Int? {
        (isInput ? config.inputs : config.outputs).firstIndex { $0.id == id }
    }

    func addInput() {
        guard config.inputs.count < RouterConfig.maxInputs else { return }
        config.inputs.append(SlotConfig(name: "Input \(config.inputs.count + 1)", stereo: true))
    }

    func addOutput() {
        guard config.outputs.count < RouterConfig.maxOutputs else { return }
        config.outputs.append(SlotConfig(name: "Output \(config.outputs.count + 1)", stereo: true))
    }

    func remove(_ id: UUID, isInput: Bool) {
        var c = config
        if isInput { c.inputs.removeAll { $0.id == id } } else { c.outputs.removeAll { $0.id == id } }
        let idString = id.uuidString
        c.routes = c.routes.filter { !$0.key.contains(idString) }
        config = c
    }

    func move(_ id: UUID, isInput: Bool, by delta: Int) {
        var list = isInput ? config.inputs : config.outputs
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard list.indices.contains(j) else { return }
        list.swapAt(i, j)
        if isInput { config.inputs = list } else { config.outputs = list }
    }

    func routeBinding(_ input: UUID, _ output: UUID) -> Binding<RouteState> {
        Binding(
            get: { self.config.route(input, output) },
            set: { self.config.routes[RouterConfig.key(input, output)] = $0 }
        )
    }

    // MARK: - Permission

    func checkMicPermission() {
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micPermission == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
                DiagnosticLog.shared.event("microphone_permission", ["granted": granted])
                self.engine.restart(after: 0.2, reason: "microphone permission answered")
            }
        }
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.config.save()
            // Settle-then-log, so a fader drag is one entry, not hundreds.
            if self.config != self.lastLoggedConfig {
                self.lastLoggedConfig = self.config
                DiagnosticLog.shared.event("config", DiagnosticInfo.config(self.config))
            }
        }
        saveItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
}

/// Meter levels, polled from the engine at 30 Hz. Kept separate from RouterModel
/// so only the meters redraw 30 times a second, not the whole window.
final class MeterStore: ObservableObject {
    @Published private(set) var inputs = Array(repeating: [Float](repeating: 0, count: 2), count: RouterConfig.maxInputs)
    @Published private(set) var outputs = Array(repeating: [Float](repeating: 0, count: 2), count: RouterConfig.maxOutputs)
    @Published private(set) var clips: UInt64 = 0
    /// Gain reduction in dB per input, for the effect buttons' activity lights.
    @Published private(set) var limiting = [Float](repeating: 0, count: RouterConfig.maxInputs)
    @Published private(set) var compressing = [Float](repeating: 0, count: RouterConfig.maxInputs)

    private let core: OpaquePointer
    private var timer: Timer?
    private var clipBaseline: UInt64 = 0

    /// The loudest level of each strip since the diagnostic heartbeat last asked.
    private var logIn = [Float](repeating: 0, count: RouterConfig.maxInputs)
    private var logOut = [Float](repeating: 0, count: RouterConfig.maxOutputs)
    private var logLimit = [Float](repeating: 0, count: RouterConfig.maxInputs)
    private var logComp = [Float](repeating: 0, count: RouterConfig.maxInputs)

    func takeLogLevels() -> (inputs: [Float], outputs: [Float], limiting: [Float], compressing: [Float]) {
        defer {
            logIn = logIn.map { _ in 0 }; logOut = logOut.map { _ in 0 }
            logLimit = logLimit.map { _ in 0 }; logComp = logComp.map { _ in 0 }
        }
        return (logIn, logOut, logLimit, logComp)
    }

    /// The engine's clip count only ever grows; "reset" counts from here on.
    func resetClips() {
        clipBaseline = ar_engine_clip_count(core)
        clips = 0
    }

    func reduction(_ i: Int, _ effect: InputEffect) -> Float {
        guard limiting.indices.contains(i) else { return 0 }
        switch effect {
        case .limiter: return limiting[i]
        case .compressor: return compressing[i]
        case .lowCut: return 0
        }
    }

    init(core: OpaquePointer) {
        self.core = core
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate() }

    func input(_ i: Int) -> [Float] { inputs.indices.contains(i) ? inputs[i] : [0, 0] }
    func output(_ o: Int) -> [Float] { outputs.indices.contains(o) ? outputs[o] : [0, 0] }

    private func tick() {
        // Fast attack, ~300 ms release.
        let release: Float = 0.82
        var newIn = inputs, newOut = outputs
        for i in 0..<newIn.count {
            for c in 0..<2 {
                let peak = ar_engine_take_input_peak(core, Int32(i), Int32(c))
                logIn[i] = max(logIn[i], peak)
                newIn[i][c] = max(peak, newIn[i][c] * release)
            }
        }
        for o in 0..<newOut.count {
            for c in 0..<2 {
                let peak = ar_engine_take_output_peak(core, Int32(o), Int32(c))
                logOut[o] = max(logOut[o], peak)
                newOut[o][c] = max(peak, newOut[o][c] * release)
            }
        }
        inputs = newIn
        outputs = newOut
        // Lights hold briefly so a single caught peak is visible.
        var newLimit = limiting, newComp = compressing
        for i in 0..<newLimit.count {
            let lim = ar_engine_take_input_reduction(core, Int32(i), AR_FX_LIMITER)
            let comp = ar_engine_take_input_reduction(core, Int32(i), AR_FX_COMPRESSOR)
            logLimit[i] = max(logLimit[i], lim)
            logComp[i] = max(logComp[i], comp)
            newLimit[i] = max(lim, newLimit[i] * 0.85)
            newComp[i] = max(comp, newComp[i] * 0.85)
        }
        if newLimit != limiting { limiting = newLimit }
        if newComp != compressing { compressing = newComp }
        let total = ar_engine_clip_count(core)
        let c = total >= clipBaseline ? total - clipBaseline : 0
        if c != clips { clips = c }
    }
}
