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
        say("ranges        \(FrontEnd.ranges(forBoard: identity.boardID).map(\.name).joined(separator: ", "))")

        do {
            let immediate = try instrument.sampleAnalog(averages: 64)
            let scale = VoltageScale(reference: capabilities.referenceVolts,
                                     fullScale: capabilities.analogFullScale,
                                     range: FrontEnd.ranges(forBoard: identity.boardID)[0])
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
            let configuration = AnalogConfiguration(
                channelMask: 0b11, triggerMode: .freeRun, samplePeriod: 4e-6,
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
            let configuration = LogicConfiguration(
                triggerMode: .freeRun, samplePeriod: 1e-7,
                recordSamples: 4096, pretriggerSamples: 512, autoTimeout: 0.1)
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
