import PiLyzerCore
import SwiftUI

/// The spectrum analyser screen.
struct SpectrumView: View {
    @ObservedObject var model: ScopeModel

    private var settings: SpectrumSettings { model.settings.spectrum }
    /// Every channel comes from the same record, so any one of them sets the
    /// frequency axis for all.
    private var axis: Spectrum { model.spectra.first?.spectrum ?? .empty }

    var body: some View {
        Workspace(model: model) {
            legend
        } screen: {
            Canvas { context, size in
                drawGrid(&context, size: size)
                drawSpectrum(&context, size: size)
                if settings.showsPeakMarkers { drawPeaks(&context, size: size) }
                if model.spectra.isEmpty {
                    context.draw(Text("Press Run").font(.system(size: 13)).foregroundColor(Theme.readout),
                                 at: CGPoint(x: size.width / 2, y: size.height / 2))
                }
            }
        } readings: {
            QualityRow(model: model)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(model.spectra) { entry in
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.channelColor(entry.channel))
                        .frame(width: 6, height: 6)
                    Text("CH\(entry.channel + 1)")
                        .foregroundStyle(Theme.channelColor(entry.channel))
                }
            }
            Text(settings.window.rawValue).foregroundStyle(Theme.readout)
            Text("\(settings.averaging)× avg").foregroundStyle(Theme.readout)
            Text("\(Format.frequency(axis.binWidth)) per bin")
                .foregroundStyle(Theme.readout)
        }
        .font(Theme.monoSmall)
        .lineLimit(1)
    }

    // MARK: - Axes

    private var levelRange: ClosedRange<Double> {
        switch settings.scale {
        case .linear:
            let top = max(model.spectra.compactMap { $0.spectrum.amplitudes.max() }.max() ?? 1, 1e-9)
            return 0...top
        case .dBFS:
            return -120...0
        default:
            return -120...20
        }
    }

    private func x(_ frequency: Double, width: CGFloat) -> CGFloat {
        let top = max(axis.nyquist, 1)
        if settings.logarithmicFrequency {
            let bottom = max(axis.binWidth, 1)
            guard frequency > bottom else { return 0 }
            let span = log10(top / bottom)
            guard span > 0 else { return 0 }
            return width * CGFloat(log10(frequency / bottom) / span)
        }
        return width * CGFloat(frequency / top)
    }

    private func y(_ level: Double, height: CGFloat) -> CGFloat {
        let range = levelRange
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return height }
        let fraction = (level - range.lowerBound) / span
        return height * CGFloat(1 - min(max(fraction, 0), 1))
    }

    private func drawGrid(_ context: inout GraphicsContext, size: CGSize) {
        var horizontal = Path()
        for row in 1..<8 {
            let position = size.height * CGFloat(row) / 8
            horizontal.move(to: CGPoint(x: 0, y: position))
            horizontal.addLine(to: CGPoint(x: size.width, y: position))
        }
        context.stroke(horizontal, with: .color(Theme.grid), lineWidth: 1)

        let range = levelRange
        for row in 0...8 {
            let level = range.upperBound - (range.upperBound - range.lowerBound) * Double(row) / 8
            let text = settings.scale == .linear ? Format.voltage(level) : String(format: "%.0f", level)
            context.draw(Text(text).font(.system(size: 9, design: .monospaced))
                .foregroundColor(Theme.readout),
                         at: CGPoint(x: 24, y: size.height * CGFloat(row) / 8 + 6))
        }

        var vertical = Path()
        let nyquist = max(axis.nyquist, 1)
        var marks: [Double] = []
        if settings.logarithmicFrequency {
            var decade = 1.0
            while decade <= nyquist {
                for multiplier in [1.0, 2.0, 5.0] where decade * multiplier <= nyquist {
                    marks.append(decade * multiplier)
                }
                decade *= 10
            }
        } else {
            marks = (1..<10).map { nyquist * Double($0) / 10 }
        }
        for mark in marks {
            let position = x(mark, width: size.width)
            guard position > 1 else { continue }
            vertical.move(to: CGPoint(x: position, y: 0))
            vertical.addLine(to: CGPoint(x: position, y: size.height))
            context.draw(Text(Format.frequency(mark)).font(.system(size: 9, design: .monospaced))
                .foregroundColor(Theme.readout),
                         at: CGPoint(x: position, y: size.height - 8))
        }
        context.stroke(vertical, with: .color(Theme.grid), lineWidth: 1)
    }

    private func drawSpectrum(_ context: inout GraphicsContext, size: CGSize) {
        for entry in model.spectra {
            let spectrum = entry.spectrum
            guard spectrum.count > 2 else { continue }
            var points: [CGPoint] = []
            points.reserveCapacity(spectrum.count)
            for index in 1..<spectrum.count {
                let frequency = Double(index) * spectrum.binWidth
                let level = spectrum.value(at: index, scale: settings.scale, fullScale: entry.fullScale)
                points.append(CGPoint(x: x(frequency, width: size.width), y: y(level, height: size.height)))
            }
            context.strokeTrace(points, color: Theme.channelColor(entry.channel), width: 1.2)
        }
    }

    /// Marked in each channel's own colour. With more than one channel on
    /// screen only the strongest two apiece are labelled, or the labels bury
    /// the traces they describe.
    private func drawPeaks(_ context: inout GraphicsContext, size: CGSize) {
        let limit = model.spectra.count > 1 ? 2 : 5
        for entry in model.spectra {
            let colour = model.spectra.count > 1 ? Theme.channelColor(entry.channel) : Theme.trigger
            for peak in entry.spectrum.peaks(limit: limit) {
                let position = CGPoint(x: x(peak.frequency, width: size.width),
                                       y: y(Spectrum.convert(amplitude: peak.amplitude,
                                                             scale: settings.scale,
                                                             fullScale: entry.fullScale),
                                            height: size.height))
                guard position.x > 1 else { continue }
                context.stroke(Path(ellipseIn: CGRect(x: position.x - 3, y: position.y - 3,
                                                      width: 6, height: 6)),
                               with: .color(colour), lineWidth: 1)
                context.draw(Text(Format.frequency(peak.frequency))
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(colour),
                             at: CGPoint(x: position.x, y: max(position.y - 12, 8)))
            }
        }
    }
}

/// Distortion and noise, measured from the spectrum on screen: one card for
/// each channel, and the harmonics beside it when there is only one.
struct QualityRow: View {
    @ObservedObject var model: ScopeModel

    var body: some View {
        MeasurementStrip {
            let measured = model.spectra.filter { $0.quality != nil }
            if measured.isEmpty {
                MeasurementPlaceholder(text: "A tone has to be on screen before its distortion can be measured.")
            } else {
                ForEach(measured) { entry in
                    if let quality = entry.quality {
                        MeasurementCard(title: "Channel \(entry.channel + 1)",
                                        colour: Theme.channelColor(entry.channel)) {
                            MeasurementRow("Frequency", Format.frequency(quality.fundamental.frequency))
                            MeasurementRow("Level", Format.voltage(quality.fundamental.amplitude))
                            MeasurementRow("THD", Format.percent(quality.thdPercent))
                            MeasurementRow("THD+N", Format.percent(quality.thdPlusNoise * 100))
                            MeasurementRow("SNR", Format.decibels(quality.signalToNoiseDB))
                            MeasurementRow("SINAD", Format.decibels(quality.sinadDB))
                            MeasurementRow("ENOB", String(format: "%.1f bits", quality.effectiveBits))
                        }
                    }
                }
                if measured.count == 1, let quality = measured[0].quality {
                    MeasurementCard(title: "Harmonics") {
                        ForEach(Array(quality.harmonics.prefix(5).enumerated()), id: \.offset) { index, peak in
                            MeasurementRow("H\(index + 2)", Format.voltage(peak.amplitude))
                        }
                    }
                }
            }
        }
    }
}
