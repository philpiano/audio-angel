import AppKit
import AVFoundation
import SwiftUI

/// The main window: status bar and the mixer (Mixer.swift).
struct ContentView: View {
    @EnvironmentObject var model: RouterModel
    @State private var window: NSWindow?
    @State private var barHeight: CGFloat?
    @State private var mixerHeight: CGFloat?
    @State private var fitted = false

    var body: some View {
        VStack(spacing: 0) {
            StatusBar()
                .background(GeometryReader { g in Color.clear.preference(key: BarHeightKey.self, value: g.size.height) })
            Divider()
            // Vertical around horizontal, not one two-axis ScrollView: on macOS 13 a
            // two-axis ScrollView opens scrolled to the middle, hiding the top.
            GeometryReader { viewport in
                ScrollView(.vertical) {
                    ScrollView(.horizontal) {
                        MixerView()
                            .padding(20)
                            .background(GeometryReader { g in Color.clear.preference(key: MixerHeightKey.self, value: g.size.height) })
                            .frame(minWidth: viewport.size.width, alignment: .topLeading)
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(WindowReader { window = $0; fitWindow() })
        .onPreferenceChange(BarHeightKey.self) { barHeight = $0; fitWindow() }
        .onPreferenceChange(MixerHeightKey.self) { mixerHeight = $0; fitWindow() }
    }

    /// Every time the window opens it sizes itself to the desk: six strips wide
    /// and exactly as tall as the strips. Resizing afterwards is up to you.
    private func fitWindow() {
        guard !fitted, let window, let barHeight, let mixerHeight, mixerHeight > 0 else { return }
        fitted = true
        let wanted = NSSize(width: Mixer.standardWidth(outputs: model.config.outputs.count),
                            height: barHeight + 1 + mixerHeight + 32) // a little air under the strips
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let content = NSSize(width: min(wanted.width, visible.width), height: min(wanted.height, visible.height - 40))
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        // Keep the top-left corner where it was; slide back on screen if that overflows.
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true)
    }
}

private struct BarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct MixerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Hands over the NSWindow a SwiftUI view ends up in.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { self.onWindow?(window) }
        }
    }
}

struct LogoMark: View {
    var size: CGFloat
    private static let image = NSImage(named: "Logo")

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "waveform.circle.fill")
                .resizable()
                .foregroundColor(.orange)
                .frame(width: size, height: size)
        }
    }
}

extension RouterModel {
    var missingLoopbacks: [String] {
        ["2ch", "16ch", "64ch"].filter { size in
            !devices.contains { $0.name.localizedCaseInsensitiveContains("blackhole \(size)") }
        }
    }

    /// Something in the setup checklist needs attention.
    var needsSetup: Bool { !missingLoopbacks.isEmpty || micPermission != .authorized }
}

// MARK: - Status bar

struct StatusBar: View {
    @EnvironmentObject var model: RouterModel
    @EnvironmentObject var meters: MeterStore

    var body: some View {
        let s = model.status
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(Self.color(s.state)).frame(width: 9, height: 9)
                Text(s.state == .running ? "Running" : s.state.rawValue.capitalized).fontWeight(.semibold)
            }
            Text(s.message).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
            if !s.warnings.isEmpty {
                StatusListButton(kind: .warning, items: s.warnings)
            }
            if !s.notes.isEmpty {
                StatusListButton(kind: .note, items: s.notes)
            }
            Spacer(minLength: 8)
            health
            SettingsButton()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var health: some View {
        let s = model.status
        return HStack(spacing: 14) {
            if s.state == .running {
                Text(String(format: "≈ %.1f ms", s.inputLatencyMs + s.outputLatencyMs))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .help(String(format: "Delay through Audio Angel: input %.1f ms + output %.1f ms.\nZoom adds its own delay on top.", s.inputLatencyMs, s.outputLatencyMs))
            }
            if model.overloads > 0 {
                CounterBadge(icon: "bolt.trianglebadge.exclamationmark", title: "Dropouts", count: model.overloads,
                             color: .orange,
                             help: "Dropouts: times the Mac couldn't prepare the audio in time, so a tiny gap (a click) got through. An odd one is harmless. If it keeps climbing while you play, raise the buffer size in Settings.") {
                    model.resetOverloads()
                }
            }
            if meters.clips > 0 {
                CounterBadge(icon: "waveform.badge.exclamationmark", title: "Clipped", count: Int(clamping: meters.clips),
                             color: .red,
                             help: "Clipped: times an output went over full scale and the final safety stage had to catch it. Usually two loud sources adding up in one output. If it keeps climbing, turn that output, or what's sent to it, down a few dB.") {
                    model.meters.resetClips()
                }
            }
            Button {
                model.resetOverloads()
                model.meters.resetClips()
                model.engine.restart()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Restart the audio engine and clear the counters")
        }
    }

    static func color(_ state: EngineStatus.State) -> Color {
        switch state {
        case .running: return .green
        case .starting, .waiting: return .orange
        case .error: return .red
        case .stopped: return .gray
        }
    }
}

/// A named count of something that went wrong since it was last cleared. Click to clear.
struct CounterBadge: View {
    let icon: String
    let title: String
    let count: Int
    let color: Color
    let help: String
    let reset: () -> Void

    var body: some View {
        Button(action: reset) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text("\(title) \(count)").monospacedDigit()
            }
            .foregroundColor(color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(help)\n\nClick to reset.")
    }
}

/// The engine's warnings (⚠, needs you) or notes (ⓘ, needs nothing), readable with a click.
struct StatusListButton: View {
    enum Kind { case warning, note }

    let kind: Kind
    let items: [String]
    @State private var showing = false

    var body: some View {
        let warning = kind == .warning
        Button {
            showing.toggle()
        } label: {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundColor(warning ? .orange : .secondary)
        }
        .buttonStyle(.plain)
        .help(items.joined(separator: "\n"))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(warning ? "Needs attention" : "Good to know").font(.headline)
                ForEach(items, id: \.self) { item in
                    Label(item, systemImage: warning ? "exclamationmark.triangle" : "info.circle")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(warning
                     ? "Everything else keeps running. These clear by themselves once the cause is fixed."
                     : "Just so you know. Nothing here needs doing.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
        }
    }
}

struct SettingsButton: View {
    @EnvironmentObject var model: RouterModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: "settings")
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 15))
                .overlay(alignment: .topTrailing) {
                    if model.needsSetup {
                        Circle().fill(Color.orange).frame(width: 7, height: 7).offset(x: 3, y: -3)
                    }
                }
        }
        .keyboardShortcut(",", modifiers: .command)
        .help(model.needsSetup ? "Settings (⌘,). Something in the setup checklist needs attention." : "Settings (⌘,)")
    }
}

// MARK: - Settings window

struct SettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    LogoMark(size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Audio Angel").font(.title2.weight(.bold))
                        Text("Settings").foregroundColor(.secondary)
                    }
                }
                GroupBox {
                    EngineSettings().padding(8)
                } label: {
                    Text("Audio engine").font(.headline)
                }
                GroupBox {
                    SetupChecklist().padding(8)
                } label: {
                    Text("Setup checklist").font(.headline)
                }
            }
            .padding(20)
        }
        .frame(width: 600, height: 680)
    }
}

struct EngineSettings: View {
    @EnvironmentObject var model: RouterModel

    var body: some View {
        let s = model.status
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Sample rate").gridColumnAlignment(.trailing)
                    Picker("Sample rate", selection: $model.config.sampleRate) {
                        Text("44.1 kHz").tag(44100.0)
                        Text("48 kHz").tag(48000.0)
                        Text("88.2 kHz").tag(88200.0)
                        Text("96 kHz").tag(96000.0)
                    }
                    .labelsHidden()
                    .fixedSize()
                    hint("48 kHz matches Zoom and avoids extra conversion.")
                }
                GridRow {
                    Text("Buffer size")
                    Picker("Buffer size", selection: $model.config.bufferFrames) {
                        ForEach([32, 64, 128, 256, 512, 1024], id: \.self) { Text("\($0) samples").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    hint("Smaller means less delay. Raise it if you hear crackles.")
                }
                GridRow {
                    Text("Clock")
                    Picker("Clock", selection: $model.config.clockDeviceUID) {
                        Text("Auto").tag(String?.none)
                        ForEach(model.devices.filter { d in (model.config.inputs + model.config.outputs).contains { $0.deviceUID == d.uid } }) { d in
                            Text(d.name).tag(Optional(d.uid))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    hint("The device every other device keeps time with. Auto picks your interface.")
                }
            }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(StatusBar.color(s.state)).frame(width: 8, height: 8)
                Text(s.state == .running
                     ? String(format: "Running at %d Hz, %d samples, ≈ %.1f ms through the router. Clock: %@.",
                              Int(s.sampleRate), s.bufferFrames, s.inputLatencyMs + s.outputLatencyMs, s.clockDeviceName)
                     : s.message)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Restart audio engine") { model.engine.restart() }
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SetupChecklist: View {
    @EnvironmentObject var model: RouterModel
    @State private var copied = false

    private static let brewCommand = "brew install blackhole-2ch blackhole-16ch blackhole-64ch"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            loopbacks
            Divider()
            macSound
            Divider()
            zoom
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loopbacks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("1 · Loopback devices and microphone access").fontWeight(.semibold)
            HStack(spacing: 16) {
                ForEach(["2ch", "16ch", "64ch"], id: \.self) { size in
                    let found = !model.missingLoopbacks.contains(size)
                    Label("BlackHole \(size)", systemImage: found ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(found ? .green : .secondary)
                }
            }
            if !model.missingLoopbacks.isEmpty {
                Text("Install with Homebrew, then log out and back in:").foregroundColor(.secondary)
                HStack {
                    Text(Self.brewCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.brewCommand, forType: .string)
                        copied = true
                    }
                    .controlSize(.small)
                }
            }
            micPermissionRow
        }
    }

    @ViewBuilder
    private var micPermissionRow: some View {
        switch model.micPermission {
        case .authorized:
            Label("Microphone access allowed", systemImage: "checkmark.circle.fill").foregroundColor(.green)
        case .notDetermined:
            Label("Microphone access: waiting for your answer", systemImage: "questionmark.circle").foregroundColor(.orange)
        default:
            HStack {
                Label("Microphone access is off, so inputs will be silent", systemImage: "xmark.octagon.fill").foregroundColor(.red)
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
                .controlSize(.small)
            }
        }
    }

    private var macSound: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("2 · Mac & browser sound").fontWeight(.semibold)
            let current = model.device(model.defaultOutputUID)?.name ?? "unknown"
            HStack {
                Text("Mac output is **\(current)**.")
                Spacer()
                Menu("Send Mac sound to…") {
                    ForEach(model.outputDevices) { d in
                        Button(d.name) { model.setSystemOutput(d.uid) }
                    }
                }
                .fixedSize()
            }
            Text("For browser music to reach Audio Angel, the Mac's output should be the loopback your “Mac / Browser” input listens to (BlackHole 64ch by default).")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var zoom: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("3 · Zoom › Settings › Audio").fontWeight(.semibold)
            Text("• **Microphone:** BlackHole 2ch (the output you send to Zoom)")
            Text("• **Speaker:** BlackHole 16ch (your “Zoom” input)")
            Text("• Turn on **Original sound for musicians**, and switch it on in the meeting (top-left).")
            Text("• Untick **Automatically adjust microphone volume**.")
            Text("• Never send the “Zoom” input to the output that goes to Zoom: the other side would hear themselves.")
                .foregroundColor(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
