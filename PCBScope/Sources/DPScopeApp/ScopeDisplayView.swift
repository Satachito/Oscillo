import DPScopeCore
import SwiftUI

enum Theme {
    static let screen = Color(red: 0.04, green: 0.06, blue: 0.08)
    static let grid = Color.white.opacity(0.10)
    static let axis = Color.white.opacity(0.28)
    static let channel1 = Color(red: 1.0, green: 0.83, blue: 0.15)
    static let channel2 = Color(red: 0.31, green: 0.85, blue: 0.91)
    static let trigger = Color(red: 1.0, green: 0.42, blue: 0.42)
    static let label = Color.white.opacity(0.65)

    static func color(forChannel channel: Int) -> Color {
        channel == 0 ? channel1 : channel2
    }
}

/// The scope screen: grid, traces, trigger marker and readouts.
struct ScopeDisplayView: View {
    let frame: ScopeFrame
    let settings: ScopeSettings
    let mode: DisplayMode
    /// Every voltage on screen is scaled by the measured supply rail.
    let supplyVoltage: Double

    private static let horizontalDivisions = ScopeGrid.horizontalDivisions
    private static let verticalDivisions = ScopeGrid.verticalDivisions

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .color(Theme.screen))
            context.clip(to: Path(rect))

            drawGrid(in: &context, rect: rect)

            switch mode {
            case .time:
                drawTimeTraces(in: &context, rect: rect)
                drawTriggerLevel(in: &context, rect: rect)
            case .xy:
                drawXY(in: &context, rect: rect)
            case .spectrum:
                drawSpectrum(in: &context, rect: rect)
            }

            drawLegend(in: &context, rect: rect)
        }
        .background(Theme.screen)
        .overlay(alignment: .center) {
            if frame.isEmpty {
                Text(placeholder)
                    .font(.callout)
                    .foregroundStyle(Theme.label)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12)))
    }

    private var placeholder: String {
        settings.hasEnabledChannel
            ? "Connect the DPScope SE (or pick the demo source) and press Run"
            : "Both channels are switched off"
    }

    // MARK: - Grid

    private func drawGrid(in context: inout GraphicsContext, rect: CGRect) {
        let columns = Self.horizontalDivisions
        let rows = Self.verticalDivisions
        var minor = Path()
        for column in 1..<columns {
            let x = rect.width * CGFloat(column) / CGFloat(columns)
            minor.move(to: CGPoint(x: x, y: 0))
            minor.addLine(to: CGPoint(x: x, y: rect.height))
        }
        for row in 1..<rows {
            let y = rect.height * CGFloat(row) / CGFloat(rows)
            minor.move(to: CGPoint(x: 0, y: y))
            minor.addLine(to: CGPoint(x: rect.width, y: y))
        }
        context.stroke(minor, with: .color(Theme.grid), lineWidth: 1)

        var centre = Path()
        centre.move(to: CGPoint(x: rect.midX, y: 0))
        centre.addLine(to: CGPoint(x: rect.midX, y: rect.height))
        centre.move(to: CGPoint(x: 0, y: rect.midY))
        centre.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        context.stroke(centre, with: .color(Theme.axis), lineWidth: 1)
    }

    // MARK: - Traces

    private func divisionHeight(_ rect: CGRect) -> CGFloat {
        rect.height / CGFloat(Self.verticalDivisions)
    }

    private func y(for volts: Double, channel: ChannelSettings, rect: CGRect) -> CGFloat {
        let perDivision = channel.voltsPerDivision(supply: supplyVoltage)
        guard perDivision > 0 else { return rect.midY }
        let divisions = volts / perDivision + channel.positionDivisions
        return rect.midY - CGFloat(divisions) * divisionHeight(rect)
    }

    private func drawTimeTraces(in context: inout GraphicsContext, rect: CGRect) {
        for channel in 0..<2 {
            let configuration = channel == 0 ? settings.channel1 : settings.channel2
            let samples = frame.samples(for: channel)
            guard configuration.isEnabled, samples.count > 1 else { continue }

            var path = Path()
            let step = rect.width / CGFloat(samples.count - 1)
            for (index, volts) in samples.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step, y: y(for: volts, channel: configuration, rect: rect))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(Theme.color(forChannel: channel)), lineWidth: 1.5)
        }
    }

    private func drawTriggerLevel(in context: inout GraphicsContext, rect: CGRect) {
        guard settings.mode == .scope, settings.trigger.mode == .normal else { return }
        guard settings.trigger.source == .channel1, settings.channel1.isEnabled else { return }

        let channel = settings.channel1
        let level = settings.trigger.levelVolts(channel: channel, supply: supplyVoltage)
        let position = y(for: level, channel: channel, rect: rect)
        guard rect.minY...rect.maxY ~= position else { return }

        var path = Path()
        path.move(to: CGPoint(x: 0, y: position))
        path.addLine(to: CGPoint(x: rect.width, y: position))
        context.stroke(
            path,
            with: .color(Theme.trigger.opacity(0.8)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
        )
        context.draw(
            Text("T").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.trigger),
            at: CGPoint(x: rect.width - 10, y: position - 8)
        )
    }

    private func drawXY(in context: inout GraphicsContext, rect: CGRect) {
        let horizontal = settings.channel1
        let vertical = settings.channel2
        let count = min(frame.channel1.count, frame.channel2.count)
        guard count > 1 else { return }

        let divisionWidth = rect.width / CGFloat(Self.horizontalDivisions)
        let horizontalPerDivision = horizontal.voltsPerDivision(supply: supplyVoltage)
        guard horizontalPerDivision > 0 else { return }
        var path = Path()
        for index in 0..<count {
            let divisions = frame.channel1[index] / horizontalPerDivision + horizontal.positionDivisions
            let x = rect.midX + CGFloat(divisions) * divisionWidth
            let point = CGPoint(x: x, y: y(for: frame.channel2[index], channel: vertical, rect: rect))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.stroke(path, with: .color(Theme.channel1), lineWidth: 1.2)
    }

    private func drawSpectrum(in context: inout GraphicsContext, rect: CGRect) {
        var spectra: [(channel: Int, frequencies: [Double], magnitudes: [Double])] = []
        for channel in 0..<2 {
            let configuration = channel == 0 ? settings.channel1 : settings.channel2
            guard configuration.isEnabled else { continue }
            let result = magnitudeSpectrum(frame.samples(for: channel), sampleInterval: frame.sampleInterval)
            guard !result.magnitudes.isEmpty else { continue }
            spectra.append((channel, result.frequencies, result.magnitudes))
        }
        guard !spectra.isEmpty else { return }

        let peak = spectra.flatMap(\.magnitudes).max() ?? 1
        guard peak > 0 else { return }
        let maximumFrequency = spectra.map { $0.frequencies.last ?? 1 }.max() ?? 1

        for spectrum in spectra {
            var path = Path()
            for (index, magnitude) in spectrum.magnitudes.enumerated() {
                let x = rect.width * CGFloat(spectrum.frequencies[index] / maximumFrequency)
                let y = rect.maxY - rect.height * CGFloat(magnitude / peak) * 0.92
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(Theme.color(forChannel: spectrum.channel)), lineWidth: 1.2)
        }

        // Frequency axis: a label every second division, plus the peak value.
        for division in stride(from: 0, through: Self.horizontalDivisions, by: 2) {
            let fraction = Double(division) / Double(Self.horizontalDivisions)
            let x = rect.width * CGFloat(fraction)
            context.draw(
                Text(Format.frequency(maximumFrequency * fraction))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.label),
                at: CGPoint(x: min(max(x, 26), rect.maxX - 26), y: rect.maxY - 9)
            )
        }
        context.draw(
            Text("peak \(Format.voltage(peak))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.label),
            at: CGPoint(x: rect.maxX - 8, y: 12),
            anchor: .trailing
        )
    }

    // MARK: - Legend

    private func drawLegend(in context: inout GraphicsContext, rect: CGRect) {
        var lines: [(String, Color)] = []
        for (index, channel) in [settings.channel1, settings.channel2].enumerated() where channel.isEnabled {
            let perDivision = Format.voltage(channel.voltsPerDivision(supply: supplyVoltage))
            let clip = frame.isClipped(index) ? "  CLIP" : ""
            lines.append(("Ch\(index + 1) \(perDivision)/div \(channel.probeAttenuation.label)\(clip)",
                          frame.isClipped(index) ? Theme.trigger : Theme.color(forChannel: index)))
        }

        var horizontal = mode == .spectrum
            ? "FFT"
            : (settings.mode == .datalog
                ? "\(Format.time(frame.duration)) total"
                : settings.timebase.label)
        if settings.mode == .scope, settings.timebase.mode == .equivalentTime, mode != .spectrum {
            horizontal += "  ET"
        }
        lines.append((horizontal, Theme.label))

        for (index, line) in lines.enumerated() {
            context.draw(
                Text(line.0).font(.system(size: 10, design: .monospaced)).foregroundColor(line.1),
                at: CGPoint(x: 8, y: 12 + CGFloat(index) * 14),
                anchor: .leading
            )
        }
    }
}
