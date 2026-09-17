import Foundation
import Testing
@testable import PiLyzerCore

@Suite("Spectrum span and resolution")
struct SpectrumSpanTests {
    /// 48 MHz over 96 cycles: 500 kSa/s for one channel, and 16384 points.
    private let capabilities = DeviceCapabilities.unavailable
    private let lengths = [512, 1024, 2048, 4096, 8192, 16384]

    @Test("The time on screen is the resolution")
    func resolutionIsOneOverTheSweep() {
        var settings = ScopeSettings()
        settings.secondsPerDivision = 0.001
        #expect(abs(settings.spectrumResolution - 100) < 1e-9)
        settings.secondsPerDivision = 0.01
        #expect(abs(settings.spectrumResolution - 10) < 1e-9)
    }

    @Test("A span picks the shortest record that reaches it, and leaves the resolution")
    func spanPicksTheRecord() {
        var settings = ScopeSettings()
        settings.secondsPerDivision = 0.01
        settings.setSpectrumSpan(5000, lengths: lengths, capabilities: capabilities, channels: 1)
        // 512 points over 100 ms is 5.12 kSa/s, which reaches 2.56 kHz; 1024 reaches 5.12.
        #expect(settings.recordLength == 1024)
        #expect(settings.spectrum.spanHz == 5000)
        #expect(settings.secondsPerDivision == 0.01)
    }

    @Test("A resolution keeps the span by choosing the record again")
    func resolutionKeepsTheSpan() {
        var settings = ScopeSettings()
        settings.secondsPerDivision = 0.01
        settings.setSpectrumSpan(5000, lengths: lengths, capabilities: capabilities, channels: 1)
        settings.setSpectrumResolution(secondsPerDivision: 0.1, lengths: lengths,
                                       capabilities: capabilities, channels: 1)
        // 1 Hz bins: 16384 points is 16.4 kSa/s, reaching 8.19 kHz; 8192 reaches only 4.1.
        #expect(settings.recordLength == 16384)
        #expect(settings.spectrum.spanHz == 5000)
    }

    @Test("Everything the record holds leaves the record alone")
    func fullSpanLeavesTheRecord() {
        var settings = ScopeSettings()
        settings.recordLength = 4096
        settings.setSpectrumSpan(nil, lengths: lengths, capabilities: capabilities, channels: 1)
        #expect(settings.recordLength == 4096)
        #expect(settings.spectrum.spanHz == nil)
    }

    @Test("A span and resolution nothing can reach are refused")
    func unreachableCombinations() {
        // 200 kHz in 1 Hz bins would need 400,000 points.
        #expect(ScopeSettings.spectrumRecord(span: 200_000, resolution: 1, lengths: lengths,
                                             capabilities: capabilities, channels: 1) == nil)
        // 10 kHz bins start at 512 points, which is 5.12 MSa/s.
        #expect(ScopeSettings.spectrumRecord(span: 1000, resolution: 10_000, lengths: lengths,
                                             capabilities: capabilities, channels: 1) == nil)
        // Three channels share the converter: 100 kHz is beyond their 83 kHz.
        #expect(!ScopeSettings.spectrumSpans(capabilities: capabilities, channels: 3).contains(100_000))
        #expect(ScopeSettings.spectrumSpans(capabilities: capabilities, channels: 1).last == 200_000)
    }

    @Test("The axis ends at the span, or where the record does if that is sooner")
    func displayedTop() {
        #expect(SpectrumSettings(spanHz: 5000).displayedTop(nyquist: 5120) == 5000)
        #expect(SpectrumSettings(spanHz: 5000).displayedTop(nyquist: 2560) == 2560)
        #expect(SpectrumSettings().displayedTop(nyquist: 5120) == 5120)
    }

    @Test("Settings saved before there was a span read as the whole band")
    func oldSettingsDecode() throws {
        let old = #"{"window":"Hann","scale":"dBV","averaging":4,"logarithmicFrequency":true,"showsPeakMarkers":true,"harmonicCount":5}"#
        let decoded = try JSONDecoder().decode(SpectrumSettings.self, from: Data(old.utf8))
        #expect(decoded.spanHz == nil)
    }
}
