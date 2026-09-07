import Foundation
import Testing
@testable import PiLyzerCore

@Suite("Trigger low-pass")
struct TriggerFilterTests {
    @Test("The LPF cutoff uses the reserved word without changing packet size")
    func wireExtension() {
        let off = AnalogConfiguration().encoded()
        let on = AnalogConfiguration(triggerLowPassHz: 1000).encoded()
        #expect(off.count == 32 && on.count == 32)
        #expect(off.prefix(28) == on.prefix(28))
        var reader = ByteReader(Data(on.suffix(4)))
        #expect(reader.uint32() == 1000)
        #expect(off.suffix(4).allSatisfy { $0 == 0 })
        var caps = DeviceCapabilities.unavailable
        #expect(!caps.hasTriggerLowPass)
        caps.flags |= 8
        #expect(caps.hasTriggerLowPass)
    }

    @Test("Old saved settings retain their calibration and default LPF to Off")
    func legacyPreferences() throws {
        var original = ScopeSettings()
        original.trigger.levelVolts = 1.65
        original.channels[0].calibrateZero(to: 0.025, forRange: 0)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var trigger = try #require(json["trigger"] as? [String: Any])
        trigger.removeValue(forKey: "lowPassHz")
        json["trigger"] = trigger
        let loaded = try JSONDecoder().decode(ScopeSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(loaded == original)
        original.trigger.lowPassHz = 1000
        let roundTrip = try JSONDecoder().decode(ScopeSettings.self, from: JSONEncoder().encode(original))
        #expect(roundTrip.trigger.lowPassHz == 1000)
    }

    @Test("The panel sends the selected cutoff")
    func panelConfiguration() {
        let caps = SimulatedInstrument().capabilities
        var settings = ScopeSettings()
        settings.trigger.lowPassHz = 1000
        let scales = settings.channels.map {
            $0.scale(reference: caps.referenceVolts, fullScale: caps.analogFullScale, ranges: FrontEnd.revA)
        }
        #expect(settings.analogConfiguration(capabilities: caps, scales: scales).triggerLowPassHz == 1000)
    }

    @Test("Off is bit-exact; the cutoff follows physical time across timebases")
    func filterTiming() {
        var off = TriggerFilter(cutoffHz: 0, samplePeriod: 4e-6)
        for code in stride(from: 0, through: 65535, by: 257) {
            #expect(off.sample(UInt16(code)) == code)
        }
        for divisor in [1, 2, 4] {
            var filter = TriggerFilter(cutoffHz: 1000, samplePeriod: Double(divisor) * 4e-6)
            _ = filter.sample(0)
            var output = 0
            for _ in 0..<(40 / divisor) { output = filter.sample(65520) }
            let expected = 65520 * (1 - exp(-2 * Double.pi * 1000 * 160e-6))
            #expect(abs(Double(output) - expected) < 1)
        }
    }

    @Test("A 194 Hz stepped waveform has less trigger jitter with the 1 kHz LPF")
    func steppedSignal() throws {
        func crossing(cutoff: Int, phase: Double) -> Double? {
            var filter = TriggerFilter(cutoffHz: cutoff, samplePeriod: 4e-6)
            var armed = false
            for index in 0..<2000 {
                let time = -0.45 / 194 + Double(index) * 4e-6
                let stair = sin(2 * Double.pi * floor(time * 194 * 30) / 30)
                let ripple = 200 * sin(2 * Double.pi * 8000 * time + phase)
                let raw = UInt16((32768 + 20000 * stair + ripple).rounded())
                let value = filter.sample(raw)
                guard filter.remaining == 0 else { continue }
                if !armed {
                    armed = value < 32768 - 256
                } else if value >= 32768 {
                    return time
                }
            }
            return nil
        }
        var raw: [Double] = []
        var filtered: [Double] = []
        for index in 0..<128 {
            let phase = Double(index) * 2 * Double.pi / 128
            raw.append(try #require(crossing(cutoff: 0, phase: phase)))
            filtered.append(try #require(crossing(cutoff: 1000, phase: phase)))
        }
        let rawSpan = raw.max()! - raw.min()!
        let filteredSpan = filtered.max()! - filtered.min()!
        #expect(rawSpan > 40e-6)
        #expect(filteredSpan < rawSpan / 2)
    }

    @Test("The simulator triggers on a filtered crossing but preserves raw steps")
    func simulatorKeepsWaveform() throws {
        let device = SimulatedInstrument()
        device.noise = 0
        device.tones[0] = .init(frequency: 194, amplitude: 2, isSquare: true)
        let plan = try device.configureAnalog(.init(channelMask: 1, triggerMode: .normal,
                                                    samplePeriod: 4e-6, recordSamples: 4096,
                                                    pretriggerSamples: 1024, triggerLowPassHz: 1000))
        try device.armAnalog()
        Thread.sleep(forTimeInterval: plan.duration + 0.005)
        let status = try device.analogStatus()
        #expect(status.triggered)
        let raw = try device.readAnalogRecord(plan: plan)[0]
        #expect(Set(raw).count == 2) // An LPF on the stored waveform would add levels.
        #expect(raw[status.triggerIndex - 1] == raw[status.triggerIndex])
        #expect(raw[status.triggerIndex] > 32768)
    }
}
