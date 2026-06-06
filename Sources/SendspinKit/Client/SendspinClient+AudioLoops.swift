// ABOUTME: Audio runtime loops for SendspinClient — scheduler output and sync telemetry
// ABOUTME: Detached tasks that drain scheduled PCM to the player and poll reanchor/telemetry

import Foundation
import os

extension SendspinClient {
    // MARK: - Scheduler output

    /// Number of chunks to pre-buffer before rebuilding the AudioQueue during
    /// a format transition. This gives the AudioQueue headroom so the sync
    /// correction doesn't engage aggressively on the first few samples.
    /// 2 chunks ≈ 200ms — enough headroom without overshooting.
    nonisolated static let formatTransitionPreBuffer = 2

    nonisolated func runSchedulerOutput() async {
        guard let audioScheduler = await audioScheduler,
              let audioPlayer = await audioPlayer
        else { return }

        var activeGeneration: UInt64 = await streamGeneration

        for await chunk in audioScheduler.scheduledChunks {
            if chunk.generation != activeGeneration {
                if chunk.generation < activeGeneration {
                    // Old-generation chunk after a format change already happened.
                    // This shouldn't occur since old chunks have earlier timestamps,
                    // but discard just in case.
                    continue
                }

                // New generation — first chunk decoded in the new format.
                // Accumulate a few chunks before rebuilding the AudioQueue
                // so we have buffer headroom for clean sync convergence.
                let pending = await MainActor.run { () -> (AudioFormatSpec?, Data?) in
                    let fmt = self.pendingFormat
                    let hdr = self.pendingCodecHeader
                    self.pendingFormat = nil
                    self.pendingCodecHeader = nil
                    return (fmt, hdr)
                }

                activeGeneration = chunk.generation

                guard let format = pending.0 else {
                    try? await audioPlayer.playPCM(chunk.pcmData, serverTimestamp: chunk.originalTimestamp)
                    continue
                }

                // Pre-buffer: collect this chunk + one more before switching
                var preBuffer: [(pcm: Data, timestamp: Int64)] = [
                    (chunk.pcmData, chunk.originalTimestamp)
                ]

                for await nextChunk in audioScheduler.scheduledChunks {
                    preBuffer.append((nextChunk.pcmData, nextChunk.originalTimestamp))
                    if preBuffer.count >= Self.formatTransitionPreBuffer {
                        break
                    }
                }

                // Rebuild AudioQueue and feed pre-buffered chunks
                Log.client.info("Seamless switch: rebuilding AudioQueue at \(format.sampleRate)Hz (pre-buffered \(preBuffer.count) chunks)")
                try? await audioPlayer.start(format: format, codecHeader: pending.1)

                for buffered in preBuffer {
                    try? await audioPlayer.playPCM(buffered.pcm, serverTimestamp: buffered.timestamp)
                }
                continue
            }
            try? await audioPlayer.playPCM(chunk.pcmData, serverTimestamp: chunk.originalTimestamp)
        }
    }

    /// Polls for reanchor requests from the audio callback and logs telemetry.
    /// Sync correction is now computed inside the AudioQueue callback itself,
    /// so this loop only handles rare reanchor events and periodic logging.
    nonisolated func runSyncCorrectionAndTelemetry() async {
        var lastTelemetryStats = SchedulerStats()
        var tickCount = 0
        var underrunMonitor = UnderrunMonitor()

        while !Task.isCancelled {
            // 500ms poll — reanchors are rare events, no need to check faster.
            // Telemetry logs every 4th tick (2s).
            try? await Task.sleep(for: .milliseconds(500))
            tickCount += 1

            guard let audioScheduler = await audioScheduler,
                  let clockSync = await clockSync,
                  let audioPlayer = await audioPlayer else { continue }

            // --- Poll for reanchor requests from the audio callback ---
            if let reanchorTarget = await audioPlayer.pollReanchor() {
                await audioPlayer.reanchorCursor(to: reanchorTarget)
            }

            let tSnap = await audioPlayer.telemetrySnapshot

            // Report buffer starvation as `error`/`synchronized` (spec §Playback
            // Synchronization). The audio callback only counts underruns; this
            // off-thread loop is where we can reach the server.
            switch await clientOperationalState {
            case .externalSource:
                // Re-baseline: underruns accrued while not playing must not trip an
                // error once we rejoin.
                underrunMonitor.resetBaseline(underrunCount: tSnap.underrunCount)
            case .synchronized, .error:
                await applyUnderrunTransition(underrunMonitor.observe(underrunCount: tSnap.underrunCount))
            }

            // --- Telemetry (every 2s = every 4 ticks) ---
            if tickCount % 4 == 0 {
                let currentStats = await audioScheduler.stats
                guard currentStats.received > 0 else { continue }

                // Atomic snapshot of clock-sync state — single actor hop covers
                // offset, RTT, and the Kalman convergence diagnostics.
                guard let syncSnap = await clockSync.diagnosticSnapshot() else { continue }

                let framesScheduled = currentStats.received - lastTelemetryStats.received
                let framesPlayed = currentStats.played - lastTelemetryStats.played
                let framesDroppedLate = currentStats.droppedLate - lastTelemetryStats.droppedLate

                let clockOffsetMs = Double(syncSnap.offset) / 1_000.0
                let rttMs = Double(syncSnap.rtt) / 1_000.0
                let estErrUs = Int64(syncSnap.estimatedError.rounded())
                // Drift is dimensionless (μs of offset per μs of time); ppm is the
                // human-readable form for clock-drift rates.
                let driftPpm = syncSnap.drift * 1_000_000.0

                // Sync error computed by the audio callback (precise, no actor jitter);
                // reuse the per-tick telemetry snapshot read above.
                let syncErrorUs = tSnap.syncErrorUs
                let dropN = tSnap.correctionSchedule.dropEveryNFrames
                let insertN = tSnap.correctionSchedule.insertEveryNFrames

                let correcting = tSnap.correctionSchedule.isCorrecting

                // Telemetry is pre-formatted into a single String because os.Logger's
                // type checker can't handle this many inline interpolation segments.
                // The cost (unconditional formatting) is acceptable at the 2s tick rate.
                let telemetry = "sched=\(framesScheduled) played=\(framesPlayed)"
                    + " late=\(framesDroppedLate)"
                    + " buf=\(String(format: "%.1f", currentStats.bufferFillMs))ms"
                    + " offset=\(String(format: "%.2f", clockOffsetMs))ms"
                    + " rtt=\(String(format: "%.2f", rttMs))ms"
                    + " est=\(estErrUs)us"
                    + " drift=\(String(format: "%.2f", driftPpm))ppm"
                    + " samples=\(syncSnap.sampleCount)"
                    + " queue=\(currentStats.queueSize)"
                    + " sync=\(syncErrorUs)us"
                    + " correcting=\(correcting)"
                    + " drop=\(dropN) insert=\(insertN)"
                Log.client.debug("\(telemetry, privacy: .public)")

                lastTelemetryStats = currentStats
            }
        }
    }
}
