import Foundation

/// The PIC's ADC inputs, as wired on the DPScope SE board.
///
/// Confirmed against the V1.1 schematic and by reading every channel on real
/// hardware: the ×10 readings track the ×1 readings amplified ten-fold.
public enum ADCChannel: UInt8, CaseIterable, Sendable {
    case channel1Gain1 = 5    // AN5  — OP1.1 buffer, comparator input C12IN1-
    case channel1Gain10 = 6   // AN6  — OP1.2 ×10.06, comparator input C12IN2-
    case externalTrigger = 7  // AN7  — comparator input C12IN3-
    case channel2Gain1 = 8    // AN8  — OP1.3 buffer
    case channel2Gain10 = 9   // AN9  — OP1.4 ×10.06
    case fixedReference = 15  // 4.096 V reference, used to measure the supply
}

/// Which analogue signal the trigger comparator watches (`CMD_ARM` byte 19).
public enum TriggerChannel: UInt8, CaseIterable, Sendable {
    case channel1Gain1 = 1
    case channel1Gain10 = 2
    case external = 3
}

/// Timer0 prescaler selection (`CMD_ARM` bytes 6 and 7).
public enum Prescaler: Sendable, Equatable {
    case bypassed
    /// Divider of `2^(power + 1)`: 0 = ÷2 … 7 = ÷256.
    case power(UInt8)

    public var divider: Double {
        switch self {
        case .bypassed: return 1
        case let .power(value): return pow(2, Double(value) + 1)
        }
    }

    public var bypassByte: UInt8 { self == .bypassed ? 1 : 0 }

    public var powerByte: UInt8 {
        if case let .power(value) = self { return value }
        return 0
    }
}

/// Everything `CMD_ARM` carries, in one value.
public struct AcquisitionSetup: Sendable, Equatable {
    public var firstChannel: ADCChannel
    public var secondChannel: ADCChannel
    /// ADCON2: `128 + ACQT * 8 + ADCS`.
    public var adcon2: UInt8
    /// Timer0 is preloaded with this and counts up to 65536.
    public var timerPreload: UInt16
    public var prescaler: Prescaler
    public var firstShift: UInt8
    public var secondShift: UInt8
    public var firstSubtract: UInt8
    public var secondSubtract: UInt8
    /// False runs free (auto trigger), true waits for the trigger condition.
    public var waitsForTrigger: Bool
    public var risingEdge: Bool
    public var triggerLevel: UInt8
    public var equivalentTime: Bool
    /// Equivalent-time sample interval, in 0.5 µs steps.
    public var equivalentTimeInterval: UInt8
    public var equivalentTimeStability: UInt8
    public var triggerChannel: TriggerChannel

    public init(
        firstChannel: ADCChannel = .channel1Gain1,
        secondChannel: ADCChannel = .channel2Gain1,
        adcon2: UInt8 = AcquisitionSetup.defaultADCON2,
        timerPreload: UInt16 = 65_036,
        prescaler: Prescaler = .bypassed,
        firstShift: UInt8 = 2,
        secondShift: UInt8 = 2,
        firstSubtract: UInt8 = 0,
        secondSubtract: UInt8 = 0,
        waitsForTrigger: Bool = false,
        risingEdge: Bool = true,
        triggerLevel: UInt8 = 128,
        equivalentTime: Bool = false,
        equivalentTimeInterval: UInt8 = 0,
        equivalentTimeStability: UInt8 = 0,
        triggerChannel: TriggerChannel = .channel1Gain1
    ) {
        self.firstChannel = firstChannel
        self.secondChannel = secondChannel
        self.adcon2 = adcon2
        self.timerPreload = timerPreload
        self.prescaler = prescaler
        self.firstShift = firstShift
        self.secondShift = secondShift
        self.firstSubtract = firstSubtract
        self.secondSubtract = secondSubtract
        self.waitsForTrigger = waitsForTrigger
        self.risingEdge = risingEdge
        self.triggerLevel = triggerLevel
        self.equivalentTime = equivalentTime
        self.equivalentTimeInterval = equivalentTimeInterval
        self.equivalentTimeStability = equivalentTimeStability
        self.triggerChannel = triggerChannel
    }

    /// `ADCS = 2` (Fosc/32) with `ACQT = 5` (12 Tad) — the fastest setting that
    /// stays within the PIC's specification.
    public static let defaultADCON2: UInt8 = 128 + 5 * 8 + 2

    /// The 19 parameter bytes of `CMD_ARM`.
    public var parameterBytes: [UInt8] {
        [
            firstChannel.rawValue,
            secondChannel.rawValue,
            adcon2,
            UInt8(timerPreload >> 8),
            UInt8(timerPreload & 0xFF),
            prescaler.bypassByte,
            prescaler.powerByte,
            firstShift,
            secondShift,
            firstSubtract,
            secondSubtract,
            waitsForTrigger ? 1 : 0,
            risingEdge ? 1 : 0,
            0,                      // trigger level MSB — unused by the firmware
            triggerLevel,
            equivalentTime ? 1 : 0,
            equivalentTimeInterval,
            equivalentTimeStability,
            triggerChannel.rawValue,
        ]
    }

    /// Interval between two samples of the *same* channel.
    ///
    /// Timer0 paces individual conversions and the scope alternates between the
    /// two channels, so one sample pair costs two timer periods — plus the
    /// converter's own time, which the timer does not cover.
    public var sampleInterval: Double {
        AcquisitionSetup.timerPeriod(preload: timerPreload, prescaler: prescaler)
            + AcquisitionSetup.conversionOverhead
    }

    /// The PIC runs at 48 MHz, so Timer0 counts at Fosc/4.
    public static let instructionClock = 12_000_000.0

    /// Fixed cost of one sample pair on top of the timer period.
    ///
    /// Measured against known 220 Hz and 311 Hz square waves fed into both
    /// inputs, over timer periods from 20 µs to 2 ms: every acquisition ran
    /// long by the same amount, 9.80 µs on average (sd 0.42 µs, n = 35), with
    /// no dependence on the timer period. That matches the converter's own
    /// acquisition and conversion time for two channels at the default
    /// ADCON2 — so a different ADCON2 would shift this constant.
    ///
    /// Ignoring it makes the time axis wrong by the ratio of this constant to
    /// the timer period: a third at the fastest sweeps, and still 5% at 200 µs.
    public static let conversionOverhead = 9.8e-6

    static func timerPeriod(preload: UInt16, prescaler: Prescaler) -> Double {
        let ticks = Double(65_536 - Int(preload))
        return 2 * ticks * prescaler.divider / instructionClock
    }

    /// Timer settings for a requested per-sample interval, allowing for the
    /// converter's fixed cost.
    public static func timing(forSampleInterval interval: Double) -> (preload: UInt16, prescaler: Prescaler) {
        let wanted = max(interval - conversionOverhead, 0)
        for power in Int8(-1)...7 {
            let prescaler: Prescaler = power < 0 ? .bypassed : .power(UInt8(power))
            let ticks = (wanted * instructionClock / (2 * prescaler.divider)).rounded()
            if ticks >= 1, ticks <= 65_535 {
                return (UInt16(65_536 - Int(ticks)), prescaler)
            }
        }
        return (65_535, .bypassed)  // fastest the timer can go
    }
}

/// The instrument, as the rest of the application needs it.
///
/// Both the USB device (`DPScopeSE`) and the built-in demo device
/// (`SimulatedDPScopeSE`) implement this.
public protocol ScopeDevice: AnyObject {
    /// `CMD_PING` — answers "DPScope SE".
    func identify() throws -> String
    /// `CMD_REVISION` — (major, minor).
    func firmwareRevision() throws -> (UInt8, UInt8)
    /// `CMD_ARM` — programs every acquisition parameter and starts sampling.
    func arm(_ setup: AcquisitionSetup) throws
    /// `CMD_DONE` — has the acquisition finished?
    func isAcquisitionDone() throws -> Bool
    /// `CMD_ABORT` — disarm.
    func abort() throws
    /// `CMD_READBACK` — 64 bytes of the record: 32 interleaved sample pairs.
    func readBlock(_ index: UInt8) throws -> [UInt8]
    /// `CMD_READADC` — an immediate 10-bit reading of two channels.
    func readADC(first: ADCChannel, second: ADCChannel, adcon2: UInt8) throws -> (UInt16, UInt16)
    /// `CMD_STATUS_LED`.
    func setStatusLED(_ on: Bool) throws
    /// `CMD_READ_LA` — the four logic analyzer inputs in the high nibble of PORTB.
    func readLogicInputs() throws -> UInt8
    func close()
}

public extension ScopeDevice {
    /// Reads the whole record and splits it into the two channels.
    ///
    /// The record is 211 sample pairs: six full 32-pair blocks plus 19 pairs in
    /// the seventh. Both numbers were measured on hardware — the readback
    /// buffer turns to noise after them, and the acquisition time matches
    /// 2 × 211.5 conversions.
    func readRecord() throws -> (channel1: [UInt8], channel2: [UInt8]) {
        var first: [UInt8] = []
        var second: [UInt8] = []
        first.reserveCapacity(ScopeRecord.sampleCount)
        second.reserveCapacity(ScopeRecord.sampleCount)

        for index in 0..<ScopeRecord.blockCount {
            let block = try readBlock(UInt8(index))
            let pairs = min(ScopeRecord.pairsPerBlock, ScopeRecord.sampleCount - first.count)
            for pair in 0..<pairs where 2 * pair + 1 < block.count {
                first.append(block[2 * pair])
                second.append(block[2 * pair + 1])
            }
        }
        return (first, second)
    }

    /// Measures the supply rail through the 4.096 V reference.
    func measureSupplyVoltage() throws -> Double {
        let (reading, _) = try readADC(first: .fixedReference, second: .fixedReference, adcon2: AcquisitionSetup.defaultADCON2)
        guard reading > 0 else { return ScopeRecord.nominalSupply }
        return 4.096 * 1023.0 / Double(reading)
    }
}

/// Fixed properties of an SE acquisition record.
public enum ScopeRecord {
    /// Sample pairs the scope stores per acquisition.
    public static let sampleCount = 211
    /// Sample pairs in one 64-byte readback block.
    public static let pairsPerBlock = 32
    /// Blocks needed to read the whole record (the last one is partial).
    public static var blockCount: Int { (sampleCount + pairsPerBlock - 1) / pairsPerBlock }
    /// The reading the converter gives for 0 V in.
    public static let zeroCode = 512.0
    public static let nominalSupply = 5.0
}
