import Foundation
import Testing
@testable import DPScopeCore

/// Thread-safe collector for the engine's callbacks, which arrive on a
/// background queue in these tests.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFrames: [ScopeFrame] = []
    private var storedState: ConnectionState = .disconnected
    private var storedErrors: [String] = []

    var frames: [ScopeFrame] { lock.withLock { storedFrames } }
    var state: ConnectionState { lock.withLock { storedState } }
    var errors: [String] { lock.withLock { storedErrors } }

    private var storedSupply: Double?
    private var storedZeros: (Double, Double, Double, Double)?
    var supply: Double? { lock.withLock { storedSupply } }
    var zeros: (Double, Double, Double, Double)? { lock.withLock { storedZeros } }

    func attach(to engine: ScopeEngine) {
        engine.callbackQueue = DispatchQueue(label: "dpscope.tests.callbacks")
        engine.onFrame = { [self] frame in lock.withLock { storedFrames.append(frame) } }
        engine.onStateChange = { [self] state in lock.withLock { storedState = state } }
        engine.onError = { [self] message in lock.withLock { storedErrors.append(message) } }
        engine.onSupplyVoltage = { [self] volts in lock.withLock { storedSupply = volts } }
        engine.onZeroCalibration = { [self] zeros in lock.withLock { storedZeros = zeros } }
    }
}

/// Polls `condition` until it holds or the deadline passes.
@discardableResult
func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

@Suite("Acquisition engine")
struct EngineTests {
    @Test("Connecting to the demo source reports the firmware identity")
    func connect() async throws {
        let engine = ScopeEngine()
        let recorder = Recorder()
        recorder.attach(to: engine)

        engine.connect(to: .simulator, settings: ScopeSettings())
        #expect(await waitUntil { recorder.state.isConnected })

        guard case let .connected(identity, source) = recorder.state else {
            Issue.record("expected a connected state, got \(recorder.state)")
            return
        }
        #expect(identity.contains("DPScope SE"))
        #expect(source == .simulator)
        #expect(recorder.errors.isEmpty)

        engine.disconnect()
        #expect(await waitUntil { recorder.state == .disconnected })
    }

    @Test("Running delivers full two-channel sweeps")
    func scopeFrames() async throws {
        let engine = ScopeEngine()
        let recorder = Recorder()
        recorder.attach(to: engine)

        var settings = ScopeSettings()
        settings.timebaseIndex = 6  // 1 ms/div

        engine.connect(to: .simulator, settings: settings)
        #expect(await waitUntil { recorder.state.isConnected })

        engine.start()
        #expect(await waitUntil { recorder.frames.count >= 3 })
        engine.stop()

        let frame = try #require(recorder.frames.last)
        #expect(frame.mode == .scope)
        #expect(frame.channel1.count == ScopeRecord.sampleCount)
        #expect(frame.channel2.count == ScopeRecord.sampleCount)
        #expect(abs(frame.duration - 10 * Timebase.all[6].secondsPerDivision) < 1e-6)
        // The demo sine is 3 V peak to peak, centred on zero.
        let statistics = try #require(ChannelStatistics(frame.channel1))
        #expect(abs(statistics.mean) < 0.5)
        #expect(abs(statistics.peakToPeak - 3.0) < 0.6)
        #expect(recorder.errors.isEmpty)
    }

    @Test("Switching a channel off leaves its trace empty")
    func singleChannel() async throws {
        let engine = ScopeEngine()
        let recorder = Recorder()
        recorder.attach(to: engine)

        var settings = ScopeSettings()
        settings.channel2.isEnabled = false

        engine.connect(to: .simulator, settings: settings)
        #expect(await waitUntil { recorder.state.isConnected })

        engine.acquireSingle()
        #expect(await waitUntil { !recorder.frames.isEmpty })

        let frame = try #require(recorder.frames.last)
        #expect(frame.channel1.count == ScopeRecord.sampleCount)
        #expect(frame.channel2.isEmpty)
    }

    @Test("Averaging keeps the record length and smooths the noise")
    func averaging() async throws {
        let engine = ScopeEngine()
        let recorder = Recorder()
        recorder.attach(to: engine)

        var settings = ScopeSettings()
        settings.averaging = 8
        engine.connect(to: .simulator, settings: settings)
        #expect(await waitUntil { recorder.state.isConnected })

        engine.acquireSingle()
        #expect(await waitUntil { !recorder.frames.isEmpty })

        let frame = try #require(recorder.frames.last)
        #expect(frame.channel1.count == ScopeRecord.sampleCount)
        #expect(frame.channel1.allSatisfy { $0.isFinite })
    }

    @Test("Data-log mode accumulates points over time")
    func datalog() async throws {
        let engine = ScopeEngine()
        let recorder = Recorder()
        recorder.attach(to: engine)

        var settings = ScopeSettings()
        settings.mode = .datalog
        settings.timebaseIndex = 6

        engine.connect(to: .simulator, settings: settings)
        #expect(await waitUntil { recorder.state.isConnected })

        engine.start()
        #expect(await waitUntil(timeout: 10) { (recorder.frames.last?.channel1.count ?? 0) >= 5 })
        engine.stop()

        let frames = recorder.frames
        let counts = frames.map(\.channel1.count)
        #expect(counts == counts.sorted())
        #expect(frames.last?.mode == .datalog)

        // Clearing throws the log away.
        engine.clear()
        #expect(await waitUntil { recorder.frames.last?.channel1.isEmpty == true })
    }

    @Test("Connecting to a scope that is not there fails without crashing")
    func missingDevice() async throws {
        let engine = ScopeEngine()
        let recorder = Recorder()
        recorder.attach(to: engine)

        engine.connect(to: .usb(locationID: 0xDEAD_BEEF), settings: ScopeSettings())
        #expect(await waitUntil {
            if case .failed = recorder.state { return true }
            return false
        })
        #expect(!recorder.state.isConnected)
    }

    @Test("Connecting measures the supply rail the readings are scaled by")
    func supplyMeasurement() async throws {
        let engine = ScopeEngine()
        let recorder = Recorder()
        recorder.attach(to: engine)

        engine.connect(to: .simulator, settings: ScopeSettings())
        #expect(await waitUntil { recorder.state.isConnected })
        let supply = try #require(recorder.supply)
        #expect(abs(supply - 5.17) < 0.05)
    }

    @Test("Zero calibration reports a code for each channel and path")
    func zeroCalibration() async throws {
        let engine = ScopeEngine()
        let recorder = Recorder()
        recorder.attach(to: engine)

        engine.connect(to: .simulator, settings: ScopeSettings())
        #expect(await waitUntil { recorder.state.isConnected })

        engine.calibrateZero(samples: 8)
        #expect(await waitUntil { recorder.zeros != nil })

        let zeros = try #require(recorder.zeros)
        for code in [zeros.0, zeros.1, zeros.2, zeros.3] {
            #expect((0...1023).contains(code))
        }
        // The demo signal is centred, so the averages land near mid-scale.
        #expect(abs(zeros.0 - ScopeRecord.zeroCode) < 60)
    }

    @Test("A railed front end is reported as clipping, not as a flat signal")
    func clippingDetection() {
        #expect(ScopeEngine.isClipped([128, 129, 130]) == false)
        #expect(ScopeEngine.isClipped([255, 255, 128]) == false)
        #expect(ScopeEngine.isClipped([255, 255, 255]))
        #expect(ScopeEngine.isClipped([0, 0, 0, 128]))
        // A single sample touching the limit is not enough to call it.
        #expect(ScopeEngine.isClipped([0, 128, 255, 128]) == false)
    }

    @Test("Auto mode still triggers when it can, so the trace stands still")
    func autoModeTriggers() async throws {
        let engine = ScopeEngine()
        let recorder = Recorder()
        recorder.attach(to: engine)

        var settings = ScopeSettings()
        settings.trigger.mode = .auto       // the default
        settings.channel2.isEnabled = false
        engine.connect(to: .simulator, settings: settings)
        #expect(await waitUntil { recorder.state.isConnected })

        engine.start()
        #expect(await waitUntil { recorder.frames.count >= 4 })
        engine.stop()

        // Successive sweeps of the same repetitive signal must line up: a
        // free-running sweep would start at a different phase every time.
        let frames = recorder.frames.filter { $0.channel1.count == ScopeRecord.sampleCount }
        #expect(frames.count >= 3)
        #expect(frames.allSatisfy { $0.isTriggered })

        let reference = try #require(frames.first?.channel1)
        for frame in frames.dropFirst() {
            let difference = zip(reference, frame.channel1).map { abs($0 - $1) }.max() ?? 0
            #expect(difference < 0.25, "sweeps drift apart by \(difference) V")
        }
    }
}
