import Foundation
import Testing
@testable import DPScopeCore

@Suite("SE command encoding")
struct ProtocolTests {
    @Test("CMD_ARM carries its 19 parameters in the documented order")
    func armParameters() {
        let setup = AcquisitionSetup(
            firstChannel: .channel1Gain10,
            secondChannel: .channel2Gain1,
            adcon2: 170,
            timerPreload: 0xFE_0C,
            prescaler: .power(7),
            firstShift: 1,
            secondShift: 2,
            firstSubtract: 128,
            secondSubtract: 0,
            waitsForTrigger: true,
            risingEdge: false,
            triggerLevel: 200,
            equivalentTime: true,
            equivalentTimeInterval: 4,
            equivalentTimeStability: 2,
            triggerChannel: .external
        )

        #expect(setup.parameterBytes == [
            6, 8, 170,          // channels, ADCON2
            0xFE, 0x0C,         // timer0 preload
            0, 7,               // prescaler: not bypassed, ÷256
            1, 2,               // shifts
            128, 0,             // subtracts
            1,                  // waits for trigger
            0,                  // falling edge
            0, 200,             // level MSB (unused), LSB
            1, 4, 2,            // equivalent time
            3,                  // trigger channel: external
        ])
        #expect(setup.parameterBytes.count == 19)
    }

    @Test("The prescaler byte pair follows the 2^(n+1) convention")
    func prescalerEncoding() {
        #expect(Prescaler.bypassed.divider == 1)
        #expect(Prescaler.bypassed.bypassByte == 1)
        #expect(Prescaler.power(0).divider == 2)
        #expect(Prescaler.power(7).divider == 256)
        #expect(Prescaler.power(7).bypassByte == 0)
        #expect(Prescaler.power(7).powerByte == 7)
    }

    @Test("The record is 211 pairs, read as seven blocks")
    func recordGeometry() {
        #expect(ScopeRecord.sampleCount == 211)
        #expect(ScopeRecord.pairsPerBlock == 32)
        #expect(ScopeRecord.blockCount == 7)
        // Six full blocks and a partial one.
        #expect(ScopeRecord.sampleCount - 6 * ScopeRecord.pairsPerBlock == 19)
    }

    @Test("Sample interval is the timer period plus the converter's own time")
    func timerModel() {
        // 500 ticks with the ÷256 prescaler: a whole record measured 4517 ms.
        let setup = AcquisitionSetup(timerPreload: UInt16(65_536 - 500), prescaler: .power(7))
        let timerPart = 2.0 * 500 * 256 / 12e6
        #expect(abs(setup.sampleInterval - (timerPart + AcquisitionSetup.conversionOverhead)) < 1e-12)
        #expect(abs(setup.sampleInterval * Double(ScopeRecord.sampleCount) - 4.503) < 0.02)

        // The converter's cost dominates at the fast end and vanishes at the
        // slow end, which is what makes it easy to miss.
        let fast = AcquisitionSetup(timerPreload: UInt16(65_536 - 120), prescaler: .bypassed)
        #expect(fast.sampleInterval / (2.0 * 120 / 12e6) > 1.4)
        let slow = AcquisitionSetup(timerPreload: UInt16(65_536 - 6000), prescaler: .power(2))
        #expect(slow.sampleInterval / (2.0 * 6000 * 8 / 12e6) < 1.002)
    }

    @Test("Requested intervals resolve to timer settings that reproduce them")
    func timingRoundTrip() {
        // The solver has to subtract the converter's cost before programming
        // the timer, or every sweep comes out long.
        for wanted in [50e-6, 100e-6, 1e-3, 10e-3, 0.1, 1.0] {
            let (preload, prescaler) = AcquisitionSetup.timing(forSampleInterval: wanted)
            let achieved = AcquisitionSetup(timerPreload: preload, prescaler: prescaler).sampleInterval
            #expect(abs(achieved - wanted) / wanted < 0.01, "\(wanted) resolved to \(achieved)")
        }
    }
}
