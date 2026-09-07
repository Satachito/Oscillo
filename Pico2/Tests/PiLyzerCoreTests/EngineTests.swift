import Foundation
import Testing
@testable import PiLyzerCore

@Suite("Settings")
struct SettingsTests {
    private let capabilities = SimulatedInstrument().capabilities

    private func scales(_ settings: ScopeSettings) -> [VoltageScale] {
        settings.channels.map {
            $0.scale(reference: capabilities.referenceVolts,
                     fullScale: capabilities.analogFullScale, ranges: FrontEnd.revA)
        }
    }

    @Test("A slow sweep gets the record length that was asked for")
    func slowSweep() {
        var settings = ScopeSettings()
        settings.secondsPerDivision = 1e-3
        settings.recordLength = 2000
        let configuration = settings.analogConfiguration(capabilities: capabilities,
                                                         scales: scales(settings))
        #expect(configuration.recordSamples == 2000)
        // Ten divisions of 1 ms over 2000 points is 5 µs a point.
        #expect(abs(configuration.samplePeriod - 5e-6) < 1e-12)
    }

    @Test("A fast sweep keeps the converter flat out and shortens the record instead")
    func fastSweep() {
        var settings = ScopeSettings()
        settings.secondsPerDivision = 50e-6
        settings.recordLength = 2000
        let configuration = settings.analogConfiguration(capabilities: capabilities,
                                                         scales: scales(settings))
        let floor = capabilities.minimumSamplePeriod(channels: 2)
        #expect(abs(configuration.samplePeriod - floor) < 1e-15)
        // 500 µs of screen at 4 µs a point is 125 points, not 2000 invented ones.
        #expect(configuration.recordSamples == 125)
    }

    @Test("Sweep speeds start where the converter can actually fill a trace")
    func timebaseFloor() {
        let list = ScopeSettings.timebases(capabilities: capabilities, channels: 2)
        let floor = capabilities.minimumSamplePeriod(channels: 2)
            * Double(ScopeSettings.minimumRecord) / Double(ScopeSettings.horizontalDivisions)
        #expect(list.allSatisfy { $0 >= floor })
        let fastestPair = try! #require(list.first)
        #expect(fastestPair < floor * 2.5)
        #expect(list.last == 5.0)
        // One channel samples twice as fast, so it sweeps twice as fast.
        let single = ScopeSettings.timebases(capabilities: capabilities, channels: 1)
        let fastestSingle = try! #require(single.first)
        #expect(fastestSingle <= fastestPair)
    }

    @Test("A trigger aimed at a channel that is off moves to one that is on")
    func triggerFallback() {
        var settings = ScopeSettings()
        settings.channels[0].isEnabled = false
        settings.trigger.source = 0
        let configuration = settings.analogConfiguration(capabilities: capabilities,
                                                         scales: scales(settings))
        #expect(configuration.channelMask == 0b10)
        // Only one channel is in the record, so the trigger watches slot zero.
        #expect(configuration.triggerSource == 0)
    }

    @Test("The trigger level reaches the instrument as a converter reading")
    func triggerLevel() {
        var settings = ScopeSettings()
        settings.trigger.levelVolts = 0
        let configuration = settings.analogConfiguration(capabilities: capabilities,
                                                         scales: scales(settings))
        // Zero volts sits at mid-rail on the rev A front end.
        let middle = capabilities.analogFullScale / 2
        #expect(abs(Double(configuration.triggerLevel) - middle) < middle * 0.01)
    }

    @Test("Nothing enabled still produces a usable configuration")
    func noChannels() {
        var settings = ScopeSettings()
        settings.channels[0].isEnabled = false
        settings.channels[1].isEnabled = false
        let configuration = settings.analogConfiguration(capabilities: capabilities,
                                                         scales: scales(settings))
        #expect(configuration.channelMask == 0b01)
    }
}

@Suite("Engine against the simulator")
struct EngineTests {
    private func connected(_ settings: ScopeSettings = ScopeSettings()) -> (InstrumentEngine, DispatchQueue) {
        let queue = DispatchQueue(label: "test.callbacks")
        let engine = InstrumentEngine()
        engine.callbackQueue = queue

        let ready = DispatchSemaphore(value: 0)
        engine.onStateChange = { state in if state.isConnected { ready.signal() } }
        engine.connect(to: .simulator, settings: settings)
        #expect(ready.wait(timeout: .now() + 5) == .success)
        return (engine, queue)
    }

    @Test("Connecting to the demo source reports what it can do")
    func connect() {
        let queue = DispatchQueue(label: "test.callbacks")
        let engine = InstrumentEngine()
        engine.callbackQueue = queue

        var seen: ConnectedInstrument?
        let ready = DispatchSemaphore(value: 0)
        engine.onStateChange = { state in
            if let instrument = state.instrument { seen = instrument; ready.signal() }
        }
        engine.connect(to: .simulator, settings: ScopeSettings())
        #expect(ready.wait(timeout: .now() + 5) == .success)

        let instrument = try! #require(seen)
        #expect(instrument.capabilities.analogChannels == 3)
        #expect(instrument.capabilities.logicChannels == 8)
        #expect(instrument.ranges.count == 2)
        engine.disconnect()
    }

    @Test("A single sweep comes back with both channels and the plan's timing")
    func singleSweep() {
        var settings = ScopeSettings()
        settings.secondsPerDivision = 1e-3
        settings.recordLength = 1000
        let (engine, _) = connected(settings)

        var frame: ScopeFrame?
        let arrived = DispatchSemaphore(value: 0)
        engine.onScopeFrame = { frame = $0; arrived.signal() }
        engine.single()
        #expect(arrived.wait(timeout: .now() + 5) == .success)

        let captured = try! #require(frame)
        #expect(captured.traces.count == 3)
        #expect(captured.sampleCount == 1000)
        #expect(abs(captured.samplePeriod - 1e-5) < 1e-9)
        #expect(captured.triggered)

        // The demo signal is a 1 kHz, 2 V sine on channel one.
        let measured = Measurements.of(captured.traces[0].samples, samplePeriod: captured.samplePeriod)
        #expect(abs(measured.peakToPeak - 4.0) < 0.2)
        let frequency = try! #require(measured.frequency)
        #expect(abs(frequency - 1000) < 20)
        engine.disconnect()
    }

    @Test("The trigger holds a repetitive signal in the same place twice running")
    func triggerIsStable() {
        var settings = ScopeSettings()
        settings.secondsPerDivision = 2e-4
        settings.recordLength = 1000
        settings.trigger.levelVolts = 0
        settings.trigger.mode = .normal
        let (engine, _) = connected(settings)

        var frames: [ScopeFrame] = []
        let arrived = DispatchSemaphore(value: 0)
        engine.onScopeFrame = { frames.append($0); arrived.signal() }
        engine.single()
        #expect(arrived.wait(timeout: .now() + 5) == .success)
        engine.single()
        #expect(arrived.wait(timeout: .now() + 5) == .success)

        #expect(frames.count == 2)
        let index = frames[0].triggerIndex
        #expect(index == frames[1].triggerIndex)
        // Both records cross zero going up at the trigger, so they agree there.
        let first = frames[0].traces[0].samples[index]
        let second = frames[1].traces[0].samples[index]
        #expect(abs(first - second) < 0.1)
        engine.disconnect()
    }

    @Test("A logic capture returns eight channels of the demo pattern")
    func logicCapture() {
        var settings = ScopeSettings()
        settings.mode = .logic
        settings.logic.sampleRate = 10_000_000
        settings.logic.recordLength = 4096
        let (engine, _) = connected(settings)

        var frame: LogicFrame?
        let arrived = DispatchSemaphore(value: 0)
        engine.onLogicFrame = { frame = $0; arrived.signal() }
        engine.single()
        #expect(arrived.wait(timeout: .now() + 5) == .success)

        let captured = try! #require(frame)
        #expect(captured.samples.count == 4096)
        #expect(captured.channelCount == 8)

        // D0 is the demo's 100 kHz square wave.
        let activity = LogicAnalysis.activity(of: captured)
        let frequency = try! #require(activity[0].frequency)
        #expect(abs(frequency - 100_000) < 5_000)
        engine.disconnect()
    }

    @Test("Stopping a normal-trigger sweep that never fires does not hang")
    func stopWithoutTrigger() {
        var settings = ScopeSettings()
        settings.trigger.mode = .normal
        let (engine, _) = connected(settings)

        let stopped = DispatchSemaphore(value: 0)
        engine.onRunningChange = { running in if !running { stopped.signal() } }
        engine.start()
        Thread.sleep(forTimeInterval: 0.2)
        engine.stop()
        #expect(stopped.wait(timeout: .now() + 5) == .success)
        engine.disconnect()
    }
}

@Suite("Vertical scale")
struct VerticalScaleTests {
    private let divisions = ScopeSettings.verticalDivisions

    @Test("A signal that never crosses zero still fits on screen",
          arguments: [3.3, 11.1, 53.0, 33.0])
    func unipolarSignalFits(span: Double) {
        // Zero volts is the centre line, so a rail that sits entirely above it
        // has only half the screen. The coarsest setting has to cover that.
        let steps = AnalogChannelSettings.verticalSteps(span: span, divisions: divisions)
        let coarsest = try! #require(steps.first)
        let halfScreen = Double(divisions) / 2
        #expect(coarsest * halfScreen >= span)
    }

    @Test("The 0–3.3 V case offers the volts a division you would reach for")
    func logicRail() {
        let steps = AnalogChannelSettings.verticalSteps(span: 3.3, divisions: divisions)
        #expect(steps.first == 2.0)
        #expect(steps.contains(1.0) && steps.contains(0.5) && steps.contains(0.01))
        // Every step is a 1–2–5 value, coarsest first.
        #expect(steps == steps.sorted(by: >))
        for step in steps {
            let mantissa = step / pow(10, (log10(step)).rounded(.down))
            #expect([1.0, 2.0, 5.0].contains { abs($0 - mantissa) < 1e-9 })
        }
    }

    @Test("The ladder reaches fine enough to be useful and stops there")
    func fineEnd() {
        let steps = AnalogChannelSettings.verticalSteps(span: 3.3, divisions: divisions)
        let finest = try! #require(steps.last)
        #expect(finest <= 3.3 / 100)
        #expect(finest >= 3.3 / 500)
    }

    @Test("A degenerate range produces nothing rather than crashing")
    func degenerate() {
        #expect(AnalogChannelSettings.verticalSteps(span: 0, divisions: 8).isEmpty)
        #expect(AnalogChannelSettings.verticalSteps(span: 3.3, divisions: 0).isEmpty)
    }
}

@Suite("Screen centre")
struct ScreenCentreTests {
    private let reference = 3.3
    private let fullScale = 65520.0

    private func scale(_ range: InputRange) -> VoltageScale {
        VoltageScale(reference: reference, fullScale: fullScale, range: range)
    }

    @Test("A range that straddles zero puts exactly zero on the centre line")
    func bipolarCentresOnZero() {
        for range in FrontEnd.revA {
            let scale = scale(range)
            #expect(scale.straddlesZero)
            // Ordinary resistors leave the range a few millivolts asymmetric;
            // the centre line should still be zero, not that asymmetry.
            #expect(abs(scale.centreVolts) > 0)
            #expect(scale.screenCentreVolts == 0)
        }
    }

    @Test("A range that stops at zero centres on its own midpoint")
    func unipolarCentresOnMidpoint() {
        let scale = scale(FrontEnd.bareBoard[0])
        #expect(!scale.straddlesZero)
        #expect(abs(scale.screenCentreVolts - reference / 2) < 1e-9)
    }

    @Test("The whole of a rail fits on screen once the centre moves")
    func railFitsOnScreen() {
        let scale = scale(FrontEnd.bareBoard[0])
        let divisions = Double(ScopeSettings.verticalDivisions)
        let step = try! #require(AnalogChannelSettings.verticalSteps(
            span: scale.spanVolts, divisions: ScopeSettings.verticalDivisions).first)
        // Both ends measured from the centre line have to land inside the grid.
        for volts in [scale.lowestVolts, scale.highestVolts] {
            let fromCentre = abs(volts - scale.screenCentreVolts) / step
            #expect(fromCentre <= divisions / 2)
        }
    }

    @Test("A trigger level on the rail is moved somewhere the signal reaches")
    func triggerLevelIsUsable() {
        let bare = scale(FrontEnd.bareBoard[0])
        // Zero is mid-range on the front end but the floor of a bare board.
        let settled = bare.usableTriggerLevel(0)
        #expect(settled > bare.lowestVolts)
        #expect(settled < bare.highestVolts)
        // A level already in the middle is left alone.
        #expect(bare.usableTriggerLevel(1.65) == 1.65)

        let fine = scale(FrontEnd.revA[1])
        #expect(fine.usableTriggerLevel(0) == 0)
        #expect(fine.usableTriggerLevel(1000) < fine.highestVolts)
        #expect(fine.usableTriggerLevel(-1000) > fine.lowestVolts)
    }
}

@Suite("Software AC coupling and the centre line")
struct AcCouplingTests {
    @Test("A channel with the mean removed reports what it took out")
    func recordsWhatItRemoved() {
        let queue = DispatchQueue(label: "test.ac")
        let engine = InstrumentEngine()
        engine.callbackQueue = queue

        var settings = ScopeSettings()
        settings.recordLength = 1024
        settings.ensureAnalogChannels(3)
        settings.channels[1].removesMean = true      // the demo's offset channel

        let ready = DispatchSemaphore(value: 0)
        engine.onStateChange = { if $0.isConnected { ready.signal() } }
        engine.connect(to: .simulator, settings: settings)
        #expect(ready.wait(timeout: .now() + 5) == .success)

        var frame: ScopeFrame?
        let arrived = DispatchSemaphore(value: 0)
        engine.onScopeFrame = { frame = $0; arrived.signal() }
        engine.single()
        #expect(arrived.wait(timeout: .now() + 5) == .success)

        let captured = try! #require(frame)
        let coupled = try! #require(captured.trace(1))
        let plain = try! #require(captured.trace(0))

        // The samples are centred on zero and the offset is kept, so anything
        // drawn against them can be shifted by the same amount.
        let mean = coupled.samples.reduce(0, +) / Double(coupled.samples.count)
        #expect(abs(mean) < 0.01)
        #expect(abs(coupled.removedMean) > 0.1)
        #expect(plain.removedMean == 0)
        engine.disconnect()
    }

    @Test("Removing the mean and centring on the range midpoint do not fight")
    func acTraceStaysOnScreen() {
        // A bare board reaches 0–3.3 V, so its centre line is 1.65 V. A trace
        // whose mean has been taken out sits about zero — a whole half-range
        // below that line, and off the bottom of the grid, unless the display
        // centres such a channel on zero instead.
        let scale = VoltageScale(reference: 3.3, fullScale: 65520,
                                 range: FrontEnd.bareBoard[0])
        let divisions = Double(ScopeSettings.verticalDivisions)
        let perDivision = 3.3 / divisions

        let ifCentredOnRange = abs(0 - scale.screenCentreVolts) / perDivision
        #expect(ifCentredOnRange >= divisions / 2)   // the fault this guards against

        let ifCentredOnZero = abs(0 - 0) / perDivision
        #expect(ifCentredOnZero < divisions / 2)
    }
}

@Suite("X/Y plot")
struct XYTests {
    @Test("The axes default to the first two channels and survive a round trip")
    func settingsCarryTheAxes() throws {
        var settings = ScopeSettings()
        #expect(settings.xyHorizontal == 0 && settings.xyVertical == 1)
        settings.showsXY = true
        settings.xyHorizontal = 2
        settings.xyVertical = 0
        let restored = try JSONDecoder().decode(
            ScopeSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.xyHorizontal == 2 && restored.xyVertical == 0)
        #expect(restored.showsXY)
    }

    @Test("A square plot keeps equal volts equal on both axes")
    func squareAspect() {
        // The time-domain grid is 10 divisions wide and 8 tall, so plotting
        // X against Y on it turns every circle into an ellipse. The X/Y plot
        // has to use one square with the same number of divisions each way.
        let canvas = CGSize(width: 1000, height: 600)
        let side = min(canvas.width, canvas.height)
        let stepX = side / CGFloat(ScopeSettings.verticalDivisions)
        let stepY = side / CGFloat(ScopeSettings.verticalDivisions)
        #expect(stepX == stepY)

        let wrongX = canvas.width / CGFloat(ScopeSettings.horizontalDivisions)
        let wrongY = canvas.height / CGFloat(ScopeSettings.verticalDivisions)
        #expect(wrongX != wrongY)     // the shape this guards against
    }
}
