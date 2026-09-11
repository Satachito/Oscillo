import Foundation
import Testing
@testable import PiLyzerCore

@Suite("Wire format")
struct ProtocolTests {
    @Test("An analogue configuration lands on the documented byte offsets")
    func analogConfigurationLayout() {
        let configuration = AnalogConfiguration(
            channelMask: 0b11, triggerMode: .normal, triggerSource: 1, triggerSlope: .falling,
            triggerLevel: 0x1234, triggerHysteresis: 0x0040,
            samplePeriod: 4e-6, recordSamples: 2000, pretriggerSamples: 200,
            autoTimeout: 0.1)
        let bytes = [UInt8](configuration.encoded())

        #expect(bytes.count == 32)
        #expect(bytes[0] == 0b11)
        #expect(bytes[1] == TriggerMode.normal.rawValue)
        #expect(bytes[2] == 1)
        #expect(bytes[3] == TriggerSlope.falling.rawValue)
        #expect(bytes[4] == 0x34 && bytes[5] == 0x12)
        #expect(bytes[6] == 0x40 && bytes[7] == 0x00)

        // 4 µs is 4_000_000_000 femtoseconds.
        var reader = ByteReader(Data(bytes[8..<16]))
        #expect(reader.uint64() == 4_000_000_000)

        var tail = ByteReader(Data(bytes[16..<32]))
        #expect(tail.uint32() == 2000)
        #expect(tail.uint32() == 200)
        #expect(tail.uint32() == 100_000)
    }

    @Test("A logic configuration is 24 bytes in the documented order")
    func logicConfigurationLayout() {
        let configuration = LogicConfiguration(triggerMode: .auto, triggerChannel: 3,
                                               triggerSlope: .rising, samplePeriod: 1e-8,
                                               recordSamples: 4096, pretriggerSamples: 512,
                                               autoTimeout: 0.25)
        let bytes = [UInt8](configuration.encoded())
        #expect(bytes.count == 24)
        #expect(bytes[1] == 3)
        var reader = ByteReader(Data(bytes[4..<24]))
        #expect(reader.uint64() == 10_000_000)
        #expect(reader.uint32() == 4096)
        #expect(reader.uint32() == 512)
        #expect(reader.uint32() == 250_000)
    }

    @Test("The plan's sample period is exact, not a rounded number of nanoseconds")
    func planTiming() {
        // 96 converter clocks at 48 MHz is 2 µs; two channels and no decimation
        // make one sample per channel every 4 µs.
        let plan = AcquisitionPlan(clockHz: 48_000_000, divisorQ8: 96 * 256, decimation: 1,
                                   recordSamples: 1000, pretriggerSamples: 100,
                                   channelMask: 0b11, conversionsPerSample: 2)
        #expect(abs(plan.samplePeriod - 4e-6) < 1e-15)
        #expect(abs(plan.sampleRate - 250_000) < 1e-6)
        #expect(abs(plan.duration - 4e-3) < 1e-12)

        // Decimating by 2500 is what a 10 ms sweep point costs.
        let slow = AcquisitionPlan(clockHz: 48_000_000, divisorQ8: 96 * 256, decimation: 2500,
                                   recordSamples: 1000, pretriggerSamples: 100,
                                   channelMask: 0b11, conversionsPerSample: 2)
        #expect(abs(slow.samplePeriod - 0.01) < 1e-12)
    }

    @Test("Structures decode from the bytes the firmware sends")
    func decoding() {
        var writer = ByteWriter()
        writer.append(Wire.identityMagic)
        writer.append(UInt16(1))
        writer.append(UInt16(0x0100))
        writer.append(UInt32(1))
        writer.append("PiLyzer Pico 2", padTo: 20)

        let identity = DeviceIdentity(writer.data)
        #expect(identity?.name == "PiLyzer Pico 2")
        #expect(identity?.firmwareDescription == "1.0")
        #expect(identity?.hasFrontEnd == true)

        var wrong = ByteWriter()
        wrong.append(UInt32(0xDEAD_BEEF))
        wrong.append(bytes: [UInt8](repeating: 0, count: 28))
        #expect(DeviceIdentity(wrong.data) == nil)
    }

    @Test("Capabilities describe full scale from the converter's own width")
    func capabilityFullScale() {
        var capabilities = DeviceCapabilities.unavailable
        capabilities.analogBits = 12
        // Twelve bits left-aligned into sixteen: 4095 << 4.
        #expect(capabilities.analogFullScale == 65520)
        #expect(abs(capabilities.minimumConversionPeriod - 2e-6) < 1e-15)
        #expect(abs(capabilities.minimumSamplePeriod(channels: 2) - 4e-6) < 1e-15)
    }

    @Test("The test output pin follows the firmware, and the PL2407AFE's SG OUT")
    func calibrationOutputPin() {
        func pin(_ firmware: UInt16, board: UInt32 = 0) -> Int {
            DeviceIdentity(protocolVersion: 1, firmwareVersion: firmware, boardID: board, name: "").calibrationOutputPin
        }
        #expect(pin(0x0102) == 2)
        #expect(pin(0x0103) == 28)
        #expect(pin(0x0104) == 28)
        #expect(pin(0x0105) == 20)
        #expect(pin(0x0108) == 20)
        #expect(pin(0x0200) == 20)
        #expect(pin(0x0108, board: 3) == 22)
    }
}
