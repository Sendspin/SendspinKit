// ABOUTME: Timestamp-based audio chunk scheduler with sorted queue
// ABOUTME: Converts server timestamps to local time and yields chunks when due

import Foundation

/// Protocol for clock synchronization
protocol ClockSyncProtocol: Actor {
    func serverTimeToLocal(_ serverTime: Int64) -> Int64
}

/// Statistics tracked by the scheduler
struct SchedulerStats {
    let received: Int
    let played: Int
    let dropped: Int
    let droppedLate: Int // Frames dropped because they were >50ms late

    init(received: Int = 0, played: Int = 0, dropped: Int = 0, droppedLate: Int = 0) {
        self.received = received
        self.played = played
        self.dropped = dropped
        self.droppedLate = droppedLate
    }
}

/// Detailed statistics including queue size and buffer metrics
struct DetailedSchedulerStats {
    let received: Int
    let played: Int
    let dropped: Int
    let droppedLate: Int
    let queueSize: Int
    let bufferFillMs: Double // Current buffer fill in milliseconds

    init(
        received: Int = 0,
        played: Int = 0,
        dropped: Int = 0,
        droppedLate: Int = 0,
        queueSize: Int = 0,
        bufferFillMs: Double = 0.0
    ) {
        self.received = received
        self.played = played
        self.dropped = dropped
        self.droppedLate = droppedLate
        self.queueSize = queueSize
        self.bufferFillMs = bufferFillMs
    }
}

/// A chunk scheduled for playback at a specific time
struct ScheduledChunk {
    let pcmData: Data
    let playTime: Date
    let originalTimestamp: Int64
    /// Stream generation — incremented on format changes so the output loop
    /// can distinguish old-format from new-format chunks.
    let generation: UInt64
}

/// Actor managing timestamp-based audio playback scheduling
actor AudioScheduler<ClockSync: ClockSyncProtocol> {
    private let clockSync: ClockSync
    private let playbackWindow: TimeInterval
    private var queue: [ScheduledChunk] = []
    private var schedulerStats: SchedulerStats
    private var timerTask: Task<Void, Never>?

    // AsyncStream for output
    private let chunkContinuation: AsyncStream<ScheduledChunk>.Continuation
    let scheduledChunks: AsyncStream<ScheduledChunk>

    init(
        clockSync: ClockSync,
        playbackWindow: TimeInterval = 0.05
    ) {
        self.clockSync = clockSync
        self.playbackWindow = playbackWindow
        schedulerStats = SchedulerStats()

        // Create AsyncStream
        (scheduledChunks, chunkContinuation) = AsyncStream.makeStream()
    }

    /// Schedule a PCM chunk for playback
    func schedule(pcm: Data, serverTimestamp: Int64, generation: UInt64 = 0) async {
        // Convert server timestamp to local playback time
        let localTimeMicros = await clockSync.serverTimeToLocal(serverTimestamp)
        let localTimeSeconds = Double(localTimeMicros) / 1_000_000.0
        let playTime = Date(timeIntervalSince1970: localTimeSeconds)

        let chunk = ScheduledChunk(
            pcmData: pcm,
            playTime: playTime,
            originalTimestamp: serverTimestamp,
            generation: generation
        )

        // No queue size limit: the server already respects our buffer_capacity
        // from client/hello, so it won't send more than we can handle. Chunks are
        // consumed by the audio callback as their play timestamps arrive.
        // Dropping future chunks here would cause silence when servers pre-buffer
        // aggressively (e.g., Music Assistant sends 25+ seconds ahead).

        // Insert into sorted position
        insertSorted(chunk)

        schedulerStats = SchedulerStats(
            received: schedulerStats.received + 1,
            played: schedulerStats.played,
            dropped: schedulerStats.dropped,
            droppedLate: schedulerStats.droppedLate
        )
    }

    /// Insert chunk maintaining sorted order by playTime
    private func insertSorted(_ chunk: ScheduledChunk) {
        // Find the insertion point using binary search
        var low = 0
        var high = queue.count

        while low < high {
            let mid = (low + high) / 2
            if queue[mid].playTime < chunk.playTime {
                low = mid + 1
            } else {
                high = mid
            }
        }

        queue.insert(chunk, at: low)
    }

    /// Get queued chunks (for testing)
    func getQueuedChunks() -> [ScheduledChunk] {
        queue
    }

    /// Get current statistics
    var stats: SchedulerStats {
        schedulerStats
    }

    /// Get detailed statistics including queue size and buffer metrics
    func getDetailedStats() -> DetailedSchedulerStats {
        // Calculate buffer fill: time until next chunk should play
        let now = Date()
        let bufferFillMs: Double = if let nextChunk = queue.first {
            max(0, nextChunk.playTime.timeIntervalSince(now) * 1_000.0)
        } else {
            0.0
        }

        return DetailedSchedulerStats(
            received: schedulerStats.received,
            played: schedulerStats.played,
            dropped: schedulerStats.dropped,
            droppedLate: schedulerStats.droppedLate,
            queueSize: queue.count,
            bufferFillMs: bufferFillMs
        )
    }

    /// Start the scheduling timer loop
    func startScheduling() {
        guard timerTask == nil else { return }

        timerTask = Task {
            while !Task.isCancelled {
                checkQueue()

                // Smart sleep: wait until the next chunk is due instead of
                // polling at a fixed interval.
                let sleepDuration: Duration
                if let next = queue.first {
                    let delay = next.playTime.timeIntervalSince(Date()) - playbackWindow
                    if delay > 0 {
                        // Cap at playbackWindow so new arrivals aren't delayed too long
                        let cappedDelay = min(delay, playbackWindow)
                        sleepDuration = .nanoseconds(Int64(cappedDelay * 1_000_000_000))
                    } else {
                        // Chunk is due now or overdue — tight loop briefly to drain
                        sleepDuration = .milliseconds(1)
                    }
                } else {
                    // Empty queue — no rush, check back in 50ms
                    sleepDuration = .milliseconds(50)
                }

                try? await Task.sleep(for: sleepDuration)
            }
        }
    }

    /// Stop the scheduler timer (but keep stream alive for next start)
    func stop() {
        timerTask?.cancel()
        timerTask = nil
        // Don't call chunkContinuation.finish() here - that would permanently
        // close the AsyncStream. We need to keep it alive for multiple stream cycles.
    }

    /// Permanently finish the scheduler (call on disconnect only)
    func finish() {
        stop()
        chunkContinuation.finish()
    }

    /// Clear all queued chunks
    func clear() {
        queue.removeAll()
    }

    /// Check queue and output ready chunks
    private func checkQueue() {
        let now = Date()

        while let next = queue.first {
            let delay = next.playTime.timeIntervalSince(now)

            if delay > playbackWindow {
                // Too early, wait
                break
            } else if delay < -playbackWindow {
                // Too late, drop
                queue.removeFirst()
                schedulerStats = SchedulerStats(
                    received: schedulerStats.received,
                    played: schedulerStats.played,
                    dropped: schedulerStats.dropped + 1,
                    droppedLate: schedulerStats.droppedLate + 1
                )
            } else {
                // Ready to play (within ±50ms window)
                let chunk = queue.removeFirst()
                chunkContinuation.yield(chunk)

                schedulerStats = SchedulerStats(
                    received: schedulerStats.received,
                    played: schedulerStats.played + 1,
                    dropped: schedulerStats.dropped,
                    droppedLate: schedulerStats.droppedLate
                )
            }
        }
    }
}
