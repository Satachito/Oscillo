import Foundation
import Testing
@testable import PiLyzerCore

@Suite("Software AC coupling")
struct MeanRemovalTests {
    @Test("Removing the mean actually removes it from the samples the panel measures")
    func removesMean() {
        let queue = DispatchQueue(label: "test.mean")
        let engine = InstrumentEngine()
        engine.callbackQueue = queue

        var settings = ScopeSettings()
        settings.secondsPerDivision = 1e-3
        settings.recordLength = 1024
        settings.ensureAnalogChannels(3)
        // The demo's channel two carries a 250 mV offset; channel one has none.
        settings.channels[1].removesMean = true

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
        let second = try! #require(captured.trace(1))
        let mean = second.samples.reduce(0, +) / Double(second.samples.count)
        #expect(abs(mean) < 0.01)
        engine.disconnect()
    }
}
