import PiLyzerCore
import SwiftUI

@main
struct PiLyzerApp: App {
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
        if CommandLine.arguments.contains("--bootsel") {
            print(Diagnostics.rebootToBootloader())
            exit(0)
        }
    }

    var body: some Scene {
        Window("PiLyzer", id: "main") {
            ContentView(model: model)
                .onAppear { model.applyLaunchArguments(CommandLine.arguments) }
                // The instrument is drawn in its own colours rather than the
                // system's — the same off-white paper and dark screen as the
                // browser application, which has no dark palette of its own.
                // Without this the system's own controls would come back in
                // dark-mode ink on that light paper and disappear.
                .preferredColorScheme(.light)
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
                Button("Calibrate Zero") { model.calibrateZero() }
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
