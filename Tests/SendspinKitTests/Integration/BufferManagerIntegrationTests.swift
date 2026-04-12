// ABOUTME: Integration tests for buffer manager simulating real audio streaming scenarios
// ABOUTME: Tests backpressure, buffer overflow prevention, and playback coordination

import Foundation
@testable import SendspinKit
import Testing

struct BufferManagerIntegrationTests {
    @Test
    func `Realistic audio streaming scenario`() async {
        // Simulate streaming 48kHz Opus at ~128kbps
        let bufferCapacity = 512_000 // 512KB buffer
        let manager = BufferManager(capacity: bufferCapacity)

        // Opus frame: ~25ms of audio at 48kHz, ~4KB compressed
        let frameSize = 4_000
        let frameDuration: Int64 = 25_000 // 25ms in microseconds

        var currentTime: Int64 = 0
        var framesBuffered = 0

        // Fill buffer with frames
        while await manager.hasCapacity(frameSize) {
            let endTime = currentTime + frameDuration
            await manager.register(endTimeMicros: endTime, byteCount: frameSize)
            currentTime = endTime
            framesBuffered += 1
        }

        // Should have buffered enough frames to fill the buffer
        let expectedFrames = bufferCapacity / frameSize
        #expect(framesBuffered >= expectedFrames - 1) // Within 1 frame of capacity

        // No more capacity
        let hasCapacity = await manager.hasCapacity(frameSize)
        #expect(hasCapacity == false)

        // Simulate playback: after 100ms, prune consumed chunks
        let playbackTime = currentTime - frameDuration * 100 // Played 100 frames
        await manager.pruneConsumed(nowMicros: playbackTime)

        // Should have capacity again
        let hasCapacityAfterPrune = await manager.hasCapacity(frameSize)
        #expect(hasCapacityAfterPrune == true)
    }

    @Test
    func `Buffer overflow prevention`() async {
        let bufferCapacity = 10_000
        let manager = BufferManager(capacity: bufferCapacity)

        // Try to buffer chunks totaling more than capacity
        let chunkSize = 3_000
        var bufferedCount = 0

        for chunkIndex in 0 ..< 10 {
            if await manager.hasCapacity(chunkSize) {
                await manager.register(
                    endTimeMicros: Int64((chunkIndex + 1) * 10_000),
                    byteCount: chunkSize
                )
                bufferedCount += 1
            } else {
                break
            }
        }

        // Should stop before overflow (3 chunks = 9KB, 4th would exceed)
        #expect(bufferedCount == 3)

        // Verify usage is at capacity
        let usage = await manager.usage
        #expect(usage == 9_000)
        #expect(usage <= bufferCapacity)
    }

    @Test
    func `Continuous playback with rolling buffer`() async {
        let bufferCapacity = 50_000
        let manager = BufferManager(capacity: bufferCapacity)

        let chunkSize = 5_000
        let chunkDuration: Int64 = 25_000 // 25ms

        var currentTime: Int64 = 0
        var playbackTime: Int64 = 0
        var totalChunksProcessed = 0

        // Simulate 1 second of streaming with continuous playback
        let targetDuration: Int64 = 1_000_000 // 1 second

        while currentTime < targetDuration {
            // Buffer new chunks if there's capacity
            while await manager.hasCapacity(chunkSize), currentTime < targetDuration {
                let endTime = currentTime + chunkDuration
                await manager.register(endTimeMicros: endTime, byteCount: chunkSize)
                currentTime = endTime
                totalChunksProcessed += 1
            }

            // Simulate playback catching up (advance by 100ms)
            playbackTime += 100_000
            await manager.pruneConsumed(nowMicros: playbackTime)
        }

        // Should have processed ~40 chunks (1 second / 25ms)
        #expect(totalChunksProcessed >= 35 && totalChunksProcessed <= 45)

        // Final cleanup
        await manager.pruneConsumed(nowMicros: currentTime)
        let finalUsage = await manager.usage
        #expect(finalUsage == 0)
    }

    @Test
    func `Late arrival handling`() async {
        let manager = BufferManager(capacity: 100_000)

        // Buffer some chunks
        await manager.register(endTimeMicros: 100_000, byteCount: 5_000)
        await manager.register(endTimeMicros: 200_000, byteCount: 5_000)
        await manager.register(endTimeMicros: 300_000, byteCount: 5_000)

        // Playback has progressed past first two chunks
        await manager.pruneConsumed(nowMicros: 250_000)

        let usage = await manager.usage
        #expect(usage == 5_000) // Only last chunk remains

        // Late chunk arrives (should still be accepted by buffer manager)
        // Note: BufferManager uses FIFO order, doesn't sort by time
        // The late chunk goes to the end of the queue
        await manager.register(endTimeMicros: 150_000, byteCount: 3_000)

        let newUsage = await manager.usage
        #expect(newUsage == 8_000) // Both chunks in buffer

        // Prune again - only removes from front of FIFO queue
        // The late chunk is at the END, so it won't be pruned until earlier chunks are removed
        await manager.pruneConsumed(nowMicros: 250_000)

        let finalUsage = await manager.usage
        // FIFO behavior: can't prune late chunk because it's behind the future chunk in queue
        #expect(finalUsage == 8_000) // Both chunks still in buffer due to FIFO
    }

    @Test
    func `Buffer usage monitoring`() async {
        let capacity = 20_000
        let manager = BufferManager(capacity: capacity)

        // Empty buffer
        var usage = await manager.usage
        #expect(usage == 0)

        // 25% full
        await manager.register(endTimeMicros: 100_000, byteCount: 5_000)
        usage = await manager.usage
        #expect(usage == 5_000)

        // 50% full
        await manager.register(endTimeMicros: 200_000, byteCount: 5_000)
        usage = await manager.usage
        #expect(usage == 10_000)

        // 75% full
        await manager.register(endTimeMicros: 300_000, byteCount: 5_000)
        usage = await manager.usage
        #expect(usage == 15_000)

        // Can still add one more to reach ~100%
        let hasCapacity = await manager.hasCapacity(5_000)
        #expect(hasCapacity == true)

        await manager.register(endTimeMicros: 400_000, byteCount: 5_000)
        usage = await manager.usage
        #expect(usage == 20_000)

        // Now at capacity
        let hasCapacityNow = await manager.hasCapacity(1)
        #expect(hasCapacityNow == false)
    }

    @Test
    func `Varying chunk sizes`() async {
        let manager = BufferManager(capacity: 100_000)

        // Different codecs produce different chunk sizes
        let opusChunk = 4_000 // Opus frame
        let flacChunk = 12_000 // FLAC frame (lossless, larger)
        let pcmChunk = 19_200 // 100ms of 48kHz stereo PCM

        // Buffer mix of chunk sizes
        await manager.register(endTimeMicros: 25_000, byteCount: opusChunk)
        await manager.register(endTimeMicros: 50_000, byteCount: flacChunk)
        await manager.register(endTimeMicros: 150_000, byteCount: pcmChunk)

        let usage = await manager.usage
        #expect(usage == opusChunk + flacChunk + pcmChunk)

        // Prune first chunk
        await manager.pruneConsumed(nowMicros: 30_000)

        let newUsage = await manager.usage
        #expect(newUsage == flacChunk + pcmChunk)
    }

    @Test
    func `Zero-size chunks handled gracefully`() async {
        let manager = BufferManager(capacity: 10_000)

        // Register some normal chunks
        await manager.register(endTimeMicros: 100_000, byteCount: 5_000)

        // Register zero-size chunk (edge case, might happen with empty messages)
        await manager.register(endTimeMicros: 150_000, byteCount: 0)

        // Register another normal chunk
        await manager.register(endTimeMicros: 200_000, byteCount: 3_000)

        let usage = await manager.usage
        #expect(usage == 8_000) // Zero-size chunk doesn't affect usage

        // Prune including zero-size chunk
        await manager.pruneConsumed(nowMicros: 175_000)

        let newUsage = await manager.usage
        #expect(newUsage == 3_000)
    }
}
