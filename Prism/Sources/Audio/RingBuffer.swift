import Foundation
import Synchronization

/// Single-producer, single-consumer ring of planar float audio. One thread writes, one reads;
/// neither ever blocks or allocates, so the audio thread can use either end.
nonisolated final class RingBuffer: @unchecked Sendable {
    let channels: Int
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    /// Total frames ever written / read; their difference is what's buffered.
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)

    init(channels: Int, capacity: Int) {
        self.channels = channels
        self.capacity = capacity
        storage = .allocate(capacity: channels * capacity)
        storage.initialize(repeating: 0, count: channels * capacity)
        // The audio thread reads this; if the system pages it out under memory pressure, the
        // callback waits for it and the output glitches. Keep it resident.
        locked = mlock(storage, channels * capacity * MemoryLayout<Float>.size) == 0
    }

    private var locked = false

    deinit {
        if locked { munlock(storage, channels * capacity * MemoryLayout<Float>.size) }
        storage.deallocate()
    }

    var available: Int { written.load(ordering: .acquiring) - read.load(ordering: .acquiring) }
    var space: Int { capacity - available }
    var writePosition: Int { written.load(ordering: .acquiring) }

    // MARK: Producer

    /// Writes `frames` of interleaved audio with `stride` samples per frame, taking the first
    /// `channels` of each frame (or `nil` for silence). Drops what doesn't fit.
    func write(interleaved source: UnsafePointer<Float>?, stride: Int, frames: Int) {
        let start = written.load(ordering: .relaxed)
        let count = min(frames, capacity - (start - read.load(ordering: .acquiring)))
        guard count > 0 else { return }
        for c in 0..<channels {
            let channel = storage + c * capacity
            for i in 0..<count {
                channel[(start + i) % capacity] = source.map { $0[i * stride + Swift.min(c, stride - 1)] } ?? 0
            }
        }
        written.store(start + count, ordering: .releasing)
    }

    /// Writes planar blocks, one array per channel.
    func write(_ blocks: [[Float]]) {
        let frames = blocks.first?.count ?? 0
        let start = written.load(ordering: .relaxed)
        let count = min(frames, capacity - (start - read.load(ordering: .acquiring)))
        guard count > 0 else { return }
        for c in 0..<channels {
            let channel = storage + c * capacity
            blocks[c].withUnsafeBufferPointer { block in
                let first = min(count, capacity - start % capacity)
                (channel + start % capacity).update(from: block.baseAddress!, count: first)
                if first < count { channel.update(from: block.baseAddress! + first, count: count - first) }
            }
        }
        written.store(start + count, ordering: .releasing)
    }

    // MARK: Consumer

    /// Copies `frames` of one channel, starting `offset` frames into what's buffered, without consuming.
    func peek(channel c: Int, into destination: UnsafeMutablePointer<Float>, frames: Int, offset: Int = 0) {
        let start = read.load(ordering: .relaxed) + offset
        let channel = storage + c * capacity
        let first = min(frames, capacity - start % capacity)
        destination.update(from: channel + start % capacity, count: first)
        if first < frames { (destination + first).update(from: channel, count: frames - first) }
    }

    func consume(_ frames: Int) {
        read.store(read.load(ordering: .relaxed) + min(frames, available), ordering: .releasing)
    }

    /// Reads everything buffered into planar arrays.
    func readAll() -> [[Float]] {
        let count = available
        guard count > 0 else { return [] }
        let blocks = (0..<channels).map { c in
            [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
                peek(channel: c, into: buffer.baseAddress!, frames: count)
                initialized = count
            }
        }
        consume(count)
        return blocks
    }

    /// Discards everything up to absolute position `position` (from `writePosition`).
    func discard(upTo position: Int) {
        let current = read.load(ordering: .relaxed)
        if position > current { read.store(min(position, written.load(ordering: .acquiring)), ordering: .releasing) }
    }
}
