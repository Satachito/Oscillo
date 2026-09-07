import Foundation
import Testing
@testable import PiLyzerCore

@Suite("Three-channel acquisition")
struct ThreeChannelTests {
    @Test("Enabled masks set rate and physical trigger slot", arguments: Array(UInt8(1)...UInt8(7)))
    func masks(_ mask: UInt8) throws {
        let device = SimulatedInstrument()
        device.noise = 0
        device.tones = [0.5, 1.0, 1.5].map { .init(frequency: 0, amplitude: 0, offset: $0) }
        var settings = ScopeSettings(secondsPerDivision: 50e-6)
        settings.ensureAnalogChannels(3)
        for i in 0..<3 { settings.channels[i].isEnabled = mask & (1 << i) != 0 }
        settings.trigger.source = 2
        settings.trigger.mode = .freeRun
        let active = (0..<3).filter { mask & (1 << $0) != 0 }
        let scales = settings.channels.map {
            $0.scale(reference: 3.3, fullScale: device.capabilities.analogFullScale, ranges: FrontEnd.revA)
        }
        let config = settings.analogConfiguration(capabilities: device.capabilities, scales: scales)
        #expect(config.channelMask == mask)
        #expect(config.channels == active.count)
        #expect(config.triggerSource == (active.firstIndex(of: 2) ?? 0))
        #expect(abs(config.samplePeriod - Double(active.count) * 2e-6) < 1e-12)
        let plan = try device.configureAnalog(config)
        #expect(abs(plan.sampleRate - 500_000 / Double(active.count)) < 1e-6)
        try device.armAnalog()
        let columns = try device.readAnalogRecord(plan: plan)
        #expect(columns.count == active.count)
        for (slot, channel) in active.enumerated() {
            let value = try #require(columns[slot].first)
            #expect(abs(scales[channel].volts(value) - Double(channel + 1) * 0.5) < 0.015)
        }
    }

    @Test("Older two-channel firmware hides CH3 without losing its calibration")
    func oldDevice() {
        var settings = ScopeSettings()
        settings.ensureAnalogChannels(3)
        settings.channels[2].setCalibration(.init(zero: 0.1, scale: 1.02), forRange: 0)
        var caps = SimulatedInstrument().capabilities
        caps.analogChannels = 2
        let config = settings.analogConfiguration(capabilities: caps, scales: [])
        #expect(config.channelMask == 3 && config.channels == 2)
        settings.ensureAnalogChannels(2)
        #expect(settings.channels[2].calibration(forRange: 0).scale == 1.02)
    }

    @Test("Channel checkbox changes reconfigure a running acquisition")
    func liveRates() throws {
        let engine = InstrumentEngine()
        engine.callbackQueue = DispatchQueue(label: "three-channel.rates")
        let ready = DispatchSemaphore(value: 0), planned = DispatchSemaphore(value: 0)
        var latest = AcquisitionPlan.empty
        engine.onStateChange = { if $0.isConnected { ready.signal() } }
        engine.onPlan = { latest = $0; planned.signal() }
        var settings = ScopeSettings(secondsPerDivision: 50e-6)
        settings.ensureAnalogChannels(3)
        settings.trigger.mode = .freeRun
        engine.connect(to: .simulator, settings: settings)
        defer { engine.disconnect() }
        try #require(ready.wait(timeout: .now() + 2) == .success)
        engine.start()
        try #require(planned.wait(timeout: .now() + 2) == .success)
        #expect(latest.channelMask == 7 && abs(latest.sampleRate - 500_000 / 3) < 1e-6)
        settings.channels[1].isEnabled = false
        engine.update(settings: settings)
        try #require(planned.wait(timeout: .now() + 2) == .success)
        #expect(latest.channelMask == 5 && abs(latest.sampleRate - 250_000) < 1e-6)
        settings.channels[0].isEnabled = false
        engine.update(settings: settings)
        try #require(planned.wait(timeout: .now() + 2) == .success)
        #expect(latest.channelMask == 4 && abs(latest.sampleRate - 500_000) < 1e-6)
    }

    @Test("Meter retains all three channel histories")
    func meter() throws {
        let engine = InstrumentEngine()
        engine.callbackQueue = DispatchQueue(label: "three-channel.meter")
        let ready = DispatchSemaphore(value: 0), captured = DispatchSemaphore(value: 0)
        engine.onStateChange = { if $0.isConnected { ready.signal() } }
        engine.onMeterReading = { reading in
            #expect(reading.volts.count == 3 && reading.history.count == 3)
            #expect(reading.history.allSatisfy { !$0.isEmpty })
            captured.signal()
        }
        engine.connect(to: .simulator, settings: ScopeSettings(mode: .meter))
        defer { engine.disconnect() }
        try #require(ready.wait(timeout: .now() + 2) == .success)
        engine.single()
        #expect(captured.wait(timeout: .now() + 2) == .success)
    }
}
