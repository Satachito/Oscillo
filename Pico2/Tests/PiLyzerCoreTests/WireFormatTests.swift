import Foundation
import Testing
@testable import PiLyzerCore

/// The wire format is written twice — once here in Swift, once in
/// `Web/src/protocol.mjs` — so both are held to one shared fixture. A change on
/// either side that the other does not follow fails here and in the browser
/// application's `npm test`.
///
/// The fixture is written from `docs/protocol.md`, not recorded from either
/// implementation, so agreeing with it means agreeing with the document.
@Suite("Shared wire fixture")
struct WireFormatTests {
    struct Golden: Decodable {
        struct Header: Decodable { let opcode: UInt8, sequence: UInt16, payloadLength: Int, bytes: String }
        struct Analog: Decodable {
            let mask: UInt8, triggerMode: UInt8, triggerSlot: Int, triggerSlope: UInt8
            let level: UInt16, hysteresis: UInt16, periodFs: UInt64
            let record: Int, pretrigger: Int, timeoutUs: Int, lowPassHz: Int, bytes: String
        }
        struct Logic: Decodable {
            let triggerMode: UInt8, triggerChannel: Int, triggerSlope: UInt8, periodFs: UInt64
            let record: Int, pretrigger: Int, timeoutUs: Int, bytes: String
        }
        struct Range: Decodable {
            let switchPosition: Int, gainMicro: Int, offsetMicrovolts: Int, name: String, bytes: String
        }
        let requestHeaders: [Header]
        let analogConfigs: [Analog]
        let logicConfigs: [Logic]
        let inputRanges: [Range]
    }

    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()        // PiLyzerCoreTests
        .deletingLastPathComponent()        // Tests
        .deletingLastPathComponent()        // Pico2
        .appendingPathComponent("Web/tests/fixtures/wire-golden.json")

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    @Test("Every encoder matches the fixture the browser application also follows")
    func encodersMatchTheFixture() throws {
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: Self.url))
        #expect(!golden.analogConfigs.isEmpty && !golden.logicConfigs.isEmpty)

        for expected in golden.requestHeaders {
            let opcode = try #require(Opcode(rawValue: expected.opcode))
            let header = Wire.requestHeader(opcode: opcode, sequence: expected.sequence,
                                            payloadLength: expected.payloadLength)
            #expect(Self.hex(header) == expected.bytes, "request header for opcode \(expected.opcode)")
        }

        for expected in golden.analogConfigs {
            let mode = try #require(TriggerMode(rawValue: expected.triggerMode))
            let slope = try #require(TriggerSlope(rawValue: expected.triggerSlope))
            let configuration = AnalogConfiguration(
                channelMask: expected.mask, triggerMode: mode, triggerSource: expected.triggerSlot,
                triggerSlope: slope, triggerLevel: expected.level, triggerHysteresis: expected.hysteresis,
                samplePeriod: Double(expected.periodFs) / 1e15, recordSamples: expected.record,
                pretriggerSamples: expected.pretrigger, autoTimeout: Double(expected.timeoutUs) / 1e6,
                triggerLowPassHz: expected.lowPassHz)
            #expect(Self.hex(configuration.encoded()) == expected.bytes, "analogue configuration \(expected.bytes)")
        }

        for expected in golden.logicConfigs {
            let mode = try #require(TriggerMode(rawValue: expected.triggerMode))
            let slope = try #require(TriggerSlope(rawValue: expected.triggerSlope))
            let configuration = LogicConfiguration(
                triggerMode: mode, triggerChannel: expected.triggerChannel, triggerSlope: slope,
                samplePeriod: Double(expected.periodFs) / 1e15, recordSamples: expected.record,
                pretriggerSamples: expected.pretrigger, autoTimeout: Double(expected.timeoutUs) / 1e6)
            #expect(Self.hex(configuration.encoded()) == expected.bytes, "logic configuration \(expected.bytes)")
        }
    }

    @Test("An input range decodes to the same front end the browser application reads")
    func inputRangesDecodeFromTheFixture() throws {
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: Self.url))
        #expect(!golden.inputRanges.isEmpty)
        for expected in golden.inputRanges {
            let bytes = [UInt8](stride(from: 0, to: expected.bytes.count, by: 2).map {
                let start = expected.bytes.index(expected.bytes.startIndex, offsetBy: $0)
                let end = expected.bytes.index(start, offsetBy: 2)
                return UInt8(expected.bytes[start..<end], radix: 16)!
            })
            let range = try #require(InputRange(wire: bytes[...]), "could not decode \(expected.name)")
            #expect(range.name == expected.name)
            #expect(range.switchPosition == expected.switchPosition)
            #expect(abs(range.gain - Double(expected.gainMicro) / 1e6) < 1e-12)
            #expect(abs(range.offset - Double(expected.offsetMicrovolts) / 1e6) < 1e-12)
        }

        // The table the host falls back to for firmware that will not say must
        // agree with what newer firmware reports for the same board.
        let reported = golden.inputRanges.compactMap { expected -> InputRange? in
            let bytes = [UInt8](stride(from: 0, to: expected.bytes.count, by: 2).map {
                let start = expected.bytes.index(expected.bytes.startIndex, offsetBy: $0)
                let end = expected.bytes.index(start, offsetBy: 2)
                return UInt8(expected.bytes[start..<end], radix: 16)!
            })
            return InputRange(wire: bytes[...])
        }
        let revA = reported.filter { $0.name.hasPrefix("±") }
        #expect(revA == FrontEnd.revA)
        #expect(reported.filter { !$0.name.hasPrefix("±") } == FrontEnd.bareBoard)
    }

    /// The fixture is only worth having while both sides can still read it.
    @Test("The fixture lives where both projects can find it")
    func fixtureIsWhereBothSidesLookForIt() {
        #expect(FileManager.default.fileExists(atPath: Self.url.path),
                "expected the shared fixture at \(Self.url.path)")
    }
}
