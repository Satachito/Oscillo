import AppKit
import PiLyzerCore
import SwiftUI

/// A binary started outside a bundle — `swift run PiLyzer`, or the executable
/// in `.build` — has no bundle for anything to read an icon from. Setting it
/// here covers what asks the application itself; the Dock, which asks Launch
/// Services about the bundle, still needs the bundle, so `make-app.sh` remains
/// the way to get an icon on screen.
final class IconDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.applicationIconImage = AppIcon.image()
    }
}

@main
struct PiLyzerApp: App {
    @NSApplicationDelegateAdaptor(IconDelegate.self) private var delegate
    @StateObject private var model = ScopeModel()
    /// The channel whose voltage sits in the menu bar, or -1 for none.
    @AppStorage("menuBarChannel") private var menuBarChannel = -1

    init() {
        // A diagnostic that does not need the window: it says what is on the
        // bus and, when nothing is, why.
        if CommandLine.arguments.contains("--list") {
            print(Diagnostics.describe())
            exit(0)
        }
        if CommandLine.arguments.contains("--selftest") {
            print(Diagnostics.selfTest())
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--timing") {
            let listed = CommandLine.arguments.dropFirst(index + 1).compactMap(Int.init)
            print(Diagnostics.timingCheck(frequencies: listed.isEmpty ? [100, 1_000, 10_000]
                                                                     : Array(listed)))
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--testout") {
            let argument = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : "1000"
            print(Diagnostics.setTestOutput(argument == "off" ? 0 : Int(argument) ?? 1000))
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--write-icon"),
           index + 1 < CommandLine.arguments.count {
            do {
                try AppIcon.writeICNS(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("could not write the icon: \(error)\n".utf8))
                exit(1)
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--signals") {
            let argument = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : "440"
            print(Diagnostics.setSignals(argument == "off" ? 0 : Int(argument) ?? 440))
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--signalcheck") {
            let argument = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : "440"
            print(Diagnostics.signalCheck(sineHz: Int(argument) ?? 440))
            exit(0)
        }
        if CommandLine.arguments.contains("--bootsel") {
            print(Diagnostics.rebootToBootloader())
            exit(0)
        }
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    var body: some Scene {
        Window("PiLyzer", id: "main") {
            ContentView(model: model)
                .onAppear { model.applyLaunchArguments(CommandLine.arguments) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Instrument") {
                Button(model.isConnected ? "Disconnect" : "Connect") { model.toggleConnection() }
                    .keyboardShortcut("k")
                Divider()
                Button(model.isRunning ? "Stop" : "Run") { model.toggleRun() }
                    .keyboardShortcut("r")
                    .disabled(!model.isConnected || model.hasNothingToCapture)
                Button("Single Sweep") { model.single() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.isConnected || model.isRunning || model.hasNothingToCapture)
                Button("Clear") { model.clear() }
                Divider()
                Button("Measure Bias") { model.measureBias(channels: model.enabledAnalogChannels) }
                    .disabled(!model.isConnected)
                Button("Reset Calibration") { model.resetCalibration() }
            }

            CommandGroup(replacing: .help) {
                Button("PiLyzer on GitHub") { open("https://github.com/Satachito/Oscillo") }
                Button("Sponsor this project") { open("https://github.com/sponsors/Satachito") }
            }

            CommandMenu("View") {
                Picker("Show in Menu Bar", selection: $menuBarChannel) {
                    Text("Nothing").tag(-1)
                    ForEach(0..<model.capabilities.analogChannels, id: \.self) { Text("CH\($0 + 1)").tag($0) }
                }
                Divider()
                ForEach(WorkMode.allCases, id: \.self) { mode in
                    Button(mode.rawValue) { model.settings.mode = mode }
                        .disabled(mode == .logic && !model.capabilities.hasLogic)
                }
                Divider()
                Toggle("Cursors", isOn: Binding(get: { model.cursorsEnabled },
                                                set: { model.cursorsEnabled = $0 }))
            }
        }

        // One channel's voltage in the menu bar, to keep an eye on while the
        // window is behind something else. It reads what the instrument is
        // already doing — the meter on the Meter screen, the record's level on
        // Scope and Spectrum — so it changes nothing about the sweep.
        MenuBarExtra(isInserted: Binding(get: { menuBarChannel >= 0 },
                                         set: { if !$0 { menuBarChannel = -1 } })) {
            MenuBarContent(model: model, channel: $menuBarChannel)
        } label: {
            Text(menuBarLabel).monospacedDigit()
        }
    }

    private var menuBarLabel: String {
        let channel = max(menuBarChannel, 0)
        return "CH\(channel + 1) " + (model.level(of: channel).map(Format.voltage) ?? "—")
    }
}

/// The menu under the reading: every channel's level, which one to show, and
/// the way back to the window.
private struct MenuBarContent: View {
    @ObservedObject var model: ScopeModel
    @Binding var channel: Int
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(0..<model.capabilities.analogChannels, id: \.self) { index in
            Button {
                channel = index
            } label: {
                Text("\(index == channel ? "✓ " : "   ")CH\(index + 1)   \(model.level(of: index).map(Format.voltage) ?? "—")")
            }
        }
        Divider()
        Text(model.isConnected ? (model.isRunning ? "Reading · \(model.settings.mode.rawValue)" : "Stopped — press Run in PiLyzer")
                               : "Not connected")
        Button(model.isRunning ? "Stop" : "Run") { model.toggleRun() }
            .disabled(!model.isConnected || model.hasNothingToCapture)
        Button("Open PiLyzer") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("Hide from Menu Bar") { channel = -1 }
    }
}
