import Foundation

/// A single-producer / single-consumer ring buffer of `Float` samples.
///
/// One audio callback (the `AVAudioSinkNode`) produces; another (the
/// `AVAudioSourceNode`) consumes. Both run on real-time threads, so the buffer
/// is **allocation-free and lock-free** after `init`.
///
/// > Production note: for a shipping build, prefer a battle-tested lock-free
/// > ring buffer such as **TPCircularBuffer** (MIT) or `swift-atomics`'
/// > `ManagedAtomic` indices for fully specified memory ordering. This pure-
/// > Swift version relies on aligned word-sized index loads/stores being atomic
/// > on arm64/x86_64, which is true in practice but not guaranteed by the
/// > language. It is intentionally simple so the data flow is easy to read.
final class RingBuffer {
    private let storage: UnsafeMutableBufferPointer<Float>
    private let capacity: Int

    /// Next index to write (owned by the producer).
    private var writeIndex = 0
    /// Next index to read (owned by the consumer).
    private var readIndex = 0

    /// - Parameter capacity: number of samples. Rounded up to a power of two so
    ///   wrap-around is a cheap mask.
    init(capacity requested: Int) {
        var cap = 1
        while cap < max(2, requested) { cap <<= 1 }
        self.capacity = cap
        self.storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: cap)
        self.storage.initialize(repeating: 0)
    }

    deinit {
        storage.deallocate()
    }

    private var mask: Int { capacity - 1 }

    /// Samples available to read right now.
    var availableToRead: Int {
        (writeIndex &- readIndex) & mask
    }

    /// Free space available to write right now.
    var availableToWrite: Int {
        capacity - 1 - availableToRead
    }

    /// Producer side. Writes as many of `frames` as fit; returns the count
    /// actually written (so the caller can detect overrun).
    @discardableResult
    func write(_ frames: UnsafeBufferPointer<Float>) -> Int {
        let count = min(frames.count, availableToWrite)
        var w = writeIndex
        for i in 0..<count {
            storage[w & mask] = frames[i]
            w &+= 1
        }
        writeIndex = w   // publish after the data is in place
        return count
    }

    /// Consumer side. Fills up to `dest.count` samples; any shortfall is filled
    /// with silence (so a starved output emits a soft gap, never garbage).
    /// Returns the number of *real* samples read.
    @discardableResult
    func read(into dest: UnsafeMutableBufferPointer<Float>) -> Int {
        let count = min(dest.count, availableToRead)
        var r = readIndex
        for i in 0..<count {
            dest[i] = storage[r & mask]
            r &+= 1
        }
        readIndex = r   // publish after the data is copied out
        if count < dest.count {
            for i in count..<dest.count { dest[i] = 0 }
        }
        return count
    }

    /// Drop everything (e.g. on mode change) to avoid stale audio.
    func reset() {
        readIndex = writeIndex
    }
}
