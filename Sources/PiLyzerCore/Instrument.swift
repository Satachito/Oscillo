import Foundation

/// The instrument, as the rest of the application needs it.
///
/// Both the real device and the built-in demo signal source implement this, so
/// every path from the front panel down to the samples is exercised whether or
/// not a board is plugged in.
public protocol Instrument: AnyObject {
    var identity: DeviceIdentity { get }
    var capabilities: DeviceCapabilities { get }

    func configureAnalog(_ configuration: AnalogConfiguration) throws -> AcquisitionPlan
    func armAnalog() throws
    func analogStatus() throws -> AcquisitionStatus
    func readAnalog(offset: Int, count: Int) throws -> [UInt16]
    func abortAnalog() throws
    /// An immediate reading of both inputs, for the meter and for calibration.
    func sampleAnalog(averages: Int) throws -> [UInt16]

    func configureLogic(_ configuration: LogicConfiguration) throws -> AcquisitionPlan
    func armLogic() throws
    func logicStatus() throws -> AcquisitionStatus
    func readLogic(offset: Int, count: Int) throws -> [UInt8]
    func abortLogic() throws

    func setRange(channel: Int, range: Int) throws
    func setLED(_ on: Bool) throws
    @discardableResult func setCalibrationOutput(enabled: Bool, frequency: Int) throws -> Int
    /// Restarts the instrument in its bootloader, ready for new firmware.
    func rebootToBootloader() throws
    func close()
}

public extension Instrument {
    func rebootToBootloader() throws {}
}

public extension Instrument {
    /// Reads a finished analogue record and splits the interleaved samples out
    /// into one array per enabled channel.
    func readAnalogRecord(plan: AcquisitionPlan) throws -> [[UInt16]] {
        let channels = max(plan.conversionsPerSample, 1)
        let perChunk = max(Wire.maxPayload / (channels * 2), 1)
        var interleaved: [UInt16] = []
        interleaved.reserveCapacity(plan.recordSamples * channels)

        var offset = 0
        while offset < plan.recordSamples {
            let want = min(perChunk, plan.recordSamples - offset)
            let block = try readAnalog(offset: offset, count: want)
            if block.isEmpty { break }
            interleaved.append(contentsOf: block)
            offset += block.count / channels
        }

        let samples = interleaved.count / channels
        return (0..<channels).map { channel in
            var column = [UInt16]()
            column.reserveCapacity(samples)
            for index in 0..<samples { column.append(interleaved[index * channels + channel]) }
            return column
        }
    }

    func readLogicRecord(plan: AcquisitionPlan) throws -> [UInt8] {
        var samples: [UInt8] = []
        samples.reserveCapacity(plan.recordSamples)
        var offset = 0
        while offset < plan.recordSamples {
            let want = min(Wire.maxPayload, plan.recordSamples - offset)
            let block = try readLogic(offset: offset, count: want)
            if block.isEmpty { break }
            samples.append(contentsOf: block)
            offset += block.count
        }
        return samples
    }
}

/// The USB instrument.
public final class USBInstrument: Instrument {
    public let identity: DeviceIdentity
    public let capabilities: DeviceCapabilities
    public let info: USBDeviceInfo?

    private let transport: USBTransport
    private let lock = NSLock()

    public init(locationID: UInt32 = 0) throws {
        info = USBTransport.attachedDevices().first { locationID == 0 || $0.locationID == locationID }
        transport = try USBInstrument.openAndGreet(locationID: locationID,
                                                   fallback: info?.locationID ?? locationID)

        guard let identity = DeviceIdentity(try transport.exchange(.identify)) else {
            transport.close()
            throw InstrumentError.notPiLyzer
        }
        guard identity.protocolVersion == Wire.version else {
            transport.close()
            throw InstrumentError.unsupportedProtocol(identity.protocolVersion)
        }
        guard let capabilities = DeviceCapabilities(try transport.exchange(.capabilities)) else {
            transport.close()
            throw InstrumentError.shortReply(.capabilities, 0)
        }
        self.identity = identity
        self.capabilities = capabilities
    }

    /// Opens the instrument and makes sure it is answering.
    ///
    /// An instrument left mid-sentence by a host that was killed will not
    /// answer at all, and no amount of asking politely helps: it has to be made
    /// to re-enumerate, which is a replug performed from this end. Firmware
    /// from version 1.1 recovers on its own, so this is the path for older
    /// boards and for the moment before the first reset lands.
    private static func openAndGreet(locationID: UInt32, fallback: UInt32) throws -> USBTransport {
        let transport = try USBTransport(locationID: locationID)
        do {
            _ = try transport.exchange(.identify, timeout: 0.5)
            return transport
        } catch {
            transport.close()
        }

        guard USBTransport.reenumerate(locationID: fallback) else {
            throw InstrumentError.timedOut(.identify)
        }
        // The device leaves the bus and comes back, which takes a moment.
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.1)
            if let recovered = try? USBTransport(locationID: locationID),
               (try? recovered.exchange(.identify, timeout: 0.5)) != nil {
                return recovered
            }
        }
        throw InstrumentError.timedOut(.identify)
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        transport.close()
    }

    private func send(_ opcode: Opcode, _ payload: Data = Data(),
                      timeout: TimeInterval = 1.0) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        return try transport.exchange(opcode, payload: payload, timeout: timeout)
    }

    private func plan(from data: Data, opcode: Opcode) throws -> AcquisitionPlan {
        guard let plan = AcquisitionPlan(data) else { throw InstrumentError.shortReply(opcode, data.count) }
        return plan
    }

    private func status(from data: Data, opcode: Opcode) throws -> AcquisitionStatus {
        guard let status = AcquisitionStatus(data) else { throw InstrumentError.shortReply(opcode, data.count) }
        return status
    }

    // MARK: - Analogue

    public func configureAnalog(_ configuration: AnalogConfiguration) throws -> AcquisitionPlan {
        try plan(from: try send(.analogConfigure, configuration.encoded()), opcode: .analogConfigure)
    }

    public func armAnalog() throws { _ = try send(.analogArm) }

    public func analogStatus() throws -> AcquisitionStatus {
        try status(from: try send(.analogStatus), opcode: .analogStatus)
    }

    public func readAnalog(offset: Int, count: Int) throws -> [UInt16] {
        var writer = ByteWriter()
        writer.append(UInt32(clamping: offset))
        writer.append(UInt32(clamping: count))
        let data = try send(.analogRead, writer.data, timeout: 2.0)
        return data.withUnsafeBytes { bytes in
            (0..<(bytes.count / 2)).map { index in
                UInt16(bytes[index * 2]) | (UInt16(bytes[index * 2 + 1]) << 8)
            }
        }
    }

    public func abortAnalog() throws { _ = try send(.analogAbort) }

    public func sampleAnalog(averages: Int) throws -> [UInt16] {
        var writer = ByteWriter()
        writer.append(UInt16(clamping: averages))
        let data = try send(.analogSample, writer.data, timeout: 2.0)
        guard data.count >= 4 else { throw InstrumentError.shortReply(.analogSample, data.count) }
        var reader = ByteReader(data)
        return [reader.uint16(), reader.uint16()]
    }

    // MARK: - Logic

    public func configureLogic(_ configuration: LogicConfiguration) throws -> AcquisitionPlan {
        try plan(from: try send(.logicConfigure, configuration.encoded()), opcode: .logicConfigure)
    }

    public func armLogic() throws { _ = try send(.logicArm) }

    public func logicStatus() throws -> AcquisitionStatus {
        try status(from: try send(.logicStatus), opcode: .logicStatus)
    }

    public func readLogic(offset: Int, count: Int) throws -> [UInt8] {
        var writer = ByteWriter()
        writer.append(UInt32(clamping: offset))
        writer.append(UInt32(clamping: count))
        return [UInt8](try send(.logicRead, writer.data, timeout: 2.0))
    }

    public func abortLogic() throws { _ = try send(.logicAbort) }

    // MARK: - Peripherals

    public func setRange(channel: Int, range: Int) throws {
        var writer = ByteWriter()
        writer.append(UInt8(clamping: channel))
        writer.append(UInt8(clamping: range))
        _ = try send(.setRange, writer.data)
    }

    public func setLED(_ on: Bool) throws {
        var writer = ByteWriter()
        writer.append(UInt8(on ? 1 : 0))
        _ = try send(.setLED, writer.data)
    }

    @discardableResult
    public func setCalibrationOutput(enabled: Bool, frequency: Int) throws -> Int {
        var writer = ByteWriter()
        writer.append(UInt8(enabled ? 1 : 0))
        writer.append(UInt32(clamping: frequency))
        let data = try send(.setCalibrationOutput, writer.data)
        var reader = ByteReader(data)
        return Int(reader.uint32())
    }

    public func rebootToBootloader() throws {
        _ = try send(.rebootToBootloader)
    }
}
