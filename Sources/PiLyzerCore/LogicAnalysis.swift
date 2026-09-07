import Foundation

/// One thing a decoder recognised in a logic record.
public struct DecodedItem: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case data, control, error }

    public var start: Int
    public var end: Int
    public var text: String
    public var kind: Kind

    public var id: Int { start << 8 | (kind == .data ? 0 : kind == .control ? 1 : 2) }
}

public struct ChannelActivity: Equatable, Sendable, Identifiable {
    public var channel: Int
    public var transitions: Int
    public var frequency: Double?
    public var dutyCycle: Double?
    public var isIdle: Bool

    public var id: Int { channel }
}

public enum LogicParity: String, CaseIterable, Codable, Sendable {
    case none = "None"
    case even = "Even"
    case odd = "Odd"
}

public enum LogicDecoder: Equatable, Codable, Sendable {
    case none
    case uart(line: Int, baud: Double, dataBits: Int, parity: LogicParity)
    case spi(clock: Int, data: Int, select: Int?, clockIdleHigh: Bool, sampleOnSecondEdge: Bool)
    case i2c(clock: Int, data: Int)

    public var label: String {
        switch self {
        case .none: return "None"
        case .uart: return "UART"
        case .spi: return "SPI"
        case .i2c: return "I²C"
        }
    }
}

public enum LogicAnalysis {
    /// Per-channel summary: how busy each input is, and its rate when it looks
    /// periodic.
    public static func activity(of frame: LogicFrame) -> [ChannelActivity] {
        guard !frame.samples.isEmpty else { return [] }
        return (0..<frame.channelCount).map { channel in
            let mask = UInt8(1 << UInt8(channel))
            var transitions = 0
            var high = 0
            var risingEdges: [Int] = []
            var previous = frame.samples[0] & mask != 0
            if previous { high += 1 }

            for index in 1..<frame.samples.count {
                let level = frame.samples[index] & mask != 0
                if level { high += 1 }
                if level != previous {
                    transitions += 1
                    if level { risingEdges.append(index) }
                    previous = level
                }
            }

            var frequency: Double?
            if risingEdges.count >= 2, frame.samplePeriod > 0 {
                let span = Double(risingEdges[risingEdges.count - 1] - risingEdges[0])
                let period = span / Double(risingEdges.count - 1) * frame.samplePeriod
                if period > 0 { frequency = 1 / period }
            }

            return ChannelActivity(channel: channel, transitions: transitions,
                                   frequency: frequency,
                                   dutyCycle: Double(high) / Double(frame.samples.count),
                                   isIdle: transitions == 0)
        }
    }

    /// Positions where a channel changes level, which is what the display uses
    /// to draw the trace and what the cursors snap to.
    public static func transitions(of frame: LogicFrame, channel: Int) -> [Int] {
        guard !frame.samples.isEmpty else { return [] }
        let mask = UInt8(1 << UInt8(channel))
        var result: [Int] = []
        var previous = frame.samples[0] & mask != 0
        for index in 1..<frame.samples.count {
            let level = frame.samples[index] & mask != 0
            if level != previous { result.append(index); previous = level }
        }
        return result
    }

    public static func decode(_ frame: LogicFrame, using decoder: LogicDecoder) -> [DecodedItem] {
        switch decoder {
        case .none:
            return []
        case let .uart(line, baud, dataBits, parity):
            return decodeUART(frame, line: line, baud: baud, dataBits: dataBits, parity: parity)
        case let .spi(clock, data, select, clockIdleHigh, sampleOnSecondEdge):
            return decodeSPI(frame, clock: clock, data: data, select: select,
                             clockIdleHigh: clockIdleHigh, sampleOnSecondEdge: sampleOnSecondEdge)
        case let .i2c(clock, data):
            return decodeI2C(frame, clock: clock, data: data)
        }
    }

    private static func printable(_ value: Int) -> String {
        let byte = UInt8(truncatingIfNeeded: value)
        let hex = String(format: "0x%02X", value)
        guard byte >= 0x20, byte < 0x7F else { return hex }
        return "\(hex) '\(Character(UnicodeScalar(byte)))'"
    }

    // MARK: - UART

    private static func decodeUART(_ frame: LogicFrame, line: Int, baud: Double,
                                   dataBits: Int, parity: LogicParity) -> [DecodedItem] {
        guard baud > 0, frame.samplePeriod > 0, !frame.samples.isEmpty else { return [] }
        let samplesPerBit = 1 / (baud * frame.samplePeriod)
        guard samplesPerBit >= 2 else {
            return [DecodedItem(start: 0, end: frame.samples.count - 1,
                                text: "sample rate too low for \(Int(baud)) baud", kind: .error)]
        }

        let mask = UInt8(1 << UInt8(line))
        func level(_ index: Int) -> Bool {
            let clamped = min(max(index, 0), frame.samples.count - 1)
            return frame.samples[clamped] & mask != 0
        }
        func level(at position: Double) -> Bool { level(Int(position.rounded())) }

        var items: [DecodedItem] = []
        var index = 1
        let bitCount = max(min(dataBits, 9), 5)

        while index < frame.samples.count - 1 {
            guard level(index - 1), !level(index) else { index += 1; continue }

            let startEdge = Double(index)
            let frameBits = 1 + bitCount + (parity == .none ? 0 : 1) + 1
            let frameEnd = startEdge + Double(frameBits) * samplesPerBit
            guard Int(frameEnd) < frame.samples.count else { break }

            // Bits are read in the middle, where the line has settled.
            var value = 0
            var ones = 0
            for bit in 0..<bitCount {
                let position = startEdge + samplesPerBit * (Double(bit) + 1.5)
                if level(at: position) { value |= 1 << bit; ones += 1 }
            }

            var isValid = true
            var offset = Double(bitCount) + 1.5
            if parity != .none {
                let bit = level(at: startEdge + samplesPerBit * offset)
                if bit { ones += 1 }
                isValid = (parity == .even) ? (ones % 2 == 0) : (ones % 2 == 1)
                offset += 1
            }
            let stop = level(at: startEdge + samplesPerBit * offset)
            let end = Int(frameEnd)

            if !stop {
                items.append(DecodedItem(start: index, end: end, text: "framing error", kind: .error))
            } else if !isValid {
                items.append(DecodedItem(start: index, end: end,
                                         text: "\(printable(value)) parity", kind: .error))
            } else {
                items.append(DecodedItem(start: index, end: end, text: printable(value), kind: .data))
            }
            index = end
        }
        return items
    }

    // MARK: - SPI

    private static func decodeSPI(_ frame: LogicFrame, clock: Int, data: Int, select: Int?,
                                  clockIdleHigh: Bool, sampleOnSecondEdge: Bool) -> [DecodedItem] {
        guard frame.samples.count > 1 else { return [] }
        let clockMask = UInt8(1 << UInt8(clock))
        let dataMask = UInt8(1 << UInt8(data))
        let selectMask = select.map { UInt8(1 << UInt8($0)) }

        // With CPHA = 0 the data is read on the first clock edge away from
        // idle, and with CPHA = 1 on the second.
        let sampleRising = clockIdleHigh == sampleOnSecondEdge

        var items: [DecodedItem] = []
        var value = 0
        var bits = 0
        var startIndex = 0
        var previousClock = frame.samples[0] & clockMask != 0

        for index in 1..<frame.samples.count {
            let sample = frame.samples[index]
            if let selectMask, sample & selectMask != 0 {
                if bits > 0 {
                    items.append(DecodedItem(start: startIndex, end: index,
                                             text: "\(printable(value)) (\(bits) bits)", kind: .error))
                }
                bits = 0
                value = 0
                previousClock = sample & clockMask != 0
                continue
            }

            let clockLevel = sample & clockMask != 0
            let edge = clockLevel != previousClock && clockLevel == sampleRising
            previousClock = clockLevel
            guard edge else { continue }

            if bits == 0 { startIndex = index }
            value = (value << 1) | (sample & dataMask != 0 ? 1 : 0)
            bits += 1
            if bits == 8 {
                items.append(DecodedItem(start: startIndex, end: index, text: printable(value), kind: .data))
                bits = 0
                value = 0
            }
        }
        return items
    }

    // MARK: - I²C

    private static func decodeI2C(_ frame: LogicFrame, clock: Int, data: Int) -> [DecodedItem] {
        guard frame.samples.count > 1 else { return [] }
        let clockMask = UInt8(1 << UInt8(clock))
        let dataMask = UInt8(1 << UInt8(data))

        var items: [DecodedItem] = []
        var previous = frame.samples[0]
        var inFrame = false
        var bits = 0
        var value = 0
        var startIndex = 0
        var expectingAddress = false

        for index in 1..<frame.samples.count {
            let sample = frame.samples[index]
            let clockHigh = sample & clockMask != 0
            let clockWasHigh = previous & clockMask != 0
            let dataHigh = sample & dataMask != 0
            let dataWasHigh = previous & dataMask != 0

            // START and STOP are the only times the data line moves while the
            // clock is high.
            if clockHigh && clockWasHigh && dataWasHigh && !dataHigh {
                items.append(DecodedItem(start: index, end: index, text: "START", kind: .control))
                inFrame = true
                expectingAddress = true
                bits = 0
                value = 0
            } else if clockHigh && clockWasHigh && !dataWasHigh && dataHigh {
                items.append(DecodedItem(start: index, end: index, text: "STOP", kind: .control))
                inFrame = false
                bits = 0
                value = 0
            } else if inFrame && clockHigh && !clockWasHigh {
                if bits == 0 { startIndex = index }
                if bits < 8 {
                    value = (value << 1) | (dataHigh ? 1 : 0)
                    bits += 1
                } else {
                    let acknowledged = !dataHigh
                    let text: String
                    if expectingAddress {
                        text = String(format: "addr 0x%02X %@ %@", value >> 1,
                                      value & 1 == 1 ? "read" : "write",
                                      acknowledged ? "ACK" : "NAK")
                        expectingAddress = false
                    } else {
                        text = "\(printable(value)) \(acknowledged ? "ACK" : "NAK")"
                    }
                    items.append(DecodedItem(start: startIndex, end: index, text: text,
                                             kind: acknowledged ? .data : .error))
                    bits = 0
                    value = 0
                }
            }
            previous = sample
        }
        return items
    }
}
