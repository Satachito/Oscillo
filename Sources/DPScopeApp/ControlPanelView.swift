import DPScopeCore
import SwiftUI

/// The instrument's front panel, mirroring the sections of the original app:
/// acquisition, display, vertical, horizontal and trigger.
struct ControlPanelView: View {
    @ObservedObject var model: ScopeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                acquisition
                display
                vertical
                horizontal
                trigger
            }
            .padding(14)
        }
        .frame(width: 300)
    }

    // MARK: - Acquisition

    private var acquisition: some View {
        Section("Acquisition") {
            Picker("Mode", selection: $model.settings.mode) {
                ForEach(AcquisitionMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                // Run/stop also has ⌘R in the Scope menu; a bare Space shortcut
                // here would fight AppKit's "space activates the focused
                // control" behaviour in a panel full of checkboxes.
                Button(model.isRunning ? "Stop" : "Run") { model.toggleRun() }
                    .disabled(!model.isConnected)
                Button("Single") { model.single() }
                    .disabled(!model.isConnected || model.isRunning || model.settings.mode == .datalog)
                Button("Clear") { model.clear() }
            }

            Stepper(
                "Averaging: \(model.settings.averaging)×",
                value: $model.settings.averaging,
                in: 1...100
            )
            .disabled(model.settings.mode == .datalog)
        }
    }

    // MARK: - Display

    private var display: some View {
        Section("Display") {
            Picker("View", selection: $model.displayMode) {
                ForEach(DisplayMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Toggle("Channel 1", isOn: $model.settings.channel1.isEnabled)
                .toggleStyle(.checkbox)
                .tint(Theme.channel1)
            Toggle("Channel 2", isOn: $model.settings.channel2.isEnabled)
                .toggleStyle(.checkbox)
            Toggle("Measurements", isOn: $model.showMeasurements)
                .toggleStyle(.checkbox)

            if model.displayMode == .xy && !(model.settings.channel1.isEnabled && model.settings.channel2.isEnabled) {
                Label("X/Y needs both channels", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Vertical

    private var vertical: some View {
        Section("Vertical") {
            channelControls(index: 0, settings: $model.settings.channel1)
            Divider()
            channelControls(index: 1, settings: $model.settings.channel2)
            Divider()
            zeroCalibration
        }
    }

    /// The board's offset trimmers rarely land exactly on mid-scale, and the
    /// ×10 stage multiplies whatever is left, so measuring the zero point is
    /// worth a button.
    private var zeroCalibration: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Calibrate Zero") { model.calibrateZero() }
                    .disabled(!model.isConnected || model.isRunning)
                if model.settings.channel1.isZeroCalibrated || model.settings.channel2.isZeroCalibrated {
                    Button("Reset") { model.resetZeroCalibration() }
                }
            }
            Text(zeroSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var zeroSummary: String {
        let channel1 = model.settings.channel1
        let channel2 = model.settings.channel2
        guard channel1.isZeroCalibrated || channel2.isZeroCalibrated else {
            return "Ground both inputs, then calibrate. Until then the nominal 512 is used."
        }
        return String(
            format: "Zero codes — Ch1 %.0f/%.0f, Ch2 %.0f/%.0f (×1/×10)",
            channel1.zeroGain1, channel1.zeroGain10, channel2.zeroGain1, channel2.zeroGain10
        )
    }

    private func channelControls(index: Int, settings: Binding<ChannelSettings>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.color(forChannel: index))
                    .frame(width: 8, height: 8)
                Text("Channel \(index + 1)").font(.subheadline.weight(.semibold))
            }

            Picker("Range", selection: settings.rangeIndex) {
                ForEach(Array(VerticalRange.all.enumerated()), id: \.offset) { offset, range in
                    Text(range.label(supply: model.supplyVoltage, probe: settings.wrappedValue.probeAttenuation))
                        .tag(offset)
                }
            }

            LabeledContent("Per division") {
                Text(Format.voltage(settings.wrappedValue.voltsPerDivision(supply: model.supplyVoltage)))
                    .font(.caption.monospacedDigit())
            }

            Picker("Probe", selection: settings.probeAttenuation) {
                ForEach(ProbeAttenuation.allCases, id: \.self) { attenuation in
                    Text(attenuation.label).tag(attenuation)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Position").font(.caption).foregroundStyle(.secondary)
                Slider(value: settings.positionDivisions, in: -4...4, step: 0.1)
                Text(String(format: "%+.1f", settings.wrappedValue.positionDivisions))
                    .font(.caption.monospacedDigit())
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }

    // MARK: - Horizontal

    private var horizontal: some View {
        Section("Horizontal") {
            Picker("Time base", selection: $model.settings.timebaseIndex) {
                ForEach(Array(Timebase.all.enumerated()), id: \.offset) { offset, timebase in
                    Text(timebase.label).tag(offset)
                }
            }

            LabeledContent("Sample interval") {
                Text(Format.time(model.settings.timebase.sampleInterval))
                    .font(.caption.monospacedDigit())
            }

            if model.settings.timebase.mode == .equivalentTime {
                Label(
                    "Equivalent-time sampling: the record is built from many trigger events, so it needs a repetitive signal and always triggers, whatever the trigger mode says.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent("Nyquist limit") {
                Text(Format.frequency(1 / (2 * model.settings.timebase.sampleInterval)))
                    .font(.caption.monospacedDigit())
            }
        }
    }

    // MARK: - Trigger

    private var trigger: some View {
        Section("Trigger") {
            Picker("Mode", selection: $model.settings.trigger.mode) {
                ForEach(TriggerMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Source", selection: $model.settings.trigger.source) {
                ForEach(TriggerSource.allCases, id: \.self) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.settings.trigger.mode == .auto && !model.settings.requiresTrigger)

            Picker("Slope", selection: $model.settings.trigger.risingEdge) {
                Text("Rising").tag(true)
                Text("Falling").tag(false)
            }
            .pickerStyle(.segmented)
            .disabled(model.settings.trigger.mode == .auto && !model.settings.requiresTrigger)

            HStack {
                Text("Level").font(.caption).foregroundStyle(.secondary)
                Slider(value: $model.settings.trigger.level, in: -1...1)
                Text(Format.voltage(model.settings.trigger.levelVolts(
                    channel: model.settings.channel1,
                    supply: model.supplyVoltage
                )))
                .font(.caption.monospacedDigit())
                .frame(width: 58, alignment: .trailing)
            }
            .disabled(model.settings.trigger.mode == .auto && !model.settings.requiresTrigger)

            if model.settings.trigger.mode == .normal || model.settings.requiresTrigger {
                Text("The comparator watches Ch1 (or the external trigger pin); Ch2 cannot trigger.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A labelled group box, so every panel section looks the same.
private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
    }
}
