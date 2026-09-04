import Foundation
import Testing
@testable import DPScopeCore

@Suite("Simulated instrument")
struct SimulatorTests {
    @Test("It identifies itself like the real firmware")
    func identity() throws {
        let scope = SimulatedDPScopeSE()
        #expect(try scope.identify() == "DPScope SE")
        let (major, minor) = try scope.firmwareRevision()
        #expect(major == 1 && minor == 5)
    }

    @Test("An auto sweep finishes after one record and reads back 211 pairs")
    func autoSweep() throws {
        let scope = SimulatedDPScopeSE()
        var setup = AcquisitionSetup()
        (setup.timerPreload, setup.prescaler) = AcquisitionSetup.timing(forSampleInterval: 20e-6)
        try scope.arm(setup)

        while try !scope.isAcquisitionDone() { usleep(1_000) }
        let record = try scope.readRecord()
        #expect(record.channel1.count == ScopeRecord.sampleCount)
        #expect(record.channel2.count == ScopeRecord.sampleCount)
    }

    @Test("Readback blocks are interleaved pairs, and the last one is partial")
    func blockLayout() throws {
        let scope = SimulatedDPScopeSE()
        try scope.arm(AcquisitionSetup())
        while try !scope.isAcquisitionDone() { usleep(1_000) }

        let full = try scope.readBlock(0)
        #expect(full.count == 64)
        let partial = try scope.readBlock(6)
        // 19 valid pairs, then the buffer is not written any more.
        #expect(partial[38] == 0 && partial[39] == 0)
    }

    @Test("A normal trigger never finishes when there is no signal")
    func triggerStarvation() throws {
        let scope = SimulatedDPScopeSE()
        scope.signalIsPresent = false
        var setup = AcquisitionSetup()
        setup.waitsForTrigger = true
        try scope.arm(setup)
        usleep(20_000)
        #expect(try scope.isAcquisitionDone() == false)
        try scope.abort()
    }

    @Test("The reference channel reports the supply rail")
    func supplyMeasurement() throws {
        let scope = SimulatedDPScopeSE()
        scope.supplyVoltage = 5.17
        let measured = try scope.measureSupplyVoltage()
        #expect(abs(measured - 5.17) < 0.02)
    }

    @Test("The demo sine comes back at the right amplitude on both paths")
    func amplitudeThroughBothPaths() throws {
        let scope = SimulatedDPScopeSE()
        scope.noiseAmplitude = 0
        let supply = scope.supplyVoltage

        for (rangeIndex, channel) in [(0, ADCChannel.channel1Gain1), (3, .channel1Gain10)] {
            var setup = AcquisitionSetup()
            setup.firstChannel = channel
            let range = VerticalRange.all[rangeIndex]
            setup.firstShift = range.digitalGain.shift
            setup.firstSubtract = range.digitalGain.subtract
            (setup.timerPreload, setup.prescaler) = AcquisitionSetup.timing(forSampleInterval: 20e-6)
            try scope.arm(setup)
            while try !scope.isAcquisitionDone() { usleep(1_000) }

            let settings = ChannelSettings(rangeIndex: rangeIndex)
            let volts = try scope.readRecord().channel1.map { settings.volts(sample: $0, supply: supply) }
            let statistics = try #require(ChannelStatistics(volts))
            // 1.5 V amplitude sine: 3 V peak to peak, centred on zero.
            #expect(abs(statistics.peakToPeak - 3.0) < 0.4, "range \(rangeIndex)")
            #expect(abs(statistics.mean) < 0.3, "range \(rangeIndex)")
        }
    }

    @Test("Closing the device makes every command fail")
    func closedDevice() throws {
        let scope = SimulatedDPScopeSE()
        scope.close()
        #expect(throws: DPScopeError.disconnected) { try scope.identify() }
        #expect(throws: DPScopeError.disconnected) { try scope.readBlock(0) }
    }
}

@Suite("Spectrum")
struct SpectrumTests {
    @Test("A pure tone lands in one bin at its own amplitude")
    func toneAmplitude() {
        let sampleRate = 10_000.0
        let interval = 1 / sampleRate
        let samples = (0..<1024).map { index in
            2.5 + 1.5 * sin(2 * .pi * 500 * Double(index) * interval)
        }
        let (frequencies, magnitudes) = magnitudeSpectrum(samples, sampleInterval: interval)
        let peak = zip(frequencies, magnitudes).max { $0.1 < $1.1 }!
        #expect(abs(peak.0 - 500) < 15)
        #expect(abs(peak.1 - 1.5) < 0.1)
        #expect(magnitudes[0] < 0.05)
    }

    @Test("Degenerate inputs return nothing rather than crashing")
    func emptyInput() {
        #expect(magnitudeSpectrum([], sampleInterval: 1e-3).magnitudes.isEmpty)
        #expect(magnitudeSpectrum([1, 2], sampleInterval: 1e-3).magnitudes.isEmpty)
        #expect(magnitudeSpectrum([1, 2, 3, 4], sampleInterval: 0).magnitudes.isEmpty)
    }

    @Test("Frequency is recovered from a trace, and refused when it cannot be")
    func frequencyEstimate() {
        let interval = 1.0 / 20_000
        let sine = (0..<400).map { sin(2 * .pi * 220 * Double($0) * interval) }
        let measured = try! #require(estimateFrequency(sine, sampleInterval: interval))
        #expect(abs(measured - 220) / 220 < 0.01)

        // A square wave measures just as well.
        let square = (0..<400).map { sin(2 * .pi * 311 * Double($0) * interval) >= 0 ? 1.0 : -1.0 }
        let fromSquare = try! #require(estimateFrequency(square, sampleInterval: interval))
        #expect(abs(fromSquare - 311) / 311 < 0.02)

        // Nothing to measure: a flat line, or too few samples.
        #expect(estimateFrequency([Double](repeating: 1, count: 100), sampleInterval: interval) == nil)
        #expect(estimateFrequency([1, 2, 3], sampleInterval: interval) == nil)
        #expect(estimateFrequency(sine, sampleInterval: 0) == nil)
    }

    @Test("Interleaved readback splits into two channels")
    func deinterleaving() {
        let (first, second) = deinterleave([1, 2, 3, 4, 5, 6])
        #expect(first == [1, 3, 5])
        #expect(second == [2, 4, 6])
    }
}
