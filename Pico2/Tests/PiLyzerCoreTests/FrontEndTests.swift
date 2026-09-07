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
}
