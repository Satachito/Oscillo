import PiLyzerCore
import SwiftUI

/// The oscilloscope screen: voltage against time, or one channel against the
/// other.
struct ScopeDisplayView: View {
    @ObservedObject var model: ScopeModel

    private let columns = ScopeSettings.horizontalDivisions
    private let rows = ScopeSettings.verticalDivisions

    var body: some View {
        VStack(spacing: 0) {
            Canvas { context, size in
                let grid = ScopeGrid(columns: columns, rows: rows)
                grid.draw(in: &context, size: size)
                if model.settings.showsXY {
                    drawXY(&context, size: size)
                } else {
                    drawTraces(&context, size: size)
                    drawTriggerMarkers(&context, size: size)
                    if model.cursorsEnabled { drawCursors(&context, size: size) }
                }
                drawBanner(&context, size: size)
            }
            .background(Theme.screen)
            .overlay(alignment: .topLeading) { legend.padding(8) }

            ReadoutRow(model: model)
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.frame.traces) { trace in
                let channel = trace.index
                let perDivision = voltsPerDivision(channel)
                HStack(spacing: 6) {
                    Text("CH\(channel + 1)")
                        .foregroundStyle(Theme.channelColor(channel))
                    Text(Format.voltage(perDivision) + "/div")
                        .foregroundStyle(Theme.readout)
                    if model.settings.channels[channel].removesMean {
                        Text("AC").foregroundStyle(Theme.readout)
                    }
                    if trace.clipped {
                        Text("CLIP").foregroundStyle(.red).bold()
                    }
                }
                .font(.system(size: 11, design: .monospaced))
            }
        }
    }

    private func voltsPerDivision(_ channel: Int) -> Double {
        guard channel < model.settings.channels.count else { return 1 }
        return model.settings.channels[channel].effectiveVoltsPerDivision(
            reference: model.capabilities.referenceVolts, ranges: model.ranges, divisions: rows)
    }

    private func y(_ volts: Double, channel: Int, height: CGFloat) -> CGFloat {
        let perDivision = voltsPerDivision(channel)
        guard perDivision > 0 else { return height / 2 }
        let position = channel < model.settings.channels.count
            ? model.settings.channels[channel].positionDivisions : 0
        let divisions = volts / perDivision + position
        return height / 2 - CGFloat(divisions) * height / CGFloat(rows)
    }

    private func drawTraces(_ context: inout GraphicsContext, size: CGSize) {
        let frame = model.frame
        guard frame.sampleCount > 1 else { return }
        let width = Int(size.width)

        for trace in frame.traces {
            let bands = envelope(trace.samples, width: max(width, 2))
            guard bands.count > 1 else { continue }
            var points: [CGPoint] = []
            points.reserveCapacity(bands.count * 2)
            for (index, band) in bands.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(bands.count - 1)
                points.append(CGPoint(x: x, y: y(band.high, channel: trace.index, height: size.height)))
                if band.low != band.high {
                    points.append(CGPoint(x: x, y: y(band.low, channel: trace.index, height: size.height)))
                }
            }
            context.strokeTrace(points, color: Theme.channelColor(trace.index))
        }
    }

    private func drawXY(_ context: inout GraphicsContext, size: CGSize) {
        guard let first = model.frame.trace(0), let second = model.frame.trace(1),
              first.samples.count > 1, second.samples.count == first.samples.count else { return }

        let horizontal = voltsPerDivision(0)
        let vertical = voltsPerDivision(1)
        guard horizontal > 0, vertical > 0 else { return }

        var points: [CGPoint] = []
        points.reserveCapacity(first.samples.count)
        for index in 0..<first.samples.count {
            let x = size.width / 2 + CGFloat(first.samples[index] / horizontal) * size.width / CGFloat(columns)
            let y = size.height / 2 - CGFloat(second.samples[index] / vertical) * size.height / CGFloat(rows)
            points.append(CGPoint(x: x, y: y))
        }
        context.strokeTrace(points, color: Theme.channelColor(0), width: 1.0)
    }

    private func drawTriggerMarkers(_ context: inout GraphicsContext, size: CGSize) {
        let frame = model.frame
        guard frame.sampleCount > 1 else { return }
        let source = min(max(model.settings.trigger.source, 0), model.settings.channels.count - 1)

        let level = y(model.settings.trigger.levelVolts, channel: source, height: size.height)
        if level.isFinite, level >= 0, level <= size.height {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: level))
            line.addLine(to: CGPoint(x: size.width, y: level))
            context.stroke(line, with: .color(Theme.trigger.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            context.draw(Text("T").font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.trigger),
                         at: CGPoint(x: size.width - 10, y: level - 8))
        }

        let x = size.width * CGFloat(frame.triggerIndex) / CGFloat(max(frame.sampleCount - 1, 1))
        var marker = Path()
        marker.move(to: CGPoint(x: x, y: 0))
        marker.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(marker, with: .color(Theme.trigger.opacity(0.35)),
                       style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
    }

    private func drawCursors(_ context: inout GraphicsContext, size: CGSize) {
        for fraction in [model.cursorA, model.cursorB] {
            let x = size.width * CGFloat(min(max(fraction, 0), 1))
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(Theme.cursor.opacity(0.8)), lineWidth: 1)
        }
    }

    private func drawBanner(_ context: inout GraphicsContext, size: CGSize) {
        guard model.frame.isEmpty else { return }
        let message = model.isConnected ? "Press Run" : "Connect an instrument, or pick the demo signal"
        context.draw(Text(message).font(.system(size: 13)).foregroundColor(Theme.readout),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
    }
}

/// The numbers under the screen.
struct ReadoutRow: View {
    @ObservedObject var model: ScopeModel

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ForEach(model.frame.traces) { trace in
                if let measured = model.measurements(for: trace.index) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("CH\(trace.index + 1)")
                            .foregroundStyle(Theme.channelColor(trace.index))
                            .bold()
                        row("Vpp", Format.voltage(measured.peakToPeak))
                        row("Mean", Format.voltage(measured.mean))
                        row("RMS", Format.voltage(measured.rms))
                        row("AC RMS", Format.voltage(measured.acRMS))
                        if let frequency = measured.frequency {
                            row("Freq", Format.frequency(frequency))
                        }
                        if let duty = measured.dutyCycle {
                            row("Duty", Format.percent(duty * 100, digits: 1))
                        }
                        if let rise = measured.riseTime {
                            row("Rise", Format.time(rise))
                        }
                    }
                }
            }

            if model.cursorsEnabled, model.frame.samplePeriod > 0 {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cursors").foregroundStyle(Theme.cursor).bold()
                    let span = abs(model.cursorB - model.cursorA) * model.frame.duration
                    row("Δt", Format.time(span))
                    row("1/Δt", span > 0 ? Format.frequency(1 / span) : "—")
                }
            }

            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(model.planDescription).foregroundStyle(.secondary)
                if model.settings.trigger.lowPassHz > 0 && model.capabilities.hasTriggerLowPass {
                    Text("Trigger LPF · " + Format.frequency(Double(model.settings.trigger.lowPassHz)))
                        .foregroundStyle(Theme.trigger)
                }
                Text(model.frame.triggered ? "Triggered" : "Not triggered")
                    .foregroundStyle(model.frame.triggered ? Theme.trigger : .secondary)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            Text(value)
        }
    }
}
