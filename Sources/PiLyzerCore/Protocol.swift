import Foundation

/// The PiLyzer wire protocol, as described in `docs/protocol.md`.
///
/// Nothing in here describes a register of any particular microcontroller. The
/// host asks for a sample period, a record length and a trigger condition; the
/// instrument answers with what it will actually do, and every axis the
/// application draws is labelled from that answer.
public enum Wire {
    public static let requestMagic: UInt8 = 0xA5
    public static let responseMagic: UInt8 = 0x5A
    public static let identityMagic: UInt32 = 0x5A59_4C50   // "PLYZ"
    public static let version: UInt16 = 1
    public static let headerSize = 12
    public static let maxPayload = 8192

    /// pid.codes 1209:0001, the identifier set aside for prototypes.
    public static let vendorID: UInt16 = 0x1209
    public static let productID: UInt16 = 0x0001

    /// Raspberry Pi's own identifier, which a board carries before this
    /// firmware is on it — including while it sits in its bootloader.
    public static let raspberryPiVendorID: UInt16 = 0x2E8A
    /// RP2040 and RP2350 in BOOTSEL.
    public static let bootloaderProductIDs: Set<UInt16> = [0x0003, 0x000F]
}

public enum Opcode: UInt8, Sendable {
    case identify = 0x01
    case capabilities = 0x02
    case setLED = 0x03
    case setRange = 0x04
    case setCalibrationOutput = 0x05
    case rebootToBootloader = 0x06

    case analogConfigure = 0x10
    case analogArm = 0x11
    case analogStatus = 0x12
    case analogRead = 0x13
    case analogAbort = 0x14
    case analogSample = 0x15

    case logicConfigure = 0x20
    case logicArm = 0x21
    case logicStatus = 0x22
    case logicRead = 0x23
    case logicAbort = 0x24
}

public enum WireStatus: UInt8, Sendable {
    case ok = 0
    case unknownOpcode = 1
    case badLength = 2
    case badArgument = 3
    case busy = 4
    case notConfigured = 5
    case noData = 6
    case internalError = 7

    public var description: String {
        switch self {
        case .ok: return "OK"
        case .unknownOpcode: return "the instrument does not know that command"
        case .badLength: return "the instrument rejected the packet length"
        case .badArgument: return "the instrument rejected a parameter"
        case .busy: return "an acquisition is already running"
        case .notConfigured: return "armed before being configured"
        case .noData: return "no record has been captured yet"
        case .internalError: return "the instrument reported an internal error"
        }
    }
}

public enum TriggerMode: UInt8, CaseIterable, Codable, Sendable {
    case freeRun = 0
    case auto = 1
    case normal = 2

    public var label: String {
        switch self {
        case .freeRun: return "Free"
        case .auto: return "Auto"
        case .normal: return "Normal"
        }
    }
}

public enum TriggerSlope: UInt8, CaseIterable, Codable, Sendable {
    case rising = 0
    case falling = 1

    public var label: String { self == .rising ? "Rising" : "Falling" }
}

public enum AcquisitionState: UInt8, Sendable {
    case idle = 0
    case filling = 1
    case waiting = 2
    case postTrigger = 3
    case complete = 4
    case aborted = 5
    case overrun = 6
}

// MARK: - Structures

public struct DeviceIdentity: Equatable, Sendable {
    public var protocolVersion: UInt16
    public var firmwareVersion: UInt16
    public var boardID: UInt32
    public var name: String

    public var firmwareDescription: String {
        "\(firmwareVersion >> 8).\(firmwareVersion & 0xFF)"
    }

    /// 0 is a bare Pico 2 with the inputs straight on the converter pins; any
    /// other value is a front end that scales and shifts them.
    public var hasFrontEnd: Bool { boardID != 0 }
}

public struct DeviceCapabilities: Equatable, Sendable {
    public var analogChannels: Int
    public var analogBits: Int
    public var logicChannels: Int
    public var analogRanges: Int
    public var analogClockHz: UInt32
    public var analogMinPeriodCycles: UInt32
    public var analogMaxRecord: Int
    public var analogMaxPretrigger: Int
    public var logicClockHz: UInt32
    public var logicMaxRecord: Int
    public var logicMaxPretrigger: Int
    public var referenceVolts: Double
    public var flags: UInt32

    public var hasSoftwareRanges: Bool { flags & 1 != 0 }
    public var hasCalibrationOutput: Bool { flags & 2 != 0 }
    public var hasTriggerLowPass: Bool { flags & 8 != 0 }

    /// Samples arrive left-aligned in 16 bits, so this is the value a reading
    /// at the top of the converter's range comes back as.
    public var analogFullScale: Double {
        Double(((1 << analogBits) - 1) << (16 - analogBits))
    }

    /// Shortest interval between two conversions, in seconds.
    public var minimumConversionPeriod: Double {
        Double(analogMinPeriodCycles) / Double(analogClockHz)
    }

    /// Shortest interval between two samples of one channel.
    public func minimumSamplePeriod(channels: Int) -> Double {
        minimumConversionPeriod * Double(max(channels, 1))
    }

    public static let unavailable = DeviceCapabilities(
        analogChannels: 2, analogBits: 12, logicChannels: 8, analogRanges: 1,
        analogClockHz: 48_000_000, analogMinPeriodCycles: 96,
        analogMaxRecord: 16384, analogMaxPretrigger: 16383,
        logicClockHz: 150_000_000, logicMaxRecord: 65536, logicMaxPretrigger: 65535,
        referenceVolts: 3.3, flags: 0)
}

/// What the instrument said it would actually do.
public struct AcquisitionPlan: Equatable, Sendable {
    public var clockHz: UInt32
    public var divisorQ8: UInt32
    public var decimation: UInt32
    public var recordSamples: Int
    public var pretriggerSamples: Int
    public var channelMask: UInt8
    public var conversionsPerSample: Int

    /// The interval the time axis is drawn with. Exact: the divisor is the
    /// hardware register, not a rounded number of nanoseconds.
    public var samplePeriod: Double {
        Double(divisorQ8) / 256.0 / Double(clockHz)
            * Double(max(conversionsPerSample, 1)) * Double(max(decimation, 1))
    }

    public var sampleRate: Double { samplePeriod > 0 ? 1 / samplePeriod : 0 }
    public var duration: Double { samplePeriod * Double(recordSamples) }
    public var enabledChannels: [Int] { (0..<8).filter { channelMask & (1 << $0) != 0 } }

    public static let empty = AcquisitionPlan(clockHz: 1, divisorQ8: 256, decimation: 1,
                                              recordSamples: 0, pretriggerSamples: 0,
                                              channelMask: 0, conversionsPerSample: 1)
}

public struct AcquisitionStatus: Equatable, Sendable {
    public var state: AcquisitionState
    public var triggered: Bool
    public var samplesAvailable: Int
    public var triggerIndex: Int

    public var isFinished: Bool {
        state == .complete || state == .aborted || state == .overrun
    }
}

public struct AnalogConfiguration: Equatable, Sendable {
    public var channelMask: UInt8
    public var triggerMode: TriggerMode
    public var triggerSource: Int
    public var triggerSlope: TriggerSlope
    public var triggerLevel: UInt16
    public var triggerHysteresis: UInt16
    public var samplePeriod: Double
    public var recordSamples: Int
    public var pretriggerSamples: Int
    public var autoTimeout: Double
    /// Cutoff in Hz; zero bypasses the trigger-only filter.
    public var triggerLowPassHz: Int

    public init(channelMask: UInt8 = 0b11, triggerMode: TriggerMode = .auto,
                triggerSource: Int = 0, triggerSlope: TriggerSlope = .rising,
                triggerLevel: UInt16 = 32768, triggerHysteresis: UInt16 = 256,
                samplePeriod: Double = 1e-5, recordSamples: Int = 2000,
                pretriggerSamples: Int = 200, autoTimeout: Double = 0.1,
                triggerLowPassHz: Int = 0) {
        self.channelMask = channelMask
        self.triggerMode = triggerMode
        self.triggerSource = triggerSource
        self.triggerSlope = triggerSlope
        self.triggerLevel = triggerLevel
        self.triggerHysteresis = triggerHysteresis
        self.samplePeriod = samplePeriod
        self.recordSamples = recordSamples
        self.pretriggerSamples = pretriggerSamples
        self.autoTimeout = autoTimeout
        self.triggerLowPassHz = triggerLowPassHz
    }

    public var channels: Int {
        channelMask.nonzeroBitCount
    }

    public func encoded() -> Data {
        var writer = ByteWriter()
        writer.append(channelMask)
        writer.append(triggerMode.rawValue)
        writer.append(UInt8(clamping: triggerSource))
        writer.append(triggerSlope.rawValue)
        writer.append(triggerLevel)
        writer.append(triggerHysteresis)
        writer.append(UInt64(max(samplePeriod, 0) * 1e15))
        writer.append(UInt32(clamping: recordSamples))
        writer.append(UInt32(clamping: pretriggerSamples))
        writer.append(UInt32(clamping: Int(max(autoTimeout, 0) * 1e6)))
        writer.append(UInt32(clamping: triggerLowPassHz))
        return writer.data
    }
}

public struct LogicConfiguration: Equatable, Sendable {
    public var triggerMode: TriggerMode
    public var triggerChannel: Int
    public var triggerSlope: TriggerSlope
    public var samplePeriod: Double
    public var recordSamples: Int
    public var pretriggerSamples: Int
    public var autoTimeout: Double

    public init(triggerMode: TriggerMode = .auto, triggerChannel: Int = 0,
                triggerSlope: TriggerSlope = .rising, samplePeriod: Double = 1e-6,
                recordSamples: Int = 4096, pretriggerSamples: Int = 512,
                autoTimeout: Double = 0.1) {
        self.triggerMode = triggerMode
        self.triggerChannel = triggerChannel
        self.triggerSlope = triggerSlope
        self.samplePeriod = samplePeriod
        self.recordSamples = recordSamples
        self.pretriggerSamples = pretriggerSamples
        self.autoTimeout = autoTimeout
    }

    public func encoded() -> Data {
        var writer = ByteWriter()
        writer.append(triggerMode.rawValue)
        writer.append(UInt8(clamping: triggerChannel))
        writer.append(triggerSlope.rawValue)
        writer.append(UInt8(0))
        writer.append(UInt64(max(samplePeriod, 0) * 1e15))
        writer.append(UInt32(clamping: recordSamples))
        writer.append(UInt32(clamping: pretriggerSamples))
        writer.append(UInt32(clamping: Int(max(autoTimeout, 0) * 1e6)))
        return writer.data
    }
}

// MARK: - Little-endian helpers

public struct ByteWriter {
    public private(set) var data = Data()
    public init() {}
    public mutating func append(_ value: UInt8) { data.append(value) }
    public mutating func append(_ value: UInt16) { appendLittleEndian(value) }
    public mutating func append(_ value: UInt32) { appendLittleEndian(value) }
    public mutating func append(_ value: UInt64) { appendLittleEndian(value) }
    public mutating func append(bytes: [UInt8]) { data.append(contentsOf: bytes) }
    public mutating func append(_ text: String, padTo width: Int) {
        var utf8 = Array(text.utf8.prefix(width))
        utf8.append(contentsOf: [UInt8](repeating: 0, count: width - utf8.count))
        data.append(contentsOf: utf8)
    }

    private mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}

public struct ByteReader {
    private let bytes: [UInt8]
    private var index = 0

    public init(_ data: Data) { bytes = [UInt8](data) }
    public var remaining: Int { bytes.count - index }

    public mutating func uint8() -> UInt8 {
        guard index < bytes.count else { return 0 }
        defer { index += 1 }
        return bytes[index]
    }

    public mutating func uint16() -> UInt16 { integer() }
    public mutating func uint32() -> UInt32 { integer() }
    public mutating func uint64() -> UInt64 { integer() }

    public mutating func skip(_ count: Int) { index = min(index + count, bytes.count) }

    public mutating func string(_ count: Int) -> String {
        let end = min(index + count, bytes.count)
        let slice = bytes[index..<end].prefix { $0 != 0 }
        index = end
        return String(decoding: slice, as: UTF8.self)
    }

    private mutating func integer<T: FixedWidthInteger>() -> T {
        let width = MemoryLayout<T>.size
        guard index + width <= bytes.count else { index = bytes.count; return 0 }
        var value: T = 0
        for offset in (0..<width).reversed() {
            value = (value << 8) | T(bytes[index + offset])
        }
        index += width
        return value
    }
}

public extension DeviceIdentity {
    init?(_ data: Data) {
        guard data.count >= 32 else { return nil }
        var reader = ByteReader(data)
        guard reader.uint32() == Wire.identityMagic else { return nil }
        protocolVersion = reader.uint16()
        firmwareVersion = reader.uint16()
        boardID = reader.uint32()
        name = reader.string(20)
    }
}

public extension DeviceCapabilities {
    init?(_ data: Data) {
        guard data.count >= 48 else { return nil }
        var reader = ByteReader(data)
        analogChannels = Int(reader.uint8())
        analogBits = Int(reader.uint8())
        logicChannels = Int(reader.uint8())
        analogRanges = Int(reader.uint8())
        analogClockHz = reader.uint32()
        analogMinPeriodCycles = reader.uint32()
        analogMaxRecord = Int(reader.uint32())
        analogMaxPretrigger = Int(reader.uint32())
        logicClockHz = reader.uint32()
        logicMaxRecord = Int(reader.uint32())
        logicMaxPretrigger = Int(reader.uint32())
        referenceVolts = Double(reader.uint32()) / 1e6
        flags = reader.uint32()
    }
}

public extension AcquisitionPlan {
    init?(_ data: Data) {
        guard data.count >= 24 else { return nil }
        var reader = ByteReader(data)
        clockHz = reader.uint32()
        divisorQ8 = reader.uint32()
        decimation = reader.uint32()
        recordSamples = Int(reader.uint32())
        pretriggerSamples = Int(reader.uint32())
        channelMask = reader.uint8()
        conversionsPerSample = Int(reader.uint8())
    }
}

public extension AcquisitionStatus {
    init?(_ data: Data) {
        guard data.count >= 16 else { return nil }
        var reader = ByteReader(data)
        state = AcquisitionState(rawValue: reader.uint8()) ?? .idle
        triggered = reader.uint8() != 0
        _ = reader.uint16()
        samplesAvailable = Int(reader.uint32())
        triggerIndex = Int(reader.uint32())
    }
}
