import PiLyzerCore
import SwiftUI

/// The front panel beside the screen. Which sections appear follows the mode,
/// so nothing on it is inert.
struct ControlPanelView: View {
    @ObservedObject var model: ScopeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                acquisition
                switch model.settings.mode {
                case .scope:
                    horizontal
                    triggerSection
                    verticalSections
                case .spectrum:
                    horizontal
                    spectrumSection
                    verticalSections
                case .logic:
                    logicSection
                    decoderSection
                case .meter:
                    verticalSections
                }
                instrumentSection
            }
            .padding(12)
        }
        .frame(width: 290)
    }

    // MARK: - Sections

    private var acquisition: some View {
        Section("Acquisition") {
            Picker("", selection: $model.settings.mode) {
                ForEach(WorkMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 6) {
                Button(model.isRunning ? "Stop" : "Run") { model.toggleRun() }
                    .keyboardShortcut("r")
                    .disabled(!model.isConnected)
                Button("Single") { model.single() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.isConnected || model.isRunning)
                Button("Clear") { model.clear() }
            }

            if model.settings.mode == .scope || model.settings.mode == .spectrum {
                Stepper(value: $model.settings.averaging, in: 1...100) {
                    Text("Average \(model.settings.averaging)×")
                }
                Picker("Record", selection: $model.settings.recordLength) {
                    ForEach(Preferences.recordLengths, id: \.self) { count in
                        Text("\(count) pt").tag(count)
                    }
                }
                Toggle("X/Y", isOn: $model.settings.showsXY)
                    .disabled(model.settings.mode != .scope)
            }
        }
    }

    private var horizontal: some View {
        Section("Horizontal") {
            Picker("Time", selection: $model.settings.secondsPerDivision) {
                ForEach(model.timebases, id: \.self) { value in
                    Text(Format.time(value) + "/div").tag(value)
                }
            }
            LabeledSlider(title: "Position", value: $model.settings.trigger.position,
                          range: 0...0.95, format: { Format.percent($0 * 100, digits: 0) })
            Text(model.planDescription)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var triggerSection: some View {
        Section("Trigger") {
            Picker("Mode", selection: $model.settings.trigger.mode) {
                ForEach(TriggerMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Source", selection: $model.settings.trigger.source) {
                ForEach(0..<model.settings.channels.count, id: \.self) { Text("CH\($0 + 1)").tag($0) }
            }
            Picker("Edge", selection: $model.settings.trigger.slope) {
                ForEach(TriggerSlope.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            LabeledSlider(title: "Level", value: $model.settings.trigger.levelVolts,
                          range: levelRange, format: Format.voltage)
            LabeledSlider(title: "Noise", value: $model.settings.trigger.hysteresis,
                          range: 0...0.05, format: { Format.percent($0 * 100, digits: 1) })
            Picker("Trigger LPF", selection: $model.settings.trigger.lowPassHz) {
                ForEach(AnalogTriggerSettings.lowPassOptions, id: \.self) { frequency in
                    Text(frequency == 0 ? "Off" : Format.frequency(Double(frequency)))
                        .tag(frequency)
                }
            }
            .help("Filters the trigger input only. The waveform stays unfiltered; the trigger marker follows the filtered crossing.")
            if model.settings.trigger.lowPassHz > 0 {
                Text(model.capabilities.hasTriggerLowPass
                     ? "LPF affects trigger timing; the trace is unchanged."
                     : "Trigger LPF requires firmware 1.2 or later.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.settings.trigger.mode == .normal {
                Text("Normal waits for the edge and never sweeps without one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var levelRange: ClosedRange<Double> {
        let scale = model.scale(for: model.settings.trigger.source)
        let low = min(scale.lowestVolts, scale.highestVolts)
        let high = max(scale.lowestVolts, scale.highestVolts)
        return low...high
    }

    @ViewBuilder private var verticalSections: some View {
        ForEach(0..<model.settings.channels.count, id: \.self) { channel in
            VerticalSection(model: model, channel: channel)
        }
    }

    private var spectrumSection: some View {
        Section("Spectrum") {
            Picker("Window", selection: $model.settings.spectrum.window) {
                ForEach(SpectrumWindow.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Text(model.settings.spectrum.window.advice)
                .font(.caption).foregroundStyle(.secondary)
            Picker("Scale", selection: $model.settings.spectrum.scale) {
                ForEach(SpectrumScale.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Stepper(value: $model.settings.spectrum.averaging, in: 1...64) {
                Text("Average \(model.settings.spectrum.averaging)×")
            }
            Stepper(value: $model.settings.spectrum.harmonicCount, in: 2...12) {
                Text("\(model.settings.spectrum.harmonicCount) harmonics")
            }
            Toggle("Logarithmic frequency", isOn: $model.settings.spectrum.logarithmicFrequency)
            Toggle("Mark peaks", isOn: $model.settings.spectrum.showsPeakMarkers)
        }
    }

    private var logicSection: some View {
        Section("Logic") {
            Picker("Rate", selection: $model.settings.logic.sampleRate) {
                ForEach(model.logicRates, id: \.self) { rate in
                    Text(Format.sampleRate(rate)).tag(rate)
                }
            }
            Picker("Record", selection: $model.settings.logic.recordLength) {
                ForEach(Preferences.logicRecordLengths, id: \.self) { count in
                    Text("\(count) pt").tag(count)
                }
            }
            Picker("Trigger", selection: $model.settings.logic.triggerMode) {
                ForEach(TriggerMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("On", selection: $model.settings.logic.triggerChannel) {
                ForEach(0..<model.capabilities.logicChannels, id: \.self) { Text("D\($0)").tag($0) }
            }
            Picker("Edge", selection: $model.settings.logic.triggerSlope) {
                ForEach(TriggerSlope.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            LabeledSlider(title: "Position", value: $model.settings.logic.triggerPosition,
                          range: 0...0.95, format: { Format.percent($0 * 100, digits: 0) })

            HStack(spacing: 4) {
                ForEach(0..<model.capabilities.logicChannels, id: \.self) { channel in
                    Toggle(isOn: Binding(
                        get: { model.settings.logic.enabledChannels.contains(channel) },
                        set: { on in
                            if on { model.settings.logic.enabledChannels.insert(channel) }
                            else { model.settings.logic.enabledChannels.remove(channel) }
                        })) {
                            Text("\(channel)")
                        }
                        .toggleStyle(.button)
                        .tint(Theme.logicColor(channel))
                }
            }
            .font(.caption)
        }
    }

    private var decoderSection: some View {
        Section("Decode") {
            Picker("Protocol", selection: $model.decoderKind) {
                ForEach(DecoderKind.allCases) { Text($0.rawValue).tag($0) }
            }

            switch model.decoderKind {
            case .none:
                EmptyView()
            case .uart:
                channelPicker("Line", value: $model.decoderConfiguration.uartLine)
                Picker("Baud", selection: $model.decoderConfiguration.uartBaud) {
                    ForEach([9600.0, 19200, 38400, 57600, 115200, 230400, 460800, 921600], id: \.self) {
                        Text("\(Int($0))").tag($0)
                    }
                }
                Picker("Parity", selection: $model.decoderConfiguration.uartParity) {
                    ForEach(LogicParity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Text(samplesPerBitAdvice).font(.caption).foregroundStyle(.secondary)
            case .spi:
                channelPicker("Clock", value: $model.decoderConfiguration.spiClock)
                channelPicker("Data", value: $model.decoderConfiguration.spiData)
                Toggle("Use chip select", isOn: $model.decoderConfiguration.spiUsesSelect)
                if model.decoderConfiguration.spiUsesSelect {
                    channelPicker("Select", value: $model.decoderConfiguration.spiSelect)
                }
                Toggle("Clock idles high (CPOL)", isOn: $model.decoderConfiguration.spiClockIdleHigh)
                Toggle("Sample on second edge (CPHA)", isOn: $model.decoderConfiguration.spiSampleOnSecondEdge)
            case .i2c:
                channelPicker("SCL", value: $model.decoderConfiguration.i2cClock)
                channelPicker("SDA", value: $model.decoderConfiguration.i2cData)
            }
        }
    }

    private var samplesPerBitAdvice: String {
        let perBit = model.settings.logic.sampleRate / model.decoderConfiguration.uartBaud
        if perBit < 4 {
            return String(format: "%.1f samples a bit — sample faster for a reliable decode.", perBit)
        }
        return String(format: "%.0f samples a bit.", perBit)
    }

    private func channelPicker(_ title: String, value: Binding<Int>) -> some View {
        Picker(title, selection: value) {
            ForEach(0..<model.capabilities.logicChannels, id: \.self) { Text("D\($0)").tag($0) }
        }
    }

    private var instrumentSection: some View {
        Section("Instrument") {
            if model.capabilities.hasCalibrationOutput {
                Toggle("Test output", isOn: $model.settings.calibrationOutputEnabled)
                if model.settings.calibrationOutputEnabled {
                    Picker("Frequency", selection: $model.settings.calibrationOutputFrequency) {
                        ForEach([100, 1000, 10000, 100_000], id: \.self) {
                            Text(Format.frequency(Double($0))).tag($0)
                        }
                    }
                }
            }
            Toggle("Cursors", isOn: $model.cursorsEnabled)
            if model.cursorsEnabled {
                LabeledSlider(title: "A", value: $model.cursorA, range: 0...1,
                              format: { Format.percent($0 * 100, digits: 0) })
                LabeledSlider(title: "B", value: $model.cursorB, range: 0...1,
                              format: { Format.percent($0 * 100, digits: 0) })
            }
        }
    }
}

/// One channel's vertical controls.
struct VerticalSection: View {
    @ObservedObject var model: ScopeModel
    let channel: Int

    private var binding: Binding<AnalogChannelSettings> {
        Binding(get: { model.settings.channels[channel] },
                set: { model.settings.channels[channel] = $0 })
    }

    var body: some View {
        Section("Channel \(channel + 1)") {
            Toggle("Enabled", isOn: binding.isEnabled)

            if model.ranges.count > 1 {
                Picker("Range", selection: binding.rangeIndex) {
                    ForEach(0..<model.ranges.count, id: \.self) { Text(model.ranges[$0].name).tag($0) }
                }
            }

            Picker("Scale", selection: binding.voltsPerDivision) {
                Text("Full range").tag(0.0)
                ForEach(verticalSteps, id: \.self) { Text(Format.voltage($0) + "/div").tag($0) }
            }

            Picker("Probe", selection: binding.probeAttenuation) {
                Text("1:1").tag(1.0)
                Text("1:10").tag(10.0)
            }

            LabeledSlider(title: "Position", value: binding.positionDivisions,
                          range: -4...4, format: { String(format: "%.1f div", $0) })

            Toggle("Remove mean (software AC)", isOn: binding.removesMean)

            HStack(spacing: 6) {
                Button("Zero here") { model.calibrateZero() }
                    .help("Ground both inputs first: what they read now becomes zero.")
                Button("Reset") { model.resetCalibration() }
            }
            .disabled(!model.isConnected)

            if !model.settings.channels[channel].calibration(forRange:
                model.settings.channels[channel].rangeIndex).isDefault {
                Text("Calibrated").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var verticalSteps: [Double] {
        let settings = model.settings.channels[channel]
        let span = settings.range(from: model.ranges)
            .span(reference: model.capabilities.referenceVolts) * settings.probeAttenuation
        return AnalogChannelSettings.verticalSteps(span: span,
                                                   divisions: ScopeSettings.verticalDivisions)
    }
}

/// A slider with its value spelled out beside the title.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(format(value)).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

/// A titled group, so the panel reads as a set of blocks rather than a list.
struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .pickerStyle(.menu)
        .controlSize(.small)
    }
}
