import Foundation

/// One input or output slot: a named, mono or stereo pair of channels on one device.
struct SlotConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var deviceUID: String?
    /// Remembered so an unplugged device can still be shown by name.
    var deviceName: String?
    var firstChannel: Int = 0
    var stereo: Bool = true
    var gainDB: Double = 0
    var muted: Bool = false
    // Input channel strip, all on by default. Outputs carry these but ignore them.
    var limiter = true
    var compressor = true
    var lowCut = true
    /// Outputs only: the short name shown on every input's send button.
    /// Empty means "use the first word of the output's name".
    var sendName = ""

    var width: Int { stereo ? 2 : 1 }

    /// "Teacher Headphones" sends as "Teacher", unless renamed.
    var busName: String {
        let custom = sendName.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom }
        return name.split(separator: " ").first.map(String.init) ?? name
    }
}

extension SlotConfig {
    /// Decodes every field if present, so settings saved before a field existed
    /// still load, with that field at its default. (In an extension, so the
    /// memberwise initialiser survives.)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SlotConfig(name: "")
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        deviceUID = try c.decodeIfPresent(String.self, forKey: .deviceUID)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        firstChannel = try c.decodeIfPresent(Int.self, forKey: .firstChannel) ?? d.firstChannel
        stereo = try c.decodeIfPresent(Bool.self, forKey: .stereo) ?? d.stereo
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? d.gainDB
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? d.muted
        limiter = try c.decodeIfPresent(Bool.self, forKey: .limiter) ?? d.limiter
        compressor = try c.decodeIfPresent(Bool.self, forKey: .compressor) ?? d.compressor
        lowCut = try c.decodeIfPresent(Bool.self, forKey: .lowCut) ?? d.lowCut
        sendName = try c.decodeIfPresent(String.self, forKey: .sendName) ?? d.sendName
    }
}

struct RouteState: Codable, Equatable {
    var on = false
    var gainDB: Double = 0
}

struct RouterConfig: Codable, Equatable {
    static let maxInputs = 8
    static let maxOutputs = 8

    var inputs: [SlotConfig] = []
    var outputs: [SlotConfig] = []
    var routes: [String: RouteState] = [:]
    var sampleRate: Double = 48000
    var bufferFrames: Int = 128
    /// nil = choose automatically (external hardware first).
    var clockDeviceUID: String?

    static func key(_ input: UUID, _ output: UUID) -> String { "\(input.uuidString)>\(output.uuidString)" }

    func route(_ input: UUID, _ output: UUID) -> RouteState { routes[Self.key(input, output)] ?? RouteState() }

    /// Routing a loopback device's input straight back into its own output would
    /// feed the engine's output into its next input — a runaway feedback loop.
    static func isFeedback(_ input: SlotConfig, _ output: SlotConfig, isVirtual: (String) -> Bool) -> Bool {
        guard let uid = input.deviceUID, uid == output.deviceUID, isVirtual(uid) else { return false }
        return input.firstChannel < output.firstChannel + output.width
            && output.firstChannel < input.firstChannel + input.width
    }
}

func linearGain(_ db: Double) -> Float {
    db <= -59.9 ? 0 : Float(pow(10, db / 20))
}

func dbText(_ db: Double) -> String {
    db <= -59.9 ? "−∞ dB" : String(format: "%+.1f dB", db)
}

// MARK: - Persistence

extension RouterConfig {
    private static let defaultsKey = "AudioAngel.RouterConfig.v1"

    static func load() -> RouterConfig? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(RouterConfig.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - First-launch layout

extension RouterConfig {
    /// A starting layout guessed from device names. Everything is editable afterwards.
    ///
    /// Loopback convention (see README):
    ///   BlackHole 2ch   → Zoom's microphone   ("Student")
    ///   BlackHole 16ch  → Zoom's speaker      ("Zoom")
    ///   BlackHole 64ch  → the Mac's output    ("Mac / Browser")
    static func makeDefault(devices: [AudioDeviceInfo]) -> RouterConfig {
        func find(_ match: (AudioDeviceInfo) -> Bool) -> AudioDeviceInfo? { devices.first(where: match) }
        func blackHole(_ channels: String) -> AudioDeviceInfo? {
            find { $0.name.localizedCaseInsensitiveContains("blackhole \(channels)") }
        }
        let pianoWords = ["yamaha", "piano", "clavinova", "arius", "steinberg"]
        let piano = find { d in d.inputChannels > 0 && pianoWords.contains { d.name.localizedCaseInsensitiveContains($0) } }
        let interface = find { $0.inputChannels > 0 && $0.isExternalHardware && $0.uid != piano?.uid }
        let mic = interface ?? find { $0.isBuiltIn && $0.inputChannels > 0 }
        let phones = (interface?.outputChannels ?? 0) >= 2 ? interface : find { $0.isBuiltIn && $0.outputChannels > 0 }

        func slot(_ name: String, _ device: AudioDeviceInfo?, stereo: Bool) -> SlotConfig {
            SlotConfig(name: name, deviceUID: device?.uid, deviceName: device?.name, stereo: stereo)
        }

        var config = RouterConfig()
        let micSlot = slot("Mic", mic, stereo: false)
        let pianoSlot = slot("Piano", piano, stereo: true)
        let macSlot = slot("Mac / Browser", blackHole("64ch"), stereo: true)
        let zoomSlot = slot("Zoom", blackHole("16ch"), stereo: true)
        // Named for what they are in a lesson. Sends show an output's first word,
        // so a name like "To Zoom" would put a send called "To" on every input.
        let toZoom = slot("Student", blackHole("2ch"), stereo: true)
        let headphones = slot("Teacher", phones, stereo: true)
        config.inputs = [micSlot, pianoSlot, macSlot, zoomSlot]
        config.outputs = [toZoom, headphones]

        for (input, output) in [(micSlot, toZoom), (pianoSlot, toZoom), (macSlot, toZoom),
                                (pianoSlot, headphones), (macSlot, headphones), (zoomSlot, headphones)] {
            config.routes[key(input.id, output.id)] = RouteState(on: true, gainDB: 0)
        }
        return config
    }
}
