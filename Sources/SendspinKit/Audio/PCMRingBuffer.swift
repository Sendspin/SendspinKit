// ABOUTME: Lock-free-safe ring buffer for real-time audio thread PCM data
// ABOUTME: O(1) read/write with no allocations after init — suitable for AudioQueue callbacks

import Foundation

/// A fixed-capacity circular buffer optimized for the audio render callback.
///
/// Design constraints:
/// - No allocations after init (real-time safe)
/// - O(1) read and write (no memmove like Data.removeFirst)
/// - Single contiguous backing store with read/write cursors
/// - Caller is responsible for external synchronization (e.g. NSLock)
///
/// The buffer uses a virtual-capacity trick: `readPos` and `writePos` are free-running
/// indices modulo `2 * capacity`. This cleanly distinguishes empty (read == write) from
/// full (write - read == capacity) without wasting a slot.
struct PCMRingBuffer {
    private var storage: UnsafeMutableRawBufferPointer
    private var readPos: Int = 0
    private var writePos: Int = 0
    private let mask: Int // capacity - 1 (capacity must be power of 2)
    let capacity: Int

    /// Create a ring buffer with the given capacity (rounded up to the next power of 2).
    init(capacity requestedCapacity: Int) {
        // Round up to next power of 2 for fast modulo via bitmask
        var cap = 1
        while cap < requestedCapacity {
            cap <<= 1
        }
        capacity = cap
        mask = cap - 1
        storage = .allocate(byteCount: cap, alignment: 16)
        storage.initializeMemory(as: UInt8.self, repeating: 0)
    }

    /// Number of bytes available to read.
    var availableToRead: Int {
        writePos - readPos
    }

    /// Number of bytes of free space for writing.
    var availableToWrite: Int {
        capacity - availableToRead
    }

    /// Write bytes into the buffer. Returns the number of bytes actually written
    /// (may be less than `count` if the buffer is nearly full).
    @discardableResult
    mutating func write(from source: UnsafeRawPointer, count: Int) -> Int {
        let toWrite = min(count, availableToWrite)
        guard toWrite > 0 else { return 0 }

        let writeOffset = writePos & mask
        let firstChunk = min(toWrite, capacity - writeOffset)
        let secondChunk = toWrite - firstChunk

        memcpy(storage.baseAddress! + writeOffset, source, firstChunk)
        if secondChunk > 0 {
            memcpy(storage.baseAddress!, source + firstChunk, secondChunk)
        }

        writePos += toWrite
        return toWrite
    }

    /// Write from Data. Returns number of bytes written.
    @discardableResult
    mutating func write(_ data: Data) -> Int {
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return 0 }
            return write(from: base, count: data.count)
        }
    }

    /// Read bytes from the buffer into a destination pointer.
    /// Returns the number of bytes actually read.
    @discardableResult
    mutating func read(into dest: UnsafeMutableRawPointer, count: Int) -> Int {
        let toRead = min(count, availableToRead)
        guard toRead > 0 else { return 0 }

        let readOffset = readPos & mask
        let firstChunk = min(toRead, capacity - readOffset)
        let secondChunk = toRead - firstChunk

        memcpy(dest, storage.baseAddress! + readOffset, firstChunk)
        if secondChunk > 0 {
            memcpy(dest + firstChunk, storage.baseAddress!, secondChunk)
        }

        readPos += toRead
        return toRead
    }

    /// Skip (discard) bytes without copying them anywhere.
    @discardableResult
    mutating func skip(_ count: Int) -> Int {
        let toSkip = min(count, availableToRead)
        readPos += toSkip
        return toSkip
    }

    /// Reset read and write positions (effectively clearing the buffer).
    mutating func reset() {
        readPos = 0
        writePos = 0
    }

    /// Deallocate backing storage. Must be called before the buffer goes out of scope.
    mutating func deallocate() {
        storage.deallocate()
    }
}
