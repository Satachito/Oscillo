import Darwin
import Foundation
import Testing
@testable import PiLyzerCore

/// An ArLyzer on the far side of a pseudo-terminal: the same frames a Nano R4
/// sends, written back in uneven pieces the way a tty delivers them.
private final class FakeArLyzer {
    let path: String
    private var master: Int32 = -1
    private var slave: Int32 = -1
    private let answersFrames: Bool
    private let finished = DispatchSemaphore(value: 0)

    init(answersFrames: Bool = true) throws {
        self.answersFrames = answersFrames
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw POSIXError(.ENOTTY) }
        path = String(cString: ttyname(slave))
        var raw = termios()
        tcgetattr(slave, &raw); cfmakeraw(&raw); tcsetattr(slave, TCSANOW, &raw)
        let master = self.master, finished = self.finished
        Thread.detachNewThread { [answersFrames] in
            FakeArLyzer.serve(master, answersFrames: answersFrames)
            finished.signal()
        }
    }

    // Closing the master while the other thread is still reading it blocks in
    // the kernel. Closing the last slave first ends that read, so it goes in
    // this order.
    deinit {
        close(slave)
        finished.wait()
        close(master)
    }

    private static func serve(_ fd: Int32, answersFrames: Bool) {
        var input = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 256)
        while true {
            let got = read(fd, &chunk, chunk.count)
            guard got > 0 else { return }
            input += chunk.prefix(got)
            while input.count >= 12 {
                let length = Int(input[8]) | Int(input[9]) << 8 | Int(input[10]) << 16 | Int(input[11]) << 24
                guard input.count >= 12 + length else { break }
                let opcode = input[1], sequence = [input[4], input[5]]
                input.removeFirst(12 + length)
                guard answersFrames else {
                    _ = "Hello from a sketch\r\n".utf8CString.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count - 1) }
                    continue
                }
                var payload = [UInt8]()
                switch opcode {
                case 0x01:
                    payload = [0x50, 0x4C, 0x59, 0x5A, 1, 0, 1, 0, 4, 0, 0, 0] + Array("ArLyzer Nano R4".utf8)
                    payload += [UInt8](repeating: 0, count: 32 - payload.count)
                case 0x02:
                    var writer = ByteWriter()
                    writer.append(UInt8(8)); writer.append(UInt8(14)); writer.append(UInt8(0)); writer.append(UInt8(1))
                    for value in [48_000_000, 96, 1024, 1023, 0, 0, 0, 5_000_000, 16, 0, 0] as [UInt32] { writer.append(value) }
                    payload = [UInt8](writer.data)
                case 0x15:
                    for channel in 0..<8 { let code = UInt16(channel * 8000); payload += [UInt8(code & 0xFF), UInt8(code >> 8)] }
                default:
                    break
                }
                var frame: [UInt8] = [0x5A, opcode, 0, 0] + sequence + [0, 0]
                frame += [UInt8(payload.count & 0xFF), UInt8(payload.count >> 8 & 0xFF), 0, 0] + payload
                // Uneven pieces, so the transport has to put frames back together.
                var offset = 0
                while offset < frame.count {
                    let piece = min(5, frame.count - offset)
                    _ = frame[offset..<offset + piece].withUnsafeBufferPointer { write(fd, $0.baseAddress, piece) }
                    offset += piece
                    usleep(200)
                }
            }
        }
    }
}

@Suite("Serial transport")
struct SerialTransportTests {
    @Test("An ArLyzer over a serial port identifies itself and reads eight channels")
    func eightChannelsOverSerial() throws {
        let device = try FakeArLyzer()
        let instrument = try USBInstrument(serialPath: device.path)
        defer { instrument.close() }
        #expect(instrument.identity.boardID == 4)
        #expect(instrument.identity.name == "ArLyzer Nano R4")
        #expect(instrument.capabilities.analogChannels == 8)
        #expect(instrument.capabilities.analogBits == 14)
        #expect(try instrument.sampleAnalog(averages: 4) == (0..<8).map { UInt16($0 * 8000) })
    }

    @Test("A sketch that is not an instrument is refused, not waited on")
    func otherSketchIsRefused() throws {
        let device = try FakeArLyzer(answersFrames: false)
        #expect(throws: InstrumentError.notPiLyzer) { try USBInstrument(serialPath: device.path) }
    }
}
