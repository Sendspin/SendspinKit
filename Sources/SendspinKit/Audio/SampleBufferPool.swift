// ABOUTME: Buffer pool for reusing audio sample buffers
// ABOUTME: Eliminates allocations in the audio hot path

import Foundation

/// Pool of reusable sample buffers to avoid allocation in the audio path
public final class SampleBufferPool: Sendable {
    private let pool: LockedQueue<[Sample]>
    /// The capacity each buffer is pre-allocated with
    public let bufferCapacity: Int

    /// Create a new buffer pool.
    /// - Parameters:
    ///   - poolSize: Number of buffers to pre-allocate
    ///   - bufferCapacity: Capacity of each buffer in samples
    public init(poolSize: Int, bufferCapacity: Int) {
        self.bufferCapacity = bufferCapacity
        self.pool = LockedQueue()

        for _ in 0..<poolSize {
            var buf = [Sample]()
            buf.reserveCapacity(bufferCapacity)
            pool.enqueue(buf)
        }
    }

    /// Get a buffer from the pool, or allocate a new one if empty
    public func get() -> [Sample] {
        if let buf = pool.dequeue() {
            return buf
        }
        var buf = [Sample]()
        buf.reserveCapacity(bufferCapacity)
        return buf
    }

    /// Return a buffer to the pool (cleared)
    public func put(_ buf: inout [Sample]) {
        buf.removeAll(keepingCapacity: true)
        pool.enqueue(buf)
    }
}

/// Simple thread-safe queue using a lock
private final class LockedQueue<T>: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var items: [T] = []

    func enqueue(_ item: T) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    func dequeue() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return items.isEmpty ? nil : items.removeFirst()
    }
}
