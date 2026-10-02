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
    private let routeInvalidationGate = AudioRouteInvalidationGate()

    // Report egress
    private let reportStream: AsyncStream<EngineReport>
    private let reportContinuation: AsyncStream<EngineReport>.Continuation

    /// Seamless format state (engine-isolated, no MainActor.run)
    private struct FormatBoundary: Sendable {
        let format: AudioFormatSpec
        let codecHeader: Data?
        let startGeneration: UInt64
    }

    /// Formats are retained by generation because several wire-ordered changes may be
    /// announced before the scheduler reaches the corresponding render boundaries.
    private var formatBoundaries: [UInt64: FormatBoundary] = [:]
    private var streamGeneration: UInt64 = 0
    private var playerStartGeneration: UInt64 = 0
    private var playerStartFailed = false
    /// Generation floor for lifecycle clears/ends. Format changes intentionally do not advance it,
    /// because old generations remain valid until their natural render boundary.
    private var discardBeforeGeneration: UInt64 = 0
    /// Invalidates a suspended hardware transition on clear, end, startup replacement, or shutdown.
    private var transitionToken: UInt64 = 0
    /// A failed decoder boundary becomes an explicit segment error. Old PCM may drain, but the
    /// failed generation is never rendered until a lifecycle restart establishes a new decoder.
    private var failedTransitionGeneration: UInt64?
    private var failedDecoderGeneration: UInt64?
    private var chunkTimingFormat: AudioFormatSpec?
    private var chunkTimingDiagnostics = ChunkTimingDiagnostics()
    private var playbackTimeline = AudioChunkPlaybackTimeline()
    private var playbackTimelineTransitionEnabled = false

    /// Output delay in milliseconds, applied in the local scheduling domain.
    private var outputDelayMs: Int = 0

    /// Map a server timestamp into the local scheduling domain, applying output delay once.
    /// Server-domain metadata and correction cursors continue to use the original timestamp.
    static func localPlayTime(mappedLocalTime: Int64, outputDelayMicroseconds: Int64) -> Int64? {
        let result = mappedLocalTime.subtractingReportingOverflow(max(0, outputDelayMicroseconds))
        return result.overflow ? nil : result.partialValue
    }

    private static func outputDelayMicroseconds(_ milliseconds: Int) -> Int64 {
        let result = Int64(max(0, milliseconds)).multipliedReportingOverflow(by: 1_000)
        return result.overflow ? Int64.max : result.partialValue
    }

    private static func localDelayShift(from oldDelayUs: Int64, to newDelayUs: Int64) -> Int64 {
        let result = oldDelayUs.subtractingReportingOverflow(newDelayUs)
        return result.overflow ? (oldDelayUs >= newDelayUs ? Int64.max : Int64.min) : result.partialValue
    }

    // Task tracking for shutdown
    private var drainTask: Task<Void, Never>?
    private var startupCoordinatorTask: Task<Void, Never>?
    private var schedulerOutputTask: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?
    private let telemetrySleep: @Sendable (Duration) async throws -> Void

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
    /// Absolute time source for startup selection; injectable only through the internal test init.
    private let startupNow: @Sendable () -> Int64
    private let engineID = UUID().uuidString

    private struct StartupBuffer {
        let startGeneration: UInt64
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
        var playTimeMicroseconds: Int64
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
        startupMinBufferMs: Int = 0,
        startupNow: @escaping @Sendable () -> Int64 = { MonotonicClock.absoluteMicroseconds() },
        telemetrySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.output = output
        audioScheduler = scheduler
        self.clock = clock
        self.startupNow = startupNow
        self.telemetrySleep = telemetrySleep
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
    init(
        clock: any ClockSyncProtocol,
        config: PlayerConfiguration,
        outputTransitionCallback: (@Sendable (AudioOutputTransition) -> Void)? = nil,
        audioOutputFactory: @Sendable (PlayerConfiguration, (@Sendable (AudioOutputTransition) -> Void)?) -> any AudioOutput = AudioEngine
            .makeProductionOutput
    ) {
        let audioScheduler = AudioScheduler(
            clockSync: clock,
            releaseLeadTime: TimeInterval(config.minBufferMs) / 1_000.0
        )

        output = audioOutputFactory(config, outputTransitionCallback)
        self.audioScheduler = audioScheduler
        self.clock = clock
        startupNow = { MonotonicClock.absoluteMicroseconds() }
        telemetrySleep = { try await Task.sleep(for: $0) }
        let sink = DataPlaneSink()
        _commandsSink = sink
        _commandStream = sink.commands
        let (reportStream, reportContinuation) = AsyncStream<EngineReport>.makeStream()
        self.reportStream = reportStream
        self.reportContinuation = reportContinuation
        startupBufferingEnabled = true
        startupMinBufferUs = Int64(config.minBufferMs) * 1_000
        outputDelayMs = config.initialOutputDelayMs
        _commandsSink.enqueue(.setOutputDelay(config.initialOutputDelayMs))
    }

    nonisolated static func makeProductionOutput(
        config: PlayerConfiguration,
        outputTransitionCallback: (@Sendable (AudioOutputTransition) -> Void)?
    ) -> any AudioOutput {
        AudioPlayer(
            pcmBufferCapacity: max(config.bufferCapacity / 2, 131_072),
            volumeControl: VolumeControlFactory.resolve(mode: config.volumeMode).control,
            processCallback: config.processCallback,
            outputTransitionCallback: outputTransitionCallback
        )
    }

    // MARK: - Public interface

    /// The data-plane sink where commands are enqueued by the client message loop.
    nonisolated var commands: DataPlaneSink {
        _commandsSink
    }

    /// Enqueue an inbound audio chunk. Route-invalidated ingress is dropped before it reaches the FIFO.
    nonisolated func enqueueAudioChunk(data: Data, timestamp: Int64, sendAhead _: UInt32 = 0) {
        routeInvalidationGate.enqueueChunk(data: data, timestamp: timestamp, to: _commandsSink)
    }

    /// Enqueue a new stream boundary and reopen its route epoch atomically.
    nonisolated func enqueueStreamStart(format: AudioFormatSpec, codecHeader: Data?, startGeneration: UInt64 = 0) {
        routeInvalidationGate.enqueueStreamStart(
            format: format,
            codecHeader: codecHeader,
            startGeneration: startGeneration,
            to: _commandsSink
        )
    }

    /// Enqueue a player end boundary and close its route epoch atomically.
    nonisolated func enqueueStreamEnd(roles: [String]?) {
        let endsPlayer = roles == nil || roles?.contains("player") == true
        guard endsPlayer else {
            _commandsSink.enqueue(.streamEnd(roles: roles))
            return
        }
        routeInvalidationGate.enqueueStreamEnd(roles: roles, to: _commandsSink)
    }

    /// Test-only unstamped enqueue; production wraps format changes with their start generation.
    nonisolated func enqueueFormatChange(format: AudioFormatSpec, codecHeader: Data?) {
        _commandsSink.enqueue(.formatChange(format, codecHeader: codecHeader))
    }

    /// Drop compressed-chunk ingress until the route transition command is enqueued.
    nonisolated func beginRouteInvalidation() {
        routeInvalidationGate.invalidate()
    }

    /// Reopen ingress without adding a command or disturbing FIFO order.
    nonisolated func clearRouteInvalidation() {
        routeInvalidationGate.clear()
    }

    /// Atomically open a new ingress epoch and enqueue the route transition.
    nonisolated func enqueueRouteInvalidatedFormatChange(format: AudioFormatSpec, codecHeader: Data?, startGeneration: UInt64 = 0) {
        routeInvalidationGate.enqueueRouteInvalidatedFormatChange(
            format: format,
            codecHeader: codecHeader,
            startGeneration: startGeneration,
            to: _commandsSink
        )
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

    func isRouteInvalidatedForTesting() -> Bool {
        routeInvalidationGate.isInvalidated()
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
                await apply(command)
                appliedKinds.append(command.kind)
                if appliedKinds.count > Self.appliedKindsRetentionLimit {
                    // Trim in batches; removeFirst(1) on an Array is O(n).
                    appliedKinds.removeFirst(appliedKinds.count - Self.appliedKindsRetentionLimit / 2)
                }
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
        let shutdownStartedAt = MonotonicClock.absoluteMicroseconds()
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
        let outputStopStartedAt = MonotonicClock.absoluteMicroseconds()
        await output.stop()
        let outputStopUs = MonotonicClock.absoluteMicroseconds() - outputStopStartedAt

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
        let shutdownUs = MonotonicClock.absoluteMicroseconds() - shutdownStartedAt
        Log.audio.info(
            "AudioEngine shutdown: outputStop=\(outputStopUs, privacy: .public)us total=\(shutdownUs, privacy: .public)us"
        )
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
        case let .withStartGeneration(generation, command):
            playerStartGeneration = generation
            await apply(command)

        case let .streamStart(format, codecHeader, generation):
            playerStartGeneration = generation
            await applyStreamStart(format: format, codecHeader: codecHeader)

        case let .chunk(data, ts):
            guard !routeInvalidationGate.isInvalidated() else { return }
            await applyChunk(data: data, ts: ts, generation: streamGeneration)

        case let .chunkAtRouteEpoch(data, ts, epoch):
            guard routeInvalidationGate.isCurrent(epoch: epoch) else { return }
            await applyChunk(data: data, ts: ts, generation: streamGeneration, routeEpoch: epoch)

        case let .chunkAtGenerationWithSendAhead(data, ts, _, generation):
            guard !routeInvalidationGate.isInvalidated() else { return }
            // Legacy tagged commands are accepted only when their tag still denotes the
            // currently applied wire generation. New ingress uses the untagged case below.
            guard generation == streamGeneration else { return }
            await applyChunk(data: data, ts: ts, generation: generation)

        case let .formatChange(format, codecHeader):
            await applyFormatChange(format: format, codecHeader: codecHeader, generation: streamGeneration &+ 1)

        case let .formatChangeRouteInvalidated(format, codecHeader, _):
            await applyRouteInvalidatedFormatChange(format: format, codecHeader: codecHeader)

        case let .formatChangeAtGeneration(format, codecHeader, generation):
            guard generation == streamGeneration &+ 1 else { return }
            await applyFormatChange(format: format, codecHeader: codecHeader, generation: generation)

        case let .streamClear(roles):
            await applyStreamClear(roles: roles)

        case let .streamEnd(roles):
            await applyStreamEnd(roles: roles)

        case let .setOutputDelay(delayMs):
            let oldDelayUs = Self.outputDelayMicroseconds(outputDelayMs)
            let newDelayUs = Self.outputDelayMicroseconds(delayMs)
            outputDelayMs = delayMs
            await audioScheduler.rebaseOutputDelay(from: oldDelayUs, to: newDelayUs)
            rebaseStartupChunks(from: oldDelayUs, to: newDelayUs)
            playbackTimeline.rebaseOutputDelay(from: oldDelayUs, to: newDelayUs)
            await output.setOutputDelayMicroseconds(newDelayUs)
        }
    }

    /// Start a new stream: init decoder, then either start immediately (test path)
    /// or prepare the backend and wait for startup lead-time/min-buffer priming.
    private func applyStreamStart(format: AudioFormatSpec, codecHeader: Data?) async {
        let startGeneration = playerStartGeneration
        playerStartFailed = false
        cancelStartupDeadline()
        startupBuffer = nil
        startupFormat = nil
        startupReleaseDeferredChunks.removeAll(keepingCapacity: true)
        startupReleaseInProgress = false
        startupSequence &+= 1
        startupReleaseEvaluations = 0
        startupDeadlineArms = 0
        streamGeneration &+= 1
        transitionToken &+= 1
        failedTransitionGeneration = nil
        failedDecoderGeneration = nil
        formatBoundaries.removeAll(keepingCapacity: true)
        discardBeforeGeneration = streamGeneration
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
                    startGeneration: startGeneration,
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
                yield(.started(format, startGeneration: startGeneration))
            }
        } catch {
            startupBuffer = nil
            startupFormat = nil
            startupReleaseDeferredChunks.removeAll(keepingCapacity: true)
            startupReleaseInProgress = false
            signalStartupCoordinator(.stateChanged)
            playerStartFailed = true
            yield(.startFailed(reason: error.localizedDescription, startGeneration: startGeneration))
        }
    }

    private static func rebase(_ chunks: inout [StartupBufferedChunk], from oldDelayUs: Int64, to newDelayUs: Int64) {
        let shift = localDelayShift(from: oldDelayUs, to: newDelayUs)
        guard shift != 0 else { return }
        for index in chunks.indices {
            chunks[index].playTimeMicroseconds = chunks[index].playTimeMicroseconds.saturatingAdding(shift)
        }
    }

    private func rebaseStartupChunks(from oldDelayUs: Int64, to newDelayUs: Int64) {
        if var startupBuffer {
            Self.rebase(&startupBuffer.chunks, from: oldDelayUs, to: newDelayUs)
            self.startupBuffer = startupBuffer
        }
        Self.rebase(&startupReleaseDeferredChunks, from: oldDelayUs, to: newDelayUs)
    }

    /// Schedule a chunk for playback.
    private func applyChunk(data: Data, ts: Int64, generation: UInt64?, routeEpoch: UInt64? = nil) async {
        if let generation, generation < streamGeneration {
            return
        }

        let chunkGeneration = generation ?? streamGeneration
        guard failedDecoderGeneration != chunkGeneration else { return }
        do {
            let pcm = try await output.decode(data)
            guard routeEpoch.map({ routeInvalidationGate.isCurrent(epoch: $0) }) ?? true else { return }
            if let format = chunkTimingFormat {
                let frameSize = format.channels * (format.effectiveOutputBitDepth / 8)
                chunkTimingDiagnostics.record(
                    timestampUs: ts,
                    decodedFrameCount: Int64(pcm.count / max(1, frameSize)),
                    sampleRate: format.sampleRate
                )
            }
            // `ts` stays in the server domain for cursor, metadata, and cadence diagnostics.
            // Output delay is local-domain correction applied only after clock mapping.
            let localDelayUs = Self.outputDelayMicroseconds(outputDelayMs)
            let frameSize = chunkTimingFormat.map {
                $0.channels * ($0.effectiveOutputBitDepth / 8)
            } ?? 1
            let sampleRate = chunkTimingFormat?.sampleRate ?? 1
            let decodedDurationUs = Int64(
                (Double(pcm.count / max(1, frameSize)) * 1_000_000.0 / Double(sampleRate)).rounded()
            )
            let mappedLocalTime = await clock.serverTimeToLocal(ts)
            guard let wirePlayTime = Self.localPlayTime(
                mappedLocalTime: mappedLocalTime,
                outputDelayMicroseconds: localDelayUs
            ) else {
                Log.audio.warning("Dropping chunk with an unrepresentable local play time")
                return
            }
            let playTime: Int64
            if playbackTimelineTransitionEnabled {
                let timeline = playbackTimeline.playTime(
                    wireTimestampUs: ts,
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
                        originalTimestamp: ts,
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
                        originalTimestamp: ts,
                        generation: chunkGeneration
                    ))
                    if !startupReleaseInProgress {
                        signalStartupCoordinator(.stateChanged)
                    }
                } else {
                    await audioScheduler.schedule(
                        pcm: pcm,
                        serverTimestamp: ts,
                        playTimeMicroseconds: playTime,
                        generation: chunkGeneration
                    )
                }
            } else {
                await audioScheduler.schedule(
                    pcm: pcm,
                    serverTimestamp: ts,
                    playTimeMicroseconds: playTime,
                    generation: chunkGeneration
                )
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
        let startGeneration = buffer.startGeneration
        startupReleaseInvocation &+= 1
        let invocation = startupReleaseInvocation
        startupReleaseInProgress = true
        // Claim the buffer before the first await. This is the single-flight boundary: later
        // chunk arrivals go to `startupReleaseDeferredChunks`, never to a second release.
        startupBuffer = nil
        var bufferDelayUs = Self.outputDelayMicroseconds(outputDelayMs)
        buffer.chunks.sort { $0.playTimeMicroseconds < $1.playTimeMicroseconds }
        // Releasing into a device that has not begun producing hands PCM to a pipeline that
        // is not consuming. The coordinator waits for the device transition once, then resumes
        // with the latest actor-owned buffer rather than polling a negative probe.
        do {
            try await output.waitUntilOutputDeviceIsLive()
        } catch {
            guard startupReleaseInProgress, startupSequence == sequence else { return }
            startupReleaseInProgress = false
            yield(.startFailed(reason: error.localizedDescription, startGeneration: startGeneration))
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
        let currentDelayUs = Self.outputDelayMicroseconds(outputDelayMs)
        Self.rebase(&currentBuffer.chunks, from: bufferDelayUs, to: currentDelayUs)
        bufferDelayUs = currentDelayUs
        buffer = currentBuffer
        guard startupReleaseInProgress, startupSequence == sequence, !outputHasStarted else {
            let invalidatedLog = "startup release invalidated engine=\(engineID) sequence=\(sequence) invocation=\(invocation) stage=device-probe"
            Log.audio.debug("\(invalidatedLog, privacy: .public)")
            return
        }

        let nowUs = startupNow()
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
            // No self-wake: the restored chunks are identical to the ones that just
            // failed the scan, so `.stateChanged` here spins forever. Only a fresh
            // arrival changes the outcome, and the chunk path signals the coordinator.
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
        let primingGeneration = discardBeforeGeneration

        do {
            Self.rebase(&buffer.chunks, from: bufferDelayUs, to: Self.outputDelayMicroseconds(outputDelayMs))
            bufferDelayUs = Self.outputDelayMicroseconds(outputDelayMs)
            for chunk in buffer.chunks where chunk.playTimeMicroseconds <= releaseHorizon
                && chunk.generation == primingGeneration {
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
            yield(.started(buffer.format, startGeneration: startGeneration))
        } catch {
            guard startupSequence == sequence else { return }
            startupReleaseInProgress = false
            await output.stop()
            outputHasStarted = false
            yield(.startFailed(reason: error.localizedDescription, startGeneration: startGeneration))
            return
        }

        for chunk in buffer.chunks where chunk.playTimeMicroseconds > releaseHorizon
            || chunk.generation != primingGeneration {
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

    /// Discard the old output immediately when a route change invalidates its PCM.
    private func applyRouteInvalidatedFormatChange(format: AudioFormatSpec, codecHeader: Data?) async {
        cancelStartupDeadline()
        startupBuffer = nil
        startupFormat = nil
        startupReleaseDeferredChunks.removeAll(keepingCapacity: true)
        startupReleaseInProgress = false
        startupSequence &+= 1
        streamGeneration &+= 1
        transitionToken &+= 1
        failedTransitionGeneration = nil
        failedDecoderGeneration = nil
        formatBoundaries.removeAll(keepingCapacity: true)
        discardBeforeGeneration = streamGeneration
        chunkTimingFormat = nil
        chunkTimingDiagnostics = ChunkTimingDiagnostics()
        playbackTimeline = AudioChunkPlaybackTimeline()
        playbackTimelineTransitionEnabled = false
        signalStartupCoordinator(.stateChanged)
        await audioScheduler.stop()
        await audioScheduler.clear()
        outputHasStarted = false
        await output.stop()
        await applyStreamStart(format: format, codecHeader: codecHeader)
    }

    /// Apply a format change at an output boundary (engine-internal, no MainActor.run).
    ///
    /// Old-generation PCM drains before the hardware switch; new PCM waits at the boundary.
    private func applyFormatChange(
        format: AudioFormatSpec,
        codecHeader: Data?,
        generation: UInt64
    ) async {
        let startGeneration = playerStartGeneration
        if playerStartFailed, !outputHasStarted, startupFormat == nil {
            await applyStreamStart(format: format, codecHeader: codecHeader)
            return
        }
        streamGeneration = generation
        formatBoundaries[generation] = FormatBoundary(format: format, codecHeader: codecHeader, startGeneration: startGeneration)
        chunkTimingFormat = format
        chunkTimingDiagnostics = ChunkTimingDiagnostics()
        playbackTimeline = AudioChunkPlaybackTimeline()
        playbackTimelineTransitionEnabled = true

        // Startup PCM retains its generation and prepared output format; later generations
        // cross the same render boundary as a format change during steady playback.
        do {
            try await output.swapDecoder(format: format, codecHeader: codecHeader)
        } catch {
            // Keep the old decoder and queue alive. New-format bytes must not be decoded by the
            // old decoder, and stopping here would truncate already-scheduled old PCM.
            failedDecoderGeneration = generation
            Log.audio.error("Decoder swap failed; quarantining generation \(generation): \(error.localizedDescription)")
            yield(.startFailed(reason: error.localizedDescription, startGeneration: startGeneration))
        }
    }

    /// Clear buffered audio.
    private func applyStreamClear(roles: [String]?) async {
        let shouldClear = roles == nil || roles?.contains("player") ?? false
        if shouldClear {
            let pendingBoundary = formatBoundaries[streamGeneration]
            cancelStartupDeadline()
            startupReleaseInProgress = false
            startupReleaseDeferredChunks.removeAll(keepingCapacity: true)
            startupSequence &+= 1
            streamGeneration &+= 1
            transitionToken &+= 1
            failedTransitionGeneration = nil
            failedDecoderGeneration = nil
            discardBeforeGeneration = streamGeneration
            formatBoundaries.removeAll(keepingCapacity: true)
            // Clear retires PCM, not the announced configuration awaiting its render boundary.
            if let pendingBoundary {
                formatBoundaries[streamGeneration] = pendingBoundary
            }
            signalStartupCoordinator(.stateChanged)
            if !outputHasStarted, let format = startupFormat {
                startupBuffer = StartupBuffer(
                    startGeneration: startupBuffer?.startGeneration ?? playerStartGeneration,
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
            formatBoundaries.removeAll(keepingCapacity: true)
            discardBeforeGeneration = streamGeneration &+ 1
            streamGeneration = discardBeforeGeneration
            transitionToken &+= 1
            failedTransitionGeneration = nil
            failedDecoderGeneration = nil
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

    /// Consumes scheduled chunks in render order.
    /// A format boundary switches hardware only when the first new-generation chunk reaches it.
    private func runSchedulerOutput() async {
        var currentGeneration: UInt64 = 0
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
            guard chunk.generation >= currentGeneration, chunk.generation >= discardBeforeGeneration else { continue }

            if chunk.generation > currentGeneration {
                let generation = chunk.generation
                // Stream start and stream clear advance the generation without a hardware
                // format boundary. Adopt those generations directly; only renegotiations
                // carry a boundary that requires an awaited queue rebuild.
                guard failedTransitionGeneration != generation,
                      failedDecoderGeneration != generation else { continue }
                if let boundary = formatBoundaries[generation] {
                    let token = transitionToken
                    do {
                        try await output.switchHardwareFormat(format: boundary.format)
                    } catch {
                        guard token == transitionToken,
                              generation <= streamGeneration,
                              generation >= discardBeforeGeneration else { continue }
                        Log.audio.error("Hardware format switch failed: \(error.localizedDescription)")
                        failedTransitionGeneration = generation
                        yield(.startFailed(reason: error.localizedDescription, startGeneration: boundary.startGeneration))
                        continue
                    }
                    guard token == transitionToken,
                          generation <= streamGeneration,
                          generation >= discardBeforeGeneration else { continue }
                    outputHasStarted = true
                    await audioScheduler.startScheduling()
                    formatBoundaries = formatBoundaries.filter { $0.key > generation }
                    currentGeneration = generation
                    yield(.formatApplied(boundary.format, startGeneration: boundary.startGeneration))
                } else {
                    guard generation <= streamGeneration, generation >= discardBeforeGeneration else { continue }
                    currentGeneration = generation
                }
            }

            guard chunk.generation == currentGeneration else { continue }
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
            try? await telemetrySleep(.milliseconds(500))
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
                    + " cbInFlight=\(tSnap.callbackDepth.minimum)/\(tSnap.callbackDepth.last)/\(tSnap.callbackDepth.maximum)f"
                    + " cbDelay=\(tSnap.callbackDepth.delayFrames)f cbTimeCost=\(tSnap.callbackDepth.timeCostUs)us"
                    + " cbSamples=\(tSnap.callbackDepth.samples)"
                    + " cbSkipPrewarm=\(tSnap.callbackDepth.prewarmSkipped) cbSkipZero=\(tSnap.callbackDepth.zeroPlayedSkipped)"
                    + " aqDevDelta=\(tSnap.queueTimeline.deviceDeltaFrames.map { String(format: "%.2f", $0) } ?? "unavailable")f"
                    + " aqHostLag=\(tSnap.queueTimeline.hostLagUs.map { String(format: "%.2f", $0) } ?? "unavailable")us"
                    + " aqStatus=\(tSnap.queueTimeline.deviceStatus)/\(tSnap.queueTimeline.queueStatus)/\(tSnap.queueTimeline.translateStatus)"
                    + " aqFlags=\(tSnap.queueTimeline.deviceFlags)/\(tSnap.queueTimeline.translatedFlags)"
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
