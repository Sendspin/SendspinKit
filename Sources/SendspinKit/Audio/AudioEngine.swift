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

    // Diagnostics: command kinds for processing-order test assertions. Bounded because
    // this is appended on the production drain path (~50/s of `.chunk` alone).
    private var appliedKinds: [DataPlaneCommandKind] = []

    static let appliedKindsRetentionLimit = 512

    /// How long a pending startup release may sleep before re-evaluating.
    ///
    /// A re-check interval, not a deadline: a chunk due further out than this sleeps
    /// again, so a legitimately distant schedule still plays on time and to the
    /// microsecond (the final sleep is the exact remaining time). The bound exists only
    /// so a saturated play time — which clears the overflow guards in
    /// ``startupReleaseCandidate`` yet names an instant millennia away — cannot commit
    /// the startup path for the life of the process.
    ///
    /// Matches `AudioScheduler`'s default playback window, which bounds its own
    /// per-chunk sleep for the same reason. That path re-checks at this rate for the
    /// whole of playback, so it is comfortably cheap for a once-per-stream path.
    static let startupRecheckIntervalUs: Int64 = 50_000

    /// Ceiling on chunks retained while waiting to release. Waiting is legitimate
    /// (joining a stream in progress), and `applyChunk` appends on every arrival, so
    /// a stream that never becomes releasable would otherwise grow this unbounded.
    static let startupChunkRetentionLimit = 2_048

    /// Distance from the release instant at which sleeping gives way to yielding.
    ///
    /// Timer overshoot scales with the sleep — ~7%, so 2.4ms for a 34ms one — and even a
    /// sub-millisecond sleep lands outside ``CorrectionPlanner/defaultEngageUs``. Overshoot
    /// is skew the sync corrector then has to remove, so the final approach is yielded
    /// rather than slept.
    ///
    /// Must exceed the overshoot of a full ``startupRecheckIntervalUs`` hop (~3.5ms), or the
    /// last sleep jumps the instant and leaves nothing to yield through.
    static let startupSpinThresholdUs: Int64 = 8_000

    /// How long to sleep before re-evaluating a pending startup release.
    ///
    /// Stops ``startupSpinThresholdUs`` short of the release instant, leaving the final
    /// approach to ``yieldUntilReleaseInstant(_:)``; returns 0 once already inside that
    /// window. Hops are capped at ``startupRecheckIntervalUs`` so a distant or
    /// unrepresentable schedule yields a wait that ends and gets re-examined.
    static func startupWaitMicroseconds(releaseTimeUs: Int64, nowUs: Int64) -> Int64 {
        let remaining = releaseTimeUs.subtractingReportingOverflow(nowUs)
        guard !remaining.overflow else { return startupRecheckIntervalUs }
        // Clamping before subtracting keeps the subtraction unconditionally safe: `pending`
        // is non-negative and the threshold positive.
        let pending = max(remaining.partialValue, 0)
        guard pending > startupSpinThresholdUs else { return 0 }
        return min(pending - startupSpinThresholdUs, startupRecheckIntervalUs)
    }

    /// Close the last ``startupSpinThresholdUs`` before a release instant by yielding.
    ///
    /// Yielding polls the clock at microsecond cost while still suspending, so this lands
    /// within a few microseconds where no sleep can, and the engine keeps draining its
    /// command queue throughout. Runs on the deadline task rather than inside an
    /// actor-isolated method, so it never holds the engine between polls.
    ///
    /// The budget is a guard against a non-advancing clock only: the entry check bounds the
    /// distance to ``startupSpinThresholdUs``, so a monotonic clock always reaches the release
    /// instant first. Normal operation never reaches it.
    static func yieldUntilReleaseInstant(_ releaseTimeUs: Int64) async {
        let entry = MonotonicClock.absoluteMicroseconds()
        let distance = releaseTimeUs.subtractingReportingOverflow(entry)
        // Only the final approach is yielded through; a still-distant instant belongs to the
        // next sleep hop.
        guard !distance.overflow, distance.partialValue <= startupSpinThresholdUs else { return }
        let budget = entry.addingReportingOverflow(startupSpinThresholdUs * 4)
        let giveUpAt = budget.overflow ? Int64.max : budget.partialValue
        while !Task.isCancelled {
            let now = MonotonicClock.absoluteMicroseconds()
            if now >= releaseTimeUs || now >= giveUpAt {
                return
            }
            await Task.yield()
        }
    }

    /// Whether to use the prepared-start path. Test-injected engines default this
    /// off to preserve direct scheduler observability; production engines use it
    /// to locally prime the initial `min_buffer_ms` span before output starts.
    /// `required_lead_time_ms` remains an advertised server send-ahead contract,
    /// not a second local release-span gate.
    private let startupBufferingEnabled: Bool
    private let startupMinBufferUs: Int64
    private var startupBuffer: StartupBuffer?
    private var startupDeadlineTask: Task<Void, Never>?
    /// Identifies the current wait. `Task` is not `Equatable`, so without this a
    /// continuation cannot ask whether the stored handle still refers to it — and the stream
    /// sequence cannot answer that, because every wait within one stream shares a sequence.
    private var startupDeadlineToken: UInt64 = 0
    /// Startup-release evaluations for the current stream. Internal so a test can prove the
    /// wait sleeps rather than polls; a polling wait reaches five figures per stream start.
    private(set) var startupReleaseEvaluations = 0
    private var startupSequence: UInt64 = 0
    private var outputHasStarted = false

    private struct StartupBuffer {
        let sequence: UInt64
        let format: AudioFormatSpec
        let startupLeadUs: Int64
        var chunks: [StartupBufferedChunk] = []
    }

    /// What a timer-driven re-entry needs in order to identify itself: which wait it is,
    /// which stream it belongs to, and the instant it waited for.
    private struct DeadlineArm: Sendable {
        let sequence: UInt64
        let token: UInt64
        let releaseTimeUs: Int64
    }

    private struct StartupBufferedChunk {
        let pcmData: Data
        let playTimeMicroseconds: Int64
        let originalTimestamp: Int64
        let generation: UInt64
    }

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

    /// Suppress underrun→`error` reporting until this instant after a fresh
    /// AudioQueue start. Priming an empty ring buffer plus the initial buffer
    /// fill produce a deterministic burst of underruns (observed: ~6 spread over
    /// ~2s on a healthy stream) that are a startup artifact, not a sync failure —
    /// without this window the client flaps `synchronized`↔`error` on every
    /// `stream/start`, and (worse than no window) a mute landing mid-playback is an
    /// audible dropout. The window must comfortably outlast the prime burst; 3s
    /// gives margin over the observed ~2s. Real sync failures keep accruing
    /// underruns and are caught once the window closes.
    private var underrunGraceDeadline: ContinuousClock.Instant?
    private static let underrunGraceWindow: Duration = .milliseconds(3_000)

    /// Pick the first buffered chunk we can still start on, and when to start it.
    ///
    /// Startup is governed by the server's schedule, not by a local accumulation target:
    /// the server already schedules the first chunk at least `min_buffer_ms +
    /// static_delay_ms` ahead, and `min_buffer_ms` is a request for *ongoing* buffer depth
    /// during playback, not a precondition for starting. Our job is to be ready when the
    /// first playable chunk is due.
    ///
    /// Gating on accumulated span instead would wedge two legitimate cases forever: a
    /// stream shorter than the requested buffer, and any stream whose `buffer_capacity`
    /// caps queued duration below `min_buffer_ms` (which the spec explicitly permits for
    /// high byte-rate codecs).
    ///
    /// Chunks whose start moment has already passed beyond `latenessToleranceUs` are
    /// skipped — joining a stream in progress, they can no longer be played in full.
    static func startupReleaseCandidate(
        playTimes: [Int64],
        nowUs: Int64,
        startupLeadUs: Int64,
        latenessToleranceUs: Int64 = CorrectionPlanner.defaultEngageUs
    ) -> (index: Int, releaseTimeUs: Int64)? {
        for (index, playTime) in playTimes.enumerated() {
            // `playTime` derives from `serverTimeToLocal`, which saturates instead of
            // trapping, so a malformed wire timestamp reaches this loop sitting near the
            // Int64 bounds. Overflow here means the value is not a schedule at all —
            // skip it rather than trap or hand back a nonsense release instant.
            let releaseTime = playTime.subtractingReportingOverflow(startupLeadUs)
            guard !releaseTime.overflow else { continue }
            let lateness = nowUs.subtractingReportingOverflow(releaseTime.partialValue)
            guard !lateness.overflow else { continue }
            if lateness.partialValue <= latenessToleranceUs {
                return (index, releaseTime.partialValue)
            }
        }
        return nil
    }

    /// Cancel any pending startup wait and invalidate its arm, so a continuation already past
    /// its sleep cannot act on a schedule that no longer applies. Cancellation alone does not
    /// achieve that: it is cooperative, and a task past its last suspension point runs on.
    private func cancelStartupDeadline() {
        startupDeadlineTask?.cancel()
        startupDeadlineTask = nil
        startupDeadlineToken &+= 1
    }

    /// Pick the chunk to start on, honouring a wait already made for one.
    ///
    /// A wait that has come due releases the chunk it was armed for, without re-testing
    /// lateness. ``startupReleaseCandidate``'s tolerance is for chunks already unplayable when
    /// first examined — joining a stream in progress — and a chunk this engine waited for
    /// deliberately is not one: charging it for the cost of the wake slides the start to the
    /// next chunk, and a live stream always has a next one.
    static func releaseSelection(
        playTimes: [Int64],
        nowUs: Int64,
        startupLeadUs: Int64,
        awaitedReleaseTimeUs: Int64?
    ) -> (index: Int, releaseTimeUs: Int64)? {
        if let awaited = awaitedReleaseTimeUs, nowUs >= awaited {
            for (index, playTime) in playTimes.enumerated() {
                let releaseTime = playTime.subtractingReportingOverflow(startupLeadUs)
                guard !releaseTime.overflow else { continue }
                if releaseTime.partialValue == awaited {
                    return (index, awaited)
                }
            }
        }
        return startupReleaseCandidate(
            playTimes: playTimes,
            nowUs: nowUs,
            startupLeadUs: startupLeadUs
        )
    }

    /// Re-arm the startup underrun grace window. Called after every successful
    /// `output.start(...)` (full stream start and the format-change fallback).
    private func armUnderrunGrace() {
        underrunGraceDeadline = ContinuousClock.now.advanced(by: Self.underrunGraceWindow)
    }

    /// Decide the startup underrun-grace action for one telemetry tick. Pure so the
    /// gap-free boundary behavior is unit-testable without wall-clock waits.
    ///
    /// While the window is open the caller must ABSORB (rebaseline the underrun
    /// monitor and skip observation). The expiry tick — `now >= deadline` — STILL
    /// absorbs (closing the gap where a prime underrun landing at the boundary would
    /// otherwise leak into the first real `observe()` and trip a spurious mute) and
    /// clears the deadline, so the first tick AFTER the window monitors from a fully
    /// settled baseline.
    static func underrunGraceTick(
        deadline: ContinuousClock.Instant?,
        now: ContinuousClock.Instant
    ) -> (absorb: Bool, deadline: ContinuousClock.Instant?) {
        guard let deadline else { return (absorb: false, deadline: nil) }
        return (absorb: true, deadline: now >= deadline ? nil : deadline)
    }

    // MARK: - Initialization

    /// Designated internal initializer for testing with injected output and clock.
    init(
        output: any AudioOutput,
        scheduler: AudioScheduler,
        clock: any ClockSyncProtocol,
        enableStartupBuffering: Bool = false,
        startupMinBufferMs: Int = 0
    ) {
        self.output = output
        audioScheduler = scheduler
        self.clock = clock
        let sink = DataPlaneSink()
        _commandsSink = sink
        _commandStream = sink.commands
        let (reportStream, reportContinuation) = AsyncStream<EngineReport>.makeStream()
        self.reportStream = reportStream
        self.reportContinuation = reportContinuation
        startupBufferingEnabled = enableStartupBuffering
        startupMinBufferUs = Int64(startupMinBufferMs) * 1_000
    }

    /// Secondary initializer for production use, building real AudioPlayer and AudioScheduler.
    /// (Actors don't support convenience initializers, so this is a separate designated init.)
    init(clock: any ClockSyncProtocol, config: PlayerConfiguration) {
        let audioScheduler = AudioScheduler(
            clockSync: clock,
            releaseLeadTime: TimeInterval(config.minBufferMs) / 1_000.0
        )

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
        startupBufferingEnabled = true
        startupMinBufferUs = Int64(config.minBufferMs) * 1_000
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
                if appliedKinds.count > Self.appliedKindsRetentionLimit {
                    // Trim in batches; removeFirst(1) on an Array is O(n).
                    appliedKinds.removeFirst(appliedKinds.count - Self.appliedKindsRetentionLimit / 2)
                }
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
        cancelStartupDeadline()
        startupBuffer = nil
        startupSequence &+= 1
        outputHasStarted = false
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

    /// Start a new stream: init decoder, then either start immediately (test path)
    /// or prepare the backend and wait for startup lead-time/min-buffer priming.
    private func applyStreamStart(format: AudioFormatSpec, codecHeader: Data?) async {
        cancelStartupDeadline()
        startupBuffer = nil
        startupSequence &+= 1
        startupReleaseEvaluations = 0

        do {
            if startupBufferingEnabled {
                try await output.prepare(format: format, codecHeader: codecHeader)
                outputHasStarted = false
                startupBuffer = await StartupBuffer(
                    sequence: startupSequence,
                    format: format,
                    startupLeadUs: output.startupLeadMicroseconds()
                )
                await audioScheduler.stop()
                await audioScheduler.clear()
            } else {
                try await output.start(format: format, codecHeader: codecHeader)
                outputHasStarted = true
                armUnderrunGrace()
                await audioScheduler.startScheduling()
                yield(.started(format))
            }
        } catch {
            startupBuffer = nil
            yield(.startFailed(reason: error.localizedDescription))
        }
    }

    /// Schedule a chunk for playback.
    private func applyChunk(data: Data, ts: Int64) async {
        do {
            let pcm = try await output.decode(data)
            // `ts` is unvalidated wire data; a hostile or buggy server can put it near
            // the Int64 bounds where the delay adjustment would trap.
            let delayed = ts.subtractingReportingOverflow(Int64(staticDelayMs) * 1_000)
            guard !delayed.overflow else {
                Log.audio.warning("Dropping chunk with an unrepresentable timestamp")
                return
            }
            let adjustedTs = delayed.partialValue
            if startupBuffer != nil {
                let playTime = await clock.serverTimeToLocal(adjustedTs)
                if startupBuffer != nil {
                    if let depth = startupBuffer?.chunks.count, depth >= Self.startupChunkRetentionLimit {
                        // Drop the oldest instead of the newest: the oldest is the most
                        // likely to already be unplayable, and the newest is what lets a
                        // stalled startup finally find a viable release point.
                        startupBuffer?.chunks.removeFirst()
                    }
                    startupBuffer?.chunks.append(StartupBufferedChunk(
                        pcmData: pcm,
                        playTimeMicroseconds: playTime,
                        originalTimestamp: adjustedTs,
                        generation: streamGeneration
                    ))
                    await releaseStartupBufferIfReady()
                } else {
                    await audioScheduler.schedule(
                        pcm: pcm,
                        serverTimestamp: adjustedTs,
                        playTimeMicroseconds: playTime,
                        generation: streamGeneration
                    )
                }
            } else {
                await audioScheduler.schedule(pcm: pcm, serverTimestamp: adjustedTs, generation: streamGeneration)
            }
        } catch {
            // Per-chunk decode failures are silent; stream-start failures are reported separately.
            Log.audio.debug("Chunk decode failed: \(error.localizedDescription)")
        }
    }

    /// Release the startup buffer when starting AudioQueue now will naturally land
    /// the first sample near its server timestamp. The release feeds decoded PCM into
    /// the ring before starting AudioQueue, then hands any future chunks back to the scheduler.
    private func releaseStartupBufferIfReady(arm: DeadlineArm? = nil) async {
        startupReleaseEvaluations += 1
        guard var buffer = startupBuffer, !buffer.chunks.isEmpty else { return }
        if let arm {
            guard buffer.sequence == arm.sequence, arm.token == startupDeadlineToken else {
                // A superseded wait: a newer arrival re-armed, or the stream was replaced.
                // The arm that superseded this one owns the handle, so leave it untouched.
                return
            }
            // This call runs on the task the handle refers to, and its wait is over. Clearing
            // the handle first keeps the re-arm below from cancelling the task it runs on.
            startupDeadlineTask = nil
        }
        buffer.chunks.sort { $0.playTimeMicroseconds < $1.playTimeMicroseconds }

        // Releasing into a device that has not begun producing hands PCM to a pipeline that
        // is not consuming: it sits in the ring and plays stale by however long the device
        // took. Keep buffering instead — `applyChunk` re-enters here on every arrival, so a
        // device that wakes late simply starts late rather than starting wrong.
        guard await output.outputDeviceIsLive else {
            Log.audio.debug("startup release deferred: output device not yet producing")
            startupBuffer = buffer
            cancelStartupDeadline()
            return
        }

        let nowUs = MonotonicClock.absoluteMicroseconds()
        let playTimes = buffer.chunks.map(\.playTimeMicroseconds)
        let candidate = Self.releaseSelection(
            playTimes: playTimes,
            nowUs: nowUs,
            startupLeadUs: buffer.startupLeadUs,
            awaitedReleaseTimeUs: arm?.releaseTimeUs
        )

        // Nil when every buffered chunk is already too late to start on. The spec permits
        // chunks to arrive past-dated after network delay or buffering (a compliant server
        // sends late joiners future timestamps only, so this is not the join case).
        //
        // Deliberately no timer here: re-evaluating cannot change the answer, because
        // advancing `nowUs` only makes these chunks staler. Only a newly arrived,
        // future-dated chunk can, and `applyChunk` re-enters this method on every append.
        //
        // Logged because no playback counter can show it: a stream that never releases reports
        // no lateness, no underruns and no drops. It is simply silent.
        guard let candidate else {
            Log.audio.warning("startup release found no viable chunk (buffered=\(buffer.chunks.count))")
            startupBuffer = buffer
            cancelStartupDeadline()
            return
        }
        if candidate.index > 0 {
            buffer.chunks.removeFirst(candidate.index)
        }
        let firstPlayTime = buffer.chunks[0].playTimeMicroseconds
        let lastPlayTime = buffer.chunks[buffer.chunks.count - 1].playTimeMicroseconds
        let startTime = candidate.releaseTimeUs
        guard nowUs >= startTime else {
            startupBuffer = buffer
            cancelStartupDeadline()
            let delayUs = Self.startupWaitMicroseconds(releaseTimeUs: startTime, nowUs: nowUs)
            startupDeadlineToken &+= 1
            let arm = DeadlineArm(
                sequence: buffer.sequence,
                token: startupDeadlineToken,
                releaseTimeUs: startTime
            )
            startupDeadlineTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .microseconds(delayUs))
                } catch {
                    // A superseded wait ends here; the arm that replaced it owns the handle.
                    // Continuing arms a further replacement instead, polling the schedule.
                    return
                }
                await Self.yieldUntilReleaseInstant(startTime)
                await self?.releaseStartupBufferIfReady(arm: arm)
            }
            return
        }

        cancelStartupDeadline()
        startupBuffer = nil

        // Saturate rather than trap: `firstPlayTime` is wire-derived, and a horizon
        // pinned at Int64.max simply primes every buffered chunk, which is correct.
        let horizonSum = firstPlayTime.addingReportingOverflow(startupMinBufferUs)
        let releaseHorizon = horizonSum.overflow ? Int64.max : horizonSum.partialValue
        let startupTelemetry = "startup release chunks=\(buffer.chunks.count)"
            + " span=\(lastPlayTime.subtractingReportingOverflow(firstPlayTime).partialValue)us"
            + " min=\(startupMinBufferUs)us"
            + " lateness=\(nowUs.subtractingReportingOverflow(startTime).partialValue)us"
        Log.audio.debug("\(startupTelemetry, privacy: .public)")

        do {
            for chunk in buffer.chunks where chunk.playTimeMicroseconds <= releaseHorizon {
                try await output.playPCM(chunk.pcmData, serverTimestamp: chunk.originalTimestamp)
            }

            try await output.startPrepared()
            outputHasStarted = true
            armUnderrunGrace()
            await audioScheduler.startScheduling()
            yield(.started(buffer.format))
        } catch {
            await output.stop()
            outputHasStarted = false
            yield(.startFailed(reason: error.localizedDescription))
            return
        }

        for chunk in buffer.chunks where chunk.playTimeMicroseconds > releaseHorizon {
            await audioScheduler.schedule(
                pcm: chunk.pcmData,
                serverTimestamp: chunk.originalTimestamp,
                playTimeMicroseconds: chunk.playTimeMicroseconds,
                generation: chunk.generation
            )
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
                outputHasStarted = true
                armUnderrunGrace()
                await audioScheduler.startScheduling()
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
            cancelStartupDeadline()
            if startupBuffer != nil {
                startupBuffer?.chunks.removeAll()
            }
            await audioScheduler.clear()
            await output.clearBuffer()
        }
    }

    /// End the stream, truncating unplayed audio.
    private func applyStreamEnd(roles: [String]?) async {
        let shouldEnd = roles == nil || roles?.contains("player") ?? false
        if shouldEnd {
            startupBuffer = nil
            cancelStartupDeadline()
            startupSequence &+= 1
            outputHasStarted = false
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
                    outputHasStarted = true
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
                // Startup grace: while a freshly-started AudioQueue is still
                // establishing its buffer, absorb the prime/fill underruns into the
                // baseline rather than reporting them as a sync `error`.
                //
                // Rebaseline on EVERY grace tick INCLUDING the tick on which the
                // window expires, then `continue`. Rebaselining only while
                // `now < deadline` and falling through to `observe()` on the expiry
                // tick leaves a gap: a prime underrun landing between the last
                // in-grace tick and expiry leaks into the first real `observe()` and
                // trips a spurious mute ~window-length into playback (an audible
                // mid-stream dropout). Absorbing through expiry closes that gap, so
                // real monitoring begins the first tick AFTER the window from a fully
                // settled baseline.
                let grace = Self.underrunGraceTick(deadline: underrunGraceDeadline, now: .now)
                underrunGraceDeadline = grace.deadline
                if grace.absorb {
                    underrunMonitor.resetBaseline(underrunCount: tSnap.underrunCount)
                    continue
                }

                let transition = underrunMonitor.observe(underrunCount: tSnap.underrunCount)
                switch transition {
                case .none:
                    break
                case .toError:
                    // Operational, app-owner-facing: sustained underruns past the
                    // monitor threshold force a protective mute. Logged at .notice so
                    // it surfaces in a user-collected diagnostic without debug logging.
                    Log.audio.notice(
                        "Audio sync lost: sustained buffer underruns — muting output (underruns=\(tSnap.underrunCount, privacy: .public))"
                    )
                    operationalState = .error
                    // Spec: mute the output while unable to maintain sync.
                    errorMuted = true
                    await applyEffectiveMute()
                    yield(.operationalState(.error))
                case .toSynchronized:
                    Log.audio.notice(
                        "Audio sync restored: buffer underruns cleared — unmuting output (underruns=\(tSnap.underrunCount, privacy: .public))"
                    )
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
                    // Buffer-health counters (cumulative): `underrun` is the ring
                    // running dry on read (output silence — audible dropouts);
                    // `pcmDrop` is bytes lost to ring overflow on write (the producer
                    // outrunning playback). A climbing `underrun` is the signal an app
                    // owner needs to diagnose stutter/pauses.
                    + " underrun=\(tSnap.underrunCount) pcmDrop=\(tSnap.pcmBytesDropped)"
                    // `sync` reads ~0 from grace expiry onward regardless of how far out
                    // playback actually started, because the rebaseline assigns the
                    // equilibrium. `startOffset` is that start error, and `spinUp` is the
                    // device's own delay before its first callback — the dominant term in it.
                    + " startOffset=\(tSnap.startupOffsetUs.map(String.init) ?? "pending")us"
                    + " spinUp=\(tSnap.spinUpUs)us"
                    + " startPad=\(tSnap.startupPadFrames)f"
                    + " inFlight=\(tSnap.framesInFlight)f"
                    // The one question no other counter answers: is anything audible at all.
                    + " peak=\(String(format: "%.4f", tSnap.peakOutputLevel))"
                    + " consumed=\(tSnap.framesConsumed)f silentBufs=\(tSnap.silentBuffers)"
                    + " enqFail=\(tSnap.enqueueFailures)"
                    + " gain=\(String(format: "%.2f", tSnap.appliedVolume))"
                    + " qGain=\(String(format: "%.2f", tSnap.queueGain))"
                    + " devVol=\(String(format: "%.2f", tSnap.deviceVolume))"
                    + " devMute=\(tSnap.deviceMuted)"
                Log.audio.debug("\(telemetry, privacy: .public)")

                lastTelemetryStats = currentStats
            }
        }
    }
}
