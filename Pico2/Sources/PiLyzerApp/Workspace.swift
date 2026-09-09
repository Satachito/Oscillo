import PiLyzerCore
import SwiftUI

/// The chrome around every screen, laid out the way the browser application
/// lays out its own: a heading with the mode tabs, the instrument on a dark
/// card of its own, the readings on light cards beneath it.
///
/// Each screen supplies only three things — what goes in the legend strip, what
/// is drawn on the screen, and what the readings are — so all four share one
/// set of margins, one card and one status line rather than four that drift.
struct Workspace<Legend: View, Screen: View, Readings: View>: View {
    @ObservedObject var model: ScopeModel
    @ViewBuilder var legend: () -> Legend
    @ViewBuilder var screen: () -> Screen
    @ViewBuilder var readings: () -> Readings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            display
            readings().padding(.top, 14)
            foot
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(Theme.page)
    }

    // MARK: - Heading

    private var head: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("YOUR BENCH, ON YOUR DESK")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.7)
                    .foregroundStyle(Theme.muted)
                Text(title)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Theme.ink)
            }
            Spacer(minLength: 12)
            ModeTabs(mode: $model.settings.mode)
        }
        .padding(.bottom, 16)
    }

    private var title: String {
        switch model.settings.mode {
        case .scope: return "Oscilloscope"
        case .spectrum: return "Spectrum analyser"
        case .logic: return "Logic analyser"
        case .meter: return "Voltage meter"
        }
    }

    // MARK: - The instrument

    private var display: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                legend()
                Spacer(minLength: 8)
                Circle()
                    .fill(model.isRunning ? Theme.live : Theme.readout)
                    .frame(width: 7, height: 7)
                Text(model.statusText)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.readout)
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
            .overlay(alignment: .bottom) { hairline }

            screen()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                Text(timing)
                Spacer(minLength: 8)
                Text(triggerSummary)
            }
            .font(Theme.monoSmall)
            .foregroundStyle(Theme.readout)
            .lineLimit(1)
            .padding(.horizontal, 18)
            .frame(height: 32)
            .overlay(alignment: .top) { hairline }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.screen)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.screenEdge) }
    }

    /// What the acquisition actually did. The meter has no record, so it says
    /// how much history it is drawing instead.
    private var timing: String {
        guard model.settings.mode == .meter else { return model.planDescription }
        let readings = model.meter?.history.first?.count ?? 0
        return "\(readings) reading\(readings == 1 ? "" : "s")"
    }

    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.04)).frame(height: 1)
    }

    private var triggerSummary: String {
        switch model.settings.mode {
        case .meter:
            return "Immediate readings · all inputs"
        case .logic:
            return "Trigger: \(model.settings.logic.triggerMode.label) · D\(model.settings.logic.triggerChannel)"
        default:
            let filter = model.settings.trigger.lowPassHz > 0 && model.capabilities.hasTriggerLowPass
                ? " · LPF " + Format.frequency(Double(model.settings.trigger.lowPassHz)) : ""
            return "Trigger: \(model.settings.trigger.mode.label) · CH\(model.settings.trigger.source + 1)\(filter)"
        }
    }

    // MARK: - Footer

    private var foot: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.accent.opacity(0.55)).frame(width: 5, height: 5)
            Text("Signals stay on this Mac.")
            Spacer()
            if !model.isConnected, let hint = model.busHint {
                Text(hint).foregroundStyle(Theme.clip)
            } else {
                Text(model.isConnected ? "Connected over USB" : "No instrument connected")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.muted)
        .padding(.top, 14)
    }
}

/// The mode tabs, drawn as the browser application draws them: a soft trough
/// with the selected mode raised out of it. `Picker(.segmented)` would put a
/// system control in the middle of a page that is otherwise entirely our own.
struct ModeTabs: View {
    @Binding var mode: WorkMode

    var body: some View {
        HStack(spacing: 3) {
            ForEach(WorkMode.allCases, id: \.self) { candidate in
                Button {
                    mode = candidate
                } label: {
                    Text(candidate.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(candidate == mode ? Theme.accent : Theme.muted)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background {
                            if candidate == mode {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Theme.panel)
                                    .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(candidate == mode ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.line.opacity(0.55)))
    }
}

/// The strip of reading cards under the screen.
///
/// All four screens put something different down here — readings, distortion
/// figures, per-channel activity, decoded bytes — and each of those grows and
/// shrinks as measurements come and go. The trace above must not move when they
/// do, so the strip is sized by a hidden template of the tallest thing any
/// screen shows rather than by whatever is in it at the moment. Using a
/// template instead of a fixed number keeps it right if the font, the type size
/// or the translation changes.
struct MeasurementStrip<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            template.hidden().accessibilityHidden(true)
            HStack(alignment: .top, spacing: 12) { content() }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// One channel's worth of readings: a heading and seven values, which is
    /// the tallest card in the application.
    private var template: some View {
        MeasurementCard(title: "CH1", colour: Theme.channelColor(0)) {
            ForEach(0..<7, id: \.self) { _ in MeasurementRow("Vpp", "0 V") }
        }
    }
}

/// One card in that strip.
struct MeasurementCard<Content: View>: View {
    var title: String
    var colour: Color?
    @ViewBuilder var content: () -> Content

    init(title: String, colour: Color? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.colour = colour
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let colour {
                    Circle().fill(colour).frame(width: 7, height: 7)
                }
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 3) { content() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line) }
    }
}

/// A label on the left and a right-aligned reading, with the number and its
/// unit in columns of their own so changing digits or SI prefixes cannot move
/// anything.
struct MeasurementRow: View {
    var label: String
    var value: String

    init(_ label: String, _ value: String?) {
        self.label = label
        self.value = value ?? "—"
    }

    var body: some View {
        let parts = value.split(separator: " ", maxSplits: 1)
        let number = parts.first.map(String.init) ?? value
        let unit = parts.count > 1 ? String(parts[1]) : ""
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 6)
            Text(number)
                .font(Theme.mono)
                .foregroundStyle(Theme.ink)
            Text(unit)
                .font(Theme.mono)
                .foregroundStyle(Theme.ink)
                .frame(width: 22, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }
}

/// Shown in place of the cards when a screen has nothing to report yet.
struct MeasurementPlaceholder: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 22)
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
    }
}
