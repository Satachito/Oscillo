import PiLyzerCore
import SwiftUI

/// The logic analyser screen: eight traces, and whatever the decoder made of
/// them underneath.
struct LogicView: View {
    @ObservedObject var model: ScopeModel

    private var frame: LogicFrame { model.logicFrame }
    private var visibleChannels: [Int] {
        (0..<frame.channelCount).filter { model.settings.logic.enabledChannels.contains($0) }
    }

    var body: some View {
        Workspace(model: model) {
            Text("D0–D7 · 3.3 V logic")
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.readout)
        } screen: {
            Canvas { context, size in
                drawTimeGrid(&context, size: size)
                drawChannels(&context, size: size)
                drawTrigger(&context, size: size)
                if frame.isEmpty {
                    context.draw(Text("Press Run").font(.system(size: 13))
                        .foregroundColor(Theme.readout),
                                 at: CGPoint(x: size.width / 2, y: size.height / 2))
                }
            }
        } readings: {
            if model.decoderKind == .none {
                LogicActivityRow(model: model)
            } else {
                DecodedRow(model: model)
            }
        }
    }

    private func laneHeight(_ size: CGSize) -> CGFloat {
        let lanes = max(visibleChannels.count, 1)
        return size.height / CGFloat(lanes)
    }

    private func drawTimeGrid(_ context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        for column in 1..<ScopeSettings.horizontalDivisions {
            let x = size.width * CGFloat(column) / CGFloat(ScopeSettings.horizontalDivisions)
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(path, with: .color(Theme.grid), lineWidth: 1)
    }

    private func drawChannels(_ context: inout GraphicsContext, size: CGSize) {
        guard frame.samples.count > 1 else { return }
        let lane = laneHeight(size)
        let inset = lane * 0.22
        let width = max(Int(size.width), 2)

        for (row, channel) in visibleChannels.enumerated() {
            let top = lane * CGFloat(row) + inset
            let bottom = lane * CGFloat(row + 1) - inset
            var points: [CGPoint] = []
            var previous: Bool?

            for column in 0..<width {
                let index = frame.samples.count * column / width
                let end = max(frame.samples.count * (column + 1) / width, index + 1)
                var anyHigh = false, anyLow = false
                for position in index..<min(end, frame.samples.count) {
                    if frame.level(channel, at: position) { anyHigh = true } else { anyLow = true }
                }
                let x = size.width * CGFloat(column) / CGFloat(width - 1)

                // A column holding both levels is drawn as a full-height bar,
                // which is how a scope shows a signal faster than the screen.
                if anyHigh && anyLow {
                    points.append(CGPoint(x: x, y: top))
                    points.append(CGPoint(x: x, y: bottom))
                    previous = nil
                } else {
                    let level = anyHigh
                    let y = level ? top : bottom
                    if let previous, previous != level {
                        points.append(CGPoint(x: x, y: previous ? top : bottom))
                    }
                    points.append(CGPoint(x: x, y: y))
                    previous = level
                }
            }
            context.strokeTrace(points, color: Theme.logicColor(channel), width: 1.3)

            context.draw(Text("D\(channel)").font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.logicColor(channel)),
                         at: CGPoint(x: 14, y: lane * CGFloat(row) + lane / 2))
        }
    }

    private func drawTrigger(_ context: inout GraphicsContext, size: CGSize) {
        guard frame.samples.count > 1 else { return }
        let x = size.width * CGFloat(frame.triggerIndex) / CGFloat(frame.samples.count - 1)
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(path, with: .color(Theme.trigger.opacity(0.45)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
    }
}

struct LogicActivityRow: View {
    @ObservedObject var model: ScopeModel

    var body: some View {
        MeasurementStrip {
            if model.logicActivity.isEmpty {
                MeasurementPlaceholder(text: "Digital inputs D0–D7 · pick a decoder to inspect a serial signal.")
            } else {
                ForEach(model.logicActivity) { activity in
                    MeasurementCard(title: "D\(activity.channel)",
                                    colour: Theme.logicColor(activity.channel)) {
                        if activity.isIdle {
                            MeasurementRow("State", model.logicFrame.level(activity.channel, at: 0)
                                           ? "idle high" : "idle low")
                        } else {
                            MeasurementRow("Frequency", activity.frequency.map(Format.frequency))
                            MeasurementRow("Duty", activity.dutyCycle.map { Format.percent($0 * 100, digits: 0) })
                        }
                    }
                }
            }
        }
    }
}

struct DecodedRow: View {
    @ObservedObject var model: ScopeModel

    var body: some View {
        MeasurementStrip {
            MeasurementCard(title: "\(model.decoder.label) · \(model.decoded.count) items") {
                if model.decoded.isEmpty {
                    Text("Nothing decoded from this record yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        FlowingBytes(items: model.decoded, model: model)
                    }
                }
            }
        }
    }
}

/// The decoded bytes, wrapped the way the browser application wraps them
/// rather than run off the side of a one-line strip.
struct FlowingBytes: View {
    var items: [DecodedItem]
    @ObservedObject var model: ScopeModel

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 5)],
                  alignment: .leading, spacing: 5) {
            ForEach(items) { item in
                Text(item.text)
                    .font(Theme.monoSmall)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(background(for: item.kind),
                                in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(foreground(for: item.kind))
                    .help(Format.time(model.logicFrame.time(at: item.start)))
            }
        }
    }

    private func background(for kind: DecodedItem.Kind) -> Color {
        switch kind {
        case .data: return Theme.line.opacity(0.7)
        case .control: return Theme.accentSoft.opacity(0.6)
        case .error: return Theme.clip.opacity(0.28)
        }
    }

    private func foreground(for kind: DecodedItem.Kind) -> Color {
        switch kind {
        case .data: return Theme.ink
        case .control: return Theme.accent
        case .error: return Color(red: 0.61, green: 0.30, blue: 0.19)
        }
    }
}

/// The meter: all inputs read straight off the converter, with a rolling
/// chart of where they have been.
struct MeterView: View {
    @ObservedObject var model: ScopeModel

    var body: some View {
        Workspace(model: model) {
            Text(model.meter.map { "reading every \(Format.time($0.interval))" } ?? "—")
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.readout)
        } screen: {
            // The readings sit on the screen itself, over the history, exactly
            // as they do in the browser application.
            Canvas { context, size in
                let grid = ScopeGrid(columns: 10, rows: 6)
                grid.draw(in: &context, size: size)
                drawHistory(&context, size: size)
            }
            .overlay(alignment: .top) { readings }
        } readings: {
            MeasurementStrip {
                MeasurementPlaceholder(text: "Meter readings are DC coupled. Ground the inputs before checking offsets.")
            }
        }
    }

    private var readings: some View {
        HStack(spacing: 20) {
            ForEach(model.availableAnalogChannels, id: \.self) { channel in
                VStack(alignment: .leading, spacing: 6) {
                    Text("CH\(channel + 1)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.readout)
                    // Fixed width: the reading changes length as it moves
                    // between millivolts and volts, and a box that resizes
                    // under a live number is unreadable.
                    Text(reading(channel))
                        .font(.system(size: 34, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.channelColor(channel))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
    }

    private func reading(_ channel: Int) -> String {
        guard let meter = model.meter, channel < meter.volts.count else { return "—" }
        return Format.voltage(meter.volts[channel])
    }

    private func drawHistory(_ context: inout GraphicsContext, size: CGSize) {
        guard let meter = model.meter else { return }
        let series = meter.history.filter { !$0.isEmpty }
        guard !series.isEmpty else { return }

        let low = series.flatMap { $0 }.min() ?? 0
        let high = series.flatMap { $0 }.max() ?? 1
        let span = max(high - low, 1e-6)

        for (channel, values) in series.enumerated() {
            let bands = envelope(values, width: max(Int(size.width), 2))
            guard bands.count > 1 else { continue }
            var points: [CGPoint] = []
            for (index, band) in bands.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(bands.count - 1)
                let middle = (band.low + band.high) / 2
                points.append(CGPoint(x: x, y: size.height * CGFloat(1 - (middle - low) / span)))
            }
            context.strokeTrace(points, color: Theme.channelColor(channel), width: 1.2)
        }
    }
}
