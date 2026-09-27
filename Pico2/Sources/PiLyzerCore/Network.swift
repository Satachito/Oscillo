import Foundation

/// The network a Pico 2 W joins and the name it answers to, as
/// `setNetwork` carries them: fixed UTF-8 fields, zero-padded.
public struct NetworkConfiguration: Equatable, Sendable {
    public static let ssidBytes = 32
    public static let passwordBytes = 64
    public static let hostnameBytes = 32

    public var ssid: String
    public var password: String
    public var hostname: String

    public init(ssid: String, password: String, hostname: String = "pilyzer") {
        self.ssid = ssid
        self.password = password
        self.hostname = hostname
    }

    /// Forgets the network: the instrument joins nothing until told again.
    public static let forget = NetworkConfiguration(ssid: "", password: "", hostname: "")

    /// Why the instrument would refuse this, in words, or nil if it would not.
    /// The same rules as the firmware's (wifi.c).
    public var problem: String? {
        if ssid.isEmpty { return nil }
        if ssid.utf8.count > Self.ssidBytes { return "The network name is longer than 32 bytes." }
        let pass = password.utf8.count
        let hex = pass == 64 && password.allSatisfy(\.isHexDigit)
        if pass != 0 && !(8...63).contains(pass) && !hex {
            return "A WPA password is 8 to 63 characters, or 64 hexadecimal digits."
        }
        let name = hostname.isEmpty ? "pilyzer" : hostname
        let allowed = name.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        if !allowed || name.count > 31 || name.hasPrefix("-") || name.hasSuffix("-") {
            return "The name is lower-case letters, digits and hyphens, up to 31, not starting or ending with a hyphen."
        }
        return nil
    }

    public func encoded() -> Data {
        var writer = ByteWriter()
        writer.append(ssid, padTo: Self.ssidBytes)
        writer.append(password, padTo: Self.passwordBytes)
        writer.append(hostname, padTo: Self.hostnameBytes)
        return writer.data
    }
}

/// What `networkStatus` says: never the password.
public struct NetworkStatus: Equatable, Sendable {
    public enum State: UInt8, Sendable {
        case notSet = 0, joining = 1, joined = 2, failing = 3
    }
    public enum Source: UInt8, Sendable {
        case none = 0, stored = 1, builtIn = 2
    }

    public var state: State
    public var source: Source
    /// Dotted IPv4, once joined.
    public var address: String?
    public var ssid: String
    public var hostname: String

    public init(state: State, source: Source, address: String?, ssid: String, hostname: String) {
        self.state = state
        self.source = source
        self.address = address
        self.ssid = ssid
        self.hostname = hostname
    }

    public init?(_ data: Data) {
        guard data.count >= 72 else { return nil }
        var reader = ByteReader(data)
        state = State(rawValue: reader.uint8()) ?? .notSet
        source = Source(rawValue: reader.uint8()) ?? .none
        _ = reader.uint16()
        let octets = (0..<4).map { _ in reader.uint8() }
        address = state == .joined ? octets.map(String.init).joined(separator: ".") : nil
        ssid = reader.string(32)
        hostname = reader.string(32)
    }

    /// Where the front panel is, once joined.
    public var url: String? { state == .joined ? "http://\(hostname).local" : nil }
}
