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
///   AudioAngel --probe --log DIR  the same, recording a diagnostic log in DIR; it also
///                               changes the speakers' sample rate behind the engine's
///                               back (then restores it) and checks the log explains
///                               the restart that follows
///   AudioAngel --snapshot FILE           the main window, drawn offscreen to a PNG
///                                        (add --demo for the status bar of a running rig)
///   AudioAngel --snapshot-settings FILE  the Settings window, likewise
enum Diagnostics {
    static func run(_ args: [String]) -> Int32? {
        setlinebuf(stdout) // show progress live even when piped
        if args.contains("--list-devices") { listDevices(); return 0 }
        if args.contains("--probe") {
            let i = args.firstIndex(of: "--log")
            return probe(logDir: i.flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil })
        }
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

    /// Reads a probe's log back and checks it tells the story of each restart.
    static func checkLog(_ file: URL) -> Bool {
        guard let text = try? String(contentsOf: file) else { print("  FAIL: log unreadable"); return false }
        var events: [[String: Any]] = []
        for (n, line) in text.split(separator: "\n").enumerated() {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                print("  FAIL: log line \(n + 1) is not valid JSON")
                return false
            }
            events.append(obj)
        }
        func named(_ ev: String) -> [[String: Any]] { events.filter { $0["ev"] as? String == ev } }
        var ok = true
        func expect(_ condition: Bool, _ what: String) {
            print("  \(condition ? "ok  " : "FAIL") log: \(what)")
            if !condition { ok = false }
        }
        expect(!named("session_start").isEmpty, "session recorded")
        expect(!named("heartbeat").isEmpty, "heartbeats recorded (\(named("heartbeat").count))")
        let resumed = named("audio_resumed")
        expect(!resumed.isEmpty, "every restart logs when sound came back")
        for r in resumed {
            print(String(format: "        silent %.1f ms, because: %@", r["silence_ms"] as? Double ?? -1, r["stopped_because"] as? String ?? "?"))
        }
        expect(resumed.allSatisfy { ($0["silence_ms"] as? Double ?? -1) >= 0 }, "each silence has a measured duration")
        let rateEvents = named("sample_rate_changed").filter { ($0["action"] as? String ?? "").hasPrefix("rebuild") }
        if !rateEvents.isEmpty {
            expect(resumed.contains { ($0["stopped_because"] as? String ?? "").contains("sample rate") },
                   "the rate-change restart is attributed to the sample rate")
        }
        expect(named("hal_property").contains { $0["property"] as? String == "NominalSampleRate" } || rateEvents.isEmpty,
               "the raw Core Audio notification is recorded too")
        return ok
    }

    static func probe(logDir: String? = nil) -> Int32 {
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

        var heartbeat: DiagnosticHeartbeat?
        if let logDir {
            DiagnosticLog.shared.start(directory: URL(fileURLWithPath: logDir, isDirectory: true))
            DiagnosticLog.shared.event("session_start", DiagnosticInfo.session().merging(["probe": true], uniquingKeysWith: { a, _ in a }))
            DiagnosticLog.shared.event("config", DiagnosticInfo.config(config))
            heartbeat = DiagnosticHeartbeat(engine: engine, model: nil)
            heartbeat?.start()
        }

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

        // With a log: provoke a real restart from outside the app and check the log
        // explains it: what triggered it, and how long the sound was silent.
        let originalRate = CA.nominalRate(speakers.objectID)
        if logDir != nil, let original = originalRate {
            let other = [44100.0, 48000.0, 96000.0].first { abs($0 - original) > 0.5 && CA.supportsRate(speakers.objectID, $0) }
            if let other {
                print("Changing \(speakers.name) to \(Int(other)) Hz behind the engine's back…")
                latest.state = .starting
                CA.setNominalRate(speakers.objectID, other)
                if waitForRunning(8) {
                    RunLoop.main.run(until: Date().addingTimeInterval(1.5))
                } else {
                    print("  FAIL: engine didn't come back after the rate change")
                    ok = false
                }
            }
        }

        heartbeat?.stop()
        engine.shutdown()
        if let original = originalRate { CA.setNominalRate(speakers.objectID, original) }

        if let logDir, let file = DiagnosticLog.shared.fileURL {
            DiagnosticLog.shared.stop()
            ok = checkLog(file) && ok
            print("  log: \(logDir)/\(file.lastPathComponent)")
        }
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
