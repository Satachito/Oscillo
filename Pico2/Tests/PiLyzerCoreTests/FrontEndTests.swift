import Foundation
import Testing
@testable import PiLyzerCore

@Suite("Front end scaling")
struct FrontEndTests {
    private let reference = 3.3
    private let fullScale = 65520.0

    @Test("Both rev A ranges put 0 V at the middle of the converter")
    func midRail() {
        for range in FrontEnd.revA {
            let scale = VoltageScale(reference: reference, fullScale: fullScale, range: range)
            let middle = scale.code(forVolts: 0)
            #expect(abs(middle - fullScale / 2) < fullScale * 0.002)
        }
    }

    @Test("Each range reaches its name with headroom, and not much more",
          arguments: zip(FrontEnd.revA, [25.0, 5.0]))
    func spans(range: InputRange, named: Double) {
        let scale = VoltageScale(reference: reference, fullScale: fullScale, range: range)
        // The named voltage has to fit with room for 1% parts to move the ends,
        // but a range that reached twice its name would be wasting resolution.
        #expect(scale.highestVolts > named * 1.02)
        #expect(scale.highestVolts < named * 1.25)
        #expect(scale.lowestVolts < -named * 1.02)
        #expect(scale.lowestVolts > -named * 1.25)
    }

    @Test("Volts and codes are inverses of each other")
    func roundTrip() {
        let calibration = ChannelCalibration(zero: 0.037, scale: 1.014)
        let scale = VoltageScale(reference: reference, fullScale: fullScale,
                                 range: FrontEnd.revA[1], calibration: calibration, probe: 10)
        for volts in stride(from: -40.0, through: 40.0, by: 3.7) {
            let code = scale.code(forVolts: volts)
            #expect(abs(scale.volts(code: code) - volts) < 1e-9)
        }
    }

    @Test("A two-point calibration recovers the line it was measured on")
    func twoPoint() {
        // The instrument reads 4% high and 25 mV off zero.
        func measured(_ truth: Double) -> Double { truth * 1.04 + 0.025 }
        let calibration = ChannelCalibration.from(low: measured(0), lowTrue: 0,
                                                  high: measured(5), highTrue: 5)
        let corrected = try! #require(calibration)
        #expect(abs(corrected.apply(measured(0)) - 0) < 1e-9)
        #expect(abs(corrected.apply(measured(5)) - 5) < 1e-9)
        #expect(abs(corrected.apply(measured(2.5)) - 2.5) < 1e-9)
    }

    @Test("A bare Pico 2 has one range and no offset")
    func bareBoard() {
        let ranges = FrontEnd.ranges(forBoard: 0)
        #expect(ranges.count == 1)
        let scale = VoltageScale(reference: reference, fullScale: fullScale, range: ranges[0])
        #expect(abs(scale.lowestVolts) < 1e-12)
        #expect(abs(scale.highestVolts - reference) < 1e-12)
    }

    @Test("A typed zero cancels a front end's bias, on whichever range is selected")
    func zeroCancelsBias() {
        // A home-made front end biased to mid rail: grounded in reads 1.65 V.
        var channel = AnalogChannelSettings()
        let scale = { channel.scale(reference: 3.3, fullScale: 65520, ranges: FrontEnd.bareBoard) }
        let code = 65520.0 / 2
        #expect(abs(scale().volts(code: code) - 1.65) < 0.001)

        channel.calibrateZero(to: 1.65, forRange: 0)
        #expect(abs(scale().volts(code: code)) < 0.001)
        #expect(abs(scale().code(forVolts: 0) - code) < 1)

        // The calibration array starts empty, so a range the board only just
        // reported must still take a zero rather than fall off the end.
        channel.rangeIndex = 2
        channel.calibrateZero(to: 0.132, forRange: 2)
        #expect(channel.calibration(forRange: 2).zero == 0.132)
        #expect(channel.calibration(forRange: 1).zero == 0)
    }

    @Test("A known voltage corrects the gain the divider's tolerance got wrong")
    func gainCalibration() {
        // 1% parts put this divider out by up to 2%, which no range descriptor
        // can know: 1 V applied, 0.98 V read.
        var channel = AnalogChannelSettings()
        channel.calibrateGain(measured: 0.98, applied: 1.0, forRange: 0)
        let scale = channel.scale(reference: 3.3, fullScale: 65520, ranges: FrontEnd.bareBoard)
        #expect(abs(channel.calibration(forRange: 0).scale - 1.0 / 0.98) < 1e-9)
        #expect(abs(scale.volts(code: 65520 * 0.98 / 3.3) - 1.0) < 0.001)

        // It multiplies what is there, so a second pass converges.
        channel.calibrateGain(measured: 1.01, applied: 1.0, forRange: 0)
        #expect(abs(channel.calibration(forRange: 0).scale - 1.0 / 0.98 / 1.01) < 1e-9)

        // The zero is a separate correction and survives.
        channel.calibrateZero(to: 1.65, forRange: 0)
        channel.calibrateGain(measured: 2, applied: 2, forRange: 0)
        #expect(channel.calibration(forRange: 0).zero == 1.65)

        // Nothing on the input, or nothing claimed, leaves it alone.
        let before = channel.calibration(forRange: 0)
        channel.calibrateGain(measured: 0, applied: 1, forRange: 0)
        channel.calibrateGain(measured: 1, applied: 0, forRange: 0)
        #expect(channel.calibration(forRange: 0) == before)
    }

    @Test("A trigger starts at the middle of what the channel reads")
    func biasIsWhereATriggerStarts() {
        // A bare board reads 0 to 3.3 V, and 0 V is on its bottom rail: a level
        // there never fires, so a channel that has never been set starts at the
        // mid rail a front end biases the input to.
        let bare = VoltageScale(reference: 3.3, fullScale: 65520, range: FrontEnd.bareBoard[0])
        #expect(abs(bare.biasVolts - 1.65) < 1e-3)
        #expect(bare.triggerWindow?.contains(0) == false)
        #expect(bare.triggerWindow?.contains(bare.biasVolts) == true)

        // A front end that reports its own offset is already about zero.
        for range in FrontEnd.revA {
            let scale = VoltageScale(reference: 3.3, fullScale: 65520, range: range)
            #expect(abs(scale.biasVolts) < 0.05)
            #expect(scale.triggerWindow?.contains(0) == true)
        }

        // And a channel told what its bias is reads zero in the middle.
        var channel = AnalogChannelSettings()
        channel.calibrateZero(to: 1.65, forRange: 0)
        let corrected = channel.scale(reference: 3.3, fullScale: 65520, ranges: FrontEnd.bareBoard)
        #expect(abs(corrected.biasVolts) < 1e-3)
    }
}
