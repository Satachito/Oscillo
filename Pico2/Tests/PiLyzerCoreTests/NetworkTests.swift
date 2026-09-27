import Foundation
import Testing
@testable import PiLyzerCore

@Suite("Pico 2 W network")
struct NetworkTests {
    @Test("A network is sent as three zero-padded fields")
    func encoding() {
        let data = NetworkConfiguration(ssid: "Home-2G", password: "correct horse", hostname: "bench").encoded()
        #expect(data.count == 128)
        #expect(String(decoding: data[0..<7], as: UTF8.self) == "Home-2G")
        #expect(data[7] == 0)
        #expect(String(decoding: data[32..<45], as: UTF8.self) == "correct horse")
        #expect(String(decoding: data[96..<101], as: UTF8.self) == "bench")
        #expect(NetworkConfiguration.forget.encoded() == Data(count: 128))
    }

    @Test("The status is read back, with no address until joined")
    func status() throws {
        var bytes = [UInt8](repeating: 0, count: 72)
        bytes[0] = 2
        bytes[1] = 1
        bytes.replaceSubrange(4..<8, with: [192, 168, 0, 11])
        bytes.replaceSubrange(8..<15, with: Array("Home-2G".utf8))
        bytes.replaceSubrange(40..<45, with: Array("bench".utf8))
        let joined = try #require(NetworkStatus(Data(bytes)))
        #expect(joined.state == .joined && joined.source == .stored)
        #expect(joined.address == "192.168.0.11" && joined.ssid == "Home-2G" && joined.hostname == "bench")
        #expect(joined.url == "http://bench.local")
        bytes[0] = 3
        let failing = try #require(NetworkStatus(Data(bytes)))
        #expect(failing.address == nil && failing.url == nil)
        #expect(NetworkStatus(Data(count: 10)) == nil)
    }

    @Test("A network the board would refuse is caught before it is sent")
    func problems() {
        #expect(NetworkConfiguration(ssid: "Home", password: "longenough", hostname: "").problem == nil)
        #expect(NetworkConfiguration(ssid: "Cafe", password: "", hostname: "pilyzer").problem == nil)
        #expect(NetworkConfiguration.forget.problem == nil)
        #expect(NetworkConfiguration(ssid: "Home", password: "short", hostname: "").problem != nil)
        #expect(NetworkConfiguration(ssid: "Home", password: String(repeating: "a", count: 64), hostname: "").problem == nil)
        #expect(NetworkConfiguration(ssid: "Home", password: "longenough", hostname: "Bench_1").problem != nil)
        #expect(NetworkConfiguration(ssid: String(repeating: "x", count: 33), password: "", hostname: "").problem != nil)
    }
}
