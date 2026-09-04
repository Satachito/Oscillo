import AppKit
import SwiftUI

@main
struct DPScopeApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = ScopeModel()

    var body: some Scene {
        WindowGroup("DPScope") {
            ContentView(model: model)
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandGroup(after: .saveItem) {
                Button("Export Trace as CSV…") { model.exportCSV() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.frame.isEmpty)
            }

            CommandMenu("Scope") {
                Button(model.isConnected ? "Disconnect" : "Connect") { model.toggleConnection() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Rescan for Scopes") { model.refreshDevices() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Measure Supply Rail") { model.recalibrate() }
                    .disabled(!model.isConnected)
                Button("Calibrate Zero…") { model.calibrateZero() }
                    .disabled(!model.isConnected || model.isRunning)
                Divider()
                Button(model.isRunning ? "Stop" : "Run") { model.toggleRun() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.isConnected)
                Button("Single Sweep") { model.single() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.isConnected || model.isRunning)
                Button("Clear") { model.clear() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }
    }
}

/// A Swift Package executable starts as a background process; asking for the
/// regular activation policy gives the app a Dock icon, a menu bar and focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
