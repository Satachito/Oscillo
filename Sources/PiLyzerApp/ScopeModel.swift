import Combine
import Foundation
import PiLyzerCore
import SwiftUI

/// The front panel's state: what the user set, what came back, and the
/// derived numbers the readouts need.
@MainActor
final class ScopeModel: ObservableObject {
    @Published var settings: ScopeSettings {
        didSet {
            guard settings != oldValue else { return }
            if !settings.hasSameSpectrumInput(as: oldValue) { resetSpectrum() }
            engine.update(settings: settings)
            Preferences.save(settings)
        }
    }

    @Published private(set) var connection: ConnectionState = .disconnected
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "Not connected"
    @Published var errorText: String?

    @Published private(set) var frame = ScopeFrame()
    @Published private(set) var logicFrame = LogicFrame()
    @Published private(set) var meter: MeterReading?
    @Published private(set) var spectrum = Spectrum.empty
    @Published private(set) var quality: SpectrumQuality?
    @Published private(set) var plan = AcquisitionPlan.empty

    @Published var sources: [(source: DeviceSource, label: String)] = []
    /// Why the instrument list is empty, when it is.
    @Published private(set) var busHint: String?
    @Published var selectedSource: DeviceSource = .simulator
    @Published var decoderKind: DecoderKind = .none { didSet { rebuildDecoder() } }
    @Published var decoderConfiguration = DecoderConfiguration() { didSet { rebuildDecoder() } }
    @Published private(set) var decoder: LogicDecoder = .none
    @Published private(set) var decoded: [DecodedItem] = []
    @Published var cursorsEnabled = false
    @Published var cursorA = 0.3
    @Published var cursorB = 0.7

    private let engine = InstrumentEngine()
    private var spectrumHistory: [Spectrum] = []
    private var deviceTimer: Timer?
    /// Set by --autostart: sweep as soon as the instrument answers.
    private var startsOnConnect = false

    var instrument: ConnectedInstrument? { connection.instrument }
    var capabilities: DeviceCapabilities { instrument?.capabilities ?? .unavailable }
    var ranges: [InputRange] { instrument?.ranges ?? FrontEnd.bareBoard }
    var isConnected: Bool { connection.isConnected }

    init() {
        settings = Preferences.load()
        selectedSource = Preferences.loadSource() ?? .simulator

        engine.onStateChange = { [weak self] state in self?.apply(state) }
        engine.onScopeFrame = { [weak self] frame in self?.apply(frame) }
        engine.onLogicFrame = { [weak self] frame in self?.apply(frame) }
        engine.onMeterReading = { [weak self] reading in self?.meter = reading }
        engine.onRunningChange = { [weak self] running in self?.isRunning = running }
        engine.onStatus = { [weak self] text in self?.statusText = text }
        engine.onError = { [weak self] text in self?.errorText = text }
        engine.onPlan = { [weak self] plan in self?.plan = plan }

        refreshSources()
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSources() }
        }
    }

    // MARK: - Devices

    func refreshSources() {
        let report = Diagnostics.look()
        let hint = report.hint
        if hint != busHint { busHint = hint }

        let found = InstrumentEngine.availableSources()
        guard found.map(\.label) != sources.map(\.label) else { return }
        sources = found
        if !found.contains(where: { $0.source == selectedSource }) {
            selectedSource = found.first?.source ?? .simulator
        }
    }

    func connect() {
        resetSpectrum()
        Preferences.save(source: selectedSource)
        engine.connect(to: selectedSource, settings: settings)
    }

    /// Applies the command line: `--demo` picks the built-in generator, `--usb`
    /// picks the first attached instrument, `--mode <name>` opens on one of the
    /// four screens, and `--autostart` connects and sweeps without touching the
    /// toolbar.
    func applyLaunchArguments(_ arguments: [String]) {
        if arguments.contains("--demo") { selectedSource = .simulator }
        if arguments.contains("--usb") {
            refreshSources()
            if let device = sources.first(where: { if case .usb = $0.source { return true }; return false }) {
                selectedSource = device.source
            }
        }
        if let index = arguments.firstIndex(of: "--mode"), index + 1 < arguments.count,
           let mode = WorkMode.allCases.first(where: {
               $0.rawValue.lowercased() == arguments[index + 1].lowercased()
           }) {
            settings.mode = mode
        }
        guard arguments.contains("--autostart") || arguments.contains("--demo")
                || arguments.contains("--usb") else { return }
        startsOnConnect = true
        connect()
    }

    func disconnect() {
        engine.disconnect()
    }

    func toggleConnection() {
        isConnected ? disconnect() : connect()
    }

    // MARK: - Acquisition

    func start() { errorText = nil; engine.start() }
    func stop() { engine.stop() }
    func single() { errorText = nil; engine.single() }

    func toggleRun() { isRunning ? stop() : start() }

    func clear() {
        frame = ScopeFrame()
        logicFrame = LogicFrame()
        resetSpectrum()
        decoded = []
    }

    private func resetSpectrum() {
        spectrum = .empty
        spectrumHistory.removeAll()
        quality = nil
    }

    /// Grounded-input calibration: whatever both channels read now becomes
    /// zero for the range each one is on.
    func calibrateZero() {
        let measuredRanges = settings.channels.map(\.rangeIndex)
        engine.calibrateZero { [weak self] volts in
            guard let self else { return }
            for (index, value) in volts.enumerated() where index < self.settings.channels.count {
                let range = measuredRanges[index]
                self.settings.channels[index].calibrateZero(to: value, forRange: range)
            }
            self.statusText = "Zero calibrated"
        }
    }

    func resetCalibration() {
        for index in settings.channels.indices {
            settings.channels[index].calibration = []
        }
        statusText = "Calibration cleared"
    }

    /// Second point of the calibration: the user says what is really on the
    /// input, and the gain error follows from what was read.
    func calibrateGain(channel: Int, appliedVolts: Double) {
        guard channel < settings.channels.count, abs(appliedVolts) > 1e-6 else { return }
        engine.readNow { [weak self] volts in
            guard let self, channel < volts.count else { return }
            let range = self.settings.channels[channel].rangeIndex
            var calibration = self.settings.channels[channel].calibration(forRange: range)
            let measured = volts[channel]
            guard abs(measured) > 1e-9 else { return }
            calibration.scale *= appliedVolts / measured
            self.settings.channels[channel].setCalibration(calibration, forRange: range)
            self.statusText = String(format: "Channel %d gain calibrated", channel + 1)
        }
    }

    // MARK: - Incoming records

    private func apply(_ state: ConnectionState) {
        connection = state
        switch state {
        case .disconnected: statusText = "Not connected"
        case .connecting: statusText = "Connecting…"
        case let .connected(instrument):
            statusText = instrument.summary
            if startsOnConnect { startsOnConnect = false; start() }
        case let .failed(reason): statusText = "Not connected"; errorText = reason
        }
    }

    private func apply(_ incoming: ScopeFrame) {
        frame = incoming
        guard settings.mode == .spectrum else { return }
        updateSpectrum(from: incoming)
    }

    private func apply(_ incoming: LogicFrame) {
        logicFrame = incoming
        decodeLogic()
    }

    private func updateSpectrum(from frame: ScopeFrame) {
        guard frame.samplePeriod > 0,
              let trace = frame.traces.first(where: { $0.index == spectrumChannel })
                ?? frame.traces.first else { return }

        let fresh = SpectrumAnalyzer.transform(trace.samples,
                                               sampleRate: 1 / frame.samplePeriod,
                                               window: settings.spectrum.window)
        spectrumHistory.append(fresh)
        let depth = max(settings.spectrum.averaging, 1)
        if spectrumHistory.count > depth { spectrumHistory.removeFirst(spectrumHistory.count - depth) }

        spectrum = SpectrumAnalyzer.average(spectrumHistory)
        quality = SpectrumAnalyzer.quality(of: spectrum, harmonics: settings.spectrum.harmonicCount)
    }

    /// The spectrum follows the first channel that is switched on.
    var spectrumChannel: Int {
        settings.channels.firstIndex { $0.isEnabled } ?? 0
    }

    private func rebuildDecoder() {
        decoder = decoderConfiguration.decoder(kind: decoderKind)
        decodeLogic()
    }

    private func decodeLogic() {
        decoded = logicFrame.isEmpty ? [] : LogicAnalysis.decode(logicFrame, using: decoder)
    }

    // MARK: - Derived readouts

    func measurements(for channel: Int) -> Measurements? {
        guard let trace = frame.trace(channel), !trace.samples.isEmpty else { return nil }
        return Measurements.of(trace.samples, samplePeriod: frame.samplePeriod)
    }

    func scale(for channel: Int) -> VoltageScale {
        guard channel < settings.channels.count else {
            return VoltageScale(reference: capabilities.referenceVolts,
                                fullScale: capabilities.analogFullScale,
                                range: ranges[0])
        }
        return settings.channels[channel].scale(reference: capabilities.referenceVolts,
                                                fullScale: capabilities.analogFullScale,
                                                ranges: ranges)
    }

    var logicActivity: [ChannelActivity] {
        logicFrame.isEmpty ? [] : LogicAnalysis.activity(of: logicFrame)
    }

    var timebases: [Double] {
        ScopeSettings.timebases(capabilities: capabilities,
                                channels: max(settings.enabledChannelCount, 1))
    }

    var logicRates: [Double] {
        LogicSettings.availableRates(capabilities: capabilities)
    }

    /// What the instrument is really doing, which is not always what was asked.
    var planDescription: String {
        guard plan.recordSamples > 0 else { return "—" }
        let rate = Format.sampleRate(plan.sampleRate)
        let points = "\(plan.recordSamples) pt"
        if plan.decimation > 1 {
            return "\(rate) · \(points) · ×\(plan.decimation) averaged"
        }
        return "\(rate) · \(points)"
    }

    // MARK: - Export

    func exportText() -> (name: String, contents: String) {
        switch settings.mode {
        case .scope:
            return ("waveform.csv", Export.csv(scope: frame))
        case .spectrum:
            return ("spectrum.csv", Export.csv(spectrum: spectrum, scale: settings.spectrum.scale,
                                               fullScale: fullScaleVolts))
        case .logic:
            if decoderKind == .none {
                return ("logic.csv", Export.csv(logicTransitions: logicFrame))
            }
            return ("decoded.csv", Export.csv(decoded: decoded, frame: logicFrame))
        case .meter:
            guard let meter else { return ("meter.csv", "") }
            var lines = ["time_s,channel1_V,channel2_V"]
            let count = meter.history.first?.count ?? 0
            for index in 0..<count {
                let time = Double(index) * meter.interval
                let first = meter.history[0][index]
                let second = meter.history.count > 1 && index < meter.history[1].count ? meter.history[1][index] : 0
                lines.append(String(format: "%.6g,%.7g,%.7g", time, first, second))
            }
            return ("meter.csv", lines.joined(separator: "\n") + "\n")
        }
    }

    var fullScaleVolts: Double {
        let scale = self.scale(for: spectrumChannel)
        return scale.spanVolts / 2
    }
}

/// Which decoder the logic panel is running, and what it is wired to.
enum DecoderKind: String, CaseIterable, Identifiable {
    case none = "None"
    case uart = "UART"
    case spi = "SPI"
    case i2c = "I²C"

    var id: String { rawValue }
}

struct DecoderConfiguration: Equatable {
    var uartLine = 4
    var uartBaud = 115_200.0
    var uartDataBits = 8
    var uartParity: LogicParity = .none

    var spiClock = 5
    var spiData = 6
    var spiSelect = 7
    var spiUsesSelect = true
    var spiClockIdleHigh = false
    var spiSampleOnSecondEdge = false

    var i2cClock = 0
    var i2cData = 1

    func decoder(kind: DecoderKind) -> LogicDecoder {
        switch kind {
        case .none:
            return .none
        case .uart:
            return .uart(line: uartLine, baud: uartBaud, dataBits: uartDataBits, parity: uartParity)
        case .spi:
            return .spi(clock: spiClock, data: spiData,
                        select: spiUsesSelect ? spiSelect : nil,
                        clockIdleHigh: spiClockIdleHigh,
                        sampleOnSecondEdge: spiSampleOnSecondEdge)
        case .i2c:
            return .i2c(clock: i2cClock, data: i2cData)
        }
    }
}
