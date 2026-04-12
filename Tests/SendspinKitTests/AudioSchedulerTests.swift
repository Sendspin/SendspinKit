@testable import SendspinKit
import XCTest

final class AudioSchedulerTests: XCTestCase {
    func testSchedulerAcceptsChunk() async {
        // Mock clock sync that returns zero offset
        let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        let pcmData = Data(repeating: 0x00, count: 1_024)
        let serverTimestamp: Int64 = 1_000_000 // 1 second in microseconds

        // Should not throw
        await scheduler.schedule(pcm: pcmData, serverTimestamp: serverTimestamp)

        let stats = await scheduler.stats
        XCTAssertEqual(stats.received, 1)
    }

    func testSchedulerConvertsTimestamps() async {
        // Clock sync with 1 second offset (server ahead)
        let clockSync = MockClockSynchronizer(offset: 1_000_000, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        let pcmData = Data(repeating: 0x00, count: 1_024)
        let serverTimestamp: Int64 = 2_000_000 // 2 seconds server time

        await scheduler.schedule(pcm: pcmData, serverTimestamp: serverTimestamp)

        let chunks = await scheduler.getQueuedChunks()
        XCTAssertEqual(chunks.count, 1)

        // Expected: serverTime - offset = 2_000_000 - 1_000_000 = 1_000_000 microseconds
        XCTAssertEqual(chunks[0].playTimeMicroseconds, 1_000_000)
    }

    func testSchedulerMaintainsSortedQueue() async {
        let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        // Schedule chunks out of order
        await scheduler.schedule(pcm: Data([3]), serverTimestamp: 3_000_000)
        await scheduler.schedule(pcm: Data([1]), serverTimestamp: 1_000_000)
        await scheduler.schedule(pcm: Data([2]), serverTimestamp: 2_000_000)

        let chunks = await scheduler.getQueuedChunks()
        XCTAssertEqual(chunks.count, 3)

        // Should be sorted by playTime
        XCTAssertLessThan(chunks[0].playTimeMicroseconds, chunks[1].playTimeMicroseconds)
        XCTAssertLessThan(chunks[1].playTimeMicroseconds, chunks[2].playTimeMicroseconds)
    }

    func testSchedulerOutputsReadyChunks() async throws {
        let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        // Schedule chunk for immediate playback (current time)
        let nowMicros = MonotonicClock.absoluteMicroseconds()

        await scheduler.schedule(pcm: Data([0x01]), serverTimestamp: nowMicros)
        await scheduler.startScheduling()

        // Should output chunk immediately
        let outputChunk: ScheduledChunk? = await withCheckedContinuation { continuation in
            Task {
                for await chunk in await scheduler.scheduledChunks {
                    continuation.resume(returning: chunk)
                    return
                }
                continuation.resume(returning: nil)
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        await scheduler.stop()

        XCTAssertNotNil(outputChunk)
        XCTAssertEqual(outputChunk?.pcmData, Data([0x01]))

        let stats = await scheduler.stats
        XCTAssertEqual(stats.played, 1)
    }

    func testSchedulerDropsLateChunks() async throws {
        let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        // Schedule chunk 100ms in the past
        let pastMicros = MonotonicClock.absoluteMicroseconds() - 100_000

        await scheduler.schedule(pcm: Data([0xFF]), serverTimestamp: pastMicros)
        await scheduler.startScheduling()

        try await Task.sleep(for: .milliseconds(50))
        await scheduler.stop()

        let stats = await scheduler.stats
        XCTAssertEqual(stats.dropped, 1)
        XCTAssertEqual(stats.played, 0)
    }

    func testSchedulerKeepsAllFutureChunks() async {
        let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        let futureMicros = MonotonicClock.absoluteMicroseconds() + 10_000_000 // 10 seconds ahead

        // Schedule 10 chunks — all should be kept (no queue size limit)
        for chunkIndex in 0 ..< 10 {
            await scheduler.schedule(
                pcm: Data([UInt8(chunkIndex)]),
                serverTimestamp: futureMicros + Int64(chunkIndex * 1_000)
            )
        }

        let chunks = await scheduler.getQueuedChunks()
        XCTAssertEqual(chunks.count, 10)

        let stats = await scheduler.stats
        XCTAssertEqual(stats.received, 10)
        XCTAssertEqual(stats.dropped, 0)
    }

    func testSchedulerClearQueue() async {
        let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        let futureMicros = MonotonicClock.absoluteMicroseconds() + 10_000_000

        await scheduler.schedule(pcm: Data([0x01]), serverTimestamp: futureMicros)
        await scheduler.schedule(pcm: Data([0x02]), serverTimestamp: futureMicros + 1_000)

        var chunks = await scheduler.getQueuedChunks()
        XCTAssertEqual(chunks.count, 2)

        await scheduler.clear()

        chunks = await scheduler.getQueuedChunks()
        XCTAssertEqual(chunks.count, 0)
    }

    func testSchedulerDetailedStatsReturnsQueueSize() async {
        let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        // Initially queue should be empty
        var detailedStats = await scheduler.getDetailedStats()
        XCTAssertEqual(detailedStats.queueSize, 0)
        XCTAssertEqual(detailedStats.received, 0)
        XCTAssertEqual(detailedStats.played, 0)
        XCTAssertEqual(detailedStats.dropped, 0)

        // Schedule 3 chunks for future playback
        let futureMicros = MonotonicClock.absoluteMicroseconds() + 10_000_000

        await scheduler.schedule(pcm: Data([0x01]), serverTimestamp: futureMicros)
        await scheduler.schedule(pcm: Data([0x02]), serverTimestamp: futureMicros + 1_000)
        await scheduler.schedule(pcm: Data([0x03]), serverTimestamp: futureMicros + 2_000)

        // Queue should have 3 items
        detailedStats = await scheduler.getDetailedStats()
        XCTAssertEqual(detailedStats.queueSize, 3)
        XCTAssertEqual(detailedStats.received, 3)
        XCTAssertEqual(detailedStats.played, 0)
        XCTAssertEqual(detailedStats.dropped, 0)
    }

    func testSchedulerDetailedStatsUpdatesAfterPlayback() async throws {
        let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        // Schedule chunk for immediate playback
        let nowMicros = MonotonicClock.absoluteMicroseconds()

        await scheduler.schedule(pcm: Data([0x01]), serverTimestamp: nowMicros)
        await scheduler.startScheduling()

        // Consume the output
        let outputChunk: ScheduledChunk? = await withCheckedContinuation { continuation in
            Task {
                for await chunk in await scheduler.scheduledChunks {
                    continuation.resume(returning: chunk)
                    return
                }
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        await scheduler.stop()

        // Verify chunk was played
        XCTAssertNotNil(outputChunk)

        // Check detailed stats
        let detailedStats = await scheduler.getDetailedStats()
        XCTAssertEqual(detailedStats.queueSize, 0) // Queue should be empty
        XCTAssertEqual(detailedStats.received, 1)
        XCTAssertEqual(detailedStats.played, 1)
        XCTAssertEqual(detailedStats.dropped, 0)
    }
}

/// Mock ClockSynchronizer for testing
actor MockClockSynchronizer: ClockSyncProtocol {
    private let offset: Int64
    private let drift: Double

    init(offset: Int64, drift: Double) {
        self.offset = offset
        self.drift = drift
    }

    func serverTimeToLocal(_ serverTime: Int64) -> Int64 {
        serverTime - offset
    }
}
