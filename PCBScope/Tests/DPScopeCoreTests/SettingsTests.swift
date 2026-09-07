import Foundation
import Testing
@testable import DPScopeCore

@Suite("Ranges and scaling")
struct SettingsTests {
    /// What the reference channel reads on the machine this was developed on.
    static let supply = 5.17

    @Test("Digital gain keeps 0 V at code 128 for every setting")
    func digitalGainCentre() {
        for gain in DigitalGain.allCases {
            #expect(gain.rawCode(from: 128) == ScopeRecord.zeroCode)
        }
        // The firmware's own scaling, inverted.
        #expect(DigitalGain.x1.rawCode(from: 140) == 560)
        #expect(DigitalGain.x4.rawCode(from: 187) == 571)
    }

    @Test("The six ranges span ±26 V down to ±0.65 V")
    func rangeSpan() {
        let ranges = VerticalRange.all
        #expect(ranges.count == 6)

        let spans = ranges.map { $0.fullScaleVolts(supply: Self.supply) }
        #expect(abs(spans[0] - 26.1) < 0.2)   // ×1 path, no digital gain
        #expect(abs(spans[3] - 2.60) < 0.05)  // ×10 path
        #expect(abs(spans[5] - 0.65) < 0.02)  // ×10 path, digital gain 4
        // Coarse to fine, with no duplicates.
        #expect(spans == spans.sorted(by: >))
    }

    @Test("Counts become volts through the divider and the ×10 stage")
    func voltageConversion() {
        var channel = ChannelSettings(rangeIndex: 0)  // ×1 path, gain 1
        #expect(abs(channel.volts(sample: 128, supply: Self.supply)) < 1e-9)

        // One 8-bit step at gain 1 is four converter counts.
        let step = channel.volts(sample: 129, supply: Self.supply)
        #expect(abs(step - 4 * (Self.supply / 1023) / FrontEnd.inputDivider) < 1e-9)

        // The ×10 path sees ten times the signal, so it reads ten times finer.
        var amplified = ChannelSettings(rangeIndex: 3)
        #expect(abs(amplified.volts(sample: 129, supply: Self.supply) - step / FrontEnd.secondStageGain) < 1e-9)

        // A 10:1 probe multiplies whatever the front end measured.
        amplified.probeAttenuation = .x10
        #expect(abs(amplified.volts(sample: 200, supply: Self.supply)
                    - 10 * ChannelSettings(rangeIndex: 3).volts(sample: 200, supply: Self.supply)) < 1e-9)

        // A direct 10-bit reading uses the same scale.
        channel = ChannelSettings(rangeIndex: 0)
        #expect(abs(channel.volts(rawCode: 512, supply: Self.supply)) < 1e-9)
        #expect(abs(channel.volts(rawCode: 516, supply: Self.supply) - step) < 1e-9)
    }

    @Test("A calibrated zero shifts the readings, per path")
    func zeroCalibration() {
        var channel = ChannelSettings(rangeIndex: 0)   // ×1 path
        #expect(channel.isZeroCalibrated == false)

        channel.setZero(520, for: .gain1)
        channel.setZero(585, for: .gain10)
        #expect(channel.isZeroCalibrated)
        #expect(channel.zeroCode == 520)
        // The calibrated code now reads as 0 V.
        #expect(abs(channel.volts(rawCode: 520, supply: Self.supply)) < 1e-9)

        channel.rangeIndex = 3                          // ×10 path
        #expect(channel.zeroCode == 585)
        #expect(abs(channel.volts(rawCode: 585, supply: Self.supply)) < 1e-9)
        // And an uncalibrated channel still uses the nominal mid-scale.
        #expect(abs(ChannelSettings().volts(rawCode: 512, supply: Self.supply)) < 1e-9)
    }

    @Test("The front end matches the V1.1 schematic")
    func frontEndConstants() {
        #expect(abs(FrontEnd.inputDivider - 100.0 / 1009.0) < 1e-12)
        #expect(abs(FrontEnd.secondStageGain - 10.06) < 1e-12)
        // The ×10 path lands almost exactly 1:1 at the converter.
        #expect(abs(FrontEnd.attenuation(.gain10) - 0.997) < 0.001)
    }

    @Test("The timebase table is ordered and switches to equivalent time when needed")
    func timebaseTable() {
        let table = Timebase.all
        #expect(table.count == 18)
        #expect(table.map(\.secondsPerDivision) == table.map(\.secondsPerDivision).sorted())

        // Anything faster than the converter can follow is sampled in
        // equivalent time; everything else is a single real-time sweep.
        for timebase in table {
            let expected: SamplingMode = timebase.sampleInterval < Timebase.fastestRealTimeInterval
                ? .equivalentTime : .realTime
            #expect(timebase.mode == expected, "\(timebase.label)")
        }
        #expect(table.first?.mode == .equivalentTime)
        #expect(table.last?.mode == .realTime)

        // The sweep really is ten divisions of the record.
        for timebase in table {
            let sweep = timebase.sampleInterval * Double(ScopeRecord.sampleCount)
            #expect(abs(sweep / timebase.secondsPerDivision - 10) < 1e-9)
        }
    }

    @Test("Trigger levels map onto the comparator's 8-bit PWM")
    func triggerLevel() {
        #expect(TriggerSettings(level: 0).levelByte() == 128)
        #expect(TriggerSettings(level: 1).levelByte() == 255)
        #expect(TriggerSettings(level: -1).levelByte() == 0)
        #expect(TriggerSettings(level: 5).levelByte() == 255)

        let channel = ChannelSettings(rangeIndex: 3)
        let trigger = TriggerSettings(level: 0.5)
        let volts = trigger.levelVolts(channel: channel, supply: Self.supply)
        #expect(abs(volts - 0.5 * channel.fullScaleVolts(supply: Self.supply)) < 1e-9)
    }

    @Test("Settings turn into a well-formed ARM packet")
    func settingsToSetup() {
        var settings = ScopeSettings()
        settings.channel1.rangeIndex = 4          // ×10 path, digital gain 2
        settings.channel2.rangeIndex = 0          // ×1 path, digital gain 1
        settings.trigger.mode = .normal
        settings.trigger.source = .channel1

        let setup = settings.acquisitionSetup()
        #expect(setup.firstChannel == .channel1Gain10)
        #expect(setup.secondChannel == .channel2Gain1)
        #expect(setup.firstShift == DigitalGain.x2.shift)
        #expect(setup.secondSubtract == DigitalGain.x1.subtract)
        #expect(setup.waitsForTrigger)
        #expect(setup.triggerChannel == .channel1Gain10)
    }

    @Test("Equivalent-time sweeps always arm the trigger")
    func equivalentTimeForcesTrigger() {
        var settings = ScopeSettings()
        settings.trigger.mode = .auto

        // A real-time sweep in auto mode runs free.
        settings.timebaseIndex = 6
        #expect(settings.timebase.mode == .realTime)
        #expect(settings.acquisitionSetup().waitsForTrigger == false)
        #expect(settings.requiresTrigger == false)

        // The fastest sweeps are built from many trigger events, so they must
        // wait for one even though the mode still says auto.
        settings.timebaseIndex = 0
        #expect(settings.timebase.mode == .equivalentTime)
        #expect(settings.acquisitionSetup().waitsForTrigger)
        #expect(settings.requiresTrigger)
        #expect(settings.acquisitionSetup().equivalentTimeInterval > 0)
    }

    @Test("Out-of-range indices are clamped instead of trapping")
    func clamping() {
        var settings = ScopeSettings()
        settings.timebaseIndex = 999
        #expect(settings.timebase.label == Timebase.all.last?.label)
        settings.channel1.rangeIndex = -5
        #expect(settings.channel1.range == VerticalRange.all[0])
        settings.averaging = 5_000
        #expect(settings.effectiveAveraging == 100)
    }
}
