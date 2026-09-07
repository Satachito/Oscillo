import Accelerate
import Foundation

public enum SpectrumWindow: String, CaseIterable, Codable, Sendable {
    case rectangular = "Rectangular"
    case hann = "Hann"
    case hamming = "Hamming"
    case blackmanHarris = "Blackman-Harris"
    case flatTop = "Flat top"

    /// Which window to reach for: Hann for general work, flat top when the
    /// amplitude of a tone matters more than telling two tones apart,
    /// Blackman-Harris when a small tone sits next to a large one.
    public var advice: String {
        switch self {
        case .rectangular: return "No window. Only for signals that fit the record exactly."
        case .hann: return "General purpose."
        case .hamming: return "Slightly narrower than Hann, with higher distant sidelobes."
        case .blackmanHarris: return "Lowest sidelobes; use next to a strong tone."
        case .flatTop: return "Most accurate amplitude; poorest resolution."
        }
    }

    public func coefficients(count: Int) -> [Double] {
        guard count > 1 else { return [1] }
        let n = Double(count - 1)
        switch self {
        case .rectangular:
            return [Double](repeating: 1, count: count)
        case .hann:
            return (0..<count).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / n) }
        case .hamming:
            return (0..<count).map { 0.54 - 0.46 * cos(2 * .pi * Double($0) / n) }
        case .blackmanHarris:
            let a = [0.35875, 0.48829, 0.14128, 0.01168]
            return (0..<count).map { index in
                let x = 2 * .pi * Double(index) / n
                return a[0] - a[1] * cos(x) + a[2] * cos(2 * x) - a[3] * cos(3 * x)
            }
        case .flatTop:
            let a = [0.21557895, 0.41663158, 0.277263158, 0.083578947, 0.006947368]
            return (0..<count).map { index in
                let x = 2 * .pi * Double(index) / n
                return a[0] - a[1] * cos(x) + a[2] * cos(2 * x) - a[3] * cos(3 * x) + a[4] * cos(4 * x)
            }
        }
    }

    /// Bins one tone is smeared over, which is what turns a spectrum into a
    /// noise density.
    public var equivalentNoiseBandwidth: Double {
        switch self {
        case .rectangular: return 1.0
        case .hann: return 1.5
        case .hamming: return 1.36
        case .blackmanHarris: return 2.0
        case .flatTop: return 3.77
        }
    }
}

public enum SpectrumScale: String, CaseIterable, Codable, Sendable {
    case dBV = "dBV"
    case dBu = "dBu"
    case dBFS = "dBFS"
    case linear = "V"

    public var unit: String { rawValue }
    public var isLogarithmic: Bool { self != .linear }
}

public struct SpectrumSettings: Codable, Equatable, Sendable {
    public var window: SpectrumWindow
    public var scale: SpectrumScale
    /// Number of spectra averaged together; 1 shows every record on its own.
    public var averaging: Int
    public var logarithmicFrequency: Bool
    public var showsPeakMarkers: Bool
    public var harmonicCount: Int

    public init(window: SpectrumWindow = .hann, scale: SpectrumScale = .dBV,
                averaging: Int = 4, logarithmicFrequency: Bool = true,
                showsPeakMarkers: Bool = true, harmonicCount: Int = 5) {
        self.window = window
        self.scale = scale
        self.averaging = averaging
        self.logarithmicFrequency = logarithmicFrequency
        self.showsPeakMarkers = showsPeakMarkers
        self.harmonicCount = harmonicCount
    }
}

public struct SpectrumPeak: Equatable, Sendable, Identifiable {
    public var frequency: Double
    /// Amplitude of the tone, in volts peak.
    public var amplitude: Double
    public var bin: Int

    public var id: Int { bin }
}

/// One spectrum, and the numbers that fall out of it.
public struct Spectrum: Equatable, Sendable {
    /// Amplitude per bin, in volts peak.
    public var amplitudes: [Double]
    public var binWidth: Double
    public var sampleRate: Double
    public var windowUsed: SpectrumWindow

    public var frequencies: [Double] { amplitudes.indices.map { Double($0) * binWidth } }
    public var count: Int { amplitudes.count }
    public var nyquist: Double { sampleRate / 2 }

    public static let empty = Spectrum(amplitudes: [], binWidth: 0, sampleRate: 0, windowUsed: .hann)

    /// Amplitude converted to the unit the panel is set to.
    public func value(at index: Int, scale: SpectrumScale, fullScale: Double) -> Double {
        let amplitude = index < amplitudes.count ? amplitudes[index] : 0
        return Spectrum.convert(amplitude: amplitude, scale: scale, fullScale: fullScale)
    }

    public static func convert(amplitude: Double, scale: SpectrumScale, fullScale: Double) -> Double {
        let rms = amplitude / 2.0.squareRoot()
        switch scale {
        case .linear:
            return amplitude
        case .dBV:
            return 20 * log10(max(rms, 1e-12))
        case .dBu:
            return 20 * log10(max(rms, 1e-12) / 0.7745966692)
        case .dBFS:
            return 20 * log10(max(amplitude, 1e-12) / max(fullScale, 1e-12))
        }
    }

    /// Local maxima, strongest first, with the true peak interpolated between
    /// bins so a tone between two bins still reads its real frequency.
    public func peaks(limit: Int = 8, floor: Double = 1e-7) -> [SpectrumPeak] {
        guard amplitudes.count > 4 else { return [] }
        var found: [SpectrumPeak] = []
        for index in 1..<(amplitudes.count - 1) {
            let value = amplitudes[index]
            guard value > floor,
                  value >= amplitudes[index - 1],
                  value > amplitudes[index + 1] else { continue }
            found.append(interpolatedPeak(at: index))
        }
        return Array(found.sorted { $0.amplitude > $1.amplitude }.prefix(limit))
    }

    func interpolatedPeak(at index: Int) -> SpectrumPeak {
        guard index >= 1, index + 1 < amplitudes.count else {
            return SpectrumPeak(frequency: Double(index) * binWidth,
                                amplitude: amplitudes[index], bin: index)
        }
        // A parabola through the log of three bins: the standard correction for
        // a tone that does not land on a bin centre.
        let left = log(max(amplitudes[index - 1], 1e-18))
        let centre = log(max(amplitudes[index], 1e-18))
        let right = log(max(amplitudes[index + 1], 1e-18))
        let denominator = left - 2 * centre + right
        let shift = abs(denominator) < 1e-15 ? 0 : 0.5 * (left - right) / denominator
        let amplitude = exp(centre - 0.25 * (left - right) * shift)
        return SpectrumPeak(frequency: (Double(index) + shift) * binWidth,
                            amplitude: amplitude, bin: index)
    }
}

/// Distortion and noise figures, measured from a spectrum with one dominant tone.
public struct SpectrumQuality: Equatable, Sendable {
    public var fundamental: SpectrumPeak
    public var harmonics: [SpectrumPeak]
    /// Total harmonic distortion as a fraction of the fundamental.
    public var thd: Double
    /// Everything that is not the fundamental, as a fraction of it.
    public var thdPlusNoise: Double
    public var signalToNoiseDB: Double
    public var sinadDB: Double
    /// Effective number of bits the whole chain delivered.
    public var effectiveBits: Double

    public var thdPercent: Double { thd * 100 }
}

public enum SpectrumAnalyzer {
    /// Transforms one record into a single-sided amplitude spectrum.
    ///
    /// The record is trimmed to the largest power of two it contains, its mean
    /// is removed so the window does not turn a DC offset into a skirt, and the
    /// window's coherent gain is divided back out — so a 1 V sine reads 1 V
    /// whichever window is chosen.
    public static func transform(_ samples: [Double], sampleRate: Double,
                                 window: SpectrumWindow) -> Spectrum {
        guard samples.count >= 8, sampleRate > 0 else { return .empty }

        let log2n = Int(floor(log2(Double(samples.count))))
        let length = 1 << log2n
        guard length >= 8 else { return .empty }
        guard let setup = vDSP_create_fftsetupD(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else {
            return .empty
        }
        defer { vDSP_destroy_fftsetupD(setup) }

        var block = Array(samples.prefix(length))
        let mean = vDSP.mean(block)
        block = vDSP.add(-mean, block)

        let coefficients = window.coefficients(count: length)
        let coherentGain = vDSP.mean(coefficients)
        block = vDSP.multiply(block, coefficients)

        let half = length / 2
        var real = [Double](repeating: 0, count: half)
        var imaginary = [Double](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPDoubleSplitComplex(realp: realPointer.baseAddress!,
                                                  imagp: imaginaryPointer.baseAddress!)
                block.withUnsafeBufferPointer { source in
                    source.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: half) {
                        vDSP_ctozD($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zripD(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
            }
        }

        // vDSP's real transform packs DC and Nyquist into bin zero and returns
        // twice the mathematical coefficient, which is where the factors below
        // come from.
        let normaliser = Double(length) * max(coherentGain, 1e-12)
        var amplitudes = [Double](repeating: 0, count: half + 1)
        amplitudes[0] = abs(real[0]) / (2 * normaliser)
        amplitudes[half] = abs(imaginary[0]) / (2 * normaliser)
        for index in 1..<half {
            amplitudes[index] = (real[index] * real[index] + imaginary[index] * imaginary[index])
                .squareRoot() / normaliser
        }

        return Spectrum(amplitudes: amplitudes,
                        binWidth: sampleRate / Double(length),
                        sampleRate: sampleRate,
                        windowUsed: window)
    }

    /// Averages the latest contiguous set of compatible spectra, in power.
    public static func average(_ spectra: [Spectrum]) -> Spectrum {
        guard let latest = spectra.last else { return .empty }
        guard spectra.count > 1 else { return latest }
        let count = latest.amplitudes.count
        var power = [Double](repeating: 0, count: count)
        var used = 0
        for spectrum in spectra.reversed() {
            guard spectrum.amplitudes.count == count,
                  spectrum.sampleRate == latest.sampleRate,
                  spectrum.binWidth == latest.binWidth,
                  spectrum.windowUsed == latest.windowUsed else { break }
            for index in 0..<count { power[index] += spectrum.amplitudes[index] * spectrum.amplitudes[index] }
            used += 1
        }
        var result = latest
        result.amplitudes = power.map { ($0 / Double(used)).squareRoot() }
        return result
    }

    /// Measures distortion and noise around the strongest tone in the spectrum.
    public static func quality(of spectrum: Spectrum, harmonics harmonicCount: Int) -> SpectrumQuality? {
        guard spectrum.amplitudes.count > 8 else { return nil }
        let skirt = Int(ceil(spectrum.windowUsed.equivalentNoiseBandwidth)) + 1

        // Ignore the DC skirt: the mean was removed, but the window leaves a
        // little of it behind and it is not a tone.
        var strongest = skirt
        for index in skirt..<spectrum.amplitudes.count where spectrum.amplitudes[index] > spectrum.amplitudes[strongest] {
            strongest = index
        }
        guard spectrum.amplitudes[strongest] > 0 else { return nil }
        let fundamental = spectrum.interpolatedPeak(at: strongest)

        var claimed = Set<Int>()

        // Each bin belongs to exactly one thing. Without this the band around
        // a low harmonic re-counts the fundamental's own skirt, and a clean
        // tone reports distortion it does not have.
        func power(around bin: Int, claiming: Bool) -> Double {
            let low = max(bin - skirt, 0)
            let high = min(bin + skirt, spectrum.amplitudes.count - 1)
            guard low <= high else { return 0 }
            var total = 0.0
            for index in low...high where !claimed.contains(index) {
                total += spectrum.amplitudes[index] * spectrum.amplitudes[index]
                if claiming { claimed.insert(index) }
            }
            return total
        }

        for index in 0...skirt { claimed.insert(index) }
        let fundamentalPower = power(around: strongest, claiming: true)

        var harmonicList: [SpectrumPeak] = []
        var harmonicPower = 0.0
        if harmonicCount > 1 {
            for order in 2...max(harmonicCount, 2) {
                let bin = strongest * order
                guard bin + skirt < spectrum.amplitudes.count else { break }
                // A harmonic closer than two skirts to the fundamental is not
                // resolved from it, so it is not measurable — reporting it
                // would only be reporting the window.
                guard bin - strongest > 2 * skirt else { continue }
                harmonicPower += power(around: bin, claiming: true)
                harmonicList.append(spectrum.interpolatedPeak(at: bin))
            }
        }

        var noisePower = 0.0
        for index in (skirt + 1)..<spectrum.amplitudes.count where !claimed.contains(index) {
            noisePower += spectrum.amplitudes[index] * spectrum.amplitudes[index]
        }

        let thd = fundamentalPower > 0 ? (harmonicPower / fundamentalPower).squareRoot() : 0
        let rest = harmonicPower + noisePower
        let thdPlusNoise = fundamentalPower > 0 ? (rest / fundamentalPower).squareRoot() : 0
        let snr = 10 * log10(max(fundamentalPower, 1e-30) / max(noisePower, 1e-30))
        let sinad = 10 * log10(max(fundamentalPower, 1e-30) / max(rest, 1e-30))

        return SpectrumQuality(fundamental: fundamental, harmonics: harmonicList,
                               thd: thd, thdPlusNoise: thdPlusNoise,
                               signalToNoiseDB: snr, sinadDB: sinad,
                               effectiveBits: (sinad - 1.76) / 6.02)
    }
}
