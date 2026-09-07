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
        #expect(instrument.capabilities.analogChannels == 2)
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
        #expect(captured.traces.count == 2)
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
