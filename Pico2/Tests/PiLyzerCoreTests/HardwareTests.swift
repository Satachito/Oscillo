import Foundation
import Testing
@testable import PiLyzerCore

/// Tests that need a real instrument. They are skipped when none is attached,
/// so the suite still runs on a machine with nothing plugged in.
///
/// These exist because the interesting failures here are not the ones a
/// simulator can have: an IOKit call that matches nothing, a handle freed
/// twice, a record whose trigger is not where the firmware said it was.
///
/// Serialized because there is one instrument and it is opened exclusively —
/// run in parallel, all but one of these would only prove that.
/// Attached is not the same as available: the instrument is opened
/// exclusively, so if the application has it these tests cannot run. Skip
/// rather than fail — a running front panel is not a broken build.
private let instrumentIsFree: Bool = {
    guard !USBTransport.attachedDevices().isEmpty else { return false }
    guard let transport = try? USBTransport() else { return false }
    transport.close()
    return true
}()

@Suite("Hardware", .serialized, .enabled(if: instrumentIsFree))
struct HardwareTests {
    private func open() throws -> USBInstrument {
        try USBInstrument()
    }

    @Test("The instrument identifies itself and its protocol version matches")
    func identity() throws {
        let instrument = try open()
        defer { instrument.close() }
        #expect(instrument.identity.protocolVersion == Wire.version)
        #expect(instrument.identity.name.contains("PiLyzer"))
        #expect(instrument.capabilities.analogChannels >= 1)
        #expect(instrument.capabilities.logicChannels >= 1)
    }

    @Test("Full scale follows the converter's own resolution, not sixteen bits")
    func fullScale() throws {
        let instrument = try open()
        defer { instrument.close() }
        let capabilities = instrument.capabilities
        // Samples are left-aligned, so a 12-bit converter tops out at 65520.
        let expected = Double(((1 << capabilities.analogBits) - 1) << (16 - capabilities.analogBits))
        #expect(capabilities.analogFullScale == expected)
        #expect(capabilities.analogBits <= 16)
    }

    @Test("Closing twice is harmless")
    func closeIsIdempotent() throws {
        // Both an explicit close and deinit happen when disconnecting, and the
        // handle is freed by the C side — so this used to be a double free.
        let instrument = try open()
        instrument.close()
        instrument.close()
    }

    @Test("A free-running record comes back the length that was planned")
    func record() throws {
        let instrument = try open()
        defer { instrument.close() }

        let plan = try instrument.configureAnalog(AnalogConfiguration(
            channelMask: 0b11, triggerMode: .freeRun, samplePeriod: 4e-6,
            recordSamples: 1024, pretriggerSamples: 128))
        #expect(plan.recordSamples == 1024)
        #expect(plan.conversionsPerSample == 2)
        #expect(abs(plan.samplePeriod - 4e-6) < 1e-7)

        try instrument.armAnalog()
        let status = try waitForCompletion { try instrument.analogStatus() }
        #expect(status?.state == .complete)

        let columns = try instrument.readAnalogRecord(plan: plan)
        #expect(columns.count == 2)
        for column in columns {
            #expect(column.count == plan.recordSamples)
            #expect(column.allSatisfy { Double($0) <= instrument.capabilities.analogFullScale })
        }
    }

    @Test("The edge really is at the index the instrument reported")
    func triggerIndexIsExact() throws {
        let instrument = try open()
        defer { instrument.close() }

        let level = UInt16(instrument.capabilities.analogFullScale / 2)
        let plan = try instrument.configureAnalog(AnalogConfiguration(
            channelMask: 0b01, triggerMode: .normal, triggerSource: 0,
            triggerSlope: .rising, triggerLevel: level, triggerHysteresis: 200,
            samplePeriod: 4e-6, recordSamples: 1024, pretriggerSamples: 256))

        try instrument.armAnalog()
        guard let status = try waitForCompletion({ try instrument.analogStatus() }, timeout: 5),
              status.state == .complete, status.triggered else {
            // An input sitting quietly on one side of mid-scale never crosses
            // it, and that is not a failure of anything.
            return
        }

        let samples = try instrument.readAnalogRecord(plan: plan)[0]
        let index = status.triggerIndex
        try #require(index > 0 && index < samples.count)
        #expect(samples[index - 1] < level)
        #expect(samples[index] >= level)
    }

    @Test("A logic capture returns one byte a sample")
    func logicRecord() throws {
        let instrument = try open()
        defer { instrument.close() }

        let plan = try instrument.configureLogic(LogicConfiguration(
            triggerMode: .freeRun, samplePeriod: 1e-7,
            recordSamples: 2048, pretriggerSamples: 256))
        try instrument.armLogic()
        let status = try waitForCompletion { try instrument.logicStatus() }
        #expect(status?.state == .complete)
        #expect(try instrument.readLogicRecord(plan: plan).count == plan.recordSamples)
    }

    private func waitForCompletion(_ poll: () throws -> AcquisitionStatus,
                                   timeout: Double = 3) throws -> AcquisitionStatus? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = try poll()
            if status.isFinished { return status }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return nil
    }
}
