import PiLyzerCore
import SwiftUI

/// The front panel beside the screen. Which sections appear follows the mode,
/// so nothing on it is inert.
struct ControlPanelView: View {
    @ObservedObject var model: ScopeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                acquisition
                switch model.settings.mode {
                case .scope:
                    horizontal
                    triggerSection
                    verticalSections
                case .spectrum:
                    frequencySection
                    spectrumSection
                    verticalSections
                case .logic:
                    logicSection
                    decoderSection
                case .meter:
                    loggerSection
                    verticalSections
                }
                if model.capabilities.hasCalibrationOutput { testOutputSection }
                instrumentSection
                Text("PiLyzer for macOS")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.muted)
                    .padding(.vertical, 20)
            }
            .padding(.horizontal, 20)
        }
        .frame(width: 310)
        .background(Theme.panel)
    }

    // MARK: - Sections

    private var acquisition: some View {
        // The mode itself is chosen by the tabs above the screen, as it is in
        // the browser application, so it is not repeated here.
        Section("Acquisition", tag: sourceTag) {
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
                // The spectrum chooses the record from its span.
                if model.settings.mode == .scope {
                    Picker("Record", selection: $model.settings.recordLength) {
                        ForEach(Preferences.recordLengths, id: \.self) { count in
                            Text("\(count) pt").tag(count)
                        }
                    }
                }
                Toggle("X/Y", isOn: $model.settings.showsXY)
                    .disabled(model.settings.mode != .scope)
                if model.settings.showsXY && model.settings.mode == .scope {
                    Picker("X axis", selection: $model.settings.xyHorizontal) {
                        ForEach(model.enabledAnalogChannels, id: \.self) { Text("CH\($0 + 1)").tag($0) }
                    }
                    Picker("Y axis", selection: $model.settings.xyVertical) {
                        ForEach(model.enabledAnalogChannels, id: \.self) { Text("CH\($0 + 1)").tag($0) }
                    }
                }
            }
        }
    }

    private var loggerSection: some View {
        Section("Logger", tag: model.meterSpanDescription) {
            Picker("Every", selection: $model.settings.logIntervalSeconds) {
                ForEach(ScopeSettings.logIntervals, id: \.self) { Text(Format.time($0)).tag($0) }
            }
            Text(model.loggerAdvice)
                .font(.caption).foregroundStyle(.secondary)
            Button("Clear log") { model.clear() }
        }
    }

    private var sourceTag: String {
        guard model.isConnected else { return "OFFLINE" }
        return model.selectedSource == .simulator ? "DEMO" : "USB"
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
            Text("\(model.enabledAnalogChannels.count) ch · max \(Format.sampleRate(model.maximumAnalogRate))/ch")
                .font(.caption).foregroundStyle(.secondary)
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
                ForEach(model.enabledAnalogChannels, id: \.self) { Text("CH\($0 + 1)").tag($0) }
            }
            Picker("Edge", selection: $model.settings.trigger.slope) {
                ForEach(TriggerSlope.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            LabeledSlider(title: "Level", value: $model.settings.trigger.levelVolts,
                          range: levelRange, format: Format.voltage)
            if let note = model.triggerLevelNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            LabeledSlider(title: "Noise", value: $model.settings.trigger.hysteresis,
                          range: 0...0.05, format: { Format.percent($0 * 100, digits: 1) })
            TriggerLowPassControl(cutoffHz: $model.settings.trigger.lowPassHz)
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
        ForEach(model.availableAnalogChannels, id: \.self) { channel in
            VerticalSection(model: model, channel: channel)
        }
    }

    /// The spectrum's horizontal controls, in its own terms. Span and
    /// resolution write the same time per division and record length the
    /// scope's controls do, so both modes are looking at one sweep, and the
    /// scope shows the record a spectrum was made from.
    private var frequencySection: some View {
        let channels = max(model.enabledAnalogChannels.count, 1)
        let capabilities = model.capabilities
        let settings = model.settings
        let reaches = { (span: Double, resolution: Double) in
            ScopeSettings.spectrumRecord(span: span, resolution: resolution,
                                         lengths: Preferences.recordLengths,
                                         capabilities: capabilities, channels: channels) != nil
        }
        // Only what can be reached with the other setting as it is — plus the
        // current choice, so the menu still names it when it no longer can.
        var spans = ScopeSettings.spectrumSpans(capabilities: capabilities, channels: channels)
            .filter { reaches($0, settings.spectrumResolution) }
        if let span = settings.spectrum.spanHz, !spans.contains(span) { spans.append(span); spans.sort() }
        var timebases = model.timebases.filter { time in
            guard let span = settings.spectrum.spanHz else { return true }
            return reaches(span, ScopeSettings.resolution(secondsPerDivision: time))
        }
        if !timebases.contains(settings.secondsPerDivision) { timebases.append(settings.secondsPerDivision) }

        let fastest = 1 / capabilities.minimumSamplePeriod(channels: channels)
        // Until an instrument has answered there is no plan, so say what the
        // settings will ask for.
        let rate = model.plan.recordSamples > 0 && model.plan.sampleRate > 0
            ? model.plan.sampleRate
            : min(Double(settings.recordLength) / (settings.secondsPerDivision
                                                    * Double(ScopeSettings.horizontalDivisions)), fastest)
        let nyquist = rate / 2

        return Section("Frequency") {
            Picker("Span", selection: Binding(
                get: { model.settings.spectrum.spanHz },
                set: { model.settings.setSpectrumSpan($0, lengths: Preferences.recordLengths,
                                                      capabilities: capabilities, channels: channels) })) {
                Text("Full · \(Format.frequency(nyquist))").tag(Double?.none)
                ForEach(spans, id: \.self) { Text(Format.frequency($0)).tag(Double?.some($0)) }
            }
            Picker("Resolution", selection: Binding(
                get: { model.settings.secondsPerDivision },
                set: { model.settings.setSpectrumResolution(secondsPerDivision: $0,
                                                            lengths: Preferences.recordLengths,
                                                            capabilities: capabilities,
                                                            channels: channels) })) {
                ForEach(timebases.sorted(by: >), id: \.self) { time in
                    Text(Format.frequency(ScopeSettings.resolution(secondsPerDivision: time))).tag(time)
                }
            }
            Text("\(model.planDescription) · a sweep every "
                 + Format.time(settings.secondsPerDivision * Double(ScopeSettings.horizontalDivisions)))
                .font(.caption).foregroundStyle(.secondary)
            if let span = settings.spectrum.spanHz, span > nyquist * (1 + 1e-9) {
                Text("Drawn to \(Format.frequency(nyquist)): at this resolution, with "
                     + "\(channels) channel\(channels == 1 ? "" : "s") sharing the converter, "
                     + "the record does not reach \(Format.frequency(span)).")
                    .font(.caption).foregroundStyle(Theme.trigger)
            }
            Text("Nothing filters the input before the converter, so a signal above "
                 + "\(Format.frequency(nyquist)) — half the sample rate — folds back into the "
                 + "span as a false peak.")
                .font(.caption).foregroundStyle(.secondary)
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

            // Checkboxes four to a row, as in the browser application.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4),
                      alignment: .leading, spacing: 8) {
                ForEach(0..<model.capabilities.logicChannels, id: \.self) { channel in
                    Toggle(isOn: Binding(
                        get: { model.settings.logic.enabledChannels.contains(channel) },
                        set: { on in
                            if on { model.settings.logic.enabledChannels.insert(channel) }
                            else { model.settings.logic.enabledChannels.remove(channel) }
                        })) {
                            Text("D\(channel)").font(.system(size: 10, design: .monospaced))
                        }
                        .toggleStyle(.checkbox)
                }
            }
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

    /// A section of its own, as in the browser, and saying which pin: the
    /// square wave is only useful to someone who knows where to clip on.
    private var testOutputSection: some View {
        Section("Test output") {
            Toggle("Calibration square wave", isOn: $model.settings.calibrationOutputEnabled)
            Picker("Frequency", selection: $model.settings.calibrationOutputFrequency) {
                ForEach([100, 1000, 10000, 100_000], id: \.self) {
                    Text(Format.frequency(Double($0))).tag($0)
                }
            }
            .disabled(!model.settings.calibrationOutputEnabled)
            Text(testOutputHint)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var testOutputHint: String {
        if model.selectedSource == .simulator && model.isConnected {
            return "The demo is generated on this Mac. Test output applies to a USB instrument."
        }
        return "GPIO\(DeviceIdentity.calibrationOutputPin) · 0–3.3 V square wave. "
            + "Wire the output to an input to measure it."
    }

    /// Which pin carries what, and the one thing that has to be fitted to
    /// hear any of it.
    private var signalPinsHint: String {
        let base = DeviceIdentity.signalBasePin
        return "GPIO\(base) sine, GPIO\(base + 1) white, GPIO\(base + 2) pink, "
            + "GPIO\(base + 3) brown — PWM at 586 kHz, so each pin wants an RC "
            + "(1 kΩ and 10 nF) to come out as a voltage."
    }

    private var instrumentSection: some View {
        Section("Instrument") {
            if model.capabilities.hasSignalGenerator {
                Toggle("Signal generator", isOn: $model.settings.signalsEnabled)
                if model.settings.signalsEnabled {
                    Picker("Sine", selection: $model.settings.signalSineHz) {
                        ForEach([100, 440, 1000, 5000, 10000], id: \.self) {
                            Text(Format.frequency(Double($0))).tag($0)
                        }
                    }
                }
                Text(signalPinsHint)
                    .font(.caption).foregroundStyle(.secondary)
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

    private var biasVolts: Binding<Double> {
        Binding(get: { model.settings.channels[channel].biasVolts },
                set: { model.settings.channels[channel].setBias($0) })
    }

    /// The input voltage that reads mid scale right now — what a passive front
    /// end biased to the middle of the converter's range leaves on a grounded
    /// input. On a board that reports its own offset it is already nearly zero,
    /// and the button then does nothing worth doing, which is the honest answer.
    private var midRailVolts: Double {
        let scale = model.scale(for: channel)
        let value = scale.uncalibratedVolts(code: model.capabilities.analogFullScale / 2)
        return value.isFinite ? value : 0
    }

    /// Reads through the resolved step rather than the stored zero, so a
    /// channel nobody has set still shows a number in the menu.
    private var voltsPerDivision: Binding<Double> {
        Binding(get: { model.settings.channels[channel].effectiveVoltsPerDivision(
                    reference: model.capabilities.referenceVolts, ranges: model.ranges,
                    divisions: ScopeSettings.verticalDivisions) },
                set: { model.settings.channels[channel].voltsPerDivision = $0 })
    }

    /// Removing the mean is a scope setting: nothing else on screen is drawn
    /// from the samples it shifts.
    private var removesMeanApplies: Bool {
        model.settings.mode == .scope
    }

    private var gainCorrection: Double {
        let channel = model.settings.channels[self.channel]
        return channel.calibration(forRange: channel.rangeIndex).scale
    }

    private var binding: Binding<AnalogChannelSettings> {
        Binding(get: { model.settings.channels[channel] },
                set: { model.settings.channels[channel] = $0 })
    }

    var body: some View {
        Section("Channel \(channel + 1)", titleSize: 15) {
            Toggle("Enabled", isOn: Binding(
                get: { model.settings.channels[channel].isEnabled },
                set: { enabled in
                    model.settings.channels[channel].isEnabled = enabled
                    model.normalizeAnalogSelection()
                }))
                .disabled(model.settings.channels[channel].isEnabled && model.enabledAnalogChannels.count == 1)

            // A channel that is off has nothing to set: its settings are kept,
            // just not shown, so turning it back on brings them all back.
            if model.settings.channels[channel].isEnabled {
                if model.ranges.count > 1 {
                    Picker("Range", selection: binding.rangeIndex) {
                        ForEach(0..<model.ranges.count, id: \.self) { Text(model.ranges[$0].name).tag($0) }
                    }
                }

                Picker("Scale", selection: voltsPerDivision) {
                    ForEach(verticalSteps, id: \.self) { Text(Format.voltage($0) + "/div").tag($0) }
                }

                Picker("Probe", selection: binding.probeAttenuation) {
                    Text("1:1").tag(1.0)
                    Text("1:10").tag(10.0)
                }

                LabeledSlider(title: "Position", value: binding.positionDivisions,
                              range: -4...4, format: { String(format: "%.1f div", $0) })

                // Only the scope draws what this changes. The spectrum takes the
                // mean out itself, because a DC offset through the window is a
                // skirt over the low bins rather than a tall one at zero, and the
                // meter's whole job is the reading the converter actually made.
                Toggle("Remove mean (software AC)", isOn: binding.removesMean)
                    .disabled(!removesMeanApplies)
                    .help(removesMeanApplies
                          ? "Centres the trace on zero, and the CSV with it."
                          : "Scope only. The spectrum removes the mean itself, and "
                            + "the meter logs what the converter read.")

                // Each button sits under the field it writes, and Reset — which
                // clears both of them — stands on its own.
                HStack(spacing: 6) {
                    Text("Bias").font(.caption)
                    Spacer(minLength: 6)
                    VoltsField(volts: biasVolts, discardToken: model.fieldWrites)
                    Text("V").font(.caption).foregroundStyle(.secondary)
                }
                Text("Where the front end holds this input with nothing on it. Drawn as a "
                     + "dotted line; readings stay as the converter saw them.")
                    .font(.caption).foregroundStyle(.secondary)
                if let measured = model.settings.channels[channel].measuredBiasVolts,
                   let error = model.settings.channels[channel].offsetErrorVolts {
                    Text("Measured \(Format.voltage(measured)) — \(Format.voltage(abs(error))) "
                         + (error < 0 ? "below" : "above") + " it, marked on the right.")
                        .font(.caption).foregroundStyle(Theme.channelColor(channel))
                }
                HStack(spacing: 6) {
                    Button("Measure") { model.measureBias() }
                        .help("Ground all inputs first: what they read now is the bias.")
                        .disabled(!model.isConnected)
                    Button("Mid rail") {
                        model.fieldWrites &+= 1
                        biasVolts.wrappedValue = midRailVolts
                    }
                        .help("Writes \(Format.voltage(midRailVolts)), the input that reads mid "
                              + "scale: where a passive front end holds it.")
                }

                HStack(spacing: 6) {
                    Text("Applied").font(.caption)
                    Spacer(minLength: 6)
                    VoltsField(volts: binding.appliedVolts, discardToken: model.fieldWrites)
                    Text("V").font(.caption).foregroundStyle(.secondary)
                }
                Text("A known voltage on the input. Set gain measures the swing from the bias "
                     + "and corrects the gain by what it is short of this — so measure the bias "
                     + "first. The divider's 1% parts put it out by up to 2%.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Button("Set gain") {
                        model.calibrateGain(channel: channel,
                                            appliedVolts: model.settings.channels[channel].appliedVolts)
                    }
                    .help("Reads this input now and takes the difference from the applied voltage.")
                    .disabled(!model.isConnected
                              || abs(model.settings.channels[channel].appliedVolts) < 1e-6)
                    Spacer()
                    Button("Reset") { model.resetCalibration(channel: channel) }
                        .help("Clears this channel's bias and gain correction.")
                }

                // A correction nobody can see is one nobody can question, and a
                // reading past what the converter can reach is always one of these.
                if abs(gainCorrection - 1) > 1e-9 {
                    Text(String(format: "Gain corrected by %+.2f%% — readings are scaled by it.",
                                (gainCorrection - 1) * 100))
                        .font(.caption).foregroundStyle(Theme.channelColor(channel))
                }
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

/// A logarithmic frequency control gives the low end as much travel as the
/// high end. Bypass has its own switch so zero is never mapped through log10.
private struct TriggerLowPassControl: View {
    @Binding var cutoffHz: Int
    @State private var rememberedCutoff = 1000

    private var enabled: Binding<Bool> {
        Binding(get: { cutoffHz > 0 }, set: { on in
            if cutoffHz > 0 { rememberedCutoff = cutoffHz }
            cutoffHz = on ? rememberedCutoff : 0
        })
    }

    private var logarithmicFrequency: Binding<Double> {
        Binding(get: { log10(Double(max(cutoffHz > 0 ? cutoffHz : rememberedCutoff, 100))) },
                set: { position in
                    let frequency = Int(pow(10, position).rounded())
                    rememberedCutoff = frequency
                    cutoffHz = frequency
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Toggle("Trigger LPF", isOn: enabled)
                Spacer()
                Text(cutoffHz > 0 ? "\(cutoffHz.formatted()) Hz" : "Off")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: logarithmicFrequency, in: 2...5)
                .disabled(cutoffHz == 0)
                .accessibilityLabel("Trigger LPF cutoff")
                .accessibilityValue(cutoffHz > 0 ? "\(cutoffHz) hertz" : "Off")
            GeometryReader { geometry in
                // Decades occupy equal thirds of the logarithmic slider's travel.
                // Inset by the small slider thumb's radius to match its endpoints.
                let inset: CGFloat = 8
                let travel = max(geometry.size.width - 2 * inset, 0)
                ZStack(alignment: .topLeading) {
                    HStack {
                        Text("100 Hz")
                        Spacer()
                        Text("100 kHz")
                    }
                    Button("1 kHz") { cutoffHz = 1000 }
                        .buttonStyle(.borderless)
                        .help("Set trigger LPF to 1 kHz")
                        .fixedSize()
                        .position(x: inset + travel / 3, y: geometry.size.height / 2)
                    Text("10 kHz")
                        .fixedSize()
                        .position(x: inset + travel * 2 / 3, y: geometry.size.height / 2)
                }
            }
            .frame(height: 14)
            .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { if cutoffHz > 0 { rememberedCutoff = cutoffHz } }
        .onChange(of: cutoffHz) { if $0 > 0 { rememberedCutoff = $0 } }
    }
}

/// A volts field that takes its number when it is done with: on Return, or
/// when focus leaves it. The reading and the dotted line do not follow every
/// keystroke on the way to 1.65.
///
/// What is typed is kept as a draft rather than parsed as it goes, so the
/// point in "1." survives — `TextField(value:format:)` reparses on every
/// keystroke and redraws "1." as "1", eating the point.
///
/// A button that writes the number while a draft is open — Mid rail, Reset —
/// has to win. Clicking one leaves the field's focus where it was, so the
/// draft would otherwise be committed afterwards, over the button's value;
/// `discardToken` changes with every such write and throws the draft away.
private struct VoltsField: View {
    @Binding var volts: Double
    var discardToken: Int

    @State private var draft: String?
    @FocusState private var isEditing: Bool

    private static let style = FloatingPointFormatStyle<Double>()
        .precision(.fractionLength(0...4))

    var body: some View {
        TextField("", text: Binding(get: { draft ?? Self.style.format(volts) },
                                    set: { draft = $0 }))
            .multilineTextAlignment(.trailing)
            .frame(width: 80)
            .focused($isEditing)
            .onSubmit { commit() }
            .onChange(of: isEditing) { editing in
                if !editing { commit() }
            }
            .onChange(of: discardToken) { _ in draft = nil }
            .onChange(of: volts) { _ in draft = nil }
    }

    /// Text that will not parse is a change of mind, not a zero: the number
    /// that is still in the settings comes back.
    private func commit() {
        guard let text = draft else { return }
        draft = nil
        if let value = try? Self.style.parseStrategy.parse(text) { volts = value }
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

/// A titled group. Ruled off from its neighbours rather than boxed, which is
/// how the browser application's control column is divided.
struct Section<Content: View>: View {
    let title: String
    let tag: String?
    let titleSize: CGFloat
    @ViewBuilder let content: () -> Content

    init(_ title: String, tag: String? = nil, titleSize: CGFloat = 11,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.tag = tag
        self.titleSize = titleSize
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if let tag {
                    Text(tag)
                        .font(.system(size: 8, weight: .regular))
                        .tracking(1)
                        .foregroundStyle(Theme.muted)
                }
            }
            content()
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .pickerStyle(.menu)
        .controlSize(.small)
        .tint(Theme.accent)
    }
}
