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
                if model.settings.showsXY {
                    drawXYGrid(&context, size: size)
                    drawXY(&context, size: size)
                } else {
                    let grid = ScopeGrid(columns: columns, rows: rows)
                    grid.draw(in: &context, size: size)
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
                    // Say where the centre line is whenever it is not zero, or
                    // the offset looks like a fault rather than a choice.
                    if abs(centre(channel)) > 1e-6 {
                        Text("mid " + Format.voltage(centre(channel)))
                            .foregroundStyle(Theme.readout)
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

    /// The voltage on the centre line for a channel, before its own shift.
    private func centre(_ channel: Int) -> Double {
        // With the mean removed the samples already sit about zero, so zero is
        // where the centre line belongs. Centring such a channel on the middle
        // of its input range instead would push the trace a whole half-range
        // below the grid — off the bottom of the screen on a front end that
        // does not reach below zero.
        if channel < model.settings.channels.count,
           model.settings.channels[channel].removesMean { return 0 }
        return model.scale(for: channel).screenCentreVolts
    }

    private func y(_ volts: Double, channel: Int, height: CGFloat) -> CGFloat {
        let perDivision = voltsPerDivision(channel)
        guard perDivision > 0 else { return height / 2 }
        let position = channel < model.settings.channels.count
            ? model.settings.channels[channel].positionDivisions : 0
        // Measured from the middle of the range, not from zero: a front end
        // that cannot go below zero would otherwise draw everything in the top
        // half of the screen.
        let divisions = (volts - centre(channel)) / perDivision + position
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

    /// X/Y is read for its shape — a circle means quadrature, a line means in
    /// phase — so it is drawn on a square with equal divisions each way. The
    /// time-domain grid is 10 by 8 across the whole window, which would turn
    /// every circle into an ellipse.
    private func xySquare(_ size: CGSize) -> CGRect {
        let side = min(size.width, size.height)
        return CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                      width: side, height: side)
    }

    private func drawXYGrid(_ context: inout GraphicsContext, size: CGSize) {
        let square = xySquare(size)
        let step = square.width / CGFloat(rows)
        var lines = Path()
        for index in 0...rows {
            let offset = step * CGFloat(index)
            lines.move(to: CGPoint(x: square.minX + offset, y: square.minY))
            lines.addLine(to: CGPoint(x: square.minX + offset, y: square.maxY))
            lines.move(to: CGPoint(x: square.minX, y: square.minY + offset))
            lines.addLine(to: CGPoint(x: square.maxX, y: square.minY + offset))
        }
        context.stroke(lines, with: .color(Theme.grid), lineWidth: 1)

        var axes = Path()
        axes.move(to: CGPoint(x: square.midX, y: square.minY))
        axes.addLine(to: CGPoint(x: square.midX, y: square.maxY))
        axes.move(to: CGPoint(x: square.minX, y: square.midY))
        axes.addLine(to: CGPoint(x: square.maxX, y: square.midY))
        context.stroke(axes, with: .color(Theme.gridStrong), lineWidth: 1)
    }

    private func drawXY(_ context: inout GraphicsContext, size: CGSize) {
        let horizontalChannel = model.xyHorizontalChannel
        let verticalChannel = model.xyVerticalChannel
        guard let horizontal = model.frame.trace(horizontalChannel),
              let vertical = model.frame.trace(verticalChannel),
              horizontal.samples.count > 1,
              vertical.samples.count == horizontal.samples.count else { return }

        let perX = voltsPerDivision(horizontalChannel)
        let perY = voltsPerDivision(verticalChannel)
        guard perX > 0, perY > 0 else { return }

        let square = xySquare(size)
        let step = square.width / CGFloat(rows)
        let centreX = centre(horizontalChannel), centreY = centre(verticalChannel)

        var points: [CGPoint] = []
        points.reserveCapacity(horizontal.samples.count)
        for index in 0..<horizontal.samples.count {
            points.append(CGPoint(
                x: square.midX + CGFloat((horizontal.samples[index] - centreX) / perX) * step,
                y: square.midY - CGFloat((vertical.samples[index] - centreY) / perY) * step))
        }
        context.strokeTrace(points, color: Theme.channelColor(verticalChannel), width: 1.0)

        context.draw(Text("X: CH\(horizontalChannel + 1)   Y: CH\(verticalChannel + 1)")
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(Theme.readout),
                     at: CGPoint(x: square.midX, y: square.maxY - 8))
    }

    private func drawTriggerMarkers(_ context: inout GraphicsContext, size: CGSize) {
        let frame = model.frame
        guard frame.sampleCount > 1 else { return }
        let source = min(max(model.settings.trigger.source, 0), model.settings.channels.count - 1)

        // The trigger works on the raw signal, so on a channel whose mean has
        // been taken out the level has to move by the same amount to sit where
        // the trace actually crosses it.
        let removed = frame.trace(source)?.removedMean ?? 0
        let level = y(model.settings.trigger.levelVolts - removed, channel: source, height: size.height)
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
        Footer { content }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 24) {
            // Driven by the enabled channels rather than by whatever the last
            // frame contained, and every reading always occupies its line. A
            // grounded input has no edges, so its frequency, duty and rise time
            // have no value — but the footer must not change height as a
            // measurement comes and goes underneath the trace.
            ForEach(model.enabledAnalogChannels, id: \.self) { channel in
                let measured = model.measurements(for: channel)
                VStack(alignment: .leading, spacing: 1) {
                    Text("CH\(channel + 1)")
                        .foregroundStyle(Theme.channelColor(channel))
                        .bold()
                    row("Vpp", measured.map { Format.voltage($0.peakToPeak) })
                    row("Mean", measured.map { Format.voltage($0.mean) })
                    row("RMS", measured.map { Format.voltage($0.rms) })
                    row("AC RMS", measured.map { Format.voltage($0.acRMS) })
                    row("Freq", measured?.frequency.map(Format.frequency))
                    row("Duty", measured?.dutyCycle.map { Format.percent($0 * 100, digits: 1) })
                    row("Rise", measured?.riseTime.map(Format.time))
                }
            }

            if model.cursorsEnabled, model.frame.samplePeriod > 0 {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cursors").foregroundStyle(Theme.cursor).bold()
                    let span = abs(model.cursorB - model.cursorA) * model.frame.duration
                    row("Δt", Format.time(span))
                    row("1/Δt", span > 0 ? Format.frequency(1 / span) : nil)
                }
            }

            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(model.planDescription).foregroundStyle(.secondary)
                // Kept in the layout whether or not the filter is on, for the
                // same reason as the readings above.
                Text(model.settings.trigger.lowPassHz > 0 && model.capabilities.hasTriggerLowPass
                     ? "Trigger LPF · " + Format.frequency(Double(model.settings.trigger.lowPassHz))
                     : " ")
                    .foregroundStyle(Theme.trigger)
                Text(model.frame.triggered ? "Triggered" : "Not triggered")
                    .foregroundStyle(model.frame.triggered ? Theme.trigger : .secondary)
            }
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        row(label, value ?? "—")
    }

    private func row(_ label: String, _ value: String) -> some View {
        // Format separates the numeric reading and engineering unit with a space.
        // Keep both columns fixed so changing digits or SI prefixes cannot move them.
        let parts = value.split(separator: " ", maxSplits: 1)
        let number = parts.first.map(String.init) ?? value
        let unit = parts.count > 1 ? String(parts[1]) : ""
        return HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            Text(number).frame(width: 60, alignment: .trailing)
            Text(unit).frame(width: 24, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }
}
