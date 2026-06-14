import Foundation
@testable import SendspinKit
import Testing

struct AudioSchedulerTests {
    @Test
    func schedulerAcceptsChunk() async {
        // Mock clock sync that returns zero offset
        let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        let pcmData = Data(repeating: 0x00, count: 1_024)
        let serverTimestamp: Int64 = 1_000_000 // 1 second in microseconds

        // Should not throw
        await scheduler.schedule(pcm: pcmData, serverTimestamp: serverTimestamp)

        let stats = await scheduler.stats
        #expect(stats.received == 1)
    }

    @Test
    func schedulerConvertsTimestamps() async {
        // Clock sync with 1 second offset (server ahead)
        let clockSync = MockClockSynchronizer(offset: 1_000_000, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        let pcmData = Data(repeating: 0x00, count: 1_024)
        let serverTimestamp: Int64 = 2_000_000 // 2 seconds server time

        await scheduler.schedule(pcm: pcmData, serverTimestamp: serverTimestamp)

        let chunks = await scheduler.queuedChunks
        #expect(chunks.count == 1)

        // Expected: serverTime - offset = 2_000_000 - 1_000_000 = 1_000_000 microseconds
        #expect(chunks[0].playTimeMicroseconds == 1_000_000)
    }

    @Test
    func schedulerMaintainsSortedQueue() async {
        let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        // Schedule chunks out of order
        await scheduler.schedule(pcm: Data([3]), serverTimestamp: 3_000_000)
        await scheduler.schedule(pcm: Data([1]), serverTimestamp: 1_000_000)
        await scheduler.schedule(pcm: Data([2]), serverTimestamp: 2_000_000)

        let chunks = await scheduler.queuedChunks
        #expect(chunks.count == 3)

        // Should be sorted by playTime
        #expect(chunks[0].playTimeMicroseconds < chunks[1].playTimeMicroseconds)
        #expect(chunks[1].playTimeMicroseconds < chunks[2].playTimeMicroseconds)
    }

    @Test
    func schedulerOutputsReadyChunks() async {
        let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        // Enqueue a chunk that is due now, then drive a single checkQueue pass.
        // This tests the yield/stats logic without depending on the timer task,
        // which competes for cooperative-pool threads under heavy parallel load.
        let playMicros = MonotonicClock.absoluteMicroseconds()
        await scheduler.schedule(pcm: Data([0x01]), serverTimestamp: playMicros)
        await scheduler.checkQueue()

        let stats = await scheduler.stats
        #expect(stats.played == 1)
        #expect(stats.queueSize == 0)
    }

    @Test
    func schedulerDropsLateChunks() async {
        let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        // Schedule chunk far enough in the past that it's outside the ±50ms
        // playback window and will be dropped by checkQueue.
        let pastMicros = MonotonicClock.absoluteMicroseconds() - 100_000

        await scheduler.schedule(pcm: Data([0xFF]), serverTimestamp: pastMicros)
        await scheduler.checkQueue()

        let stats = await scheduler.stats
        #expect(stats.dropped == 1)
        #expect(stats.played == 0)
    }

    @Test
    func schedulerYieldsSlightlyLateChunksWithinPlaybackWindow() async {
        let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        // A chunk inside the scheduler's default 50ms jitter tolerance is played
        // immediately instead of being dropped. The spec's late-drop rule is enforced
        // for chunks beyond this tolerance (see schedulerDropsLateChunks).
        let slightlyPastMicros = MonotonicClock.absoluteMicroseconds() - 25_000

        await scheduler.schedule(pcm: Data([0xAA]), serverTimestamp: slightlyPastMicros)
        await scheduler.checkQueue()

        let stats = await scheduler.stats
        #expect(stats.played == 1)
        #expect(stats.dropped == 0)
        #expect(stats.queueSize == 0)
    }

    @Test
    func schedulerKeepsAllFutureChunks() async {
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
        #expect(chunks.count == 10)

        let stats = await scheduler.stats
        #expect(stats.received == 10)
        #expect(stats.dropped == 0)
    }

    @Test
    func schedulerClearQueue() async {
        let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        let futureMicros = MonotonicClock.absoluteMicroseconds() + 10_000_000

        await scheduler.schedule(pcm: Data([0x01]), serverTimestamp: futureMicros)
        await scheduler.schedule(pcm: Data([0x02]), serverTimestamp: futureMicros + 1_000)

        var chunks = await scheduler.queuedChunks
        #expect(chunks.count == 2)

        await scheduler.clear()

        chunks = await scheduler.queuedChunks
        #expect(chunks.count == 0)
    }

    @Test
    func getStatsIncludesQueueSize() async {
        let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        // Initially queue should be empty
        var snapshot = await scheduler.stats
        #expect(snapshot.queueSize == 0)
        #expect(snapshot.received == 0)
        #expect(snapshot.played == 0)
        #expect(snapshot.dropped == 0)

        // Schedule 3 chunks for future playback
        let futureMicros = MonotonicClock.absoluteMicroseconds() + 10_000_000

        await scheduler.schedule(pcm: Data([0x01]), serverTimestamp: futureMicros)
        await scheduler.schedule(pcm: Data([0x02]), serverTimestamp: futureMicros + 1_000)
        await scheduler.schedule(pcm: Data([0x03]), serverTimestamp: futureMicros + 2_000)

        // Queue should have 3 items
        snapshot = await scheduler.stats
        #expect(snapshot.queueSize == 3)
        #expect(snapshot.received == 3)
        #expect(snapshot.played == 0)
        #expect(snapshot.dropped == 0)
    }

    @Test
    func getStatsUpdatesAfterPlayback() async {
        let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        // Enqueue a chunk that is due now, then drive a single checkQueue pass.
        let playMicros = MonotonicClock.absoluteMicroseconds()
        await scheduler.schedule(pcm: Data([0x01]), serverTimestamp: playMicros)
        await scheduler.checkQueue()

        let snapshot = await scheduler.stats
        #expect(snapshot.queueSize == 0)
        #expect(snapshot.received == 1)
        #expect(snapshot.played == 1)
        #expect(snapshot.dropped == 0)
    }

    @Test
    func bufferFillMeasuresToLastChunk() async {
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
        #expect(snapshot.bufferFillMs > 4_000.0)
    }
}

// MARK: - Mocks

/// Mock ClockSynchronizer for testing
actor MockClockSynchronizer: ClockSyncProtocol {
    private let offset: Int64

    var hasSynced: Bool {
        true
    }

    init(offset: Int64, drift _: Double) {
        self.offset = offset
    }

    func processServerTime(
        clientTransmitted _: Int64,
        serverReceived _: Int64,
        serverTransmitted _: Int64,
        clientReceived _: Int64
    ) {}

    func serverTimeToLocal(_ serverTime: Int64) -> Int64 {
        serverTime - offset
    }

    func localTimeToServer(_ localTime: Int64) -> Int64 {
        localTime + offset
    }

    func snapshot() -> TimeFilterSnapshot? {
        TimeFilterSnapshot(
            offset: Double(offset),
            drift: 0.0,
            lastUpdate: 0,
            useDrift: false,
            clientProcessStartAbsolute: 0
        )
    }

    func diagnosticSnapshot() -> ClockSynchronizer.DiagnosticSnapshot? {
        ClockSynchronizer.DiagnosticSnapshot(
            offset: offset,
            rtt: 10_000,
            rawRtt: 10_000,
            rawRttWasRejected: false,
            drift: 0.0,
            estimatedError: 100.0,
            sampleCount: 0
        )
    }
}
