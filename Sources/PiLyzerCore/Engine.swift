import Foundation

public enum DeviceSource: Hashable, Codable, Sendable {
    case usb(locationID: UInt32)
    case simulator

    public var label: String {
        switch self {
        case .simulator: return "Demo signal"
        case let .usb(location): return String(format: "PiLyzer @ 0x%08X", location)
        }
    }
}

public struct ConnectedInstrument: Equatable, Sendable {
    public var identity: DeviceIdentity
    public var capabilities: DeviceCapabilities
    public var source: DeviceSource
    public var ranges: [InputRange]

    public var summary: String {
        "\(identity.name) · firmware \(identity.firmwareDescription)"
    }
}

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(ConnectedInstrument)
    case failed(String)

    public var isConnected: Bool { if case .connected = self { return true }; return false }
    public var instrument: ConnectedInstrument? {
        if case let .connected(instrument) = self { return instrument }
        return nil
    }
}

public struct MeterReading: Equatable, Sendable {
    public var volts: [Double]
    public var history: [[Double]]
    public var interval: Double
    public var timestamp: Date
}

/// Drives the instrument on one background queue and hands finished records to
/// the interface on the callback queue.
///
/// One acquisition is: configure if anything changed, arm, poll until the
/// record is complete, read it, convert it to volts. Every public method only
/// enqueues work, so they are all safe to call from the main thread.
public final class InstrumentEngine {
    public var onStateChange: ((ConnectionState) -> Void)?
    public var onScopeFrame: ((ScopeFrame) -> Void)?
    public var onLogicFrame: ((LogicFrame) -> Void)?
    public var onMeterReading: ((MeterReading) -> Void)?
    public var onRunningChange: ((Bool) -> Void)?
    public var onStatus: ((String) -> Void)?
    public var onError: ((String) -> Void)?
    public var onPlan: ((AcquisitionPlan) -> Void)?

    public var callbackQueue: DispatchQueue = .main

    /// Ceiling on the redraw rate; the instrument can outrun any screen.
    public static let minimumFramePeriod = 1.0 / 30.0
    public static let meterCapacity = 20_000

    private let queue = DispatchQueue(label: "com.pilyzer.acquisition", qos: .userInitiated)
    private let generationLock = NSLock()
    private var generation = 0

    private var instrument: Instrument?
    private var connected: ConnectedInstrument?
    private var settings = ScopeSettings()
    private var appliedAnalog: AnalogConfiguration?
    private var appliedLogic: LogicConfiguration?
    private var analogPlan = AcquisitionPlan.empty
    private var logicPlan = AcquisitionPlan.empty
    private var meterHistory: [[Double]] = [[], []]
    private var meterStart = Date()

    public init() {}
    deinit { instrument?.close() }

    // MARK: - Sources

    public static func availableSources() -> [(source: DeviceSource, label: String)] {
        USBTransport.attachedDevices().map { (.usb(locationID: $0.locationID), $0.label) }
            + [(.simulator, "Demo signal")]
    }

    // MARK: - Generation

    private func nextGeneration() -> Int {
        generationLock.lock(); defer { generationLock.unlock() }
        generation += 1
        return generation
    }

    private func isCurrent(_ token: Int) -> Bool {
        generationLock.lock(); defer { generationLock.unlock() }
        return token == generation
    }

    // MARK: - Connection

    public func connect(to source: DeviceSource, settings newSettings: ScopeSettings) {
        _ = nextGeneration()
        report(state: .connecting)
        queue.async { [self] in
            instrument?.close()
            instrument = nil
            connected = nil
            appliedAnalog = nil
            appliedLogic = nil
            settings = newSettings

            do {
                let device: Instrument
                switch source {
                case .simulator: device = SimulatedInstrument()
                case let .usb(location): device = try USBInstrument(locationID: location)
                }
                let ranges = FrontEnd.ranges(forBoard: device.identity.boardID)
                instrument = device
                let description = ConnectedInstrument(identity: device.identity,
                                                      capabilities: device.capabilities,
                                                      source: source, ranges: ranges)
                connected = description
                applyPanel(to: device)
                report(state: .connected(description))
            } catch {
                instrument?.close()
                instrument = nil
                report(state: .failed(Self.describe(error)))
            }
        }
    }

    public func disconnect() {
        _ = nextGeneration()
        queue.async { [self] in
            try? instrument?.abortAnalog()
            try? instrument?.abortLogic()
            instrument?.close()
            instrument = nil
            connected = nil
            report(running: false)
            report(state: .disconnected)
        }
    }

    /// Pushes the panel settings that live in the hardware rather than in a
    /// packet: the input range switches and the calibration output.
    private func applyPanel(to device: Instrument) {
        guard let ranges = connected?.ranges else { return }
        for (index, channel) in settings.channels.enumerated() where index < device.capabilities.analogChannels {
            let range = channel.range(from: ranges)
            try? device.setRange(channel: index, range: range.switchPosition)
        }
        if device.capabilities.hasCalibrationOutput {
            _ = try? device.setCalibrationOutput(enabled: settings.calibrationOutputEnabled,
                                                 frequency: settings.calibrationOutputFrequency)
        }
    }

    // MARK: - Control

    public func update(settings newSettings: ScopeSettings) {
        queue.async { [self] in
            let modeChanged = newSettings.mode != settings.mode
            let panelChanged = newSettings.channels.map(\.rangeIndex) != settings.channels.map(\.rangeIndex)
                || newSettings.calibrationOutputEnabled != settings.calibrationOutputEnabled
                || newSettings.calibrationOutputFrequency != settings.calibrationOutputFrequency
            settings = newSettings
            if modeChanged { resetMeter() }
            if panelChanged, let instrument { applyPanel(to: instrument) }
        }
    }

    public func start() {
        guard instrument != nil || connected != nil else { return }
        let token = nextGeneration()
        queue.async { [self] in
            guard instrument != nil, isCurrent(token) else { return }
            resetMeter()
            report(running: true)
            step(token: token)
        }
    }

    public func stop() {
        _ = nextGeneration()
        queue.async { [self] in
            try? instrument?.abortAnalog()
            try? instrument?.abortLogic()
            report(running: false)
            report(status: "Stopped")
        }
    }

    public func single() {
        let token = nextGeneration()
        queue.async { [self] in
            guard let instrument, isCurrent(token) else { return }
            do {
                switch settings.mode {
                case .scope, .spectrum:
                    if let frame = try acquireAnalog(instrument, token: token) {
                        report(frame: frame)
                        report(status: frame.triggered ? "Single sweep" : "Single sweep, no trigger")
                    } else {
                        report(status: "No trigger")
                    }
                case .logic:
                    if let frame = try acquireLogic(instrument, token: token) {
                        report(logic: frame)
                        report(status: "Single capture")
                    } else {
                        report(status: "No trigger")
                    }
                case .meter:
                    try acquireMeter(instrument)
                }
            } catch {
                handle(error)
            }
        }
    }

    /// Grounded-input zero calibration: whatever the instrument reads with
    /// nothing applied becomes the new zero for the range each channel is on.
    public func calibrateZero(samples: Int = 32, completion: @escaping ([Double]) -> Void) {
        queue.async { [self] in
            guard let instrument, let connected else { return }
            do {
                let readings = try instrument.sampleAnalog(averages: samples)
                let volts = readings.enumerated().map { index, code -> Double in
                    guard index < settings.channels.count else { return 0 }
                    var scale = settings.channels[index].scale(reference: connected.capabilities.referenceVolts,
                                                               fullScale: connected.capabilities.analogFullScale,
                                                               ranges: connected.ranges)
                    scale.calibration = ChannelCalibration(zero: 0, scale: scale.calibration.scale)
                    return scale.volts(code)
                }
                callbackQueue.async { completion(volts) }
                report(status: "Zero: " + volts.map { Format.voltage($0) }.joined(separator: ", "))
            } catch {
                handle(error)
            }
        }
    }

    /// One immediate reading of both inputs, in volts.
    public func readNow(completion: @escaping ([Double]) -> Void) {
        queue.async { [self] in
            guard let instrument else { return }
            guard let volts = try? currentVolts(instrument) else { return }
            callbackQueue.async { completion(volts) }
        }
    }

    // MARK: - Acquisition

    private func step(token: Int) {
        guard isCurrent(token), let instrument else { return }
        let started = Date()
        var delay = Self.minimumFramePeriod

        do {
            switch settings.mode {
            case .scope, .spectrum:
                if let frame = try acquireAnalog(instrument, token: token) {
                    report(frame: frame)
                    report(status: frame.triggered ? "Triggered" : "Auto")
                } else {
                    report(status: "Waiting for trigger…")
                }
            case .logic:
                if let frame = try acquireLogic(instrument, token: token) {
                    report(logic: frame)
                    report(status: frame.triggered ? "Triggered" : "Auto")
                } else {
                    report(status: "Waiting for trigger…")
                }
            case .meter:
                try acquireMeter(instrument)
                delay = 0.05
            }
        } catch {
            handle(error)
            return
        }

        guard isCurrent(token) else { return }
        let elapsed = Date().timeIntervalSince(started)
        queue.asyncAfter(deadline: .now() + max(delay - elapsed, 0.001)) { [self] in step(token: token) }
    }

    private func acquireAnalog(_ instrument: Instrument, token: Int) throws -> ScopeFrame? {
        guard let connected else { throw InstrumentError.notConnected }

        let scales = voltageScales(connected)
        let configuration = settings.analogConfiguration(capabilities: connected.capabilities,
                                                         scales: scales)
        if configuration != appliedAnalog {
            analogPlan = try instrument.configureAnalog(configuration)
            appliedAnalog = configuration
            let plan = analogPlan
            callbackQueue.async { [onPlan] in onPlan?(plan) }
        }

        let averaging = min(max(settings.averaging, 1), 100)
        var accumulator: [[Double]] = []
        var triggered = true
        var clipped = [Bool](repeating: false, count: scales.count)
        var triggerIndex = analogPlan.pretriggerSamples

        for _ in 0..<averaging {
            guard let capture = try captureAnalogOnce(instrument, token: token) else { return nil }
            triggered = triggered && capture.triggered
            triggerIndex = capture.triggerIndex

            let channelSlots = analogPlan.enabledChannels
            var traces: [[Double]] = []
            for (slot, channel) in channelSlots.enumerated() where slot < capture.columns.count {
                let column = capture.columns[slot]
                let scale = scales.indices.contains(channel) ? scales[channel] : scales[0]
                let limit = connected.capabilities.analogFullScale
                if column.contains(where: { $0 == 0 || Double($0) >= limit - 16 }) {
                    if channel < clipped.count { clipped[channel] = true }
                }
                traces.append(column.map(scale.volts))
            }
            accumulator = accumulate(accumulator, traces)
        }

        let divisor = Double(averaging)
        let channelSlots = analogPlan.enabledChannels
        var traces: [ChannelTrace] = []
        for (slot, channel) in channelSlots.enumerated() where slot < accumulator.count {
            var samples = accumulator[slot].map { $0 / divisor }
            if channel < settings.channels.count, settings.channels[channel].removesMean, !samples.isEmpty {
                let mean = samples.reduce(0, +) / Double(samples.count)
                samples = samples.map { $0 - mean }
            }
            traces.append(ChannelTrace(index: channel, samples: samples,
                                       clipped: channel < clipped.count && clipped[channel]))
        }

        return ScopeFrame(traces: traces, samplePeriod: analogPlan.samplePeriod,
                          triggerIndex: triggerIndex, triggered: triggered)
    }

    private struct Capture {
        var columns: [[UInt16]]
        var triggered: Bool
        var triggerIndex: Int
    }

    private func captureAnalogOnce(_ instrument: Instrument, token: Int) throws -> Capture? {
        try instrument.armAnalog()
        guard let status = try waitForCompletion(token: token,
                                                 expected: analogPlan.duration,
                                                 poll: { try instrument.analogStatus() },
                                                 abort: { try? instrument.abortAnalog() })
        else { return nil }

        guard status.state == .complete else {
            try? instrument.abortAnalog()
            if status.state == .overrun { throw InstrumentError.rejected(.analogStatus, .internalError) }
            return nil
        }
        let columns = try instrument.readAnalogRecord(plan: analogPlan)
        return Capture(columns: columns, triggered: status.triggered, triggerIndex: status.triggerIndex)
    }

    private func acquireLogic(_ instrument: Instrument, token: Int) throws -> LogicFrame? {
        guard let connected else { throw InstrumentError.notConnected }
        let configuration = settings.logic.configuration(capabilities: connected.capabilities)
        if configuration != appliedLogic {
            logicPlan = try instrument.configureLogic(configuration)
            appliedLogic = configuration
            let plan = logicPlan
            callbackQueue.async { [onPlan] in onPlan?(plan) }
        }

        try instrument.armLogic()
        guard let status = try waitForCompletion(token: token,
                                                 expected: logicPlan.duration,
                                                 poll: { try instrument.logicStatus() },
                                                 abort: { try? instrument.abortLogic() })
        else { return nil }
        guard status.state == .complete else { try? instrument.abortLogic(); return nil }

        let samples = try instrument.readLogicRecord(plan: logicPlan)
        return LogicFrame(samples: samples, samplePeriod: logicPlan.samplePeriod,
                          triggerIndex: status.triggerIndex, triggered: status.triggered,
                          channelCount: connected.capabilities.logicChannels)
    }

    /// Polls until the record is finished, giving up only when the panel says
    /// to — a normal trigger is allowed to wait indefinitely, and Stop is what
    /// ends the wait.
    private func waitForCompletion(token: Int, expected: Double,
                                   poll: () throws -> AcquisitionStatus,
                                   abort: () -> Void) throws -> AcquisitionStatus? {
        let interval = min(max(expected / 20, 0.0005), 0.02)
        let patience = expected + 2.0
        let deadline = Date().addingTimeInterval(patience)
        let waitsForever = settings.mode == .logic
            ? settings.logic.triggerMode == .normal
            : settings.trigger.mode == .normal

        while true {
            guard isCurrent(token) else { abort(); return nil }
            let status = try poll()
            if status.isFinished { return status }
            if !waitsForever && Date() > deadline { abort(); return nil }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    private func acquireMeter(_ instrument: Instrument) throws {
        let volts = try currentVolts(instrument)
        for (index, value) in volts.enumerated() where index < meterHistory.count {
            meterHistory[index].append(value)
            if meterHistory[index].count > Self.meterCapacity {
                meterHistory[index].removeFirst(meterHistory[index].count - Self.meterCapacity)
            }
        }
        let span = Date().timeIntervalSince(meterStart)
        let count = meterHistory.first?.count ?? 1
        let interval = count > 1 ? span / Double(count - 1) : 0.05
        let reading = MeterReading(volts: volts, history: meterHistory,
                                   interval: interval, timestamp: Date())
        callbackQueue.async { [onMeterReading] in onMeterReading?(reading) }
    }

    private func currentVolts(_ instrument: Instrument) throws -> [Double] {
        guard let connected else { throw InstrumentError.notConnected }
        let codes = try instrument.sampleAnalog(averages: 64)
        let scales = voltageScales(connected)
        return codes.enumerated().map { index, code in
            let scale = scales.indices.contains(index) ? scales[index] : scales[0]
            return scale.volts(code)
        }
    }

    private func voltageScales(_ connected: ConnectedInstrument) -> [VoltageScale] {
        settings.channels.map {
            $0.scale(reference: connected.capabilities.referenceVolts,
                     fullScale: connected.capabilities.analogFullScale,
                     ranges: connected.ranges)
        }
    }

    private func accumulate(_ total: [[Double]], _ addition: [[Double]]) -> [[Double]] {
        guard !total.isEmpty, total.count == addition.count else { return addition }
        return zip(total, addition).map { left, right in
            guard left.count == right.count else { return right }
            return zip(left, right).map(+)
        }
    }

    private func resetMeter() {
        meterHistory = [[], []]
        meterStart = Date()
    }

    // MARK: - Reporting

    private func handle(_ error: Error) {
        _ = nextGeneration()
        report(running: false)
        report(error: Self.describe(error))
        if let instrumentError = error as? InstrumentError,
           case .transferFailed = instrumentError {
            instrument?.close()
            instrument = nil
            connected = nil
            report(state: .disconnected)
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func report(state: ConnectionState) {
        callbackQueue.async { [onStateChange] in onStateChange?(state) }
    }
    private func report(frame: ScopeFrame) {
        callbackQueue.async { [onScopeFrame] in onScopeFrame?(frame) }
    }
    private func report(logic frame: LogicFrame) {
        callbackQueue.async { [onLogicFrame] in onLogicFrame?(frame) }
    }
    private func report(running: Bool) {
        callbackQueue.async { [onRunningChange] in onRunningChange?(running) }
    }
    private func report(status: String) {
        callbackQueue.async { [onStatus] in onStatus?(status) }
    }
    private func report(error: String) {
        callbackQueue.async { [onError] in onError?(error) }
    }
}
