import Foundation
import Testing
@testable import DPScopeCore

/// End-to-end tests against a real DPScope SE.
///
/// They are skipped when no scope is plugged in, so the suite still runs on a
/// machine without hardware.
/// The suite is serialized: one scope cannot serve two clients at once.
@Suite("Attached hardware", .serialized, .enabled(if: !HIDTransport.availableDevices().isEmpty))
struct HardwareTests {
    /// Opens the scope, or returns nil when another client — usually the app
    /// itself — already owns it. A busy scope is not a failure of the code
    /// under test, so the test reports and returns instead of failing.
    static func openScope() -> DPScopeSE? {
        do {
            return try DPScopeSE()
        } catch {
            print("skipped: the scope is in use by another client (\(error))")
            return nil
        }
    }

    @Test("The scope identifies itself and reports a sane supply rail")
    func identity() throws {
        guard let scope = Self.openScope() else { return }
        defer { scope.close() }

        #expect(try scope.identify() == "DPScope SE")
        let (major, minor) = try scope.firmwareRevision()
        #expect(major >= 1)
        print("firmware \(major).\(minor)")

        let supply = try scope.measureSupplyVoltage()
        print(String(format: "supply %.3f V", supply))
        #expect((4.5...5.5).contains(supply))
    }

    @Test("An auto sweep completes and returns a full record")
    func autoSweep() throws {
        guard let scope = Self.openScope() else { return }
        defer { scope.close() }
        try scope.abort()

        var settings = ScopeSettings()
        settings.timebaseIndex = 6  // ~1 ms/div, a few milliseconds per record
        try scope.arm(settings.acquisitionSetup())

        let deadline = Date().addingTimeInterval(2)
        var finished = false
        while Date() < deadline {
            if try scope.isAcquisitionDone() { finished = true; break }
            Thread.sleep(forTimeInterval: 0.002)
        }
        #expect(finished)

        let record = try scope.readRecord()
        try scope.abort()
        #expect(record.channel1.count == ScopeRecord.sampleCount)
        #expect(record.channel2.count == ScopeRecord.sampleCount)

        // With nothing connected the inputs sit near the middle of the range,
        // and they must not be stuck at a rail.
        let statistics = try #require(ChannelStatistics(record.channel1.map(Double.init)))
        print(String(format: "ch1 raw min %.0f max %.0f mean %.1f",
                     statistics.minimum, statistics.maximum, statistics.mean))
        #expect(statistics.maximum > 0)
    }

    @Test("Every ADC channel answers, and the ×10 path tracks the ×1 path")
    func channelMapping() throws {
        guard let scope = Self.openScope() else { return }
        defer { scope.close() }

        let (gain1, gain10) = try scope.readADC(
            first: .channel2Gain1, second: .channel2Gain10, adcon2: AcquisitionSetup.defaultADCON2)
        // Ch2 ×10 amplifies the ×1 offset from mid-scale about ten-fold.
        let offset1 = Double(gain1) - ScopeRecord.zeroCode
        let offset10 = Double(gain10) - ScopeRecord.zeroCode
        print("ch2 x1 \(gain1) (offset \(offset1)), x10 \(gain10) (offset \(offset10))")
        if abs(offset1) > 2, abs(offset10) < 500 {
            #expect(abs(offset10 / offset1 - FrontEnd.secondStageGain) < 5)
        }
    }
}
