import Foundation

/// What the application can see on the USB bus, in words.
///
/// An empty instrument list has several causes that look identical from the
/// front panel — no board, the firmware not flashed yet, a board sitting in its
/// bootloader — and the difference matters, so it is worth saying which.
public enum Diagnostics {
    public struct Report: Equatable, Sendable {
        public var instruments: [USBDeviceInfo]
        public var otherBoards: [UnprogrammedBoard]

        public var hasInstrument: Bool { !instruments.isEmpty }

        /// One line for the status bar, or nothing when an instrument is there.
        public var hint: String? {
            guard instruments.isEmpty else { return nil }
            if let bootloader = otherBoards.first(where: \.isInBootloader) {
                return bootloader.advice
            }
            if let board = otherBoards.first {
                return board.advice
            }
            return nil
        }
    }

    public static func look() -> Report {
        Report(instruments: USBTransport.attachedDevices(),
               otherBoards: USBTransport.unprogrammedBoards())
    }

    /// The `--list` output.
    public static func describe(_ report: Report = look()) -> String {
        var lines: [String] = []
        lines.append(String(format: "Looking for %04X:%04X", Wire.vendorID, Wire.productID))

        if report.instruments.isEmpty {
            lines.append("No instrument found.")
        } else {
            for device in report.instruments {
                lines.append(String(format: "  instrument at 0x%08X  %@  serial %@",
                                    device.locationID, device.product, device.serial))
            }
        }

        if !report.otherBoards.isEmpty {
            lines.append("")
            lines.append("Raspberry Pi boards on the bus:")
            for board in report.otherBoards {
                lines.append(String(format: "  %04X:%04X  %@%@",
                                    Wire.raspberryPiVendorID, board.productID,
                                    board.product.isEmpty ? "(no product string)" : board.product,
                                    board.isInBootloader ? "  — in BOOTSEL" : ""))
            }
        }

        if let hint = report.hint {
            lines.append("")
            lines.append(hint)
        }
        return lines.joined(separator: "\n")
    }

    /// Walks the whole command set against a real instrument and reports what
    /// came back. This is the thing to run first when a board is new, or when
    /// something on the front panel looks wrong and it is not obvious whether
    /// the fault is in the firmware or above it.
    public static func selfTest(locationID: UInt32 = 0) -> String {
        var lines: [String] = []
        func say(_ text: String) { lines.append(text) }

        let instrument: Instrument
        do {
            instrument = try USBInstrument(locationID: locationID)
        } catch {
            return "Could not open the instrument: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
        defer { instrument.close() }

        let identity = instrument.identity
        let capabilities = instrument.capabilities
        say("identity      \(identity.name), firmware \(identity.firmwareDescription), board \(identity.boardID)")
        say("protocol      version \(identity.protocolVersion)")
        say("analogue      \(capabilities.analogChannels) ch, \(capabilities.analogBits) bit, "
            + "up to \(Format.sampleRate(1 / capabilities.minimumConversionPeriod)), "
            + "\(capabilities.analogMaxRecord) pt")
        say("logic         \(capabilities.logicChannels) ch, "
            + "up to \(Format.sampleRate(Double(capabilities.logicClockHz))), "
            + "\(capabilities.logicMaxRecord) pt")
        say("reference     \(Format.voltage(capabilities.referenceVolts)), "
            + "full scale \(Int(capabilities.analogFullScale))")
        // Says where the numbers came from, so a firmware that has stopped
        // answering is visible rather than silently falling back.
        let reported = capabilities.reportsInputRanges ? try? instrument.inputRanges() : nil
        let ranges = reported ?? FrontEnd.ranges(forBoard: identity.boardID)
        say("ranges        \(ranges.map(\.name).joined(separator: ", ")) "
            + "(\(reported != nil ? "from the device" : "from the board-id table"))")
        for range in ranges {
            say(String(format: "              %@  gain %.6f  offset %.6f V",
                       range.name, range.gain, range.offset))
        }

        do {
            let immediate = try instrument.sampleAnalog(averages: 64)
            let scale = VoltageScale(reference: capabilities.referenceVolts,
                                     fullScale: capabilities.analogFullScale,
                                     range: ranges[0])
            say("")
            say("immediate     " + immediate.enumerated().map { index, code in
                "CH\(index + 1) \(code) (\(Format.voltage(scale.volts(code))))"
            }.joined(separator: "   "))
        } catch {
            say("immediate     FAILED: \(error)")
        }

        say("")
        say(analogueCheck(instrument, capabilities: capabilities))
        say("")
        say(mappingCheck(instrument, capabilities: capabilities))
        say("")
        say(triggerCheck(instrument, capabilities: capabilities))
        say("")
        say(logicCheck(instrument, capabilities: capabilities))
        return lines.joined(separator: "\n")
    }

    /// Restarts the instrument in its bootloader, so new firmware can be
    /// loaded without reaching for the BOOTSEL button.
    public static func rebootToBootloader(locationID: UInt32 = 0) -> String {
        do {
            let instrument = try USBInstrument(locationID: locationID)
            defer { instrument.close() }
            try instrument.rebootToBootloader()
            return "The instrument is restarting in its bootloader."
        } catch {
            return "Could not reach the instrument: "
                + ((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// Drives the calibration output, for wiring up a channel against a known
    /// signal. `frequency` of zero switches it off.
    public static func setTestOutput(_ frequency: Int, locationID: UInt32 = 0) -> String {
        do {
            let instrument = try USBInstrument(locationID: locationID)
            defer { instrument.close() }
            guard instrument.capabilities.hasCalibrationOutput else {
                return "This instrument has no calibration output."
            }
            let actual = try instrument.setCalibrationOutput(enabled: frequency > 0,
                                                             frequency: max(frequency, 0))
            return frequency > 0
                ? "Test output on at \(Format.frequency(Double(actual)))."
                : "Test output off."
        } catch {
            return "Could not reach the instrument: "
                + ((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// Measures the instrument's own calibration output back through the
    /// converter, at several frequencies and several sample rates.
    ///
    /// Nothing else checks the time axis. The samples alone cannot say how far
    /// apart they are, so the only way to know the divisor arithmetic is right
    /// is to put a known frequency in and see it come out — and to do it at
    /// more than one rate, because a constant factor hides in a single
    /// measurement.
    ///
    /// Wire the calibration output to an analogue input first; the channel is
    /// found by looking for the one that swings.
    public static func timingCheck(frequencies: [Int] = [100, 1_000, 10_000],
                                   locationID: UInt32 = 0) -> String {
        do {
            let instrument = try USBInstrument(locationID: locationID)
            defer { instrument.close() }
            let capabilities = instrument.capabilities
            guard capabilities.hasCalibrationOutput else {
                return "This instrument has no calibration output to measure."
            }

            let mask = UInt8((1 << capabilities.analogChannels) - 1)
            let floor = capabilities.minimumSamplePeriod(channels: capabilities.analogChannels)

            // The interval the instrument grants is the one to measure with.
            // Measuring against what was asked for would only ever confirm the
            // request.
            func capture(period: Double, samples: Int,
                         mask: UInt8 = mask) throws -> (columns: [[Double]], period: Double) {
                let plan = try instrument.configureAnalog(AnalogConfiguration(
                    channelMask: mask, triggerMode: .freeRun, samplePeriod: period,
                    recordSamples: samples, pretriggerSamples: 0, autoTimeout: 0.1))
                try instrument.armAnalog()
                guard let status = try waitForRecord({ try instrument.analogStatus() },
                                                     timeout: plan.duration + 2),
                      status.state == .complete else { return ([], plan.samplePeriod) }
                return (try instrument.readAnalogRecord(plan: plan).map { $0.map(Double.init) },
                        plan.samplePeriod)
            }

            _ = try instrument.setCalibrationOutput(enabled: true, frequency: 1000)
            Thread.sleep(forTimeInterval: 0.02)

            // Whichever input the wire is on is the one that swings.
            let probe = try capture(period: floor, samples: 2048).columns
            guard !probe.isEmpty else { return "timing        FAILED: no record" }
            let swing = probe.map { ($0.max() ?? 0) - ($0.min() ?? 0) }
            guard let channel = swing.enumerated().max(by: { $0.element < $1.element })?.offset,
                  swing[channel] > capabilities.analogFullScale * 0.25 else {
                return "timing        no channel is swinging — connect the calibration output "
                    + "to an analogue input to check the time axis"
            }

            var lines = ["timing        measuring on CH\(channel + 1)"]
            var worst = 0.0

            for commanded in frequencies {
                let actual = Double(try instrument.setCalibrationOutput(enabled: true,
                                                                       frequency: commanded))
                Thread.sleep(forTimeInterval: 0.02)

                // The same signal at several sample rates. If what comes back
                // depends on how fast it was sampled, the fault is in the
                // sampling; if every rate agrees, the output really is at that
                // frequency and the time axis is sound.
                for samplesPerCycle in [10.0, 40.0, 160.0] {
                    let requested = max(1 / (actual * samplesPerCycle), floor)
                    let (columns, period) = try capture(period: requested, samples: 2048)
                    guard columns.indices.contains(channel) else { continue }
                    let measured = Measurements.of(columns[channel], samplePeriod: period)
                    guard let frequency = measured.frequency else {
                        lines.append(String(format: "              %@ at %@ a sample — no edges",
                                            Format.frequency(actual), Format.time(period)))
                        continue
                    }
                    let error = (frequency - actual) / actual * 100
                    worst = max(worst, abs(error))
                    lines.append(String(format: "              %@ out, %@ back at %@ a sample (%.0f/cycle) — %+.2f%%",
                                        Format.frequency(actual), Format.frequency(frequency),
                                        Format.time(period), 1 / (actual * period), error))
                }
            }

            // The same signal at each channel count, always at that count's
            // fastest. If the error tracks the number of channels, the
            // interleaving is at fault; if it is the same factor throughout,
            // the conversion period is.
            _ = try instrument.setCalibrationOutput(enabled: true, frequency: 1000)
            Thread.sleep(forTimeInterval: 0.02)
            for count in 1...capabilities.analogChannels {
                var trial: UInt8 = 1 << UInt8(channel)
                for other in 0..<capabilities.analogChannels where trial.nonzeroBitCount < count {
                    if other != channel { trial |= 1 << UInt8(other) }
                }
                let each = capabilities.minimumSamplePeriod(channels: trial.nonzeroBitCount)
                let (columns, period) = try capture(period: each, samples: 2048, mask: trial)
                let slot = (0..<capabilities.analogChannels)
                    .filter { trial & (1 << $0) != 0 }.firstIndex(of: channel) ?? 0
                guard columns.indices.contains(slot),
                      let frequency = Measurements.of(columns[slot], samplePeriod: period).frequency
                else { continue }
                lines.append(String(format: "              1 kHz with %d ch at %@ a sample — %@ back (%+.1f%%)",
                                    trial.nonzeroBitCount, Format.time(period),
                                    Format.frequency(frequency), (frequency - 1000) / 10))
            }

            lines.append(worst < 1
                ? String(format: "              worst error %.2f%% — the time axis is right", worst)
                : String(format: "              worst error %.2f%%", worst))
            return lines.joined(separator: "\n")
        } catch {
            return "timing        FAILED: "
                + ((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private static func waitForRecord(_ poll: () throws -> AcquisitionStatus,
                                      timeout: Double) throws -> AcquisitionStatus? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = try poll()
            if status.isFinished { return status }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return nil
    }

    private static func analogueCheck(_ instrument: Instrument,
                                      capabilities: DeviceCapabilities) -> String {
        do {
            // Every channel the instrument has, not a number fixed here:
            // a diagnostic that tests two of three channels is worse than none.
            let mask = UInt8((1 << capabilities.analogChannels) - 1)
            let period = capabilities.minimumSamplePeriod(channels: capabilities.analogChannels)
            let configuration = AnalogConfiguration(
                channelMask: mask, triggerMode: .freeRun, samplePeriod: period,
                recordSamples: 2048, pretriggerSamples: 256, autoTimeout: 0.1)
            let plan = try instrument.configureAnalog(configuration)
            let started = Date()
            try instrument.armAnalog()
            guard let status = try waitForRecord({ try instrument.analogStatus() },
                                                 timeout: plan.duration + 2) else {
                return "analogue      FAILED: the record never completed"
            }
            guard status.state == .complete else {
                return "analogue      FAILED: finished in state \(status.state)"
            }
            let columns = try instrument.readAnalogRecord(plan: plan)
            let elapsed = Date().timeIntervalSince(started)

            var report = ["analogue      \(Format.sampleRate(plan.sampleRate)) a channel, "
                          + "\(plan.recordSamples) pt, decimation \(plan.decimation), "
                          + String(format: "%.0f ms round trip", elapsed * 1000)]
            for (index, column) in columns.enumerated() {
                guard let low = column.min(), let high = column.max() else { continue }
                let mean = column.reduce(0.0) { $0 + Double($1) } / Double(column.count)
                report.append(String(format: "              CH%d  %d samples  min %d  max %d  mean %.0f",
                                     index + 1, column.count, low, high, mean))
            }
            // The record's own timing is the thing worth checking against the
            // plan: a wrong sample interval is invisible in the samples alone.
            report.append(String(format: "              record spans %@ by the plan",
                                 Format.time(plan.duration)))
            return report.joined(separator: "\n")
        } catch {
            return "analogue      FAILED: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }

    /// Checks that a channel's samples land in the slot the plan promised,
    /// including when only some channels are on.
    ///
    /// The converter walks the enabled inputs in turn, so switching one off
    /// moves every channel after it to a different slot. Getting that wrong
    /// swaps two traces and nothing else looks wrong.
    ///
    /// This can only be measured on inputs that are actually driven. An
    /// unconnected pin wanders by thousands of codes, and it does not even
    /// settle to the same level under continuous sampling as under the
    /// occasional single reads used for comparison — so the check first works
    /// out which channels are steady and far enough apart to tell from each
    /// other, and judges only those. Saying "cannot tell" is the useful answer
    /// when nothing is connected; a verdict there would be a coin flip.
    private static func mappingCheck(_ instrument: Instrument,
                                     capabilities: DeviceCapabilities) -> String {
        let count = capabilities.analogChannels
        guard count > 1 else { return "mapping       one channel; nothing to confuse" }

        /// Two readings a moment apart: a driven input repeats, a floating one
        /// does not.
        let steadyLimit = capabilities.analogFullScale * 0.01
        /// Two channels closer than this cannot be told apart in a record.
        let separationLimit = capabilities.analogFullScale * 0.05

        do {
            let first = try instrument.sampleAnalog(averages: 64).map(Double.init)
            Thread.sleep(forTimeInterval: 0.15)
            let second = try instrument.sampleAnalog(averages: 64).map(Double.init)
            let level = zip(first, second).map { ($0 + $1) / 2 }

            let steady = (0..<count).map { abs(first[$0] - second[$0]) < steadyLimit }
            let distinct = (0..<count).map { channel in
                (0..<count).allSatisfy { $0 == channel || abs(level[channel] - level[$0]) > separationLimit }
            }
            let usable = (0..<count).filter { steady[$0] && distinct[$0] }

            var lines = ["mapping       " + (0..<count).map { channel in
                "CH\(channel + 1) \(Int(level[channel]))"
                    + (steady[channel] ? (distinct[channel] ? "" : "≈") : "~")
            }.joined(separator: "  ") + "   (~ drifting, ≈ same as another)"]

            guard !usable.isEmpty else {
                lines.append("              no channel is both steady and distinct — connect different, "
                             + "settled voltages to check the channel mapping")
                return lines.joined(separator: "\n")
            }

            var wrong = 0
            var judged = 0
            for mask in 1...UInt8((1 << count) - 1) where mask.nonzeroBitCount > 1 {
                let plan = try instrument.configureAnalog(AnalogConfiguration(
                    channelMask: mask, triggerMode: .freeRun,
                    samplePeriod: capabilities.minimumSamplePeriod(channels: mask.nonzeroBitCount),
                    recordSamples: 512, pretriggerSamples: 64, autoTimeout: 0.1))
                try instrument.armAnalog()
                guard let status = try waitForRecord({ try instrument.analogStatus() },
                                                     timeout: plan.duration + 2),
                      status.state == .complete else {
                    return "mapping       FAILED: no record for mask \(String(mask, radix: 2))"
                }
                let slots = try instrument.readAnalogRecord(plan: plan).map { column in
                    column.reduce(0.0) { $0 + Double($1) } / Double(max(column.count, 1))
                }
                let expected = (0..<count).filter { mask & (1 << $0) != 0 }
                guard slots.count == expected.count else {
                    return "mapping       FAILED: mask \(String(mask, radix: 2)) gave \(slots.count) columns, expected \(expected.count)"
                }

                for (slot, channel) in expected.enumerated() where usable.contains(channel) {
                    judged += 1
                    let nearest = (0..<count).min { abs(slots[slot] - level[$0]) < abs(slots[slot] - level[$1]) }
                    if nearest != channel {
                        wrong += 1
                        lines.append(String(format: "              mask %@ slot %d should be CH%d but reads %.0f, which is CH%d",
                                            String(mask, radix: 2), slot, channel + 1,
                                            slots[slot], (nearest ?? 0) + 1))
                    }
                }
            }

            let checkable = usable.map { "CH\($0 + 1)" }.joined(separator: ", ")
            lines.append(wrong == 0
                ? "              \(judged) slots checked against \(checkable): every one holds its channel"
                : "              \(wrong) of \(judged) slots hold the wrong channel — check the round robin")
            if usable.count < count {
                lines.append("              the rest could not be checked; drive them apart to include them")
            }
            return lines.joined(separator: "\n")
        } catch {
            return "mapping       FAILED: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }

    /// Arms a real trigger and checks that the edge landed where the
    /// instrument said it did. This is the most intricate path in the firmware
    /// and the one nothing else exercises.
    private static func triggerCheck(_ instrument: Instrument,
                                     capabilities: DeviceCapabilities) -> String {
        let level = UInt16(capabilities.analogFullScale / 2)
        do {
            let configuration = AnalogConfiguration(
                channelMask: 0b01, triggerMode: .normal, triggerSource: 0,
                triggerSlope: .rising, triggerLevel: level, triggerHysteresis: 200,
                samplePeriod: 4e-6, recordSamples: 1024, pretriggerSamples: 256,
                autoTimeout: 0.2)
            let plan = try instrument.configureAnalog(configuration)
            try instrument.armAnalog()
            guard let status = try waitForRecord({ try instrument.analogStatus() },
                                                 timeout: 3) else {
                return "trigger       no edge crossed \(level) within 3 s "
                    + "(expected if the input is quiet — this checks a real crossing)"
            }
            guard status.state == .complete else {
                return "trigger       FAILED: finished in state \(status.state)"
            }
            let columns = try instrument.readAnalogRecord(plan: plan)
            guard let samples = columns.first, samples.count > status.triggerIndex,
                  status.triggerIndex > 0 else {
                return "trigger       FAILED: the record does not contain its own trigger index"
            }

            let index = status.triggerIndex
            let before = samples[index - 1]
            let at = samples[index]
            let crossed = before < level && at >= level
            return """
            trigger       rising through \(level), triggered \(status.triggered)
                          index \(index) of \(samples.count) (asked for \(plan.pretriggerSamples))
                          sample \(index - 1) = \(before), sample \(index) = \(at)
                          the edge is \(crossed ? "where the instrument said it was" : "NOT at the reported index")
            """
        } catch {
            return "trigger       FAILED: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }

    private static func logicCheck(_ instrument: Instrument,
                                   capabilities: DeviceCapabilities) -> String {
        do {
            // A window wide enough to show ordinary signals. At the PIO's top
            // speed a full record covers under half a millisecond, so anything
            // slower than a few kilohertz reads as a flat line and the check
            // says "idle" about a pin that is perfectly busy.
            let configuration = LogicConfiguration(
                triggerMode: .freeRun, samplePeriod: 1e-6,
                recordSamples: 65536, pretriggerSamples: 512, autoTimeout: 0.1)
            let plan = try instrument.configureLogic(configuration)
            try instrument.armLogic()
            guard let status = try waitForRecord({ try instrument.logicStatus() },
                                                 timeout: plan.duration + 2) else {
                return "logic         FAILED: the capture never completed"
            }
            guard status.state == .complete else {
                return "logic         FAILED: finished in state \(status.state)"
            }
            let samples = try instrument.readLogicRecord(plan: plan)
            let frame = LogicFrame(samples: samples, samplePeriod: plan.samplePeriod,
                                   triggerIndex: status.triggerIndex, triggered: status.triggered,
                                   channelCount: capabilities.logicChannels)
            var report = ["logic         \(Format.sampleRate(plan.sampleRate)), \(samples.count) pt"]
            for activity in LogicAnalysis.activity(of: frame) {
                let state = activity.isIdle
                    ? (frame.level(activity.channel, at: 0) ? "idle high" : "idle low")
                    : "\(activity.transitions) edges, \(activity.frequency.map(Format.frequency) ?? "—")"
                report.append("              D\(activity.channel)  \(state)")
            }
            return report.joined(separator: "\n")
        } catch {
            return "logic         FAILED: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }
}
