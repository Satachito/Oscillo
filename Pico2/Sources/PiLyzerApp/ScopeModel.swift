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
    /// One entry per enabled channel, in channel order.
    @Published private(set) var spectra: [ChannelSpectrum] = []
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
    private var spectrumHistory: [Int: [Spectrum]] = [:]
    private var deviceTimer: Timer?
    /// Set by --autostart: sweep as soon as the instrument answers.
    private var startsOnConnect = false

    var instrument: ConnectedInstrument? { connection.instrument }
    // Show the Pico 2 front panel before connecting; the device's actual
    // capabilities take precedence as soon as it answers.
    private static let previewCapabilities: DeviceCapabilities = {
        var caps = DeviceCapabilities.unavailable
        caps.analogChannels = 3
        caps.analogMinPeriodCycles = 97
        return caps
    }()
    var capabilities: DeviceCapabilities { instrument?.capabilities ?? Self.previewCapabilities }
    var ranges: [InputRange] { instrument?.ranges ?? FrontEnd.bareBoard }
    var isConnected: Bool { connection.isConnected }

    init() {
        var savedSettings = Preferences.load()
        savedSettings.ensureAnalogChannels(Self.previewCapabilities.analogChannels)
        settings = savedSettings
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
        clear()
        plan = .empty
        meter = nil
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
        spectra = []
        spectrumHistory.removeAll()
    }

    /// Grounded-input calibration: whatever all channels read now becomes
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
            settings.ensureAnalogChannels(instrument.capabilities.analogChannels)
            normalizeAnalogSelection()
            settleTriggerLevel()
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

    /// Every channel in the record gets its own transform and its own
    /// averaging history. They come from the same sweep, so the bins agree and
    /// an input and an output can be read against each other directly.
    private func updateSpectrum(from frame: ScopeFrame) {
        guard frame.samplePeriod > 0 else { return }
        let depth = max(settings.spectrum.averaging, 1)
        var fresh: [ChannelSpectrum] = []
        for trace in frame.traces {
            var history = spectrumHistory[trace.index, default: []]
            history.append(SpectrumAnalyzer.transform(trace.samples,
                                                      sampleRate: 1 / frame.samplePeriod,
                                                      window: settings.spectrum.window))
            if history.count > depth { history.removeFirst(history.count - depth) }
            spectrumHistory[trace.index] = history

            let averaged = SpectrumAnalyzer.average(history)
            fresh.append(ChannelSpectrum(
                channel: trace.index, spectrum: averaged,
                fullScale: scale(for: trace.index).spanVolts / 2,
                quality: SpectrumAnalyzer.quality(of: averaged,
                                                  harmonics: settings.spectrum.harmonicCount)))
        }
        let present = Set(frame.traces.map(\.index))
        spectrumHistory = spectrumHistory.filter { present.contains($0.key) }
        spectra = fresh.sorted { $0.channel < $1.channel }
    }

    private func rebuildDecoder() {
        decoder = decoderConfiguration.decoder(kind: decoderKind)
        decodeLogic()
    }

    private func decodeLogic() {
        decoded = logicFrame.isEmpty ? [] : LogicAnalysis.decode(logicFrame, using: decoder)
    }

    /// A trigger level from a previous session can land outside what the
    /// instrument now in front of us can reach — a level of 0 V is mid-range on
    /// the front end but the very bottom of a bare Pico 2, where nothing ever
    /// crosses it. That looks like a broken trigger rather than a stale
    /// setting, so it is moved somewhere the signal can get to.
    private func settleTriggerLevel() {
        let source = min(max(settings.trigger.source, 0), max(settings.channels.count - 1, 0))
        let usable = scale(for: source).usableTriggerLevel(settings.trigger.levelVolts)
        if abs(usable - settings.trigger.levelVolts) > 1e-9 {
            settings.trigger.levelVolts = usable
        }
    }

    /// The X/Y axes, held to channels that are switched on. A plot against a
    /// channel that is not being captured would simply be blank.
    var xyHorizontalChannel: Int { resolveXY(settings.xyHorizontal, fallback: 0) }
    var xyVerticalChannel: Int { resolveXY(settings.xyVertical, fallback: 1) }

    private func resolveXY(_ wanted: Int, fallback: Int) -> Int {
        let live = enabledAnalogChannels
        if live.contains(wanted) { return wanted }
        if live.contains(fallback) { return fallback }
        return live.first ?? 0
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

    var availableAnalogChannels: [Int] {
        Array(0..<min(settings.channels.count, capabilities.analogChannels))
    }

    var enabledAnalogChannels: [Int] {
        let mask = settings.enabledMask(capabilities: capabilities)
        return availableAnalogChannels.filter { mask & (1 << $0) != 0 }
    }

    func normalizeAnalogSelection() {
        if !enabledAnalogChannels.contains(settings.trigger.source) {
            settings.trigger.source = enabledAnalogChannels.first ?? 0
        }
        let choices = timebases
        if !choices.contains(settings.secondsPerDivision), let value = choices.first(where: { $0 >= settings.secondsPerDivision }) ?? choices.last {
            settings.secondsPerDivision = value
        }
    }

    var maximumAnalogRate: Double {
        1 / capabilities.minimumSamplePeriod(channels: max(enabledAnalogChannels.count, 1))
    }

    var timebases: [Double] {
        ScopeSettings.timebases(capabilities: capabilities,
                                channels: max(enabledAnalogChannels.count, 1))
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
            return ("spectrum.csv", Export.csv(spectra: spectra, scale: settings.spectrum.scale))
        case .logic:
            if decoderKind == .none {
                return ("logic.csv", Export.csv(logicTransitions: logicFrame))
            }
            return ("decoded.csv", Export.csv(decoded: decoded, frame: logicFrame))
        case .meter:
            guard let meter else { return ("log.csv", "") }
            // Each row is one logged interval, so the extremes within it are
            // part of the record rather than something only the screen knew.
            let stamp = ISO8601DateFormatter()
            var header = ["time_s", "timestamp"]
            for channel in meter.history.indices {
                header += ["CH\(channel + 1)_min_V", "CH\(channel + 1)_mean_V", "CH\(channel + 1)_max_V"]
            }
            var lines = [header.joined(separator: ",")]
            let count = meter.history.map(\.count).min() ?? 0
            for index in 0..<count {
                let seconds = Double(index) * meter.interval
                var row = [String(format: "%.6g", seconds),
                           stamp.string(from: meter.start.addingTimeInterval(seconds))]
                for channel in meter.history.indices {
                    let sample = meter.history[channel][index]
                    row += [String(format: "%.7g", sample.low),
                            String(format: "%.7g", sample.mean),
                            String(format: "%.7g", sample.high)]
                }
                lines.append(row.joined(separator: ","))
            }
            return ("log.csv", lines.joined(separator: "\n") + "\n")
        }
    }

    /// How much log is on screen, for the section's tag.
    var meterSpanDescription: String {
        guard let meter, let points = meter.history.first?.count, points > 0 else { return "EMPTY" }
        return "\(points) PT · \(Format.time(meter.span).uppercased())"
    }

    /// What this interval means in practice: how long the log can run before it
    /// starts dropping its oldest points.
    var loggerAdvice: String {
        let interval = max(settings.logIntervalSeconds, 0.05)
        let full = Format.time(interval * Double(InstrumentEngine.meterCapacity))
        return "Each point holds the lowest, mean and highest reading of its "
            + "interval. \(InstrumentEngine.meterCapacity.formatted()) points fit — \(full) — "
            + "after which the oldest are dropped."
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
