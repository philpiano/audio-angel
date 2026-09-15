import AppKit
import SwiftUI

@main
struct AudioAngelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RouterModel()

    init() {
        // Command-line diagnostics run instead of the app (see Diagnostics.swift).
        if let code = Diagnostics.run(CommandLine.arguments) { exit(code) }
    }

    var body: some Scene {
        Window("Audio Angel", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.meters)
        }
        .defaultSize(width: 1022, height: 640) // ContentView then fits it exactly

        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.meters)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            Image(systemName: model.status.state == .running ? "waveform.circle.fill" : "waveform.circle")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the window must not stop the audio. Quit from the menu bar icon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        RouterModel.current?.shutdown()
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: RouterModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = model.status
        Text(s.state == .running ? "Routing · \(Int(s.sampleRate)) Hz · \(s.bufferFrames) frames" : s.message)
        Divider()
        Button("Open Audio Angel") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Restart Audio Engine") { model.engine.restart(reason: "user pressed Restart (menu bar)") }
        Divider()
        Button("Quit Audio Angel") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
