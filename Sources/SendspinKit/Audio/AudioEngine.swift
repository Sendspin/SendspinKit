import Foundation
import os

/// Audio processing engine running off the MainActor.
///
/// Owns the `AudioPlayer`, `AudioScheduler`, and seamless-format state machine.
/// Consumes `DataPlaneCommand`s from an ordered `DataPlaneSink` channel and emits
/// `EngineReport`s for lifecycle/state transitions. The engine does all heavy
/// per-chunk work (decode, schedule, output, sync telemetry) off-main,
/// while the client message loop remains on the MainActor for classification and gates.
///
/// **No `@MainActor` or `MainActor.run` anywhere.** Seamless format changes are
/// entirely engine-internal.
actor AudioEngine {
    private let output: any AudioOutput
    private let audioScheduler: AudioScheduler
    private let clock: any ClockSyncProtocol

    // Command ingress
    private let _commandsSink: DataPlaneSink
    private let _commandStream: AsyncStream<DataPlaneCommand>

    // Report egress
    private let reportStream: AsyncStream<EngineReport>
    private let reportContinuation: AsyncStream<EngineReport>.Continuation

    // Seamless format state (engine-isolated, no MainActor.run)
    private var pendingFormat: AudioFormatSpec?
    private var pendingCodecHeader: Data?
    private var streamGeneration: UInt64 = 0

    /// Static delay in milliseconds (subtracted from scheduled timestamps)
    private var staticDelayMs: Int = 0

    // Task tracking for shutdown
    private var drainTask: Task<Void, Never>?
    private var schedulerOutputTask: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?

    // Running state
    private var running = false
    private var shuttingDown = false

    // Diagnostics: record command kinds for processing-order test assertions.
    private var appliedKinds: [DataPlaneCommandKind] = []

    /// Operational state tracking for telemetry (engine maintains the state, client drains reports)
    private var operationalState: ClientOperationalState = .synchronized

    /// User/server-commanded mute (visible state, reported via `client/state`).
    private var userMuted = false
    /// Engine-imposed safety mute while in the underrun `error` state
    /// (spec §Playback Synchronization). Never visible in `client/state`.
    private var errorMuted = false

    /// Whether this client is participating in playback (not external source).
    /// When false (external source is active), underrun telemetry is suppressed.
    private var participatingInPlayback = true

    // MARK: - Initialization

    /// Designated internal initializer for testing with injected output and clock.
    init(output: any AudioOutput, scheduler: AudioScheduler, clock: any ClockSyncProtocol) {
        self.output = output
        audioScheduler = scheduler
        self.clock = clock
        let sink = DataPlaneSink()
        _commandsSink = sink
        _commandStream = sink.commands
        let (reportStream, reportContinuation) = AsyncStream<EngineReport>.makeStream()
        self.reportStream = reportStream
        self.reportContinuation = reportContinuation
    }

    /// Secondary initializer for production use, building real AudioPlayer and AudioScheduler.
    /// (Actors don't support convenience initializers, so this is a separate designated init.)
    init(clock: any ClockSyncProtocol, config: PlayerConfiguration) {
        let audioScheduler = AudioScheduler(clockSync: clock)

        // Build AudioPlayer with the same configuration the client used to construct it.
        let pcmBufferCapacity = max(config.bufferCapacity / 2, 131_072) // min 128KB
        let audioPlayer = AudioPlayer(
            pcmBufferCapacity: pcmBufferCapacity,
            volumeControl: VolumeControlFactory.resolve(mode: config.volumeMode).control,
            processCallback: config.processCallback
        )

        output = audioPlayer
        self.audioScheduler = audioScheduler
        self.clock = clock
        let sink = DataPlaneSink()
        _commandsSink = sink
        _commandStream = sink.commands
        let (reportStream, reportContinuation) = AsyncStream<EngineReport>.makeStream()
        self.reportStream = reportStream
        self.reportContinuation = reportContinuation
    }

    // MARK: - Public interface

    /// The data-plane sink where commands are enqueued by the client message loop.
    nonisolated var commands: DataPlaneSink {
        _commandsSink
    }

    /// The report stream where the engine emits lifecycle and state transitions.
    ///
    /// Contract: a consumer must be draining this stream whenever the engine is
    /// running, or reports buffer unboundedly. `SendspinConnection` satisfies it
    /// structurally — `reportDrain()` is a sibling of `messageLoop()` in the
    /// supervisor task group and the engine only starts inside `messageLoop()`,
    /// so the engine never runs undrained.
    nonisolated var reports: AsyncStream<EngineReport> {
        reportStream
    }

    /// Record of command kinds applied, for test assertions about processing order.
    func appliedCommandKinds() -> [DataPlaneCommandKind] {
        appliedKinds
    }

    /// Whether underrun telemetry is currently enabled for playback participation.
    /// Internal testing/diagnostic seam; production callers drive this through
    /// ``setExternalSource(_:)``.
    func isParticipatingInPlaybackForTesting() -> Bool {
        participatingInPlayback
    }

    // MARK: - Lifecycle

    /// Start the engine and spawn all three owned tasks.
    /// Idempotent, and single-use: start() after shutdown() is a no-op —
    /// the streams are finished, so a respawned telemetry task would be a
    /// zombie driving a closed output.
    func start() {
        guard !running, !shuttingDown else { return }
        running = true

        // Drain task consumes commands and applies them
        drainTask = Task {
            for await command in _commandStream {
                appliedKinds.append(command.kind)
                await apply(command)
                _commandsSink.decrementDepth()
            }
        }

        // Scheduler output task consumes ScheduledChunk and applies format changes
        schedulerOutputTask = Task {
            await runSchedulerOutput()
        }

        // Telemetry task polls reanchor, underrun, and logs periodically
        telemetryTask = Task {
            await runSyncCorrectionAndTelemetry()
        }
    }

    /// Shutdown the engine and terminate all three tasks.
    /// Must be called to clean up resources. Idempotent.
    func shutdown() async {
        guard running else { return }
        running = false

        // 1. Set shuttingDown to make buffered commands no-ops
        shuttingDown = true

        // 2. Stop accepting new commands
        _commandsSink.finish()

        // 3. Wait for the drain task to consume all buffered commands (and become no-ops)
        if let task = drainTask {
            await task.value
        }

        // 4. Stop the output immediately (any buffered playPCM becomes harmless)
        await output.stop()

        // 5. Finish the scheduler and clear its queue
        await audioScheduler.finish()
        await audioScheduler.clear()

        // 6. Cancel the telemetry task (its loop is `while !Task.isCancelled`)
        telemetryTask?.cancel()

        // 7. Wait for scheduler-output and telemetry tasks to end
        if let task = schedulerOutputTask {
            await task.value
        }
        if let task = telemetryTask {
            await task.value
        }

        // 8. Finish the reports stream
        reportContinuation.finish()
    }

    // MARK: - Volume and timing (direct routes, not wire-ordered)

    /// Set playback gain. Direct route to output (not via data plane).
    func setGain(_ gain: Float) async {
        await output.setVolume(gain)
    }

    /// Set the user/server-visible mute state. Direct route to output, OR'd with
    /// the safety mute (spec §Playback Synchronization: mute while in `error`).
    func setMuted(_ muted: Bool) async {
        userMuted = muted
        await applyEffectiveMute()
    }

    /// The output is muted if the user muted OR the engine safety-muted on a
    /// sync error. Keeping the two separate means error recovery cannot unmute
    /// a user-muted player, and a user unmute cannot defeat the safety mute.
    private func applyEffectiveMute() async {
        await output.setMute(userMuted || errorMuted)
    }

    /// Update the clock snapshot for sync correction. Direct route to output.
    /// This preserves the per-server/time cross-boundary push.
    func updateClockSnapshot(_ snapshot: TimeFilterSnapshot) async {
        await output.updateTimeSnapshot(snapshot)
    }

    /// Set whether this client is participating in playback (not external source).
    /// When external source is active (active: true), underrun telemetry is suppressed.
    ///
    /// Entering external source clears the safety mute: the telemetry loop drops
    /// its tracked error without a `.toSynchronized` transition (`resetBaseline`),
    /// so without this the output would return from external source permanently
    /// silenced.
    func setExternalSource(_ active: Bool) async {
        participatingInPlayback = !active
        if active, errorMuted {
            errorMuted = false
            await applyEffectiveMute()
        }
    }

    // MARK: - Command application

    /// Apply a single command, updating engine state and emitting reports as needed.
    private func apply(_ command: DataPlaneCommand) async {
        guard !shuttingDown else { return }

        switch command {
        case let .streamStart(format, codecHeader):
            await applyStreamStart(format: format, codecHeader: codecHeader)

        case let .chunk(data, ts):
            await applyChunk(data: data, ts: ts)

        case let .formatChange(format, codecHeader):
            await applyFormatChange(format: format, codecHeader: codecHeader)

        case let .streamClear(roles):
            await applyStreamClear(roles: roles)

        case let .streamEnd(roles):
            await applyStreamEnd(roles: roles)

        case let .setStaticDelay(delayMs):
            staticDelayMs = delayMs
        }
    }

    /// Start a new stream: init decoder, start output, spawn scheduler.
    private func applyStreamStart(format: AudioFormatSpec, codecHeader: Data?) async {
        do {
            try await output.start(format: format, codecHeader: codecHeader)
            await audioScheduler.startScheduling()
            yield(.started(format))
        } catch {
            yield(.startFailed(reason: error.localizedDescription))
        }
    }

    /// Schedule a chunk for playback.
    private func applyChunk(data: Data, ts: Int64) async {
        do {
            let pcm = try await output.decode(data)
            let adjustedTs = ts - Int64(staticDelayMs) * 1_000
            await audioScheduler.schedule(pcm: pcm, serverTimestamp: adjustedTs, generation: streamGeneration)
        } catch {
            // Per-chunk decode failures are silent; stream-start failures are reported separately.
            Log.audio.debug("Chunk decode failed: \(error.localizedDescription)")
        }
    }

    /// Apply a seamless format change (engine-internal, no MainActor.run).
    private func applyFormatChange(format: AudioFormatSpec, codecHeader: Data?) async {
        streamGeneration &+= 1
        pendingFormat = format
        pendingCodecHeader = codecHeader
        do {
            try await output.swapDecoder(format: format, codecHeader: codecHeader)
            // On success, .formatApplied is yielded when runSchedulerOutput processes
            // the first new-generation chunk (the deferred AudioQueue rebuild).
        } catch {
            // Swap failed: fall back to a full restart so new-format chunks are not
            // decoded by the stale decoder. The deferred rebuild is now moot, so
            // clear the pending transition and surface the format directly here.
            Log.audio.error("Decoder swap failed, full restart: \(error.localizedDescription)")
            pendingFormat = nil
            pendingCodecHeader = nil
            do {
                try await output.start(format: format, codecHeader: codecHeader)
                yield(.formatApplied(format))
            } catch {
                yield(.startFailed(reason: error.localizedDescription))
            }
        }
    }

    /// Clear buffered audio.
    private func applyStreamClear(roles: [String]?) async {
        let shouldClear = roles == nil || roles?.contains("player") ?? false
        if shouldClear {
            await audioScheduler.clear()
            await output.clearBuffer()
        }
    }

    /// End the stream, truncating unplayed audio.
    private func applyStreamEnd(roles: [String]?) async {
        let shouldEnd = roles == nil || roles?.contains("player") ?? false
        if shouldEnd {
            await audioScheduler.stop()
            await audioScheduler.clear()
            await output.stop()
        }
    }

    /// Emit a report to the reports stream.
    private nonisolated func yield(_ report: EngineReport) {
        reportContinuation.yield(report)
    }

    // MARK: - Scheduler output loop

    /// Consumes scheduled chunks, detects generation changes, and applies seamless format changes.
    private func runSchedulerOutput() async {
        // Seeded at the engine's initial generation (0); the field tracks the latest
        // generation seen on the scheduled-chunk stream as format changes bump it.
        var currentGeneration: UInt64 = 0

        // ONE iterator over the single-consumer `scheduledChunks` stream. The
        // format-transition pre-buffer continues pulling from this SAME iterator
        // (state machine below) rather than opening a second `for await`: a
        // second iterator over an AsyncStream is unsupported and left
        // `shutdown()`'s `await schedulerOutputTask` hanging when
        // `audioScheduler.finish()` fired mid-transition.
        let stream = audioScheduler.scheduledChunks
        var iterator = stream.makeAsyncIterator()

        while let chunk = await iterator.next() {
            if chunk.generation != currentGeneration {
                if chunk.generation < currentGeneration {
                    // Old generation after format change; discard
                    continue
                }

                // New generation — first chunk in new format
                currentGeneration = chunk.generation

                // Read the pending format engine-internally (no MainActor.run)
                guard let format = pendingFormat else {
                    try? await output.playPCM(chunk.pcmData, serverTimestamp: chunk.originalTimestamp)
                    continue
                }

                // Report the format applied at the commitment point — the first
                // new-generation chunk — NOT gated on the audio-rebuild pre-buffer
                // below. A brief change with fewer than `formatTransitionPreBuffer`
                // trailing chunks must still surface .formatApplied (and update the
                // client's currentStreamFormat); the pre-buffer can otherwise block
                // on iterator.next() awaiting a chunk that never arrives.
                yield(.formatApplied(format))

                // Pre-buffer before switching, pulling from the same iterator.
                var preBuffer: [(pcm: Data, timestamp: Int64)] = [
                    (chunk.pcmData, chunk.originalTimestamp)
                ]

                let formatTransitionPreBuffer = 2
                while preBuffer.count < formatTransitionPreBuffer, let nextChunk = await iterator.next() {
                    preBuffer.append((nextChunk.pcmData, nextChunk.originalTimestamp))
                }

                // Rebuild AudioQueue
                Log.audio.info("Seamless switch: rebuilding AudioQueue at \(format.sampleRate)Hz (pre-buffered \(preBuffer.count) chunks)")
                do {
                    try await output.start(format: format, codecHeader: pendingCodecHeader)
                } catch {
                    // A failed deferred rebuild would otherwise be silent — the
                    // .formatApplied above already reported the change, so the client
                    // would believe the format switched while audio stops. Surface it
                    // so the client enters error/recovery, matching applyStreamStart
                    // and applyFormatChange. Skip feeding a queue that failed to start.
                    Log.audio.error("Seamless rebuild failed: \(error.localizedDescription)")
                    yield(.startFailed(reason: error.localizedDescription))
                    pendingFormat = nil
                    pendingCodecHeader = nil
                    continue
                }

                // Feed pre-buffered chunks
                for buffered in preBuffer {
                    try? await output.playPCM(buffered.pcm, serverTimestamp: buffered.timestamp)
                }

                pendingFormat = nil
                pendingCodecHeader = nil

                continue
            }

            try? await output.playPCM(chunk.pcmData, serverTimestamp: chunk.originalTimestamp)
        }
    }

    /// Polls reanchor requests and emits operational-state reports via the UnderrunMonitor.
    private func runSyncCorrectionAndTelemetry() async {
        var lastTelemetryStats = SchedulerStats()
        var tickCount = 0
        var underrunMonitor = UnderrunMonitor()

        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            tickCount += 1

            // Poll for reanchor
            if let reanchorTarget = await output.pollReanchor() {
                await output.reanchorCursor(to: reanchorTarget)
            }

            let tSnap = await output.telemetrySnapshot

            // Observe underruns and emit state transitions, unless external source is active
            if participatingInPlayback {
                let transition = underrunMonitor.observe(underrunCount: tSnap.underrunCount)
                switch transition {
                case .none:
                    break
                case .toError:
                    operationalState = .error
                    // Spec: mute the output while unable to maintain sync.
                    errorMuted = true
                    await applyEffectiveMute()
                    yield(.operationalState(.error))
                case .toSynchronized:
                    operationalState = .synchronized
                    errorMuted = false
                    await applyEffectiveMute()
                    yield(.operationalState(.synchronized))
                }
            } else {
                // While external source is active, re-baseline underrun count and emit nothing
                underrunMonitor.resetBaseline(underrunCount: tSnap.underrunCount)
            }

            // Telemetry logging (every 2s = every 4 ticks at 500ms)
            if tickCount % 4 == 0 {
                let currentStats = await audioScheduler.stats
                guard currentStats.received > 0 else { continue }

                guard let syncSnap = await clock.diagnosticSnapshot() else { continue }

                let framesScheduled = currentStats.received - lastTelemetryStats.received
                let framesPlayed = currentStats.played - lastTelemetryStats.played
                let framesDroppedLate = currentStats.droppedLate - lastTelemetryStats.droppedLate

                let clockOffsetMs = Double(syncSnap.offset) / 1_000.0
                let rttMs = Double(syncSnap.rtt) / 1_000.0
                let estErrUs = Int64(syncSnap.estimatedError.rounded())
                let driftPpm = syncSnap.drift * 1_000_000.0

                let syncErrorUs = tSnap.syncErrorUs
                let dropN = tSnap.correctionSchedule.dropEveryNFrames
                let insertN = tSnap.correctionSchedule.insertEveryNFrames
                let correcting = tSnap.correctionSchedule.isCorrecting

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
                Log.audio.debug("\(telemetry, privacy: .public)")

                lastTelemetryStats = currentStats
            }
        }
    }
}
