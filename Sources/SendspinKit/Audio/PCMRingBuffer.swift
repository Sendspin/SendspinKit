// ABOUTME: Lock-free-safe ring buffer for real-time audio thread PCM data
// ABOUTME: O(1) read/write with no allocations after init — suitable for AudioQueue callbacks

import Foundation

/// A fixed-capacity circular buffer optimized for the audio render callback.
///
/// Design constraints:
/// - No allocations after init (real-time safe)
/// - O(1) read and write (no memmove like Data.removeFirst)
/// - Single contiguous backing store with read/write cursors
/// - Caller is responsible for external synchronization (e.g. OSAllocatedUnfairLock)
///
/// The buffer uses free-running `readPos` and `writePos` counters that are never
/// wrapped — they grow monotonically. Physical offsets are computed via bitmask
/// (`pos & mask`) since capacity is always a power of 2. This cleanly distinguishes
/// empty (`readPos == writePos`) from full (`writePos - readPos == capacity`) without
/// wasting a slot.
///
/// **Copy safety:** This struct owns a heap allocation via `UnsafeMutableRawBufferPointer`.
/// Copying it would alias the storage, leading to double-free or use-after-free.
/// `~Copyable` cannot be used here because `OSAllocatedUnfairLock<State>` requires
/// `State: Copyable`. In practice, copies never occur: the buffer lives inside
/// `LockedState`, accessed exclusively via `withLock` (`inout`, no copy).
/// If this struct is ever used outside that pattern, convert it to a class.
struct PCMRingBuffer: @unchecked Sendable {
    private var storage: UnsafeMutableRawBufferPointer
    private var readPos: Int = 0
    private var writePos: Int = 0
    private let mask: Int // capacity - 1 (capacity must be power of 2)
    let capacity: Int

    /// Create a ring buffer with the given capacity (rounded up to the next power of 2).
    ///
    /// - Parameter requestedCapacity: Must be positive. Rounded up to the next power of 2.
    init(capacity requestedCapacity: Int) {
        precondition(requestedCapacity > 0, "Ring buffer capacity must be positive")

        // Round up to next power of 2 for fast modulo via bitmask.
        // Clamped to avoid shift overflow on extreme values.
        let clamped = min(requestedCapacity, 1 << (Int.bitWidth - 2))
        var cap = 1
        while cap < clamped {
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
    ///
    /// **Not real-time safe** — `Data` is reference-counted, so this may trigger
    /// ARC retain/release. Use ``write(from:count:)`` on the audio render thread.
    /// This convenience is intended for the actor-isolated `playPCM` path.
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
    /// Does not zero memory — stale data beyond `writePos` is never accessible
    /// through the read/write API, and zeroing 512KB+ on the audio thread would
    /// violate the real-time contract.
    mutating func reset() {
        readPos = 0
        writePos = 0
    }

    /// Deallocate backing storage. Must be called exactly once before the buffer
    /// goes out of scope. Called via `LockedState.deallocateResources()` in
    /// `AudioPlayer.deinit`.
    mutating func deallocate() {
        storage.deallocate()
        // Nil-out so a second call is a no-op (deallocating nil is safe).
        storage = UnsafeMutableRawBufferPointer(start: nil, count: 0)
    }
}
