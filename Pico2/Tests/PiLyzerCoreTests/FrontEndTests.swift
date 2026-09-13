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
        let calibration = ChannelCalibration(scale: 1.014)
        let scale = VoltageScale(reference: reference, fullScale: fullScale,
                                 range: FrontEnd.revA[1], calibration: calibration, probe: 10)
        for volts in stride(from: -40.0, through: 40.0, by: 3.7) {
            let code = scale.code(forVolts: volts)
            #expect(abs(scale.volts(code: code) - volts) < 1e-9)
        }
    }

    @Test("A bare Pico 2 has one range and no offset")
    func bareBoard() {
        let ranges = FrontEnd.ranges(forBoard: 0)
        #expect(ranges.count == 1)
        let scale = VoltageScale(reference: reference, fullScale: fullScale, range: ranges[0])
        #expect(abs(scale.lowestVolts) < 1e-12)
        #expect(abs(scale.highestVolts - reference) < 1e-12)
    }

    @Test("A bias is drawn, not taken out of the reading")
    func biasIsNotSubtracted() {
        // A home-made front end biased to mid rail: grounded in reads 1.65 V,
        // and goes on reading 1.65 V once it has been told so. What arrived at
        // the converter is what the panel shows; the bias is a line on it.
        var channel = AnalogChannelSettings()
        let scale = { channel.scale(reference: 3.3, fullScale: 65520, ranges: FrontEnd.bareBoard) }
        let code = 65520.0 / 2
        #expect(abs(scale().volts(code: code) - 1.65) < 0.001)

        channel.setBias(1.65)
        #expect(abs(scale().volts(code: code) - 1.65) < 0.001)
        #expect(channel.biasVolts == 1.65)
        // And a trigger level still means the volts the converter will see.
        #expect(abs(scale().code(forVolts: 1.65) - code) < 1)
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

        // The bias is a separate number, survives, and is where the gain is
        // measured from: 1.65 V of mid rail plus a volt reading 0.98 V of
        // swing is a 2% error, not a 65% one.
        channel = AnalogChannelSettings()
        channel.setBias(1.65)
        channel.calibrateGain(measured: 1.65 + 0.98, applied: 1.0,
                              bias: channel.referenceBiasVolts, forRange: 0)
        #expect(channel.biasVolts == 1.65)
        #expect(abs(channel.calibration(forRange: 0).scale - 1.0 / 0.98) < 1e-9)

        // A measured bias is the one it uses, when there is one.
        channel.recordMeasuredBias(1.63)
        #expect(channel.referenceBiasVolts == 1.63)

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

        // And a channel told what its bias is still reads what came in: the
        // seed and the line agree because both are the mid-scale voltage.
        var channel = AnalogChannelSettings()
        channel.setBias(1.65)
        let told = channel.scale(reference: 3.3, fullScale: 65520, ranges: FrontEnd.bareBoard)
        #expect(abs(told.biasVolts - channel.biasVolts) < 1e-3)
    }

    @Test("Measuring a bias leaves the expected one alone, and the gap is the error")
    func offsetErrorIsTheGap() throws {
        var channel = AnalogChannelSettings()
        #expect(channel.offsetErrorVolts == nil)          // nothing measured yet

        channel.setBias(1.65)                             // what it should read
        channel.recordMeasuredBias(1.6312)                // what it does read
        #expect(channel.biasVolts == 1.65)
        #expect(abs(try #require(channel.offsetErrorVolts) + 0.0188) < 1e-9)

        // Measuring again replaces only the measurement.
        channel.recordMeasuredBias(1.67)
        #expect(channel.biasVolts == 1.65)
        #expect(abs(try #require(channel.offsetErrorVolts) - 0.02) < 1e-9)

        // Both survive a round trip through the panel's storage, and a panel
        // saved before either existed decodes without them.
        let encoded = try #require(try? JSONEncoder().encode(channel))
        let back = try #require(try? JSONDecoder().decode(AnalogChannelSettings.self, from: encoded))
        #expect(back.biasVolts == 1.65)
        #expect(back.measuredBiasVolts == 1.67)
        let older = try #require(try? JSONDecoder().decode(
            AnalogChannelSettings.self, from: Data(#"{"isEnabled":true}"#.utf8)))
        #expect(older.biasVolts == 0)
        #expect(older.measuredBiasVolts == nil)
    }
}
