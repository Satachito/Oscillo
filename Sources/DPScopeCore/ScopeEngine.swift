import Foundation

public enum DeviceSource: Hashable, Codable, Sendable {
    case usb(locationID: UInt32)
    case simulator

    public var label: String {
        switch self {
        case .simulator: return "Demo signal"
        case let .usb(location): return String(format: "DPScope SE @ 0x%08X", location)
        }
    }
}

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(identity: String, source: DeviceSource)
    case failed(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Drives the instrument on a background queue and hands finished frames to
/// the UI on the callback queue.
///
/// One acquisition is: program `CMD_ARM`, poll `CMD_DONE`, read the seven
/// readback blocks, `CMD_ABORT`. All of that happens on `queue`, so the public
/// methods only enqueue work and are safe to call from the main thread.
public final class ScopeEngine {
    public var onFrame: ((ScopeFrame) -> Void)?
    public var onStateChange: ((ConnectionState) -> Void)?
    public var onRunningChange: ((Bool) -> Void)?
    public var onStatus: ((String) -> Void)?
    public var onError: ((String) -> Void)?
    /// Supply rail measured through the scope's 4.096 V reference.
    public var onSupplyVoltage: ((Double) -> Void)?
    /// Zero-calibration result: the converter codes for 0 V on each path,
    /// as `(channel1Gain1, channel1Gain10, channel2Gain1, channel2Gain10)`.
    public var onZeroCalibration: (((Double, Double, Double, Double)) -> Void)?

    /// Queue the callbacks are delivered on; the main queue by default.
    public var callbackQueue: DispatchQueue = .main

    public static let datalogCapacity = 20_000
    /// Upper bound on the scope refresh rate.
    public static let minimumFramePeriod = 1.0 / 30.0
    /// How long to wait past the record time before giving up on a trigger.
    public static let triggerPatience = 1.5
    /// How long auto mode looks for a trigger before sweeping anyway.
    public static let autoTriggerPatience = 0.08

    private let queue = DispatchQueue(label: "com.dpscope.acquisition", qos: .userInitiated)
    private var device: ScopeDevice?
    private var settings = ScopeSettings()
    private var supplyVoltage = ScopeRecord.nominalSupply
    private var isRunning = false
    private var generation = 0

    private var logChannel1: [Double] = []
    private var logChannel2: [Double] = []
    private var logStart = Date()
    private var logSampleCount = 0

    public init() {}

    deinit { device?.close() }

    // MARK: - Connection

    /// Devices currently attached, plus the always-available demo source.
    public static func availableSources() -> [(source: DeviceSource, label: String)] {
        HIDTransport.availableDevices().map { (.usb(locationID: $0.locationID), $0.label) }
            + [(.simulator, "Demo signal")]
    }

    public func connect(to source: DeviceSource, settings newSettings: ScopeSettings) {
        report(state: .connecting)
        queue.async { [self] in
            device?.close()
            device = nil
            settings = newSettings

            do {
                let scope: ScopeDevice
                switch source {
                case .simulator:
                    scope = SimulatedDPScopeSE()
                case let .usb(location):
                    scope = try DPScopeSE(locationID: location)
                }

                let identity = try scope.identify()
                guard identity.hasPrefix("DPScope") else {
                    scope.close()
                    report(state: .failed(DPScopeError.notIdentified(identity).localizedDescription))
                    return
                }
                let (major, minor) = try scope.firmwareRevision()
                try scope.abort()
                device = scope

                supplyVoltage = (try? scope.measureSupplyVoltage()) ?? ScopeRecord.nominalSupply
                if !(4.0...5.6).contains(supplyVoltage) { supplyVoltage = ScopeRecord.nominalSupply }
                let measured = supplyVoltage
                callbackQueue.async { [onSupplyVoltage] in onSupplyVoltage?(measured) }

                report(state: .connected(identity: "DPScope SE \(major).\(minor)", source: source))
            } catch {
                device?.close()
                device = nil
                report(state: .failed(Self.describe(error)))
            }
        }
    }

    public func disconnect() {
        queue.async { [self] in
            generation += 1
            isRunning = false
            try? device?.abort()
            device?.close()
            device = nil
            report(running: false)
            report(state: .disconnected)
        }
    }

    // MARK: - Control

    public func update(settings newSettings: ScopeSettings) {
        queue.async { [self] in
            let modeChanged = newSettings.mode != settings.mode
            settings = newSettings
            if modeChanged { resetLog() }
        }
    }

    public func start() {
        queue.async { [self] in
            guard device != nil, !isRunning else { return }
            isRunning = true
            generation += 1
            let token = generation
            resetLog()
            report(running: true)
            step(token: token)
        }
    }

    public func stop() {
        queue.async { [self] in
            guard isRunning else { return }
            generation += 1
            isRunning = false
            try? device?.abort()
            report(running: false)
            report(status: "Stopped")
        }
    }

    public func acquireSingle() {
        queue.async { [self] in
            guard device != nil, !isRunning else { return }
            do {
                if let frame = try acquireScopeFrame() {
                    report(frame: frame)
                    report(status: "Single sweep")
                } else {
                    report(status: "No trigger")
                }
            } catch {
                handle(error)
            }
        }
    }

    public func clear() {
        queue.async { [self] in
            resetLog()
            report(frame: ScopeFrame(mode: settings.mode))
        }
    }

    /// Re-measures the supply rail, which every voltage reading is scaled by.
    public func recalibrate() {
        queue.async { [self] in
            guard let device else { return }
            guard let measured = try? device.measureSupplyVoltage(), (4.0...5.6).contains(measured) else {
                report(status: "Supply measurement failed")
                return
            }
            supplyVoltage = measured
            callbackQueue.async { [onSupplyVoltage] in onSupplyVoltage?(measured) }
            report(status: String(format: "Supply %.3f V", measured))
        }
    }

    /// Averages the converter with the inputs grounded, so the offset trimmers'
    /// residual error stops showing up as a DC shift — especially on the ×10
    /// path, which amplifies it ten-fold.
    public func calibrateZero(samples: Int = 24) {
        queue.async { [self] in
            guard let device else { return }
            do {
                var totals = [0.0, 0.0, 0.0, 0.0]
                for _ in 0..<samples {
                    let (a, b) = try device.readADC(first: .channel1Gain1, second: .channel2Gain1,
                                                   adcon2: AcquisitionSetup.defaultADCON2)
                    let (c, d) = try device.readADC(first: .channel1Gain10, second: .channel2Gain10,
                                                    adcon2: AcquisitionSetup.defaultADCON2)
                    totals[0] += Double(a)
                    totals[2] += Double(b)
                    totals[1] += Double(c)
                    totals[3] += Double(d)
                }
                let count = Double(samples)
                let result = (totals[0] / count, totals[1] / count, totals[2] / count, totals[3] / count)
                callbackQueue.async { [onZeroCalibration] in onZeroCalibration?(result) }
                report(status: String(format: "Zero: Ch1 %.0f/%.0f, Ch2 %.0f/%.0f",
                                      result.0, result.1, result.2, result.3))
            } catch {
                handle(error)
            }
        }
    }

    private func resetLog() {
        logChannel1.removeAll(keepingCapacity: true)
        logChannel2.removeAll(keepingCapacity: true)
        logStart = Date()
        logSampleCount = 0
    }

    private func step(token: Int) {
        guard token == generation, isRunning, device != nil else { return }

        let started = Date()
        var nextDelay = Self.minimumFramePeriod
        do {
            switch settings.mode {
            case .scope:
                if let frame = try acquireScopeFrame() {
                    report(frame: frame)
                    report(status: frame.isTriggered ? "Running" : "Auto")
                } else {
                    report(status: "Waiting for trigger…")
                }
            case .datalog:
                let frame = try acquireDatalogSample()
                report(frame: frame)
                report(status: "Logging \(logSampleCount) points")
                nextDelay = max(settings.timebase.sampleInterval, 0.02)
            }
        } catch {
            handle(error)
            return
        }

        let elapsed = Date().timeIntervalSince(started)
        queue.asyncAfter(deadline: .now() + max(nextDelay - elapsed, 0.001)) { [self] in
            step(token: token)
        }
    }

    // MARK: - Acquisition

    private func acquireScopeFrame() throws -> ScopeFrame? {
        guard device != nil else { throw DPScopeError.notConnected }
        guard settings.hasEnabledChannel else { return ScopeFrame(mode: .scope) }

        let averaging = settings.effectiveAveraging
        var sum1: [Double] = []
        var sum2: [Double] = []
        var triggered = true
        var clipped1 = false
        var clipped2 = false

        for _ in 0..<averaging {
            guard let capture = try captureOnce() else { return nil }
            triggered = triggered && capture.isTriggered
            clipped1 = clipped1 || capture.channel1Clipped
            clipped2 = clipped2 || capture.channel2Clipped
            sum1 = Self.accumulate(sum1, capture.channel1)
            sum2 = Self.accumulate(sum2, capture.channel2)
        }

        let divisor = Double(averaging)
        return ScopeFrame(
            channel1: sum1.map { $0 / divisor },
            channel2: sum2.map { $0 / divisor },
            sampleInterval: settings.timebase.sampleInterval,
            mode: .scope,
            isTriggered: triggered,
            channel1Clipped: clipped1,
            channel2Clipped: clipped2
        )
    }

    /// A run of samples sitting on 0 or 255 means the front end ran out of
    /// range — usually the offset trimmer on the ×10 path, which no software
    /// calibration can undo.
    static func isClipped(_ samples: [UInt8], threshold: Int = 3) -> Bool {
        var low = 0
        var high = 0
        for sample in samples {
            if sample == 0 { low += 1 } else if sample == 255 { high += 1 }
            if low >= threshold || high >= threshold { return true }
        }
        return false
    }

    private static func accumulate(_ total: [Double], _ addition: [Double]) -> [Double] {
        guard !total.isEmpty, total.count == addition.count else { return addition }
        return zip(total, addition).map(+)
    }

    private func captureOnce() throws -> ScopeFrame? {
        // Auto mode still triggers whenever it can — that is what keeps a
        // repetitive signal standing still — and only sweeps free when nothing
        // crosses the threshold in time. Arming without the trigger, as this
        // used to, starts every sweep at a different phase, and the traces
        // smear into each other on screen.
        if settings.trigger.mode == .normal || settings.requiresTrigger {
            return try capture(waitingForTrigger: true, patience: Self.triggerPatience)
        }
        if let triggered = try capture(waitingForTrigger: true, patience: Self.autoTriggerPatience) {
            return triggered
        }
        return try capture(waitingForTrigger: false, patience: Self.triggerPatience)
    }

    private func capture(waitingForTrigger: Bool, patience: Double) throws -> ScopeFrame? {
        guard let device else { throw DPScopeError.notConnected }

        let timebase = settings.timebase
        var setup = settings.acquisitionSetup()
        setup.waitsForTrigger = waitingForTrigger
        try device.arm(setup)

        let expected = timebase.mode == .equivalentTime
            ? Double(ScopeRecord.sampleCount) * 5e-3
            : timebase.recordDuration
        let deadline = Date().addingTimeInterval(expected + patience)
        let pollInterval = min(max(expected / 20, 0.001), 0.05)

        var finished = false
        while Date() < deadline {
            if try device.isAcquisitionDone() { finished = true; break }
            Thread.sleep(forTimeInterval: pollInterval)
        }

        guard finished else {
            try device.abort()
            return nil
        }

        let record = try device.readRecord()
        try device.abort()

        return ScopeFrame(
            channel1: settings.channel1.isEnabled
                ? record.channel1.map { settings.channel1.volts(sample: $0, supply: supplyVoltage) }
                : [],
            channel2: settings.channel2.isEnabled
                ? record.channel2.map { settings.channel2.volts(sample: $0, supply: supplyVoltage) }
                : [],
            sampleInterval: timebase.sampleInterval,
            mode: .scope,
            isTriggered: waitingForTrigger,
            channel1Clipped: settings.channel1.isEnabled && Self.isClipped(record.channel1),
            channel2Clipped: settings.channel2.isEnabled && Self.isClipped(record.channel2)
        )
    }

    /// Data-log mode reads the converter directly, which keeps all 10 bits.
    private func acquireDatalogSample() throws -> ScopeFrame {
        guard let device else { throw DPScopeError.notConnected }
        let (first, second) = try device.readADC(
            first: settings.channel1.range.path.adcChannel(forChannel: 0),
            second: settings.channel2.range.path.adcChannel(forChannel: 1),
            adcon2: AcquisitionSetup.defaultADCON2
        )

        logChannel1.append(settings.channel1.volts(rawCode: first, supply: supplyVoltage))
        logChannel2.append(settings.channel2.volts(rawCode: second, supply: supplyVoltage))
        logSampleCount += 1

        if logChannel1.count > Self.datalogCapacity {
            let excess = logChannel1.count - Self.datalogCapacity
            logChannel1.removeFirst(excess)
            logChannel2.removeFirst(excess)
        }

        let span = Date().timeIntervalSince(logStart)
        let interval = logChannel1.count > 1 ? span / Double(logChannel1.count - 1) : 0.02

        return ScopeFrame(
            channel1: settings.channel1.isEnabled ? logChannel1 : [],
            channel2: settings.channel2.isEnabled ? logChannel2 : [],
            sampleInterval: interval,
            mode: .datalog,
            isTriggered: true
        )
    }

    // MARK: - Reporting

    private func handle(_ error: Error) {
        generation += 1
        isRunning = false
        report(running: false)
        report(error: Self.describe(error))

        if let scopeError = error as? DPScopeError, scopeError == .disconnected {
            device?.close()
            device = nil
            report(state: .disconnected)
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func report(frame: ScopeFrame) {
        callbackQueue.async { [onFrame] in onFrame?(frame) }
    }

    private func report(state: ConnectionState) {
        callbackQueue.async { [onStateChange] in onStateChange?(state) }
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
