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

    /// Generation gate shared with the wire-facing connection. Format announcements must
    /// invalidate already-received chunks before the FIFO command drain reaches the format
    /// command; an actor-isolated counter would be too late for that boundary.
    private nonisolated let inputGeneration: OSAllocatedUnfairLock<UInt64>

    // Report egress
    private let reportStream: AsyncStream<EngineReport>
    private let reportContinuation: AsyncStream<EngineReport>.Continuation

    // Seamless format state (engine-isolated, no MainActor.run)
    private var pendingFormat: AudioFormatSpec?
    private var pendingCodecHeader: Data?
    private var pendingFormatGeneration: UInt64?
    private var streamGeneration: UInt64 = 0
    private var chunkTimingFormat: AudioFormatSpec?
    private var chunkTimingDiagnostics = ChunkTimingDiagnostics()
    private var playbackTimeline = AudioChunkPlaybackTimeline()
    private var playbackTimelineTransitionEnabled = false

    /// Output delay in milliseconds (subtracted from scheduled timestamps)
    private var outputDelayMs: Int = 0

    // Task tracking for shutdown
    private var drainTask: Task<Void, Never>?
    private var startupCoordinatorTask: Task<Void, Never>?
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
    private var startupFormat: AudioFormatSpec?
    private var startupLeadUs: Int64 = 0
    /// Chunks arriving after a release claims the startup buffer wait here until the
    /// prepared output is running. They must not enter the scheduler before `.started`.
    private var startupReleaseDeferredChunks: [StartupBufferedChunk] = []
    private var startupDeadlineTask: Task<Void, Never>?
    private var currentStartupDeadlineArm: DeadlineArm?
    /// Identifies the current wait. `Task` is not `Equatable`, so without this a
    /// continuation cannot ask whether the stored handle still refers to it — and the stream
    /// sequence cannot answer that, because every wait within one stream shares a sequence.
    private var startupDeadlineToken: UInt64 = 0

    private enum StartupSignal: Sendable {
        case stateChanged
        case deadline(DeadlineArm)
        case finished
    }

    /// Startup-release evaluations for the current stream. Kept internal for bounded-work
    /// diagnostics and tests.
    private(set) var startupReleaseEvaluations = 0
    /// Count of successful prepared-start commits for the current engine lifetime.
    private(set) var startupReleaseCommits = 0
    /// Count of deadline tasks armed for the current stream.
    private(set) var startupDeadlineArms = 0
    private var startupSequence: UInt64 = 0
    private var startupSignalPending: StartupSignal?
    private var startupStateChangedPending = false
    private var startupSignalContinuation: CheckedContinuation<StartupSignal, Never>?
    private var startupCoordinatorFinished = false
    private var startupReleaseInvocation: UInt64 = 0
    private var startupReleaseInProgress = false
    private var outputHasStarted = false
    private let engineID = UUID().uuidString

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
    private var operationalState: EngineSyncState = .synchronized

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
    /// output_delay_ms` ahead, and `min_buffer_ms` is a request for *ongoing* buffer depth
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
        currentStartupDeadlineArm = nil
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
        inputGeneration = OSAllocatedUnfairLock(initialState: 0)
        let (reportStream, reportContinuation) = AsyncStream<EngineReport>.makeStream()
        self.reportStream = reportStream
        self.reportContinuation = reportContinuation
        startupBufferingEnabled = enableStartupBuffering
        startupMinBufferUs = Int64(startupMinBufferMs) * 1_000
    }

    /// Secondary initializer for production use, building real AudioPlayer and AudioScheduler.
    /// (Actors don't support convenience initializers, so this is a separate designated init.)
    init(
        clock: any ClockSyncProtocol,
        config: PlayerConfiguration,
        outputTransitionCallback: (@Sendable (AudioOutputTransition) -> Void)? = nil
    ) {
        let audioScheduler = AudioScheduler(
            clockSync: clock,
            releaseLeadTime: TimeInterval(config.minBufferMs) / 1_000.0
        )

        // Build AudioPlayer with the same configuration the client used to construct it.
        let pcmBufferCapacity = max(config.bufferCapacity / 2, 131_072) // min 128KB
        let audioPlayer = AudioPlayer(
            pcmBufferCapacity: pcmBufferCapacity,
            volumeControl: VolumeControlFactory.resolve(mode: config.volumeMode).control,
            processCallback: config.processCallback,
            outputTransitionCallback: outputTransitionCallback
        )

        output = audioPlayer
        self.audioScheduler = audioScheduler
        self.clock = clock
        let sink = DataPlaneSink()
        _commandsSink = sink
        _commandStream = sink.commands
        inputGeneration = OSAllocatedUnfairLock(initialState: 0)
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

    /// Enqueue an inbound audio chunk tagged with the current wire generation.
    nonisolated func enqueueAudioChunk(data: Data, timestamp: Int64) {
        let generation = inputGeneration.withLock { $0 }
        _commandsSink.enqueue(.chunkAtGeneration(data, ts: timestamp, generation: generation))
    }

    /// Enqueue a format change with an ingress generation barrier.
    ///
    /// The barrier advances before the command enters the FIFO. Audio chunks that were already
    /// received but are still waiting in that FIFO therefore become stale immediately, rather
    /// than being decoded and scheduled while the engine waits to reach this command.
    nonisolated func enqueueFormatChange(format: AudioFormatSpec, codecHeader: Data?) {
        let generation = inputGeneration.withLock { value in
            value &+= 1
            return value
        }
        _commandsSink.enqueue(.formatChangeAtGeneration(format, codecHeader: codecHeader, generation: generation))
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

        startupCoordinatorFinished = false
        startupCoordinatorTask = Task {
            await runStartupCoordinator()
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
        finishStartupCoordinator()
        cancelStartupDeadline()
        startupBuffer = nil
        startupReleaseDeferredChunks.removeAll(keepingCapacity: true)
        startupReleaseInProgress = false
        startupSequence &+= 1
        outputHasStarted = false
        await output.stop()

        // 5. Finish the scheduler and clear its queue
        await audioScheduler.finish()
        await audioScheduler.clear()

        // 6. Cancel the telemetry task (its loop is `while !Task.isCancelled`)
        telemetryTask?.cancel()

        // 7. Wait for scheduler-output and telemetry tasks to end
        if let task = startupCoordinatorTask {
            await task.value
        }
        if let task = schedulerOutputTask {
            await task.value
        }
        if let task = telemetryTask {
            await task.value
        }

        // 8. Finish the reports stream
        reportContinuation.finish()
    }

    private func signalStartupCoordinator(_ signal: StartupSignal) {
        guard !startupCoordinatorFinished else { return }
        switch signal {
        case .stateChanged:
            startupStateChangedPending = true
        case .deadline:
            startupSignalPending = signal
        case .finished:
            startupSignalPending = signal
        }
        if let continuation = startupSignalContinuation {
            startupSignalContinuation = nil
            let pending = nextStartupSignal()
            continuation.resume(returning: pending)
        }
    }

    private func signalStartupDeadline(_ arm: DeadlineArm) {
        guard !startupCoordinatorFinished else { return }
        // A deadline is only meaningful if it is still the current arm. The coordinator checks
        // the token again before touching the buffer, so a stale wake cannot resurrect old work.
        guard arm.token == startupDeadlineToken else { return }
        signalStartupCoordinator(.deadline(arm))
    }

    private func finishStartupCoordinator() {
        startupCoordinatorFinished = true
        startupSignalPending = .finished
        startupStateChangedPending = false
        startupSignalContinuation?.resume(returning: .finished)
        startupSignalContinuation = nil
    }

    private func nextStartupSignal() -> StartupSignal {
        if let pending = startupSignalPending {
            startupSignalPending = nil
            return pending
        }
        if startupStateChangedPending {
            startupStateChangedPending = false
            return .stateChanged
        }
        return .finished
    }

    private func waitForStartupSignal() async -> StartupSignal {
        if startupCoordinatorFinished {
            return .finished
        }
        if startupSignalPending != nil || startupStateChangedPending {
            return nextStartupSignal()
        }
        return await withCheckedContinuation { continuation in
            startupSignalContinuation = continuation
        }
    }

    private func runStartupCoordinator() async {
        while !startupCoordinatorFinished {
            let signal = await waitForStartupSignal()
            switch signal {
            case .stateChanged:
                // Once a release instant is armed, arrivals only extend the owned buffer.
                // They must not re-select the startup anchor: doing so can keep sliding the
                // deadline on a late join until the server ends the stream. The deadline task
                // is the sole owner of that wait and re-evaluates lateness when it fires.
                guard currentStartupDeadlineArm == nil else { continue }
                await releaseStartupBufferIfReady()
            case let .deadline(arm):
                await releaseStartupBufferIfReady(arm: arm)
            case .finished:
                return
            }
        }
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
            await applyChunk(data: data, ts: ts, generation: nil)

        case let .chunkAtGeneration(data, ts, generation):
            guard generation == inputGeneration.withLock({ $0 }), generation == streamGeneration else { return }
            await applyChunk(data: data, ts: ts, generation: generation)

        case let .formatChange(format, codecHeader):
            await applyFormatChange(format: format, codecHeader: codecHeader, generation: nil)

        case let .formatChangeAtGeneration(format, codecHeader, generation):
            guard generation == inputGeneration.withLock({ $0 }) else { return }
            await applyFormatChange(format: format, codecHeader: codecHeader, generation: generation)

        case let .streamClear(roles):
            await applyStreamClear(roles: roles)

        case let .streamEnd(roles):
            await applyStreamEnd(roles: roles)

        case let .setOutputDelay(delayMs):
            outputDelayMs = delayMs
        }
    }

    /// Start a new stream: init decoder, then either start immediately (test path)
    /// or prepare the backend and wait for startup lead-time/min-buffer priming.
    private func applyStreamStart(format: AudioFormatSpec, codecHeader: Data?) async {
        cancelStartupDeadline()
        startupBuffer = nil
        startupFormat = nil
        startupReleaseDeferredChunks.removeAll(keepingCapacity: true)
        startupReleaseInProgress = false
        startupSequence &+= 1
        startupReleaseEvaluations = 0
        startupDeadlineArms = 0
        pendingFormat = nil
        pendingCodecHeader = nil
        pendingFormatGeneration = nil
        chunkTimingFormat = format
        chunkTimingDiagnostics = ChunkTimingDiagnostics()
        playbackTimeline = AudioChunkPlaybackTimeline()
        playbackTimelineTransitionEnabled = false
        signalStartupCoordinator(.stateChanged)
        let streamStartLog = "stream start engine=\(engineID) sequence=\(startupSequence) format=\(format.codec.rawValue)"
        Log.audio.debug("\(streamStartLog, privacy: .public)")

        do {
            if startupBufferingEnabled {
                try await output.prepare(format: format, codecHeader: codecHeader)
                outputHasStarted = false
                startupFormat = format
                startupLeadUs = await output.startupLeadMicroseconds()
                startupBuffer = StartupBuffer(
                    sequence: startupSequence,
                    format: format,
                    startupLeadUs: startupLeadUs
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
            startupFormat = nil
            startupReleaseDeferredChunks.removeAll(keepingCapacity: true)
            startupReleaseInProgress = false
            signalStartupCoordinator(.stateChanged)
            yield(.startFailed(reason: error.localizedDescription))
        }
    }

    /// Schedule a chunk for playback.
    private func applyChunk(data: Data, ts: Int64, generation: UInt64?) async {
        if let generation, generation < streamGeneration {
            return
        }

        let chunkGeneration = generation ?? streamGeneration
        do {
            let pcm = try await output.decode(data)
            if let format = chunkTimingFormat {
                let frameSize = format.channels * (format.effectiveOutputBitDepth / 8)
                chunkTimingDiagnostics.record(
                    timestampUs: ts,
                    decodedFrameCount: Int64(pcm.count / max(1, frameSize)),
                    sampleRate: format.sampleRate
                )
            }
            // `ts` is unvalidated wire data; a hostile or buggy server can put it near
            // the Int64 bounds where the delay adjustment would trap.
            let delayed = ts.subtractingReportingOverflow(Int64(outputDelayMs) * 1_000)
            guard !delayed.overflow else {
                Log.audio.warning("Dropping chunk with an unrepresentable timestamp")
                return
            }
            let adjustedTs = delayed.partialValue
            let frameSize = chunkTimingFormat.map {
                $0.channels * ($0.effectiveOutputBitDepth / 8)
            } ?? 1
            let sampleRate = chunkTimingFormat?.sampleRate ?? 1
            let decodedDurationUs = Int64(
                (Double(pcm.count / max(1, frameSize)) * 1_000_000.0 / Double(sampleRate)).rounded()
            )
            let wirePlayTime = await clock.serverTimeToLocal(adjustedTs)
            let playTime: Int64
            if playbackTimelineTransitionEnabled {
                let timeline = playbackTimeline.playTime(
                    wireTimestampUs: adjustedTs,
                    wirePlayTimeUs: wirePlayTime,
                    decodedDurationUs: max(1, decodedDurationUs)
                )
                if timeline.didEngageDecodedTimeline {
                    Log.audio.notice(
                        "Audio timestamp cadence differs from decoded duration; using a contiguous playback timeline"
                    )
                }
                playTime = timeline.playTimeUs
            } else {
                playTime = wirePlayTime
            }
            if startupBuffer != nil || startupReleaseInProgress {
                if startupReleaseInProgress, startupBuffer == nil {
                    startupReleaseDeferredChunks.append(StartupBufferedChunk(
                        pcmData: pcm,
                        playTimeMicroseconds: playTime,
                        originalTimestamp: adjustedTs,
                        generation: chunkGeneration
                    ))
                    return
                }
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
                        generation: chunkGeneration
                    ))
                    if !startupReleaseInProgress {
                        signalStartupCoordinator(.stateChanged)
                    }
                } else {
                    await audioScheduler.schedule(
                        pcm: pcm,
                        serverTimestamp: adjustedTs,
                        playTimeMicroseconds: playTime,
                        generation: chunkGeneration
                    )
                }
            } else {
                await audioScheduler.schedule(pcm: pcm, serverTimestamp: adjustedTs, generation: chunkGeneration)
            }
        } catch {
            // Per-chunk decode failures are silent; stream-start failures are reported separately.
            Log.audio.debug("Chunk decode failed: \(error.localizedDescription)")
        }
    }

    /// Release the startup buffer when starting AudioQueue now will naturally land
    /// the first sample near its server timestamp. The release feeds decoded PCM into
    /// the ring before starting AudioQueue, then hands any future chunks back to the scheduler.
    private func releaseStartupBufferIfReady(arm: DeadlineArm? = nil) async { // swiftlint:disable:this function_body_length
        startupReleaseEvaluations += 1
        guard !outputHasStarted, !startupReleaseInProgress,
              var buffer = startupBuffer, !buffer.chunks.isEmpty else { return }
        if let arm {
            guard buffer.sequence == arm.sequence, arm.token == startupDeadlineToken else {
                // A superseded wait: a newer arrival re-armed, or the stream was replaced.
                return
            }
            // This call runs on the task the handle refers to. Clearing the handle first keeps
            // a replacement from cancelling the task it runs on.
            startupDeadlineTask = nil
            currentStartupDeadlineArm = nil
        }

        let sequence = buffer.sequence
        startupReleaseInvocation &+= 1
        let invocation = startupReleaseInvocation
        startupReleaseInProgress = true
        // Claim the buffer before the first await. This is the single-flight boundary: later
        // chunk arrivals go to `startupReleaseDeferredChunks`, never to a second release.
        startupBuffer = nil
        buffer.chunks.sort { $0.playTimeMicroseconds < $1.playTimeMicroseconds }
        // Releasing into a device that has not begun producing hands PCM to a pipeline that
        // is not consuming. The coordinator waits for the device transition once, then resumes
        // with the latest actor-owned buffer rather than polling a negative probe.
        do {
            try await output.waitUntilOutputDeviceIsLive()
        } catch {
            guard startupReleaseInProgress, startupSequence == sequence else { return }
            startupReleaseInProgress = false
            yield(.startFailed(reason: error.localizedDescription))
            return
        }
        guard startupReleaseInProgress, startupSequence == sequence else {
            let invalidatedLog = "startup release invalidated engine=\(engineID) sequence=\(sequence) invocation=\(invocation) stage=device-wait"
            Log.audio.debug("\(invalidatedLog, privacy: .public)")
            return
        }
        var currentBuffer = startupBuffer ?? buffer
        currentBuffer.chunks.append(contentsOf: startupReleaseDeferredChunks)
        startupReleaseDeferredChunks.removeAll(keepingCapacity: true)
        buffer = currentBuffer
        guard startupReleaseInProgress, startupSequence == sequence, !outputHasStarted else {
            let invalidatedLog = "startup release invalidated engine=\(engineID) sequence=\(sequence) invocation=\(invocation) stage=device-probe"
            Log.audio.debug("\(invalidatedLog, privacy: .public)")
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

        // Only a newly arrived future-dated chunk can change an all-stale result, so restore
        // the claimed buffer and let the next arrival re-enter startup evaluation.
        guard let candidate else {
            guard startupReleaseInProgress, startupSequence == sequence else { return }
            var waitingLog = "startup release waiting"
            waitingLog += " engine=\(engineID) sequence=\(sequence)"
            waitingLog += " invocation=\(invocation) reason=no-viable-chunk"
            waitingLog += " chunks=\(buffer.chunks.count)"
            Log.audio.debug("\(waitingLog, privacy: .public)")
            startupBuffer = buffer
            startupBuffer?.chunks.append(contentsOf: startupReleaseDeferredChunks)
            startupReleaseDeferredChunks.removeAll(keepingCapacity: true)
            startupReleaseInProgress = false
            cancelStartupDeadline()
            signalStartupCoordinator(.stateChanged)
            return
        }
        if candidate.index > 0 {
            buffer.chunks.removeFirst(candidate.index)
        }
        let firstPlayTime = buffer.chunks[0].playTimeMicroseconds
        let lastPlayTime = buffer.chunks[buffer.chunks.count - 1].playTimeMicroseconds
        let startTime = candidate.releaseTimeUs
        guard nowUs >= startTime else {
            guard startupReleaseInProgress, startupSequence == sequence else { return }
            startupBuffer = buffer
            startupBuffer?.chunks.append(contentsOf: startupReleaseDeferredChunks)
            startupReleaseDeferredChunks.removeAll(keepingCapacity: true)
            startupReleaseInProgress = false
            if let currentArm = currentStartupDeadlineArm,
               currentArm.sequence == sequence,
               currentArm.releaseTimeUs <= startTime {
                return
            }
            let delayUs = Self.startupWaitMicroseconds(releaseTimeUs: startTime, nowUs: nowUs)
            cancelStartupDeadline()
            let arm = DeadlineArm(sequence: sequence, token: startupDeadlineToken, releaseTimeUs: startTime)
            currentStartupDeadlineArm = arm
            startupDeadlineArms += 1
            var scheduledLog = "startup release scheduled"
            scheduledLog += " engine=\(engineID) sequence=\(sequence)"
            scheduledLog += " invocation=\(invocation) releaseIn=\(delayUs)us"
            scheduledLog += " chunks=\(startupBuffer?.chunks.count ?? 0)"
            Log.audio.debug("\(scheduledLog, privacy: .public)")
            startupDeadlineTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .microseconds(delayUs))
                } catch {
                    return
                }
                await Self.yieldUntilReleaseInstant(startTime)
                await self?.signalStartupDeadline(arm)
            }
            return
        }

        cancelStartupDeadline()
        // The claimed buffer remains local for the whole priming operation. No actor state is
        // restored after an await unless the sequence check above still proves ownership.
        let horizonSum = firstPlayTime.addingReportingOverflow(startupMinBufferUs)
        let releaseHorizon = horizonSum.overflow ? Int64.max : horizonSum.partialValue
        let spanUs = lastPlayTime.subtractingReportingOverflow(firstPlayTime).partialValue
        let latenessUs = nowUs.subtractingReportingOverflow(startTime).partialValue
        var startupTelemetry = "startup priming begin"
        startupTelemetry += " engine=\(engineID)"
        startupTelemetry += " sequence=\(sequence)"
        startupTelemetry += " invocation=\(invocation)"
        startupTelemetry += " chunks=\(buffer.chunks.count)"
        startupTelemetry += " span=\(spanUs)us"
        startupTelemetry += " min=\(startupMinBufferUs)us"
        startupTelemetry += " lateness=\(latenessUs)us"
        Log.audio.debug("\(startupTelemetry, privacy: .public)")
        var deferred: [StartupBufferedChunk] = []

        do {
            for chunk in buffer.chunks where chunk.playTimeMicroseconds <= releaseHorizon {
                guard startupReleaseInProgress, startupSequence == sequence else {
                    let invalidatedLog = "startup priming invalidated engine=\(engineID) sequence=\(sequence) invocation=\(invocation) stage=pcm"
                    Log.audio.debug("\(invalidatedLog, privacy: .public)")
                    return
                }
                try await output.playPCM(
                    chunk.pcmData,
                    serverTimestamp: chunk.originalTimestamp,
                    playTimeMicroseconds: chunk.playTimeMicroseconds
                )
            }
            guard startupReleaseInProgress, startupSequence == sequence, !outputHasStarted else {
                let invalidatedLog = "startup priming invalidated engine=\(engineID) sequence=\(sequence) invocation=\(invocation) stage=before-start"
                Log.audio.debug("\(invalidatedLog, privacy: .public)")
                return
            }
            try await output.startPrepared()
            guard startupReleaseInProgress, startupSequence == sequence, !outputHasStarted else {
                let invalidatedLog = "startup priming invalidated engine=\(engineID) sequence=\(sequence) invocation=\(invocation) stage=after-start"
                Log.audio.debug("\(invalidatedLog, privacy: .public)")
                return
            }
            outputHasStarted = true
            startupReleaseInProgress = false
            startupReleaseCommits += 1
            var commitLog = "startup priming committed"
            commitLog += " engine=\(engineID) sequence=\(sequence)"
            commitLog += " invocation=\(invocation) commits=\(startupReleaseCommits)"
            Log.audio.debug("\(commitLog, privacy: .public)")
            deferred = startupReleaseDeferredChunks
            startupReleaseDeferredChunks.removeAll(keepingCapacity: true)
            armUnderrunGrace()
            await audioScheduler.startScheduling()
            guard startupSequence == sequence else { return }
            yield(.started(buffer.format))
        } catch {
            guard startupSequence == sequence else { return }
            startupReleaseInProgress = false
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
        for chunk in deferred {
            await audioScheduler.schedule(
                pcm: chunk.pcmData,
                serverTimestamp: chunk.originalTimestamp,
                playTimeMicroseconds: chunk.playTimeMicroseconds,
                generation: chunk.generation
            )
        }
    }

    /// Apply a format change at an output boundary (engine-internal, no MainActor.run).
    ///
    /// The public binary stream still receives every wire chunk, but already-scheduled PCM
    /// belongs to the old output format and cannot safely remain ahead of the new AudioQueue.
    /// Stop and flush that private output state here; the first new-generation chunk starts the
    /// replacement queue, avoiding a period where decoded 44.1 kHz data follows a 48 kHz queue.
    private func applyFormatChange(
        format: AudioFormatSpec,
        codecHeader: Data?,
        generation: UInt64?
    ) async {
        if let generation {
            streamGeneration = generation
        } else {
            streamGeneration &+= 1
        }
        if !outputHasStarted, startupFormat != nil {
            // Startup is still priming, so there is no playing queue to switch seamlessly:
            // the prepared queue and any release in flight belong to the old format. Restart
            // the startup pipeline for the new format; entering the seamless path here would
            // leave the stale startup release racing a disposed queue.
            await applyStreamStart(format: format, codecHeader: codecHeader)
            return
        }
        chunkTimingFormat = format
        chunkTimingDiagnostics = ChunkTimingDiagnostics()
        playbackTimeline = AudioChunkPlaybackTimeline()
        playbackTimelineTransitionEnabled = true
        pendingFormat = format
        pendingCodecHeader = codecHeader
        pendingFormatGeneration = streamGeneration

        await audioScheduler.clear()
        await output.stop()
        outputHasStarted = false

        do {
            try await output.swapDecoder(format: format, codecHeader: codecHeader)
            // The replacement AudioQueue starts when runSchedulerOutput receives the first
            // new-generation chunk. Keeping the decoder ready avoids decoding on the old format.
        } catch {
            // Swap failed: fall back to a full restart so new-format chunks are not decoded by
            // the stale decoder. The queue is already flushed, so this starts from a clean path.
            Log.audio.error("Decoder swap failed, full restart: \(error.localizedDescription)")
            pendingFormat = nil
            pendingCodecHeader = nil
            pendingFormatGeneration = nil
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
            startupReleaseInProgress = false
            startupReleaseDeferredChunks.removeAll(keepingCapacity: true)
            startupSequence &+= 1
            signalStartupCoordinator(.stateChanged)
            if let format = startupFormat {
                startupBuffer = StartupBuffer(
                    sequence: startupSequence,
                    format: format,
                    startupLeadUs: startupLeadUs
                )
            } else {
                startupBuffer = nil
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
            startupFormat = nil
            chunkTimingFormat = nil
            chunkTimingDiagnostics = ChunkTimingDiagnostics()
            playbackTimeline = AudioChunkPlaybackTimeline()
            playbackTimelineTransitionEnabled = false
            pendingFormat = nil
            pendingCodecHeader = nil
            pendingFormatGeneration = nil
            startupReleaseDeferredChunks.removeAll(keepingCapacity: true)
            startupReleaseInProgress = false
            cancelStartupDeadline()
            startupSequence &+= 1
            signalStartupCoordinator(.stateChanged)
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
        var deferredChunk: ScheduledChunk?

        while true {
            let chunk: ScheduledChunk?
            if let pendingChunk = deferredChunk {
                chunk = pendingChunk
                deferredChunk = nil
            } else {
                chunk = await iterator.next()
            }
            guard let chunk else { break }

            // `clear()` cannot retract values already yielded by the AsyncStream. The
            // engine generation is the authoritative boundary, so discard those values
            // even when the output loop has not observed the new generation yet.
            guard chunk.generation >= streamGeneration else { continue }

            if chunk.generation != currentGeneration {
                if chunk.generation < currentGeneration {
                    // Old generation after format change; discard
                    continue
                }

                // New generation — first chunk in new format
                currentGeneration = chunk.generation

                // Read the pending format engine-internally (no MainActor.run). A newer
                // transition may have superseded this yielded chunk while it was waiting
                // in the AsyncStream; never pair that chunk with the newer decoder.
                guard let format = pendingFormat,
                      pendingFormatGeneration == currentGeneration else {
                    if let pendingFormatGeneration, pendingFormatGeneration > currentGeneration {
                        continue
                    }
                    try? await output.playPCM(
                        chunk.pcmData,
                        serverTimestamp: chunk.originalTimestamp,
                        playTimeMicroseconds: chunk.playTimeMicroseconds
                    )
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
                var preBuffer: [(pcm: Data, timestamp: Int64, playTime: Int64)] = [
                    (chunk.pcmData, chunk.originalTimestamp, chunk.playTimeMicroseconds)
                ]

                let formatTransitionPreBuffer = 2
                while preBuffer.count < formatTransitionPreBuffer, let nextChunk = await iterator.next() {
                    if nextChunk.generation < streamGeneration || nextChunk.generation < currentGeneration {
                        continue
                    }
                    if nextChunk.generation > currentGeneration {
                        deferredChunk = nextChunk
                        break
                    }
                    preBuffer.append((nextChunk.pcmData, nextChunk.originalTimestamp, nextChunk.playTimeMicroseconds))
                }

                // A newer format command may have superseded this transition while its
                // prebuffer was being assembled. Do not start the old queue or consume its PCM.
                guard pendingFormatGeneration == currentGeneration, streamGeneration == currentGeneration else {
                    continue
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
                    if pendingFormatGeneration == currentGeneration {
                        pendingFormat = nil
                        pendingCodecHeader = nil
                        pendingFormatGeneration = nil
                    }
                    continue
                }

                // Feed pre-buffered chunks
                for buffered in preBuffer {
                    try? await output.playPCM(
                        buffered.pcm,
                        serverTimestamp: buffered.timestamp,
                        playTimeMicroseconds: buffered.playTime
                    )
                }

                if pendingFormatGeneration == currentGeneration {
                    pendingFormat = nil
                    pendingCodecHeader = nil
                    pendingFormatGeneration = nil
                }

                continue
            }

            try? await output.playPCM(
                chunk.pcmData,
                serverTimestamp: chunk.originalTimestamp,
                playTimeMicroseconds: chunk.playTimeMicroseconds
            )
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

                let chunkTiming = chunkTimingDiagnostics.takeSnapshot()
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
                    + " timingCodec=\(chunkTimingFormat?.codec.rawValue ?? "none")"
                    + " timing=\(chunkTiming.summary)"
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
