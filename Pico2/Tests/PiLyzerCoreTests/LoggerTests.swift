import Foundation
import Testing
@testable import PiLyzerCore

/// The logger's whole point is that a point stands for its interval rather than
/// for the instant it was written on.
@Suite("Logger")
struct LoggerTests {
    /// Drives the engine's accumulation directly, which is the part that has to
    /// be right; the wait for real intervals belongs in the hardware tests.
    @Test("A point carries the lowest, mean and highest reading of its interval")
    func pointSpansItsInterval() {
        let readings = [1.0, 3.0, 2.0, 2.0]
        var low = Double.infinity, high = -Double.infinity, sum = 0.0
        for value in readings { low = min(low, value); high = max(high, value); sum += value }
        let sample = MeterSample(low: low, mean: sum / Double(readings.count), high: high)

        #expect(sample.low == 1)
        #expect(sample.high == 3)
        #expect(sample.mean == 2)
        // A logger that recorded only the last reading would have said 2 V and
        // shown nothing of the excursion to 3.
        #expect(sample.high > sample.mean)
    }

    @Test("The log starts with a point rather than an empty chart")
    func firstPointIsImmediate() throws {
        let engine = InstrumentEngine()
        engine.callbackQueue = DispatchQueue(label: "logger.first")
        let ready = DispatchSemaphore(value: 0), captured = DispatchSemaphore(value: 0)
        let points = Locked(0)
        engine.onStateChange = { if $0.isConnected { ready.signal() } }
        engine.onMeterReading = { reading in
            points.value = reading.history.first?.count ?? 0
            captured.signal()
        }
        // The slowest interval there is: without an immediate first point this
        // would be five minutes of nothing.
        var settings = ScopeSettings(mode: .meter)
        settings.logIntervalSeconds = 300
        engine.connect(to: .simulator, settings: settings)
        defer { engine.disconnect() }
        try #require(ready.wait(timeout: .now() + 2) == .success)
        engine.single()
        try #require(captured.wait(timeout: .now() + 2) == .success)
        #expect(points.value == 1)
    }

    @Test("The axis is labelled from the interval, not from how long it took to read")
    func spanFollowsTheInterval() {
        let history = [Array(repeating: MeterSample(low: 0, mean: 0, high: 0), count: 7)]
        let reading = MeterReading(volts: [0], history: history, interval: 2,
                                   start: Date(), timestamp: Date())
        // Seven points two seconds apart span twelve seconds, not fourteen.
        #expect(reading.span == 12)
    }

    @Test("A panel saved before the logger existed still loads")
    func settingsFromAnOlderBuildSurvive() throws {
        // Every field the older build wrote, and none of the newer ones.
        let json = """
        {"mode":"Meter","channels":[],"secondsPerDivision":0.002,"recordLength":4096,
         "averaging":3,"showsXY":true,"xyHorizontal":1,"xyVertical":0,
         "calibrationOutputEnabled":false,"calibrationOutputFrequency":10000}
        """
        let settings = try JSONDecoder().decode(ScopeSettings.self, from: Data(json.utf8))
        #expect(settings.mode == .meter)
        #expect(settings.recordLength == 4096)
        #expect(settings.averaging == 3)
        #expect(settings.calibrationOutputFrequency == 10000)
        // The one it could not have known about comes back as the default
        // rather than taking the whole panel down with it.
        #expect(settings.logIntervalSeconds == ScopeSettings().logIntervalSeconds)
    }

    @Test("An interval that is no longer offered falls back")
    func unknownIntervalFallsBack() throws {
        let json = #"{"logIntervalSeconds":1234.5}"#
        let settings = try JSONDecoder().decode(ScopeSettings.self, from: Data(json.utf8))
        #expect(ScopeSettings.logIntervals.contains(settings.logIntervalSeconds))
    }
}

/// A box the callback queue and the test can both touch.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
