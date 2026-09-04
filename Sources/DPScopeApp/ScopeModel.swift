import AppKit
import Combine
import DPScopeCore
import Foundation

/// How the acquired frame is drawn.
enum DisplayMode: String, CaseIterable, Identifiable {
    case time = "Y/T"
    case xy = "X/Y"
    case spectrum = "FFT"

    var id: String { rawValue }
}

/// UI-facing state. Every engine callback arrives on the main queue, so the
/// published properties are only ever mutated there.
final class ScopeModel: ObservableObject {
    @Published var settings = ScopeSettings() {
        didSet {
            guard settings != oldValue else { return }
            engine.update(settings: settings)
            Preferences.save(settings)
        }
    }
    @Published private(set) var frame = ScopeFrame()
    @Published private(set) var connection: ConnectionState = .disconnected
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Not connected"
    @Published var errorMessage: String?
    @Published private(set) var availableSources: [(source: DeviceSource, label: String)] = []
    @Published var selectedSource: DeviceSource = .simulator {
        didSet {
            guard selectedSource != oldValue else { return }
            Preferences.deviceSource = selectedSource
            // Picking a different instrument while connected should just move
            // to it, rather than making the user disconnect first.
            if isConnected {
                let wasRunning = isRunning
                engine.disconnect()
                startWhenConnected = wasRunning
                connect()
            }
        }
    }
    /// Supply rail the scope measured through its 4.096 V reference.
    @Published private(set) var supplyVoltage = ScopeRecord.nominalSupply
    @Published var displayMode: DisplayMode = Preferences.displayMode {
        didSet { Preferences.displayMode = displayMode }
    }
    @Published var showMeasurements = Preferences.showMeasurements {
        didSet { Preferences.showMeasurements = showMeasurements }
    }

    private let engine = ScopeEngine()
    /// Keeps the source list correct as scopes come and go.
    private let watcher = HIDDeviceWatcher()
    /// Set when the app is launched with `--demo`, so the first successful
    /// connection also starts the sweep.
    private var startWhenConnected = false

    /// `--autostart` connects to the remembered source and starts sweeping;
    /// `--demo` does the same but forces the built-in signal generator.
    init(
        autoStart: Bool = CommandLine.arguments.contains("--autostart") || CommandLine.arguments.contains("--demo"),
        forceSimulator: Bool = CommandLine.arguments.contains("--demo")
    ) {
        settings = Preferences.loadSettings()

        engine.onFrame = { [weak self] frame in self?.frame = frame }
        engine.onStateChange = { [weak self] state in self?.apply(state) }
        engine.onRunningChange = { [weak self] running in self?.isRunning = running }
        engine.onStatus = { [weak self] status in self?.status = status }
        engine.onError = { [weak self] message in
            self?.errorMessage = message
            self?.status = "Error"
        }
        engine.onSupplyVoltage = { [weak self] volts in self?.supplyVoltage = volts }
        engine.onZeroCalibration = { [weak self] zeros in
            guard let self else { return }
            settings.channel1.zeroGain1 = zeros.0
            settings.channel1.zeroGain10 = zeros.1
            settings.channel2.zeroGain1 = zeros.2
            settings.channel2.zeroGain10 = zeros.3
        }
        watcher.onChange = { [weak self] _ in self?.devicesChanged() }
        watcher.start()

        refreshDevices()
        if let remembered = Preferences.deviceSource,
           availableSources.contains(where: { $0.source == remembered }) {
            selectedSource = remembered
        } else {
            // Nothing remembered: attached hardware wins over the demo source.
            selectedSource = availableSources.first?.source ?? .simulator
        }
        if forceSimulator { selectedSource = .simulator }

        if autoStart {
            startWhenConnected = true
            connect()
        }
    }

    // MARK: - Connection

    var isConnected: Bool { connection.isConnected }

    var connectionSummary: String {
        switch connection {
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting…"
        case let .connected(identity, source): return "\(identity) — \(source.label)"
        case let .failed(message): return message
        }
    }

    func refreshDevices() {
        watcher.refresh()
        availableSources = ScopeEngine.availableSources()
        if !availableSources.contains(where: { $0.source == selectedSource }) {
            // Prefer real hardware over the demo source when something is attached.
            selectedSource = availableSources.first?.source ?? .simulator
        }
    }

    /// A scope was plugged in or unplugged.
    private func devicesChanged() {
        availableSources = ScopeEngine.availableSources()
        guard !isConnected else { return }
        // Move to hardware when it turns up, unless the demo source was a
        // deliberate choice made while a scope was already attached.
        if !availableSources.contains(where: { $0.source == selectedSource }) {
            selectedSource = availableSources.first?.source ?? .simulator
        } else if selectedSource == .simulator, Preferences.deviceSource == nil,
                  let hardware = availableSources.first(where: { $0.source != .simulator }) {
            selectedSource = hardware.source
        }
    }

    /// Re-reads the supply rail, which sets the scale of every measurement.
    func recalibrate() {
        guard isConnected else { return }
        engine.recalibrate()
    }

    /// Measures what the converter reads with 0 V in. Ground both inputs first.
    func calibrateZero() {
        guard isConnected else { return }
        engine.calibrateZero()
    }

    func resetZeroCalibration() {
        settings.channel1.zeroGain1 = ScopeRecord.zeroCode
        settings.channel1.zeroGain10 = ScopeRecord.zeroCode
        settings.channel2.zeroGain1 = ScopeRecord.zeroCode
        settings.channel2.zeroGain10 = ScopeRecord.zeroCode
    }

    func connect() {
        errorMessage = nil
        engine.connect(to: selectedSource, settings: settings)
    }

    func disconnect() {
        engine.disconnect()
    }

    func toggleConnection() {
        if isConnected { disconnect() } else { connect() }
    }

    private func apply(_ state: ConnectionState) {
        connection = state
        switch state {
        case .connecting:
            status = "Connecting…"
        case .connected:
            status = "Ready"
            if startWhenConnected {
                startWhenConnected = false
                start()
            }
        case .disconnected:
            status = "Not connected"
            frame = ScopeFrame()
        case let .failed(message):
            status = "Connection failed"
            errorMessage = message
        }
    }

    // MARK: - Acquisition

    func start() {
        guard isConnected else { return }
        engine.start()
    }

    func stop() {
        engine.stop()
    }

    func toggleRun() {
        if isRunning { stop() } else { start() }
    }

    func single() {
        guard isConnected, !isRunning else { return }
        engine.acquireSingle()
    }

    func clear() {
        engine.clear()
        frame = ScopeFrame(mode: settings.mode)
    }

    // MARK: - Derived values

    func statistics(forChannel channel: Int) -> ChannelStatistics? {
        ChannelStatistics(frame.samples(for: channel))
    }

    /// Fundamental frequency of a channel's trace, if it repeats often enough
    /// in the record to measure.
    func frequency(forChannel channel: Int) -> Double? {
        estimateFrequency(frame.samples(for: channel), sampleInterval: frame.sampleInterval)
    }

    func channelSettings(_ channel: Int) -> ChannelSettings {
        channel == 0 ? settings.channel1 : settings.channel2
    }

    /// Volts per division for a channel, at the measured supply.
    func voltsPerDivision(_ channel: Int) -> Double {
        channelSettings(channel).voltsPerDivision(supply: supplyVoltage)
    }

    /// Sample rate implied by the current frame.
    var sampleRateDescription: String {
        guard frame.sampleInterval > 0, !frame.isEmpty else { return "—" }
        let rate = 1 / frame.sampleInterval
        if rate >= 1_000_000 { return String(format: "%.2f MS/s", rate / 1e6) }
        if rate >= 1_000 { return String(format: "%.1f kS/s", rate / 1e3) }
        return String(format: "%.1f S/s", rate)
    }

    // MARK: - Export

    func exportCSV() {
        guard !frame.isEmpty else {
            errorMessage = "There is nothing to export yet."
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "dpscope.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        var text = "time_s,ch1_v,ch2_v\n"
        let count = max(frame.channel1.count, frame.channel2.count)
        text.reserveCapacity(count * 32)
        for index in 0..<count {
            let time = Double(index) * frame.sampleInterval
            let first = index < frame.channel1.count ? String(format: "%.6f", frame.channel1[index]) : ""
            let second = index < frame.channel2.count ? String(format: "%.6f", frame.channel2[index]) : ""
            text += "\(String(format: "%.9f", time)),\(first),\(second)\n"
        }

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            status = "Exported \(count) samples"
        } catch {
            errorMessage = "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
