import Foundation

/// A synthetic DPScope SE, so the application is usable — and testable —
/// without hardware.
///
/// It follows the real command sequence: `arm` starts a virtual acquisition
/// that only finishes after the record's worth of time has passed, and the
/// readback blocks carry the same interleaved, digitally-scaled samples the
/// firmware produces.
public final class SimulatedDPScopeSE: ScopeDevice {
    public struct Signal: Sendable {
        public var frequency: Double
        public var amplitude: Double
        public var offset: Double
        public var isSquare: Bool

        public init(frequency: Double, amplitude: Double, offset: Double = 0, isSquare: Bool = false) {
            self.frequency = frequency
            self.amplitude = amplitude
            self.offset = offset
            self.isSquare = isSquare
        }
    }

    /// The demo signal on the two inputs, in volts at the probe tip.
    public var channel1Signal = Signal(frequency: 1_000, amplitude: 1.5)
    public var channel2Signal = Signal(frequency: 500, amplitude: 0.8, offset: 0.2, isSquare: true)
    public var noiseAmplitude = 0.004
    /// What the 4.096 V reference implies about the supply rail.
    public var supplyVoltage = 5.17
    /// When false, `arm` never finishes in normal-trigger mode.
    public var signalIsPresent = true

    private var setup = AcquisitionSetup()
    private var isArmed = false
    private var acquisitionFinishes = Date.distantFuture
    private var recordStartTime = 0.0
    private var record: (first: [UInt8], second: [UInt8]) = ([], [])
    private var isOpen = true
    private let epoch = Date()

    public init() {}

    public func close() { isOpen = false }

    private func check() throws {
        guard isOpen else { throw DPScopeError.disconnected }
    }

    // MARK: - Identity

    public func identify() throws -> String {
        try check()
        return "DPScope SE"
    }

    public func firmwareRevision() throws -> (UInt8, UInt8) {
        try check()
        return (1, 5)
    }

    // MARK: - Acquisition

    public func arm(_ setup: AcquisitionSetup) throws {
        try check()
        self.setup = setup
        isArmed = true

        let now = Date().timeIntervalSince(epoch)
        recordStartTime = setup.waitsForTrigger ? triggerTime(after: now) : now
        let duration = setup.equivalentTime
            ? Double(ScopeRecord.sampleCount) * 4e-3   // one trigger event per point
            : setup.sampleInterval * Double(ScopeRecord.sampleCount)
        acquisitionFinishes = Date().addingTimeInterval(duration)

        if setup.waitsForTrigger && !signalIsPresent {
            acquisitionFinishes = .distantFuture
        }
        record = buildRecord(startingAt: recordStartTime)
    }

    public func isAcquisitionDone() throws -> Bool {
        try check()
        guard isArmed else { return false }
        return Date() >= acquisitionFinishes
    }

    public func abort() throws {
        try check()
        isArmed = false
        acquisitionFinishes = .distantFuture
    }

    public func readBlock(_ index: UInt8) throws -> [UInt8] {
        try check()
        var block = [UInt8](repeating: 0, count: HIDTransport.reportSize)
        let first = Int(index) * ScopeRecord.pairsPerBlock
        for pair in 0..<ScopeRecord.pairsPerBlock {
            let sample = first + pair
            guard sample < record.first.count else { break }
            block[2 * pair] = record.first[sample]
            block[2 * pair + 1] = record.second[sample]
        }
        return block
    }

    public func readADC(first: ADCChannel, second: ADCChannel, adcon2: UInt8) throws -> (UInt16, UInt16) {
        try check()
        let now = Date().timeIntervalSince(epoch)
        return (rawCode(of: first, at: now), rawCode(of: second, at: now))
    }

    public func setStatusLED(_ on: Bool) throws { try check() }

    public func readLogicInputs() throws -> UInt8 {
        try check()
        // Two of the four inputs wiggle so the readout has something to show.
        let phase = Date().timeIntervalSince(epoch)
        let bits: UInt8 = (sin(phase * 3) > 0 ? 0x10 : 0) | (sin(phase * 7) > 0 ? 0x20 : 0)
        return bits
    }

    // MARK: - Signal generation

    private func signal(for channel: ADCChannel) -> Signal? {
        switch channel {
        case .channel1Gain1, .channel1Gain10: return channel1Signal
        case .channel2Gain1, .channel2Gain10: return channel2Signal
        case .externalTrigger: return Signal(frequency: 100, amplitude: 0.5)
        case .fixedReference: return nil
        }
    }

    private func path(for channel: ADCChannel) -> InputPath {
        switch channel {
        case .channel1Gain10, .channel2Gain10: return .gain10
        default: return .gain1
        }
    }

    private func volts(_ signal: Signal, at time: Double) -> Double {
        let phase = time * signal.frequency
        let shape = signal.isSquare
            ? (phase - phase.rounded(.down) < 0.5 ? 1.0 : -1.0)
            : sin(2 * .pi * phase)
        return signal.offset + signal.amplitude * shape + noiseAmplitude * Double.random(in: -1...1)
    }

    private func rawCode(of channel: ADCChannel, at time: Double) -> UInt16 {
        guard let signal = signal(for: channel) else {
            // The fixed reference reads 4.096 V against the supply rail.
            return UInt16((4.096 / supplyVoltage * 1023).rounded())
        }
        let node = volts(signal, at: time) * FrontEnd.attenuation(path(for: channel))
        let code = ScopeRecord.zeroCode + node * 1023.0 / supplyVoltage
        return UInt16(min(max(code.rounded(), 0), 1023))
    }

    /// Applies the firmware's `(raw − 2 × subtract) >> shift` scaling.
    private func store(_ raw: UInt16, shift: UInt8, subtract: UInt8) -> UInt8 {
        let scaled = (Int(raw) - 2 * Int(subtract)) >> Int(shift)
        return UInt8(min(max(scaled, 0), 255))
    }

    private func buildRecord(startingAt start: Double) -> (first: [UInt8], second: [UInt8]) {
        let interval = setup.equivalentTime
            ? Double(setup.equivalentTimeInterval) * 0.5e-6
            : setup.sampleInterval

        var first: [UInt8] = []
        var second: [UInt8] = []
        first.reserveCapacity(ScopeRecord.sampleCount)
        second.reserveCapacity(ScopeRecord.sampleCount)

        for index in 0..<ScopeRecord.sampleCount {
            let time = start + Double(index) * interval
            first.append(store(rawCode(of: setup.firstChannel, at: time), shift: setup.firstShift, subtract: setup.firstSubtract))
            // The two channels are converted one after the other.
            let secondTime = time + interval / 2
            second.append(store(rawCode(of: setup.secondChannel, at: secondTime), shift: setup.secondShift, subtract: setup.secondSubtract))
        }
        return (first, second)
    }

    /// Finds the next moment the trigger channel crosses the threshold, so a
    /// triggered sweep stands still the way it does on real hardware.
    private func triggerTime(after now: Double) -> Double {
        let channel: ADCChannel
        switch setup.triggerChannel {
        case .channel1Gain1: channel = .channel1Gain1
        case .channel1Gain10: channel = .channel1Gain10
        case .external: channel = .externalTrigger
        }
        guard let signal = signal(for: channel), signal.amplitude > 0 else { return now }

        // Threshold at the amplifier output, converted back to input volts.
        let thresholdNode = (Double(setup.triggerLevel) / 255.0 - 0.5) * supplyVoltage
        let threshold = thresholdNode / FrontEnd.attenuation(path(for: channel))
        let normalized = (threshold - signal.offset) / signal.amplitude
        guard normalized > -1, normalized < 1 else { return now }

        let period = 1 / signal.frequency
        var phase = asin(normalized) / (2 * .pi)
        if !setup.risingEdge { phase = 0.5 - phase }
        return (now / period).rounded(.down) * period + phase * period
    }
}
