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
        VStack(spacing: 0) {
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
            .background(Theme.screen)

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
        HStack(alignment: .top, spacing: 14) {
            ForEach(model.logicActivity) { activity in
                VStack(alignment: .leading, spacing: 1) {
                    Text("D\(activity.channel)")
                        .foregroundStyle(Theme.logicColor(activity.channel)).bold()
                    if activity.isIdle {
                        Text("idle").foregroundStyle(.secondary)
                    } else {
                        Text(activity.frequency.map(Format.frequency) ?? "—")
                        Text(Format.percent((activity.dutyCycle ?? 0) * 100, digits: 0))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Text(model.planDescription).foregroundStyle(.secondary)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
    }
}

struct DecodedRow: View {
    @ObservedObject var model: ScopeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(model.decoder.label) · \(model.decoded.count) items")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.planDescription).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 6) {
                    ForEach(model.decoded) { item in
                        Text(item.text)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(colour(for: item.kind).opacity(0.18),
                                        in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(colour(for: item.kind))
                            .help(Format.time(model.logicFrame.time(at: item.start)))
                    }
                }
            }
            .frame(height: 26)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
    }

    private func colour(for kind: DecodedItem.Kind) -> Color {
        switch kind {
        case .data: return .primary
        case .control: return Theme.trigger
        case .error: return .red
        }
    }
}

/// The meter: both inputs read straight off the converter, with a rolling
/// chart of where they have been.
struct MeterView: View {
    @ObservedObject var model: ScopeModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 40) {
                ForEach(0..<min(2, model.settings.channels.count), id: \.self) { channel in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CH\(channel + 1)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.channelColor(channel))
                        // Fixed width: the reading changes length as it moves
                        // between millivolts and volts, and a box that resizes
                        // under a live number is unreadable.
                        Text(reading(channel))
                            .font(.system(size: 42, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.channelColor(channel))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(width: 230, alignment: .trailing)
                    }
                    .frame(width: 230, alignment: .leading)
                }
                Spacer()
            }
            .padding(20)

            Canvas { context, size in
                let grid = ScopeGrid(columns: 10, rows: 6)
                grid.draw(in: &context, size: size)
                drawHistory(&context, size: size)
            }
            .background(Theme.screen)

            HStack {
                Text(model.meter.map { "every \(Format.time($0.interval))" } ?? "—")
                Spacer()
                Text("\(model.meter?.history.first?.count ?? 0) points")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.thinMaterial)
        }
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
