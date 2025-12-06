// ABOUTME: Tracks buffered audio chunks to implement backpressure
// ABOUTME: Prevents buffer overflow by tracking consumed vs. pending chunks

import Foundation

/// Manages audio buffer tracking for backpressure control
public actor BufferManager {
    private let capacity: Int
    private var bufferedChunks: [(endTimeMicros: Int64, byteCount: Int)] = []
    private var bufferedBytes: Int = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "Buffer capacity must be positive")
        self.capacity = capacity
    }

    /// Check if buffer has capacity for additional bytes
    public func hasCapacity(_ bytes: Int) -> Bool {
        return bufferedBytes + bytes <= capacity
    }

    /// Register a chunk added to the buffer
    public func register(endTimeMicros: Int64, byteCount: Int) {
        guard endTimeMicros >= 0, byteCount >= 0 else {
            return // Silently ignore invalid chunks
        }

        bufferedChunks.append((endTimeMicros, byteCount))
        bufferedBytes += byteCount
    }

    /// Remove chunks that have finished playing
    /// - Parameter nowMicros: Current playback time in microseconds
    public func pruneConsumed(nowMicros: Int64) {
        while let first = bufferedChunks.first, first.endTimeMicros <= nowMicros {
            bufferedBytes -= first.byteCount
            bufferedChunks.removeFirst()
        }
        // Safety check: ensure bufferedBytes never goes negative
        // This should never happen with correct usage, but protects against bugs
        bufferedBytes = max(bufferedBytes, 0)
    }

    /// Current buffer usage in bytes
    public var usage: Int {
        return bufferedBytes
    }

    /// Clear all buffered chunks
    /// Useful when restarting playback or handling stream discontinuities
    public func clear() {
        bufferedChunks.removeAll()
        bufferedBytes = 0
    }
}
