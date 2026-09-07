import CPiLyzerUSB
import Foundation

public enum InstrumentError: Error, LocalizedError, Equatable {
    case notConnected
    case openFailed(Int32)
    case inUse
    case transferFailed(Int32)
    case timedOut(Opcode)
    case shortReply(Opcode, Int)
    case rejected(Opcode, WireStatus)
    case desynchronised
    case notPiLyzer
    case unsupportedProtocol(UInt16)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "No instrument is connected."
        case let .openFailed(code):
            return String(format: "Could not open the instrument (IOKit 0x%08X).", UInt32(bitPattern: code))
        case .inUse:
            return "Another program has the instrument open. Close it and try again."
        case let .transferFailed(code):
            return String(format: "USB transfer failed (IOKit 0x%08X).", UInt32(bitPattern: code))
        case let .timedOut(opcode):
            return "The instrument did not answer \(opcode)."
        case let .shortReply(opcode, length):
            return "The answer to \(opcode) was \(length) bytes, which is too short."
        case let .rejected(opcode, status):
            return "The instrument refused \(opcode): \(status.description)."
        case .desynchronised:
            return "The instrument and the application lost step with each other."
        case .notPiLyzer:
            return "That device is not a PiLyzer."
        case let .unsupportedProtocol(version):
            return "The instrument speaks protocol version \(version), which this application does not."
        }
    }
}

public struct USBDeviceInfo: Equatable, Hashable, Sendable, Identifiable {
    public var locationID: UInt32
    public var productID: UInt16
    public var serial: String
    public var product: String

    public var id: UInt32 { locationID }
    public var label: String {
        let name = product.isEmpty ? "PiLyzer" : product
        return serial.isEmpty ? name : "\(name) · \(serial.suffix(6))"
    }
}

/// A board that is on the bus but is not an instrument. Saying why is much more
/// use than an empty list: almost every time, the firmware is simply not on it
/// yet.
public struct UnprogrammedBoard: Equatable, Sendable {
    public var productID: UInt16
    public var product: String
    /// The chip is sitting in its own bootloader, waiting to be given a UF2.
    public var isInBootloader: Bool

    public var advice: String {
        if isInBootloader {
            return "A Raspberry Pi board is in BOOTSEL — copy pilyzer.uf2 onto it."
        }
        // The identifier is worth spelling out: earlier firmware for this
        // project used the same product string, so the name alone does not say
        // whether what is attached is the right thing.
        let name = product.isEmpty ? "board" : "\"\(product)\""
        return String(format: "A Raspberry Pi %@ (2E8A:%04X) is attached but does not speak the PiLyzer protocol — flash pilyzer.uf2.",
                      name, productID)
    }
}

/// One request, one answer, over the bulk pipes.
///
/// Bulk reads have to be a whole number of packets, so everything the caller
/// asks for is rounded up and the surplus is kept for the next read. That is
/// the only subtlety here; the rest is a straight request/response exchange.
public final class USBTransport {
    /// Nil once closed. The handle is freed by the C side, so closing twice
    /// would free it twice — and both an explicit close and deinit happen in
    /// the ordinary course of disconnecting.
    private var handle: OpaquePointer?
    private let packetSize: Int
    private var pending = Data()
    private var sequence: UInt16 = 0

    private static func enumerate(vendor: UInt16, product: UInt16) -> [USBDeviceInfo] {
        var buffer = [pilyzer_usb_info](repeating: pilyzer_usb_info(), count: 16)
        let count = buffer.withUnsafeMutableBufferPointer { pointer in
            pilyzer_usb_enumerate(vendor, product, pointer.baseAddress, 16)
        }
        guard count > 0 else { return [] }
        return buffer.prefix(Int(count)).map { info in
            var info = info
            let serial = withUnsafeBytes(of: &info.serial) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            let name = withUnsafeBytes(of: &info.product) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            return USBDeviceInfo(locationID: info.location_id, productID: info.product_id,
                                 serial: serial, product: name)
        }
    }

    /// Instruments on the bus.
    ///
    /// The prototype identifier is shared — pid.codes hands 1209:0001 to
    /// anyone — so the product string is checked as well. Something else on the
    /// same identifier should not appear in the instrument list and then fail
    /// to open.
    public static func attachedDevices() -> [USBDeviceInfo] {
        enumerate(vendor: Wire.vendorID, product: Wire.productID)
            .filter { $0.product.localizedCaseInsensitiveContains("pilyzer") }
    }

    /// Raspberry Pi boards that are attached but are not instruments, so the
    /// application can explain an empty list instead of just showing one.
    public static func unprogrammedBoards() -> [UnprogrammedBoard] {
        enumerate(vendor: Wire.raspberryPiVendorID, product: 0).map { info in
            UnprogrammedBoard(productID: info.productID, product: info.product,
                              isInBootloader: Wire.bootloaderProductIDs.contains(info.productID))
        }
    }

    public init(locationID: UInt32 = 0) throws {
        var error: Int32 = 0
        guard let opened = pilyzer_usb_open(Wire.vendorID, Wire.productID, locationID, &error) else {
            // kIOReturnExclusiveAccess
            if error == Int32(bitPattern: UInt32(0xE000_02C5)) { throw InstrumentError.inUse }
            throw InstrumentError.openFailed(error)
        }
        handle = opened
        packetSize = max(Int(pilyzer_usb_packet_size(opened)), 64)
        drain()
    }

    /// Throws away anything left in the pipe by a previous session.
    ///
    /// A host that died mid-exchange leaves an answer nobody read. Without
    /// this the first request of the next session gets the tail of the last
    /// one and every exchange after it is one reply behind.
    private func drain() {
        guard let handle else { return }
        var chunk = [UInt8](repeating: 0, count: packetSize)
        for _ in 0..<16 {
            var transferred: UInt32 = 0
            let result = chunk.withUnsafeMutableBytes { bytes in
                pilyzer_usb_read(handle, bytes.baseAddress, UInt32(packetSize), 25, &transferred)
            }
            if result != 0 || transferred == 0 { return }
        }
    }

    /// Asks the instrument to re-enumerate: a replug done from this end.
    ///
    /// This is the way back from a wedged instrument, and it invalidates the
    /// handle — the caller has to open a new transport afterwards.
    public static func reenumerate(locationID: UInt32) -> Bool {
        pilyzer_usb_reenumerate(Wire.vendorID, Wire.productID, locationID) == 0
    }

    deinit { close() }

    public func close() {
        guard let open = handle else { return }
        handle = nil
        pilyzer_usb_close(open)
    }

    public var isOpen: Bool { handle != nil }

    public func reset() {
        pending.removeAll(keepingCapacity: true)
        guard let handle else { return }
        _ = pilyzer_usb_reset(handle)
        drain()
    }

    /// Sends a command and returns the payload of its answer.
    public func exchange(_ opcode: Opcode, payload: Data = Data(),
                         timeout: TimeInterval = 1.0) throws -> Data {
        guard handle != nil else { throw InstrumentError.notConnected }
        sequence &+= 1
        let expected = sequence

        var writer = ByteWriter()
        writer.append(Wire.requestMagic)
        writer.append(opcode.rawValue)
        writer.append(UInt8(0))
        writer.append(UInt8(0))
        writer.append(expected)
        writer.append(UInt16(0))
        writer.append(UInt32(payload.count))
        var frame = writer.data
        frame.append(payload)

        try write(frame, timeout: timeout)

        let header = try read(exactly: Wire.headerSize, timeout: timeout)
        var reader = ByteReader(header)
        guard reader.uint8() == Wire.responseMagic else {
            reset()
            throw InstrumentError.desynchronised
        }
        let answeredOpcode = reader.uint8()
        let status = reader.uint8()
        _ = reader.uint8()
        let answeredSequence = reader.uint16()
        _ = reader.uint16()
        let length = Int(reader.uint32())

        guard answeredOpcode == opcode.rawValue, answeredSequence == expected else {
            reset()
            throw InstrumentError.desynchronised
        }
        guard length <= Wire.maxPayload + 64 else {
            reset()
            throw InstrumentError.desynchronised
        }

        let body = length > 0 ? try read(exactly: length, timeout: timeout) : Data()
        guard let wireStatus = WireStatus(rawValue: status) else {
            throw InstrumentError.rejected(opcode, .internalError)
        }
        guard wireStatus == .ok else { throw InstrumentError.rejected(opcode, wireStatus) }
        return body
    }

    // MARK: - Pipes

    private func write(_ data: Data, timeout: TimeInterval) throws {
        guard let handle else { throw InstrumentError.notConnected }
        let milliseconds = UInt32(max(timeout, 0.01) * 1000)
        let result = data.withUnsafeBytes { bytes -> Int32 in
            pilyzer_usb_write(handle, bytes.baseAddress,
                              UInt32(data.count), milliseconds)
        }
        guard result == 0 else {
            reset()
            throw InstrumentError.transferFailed(result)
        }
    }

    private func read(exactly count: Int, timeout: TimeInterval) throws -> Data {
        guard let handle else { throw InstrumentError.notConnected }
        let milliseconds = UInt32(max(timeout, 0.01) * 1000)
        let deadline = Date().addingTimeInterval(max(timeout, 0.01) * 2 + 0.5)

        while pending.count < count {
            let short = count - pending.count
            let request = ((short + packetSize - 1) / packetSize) * packetSize
            var chunk = [UInt8](repeating: 0, count: request)
            var transferred: UInt32 = 0
            let result = chunk.withUnsafeMutableBytes { bytes -> Int32 in
                pilyzer_usb_read(handle, bytes.baseAddress,
                                 UInt32(request), milliseconds, &transferred)
            }
            guard result == 0 else {
                reset()
                throw InstrumentError.transferFailed(result)
            }
            if transferred == 0 && Date() > deadline {
                reset()
                throw InstrumentError.desynchronised
            }
            pending.append(contentsOf: chunk.prefix(Int(transferred)))
        }

        let head = pending.prefix(count)
        pending.removeFirst(count)
        return Data(head)
    }
}
