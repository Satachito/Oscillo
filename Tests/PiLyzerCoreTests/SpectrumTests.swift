import Foundation
import Testing
@testable import PiLyzerCore

@Suite("Spectrum")
struct SpectrumTests {
    private let sampleRate = 48_000.0
    private let length = 4096

    private func tone(amplitude: Double, bin: Int, harmonic: Double = 0) -> [Double] {
        let frequency = Double(bin) * sampleRate / Double(length)
        return (0..<length).map { index in
            let time = Double(index) / sampleRate
            var value = amplitude * sin(2 * .pi * frequency * time)
            if harmonic > 0 {
                value += amplitude * harmonic * sin(2 * .pi * 3 * frequency * time)
            }
            return value
        }
    }

    @Test("A one volt tone reads one volt, whichever window is used",
          arguments: SpectrumWindow.allCases)
    func amplitudeIsCorrect(window: SpectrumWindow) {
        let spectrum = SpectrumAnalyzer.transform(tone(amplitude: 1.0, bin: 100),
                                                  sampleRate: sampleRate, window: window)
        #expect(spectrum.count == length / 2 + 1)
        #expect(abs(spectrum.binWidth - sampleRate / Double(length)) < 1e-9)
        // A bin-centred tone should land within a percent of its real amplitude.
        #expect(abs(spectrum.amplitudes[100] - 1.0) < 0.01)
    }

    @Test("The peak sits at the frequency the tone was generated at")
    func peakFrequency() {
        let spectrum = SpectrumAnalyzer.transform(tone(amplitude: 0.5, bin: 250),
                                                  sampleRate: sampleRate, window: .hann)
        let peaks = spectrum.peaks(limit: 3)
        let strongest = try! #require(peaks.first)
        let expected = 250 * sampleRate / Double(length)
        #expect(abs(strongest.frequency - expected) < spectrum.binWidth * 0.1)
        #expect(abs(strongest.amplitude - 0.5) < 0.01)
    }

    @Test("A tone between two bins still reads its true frequency")
    func interpolatedFrequency() {
        let frequency = 100.5 * sampleRate / Double(length)
        let samples = (0..<length).map { sin(2 * .pi * frequency * Double($0) / sampleRate) }
        let spectrum = SpectrumAnalyzer.transform(samples, sampleRate: sampleRate, window: .hann)
        let strongest = try! #require(spectrum.peaks(limit: 1).first)
        #expect(abs(strongest.frequency - frequency) < spectrum.binWidth * 0.15)
    }

    @Test("Distortion is measured as the ratio it was built with")
    func distortion() {
        let spectrum = SpectrumAnalyzer.transform(tone(amplitude: 1.0, bin: 120, harmonic: 0.01),
                                                  sampleRate: sampleRate, window: .hann)
        let quality = try! #require(SpectrumAnalyzer.quality(of: spectrum, harmonics: 5))
        #expect(abs(quality.thd - 0.01) < 0.002)
        #expect(quality.signalToNoiseDB > 60)
    }

    @Test("A tone low in the spectrum does not report its own skirt as distortion")
    func lowFundamentalIsNotDistortion() {
        // At bin five the second harmonic sits inside the window's own skirt,
        // so it cannot be told apart from the fundamental. Counting it would
        // invent several percent of distortion out of nothing.
        let spectrum = SpectrumAnalyzer.transform(tone(amplitude: 2.0, bin: 5, harmonic: 0.01),
                                                  sampleRate: sampleRate, window: .hann)
        let quality = try! #require(SpectrumAnalyzer.quality(of: spectrum, harmonics: 5))
        #expect(abs(quality.fundamental.amplitude - 2.0) < 0.05)
        #expect(quality.thd < 0.02)
    }

    @Test("A clean tone reports no distortion worth speaking of")
    func cleanTone() {
        let spectrum = SpectrumAnalyzer.transform(tone(amplitude: 1.0, bin: 200),
                                                  sampleRate: sampleRate, window: .hann)
        let quality = try! #require(SpectrumAnalyzer.quality(of: spectrum, harmonics: 5))
        #expect(quality.thd < 0.001)
    }

    @Test("dBV is referenced to one volt RMS")
    func decibelScale() {
        // A sine of amplitude √2 is 1 V RMS, which is 0 dBV.
        let level = Spectrum.convert(amplitude: 2.0.squareRoot(), scale: .dBV, fullScale: 1)
        #expect(abs(level) < 1e-9)
        let half = Spectrum.convert(amplitude: 2.0.squareRoot() / 2, scale: .dBV, fullScale: 1)
        #expect(abs(half + 6.0206) < 0.001)
    }

    @Test("Averaging spectra in power leaves a steady tone where it was")
    func averaging() {
        let spectra = (0..<8).map { _ in
            SpectrumAnalyzer.transform(tone(amplitude: 1.0, bin: 64), sampleRate: sampleRate, window: .hann)
        }
        let averaged = SpectrumAnalyzer.average(spectra)
        #expect(abs(averaged.amplitudes[64] - 1.0) < 0.01)
    }
}

@Suite("Measurements")
struct MeasurementTests {
    @Test("A sine reports its amplitude, its RMS and its frequency")
    func sine() {
        let rate = 100_000.0
        let samples = (0..<1000).map { 2.0 * sin(2 * .pi * 1000 * Double($0) / rate) }
        let measured = Measurements.of(samples, samplePeriod: 1 / rate)

        #expect(abs(measured.peakToPeak - 4.0) < 0.02)
        #expect(abs(measured.rms - 2 / 2.0.squareRoot()) < 0.02)
        #expect(abs(measured.mean) < 0.02)
        let frequency = try! #require(measured.frequency)
        #expect(abs(frequency - 1000) < 5)
    }

    @Test("A square wave reports its duty cycle")
    func square() {
        let rate = 1_000_000.0
        let samples = (0..<2000).map { index -> Double in
            fmod(Double(index) / rate * 1000, 1.0) < 0.3 ? 1.0 : -1.0
        }
        let measured = Measurements.of(samples, samplePeriod: 1 / rate)
        let duty = try! #require(measured.dutyCycle)
        #expect(abs(duty - 0.3) < 0.02)
        let frequency = try! #require(measured.frequency)
        #expect(abs(frequency - 1000) < 5)
    }

    @Test("A ramp with a known edge reports its rise time")
    func riseTime() {
        // 100 samples low, a 50-sample ramp, then high: 80% of 50 µs.
        let rate = 1_000_000.0
        var samples = [Double](repeating: 0, count: 100)
        samples += (0..<50).map { Double($0) / 49.0 }
        samples += [Double](repeating: 1, count: 100)
        let measured = Measurements.of(samples, samplePeriod: 1 / rate)
        let rise = try! #require(measured.riseTime)
        #expect(abs(rise - 40e-6) < 3e-6)
    }

    @Test("An empty record measures as nothing rather than crashing")
    func empty() {
        #expect(Measurements.of([], samplePeriod: 1e-6) == .empty)
    }
}
