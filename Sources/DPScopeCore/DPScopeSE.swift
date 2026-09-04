import Foundation

/// The DPScope SE command set, over USB HID.
///
/// Opcodes and packet layout follow the vendor's *DPScope SE Programming
/// Interface Description V1.0.0*. `CMD_READBACK` is left blank in that
/// document; its behaviour here — a block index parameter, answering with 32
/// interleaved sample pairs and no acknowledge byte — was determined by
/// probing the hardware.
public final class DPScopeSE: ScopeDevice {
    enum Command: UInt8 {
        case ping = 2
        case revision = 3
        case arm = 5
        case done = 6
        case abort = 7
        case readback = 8
        case readADC = 9
        case statusLED = 10
        case writeMemory = 11
        case readMemory = 12
        case writeEEPROM = 13
        case readEEPROM = 14
        case readLogicAnalyzer = 15
        case initialize = 17
        case serialInit = 18
        case serialTransmit = 19
    }

    private let transport: HIDTransport
    private let lock = NSLock()

    public let deviceInfo: HIDDeviceInfo?

    public init(locationID: UInt32? = nil) throws {
        transport = try HIDTransport(locationID: locationID)
        deviceInfo = HIDTransport.availableDevices().first { locationID == nil || $0.locationID == locationID }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        transport.close()
    }

    // MARK: - Packet plumbing

    /// Sends a command whose answer starts with an acknowledge byte.
    @discardableResult
    private func send(_ command: Command, _ parameters: [UInt8] = [], timeout: TimeInterval = 1.0) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        let reply = try transport.exchange([command.rawValue] + parameters, timeout: timeout)
        guard let acknowledge = reply.first else {
            throw DPScopeError.shortReply(command: command.rawValue, length: reply.count)
        }
        guard acknowledge == command.rawValue else {
            throw DPScopeError.unexpectedAcknowledge(command: command.rawValue, received: acknowledge)
        }
        return Array(reply.dropFirst())
    }

    /// Sends a command that answers with data only — no acknowledge byte.
    private func sendUnacknowledged(_ command: Command, _ parameters: [UInt8] = [], timeout: TimeInterval = 1.0) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return try transport.exchange([command.rawValue] + parameters, timeout: timeout)
    }

    // MARK: - ScopeDevice

    public func identify() throws -> String {
        let data = try send(.ping)
        return String(decoding: data.prefix(10), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func firmwareRevision() throws -> (UInt8, UInt8) {
        let data = try sendUnacknowledged(.revision)
        guard data.count >= 2 else {
            throw DPScopeError.shortReply(command: Command.revision.rawValue, length: data.count)
        }
        return (data[0], data[1])
    }

    public func arm(_ setup: AcquisitionSetup) throws {
        try send(.arm, setup.parameterBytes)
    }

    public func isAcquisitionDone() throws -> Bool {
        let data = try sendUnacknowledged(.done)
        guard let flag = data.first else {
            throw DPScopeError.shortReply(command: Command.done.rawValue, length: data.count)
        }
        return flag > 0
    }

    public func abort() throws {
        try send(.abort)
    }

    public func readBlock(_ index: UInt8) throws -> [UInt8] {
        try sendUnacknowledged(.readback, [index])
    }

    public func readADC(first: ADCChannel, second: ADCChannel, adcon2: UInt8) throws -> (UInt16, UInt16) {
        let data = try sendUnacknowledged(.readADC, [first.rawValue, second.rawValue, adcon2])
        guard data.count >= 4 else {
            throw DPScopeError.shortReply(command: Command.readADC.rawValue, length: data.count)
        }
        return (UInt16(data[0]) << 8 | UInt16(data[1]), UInt16(data[2]) << 8 | UInt16(data[3]))
    }

    public func setStatusLED(_ on: Bool) throws {
        try send(.statusLED, [on ? 1 : 0])
    }

    public func readLogicInputs() throws -> UInt8 {
        let data = try sendUnacknowledged(.readLogicAnalyzer)
        guard let port = data.first else {
            throw DPScopeError.shortReply(command: Command.readLogicAnalyzer.rawValue, length: data.count)
        }
        return port
    }
}
