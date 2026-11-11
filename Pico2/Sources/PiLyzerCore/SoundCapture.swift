import Foundation

/// The last stretch of every channel of a sound input, as the audio thread
/// delivered it, and the arithmetic a sweep is taken out of it with.
///
/// Frames are counted from the start, so a position stays the same frame
/// however far the ring has wrapped since. The audio thread writes and the
/// acquisition reads from another thread, so both go through the lock.
final class SoundBuffer: @unchecked Sendable {
    let channels: Int
    let capacity: Int
    private var data: [[Float]]
    private var count = 0
    private let lock = NSLock()

    init(channels: Int, capacity: Int = 1 << 20) {
        self.channels = channels
        self.capacity = capacity
        data = Array(repeating: [Float](repeating: 0, count: capacity), count: channels)
    }

    /// One block per channel, all the same length. A channel left out repeats
    /// the first.
    func push(_ blocks: [UnsafeBufferPointer<Float>]) {
        guard let length = blocks.first?.count, length > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        for channel in 0..<channels {
            let block = blocks.indices.contains(channel) ? blocks[channel] : blocks[0]
            for index in 0..<length { data[channel][(count + index) % capacity] = block[index] }
        }
        count += length
    }

    func push(_ blocks: [[Float]]) {
        var pointers: [UnsafeBufferPointer<Float>] = []
        func next(_ index: Int) {
            guard index < blocks.count else { push(pointers); return }
            blocks[index].withUnsafeBufferPointer { pointer in
                pointers.append(pointer)
                next(index + 1)
            }
        }
        next(0)
    }

    /// Reads under the lock, so the ring cannot move while a sweep is taken.
    func read<T>(_ body: (Reader) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(Reader(buffer: self))
    }

    var written: Int { read { $0.written } }

    struct Reader {
        fileprivate let buffer: SoundBuffer
        var written: Int { buffer.count }
        var oldest: Int { max(0, buffer.count - buffer.capacity) }
        func at(_ channel: Int, _ frame: Int) -> Float { buffer.data[channel][frame % buffer.capacity] }
        /// `decimation` frames from `frame` on, averaged: the anti-alias
        /// filter for a slow sweep, as a board averages the conversions
        /// underneath each point.
        func mean(_ channel: Int, _ frame: Int, _ decimation: Int) -> Double {
            var sum = 0.0
            for offset in 0..<decimation { sum += Double(at(channel, frame + offset)) }
            return sum / Double(decimation)
        }
    }
}

/// A sound card's scale in converter codes: −1…+1 across 0…65535, which the
/// range `SoundInstrument.range` turns back into −1…+1 for the screen.
enum SoundScale {
    static let fullScale = 65535.0
    static func code(_ value: Double) -> UInt16 {
        UInt16(min(max(((value + 1) / 2 * fullScale).rounded(), 0), fullScale))
    }
}

/// Looks for the trigger through whatever has arrived since the last look,
/// in converter codes as a board compares them. It carries its place, so a
/// long wait in Normal does not read the same audio over and over.
struct SoundTrigger {
    let channel: Int
    let level: Int
    let hysteresis: Int
    let rising: Bool
    let decimation: Int
    let before: Int
    let after: Int
    var next: Int
    var armed = false

    /// The newest edge since the last look with a whole record around it,
    /// as the frame it is on, or nil.
    mutating func scan(_ reader: SoundBuffer.Reader) -> Int? {
        var edge: Int?
        var frame = max(next, reader.oldest + before * decimation)
        while frame + after * decimation <= reader.written {
            let value = Int(SoundScale.code(reader.mean(channel, frame, decimation)))
            if !armed {
                armed = rising ? value < level - hysteresis : value > level + hysteresis
            } else if rising ? value >= level : value <= level {
                edge = frame
                armed = false
            }
            frame += decimation
        }
        next = frame
        return edge
    }
}

/// A finished record, interleaved as a board sends one.
func soundRecord(_ reader: SoundBuffer.Reader, channels: [Int], start: Int,
                 count: Int, decimation: Int) -> [UInt16] {
    var record = [UInt16](repeating: 0, count: count * channels.count)
    for index in 0..<count {
        for (slot, channel) in channels.enumerated() {
            record[index * channels.count + slot] = SoundScale.code(
                reader.mean(channel, start + index * decimation, decimation))
        }
    }
    return record
}

/// Each input's RMS over the last `frames`, in converter codes. A sound card
/// passes no direct current, so the mean a board's meter shows would read
/// zero here whatever was playing.
func soundLevels(_ reader: SoundBuffer.Reader, channels: Int, frames: Int) -> [UInt16] {
    // Straight after connecting nothing has arrived yet, and there is no
    // frame before the first to read.
    let span = min(frames, reader.written - reader.oldest)
    guard span > 0 else { return Array(repeating: SoundScale.code(0), count: channels) }
    return (0..<channels).map { channel in
        var sum = 0.0
        for frame in (reader.written - span)..<reader.written {
            let value = Double(reader.at(channel, frame))
            sum += value * value
        }
        return SoundScale.code((sum / Double(span)).squareRoot())
    }
}
