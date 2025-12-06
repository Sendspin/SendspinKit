// ABOUTME: Integration tests for buffer manager simulating real audio streaming scenarios
// ABOUTME: Tests backpressure, buffer overflow prevention, and playback coordination

import Foundation
@testable import SendspinKit
import Testing

@Suite("Buffer Manager Integration Tests")
struct BufferManagerIntegrationTests {
    @Test("Realistic audio streaming scenario")
    func audioStreamingScenario() async {
        // Simulate streaming 48kHz Opus at ~128kbps
        let bufferCapacity = 512_000 // 512KB buffer
        let manager = BufferManager(capacity: bufferCapacity)

        // Opus frame: ~25ms of audio at 48kHz, ~4KB compressed
        let frameSize = 4000
        let frameDuration: Int64 = 25000 // 25ms in microseconds

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

    @Test("Buffer overflow prevention")
    func overflowPrevention() async {
        let bufferCapacity = 10000
        let manager = BufferManager(capacity: bufferCapacity)

        // Try to buffer chunks totaling more than capacity
        let chunkSize = 3000
        var bufferedCount = 0

        for chunkIndex in 0 ..< 10 {
            if await manager.hasCapacity(chunkSize) {
                await manager.register(
                    endTimeMicros: Int64((chunkIndex + 1) * 10000),
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
        #expect(usage == 9000)
        #expect(usage <= bufferCapacity)
    }

    @Test("Continuous playback with rolling buffer")
    func continuousPlayback() async {
        let bufferCapacity = 50000
        let manager = BufferManager(capacity: bufferCapacity)

        let chunkSize = 5000
        let chunkDuration: Int64 = 25000 // 25ms

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

    @Test("Late arrival handling")
    func lateArrival() async {
        let manager = BufferManager(capacity: 100_000)

        // Buffer some chunks
        await manager.register(endTimeMicros: 100_000, byteCount: 5000)
        await manager.register(endTimeMicros: 200_000, byteCount: 5000)
        await manager.register(endTimeMicros: 300_000, byteCount: 5000)

        // Playback has progressed past first two chunks
        await manager.pruneConsumed(nowMicros: 250_000)

        let usage = await manager.usage
        #expect(usage == 5000) // Only last chunk remains

        // Late chunk arrives (should still be accepted by buffer manager)
        // Note: BufferManager uses FIFO order, doesn't sort by time
        // The late chunk goes to the end of the queue
        await manager.register(endTimeMicros: 150_000, byteCount: 3000)

        let newUsage = await manager.usage
        #expect(newUsage == 8000) // Both chunks in buffer

        // Prune again - only removes from front of FIFO queue
        // The late chunk is at the END, so it won't be pruned until earlier chunks are removed
        await manager.pruneConsumed(nowMicros: 250_000)

        let finalUsage = await manager.usage
        // FIFO behavior: can't prune late chunk because it's behind the future chunk in queue
        #expect(finalUsage == 8000) // Both chunks still in buffer due to FIFO
    }

    @Test("Buffer usage monitoring")
    func bufferUsageMonitoring() async {
        let capacity = 20000
        let manager = BufferManager(capacity: capacity)

        // Empty buffer
        var usage = await manager.usage
        #expect(usage == 0)

        // 25% full
        await manager.register(endTimeMicros: 100_000, byteCount: 5000)
        usage = await manager.usage
        #expect(usage == 5000)

        // 50% full
        await manager.register(endTimeMicros: 200_000, byteCount: 5000)
        usage = await manager.usage
        #expect(usage == 10000)

        // 75% full
        await manager.register(endTimeMicros: 300_000, byteCount: 5000)
        usage = await manager.usage
        #expect(usage == 15000)

        // Can still add one more to reach ~100%
        let hasCapacity = await manager.hasCapacity(5000)
        #expect(hasCapacity == true)

        await manager.register(endTimeMicros: 400_000, byteCount: 5000)
        usage = await manager.usage
        #expect(usage == 20000)

        // Now at capacity
        let hasCapacityNow = await manager.hasCapacity(1)
        #expect(hasCapacityNow == false)
    }

    @Test("Varying chunk sizes")
    func varyingChunkSizes() async {
        let manager = BufferManager(capacity: 100_000)

        // Different codecs produce different chunk sizes
        let opusChunk = 4000 // Opus frame
        let flacChunk = 12000 // FLAC frame (lossless, larger)
        let pcmChunk = 19200 // 100ms of 48kHz stereo PCM

        // Buffer mix of chunk sizes
        await manager.register(endTimeMicros: 25000, byteCount: opusChunk)
        await manager.register(endTimeMicros: 50000, byteCount: flacChunk)
        await manager.register(endTimeMicros: 150_000, byteCount: pcmChunk)

        let usage = await manager.usage
        #expect(usage == opusChunk + flacChunk + pcmChunk)

        // Prune first chunk
        await manager.pruneConsumed(nowMicros: 30000)

        let newUsage = await manager.usage
        #expect(newUsage == flacChunk + pcmChunk)
    }

    @Test("Zero-size chunks handled gracefully")
    func zeroSizeChunks() async {
        let manager = BufferManager(capacity: 10000)

        // Register some normal chunks
        await manager.register(endTimeMicros: 100_000, byteCount: 5000)

        // Register zero-size chunk (edge case, might happen with empty messages)
        await manager.register(endTimeMicros: 150_000, byteCount: 0)

        // Register another normal chunk
        await manager.register(endTimeMicros: 200_000, byteCount: 3000)

        let usage = await manager.usage
        #expect(usage == 8000) // Zero-size chunk doesn't affect usage

        // Prune including zero-size chunk
        await manager.pruneConsumed(nowMicros: 175_000)

        let newUsage = await manager.usage
        #expect(newUsage == 3000)
    }
}
