import SwiftUI

// The mixer, laid out like Logic's: one row of narrow channel strips.
//
//   INPUT ↓                                  ┃ OUTPUT ↑
//   ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐      ┃ ┌──────┐ ┌──────┐
//   │source│ │      │ │      │ │      │      ┃ │source│ │      │   ← the send that feeds it
//   │effect│ │      │ │      │ │      │      ┃ │      │ │      │
//   │fader │ │      │ │      │ │      │      ┃ │fader │ │      │
//   │sends │ │      │ │      │ │      │      ┃ │device│ │      │   ← where it plays
//   └──────┘ └──────┘ └──────┘ └──────┘      ┃ └──────┘ └──────┘
//
// An input's SEND buttons (on/off, plus a level knob) are the routing: each
// one names an output. Every section has a fixed height, so faders line up
// across all strips.

enum Mixer {
    static let stripWidth: CGFloat = 150
    static let spacing: CGFloat = 8
    static let minZoneWidth: CGFloat = 300
    static let gap: CGFloat = 6
    static let control: CGFloat = 24
    static let labelBlock: CGFloat = 16            // section label + its spacing
    static let sourceHeight = labelBlock + control * 2 + 6
    static let effectsHeight = labelBlock + control * 3 + 5 * 2
    static let faderHeight: CGFloat = 150
    static let pillWidth: CGFloat = 92
    static let knobSize: CGFloat = 20
    static let line = Color.primary.opacity(0.6)

    static func zoneWidth(_ strips: Int) -> CGFloat {
        let n = CGFloat(strips)
        return max(minZoneWidth, n * stripWidth + max(0, n - 1) * spacing)
    }

    /// Inputs' SEND list and outputs' OUTPUT pickers share this height.
    static func lowerHeight(outputs: Int) -> CGFloat {
        let n = CGFloat(outputs)
        return labelBlock + max(n * control + max(0, n - 1) * 6, control * 2 + 6)
    }

    /// The desk was designed around six strips; the window opens exactly that wide.
    static let standardModules = 6

    /// Width of the window's content for six strips, split the way this config
    /// splits them between inputs and outputs.
    static func standardWidth(outputs: Int) -> CGFloat {
        let outs = min(outputs, standardModules)
        let ins = standardModules - outs
        return zoneWidth(ins) + 24 + 2 + 24 + zoneWidth(outs) + 2 * 20 // zones, divider, padding
    }
}

struct MixerView: View {
    @EnvironmentObject var model: RouterModel

    var body: some View {
        let inputs = model.config.inputs.count
        let outputs = model.config.outputs.count
        let lower = Mixer.lowerHeight(outputs: outputs)

        HStack(alignment: .top, spacing: 24) {
            Zone(title: "Input", arrow: "arrow.down", addTitle: "Add input",
                 canAdd: inputs < RouterConfig.maxInputs, add: { model.addInput() },
                 emptyHint: inputs == 0 ? "Add an input for each sound source: a mic, the piano, the Mac, Zoom." : nil,
                 width: Mixer.zoneWidth(inputs)) {
                ForEach($model.config.inputs) { $slot in
                    InputStrip(slot: $slot, lowerHeight: lower)
                }
            }
            Rectangle().fill(Mixer.line).frame(width: 2).frame(maxHeight: .infinity)
            Zone(title: "Output", arrow: "arrow.up", addTitle: "Add output",
                 canAdd: outputs < RouterConfig.maxOutputs, add: { model.addOutput() },
                 emptyHint: outputs == 0 ? "Add an output for each place sound should go: your headphones, Zoom." : nil,
                 width: Mixer.zoneWidth(outputs)) {
                ForEach($model.config.outputs) { $slot in
                    OutputStrip(slot: $slot, lowerHeight: lower)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true) // lets the divider match the strips' height
    }
}

// MARK: - Zones

struct Zone<Content: View>: View {
    let title: String
    let arrow: String
    let addTitle: String
    let canAdd: Bool
    let add: () -> Void
    let emptyHint: String?
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZoneTitle(text: title, arrow: arrow)
                Spacer(minLength: 12)
                AddSlotButton(title: addTitle, enabled: canAdd, action: add)
            }
            .frame(width: width)
            if let emptyHint {
                EmptyZoneHint(text: emptyHint)
            } else {
                HStack(alignment: .top, spacing: Mixer.spacing) { content }
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

struct ZoneTitle: View {
    let text: String
    let arrow: String

    var body: some View {
        HStack(spacing: 10) {
            Text(text.uppercased())
                .font(.system(size: 15, weight: .bold))
                .tracking(0.5)
                .foregroundColor(.primary.opacity(0.75))
            // A plain arrow, not a box: it shows the direction sound flows, it isn't a button.
            Image(systemName: arrow)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.secondary)
        }
    }
}

struct EmptyZoneHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 260, alignment: .leading)
    }
}

struct AddSlotButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .background(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundColor(.secondary.opacity(0.5)))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(enabled ? title : "Up to 8")
    }
}

// MARK: - Strips

struct InputStrip: View {
    @EnvironmentObject var model: RouterModel
    @Binding var slot: SlotConfig
    let lowerHeight: CGFloat

    var body: some View {
        let index = model.index(of: slot.id, isInput: true) ?? 0
        VStack(spacing: Mixer.gap) {
            StripHeader(slot: $slot, isInput: true)
            StripSection(label: "Source", height: Mixer.sourceHeight) {
                SourcePickers(slot: $slot, isInput: true)
            }
            StripSection(label: "Effects", height: Mixer.effectsHeight) {
                // In signal order.
                VStack(spacing: 5) {
                    FXButton(effect: .lowCut, isOn: $slot.lowCut, index: index)
                    FXButton(effect: .compressor, isOn: $slot.compressor, index: index)
                    FXButton(effect: .limiter, isOn: $slot.limiter, index: index)
                }
                .frame(maxWidth: .infinity)
            }
            FaderMeter(db: $slot.gainDB, meter: .input(index), channels: slot.width)
            DBReadout(db: $slot.gainDB)
            MuteButton(muted: $slot.muted)
            StripSection(label: "Send", height: lowerHeight) {
                if model.config.outputs.isEmpty {
                    Text("No outputs yet").font(.caption).foregroundColor(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(model.config.outputs) { output in
                            SendRow(input: slot, output: output)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .stripCard()
    }
}

struct OutputStrip: View {
    @EnvironmentObject var model: RouterModel
    @Binding var slot: SlotConfig
    let lowerHeight: CGFloat

    var body: some View {
        let index = model.index(of: slot.id, isInput: false) ?? 0
        VStack(spacing: Mixer.gap) {
            StripHeader(slot: $slot, isInput: false)
            StripSection(label: "Source", height: Mixer.sourceHeight) {
                BusPill(slot: $slot).frame(maxWidth: .infinity)
            }
            // Outputs have no effects; the space keeps every fader level.
            Color.clear.frame(height: Mixer.effectsHeight)
            FaderMeter(db: $slot.gainDB, meter: .output(index), channels: slot.width)
            DBReadout(db: $slot.gainDB)
            MuteButton(muted: $slot.muted)
            StripSection(label: "Output", height: lowerHeight) {
                SourcePickers(slot: $slot, isInput: false)
            }
        }
        .stripCard()
    }
}

extension View {
    func stripCard() -> some View {
        padding(10)
            .frame(width: Mixer.stripWidth, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
    }
}

struct StripSection<Content: View>: View {
    let label: String
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height, alignment: .top)
    }
}

struct StripHeader: View {
    @EnvironmentObject var model: RouterModel
    @Binding var slot: SlotConfig
    let isInput: Bool

    var body: some View {
        let health = model.health(slot, isInput: isInput)
        HStack(spacing: 6) {
            Circle().fill(health.color).frame(width: 8, height: 8).help(health.help)
            TextField("Name", text: $slot.name)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
            Menu {
                Button("Move left") { model.move(slot.id, isInput: isInput, by: -1) }
                Button("Move right") { model.move(slot.id, isInput: isInput, by: 1) }
                Divider()
                Button("Remove \(slot.name)") { model.remove(slot.id, isInput: isInput) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .frame(height: 20)
    }
}

struct SourcePickers: View {
    @EnvironmentObject var model: RouterModel
    @Binding var slot: SlotConfig
    let isInput: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Device", selection: deviceBinding) {
                Text("— None —").tag(String?.none)
                if let uid = slot.deviceUID, model.device(uid) == nil {
                    Text("\(slot.deviceName ?? "Unknown") (not connected)").tag(Optional(uid))
                }
                ForEach(isInput ? model.inputDevices : model.outputDevices) { d in
                    Text(d.name).tag(Optional(d.uid))
                }
            }
            .labelsHidden()

            Picker("Channels", selection: channelBinding) {
                ForEach(channelChoices, id: \.code) { choice in
                    Text(choice.label).tag(choice.code)
                }
            }
            .labelsHidden()
            .disabled(slot.deviceUID == nil)
        }
    }

    private var deviceBinding: Binding<String?> {
        Binding(
            get: { slot.deviceUID },
            set: { uid in
                guard uid != slot.deviceUID else { return }
                let d = model.device(uid)
                let channels = (isInput ? d?.inputChannels : d?.outputChannels) ?? 2
                slot.deviceUID = uid
                slot.deviceName = d?.name ?? slot.deviceName
                slot.firstChannel = 0
                slot.stereo = slot.stereo && channels >= 2
            }
        )
    }

    private struct ChannelChoice {
        var first: Int
        var stereo: Bool
        var code: Int { first * 2 + (stereo ? 1 : 0) }
        var label: String { stereo ? "Ch \(first + 1)+\(first + 2) stereo" : "Ch \(first + 1) mono" }
    }

    private var channelChoices: [ChannelChoice] {
        let d = model.device(slot.deviceUID)
        let count = (isInput ? d?.inputChannels : d?.outputChannels) ?? 0
        var choices: [ChannelChoice] = []
        if count >= 2 {
            for first in stride(from: 0, to: count - 1, by: 2) { choices.append(ChannelChoice(first: first, stereo: true)) }
        }
        for first in 0..<count { choices.append(ChannelChoice(first: first, stereo: false)) }
        let current = ChannelChoice(first: slot.firstChannel, stereo: slot.stereo)
        if !choices.contains(where: { $0.code == current.code }) { choices.insert(current, at: 0) }
        return choices
    }

    private var channelBinding: Binding<Int> {
        Binding(
            get: { slot.firstChannel * 2 + (slot.stereo ? 1 : 0) },
            set: { code in
                slot.firstChannel = code / 2
                slot.stereo = code % 2 == 1
            }
        )
    }
}

// MARK: - Sends

/// One send on an input: on/off, and a knob for how much.
struct SendRow: View {
    @EnvironmentObject var model: RouterModel
    let input: SlotConfig
    let output: SlotConfig

    var body: some View {
        let binding = model.routeBinding(input.id, output.id)
        let feedback = model.isFeedback(input, output)
        let on = binding.wrappedValue.on && !feedback

        HStack(spacing: 6) {
            Button {
                binding.wrappedValue.on.toggle()
            } label: {
                HStack(spacing: 5) {
                    if feedback {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                    } else {
                        Circle().fill(on ? Color.green : Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
                    }
                    Text(output.busName).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 8)
                .frame(width: Mixer.pillWidth, height: Mixer.control)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
                .foregroundColor(on ? .primary : .secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(feedback)
            .help(feedback ? "Blocked: \(input.name) is on the same loopback as \(output.name), so it would feed back on itself."
                  : on ? "Sending \(input.name) to \(output.name). Click to stop."
                  : "Send \(input.name) to \(output.name)")

            Knob(db: binding.gainDB, active: on)
                .help("Send level to \(output.name): \(dbText(binding.wrappedValue.gainDB)). Drag up or down; double-click for 0 dB.")
        }
    }
}

/// On an output strip: the send that feeds it. Lit when any input is sending here.
struct BusPill: View {
    @EnvironmentObject var model: RouterModel
    @Binding var slot: SlotConfig
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        let feeders = model.config.inputs.filter { input in
            model.config.route(input.id, slot.id).on && !model.isFeedback(input, slot)
        }
        let fed = !feeders.isEmpty

        Group {
            if editing {
                TextField("Send name", text: $slot.sendName)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { editing = false }
                    .onChange(of: focused) { if !$0 { editing = false } }
                    .onAppear { focused = true }
            } else {
                HStack(spacing: 5) {
                    Circle().fill(fed ? Color.green : Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
                    Text(slot.busName).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 10)
        .frame(width: Mixer.pillWidth + 12, height: Mixer.control)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(fed ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
        .foregroundColor(fed ? .primary : .secondary)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if slot.sendName.isEmpty { slot.sendName = slot.busName }
            editing = true
        }
        .help(fed
              ? "Fed by \(feeders.map(\.name).joined(separator: ", ")). Double-click to rename this send."
              : "Nothing is sent here yet: turn on “\(slot.busName)” under SEND on an input. Double-click to rename.")
    }
}

// MARK: - Controls

struct FaderMeter: View {
    @Binding var db: Double
    let meter: MeterSource
    let channels: Int

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Fader(db: $db)
            VMeter(source: meter, channels: channels)
                .padding(.vertical, Fader.knob / 2)
        }
        .frame(height: Mixer.faderHeight)
        .frame(maxWidth: .infinity)
    }
}

struct Fader: View {
    @Binding var db: Double
    @State private var dragStart: Double?
    static let knob: CGFloat = 18

    // Travel against dB: most of the throw is spent where levels are set.
    private static let taper: [(db: Double, pos: Double)] = [
        (-60, 0), (-40, 0.1), (-20, 0.3), (-10, 0.5), (0, 0.75), (12, 1),
    ]

    static func position(_ db: Double) -> Double {
        guard db > taper[0].db else { return 0 }
        for k in 1..<taper.count where db <= taper[k].db {
            let a = taper[k - 1], b = taper[k]
            return a.pos + (db - a.db) / (b.db - a.db) * (b.pos - a.pos)
        }
        return 1
    }

    static func db(at pos: Double) -> Double {
        guard pos > 0 else { return taper[0].db }
        for k in 1..<taper.count where pos <= taper[k].pos {
            let a = taper[k - 1], b = taper[k]
            return a.db + (pos - a.pos) / (b.pos - a.pos) * (b.db - a.db)
        }
        return taper[taper.count - 1].db
    }

    /// Shared by the fader and the send knobs: relative drag, a detent at 0 dB, 0.1 dB steps.
    static func dragged(from start: Double, by delta: Double) -> Double {
        let p = min(max(start + delta, 0), 1)
        let value = db(at: p)
        return abs(value) < 0.4 ? 0 : (value * 10).rounded() / 10
    }

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.height - Self.knob, 1)
            let pos = Self.position(db)
            let knobTop = travel * (1 - pos)
            ZStack(alignment: .top) {
                Capsule().fill(Color.primary.opacity(0.12))
                    .frame(width: 4, height: travel)
                    .offset(y: Self.knob / 2)
                Capsule().fill(Color.accentColor)
                    .frame(width: 4, height: travel * pos)
                    .offset(y: knobTop + Self.knob / 2)
                Rectangle().fill(Color.primary.opacity(0.45)) // 0 dB mark
                    .frame(width: 12, height: 1)
                    .offset(y: travel * (1 - Self.position(0)) + Self.knob / 2)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.15)))
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .frame(width: Self.knob, height: Self.knob)
                    .offset(y: knobTop)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                // Relative, like a real fader: grabbing it never makes it jump.
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? pos
                        dragStart = start
                        db = Self.dragged(from: start, by: -Double(value.translation.height / travel))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { db = 0 }
        }
        .frame(width: 20)
        .contextMenu { QuickGainMenu(db: $db) }
        .help("Drag to set the level. Double-click for 0 dB; right-click for presets.")
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue(dbText(db))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: db = min(12, db + 1)
            case .decrement: db = max(-60, db - 1)
            @unknown default: break
            }
        }
    }
}

/// A send-level knob: the arc runs from −∞ at 7 o'clock to +12 dB at 5 o'clock.
struct Knob: View {
    @Binding var db: Double
    let active: Bool
    @State private var dragStart: Double?

    var body: some View {
        let pos = Fader.position(db)
        let stroke = StrokeStyle(lineWidth: 3, lineCap: .round)
        ZStack {
            Circle()
                .trim(from: 0.125, to: 0.875)
                .stroke(Color.primary.opacity(0.15), style: stroke)
            Circle()
                .trim(from: 0.125, to: 0.125 + 0.75 * pos)
                .stroke(active ? Color.accentColor : Color.secondary.opacity(0.5), style: stroke)
        }
        .rotationEffect(.degrees(90))
        .overlay(
            Capsule()
                .fill(Color.primary.opacity(active ? 0.75 : 0.4))
                .frame(width: 2, height: 6)
                .offset(y: -4)
                .rotationEffect(.degrees(-135 + 270 * pos))
        )
        .padding(2)
        .frame(width: Mixer.knobSize, height: Mixer.knobSize)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = dragStart ?? pos
                    dragStart = start
                    db = Fader.dragged(from: start, by: -Double(value.translation.height) / 120)
                }
                .onEnded { _ in dragStart = nil }
        )
        .onTapGesture(count: 2) { db = 0 }
        .contextMenu { QuickGainMenu(db: $db) }
        .accessibilityElement()
        .accessibilityLabel("Send level")
        .accessibilityValue(dbText(db))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: db = min(12, db + 1)
            case .decrement: db = max(-60, db - 1)
            @unknown default: break
            }
        }
    }
}

struct QuickGainMenu: View {
    @Binding var db: Double

    var body: some View {
        Button("Set to +5 dB") { db = 5 }
        Button("Set to 0 dB") { db = 0 }
        Button("Set to −5 dB") { db = -5 }
    }
}

/// The level, as a number you can click and type into.
struct DBReadout: View {
    @Binding var db: Double
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("dB", text: $text)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false } // Esc: leave it as it was
                    .onChange(of: focused) { if !$0 && editing { commit() } }
                    .onAppear { focused = true }
            } else {
                Text(dbText(db))
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .frame(width: 60, height: 20)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(editing ? Color(nsColor: .textBackgroundColor) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .strokeBorder(editing ? Color.accentColor : Color.primary.opacity(0.25), lineWidth: editing ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !editing else { return }
            text = db <= -59.9 ? "-inf" : String(format: "%+.1f", db)
            editing = true
        }
        .contextMenu { QuickGainMenu(db: $db) }
        .help("Click to type a level in dB (−60 to +12, or −inf). Right-click for +5 / 0 / −5 dB.")
    }

    private func commit() {
        if let value = Self.parse(text) { db = value }
        editing = false
    }

    /// Accepts "3", "+3", "-6.5", "−6,5 dB", "-inf". Anything else leaves the level alone.
    static func parse(_ input: String) -> Double? {
        var t = input.lowercased()
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "db", with: "")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        if ["-inf", "-∞", "inf", "∞", "off"].contains(t) { return -60 }
        if t.hasPrefix("+") { t.removeFirst() }
        guard let value = Double(t), value.isFinite else { return nil }
        return min(max((value * 10).rounded() / 10, -60), 12)
    }
}

enum MeterSource {
    case input(Int)
    case output(Int)
}

struct VMeter: View {
    @EnvironmentObject var meters: MeterStore
    let source: MeterSource
    let channels: Int

    var body: some View {
        let levels: [Float] = {
            switch source {
            case .input(let i): return meters.input(i)
            case .output(let o): return meters.output(o)
            }
        }()
        HStack(spacing: 2) {
            ForEach(0..<max(channels, 1), id: \.self) { c in
                VMeterBar(level: c < levels.count ? levels[c] : 0)
            }
        }
    }
}

struct VMeterBar: View {
    let level: Float

    private static let gradient = LinearGradient(
        gradient: Gradient(stops: [
            .init(color: .green, location: 0),
            .init(color: .green, location: 0.7),
            .init(color: .yellow, location: 0.87),
            .init(color: .red, location: 1),
        ]),
        startPoint: .bottom, endPoint: .top)

    var body: some View {
        GeometryReader { geo in
            let db = level > 0 ? 20 * log10(level) : -100
            let fraction = CGFloat(max(0, min(1, (db + 60) / 60)))
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Self.gradient)
                    .mask(alignment: .bottom) { Rectangle().frame(height: geo.size.height * fraction) }
            }
        }
        .frame(width: 4)
    }
}

enum InputEffect {
    case limiter, compressor, lowCut

    var title: String {
        switch self {
        case .limiter: return "Limiter"
        case .compressor: return "Compressor"
        case .lowCut: return "Low-cut"
        }
    }

    var help: String {
        switch self {
        case .limiter:
            return "Safety limiter. Nothing from this input goes above −1 dBFS. It stays out of the way until a peak would overload. The light turns orange while it's catching one."
        case .compressor:
            return "Gentle leveller (2:1 above −24 dBFS, soft knee, +2 dB make-up). Shouts come down a little, whispers come up a little. The light turns yellow while it's working."
        case .lowCut:
            return "Removes rumble below 80 Hz (12 dB/octave), the standard mixing-desk low-cut."
        }
    }

    var workingColor: Color {
        switch self {
        case .limiter: return .orange
        case .compressor: return .yellow
        case .lowCut: return .green
        }
    }
}

struct FXButton: View {
    @EnvironmentObject var meters: MeterStore
    let effect: InputEffect
    @Binding var isOn: Bool
    let index: Int

    var body: some View {
        let working = isOn && meters.reduction(index, effect) > 0.5
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(!isOn ? Color.secondary.opacity(0.3) : working ? effect.workingColor : Color.green)
                    .frame(width: 6, height: 6)
                Text(effect.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(width: 112, height: Mixer.control)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(isOn ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06)))
            .foregroundColor(isOn ? .primary : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOn ? effect.help : "\(effect.title) is off. \(effect.help)")
    }
}

struct MuteButton: View {
    @Binding var muted: Bool

    var body: some View {
        Button {
            muted.toggle()
        } label: {
            Text("M")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 20)
                .background(RoundedRectangle(cornerRadius: 4).fill(muted ? Color.red : Color.primary.opacity(0.1)))
                .foregroundColor(muted ? .white : .primary)
        }
        .buttonStyle(.plain)
        .help(muted ? "Unmute" : "Mute")
    }
}
