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

        let chunks = await scheduler.queuedChunks
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

        let chunks = await scheduler.queuedChunks
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

        // Race the stream against a timeout to avoid hanging if the scheduler
        // never yields (e.g. a regression in checkQueue).
        let outputChunk = try await nextChunkWithTimeout(from: scheduler, seconds: 2)
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

        let chunks = await scheduler.queuedChunks
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

        var chunks = await scheduler.queuedChunks
        XCTAssertEqual(chunks.count, 2)

        await scheduler.clear()

        chunks = await scheduler.queuedChunks
        XCTAssertEqual(chunks.count, 0)
    }

    func testGetStatsIncludesQueueSize() async {
        let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        // Initially queue should be empty
        var snapshot = await scheduler.stats
        XCTAssertEqual(snapshot.queueSize, 0)
        XCTAssertEqual(snapshot.received, 0)
        XCTAssertEqual(snapshot.played, 0)
        XCTAssertEqual(snapshot.dropped, 0)

        // Schedule 3 chunks for future playback
        let futureMicros = MonotonicClock.absoluteMicroseconds() + 10_000_000

        await scheduler.schedule(pcm: Data([0x01]), serverTimestamp: futureMicros)
        await scheduler.schedule(pcm: Data([0x02]), serverTimestamp: futureMicros + 1_000)
        await scheduler.schedule(pcm: Data([0x03]), serverTimestamp: futureMicros + 2_000)

        // Queue should have 3 items
        snapshot = await scheduler.stats
        XCTAssertEqual(snapshot.queueSize, 3)
        XCTAssertEqual(snapshot.received, 3)
        XCTAssertEqual(snapshot.played, 0)
        XCTAssertEqual(snapshot.dropped, 0)
    }

    func testGetStatsUpdatesAfterPlayback() async throws {
        let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        // Schedule chunk for immediate playback
        let nowMicros = MonotonicClock.absoluteMicroseconds()

        await scheduler.schedule(pcm: Data([0x01]), serverTimestamp: nowMicros)
        await scheduler.startScheduling()

        let outputChunk = try await nextChunkWithTimeout(from: scheduler, seconds: 2)
        await scheduler.stop()

        // Verify chunk was played
        XCTAssertNotNil(outputChunk)

        // Check stats
        let snapshot = await scheduler.stats
        XCTAssertEqual(snapshot.queueSize, 0) // Queue should be empty
        XCTAssertEqual(snapshot.received, 1)
        XCTAssertEqual(snapshot.played, 1)
        XCTAssertEqual(snapshot.dropped, 0)
    }

    func testBufferFillMeasuresToLastChunk() async {
        let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        let nowMicros = MonotonicClock.absoluteMicroseconds()
        // Schedule chunks spanning 5 seconds into the future
        let firstTimestamp = nowMicros + 100_000 // 100ms ahead
        let lastTimestamp = nowMicros + 5_000_000 // 5s ahead

        await scheduler.schedule(pcm: Data([0x01]), serverTimestamp: firstTimestamp)
        await scheduler.schedule(pcm: Data([0x02]), serverTimestamp: lastTimestamp)

        let snapshot = await scheduler.stats
        // bufferFillMs should reflect the last chunk (~5000ms), not the first (~100ms)
        XCTAssertGreaterThan(snapshot.bufferFillMs, 4_000.0)
    }
}

// MARK: - Helpers

/// Wait for the next chunk from the scheduler's output stream, or fail after a timeout.
private func nextChunkWithTimeout(
    from scheduler: AudioScheduler,
    seconds: Int
) async throws -> ScheduledChunk? {
    try await withThrowingTaskGroup(of: ScheduledChunk?.self) { group in
        group.addTask {
            for await chunk in await scheduler.scheduledChunks {
                return chunk
            }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private struct TimeoutError: Error {}

/// Mock ClockSynchronizer for testing
actor MockClockSynchronizer: ClockSyncProtocol {
    private let offset: Int64

    init(offset: Int64, drift _: Double) {
        self.offset = offset
    }

    func serverTimeToLocal(_ serverTime: Int64) -> Int64 {
        serverTime - offset
    }
}
