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
        // `--at 0x01100000`: which instrument, by the location --list prints,
        // when more than one is plugged in. The first one otherwise.
        let at: UInt32 = CommandLine.arguments.firstIndex(of: "--at").flatMap { index in
            index + 1 < CommandLine.arguments.count
                ? UInt32(CommandLine.arguments[index + 1].replacingOccurrences(of: "0x", with: ""), radix: 16)
                : nil
        } ?? 0
        if CommandLine.arguments.contains("--selftest") {
            print(Diagnostics.selfTest(locationID: at))
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
            print(Diagnostics.setTestOutput(argument == "off" ? 0 : Int(argument) ?? 1000, locationID: at))
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
        if let index = CommandLine.arguments.firstIndex(of: "--rangecheck") {
            let argument = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : "1000"
            print(Diagnostics.rangeCheck(frequency: Int(argument) ?? 1000, locationID: at))
            exit(0)
        }
        if CommandLine.arguments.contains("--network") {
            print(Diagnostics.networkCheck(locationID: at))
            exit(0)
        }
        if CommandLine.arguments.contains("--bootsel") {
            print(Diagnostics.rebootToBootloader(locationID: at))
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
                // The Mac App Store does not let an app point to payment outside
                // it, and its copy is the sandboxed one: only the GitHub build
                // offers this.
                if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil {
                    Button("Sponsor this project") { open("https://github.com/sponsors/Satachito") }
                }
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
            Image(nsImage: MenuBarLabel.image(MenuBarLabel.volts(model.level(of: max(menuBarChannel, 0)))))
        }
    }
}

/// The menu bar's reading: PiLyzer's mark, then the voltage to two decimals in
/// a monospaced face, so the item keeps its width as the figure moves
/// (between −9.99 and 99.99 V; past them it grows by a character). Drawn
/// as a template image because a menu bar label takes no font of its own;
/// as a template it follows the menu bar between light and dark.
enum MenuBarLabel {
    static func volts(_ value: Double?) -> String {
        guard let value else { return " -.-- V" }
        return String(format: "%5.2f V", value)
    }

    static func image(_ text: String) -> NSImage {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let wave = NSSize(width: 16, height: 18), gap: CGFloat = 4
        let size = NSSize(width: wave.width + gap + ceil(textSize.width), height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            // PiLyzer's mark, the trace in Web/favicon.svg ("M8 32h9l6-17 10 34
            // 9-25 6 8h8" on a 64-unit square), fitted to the icon's box.
            let mark: [(CGFloat, CGFloat)] = [(8, 32), (17, 32), (23, 15), (33, 49), (42, 24), (48, 32), (56, 32)]
            let path = NSBezierPath()
            let mid = size.height / 2, xScale = (wave.width - 2) / 48, yScale: CGFloat = 13 / 34
            for (index, (x, y)) in mark.enumerated() {
                let point = NSPoint(x: 1 + (x - 8) * xScale, y: mid + (32 - y) * yScale)
                index == 0 ? path.move(to: point) : path.line(to: point)
            }
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            (text as NSString).draw(at: NSPoint(x: wave.width + gap, y: (size.height - textSize.height) / 2),
                                    withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
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
                Text("\(index == channel ? "✓ " : "   ")CH\(index + 1)  \(MenuBarLabel.volts(model.level(of: index)))")
                    .font(.system(.body, design: .monospaced))
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
