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
                    .disabled(!model.isConnected)
                Button("Single Sweep") { model.single() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.isConnected || model.isRunning)
                Button("Clear") { model.clear() }
                Divider()
                Button("Measure Bias") { model.measureBias() }
                    .disabled(!model.isConnected)
                Button("Reset Calibration") { model.resetCalibration() }
            }

            CommandMenu("View") {
                ForEach(WorkMode.allCases, id: \.self) { mode in
                    Button(mode.rawValue) { model.settings.mode = mode }
                }
                Divider()
                Toggle("Cursors", isOn: Binding(get: { model.cursorsEnabled },
                                                set: { model.cursorsEnabled = $0 }))
            }
        }
    }
}
