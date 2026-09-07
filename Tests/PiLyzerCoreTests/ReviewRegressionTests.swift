import Foundation
import Testing
@testable import PiLyzerCore

@Suite("Acquisition regressions")
struct ReviewRegressionTests {
    @Test("Settings interrupt a normal-trigger wait without Stop/Run", arguments: [false, true])
    func changeWhileWaiting(single: Bool) throws {
        let engine = InstrumentEngine()
        engine.callbackQueue = DispatchQueue(label: "regression.callbacks")
        let ready = DispatchSemaphore(value: 0)
        let planned = DispatchSemaphore(value: 0)
        let captured = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        engine.onStateChange = { if $0.isConnected { ready.signal() } }
        engine.onPlan = { _ in planned.signal() }
        engine.onScopeFrame = { _ in captured.signal() }
        engine.onRunningChange = { if !$0 { finished.signal() } }
        var settings = ScopeSettings()
        settings.trigger.mode = .normal
        settings.trigger.levelVolts = 20 // The demo peaks at about 2 V.
        engine.connect(to: .simulator, settings: settings)
        defer { engine.disconnect() }
        try #require(ready.wait(timeout: .now() + 2) == .success)
        try #require(finished.wait(timeout: .now() + 2) == .success) // initial stopped state
        if single { engine.single() } else { engine.start() }
        try #require(planned.wait(timeout: .now() + 2) == .success)
        #expect(captured.wait(timeout: .now() + 0.05) == .timedOut)
        settings.trigger.mode = .auto
        engine.update(settings: settings)
        try #require(captured.wait(timeout: .now() + 2) == .success)
        if single {
            #expect(finished.wait(timeout: .now() + 2) == .success)
            #expect(captured.wait(timeout: .now() + 0.1) == .timedOut)
        } else {
            #expect(captured.wait(timeout: .now() + 2) == .success)
        }
    }

    @Test("Changing mode releases a waiting acquisition")
    func modeWhileWaiting() throws {
        let engine = InstrumentEngine()
        engine.callbackQueue = DispatchQueue(label: "regression.mode")
        let ready = DispatchSemaphore(value: 0)
        let planned = DispatchSemaphore(value: 0)
        let reading = DispatchSemaphore(value: 0)
        engine.onStateChange = { if $0.isConnected { ready.signal() } }
        engine.onPlan = { _ in planned.signal() }
        engine.onMeterReading = { _ in reading.signal() }
        var settings = ScopeSettings()
        settings.trigger.mode = .normal
        settings.trigger.levelVolts = 20
        engine.connect(to: .simulator, settings: settings)
        defer { engine.disconnect() }
        try #require(ready.wait(timeout: .now() + 2) == .success)
        engine.start()
        try #require(planned.wait(timeout: .now() + 2) == .success)
        settings.mode = .meter
        engine.update(settings: settings)
        #expect(reading.wait(timeout: .now() + 2) == .success)
    }

    @Test("Updating a stopped instrument does not start acquisition")
    func stoppedUpdate() throws {
        let engine = InstrumentEngine()
        engine.callbackQueue = DispatchQueue(label: "regression.stopped")
        let ready = DispatchSemaphore(value: 0)
        let reading = DispatchSemaphore(value: 0)
        engine.onStateChange = { if $0.isConnected { ready.signal() } }
        engine.onMeterReading = { _ in reading.signal() }
        engine.connect(to: .simulator, settings: ScopeSettings())
        defer { engine.disconnect() }
        try #require(ready.wait(timeout: .now() + 2) == .success)
        engine.update(settings: ScopeSettings(mode: .meter))
        #expect(reading.wait(timeout: .now() + 0.1) == .timedOut)
        engine.start()
        #expect(reading.wait(timeout: .now() + 2) == .success)
    }

    @Test("Fallback trigger uses the enabled input's range, gain and probe")
    func fallbackVoltage() {
        let capabilities = SimulatedInstrument().capabilities
        var settings = ScopeSettings()
        settings.channels[0].isEnabled = false
        settings.channels[1].rangeIndex = 1
        settings.channels[1].probeAttenuation = 10
        settings.channels[1].setCalibration(ChannelCalibration(zero: 0.025, scale: 1.04), forRange: 1)
        settings.trigger.levelVolts = 1
        let scales = settings.channels.map {
            $0.scale(reference: capabilities.referenceVolts,
                     fullScale: capabilities.analogFullScale, ranges: FrontEnd.revA)
        }
        let config = settings.analogConfiguration(capabilities: capabilities, scales: scales)
        #expect(config.channelMask == 2)
        #expect(config.triggerSource == 0)
        #expect(abs(scales[1].volts(config.triggerLevel) - 1) < 0.002)
    }

    @Test("Repeated zero calibration replaces the offset in input units")
    func repeatedZero() throws {
        let device = SimulatedInstrument()
        device.noise = 0
        device.tones = [.init(frequency: 0, amplitude: 0, offset: 0.025),
                        .init(frequency: 0, amplitude: 0, offset: -0.015)]
        let engine = InstrumentEngine(makeInstrument: { _ in device })
        engine.callbackQueue = DispatchQueue(label: "regression.zero")
        let ready = DispatchSemaphore(value: 0)
        engine.onStateChange = { if $0.isConnected { ready.signal() } }
        var settings = ScopeSettings(mode: .meter)
        settings.ensureAnalogChannels(device.capabilities.analogChannels)
        settings.channels[0].probeAttenuation = 10
        settings.channels[0].setCalibration(ChannelCalibration(zero: 0.1, scale: 1.04), forRange: 0)
        settings.channels[0].setCalibration(ChannelCalibration(zero: 0.2, scale: 0.98), forRange: 1)
        engine.connect(to: .simulator, settings: settings)
        defer { engine.disconnect() }
        try #require(ready.wait(timeout: .now() + 2) == .success)
        for _ in 0..<2 {
            let zero = DispatchSemaphore(value: 0)
            var values: [Double] = []
            engine.calibrateZero { values = $0; zero.signal() }
            try #require(zero.wait(timeout: .now() + 2) == .success)
            #expect(abs(values[0] - 0.025) < 0.01)
            for index in values.indices {
                settings.channels[index].calibrateZero(to: values[index], forRange: 0)
            }
            engine.update(settings: settings)
            let read = DispatchSemaphore(value: 0)
            engine.readNow { values = $0; read.signal() }
            try #require(read.wait(timeout: .now() + 2) == .success)
            #expect(values.allSatisfy { abs($0) < 1e-9 })
        }
        #expect(settings.channels[0].calibration(forRange: 0).scale == 1.04)
        #expect(settings.channels[0].calibration(forRange: 1) == ChannelCalibration(zero: 0.2, scale: 0.98))
    }
}

@Suite("Spectrum history regressions")
struct SpectrumHistoryRegressionTests {
    @Test("Changed timing, record length or window starts a new average", arguments: [0, 1, 2])
    func incompatibleSpectra(change: Int) {
        let samples = (0..<2048).map { sin(2 * Double.pi * 64 * Double($0) / 2048) }
        let old = SpectrumAnalyzer.transform(samples.map { $0 * 10 }, sampleRate: 20_000, window: .hann)
        let fresh = SpectrumAnalyzer.transform(change == 1 ? Array(samples.prefix(1024)) : samples,
                                               sampleRate: change == 0 ? 40_000 : 20_000,
                                               window: change == 2 ? .flatTop : .hann)
        let result = SpectrumAnalyzer.average([old, fresh])
        #expect(result == fresh)
        // Returning to an earlier setting must not resurrect its old history.
        #expect(SpectrumAnalyzer.average([old, fresh, old]) == old)
    }

    @Test("Input changes invalidate history while display changes preserve it")
    func acquisitionContext() {
        let original = ScopeSettings(mode: .spectrum)
        var changed = original
        changed.channels[0].isEnabled = false
        #expect(!changed.hasSameSpectrumInput(as: original))
        changed = original
        changed.channels[0].calibrateZero(to: 0.025, forRange: 0)
        #expect(!changed.hasSameSpectrumInput(as: original))
        changed = original
        changed.spectrum.window = .flatTop
        #expect(!changed.hasSameSpectrumInput(as: original))
        changed = original
        changed.secondsPerDivision *= 2
        #expect(!changed.hasSameSpectrumInput(as: original))
        changed = original
        changed.spectrum.scale = .linear
        changed.spectrum.showsPeakMarkers.toggle()
        #expect(changed.hasSameSpectrumInput(as: original))
    }
}
