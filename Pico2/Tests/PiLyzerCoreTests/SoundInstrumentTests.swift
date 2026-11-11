import Foundation
import Testing
@testable import PiLyzerCore

@Suite("Sound input")
struct SoundInstrumentTests {
    private let rate = 48_000.0

    /// A sound input holding `seconds` of a 1 kHz sine at half scale on the
    /// left and a 3 kHz one at a tenth on the right.
    private func instrument(seconds: Double) -> SoundInstrument {
        let sound = SoundInstrument(name: "Test input", channels: 2, sampleRate: rate, capacity: 1 << 16)
        append(seconds, to: sound)
        return sound
    }

    private func append(_ seconds: Double, to sound: SoundInstrument) {
        let start = sound.buffer.written, frames = Int(seconds * rate)
        sound.buffer.push([
            (0..<frames).map { Float(0.5 * sin(2 * .pi * 1000 * Double(start + $0) / rate)) },
            (0..<frames).map { Float(0.1 * sin(2 * .pi * 3000 * Double(start + $0) / rate)) },
        ])
    }

    private func configuration(_ mode: TriggerMode, period: Double = 1 / 48_000,
                               level: Double = 0, record: Int = 512) -> AnalogConfiguration {
        AnalogConfiguration(channelMask: 0b11, triggerMode: mode, triggerSource: 0,
                            triggerSlope: .rising, triggerLevel: SoundScale.code(level),
                            triggerHysteresis: 256, samplePeriod: period,
                            recordSamples: record, pretriggerSamples: record / 4, autoTimeout: 0.1)
    }

    @Test("Every input is sampled at once, so more of them do not slow one")
    func simultaneous() {
        let sound = instrument(seconds: 0)
        #expect(sound.capabilities.minimumSamplePeriod(channels: 1) == 1 / rate)
        #expect(sound.capabilities.minimumSamplePeriod(channels: 2) == 1 / rate)
        #expect(SimulatedInstrument().capabilities.minimumSamplePeriod(channels: 3)
                == 3 * SimulatedInstrument().capabilities.minimumConversionPeriod)
    }

    @Test("±1 is full scale through the ordinary scaling")
    func scale() {
        let sound = instrument(seconds: 0)
        let scale = VoltageScale(reference: sound.capabilities.referenceVolts,
                                 fullScale: sound.capabilities.analogFullScale, range: SoundInstrument.range)
        #expect(abs(scale.volts(SoundScale.code(1)) - 1) < 1e-4)
        #expect(abs(scale.volts(SoundScale.code(-1)) + 1) < 1e-4)
        #expect(abs(scale.volts(SoundScale.code(0))) < 1e-4)
    }

    @Test("A slow sweep takes whole frames, and the plan says the interval it got")
    func decimation() throws {
        let sound = instrument(seconds: 0)
        let plan = try sound.configureAnalog(configuration(.freeRun, period: 2.1 / rate))
        #expect(plan.decimation == 2)
        #expect(abs(plan.samplePeriod - 2 / rate) < 1e-12)
        #expect(plan.conversionsPerSample == 2)
    }

    @Test("A triggered sweep starts on a rising crossing, and only on audio after Arm")
    func triggered() throws {
        let sound = instrument(seconds: 0.05)
        let plan = try sound.configureAnalog(configuration(.normal))
        try sound.armAnalog()
        // Nothing has arrived since Arm, so nothing is ready yet.
        #expect(try sound.analogStatus().state == .waiting)
        append(0.05, to: sound)
        let status = try sound.analogStatus()
        #expect(status.state == .complete)
        #expect(status.triggered)
        #expect(status.triggerIndex == plan.pretriggerSamples)
        let columns = try sound.readAnalogRecord(plan: plan)
        #expect(columns.count == 2)
        #expect(columns[0].count == plan.recordSamples)
        let middle = sound.capabilities.analogFullScale / 2
        // At the first sample on or past the level: a 1 kHz sine at half scale
        // climbs 3.3% of full scale a sample at 48 kHz.
        let atTrigger = Double(columns[0][plan.pretriggerSamples])
        #expect(atTrigger >= middle - 2 && atTrigger - middle < sound.capabilities.analogFullScale * 0.034)
        #expect(Double(columns[0][plan.pretriggerSamples - 1]) < middle)
        #expect(columns[0][plan.pretriggerSamples + 6] > columns[0][plan.pretriggerSamples])
    }

    @Test("Normal waits for a level the signal never reaches; free running does not")
    func waiting() throws {
        let sound = instrument(seconds: 0)
        _ = try sound.configureAnalog(configuration(.normal, level: 0.8))
        try sound.armAnalog()
        append(0.1, to: sound)
        #expect(try sound.analogStatus().state == .waiting)

        _ = try sound.configureAnalog(configuration(.freeRun, level: 0.8))
        try sound.armAnalog()
        append(0.02, to: sound)
        let status = try sound.analogStatus()
        #expect(status.state == .complete)
        #expect(!status.triggered)
    }

    @Test("The meter reads each input's RMS")
    func meter() throws {
        let sound = instrument(seconds: 0.2)
        let codes = try sound.sampleAnalog(averages: 1)
        let scale = VoltageScale(reference: 2, fullScale: sound.capabilities.analogFullScale,
                                 range: SoundInstrument.range)
        #expect(abs(scale.volts(codes[0]) - 0.5 / 2.0.squareRoot()) < 0.002)
        #expect(abs(scale.volts(codes[1]) - 0.1 / 2.0.squareRoot()) < 0.002)
    }

    @Test("The meter reads zero before any audio has arrived, rather than reading off the front")
    func meterBeforeAudio() throws {
        let sound = instrument(seconds: 0)
        let codes = try sound.sampleAnalog(averages: 1)
        #expect(codes == [SoundScale.code(0), SoundScale.code(0)])
    }

    @Test("The ring keeps frame numbers across the wrap")
    func ring() {
        let buffer = SoundBuffer(channels: 1, capacity: 8)
        buffer.push([[0, 1, 2, 3, 4, 5]])
        buffer.push([[6, 7, 8, 9, 10]])
        buffer.read { reader in
            #expect(reader.written == 11)
            #expect(reader.oldest == 3)
            #expect(reader.at(0, 3) == 3)
            #expect(reader.at(0, 10) == 10)
            #expect(reader.mean(0, 4, 4) == 5.5)
        }
    }
}
