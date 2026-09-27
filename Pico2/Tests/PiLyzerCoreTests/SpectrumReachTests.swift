import Foundation
import Testing
@testable import PiLyzerCore

/// An UNO R4 WiFi sampling seven inputs at 1 ms/div, 19.83 µs apart. Its
/// channels carried 128 Hz up to 1458 Hz, each half as high again, and the
/// low ones read as -144 Hz, 3.6 Hz and 845 Hz.
@Suite("Spectrum reach")
struct SpectrumReachTests {
    private let period = 19.83e-6

    private func sine(_ frequency: Double, count: Int) -> [Double] {
        (0..<count).map { 1.65 + 1.2 * sin(2 * .pi * frequency * Double($0) * period) }
    }

    private func square(_ frequency: Double, count: Int) -> [Double] {
        (0..<count).map { (Double($0) * period * frequency).truncatingRemainder(dividingBy: 1) < 0.5 ? 3.3 : 0 }
    }

    private func quality(_ samples: [Double]) -> (Spectrum, SpectrumQuality?) {
        let spectrum = SpectrumAnalyzer.transform(samples, sampleRate: 1 / period, window: .hann)
        return (spectrum, SpectrumAnalyzer.quality(of: spectrum, harmonics: 5))
    }

    @Test("A tone below what the record resolves gets no frequency, rather than a wrong one",
          arguments: [128.0, 192.0])
    func outOfReach(frequency: Double) {
        let (spectrum, measured) = quality(sine(frequency, count: 512))
        #expect(measured == nil)
        #expect(spectrum.lowestMeasurable > frequency)
    }

    @Test("A square whose fundamental is out of reach is not read at its third harmonic")
    func notTheThirdHarmonic() throws {
        #expect(quality(square(288, count: 256)).1 == nil)
        let measured = try #require(quality(square(972, count: 512)).1)
        #expect(abs(measured.fundamental.frequency / 972 - 1) < 0.01)
    }

    @Test("A tone the record resolves reads within a hundredth", arguments: [432.0, 648.0, 972.0, 1458.0])
    func inReach(frequency: Double) throws {
        let measured = try #require(quality(sine(frequency, count: 512)).1)
        #expect(abs(measured.fundamental.frequency / frequency - 1) < 0.01)
    }

    @Test("No frequency is ever negative or beyond half a bin of its peak")
    func withinHalfABin() {
        for frequency in stride(from: 50.0, to: 2000, by: 37) {
            let (spectrum, measured) = quality(sine(frequency, count: 512))
            guard let measured else { continue }
            let centre = Double(measured.fundamental.bin) * spectrum.binWidth
            #expect(abs(measured.fundamental.frequency - centre) <= spectrum.binWidth / 2 + 1e-9)
        }
    }

    @Test("The spectrum is given a power of two when the converter pins the rate")
    func powerOfTwoRecord() {
        var capabilities = DeviceCapabilities.unavailable
        capabilities.analogChannels = 7
        capabilities.analogMinPeriodCycles = 136
        capabilities.analogMaxRecord = 1024
        var settings = ScopeSettings()
        settings.secondsPerDivision = 0.001
        settings.recordLength = 2048
        settings.mode = .spectrum
        settings.ensureAnalogChannels(7)
        for index in settings.channels.indices { settings.channels[index].isEnabled = true }
        let scales = settings.channels.map {
            $0.scale(reference: capabilities.referenceVolts,
                     fullScale: capabilities.analogFullScale, ranges: FrontEnd.revA)
        }
        #expect(settings.analogConfiguration(capabilities: capabilities, scales: scales).recordSamples == 512)
        settings.mode = .scope
        #expect(settings.analogConfiguration(capabilities: capabilities, scales: scales).recordSamples == 504)
    }
}
