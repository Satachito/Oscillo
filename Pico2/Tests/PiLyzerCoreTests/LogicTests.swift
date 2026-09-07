import Foundation
import Testing
@testable import PiLyzerCore

@Suite("Logic analysis")
struct LogicTests {
    private func frame(_ levels: [UInt8], rate: Double) -> LogicFrame {
        LogicFrame(samples: levels, samplePeriod: 1 / rate, triggerIndex: 0,
                   triggered: true, channelCount: 8)
    }

    // MARK: - UART

    private func uart(_ bytes: [UInt8], samplesPerBit: Int, line: Int) -> [UInt8] {
        var levels = [Bool](repeating: true, count: samplesPerBit * 4)
        for byte in bytes {
            var bits = [false]
            for index in 0..<8 { bits.append(byte & (1 << UInt8(index)) != 0) }
            bits.append(true)
            for bit in bits { levels += [Bool](repeating: bit, count: samplesPerBit) }
        }
        levels += [Bool](repeating: true, count: samplesPerBit * 4)
        return levels.map { $0 ? UInt8(1 << UInt8(line)) : 0 }
    }

    @Test("A UART line decodes back to the bytes that were sent")
    func uartDecode() {
        // 1.152 MS/s over 115200 baud is exactly ten samples a bit.
        let rate = 1_152_000.0
        let message: [UInt8] = Array("Pi2".utf8)
        let record = frame(uart(message, samplesPerBit: 10, line: 4), rate: rate)
        let items = LogicAnalysis.decode(record, using: .uart(line: 4, baud: 115_200,
                                                              dataBits: 8, parity: .none))
        let data = items.filter { $0.kind == .data }
        #expect(data.count == message.count)
        for (item, byte) in zip(data, message) {
            #expect(item.text.hasPrefix(String(format: "0x%02X", byte)))
        }
    }

    @Test("A UART decode below two samples a bit says so instead of guessing")
    func uartTooSlow() {
        let record = frame(uart([0x55], samplesPerBit: 10, line: 0), rate: 10_000)
        let items = LogicAnalysis.decode(record, using: .uart(line: 0, baud: 115_200,
                                                              dataBits: 8, parity: .none))
        #expect(items.count == 1)
        #expect(items[0].kind == .error)
    }

    // MARK: - SPI

    @Test("SPI bytes come back from clock and data lines")
    func spiDecode() {
        let bytes: [UInt8] = [0xA5, 0x3C]
        var levels: [UInt8] = [UInt8](repeating: 1 << 2, count: 8)      // chip select idle high
        for byte in bytes {
            for bit in (0..<8).reversed() {
                let data: UInt8 = (byte & (1 << UInt8(bit)) != 0) ? (1 << 1) : 0
                levels.append(data)                                      // clock low
                levels.append(data | 1)                                  // clock high: sampled here
            }
        }
        levels += [UInt8](repeating: 1 << 2, count: 8)

        let record = frame(levels, rate: 1_000_000)
        let items = LogicAnalysis.decode(record, using: .spi(clock: 0, data: 1, select: 2,
                                                             clockIdleHigh: false,
                                                             sampleOnSecondEdge: false))
        let data = items.filter { $0.kind == .data }
        #expect(data.count == 2)
        #expect(data.first?.text.hasPrefix("0xA5") == true)
        #expect(data.last?.text.hasPrefix("0x3C") == true)
    }

    // MARK: - I²C

    @Test("An I²C transfer decodes to its address, its data and its markers")
    func i2cDecode() {
        let clock: UInt8 = 1 << 0
        let data: UInt8 = 1 << 1
        var levels: [UInt8] = []

        func emit(_ scl: Bool, _ sda: Bool, times: Int = 2) {
            let value = (scl ? clock : 0) | (sda ? data : 0)
            levels += [UInt8](repeating: value, count: times)
        }
        func bit(_ value: Bool) {
            emit(false, value)
            emit(true, value)
        }

        emit(true, true, times: 4)
        emit(true, false, times: 2)                 // START: data falls while the clock is high
        for index in (0..<8).reversed() { bit((0x48 as UInt8) & (1 << UInt8(index)) != 0) }
        bit(false)                                  // acknowledge
        for index in (0..<8).reversed() { bit((0x2A as UInt8) & (1 << UInt8(index)) != 0) }
        bit(false)
        emit(true, false, times: 2)
        emit(true, true, times: 4)                  // STOP

        let record = frame(levels, rate: 1_000_000)
        let items = LogicAnalysis.decode(record, using: .i2c(clock: 0, data: 1))
        #expect(items.contains { $0.text == "START" })
        #expect(items.contains { $0.text == "STOP" })
        #expect(items.contains { $0.text.contains("addr 0x24") && $0.text.contains("write") })
        #expect(items.contains { $0.text.hasPrefix("0x2A") })
    }

    // MARK: - Activity

    @Test("Channel activity finds the rate of a square wave and notices a dead input")
    func activity() {
        let rate = 1_000_000.0
        let samples = (0..<1000).map { index -> UInt8 in
            // D0 toggles every 10 samples: 50 kHz. D1 never moves.
            (index / 10) % 2 == 0 ? 0 : 1
        }
        let record = frame(samples, rate: rate)
        let activity = LogicAnalysis.activity(of: record)

        let first = activity[0]
        let frequency = try! #require(first.frequency)
        #expect(abs(frequency - 50_000) < 500)
        #expect(abs((first.dutyCycle ?? 0) - 0.5) < 0.02)
        #expect(activity[1].isIdle)
        #expect(LogicAnalysis.transitions(of: record, channel: 0).count == 99)
    }
}
