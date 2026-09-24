import CPiLyzerUSB
import Foundation

/// A USB serial port that may have an ArLyzer behind it.
public struct SerialPortInfo: Equatable, Hashable, Sendable, Identifiable {
    public var path: String
    public var productID: UInt16
    public var serial: String
    public var product: String

    public var id: String { path }
    public var label: String {
        let name = product.isEmpty ? "ArLyzer" : product
        return serial.isEmpty ? "\(name) (serial)" : "\(name) (serial) · \(serial.suffix(6))"
    }
}

/// The same frames as `USBTransport`, over a USB CDC serial port — for boards
/// whose USB stack offers nothing else, such as an Arduino Nano R4.
///
/// A tty has no packets to round reads up to, so the only state kept between
/// reads is whatever arrived beyond the frame being read.
public final class SerialTransport: FrameTransport {
    private var descriptor: Int32 = -1
    private var pending = Data()
    private var sequence: UInt16 = 0

    /// Serial ports belonging to a board that could be an ArLyzer. Any sketch
    /// can run on the same board, so being listed says only that; `identify`
    /// is what says it is an instrument.
    public static func attachedPorts() -> [SerialPortInfo] {
        var buffer = [pilyzer_serial_info](repeating: pilyzer_serial_info(), count: 16)
        let products = Wire.arLyzerProductIDs
        let count = products.withUnsafeBufferPointer { ids in
            buffer.withUnsafeMutableBufferPointer { pointer in
                pilyzer_serial_enumerate(Wire.arduinoVendorID, ids.baseAddress, Int32(ids.count),
                                         pointer.baseAddress, 16)
            }
        }
        guard count > 0 else { return [] }
        return buffer.prefix(Int(count)).map { info in
            var info = info
            func string<T>(_ field: inout T) -> String {
                withUnsafeBytes(of: &field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            }
            return SerialPortInfo(path: string(&info.path), productID: info.product_id,
                                  serial: string(&info.serial), product: string(&info.product))
        }
    }

    public init(path: String) throws {
        var error: Int32 = 0
        let opened = pilyzer_serial_open(path, &error)
        guard opened >= 0 else {
            if error == EBUSY { throw InstrumentError.inUse }
            throw InstrumentError.portFailed(error)
        }
        descriptor = opened
    }

    deinit { close() }

    public func close() {
        guard descriptor >= 0 else { return }
        pilyzer_serial_close(descriptor)
        descriptor = -1
    }

    public var isOpen: Bool { descriptor >= 0 }

    /// Drops everything in flight, so the next exchange starts on a frame
    /// boundary however the last one ended.
    private func resynchronise() {
        pending.removeAll(keepingCapacity: true)
        guard descriptor >= 0 else { return }
        pilyzer_serial_flush(descriptor)
    }

    public func exchange(_ opcode: Opcode, payload: Data, timeout: TimeInterval) throws -> Data {
        guard descriptor >= 0 else { throw InstrumentError.notConnected }
        sequence &+= 1
        let expected = sequence

        var frame = Wire.requestHeader(opcode: opcode, sequence: expected, payloadLength: payload.count)
        frame.append(payload)
        try write(frame, timeout: timeout)

        let header = try read(exactly: Wire.headerSize, timeout: timeout)
        guard let (status, length) = Wire.responseHeader(header, opcode: opcode, sequence: expected) else {
            resynchronise()
            throw InstrumentError.desynchronised
        }
        let body = length > 0 ? try read(exactly: length, timeout: timeout) : Data()
        guard let wireStatus = WireStatus(rawValue: status) else {
            throw InstrumentError.rejected(opcode, .internalError)
        }
        guard wireStatus == .ok else { throw InstrumentError.rejected(opcode, wireStatus) }
        return body
    }

    private func write(_ data: Data, timeout: TimeInterval) throws {
        let milliseconds = UInt32(max(timeout, 0.01) * 1000)
        let result = data.withUnsafeBytes { bytes in
            pilyzer_serial_write(descriptor, bytes.baseAddress, UInt32(data.count), milliseconds)
        }
        guard result == 0 else {
            resynchronise()
            if result == ETIMEDOUT { throw InstrumentError.desynchronised }
            throw InstrumentError.portFailed(result)
        }
    }

    private func read(exactly count: Int, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(max(timeout, 0.01))
        var chunk = [UInt8](repeating: 0, count: 4096)
        while pending.count < count {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else {
                resynchronise()
                throw InstrumentError.desynchronised
            }
            var transferred: UInt32 = 0
            let result = chunk.withUnsafeMutableBytes { bytes in
                pilyzer_serial_read(descriptor, bytes.baseAddress, UInt32(bytes.count),
                                    UInt32(left * 1000) + 1, &transferred)
            }
            guard result == 0 else {
                resynchronise()
                throw InstrumentError.portFailed(result)
            }
            pending.append(contentsOf: chunk.prefix(Int(transferred)))
        }
        let head = pending.prefix(count)
        pending.removeFirst(count)
        return Data(head)
    }
}
