import AppKit
import CoreAudio
import Foundation
import RouterCore
import SwiftUI

/// Headless checks, run from Terminal:
///
///   AudioAngel --list-devices   every device, its UID, channels and rate
///   AudioAngel --probe          builds a real aggregate on the built-in speakers
///                               (silent, output-only, no microphone prompt), runs
///                               the engine, rebuilds it at a new buffer size, and
///                               reports whether audio callbacks flowed.
///   AudioAngel --snapshot FILE           the main window, drawn offscreen to a PNG
///                                        (add --demo for the status bar of a running rig)
///   AudioAngel --snapshot-settings FILE  the Settings window, likewise
enum Diagnostics {
    static func run(_ args: [String]) -> Int32? {
        setlinebuf(stdout) // show progress live even when piped
        if args.contains("--list-devices") { listDevices(); return 0 }
        if args.contains("--probe") { return probe() }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            return snapshot(to: args[i + 1], demo: args.contains("--demo"))
        }
        if let i = args.firstIndex(of: "--snapshot-settings"), i + 1 < args.count {
            return snapshot(to: args[i + 1], settings: true)
        }
        return nil
    }

    /// Renders the main window offscreen to a PNG. No audio, no permission prompts.
    static func snapshot(to path: String, settings: Bool = false, demo: Bool = false) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // no Dock icon
        let model = RouterModel(live: false)
        if demo {
            // How the status bar read on the author's rig. Nothing is started.
            model.showForScreenshot(EngineStatus(
                state: .running, message: "Routing 5 devices",
                sampleRate: 48000, bufferFrames: 128, inputLatencyMs: 6.1, outputLatencyMs: 6.8,
                notes: ["Digital Piano only runs at 44.1 kHz, so macOS converts it to 48 kHz on the way in. Nothing to fix."]))
        }
        let root = Group {
            if settings { SettingsView() } else { ContentView() }
        }
        .environmentObject(model)
        .environmentObject(model.meters)
        let hosting = NSHostingView(rootView: root)
        let size = settings ? NSSize(width: 600, height: 680) : NSSize(width: 1060, height: 700)
        // Borderless so it can sit far off-screen without being pulled back on.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        // A real window-server capture composites transparency and symbols exactly as
        // on screen; cacheDisplay doesn't. Capturing our own window needs no permission.
        var rep: NSBitmapImageRep?
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                               [.bestResolution, .boundsIgnoreFraming]) {
            rep = NSBitmapImageRep(cgImage: image)
        } else if let cached = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: cached)
            rep = cached
        }
        window.orderOut(nil)
        guard let rep, let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil else { return 1 }
        print("Wrote \(path)")
        return 0
    }

    static func listDevices() {
        let devices = AudioDeviceInfo.all()
        let defaultOut = CA.defaultOutputDevice().flatMap(CA.uid(of:))
        print("\(devices.count) devices\n")
        for d in devices {
            let mark = d.uid == defaultOut ? "  ← Mac output" : ""
            print("\(d.name)\(mark)")
            print("    in \(d.inputChannels)  out \(d.outputChannels)  \(Int(d.sampleRate)) Hz  \(d.transportName)")
            print("    uid \(d.uid)")
        }
    }

    static func probe() -> Int32 {
        let devices = AudioDeviceInfo.all()
        guard let speakers = devices.first(where: { $0.isBuiltIn && $0.outputChannels >= 2 && $0.inputChannels == 0 })
            ?? devices.first(where: { $0.outputChannels >= 2 && $0.inputChannels == 0 }) else {
            print("No output-only device to probe with.")
            return 1
        }
        print("Probing with \(speakers.name) (silent)…")

        let engine = EngineController()
        var latest = EngineStatus()
        var rebuilds = 0
        engine.onStatus = { status in
            if status.state == .starting { rebuilds += 1 }
            latest = status
            print("  [\(status.state.rawValue)] \(status.message)")
        }

        var config = RouterConfig()
        config.outputs = [SlotConfig(name: "Speakers", deviceUID: speakers.uid, deviceName: speakers.name, stereo: true)]
        config.bufferFrames = 128
        engine.update(config: config)
        engine.start()

        func waitForRunning(_ timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                if latest.state == .running { return true }
            }
            return false
        }

        func measure(_ seconds: TimeInterval) -> Double {
            let before = ar_engine_callback_count(engine.core)
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            return Double(ar_engine_callback_count(engine.core) - before) / seconds
        }

        var ok = true
        if waitForRunning(6) {
            let rate = measure(1.5)
            let expected = latest.sampleRate / Double(max(latest.bufferFrames, 1))
            print(String(format: "  %.0f callbacks/s at %d frames, %.0f Hz (expected ≈ %.0f); latency ≈ %.1f ms out",
                         rate, latest.bufferFrames, latest.sampleRate, expected, latest.outputLatencyMs))
            if rate < expected * 0.8 { print("  FAIL: callbacks are not keeping up"); ok = false }
        } else {
            print("  FAIL: engine did not reach running")
            ok = false
        }

        print("Rebuilding at 256 frames…")
        config.bufferFrames = 256
        latest.state = .starting
        engine.update(config: config)
        if waitForRunning(6), latest.bufferFrames == 256 {
            let rate = measure(1.0)
            print(String(format: "  %.0f callbacks/s at %d frames", rate, latest.bufferFrames))
            if rate < latest.sampleRate / 256 * 0.8 { ok = false }
        } else {
            print("  FAIL: rebuild did not come back at 256 frames (got \(latest.bufferFrames))")
            ok = false
        }

        let rebuildsBefore = rebuilds
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        if rebuilds != rebuildsBefore { print("  FAIL: engine kept rebuilding while idle"); ok = false }

        engine.shutdown()
        // The HAL publishes the device list asynchronously; give it a moment.
        var leftovers: [String] = []
        let deadline = Date().addingTimeInterval(2)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            leftovers = CA.deviceIDs().compactMap(CA.uid(of:)).filter { $0.hasPrefix(EngineController.aggregateUIDPrefix) }
        } while !leftovers.isEmpty && Date() < deadline
        if !leftovers.isEmpty { print("  FAIL: aggregate device left behind"); ok = false }
        print(ok ? "Probe passed." : "Probe FAILED.")
        return ok ? 0 : 1
    }
}
