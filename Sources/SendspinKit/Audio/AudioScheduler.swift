// ABOUTME: Timestamp-based audio chunk scheduler with sorted queue
// ABOUTME: Converts server timestamps to local time and yields chunks when due

import Foundation

/// Statistics tracked by the scheduler
struct SchedulerStats: Equatable {
    var received: Int = 0
    var played: Int = 0
    var dropped: Int = 0
    var droppedLate: Int = 0
    var queueSize: Int = 0
    /// Total buffered duration: time from now until the last queued chunk's
    /// play time (milliseconds). Zero when the queue is empty.
    var bufferFillMs: Double = 0.0
}

/// A chunk scheduled for playback at a specific time, carrying stream identity
/// via `generation` for seamless format transitions.
struct ScheduledChunk {
    let pcmData: Data
    /// Local absolute time in microseconds (from MonotonicClock) when this chunk should play
    let playTimeMicroseconds: Int64
    let originalTimestamp: Int64
    /// Stream generation — incremented on format changes so the output loop
    /// can distinguish old-format from new-format chunks.
    let generation: UInt64
}

/// Actor managing timestamp-based audio playback scheduling
actor AudioScheduler {
    private let clockSync: any ClockSyncProtocol
    /// Playback window in microseconds — chunks within ±this window of "now" are played
    private let playbackWindowUs: Int64
    private var queue: [ScheduledChunk] = []
    /// Index of the next chunk to consume. Using an index avoids O(n) shifts
    /// from `removeFirst()`. The prefix is compacted when it exceeds half the
    /// array to prevent unbounded growth.
    private var readIndex: Int = 0
    private var counters = SchedulerStats()
    private var timerTask: Task<Void, Never>?

    // AsyncStream for output
    private let chunkContinuation: AsyncStream<ScheduledChunk>.Continuation
    let scheduledChunks: AsyncStream<ScheduledChunk>

    init(
        clockSync: any ClockSyncProtocol,
        playbackWindow: TimeInterval = 0.05
    ) {
        self.clockSync = clockSync
        playbackWindowUs = Int64(playbackWindow * 1_000_000)

        // Create AsyncStream
        (scheduledChunks, chunkContinuation) = AsyncStream.makeStream()
    }

    /// Schedule a PCM chunk for playback
    func schedule(pcm: Data, serverTimestamp: Int64, generation: UInt64 = 0) async {
        // Convert server timestamp to local playback time (absolute µs from MonotonicClock)
        let localTimeMicros = await clockSync.serverTimeToLocal(serverTimestamp)

        let chunk = ScheduledChunk(
            pcmData: pcm,
            playTimeMicroseconds: localTimeMicros,
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

        counters.received += 1
    }

    /// Insert chunk maintaining sorted order by playTime.
    /// Binary search runs over the unconsumed portion (`readIndex..<queue.count`).
    private func insertSorted(_ chunk: ScheduledChunk) {
        var low = readIndex
        var high = queue.count

        while low < high {
            let mid = (low + high) / 2
            if queue[mid].playTimeMicroseconds < chunk.playTimeMicroseconds {
                low = mid + 1
            } else {
                high = mid
            }
        }

        queue.insert(chunk, at: low)
    }

    /// Number of unconsumed chunks in the queue.
    private var activeCount: Int {
        queue.count - readIndex
    }

    /// Queued chunks (for testing)
    var queuedChunks: [ScheduledChunk] {
        Array(queue[readIndex...])
    }

    /// Statistics snapshot including queue size and buffer fill.
    var stats: SchedulerStats {
        var snapshot = counters
        snapshot.queueSize = activeCount

        let nowUs = MonotonicClock.absoluteMicroseconds()
        if let lastChunk = queue.last {
            snapshot.bufferFillMs = max(0, Double(lastChunk.playTimeMicroseconds - nowUs) / 1_000.0)
        }

        return snapshot
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
                if readIndex < queue.count {
                    let next = queue[readIndex]
                    let nowUs = MonotonicClock.absoluteMicroseconds()
                    let delayUs = next.playTimeMicroseconds - nowUs - playbackWindowUs
                    if delayUs > 0 {
                        // Cap at playbackWindow so new arrivals aren't delayed too long
                        let cappedDelayUs = min(delayUs, playbackWindowUs)
                        sleepDuration = .microseconds(cappedDelayUs)
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
        readIndex = 0
    }

    /// Compact the consumed prefix when it exceeds half the array,
    /// preventing unbounded growth of dead entries.
    private func compactIfNeeded() {
        if readIndex > queue.count / 2, readIndex > 0 {
            queue.removeFirst(readIndex)
            readIndex = 0
        }
    }

    /// Check queue and output ready chunks
    private func checkQueue() {
        let nowUs = MonotonicClock.absoluteMicroseconds()

        while readIndex < queue.count {
            let next = queue[readIndex]
            let delayUs = next.playTimeMicroseconds - nowUs

            if delayUs > playbackWindowUs {
                // Too early, wait
                break
            } else if delayUs < -playbackWindowUs {
                // Too late, drop
                readIndex += 1
                counters.dropped += 1
                counters.droppedLate += 1
            } else {
                // Ready to play (within ±window)
                readIndex += 1
                chunkContinuation.yield(next)
                counters.played += 1
            }
        }

        compactIfNeeded()
    }
}
