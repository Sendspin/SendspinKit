// ABOUTME: Timestamp-based audio playback scheduler with priority queue
// ABOUTME: Converts server timestamps to local time and schedules precise playback

import Foundation

/// Protocol for clock synchronization
public protocol ClockSyncProtocol: Actor {
    func serverTimeToLocal(_ serverTime: Int64) -> Int64
}

/// Statistics tracked by the scheduler
public struct SchedulerStats: Sendable {
    public let received: Int
    public let played: Int
    public let dropped: Int
    public let droppedLate: Int // Frames dropped because they were >50ms late
    public let droppedOther: Int // Frames dropped due to queue overflow

    public init(received: Int = 0, played: Int = 0, dropped: Int = 0, droppedLate: Int = 0, droppedOther: Int = 0) {
        self.received = received
        self.played = played
        self.dropped = dropped
        self.droppedLate = droppedLate
        self.droppedOther = droppedOther
    }
}

/// Detailed statistics including queue size and buffer metrics
public struct DetailedSchedulerStats: Sendable {
    public let received: Int
    public let played: Int
    public let dropped: Int
    public let droppedLate: Int
    public let droppedOther: Int
    public let queueSize: Int
    public let bufferFillMs: Double // Current buffer fill in milliseconds

    public init(
        received: Int = 0,
        played: Int = 0,
        dropped: Int = 0,
        droppedLate: Int = 0,
        droppedOther: Int = 0,
        queueSize: Int = 0,
        bufferFillMs: Double = 0.0
    ) {
        self.received = received
        self.played = played
        self.dropped = dropped
        self.droppedLate = droppedLate
        self.droppedOther = droppedOther
        self.queueSize = queueSize
        self.bufferFillMs = bufferFillMs
    }
}

/// A chunk scheduled for playback at a specific time
public struct ScheduledChunk: Sendable {
    public let pcmData: Data
    public let playTime: Date
    public let originalTimestamp: Int64
}

/// Actor managing timestamp-based audio playback scheduling
public actor AudioScheduler<ClockSync: ClockSyncProtocol> {
    private let clockSync: ClockSync
    private let playbackWindow: TimeInterval
    private let maxQueueSize: Int
    private var queue: [ScheduledChunk] = []
    private var schedulerStats: SchedulerStats
    private var timerTask: Task<Void, Never>?

    // AsyncStream for output
    private let chunkContinuation: AsyncStream<ScheduledChunk>.Continuation
    public let scheduledChunks: AsyncStream<ScheduledChunk>

    public init(
        clockSync: ClockSync,
        playbackWindow: TimeInterval = 0.05,
        maxQueueSize: Int = 100
    ) {
        self.clockSync = clockSync
        self.playbackWindow = playbackWindow
        self.maxQueueSize = maxQueueSize
        schedulerStats = SchedulerStats()

        // Create AsyncStream
        (scheduledChunks, chunkContinuation) = AsyncStream.makeStream()
    }

    /// Schedule a PCM chunk for playback
    public func schedule(pcm: Data, serverTimestamp: Int64) async {
        let receivedCount = schedulerStats.received

        // Convert server timestamp to local playback time
        let localTimeMicros = await clockSync.serverTimeToLocal(serverTimestamp)
        let localTimeSeconds = Double(localTimeMicros) / 1_000_000.0
        let playTime = Date(timeIntervalSince1970: localTimeSeconds)

        // Log first 10 chunks with detailed timing info
        if receivedCount < 10 {
            let now = Date()
            let delay = playTime.timeIntervalSince(now)
            let delayMs = Int(delay * 1000)

            // Chunk #\(receivedCount): server_ts=\(serverTimestamp)μs,
            // delay=\(delayMs)ms, queue_size=\(queue.count)
        }

        let chunk = ScheduledChunk(
            pcmData: pcm,
            playTime: playTime,
            originalTimestamp: serverTimestamp
        )

        // Enforce queue size limit
        while queue.count >= maxQueueSize {
            queue.removeFirst()
            schedulerStats = SchedulerStats(
                received: schedulerStats.received,
                played: schedulerStats.played,
                dropped: schedulerStats.dropped + 1,
                droppedLate: schedulerStats.droppedLate,
                droppedOther: schedulerStats.droppedOther + 1
            )
            // print("[SCHEDULER] Queue overflow: dropped oldest chunk")
        }

        // Insert into sorted position
        insertSorted(chunk)

        schedulerStats = SchedulerStats(
            received: schedulerStats.received + 1,
            played: schedulerStats.played,
            dropped: schedulerStats.dropped,
            droppedLate: schedulerStats.droppedLate,
            droppedOther: schedulerStats.droppedOther
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
    public func getQueuedChunks() -> [ScheduledChunk] {
        return queue
    }

    /// Get current statistics
    public var stats: SchedulerStats {
        return schedulerStats
    }

    /// Get detailed statistics including queue size and buffer metrics
    public func getDetailedStats() -> DetailedSchedulerStats {
        // Calculate buffer fill: time until next chunk should play
        let now = Date()
        let bufferFillMs: Double
        if let nextChunk = queue.first {
            bufferFillMs = max(0, nextChunk.playTime.timeIntervalSince(now) * 1000.0)
        } else {
            bufferFillMs = 0.0
        }

        return DetailedSchedulerStats(
            received: schedulerStats.received,
            played: schedulerStats.played,
            dropped: schedulerStats.dropped,
            droppedLate: schedulerStats.droppedLate,
            droppedOther: schedulerStats.droppedOther,
            queueSize: queue.count,
            bufferFillMs: bufferFillMs
        )
    }

    /// Start the scheduling timer loop
    public func startScheduling() {
        guard timerTask == nil else { return }

        timerTask = Task {
            while !Task.isCancelled {
                checkQueue()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// Stop the scheduler timer (but keep stream alive for next start)
    public func stop() {
        timerTask?.cancel()
        timerTask = nil
        // Don't call chunkContinuation.finish() here - that would permanently
        // close the AsyncStream. We need to keep it alive for multiple stream cycles.
    }

    /// Permanently finish the scheduler (call on disconnect only)
    public func finish() {
        stop()
        chunkContinuation.finish()
    }

    /// Clear all queued chunks
    public func clear() {
        queue.removeAll()
        // print("[SCHEDULER] Queue cleared")
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
                    droppedLate: schedulerStats.droppedLate + 1,
                    droppedOther: schedulerStats.droppedOther
                )

                // Log first 10 drops
                if schedulerStats.droppedLate <= 10 {
                    // print("[SCHEDULER] Dropped late chunk: \(Int(-delay * 1000))ms late")
                }
            } else {
                // Ready to play (within ±50ms window)
                let chunk = queue.removeFirst()
                chunkContinuation.yield(chunk)

                schedulerStats = SchedulerStats(
                    received: schedulerStats.received,
                    played: schedulerStats.played + 1,
                    dropped: schedulerStats.dropped,
                    droppedLate: schedulerStats.droppedLate,
                    droppedOther: schedulerStats.droppedOther
                )
            }
        }
    }
}
