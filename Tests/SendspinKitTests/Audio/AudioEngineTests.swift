import Foundation
@testable import SendspinKit
import Testing

// MARK: - Helpers

/// Test clock that returns deterministic server→local conversions.
actor StubClock: ClockSyncProtocol {
    private var synchronized = true
    private let offset: Int64 // offset = server - client
    private let anchorToNow: Bool

    /// - Parameter anchorToNow: when true, `serverTimeToLocal` maps a (small) server
    ///   timestamp to `MonotonicClock.absoluteMicroseconds() + serverTime`, so a chunk
    ///   scheduled with a near-zero/near-future `ts` lands inside the scheduler's
    ///   playback window and is actually emitted to `scheduledChunks` (rather than
    ///   dropped-late). Required to drive `runSchedulerOutput`'s rebuild path.
    init(offsetMicroseconds: Int64 = 0, anchorToNow: Bool = false) {
        offset = offsetMicroseconds
        self.anchorToNow = anchorToNow
    }

    var hasSynced: Bool {
        synchronized
    }

    func processServerTime(
        clientTransmitted _: Int64,
        serverReceived _: Int64,
        serverTransmitted _: Int64,
        clientReceived _: Int64
    ) {}

    func serverTimeToLocal(_ serverTime: Int64) -> Int64 {
        if anchorToNow {
            return MonotonicClock.absoluteMicroseconds() + serverTime
        }
        // Stub: local = server - offset
        return serverTime - offset
    }

    func localTimeToServer(_ localTime: Int64) -> Int64 {
        if anchorToNow {
            return localTime - MonotonicClock.absoluteMicroseconds()
        }
        // Stub: server = local + offset (inverse of serverTimeToLocal)
        return localTime + offset
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

/// Mock audio output that records all calls and allows control over behavior.
actor SpyAudioOutput: AudioOutput {
    var recordedCalls: [String] = []
    var forcedStartThrow: Error?
    var forcedSwapThrow: Error?
    var decodeDelay: TimeInterval = 0
    var forcedDecodeThrow: Error?
    var playbackState: Bool = false
    var underrunCountValue: Int64 = 0

    var isPlaying: Bool {
        playbackState
    }

    var telemetrySnapshot: AudioPlayer.TelemetrySnapshot {
        AudioPlayer.TelemetrySnapshot(
            cursorMicroseconds: 0,
            sampleRate: 48_000,
            syncErrorUs: 0,
            correctionSchedule: CorrectionSchedule(),
            underrunCount: underrunCountValue,
            pcmBytesDropped: 0
        )
    }

    func start(format: AudioFormatSpec, codecHeader _: Data?) throws {
        recordedCalls.append("start(\(format.codec))")
        if let error = forcedStartThrow {
            throw error
        }
        playbackState = true
    }

    func stop() {
        recordedCalls.append("stop()")
        playbackState = false
    }

    func swapDecoder(format: AudioFormatSpec, codecHeader _: Data?) throws {
        recordedCalls.append("swapDecoder(\(format.codec))")
        if let error = forcedSwapThrow {
            throw error
        }
    }

    func decode(_ data: Data) async throws -> Data {
        recordedCalls.append("decode(\(data.count) bytes)")
        if decodeDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(decodeDelay * 1_000_000_000))
        }
        if let error = forcedDecodeThrow {
            throw error
        }
        // Return a minimal PCM payload (2 samples per channel for testing)
        return Data(repeating: 0, count: 4)
    }

    func playPCM(_ pcm: Data, serverTimestamp _: Int64) throws {
        recordedCalls.append("playPCM(\(pcm.count) bytes)")
    }

    func clearBuffer() {
        recordedCalls.append("clearBuffer()")
    }

    func setVolume(_ gain: Float) {
        recordedCalls.append("setVolume(\(gain))")
    }

    func setMute(_ muted: Bool) {
        recordedCalls.append("setMute(\(muted))")
    }

    func updateTimeSnapshot(_: TimeFilterSnapshot) {
        recordedCalls.append("updateTimeSnapshot()")
    }

    func pollReanchor() -> Int64? {
        nil
    }

    func reanchorCursor(to _: Int64) {
        recordedCalls.append("reanchorCursor()")
    }
}

// MARK: - Tests

@Suite("AudioEngine isolation")
struct AudioEngineTests {
    /// AudioEngine processes commands in isolation and reports when rendering starts.
    @Test("streamStart and chunks yield EngineReport.started")
    func basicStreamStartAndChunks() async throws {
        let clock = StubClock(offsetMicroseconds: 0)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)

        await engine.start()

        let format = try AudioFormatSpec(
            codec: .pcm,
            channels: 2,
            sampleRate: 48_000,
            bitDepth: 16
        )

        // Enqueue and process streamStart + chunk
        await engine.commands.enqueue(.streamStart(format, codecHeader: nil))
        try? await Task.sleep(for: .milliseconds(100))
        await engine.commands.enqueue(.chunk(Data(repeating: 0, count: 100), ts: 1_000_000))
        try? await Task.sleep(for: .milliseconds(100))

        let started = await awaitReport(from: engine, timeoutMs: 100) {
            if case .started = $0 { true } else { false }
        }
        await engine.shutdown()

        #expect(started, "Should emit .started")

        // Assert scheduler received the chunk
        let stats = await scheduler.stats
        #expect(stats.received > 0)
    }

    @Test("static delay shifts scheduled timestamps by milliseconds converted to microseconds")
    func staticDelayAdjustsScheduledChunkTimestamp() async throws {
        let clock = StubClock(offsetMicroseconds: 0)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)

        await engine.start()

        let delayMs = 200
        let serverTimestamp = MonotonicClock.absoluteMicroseconds() + 60_000_000
        engine.commands.enqueue(.setStaticDelay(delayMs))
        engine.commands.enqueue(.chunk(Data(repeating: 0, count: 100), ts: serverTimestamp))

        let received = await waitUntil(timeout: .seconds(3)) { await scheduler.queuedChunks.count == 1 }
        let queued = await scheduler.queuedChunks
        await engine.shutdown()

        #expect(received, "Expected the chunk to reach the scheduler")
        let chunk = try #require(queued.first)
        #expect(chunk.originalTimestamp == serverTimestamp - Int64(delayMs) * 1_000)
        #expect(chunk.playTimeMicroseconds == serverTimestamp - Int64(delayMs) * 1_000)
    }

    /// Seamless format change is engine-internal (no MainActor.run).
    /// Drives runSchedulerOutput's rebuild path end-to-end: chunks are anchored near
    /// "now" so the scheduler actually emits them, the generation bump routes the new
    /// chunks through the rebuild, and `.formatApplied(fmt1)` is asserted in the reports.
    /// Mutation proof: removing `streamGeneration &+= 1` in applyFormatChange means
    /// scheduled chunks never change generation, runSchedulerOutput never rebuilds, and
    /// `.formatApplied` is never emitted → this test fails.
    @Test("seamless format change rebuilds and emits .formatApplied")
    func seamlessFormatChange() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        // Wide playbackWindow → load-independent delivery (matches formatAppliedReportedOnFirstNewGenChunk;
        // the default 50ms window can drop chunks late under parallel-suite timer starvation).
        let scheduler = AudioScheduler(clockSync: clock, playbackWindow: 30)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)

        await engine.start()

        let fmt0 = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let fmt1 = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)

        await engine.commands.enqueue(.streamStart(fmt0, codecHeader: nil))
        try? await Task.sleep(for: .milliseconds(100))

        // gen0 chunks, near-now timestamps so the scheduler emits them within its window.
        for i in 0 ..< 3 {
            await engine.commands.enqueue(.chunk(Data(repeating: UInt8(i), count: 100), ts: Int64(i) * 5_000))
        }
        try? await Task.sleep(for: .milliseconds(150))

        await engine.commands.enqueue(.formatChange(fmt1, codecHeader: nil))
        try? await Task.sleep(for: .milliseconds(50))

        // gen1 chunks: at least formatTransitionPreBuffer (2) must arrive for the rebuild
        // to complete and emit .formatApplied — send extra to clear the pre-buffer.
        for i in 0 ..< 4 {
            await engine.commands.enqueue(.chunk(Data(repeating: UInt8(i + 10), count: 100), ts: Int64(i + 4) * 5_000))
        }
        try? await Task.sleep(for: .milliseconds(400))

        let formatApplied = await awaitReport(from: engine, timeoutMs: 200) {
            if case let .formatApplied(applied) = $0 { applied == fmt1 } else { false }
        }
        await engine.shutdown()

        #expect(formatApplied)

        // The rehomed seamless logic must have swapped the decoder for the new format.
        let calls = await output.recordedCalls
        #expect(calls.contains { $0.hasPrefix("swapDecoder(") })

        // No chunk lost across the swap: every received chunk was either played or is
        // still queued — none counted as a (non-late) drop.
        let stats = await scheduler.stats
        #expect(stats.dropped == stats.droppedLate)
    }

    /// A deferred AudioQueue rebuild that fails must surface `.startFailed` rather
    /// than be silently swallowed: the seamless path reports `.formatApplied` at the
    /// commitment point (first new-gen chunk) before the rebuild, so a failed rebuild
    /// would otherwise leave the client believing the format switched while audio
    /// stops. Mutation proof: reverting the rebuild's do/catch to `try?` drops the
    /// `.startFailed` report → this test fails.
    @Test("a failed seamless rebuild surfaces .startFailed")
    func seamlessRebuildFailureReportsStartFailed() async throws {
        struct TestError: Error {}
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock, playbackWindow: 30)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)

        await engine.start()

        let fmt0 = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let fmt1 = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)

        await engine.commands.enqueue(.streamStart(fmt0, codecHeader: nil))
        try? await Task.sleep(for: .milliseconds(100))

        for i in 0 ..< 3 {
            await engine.commands.enqueue(.chunk(Data(repeating: UInt8(i), count: 100), ts: Int64(i) * 5_000))
        }
        try? await Task.sleep(for: .milliseconds(150))

        // Arm the deferred rebuild to fail: swapDecoder still succeeds (so we take the
        // deferred-rebuild path), but the rebuild's output.start() throws.
        await output.setForcedStartThrow(TestError())

        await engine.commands.enqueue(.formatChange(fmt1, codecHeader: nil))
        try? await Task.sleep(for: .milliseconds(50))

        for i in 0 ..< 4 {
            await engine.commands.enqueue(.chunk(Data(repeating: UInt8(i + 10), count: 100), ts: Int64(i + 4) * 5_000))
        }
        try? await Task.sleep(for: .milliseconds(400))

        let sawStartFailed = await awaitReport(from: engine, timeoutMs: 200) {
            if case .startFailed = $0 { true } else { false }
        }
        await engine.shutdown()

        #expect(sawStartFailed, "a failed deferred rebuild must report .startFailed")
    }

    /// Wait (up to `timeoutMs`) for a report matching `predicate`, consuming the
    /// engine's single-consumer report stream. Returns false on timeout.
    private func awaitReport(
        from engine: AudioEngine,
        timeoutMs: Int,
        where predicate: @escaping @Sendable (EngineReport) -> Bool
    ) async -> Bool {
        let result = await outcomeOfUnstructuredOperation(
            timeout: .milliseconds(timeoutMs),
            onTimeout: { await engine.shutdown() },
            operation: {
                for await report in engine.reports where predicate(report) {
                    return true
                }
                return false
            }
        )
        return (try? result?.get()) ?? false
    }

    /// `.formatApplied` is reported at the commitment
    /// point — the first new-generation chunk — NOT gated on the 2-chunk audio
    /// pre-buffer. With only ONE trailing new-format chunk and no shutdown, the
    /// report must still arrive promptly. Mutation proof: moving `yield(.formatApplied)`
    /// back below the `while preBuffer.count < formatTransitionPreBuffer …` loop makes
    /// runSchedulerOutput block on a 2nd chunk that never comes, so the report does
    /// not arrive within the window → this test fails (it only appears later, when
    /// shutdown's finish() unblocks the iterator).
    @Test(".formatApplied fires on the first new-generation chunk, not the pre-buffer threshold")
    func formatAppliedReportedOnFirstNewGenChunk() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        // Wide playback window so the single gen-1 chunk is never dropped-late under
        // parallel-suite load: the scheduler drops a chunk only when its timer task
        // wakes more than `playbackWindow` past the due time (AudioScheduler.checkQueue),
        // and under contention the default 50ms is easily exceeded — starving the one
        // chunk this test depends on. A 30s window makes delivery load-independent.
        let scheduler = AudioScheduler(clockSync: clock, playbackWindow: 30)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)

        await engine.start()

        let fmt0 = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let fmt1 = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)

        await engine.commands.enqueue(.streamStart(fmt0, codecHeader: nil))
        await engine.commands.enqueue(.chunk(Data(repeating: 1, count: 100), ts: 0))
        try? await Task.sleep(for: .milliseconds(100))

        await engine.commands.enqueue(.formatChange(fmt1, codecHeader: nil))
        // Exactly ONE new-generation chunk — fewer than formatTransitionPreBuffer (2).
        await engine.commands.enqueue(.chunk(Data(repeating: 2, count: 100), ts: 5_000))

        // Must arrive BEFORE shutdown — shutdown's finish() would unblock the old
        // (regressed) code path and mask the difference. The timeout is a generous
        // FAILURE bound, not a synchronization race: on the fixed code the report
        // arrives in ~100ms (awaitReport returns as soon as it matches); the bound is
        // only reached under the mutation, where the report never arrives without a
        // 2nd chunk. Sized well above scheduler-pipeline latency under parallel suite
        // load (a 700ms bound flaked there — it raced the happy path, not just failures).
        let sawFormatApplied = await awaitReport(from: engine, timeoutMs: 5_000) { report in
            if case let .formatApplied(applied) = report { return applied == fmt1 }
            return false
        }
        #expect(sawFormatApplied, ".formatApplied must be reported on the first new-gen chunk, before any 2nd chunk")

        await engine.shutdown()
    }

    /// A `swapDecoder` failure falls back to a full
    /// `output.start()` (re-establishing a valid decoder so new-format chunks are
    /// not decoded by the stale one) and still surfaces `.formatApplied`. Mutation
    /// proof: reverting `applyFormatChange`'s catch to log-only means no second
    /// `start(...)` call and no `.formatApplied` report → both assertions fail.
    @Test("swapDecoder failure restarts output and reports .formatApplied")
    func swapDecoderFailureFallsBackToRestart() async throws {
        struct TestError: Error {}

        let clock = StubClock()
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)

        await engine.start()

        let fmt0 = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let fmt1 = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)

        await engine.commands.enqueue(.streamStart(fmt0, codecHeader: nil))
        try? await Task.sleep(for: .milliseconds(100))

        await output.setForcedSwapThrow(TestError())
        await engine.commands.enqueue(.formatChange(fmt1, codecHeader: nil))
        try? await Task.sleep(for: .milliseconds(150))

        let formatApplied = await awaitReport(from: engine, timeoutMs: 100) {
            if case let .formatApplied(applied) = $0 { applied == fmt1 } else { false }
        }
        await engine.shutdown()

        #expect(formatApplied, "swap-failure fallback must still report .formatApplied")

        // Two start() calls: the initial streamStart and the swap-failure restart.
        let starts = await output.recordedCalls.filter { $0.hasPrefix("start(") }
        #expect(starts.count >= 2, "swap failure must trigger a fallback output.start(); got \(starts)")
    }

    /// Helper: run the telemetry loop across `ticks` underrun increments (one rise per
    /// 500ms poll), then report whether an operational-state report was emitted.
    private func observesUnderrunOperationalStateReport(
        external: Bool,
        ticks: Int = 3,
        where predicate: @escaping @Sendable (EngineReport) -> Bool
    ) async throws -> Bool {
        let clock = StubClock()
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)

        await engine.start()
        if external {
            await engine.setExternalSource(true)
        }

        // Drive a rising underrun count, one increment per telemetry tick (500ms poll).
        for i in 0 ... ticks {
            await output.setUnderrunCount(Int64(i))
            try? await Task.sleep(for: .milliseconds(600))
        }

        let emitted = await awaitReport(from: engine, timeoutMs: 200, where: predicate)
        await engine.shutdown()
        return emitted
    }

    /// DEFECT 1 (positive control): while participating, a rising underrun count must
    /// drive an `.operationalState(.error)` report. Guards the observe→emit path so the
    /// suppression test below can't pass merely because the loop is dead.
    @Test("Underrun while participating reports .operationalState(.error)")
    func underrunReportsErrorWhileParticipating() async throws {
        let emitted = try await observesUnderrunOperationalStateReport(external: false) {
            if case .operationalState(.error) = $0 { true } else { false }
        }
        #expect(emitted)
    }

    /// Startup underrun-grace boundary: the deterministic burst of prime/fill
    /// underruns after a fresh AudioQueue start must be absorbed for the WHOLE
    /// window, including the expiry tick. If the expiry tick observed instead of
    /// absorbing, a prime underrun landing at the boundary would trip a spurious
    /// mute ~window-length into playback — an audible mid-stream dropout.
    @Test("Underrun grace absorbs through the expiry tick (gap-free), then monitors")
    func underrunGraceAbsorbsThroughExpiry() {
        let now = ContinuousClock.now
        let future = now.advanced(by: .seconds(1))
        let past = now.advanced(by: .seconds(-1))

        // No window armed → monitor immediately (fall through to observe()).
        let noWindow = AudioEngine.underrunGraceTick(deadline: nil, now: now)
        #expect(!noWindow.absorb)
        #expect(noWindow.deadline == nil)

        // Inside the window → absorb, deadline preserved for subsequent ticks.
        let inside = AudioEngine.underrunGraceTick(deadline: future, now: now)
        #expect(inside.absorb)
        #expect(inside.deadline == future)

        // AT expiry → STILL absorb (the gap fix) and clear the deadline so the NEXT
        // tick monitors from a settled baseline. A regression that observed on the
        // expiry tick would make `absorb` false here and reintroduce the mute.
        let atExpiry = AudioEngine.underrunGraceTick(deadline: now, now: now)
        #expect(atExpiry.absorb)
        #expect(atExpiry.deadline == nil)

        // Past expiry (e.g. a long telemetry gap) → absorb once more, deadline cleared.
        let afterExpiry = AudioEngine.underrunGraceTick(deadline: past, now: now)
        #expect(afterExpiry.absorb)
        #expect(afterExpiry.deadline == nil)
    }

    /// DEFECT 1 (the fix): while external source is active, the engine must re-baseline
    /// and emit NOTHING — a starved device isn't our error, and any report would clobber
    /// the client's externalSource state. Mutation proof: deleting the `else { resetBaseline }`
    /// branch (always observe) makes the rising count emit `.operationalState(.error)`, so
    /// `hasOperationalState` becomes true → this test fails.
    @Test("Underrun while external source emits no operational-state report")
    func underrunSuppressedWhileExternalSource() async throws {
        let emitted = try await observesUnderrunOperationalStateReport(external: true) {
            if case .operationalState = $0 { true } else { false }
        }
        #expect(!emitted)
    }

    // MARK: - Spec §Playback Synchronization: mute on error, restore on recovery

    /// Drive the telemetry loop into the error state (rising underrun count),
    /// optionally entering external source after the error, optionally holding the
    /// count stable long enough to recover (`recoveryTicks = 2` at the 500 ms poll).
    /// Returns the recorded `setMute` calls for inspection.
    private func driveUnderrunMuteScenario(
        userMutedFirst: Bool = false,
        goExternalAfterError: Bool = false,
        recover: Bool
    ) async throws -> [String] {
        let clock = StubClock()
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)

        await engine.start()
        if userMutedFirst {
            await engine.setMuted(true)
        }

        // Rising count: the loop observes 1 > 0 and transitions to error.
        for i in 0 ... 1 {
            await output.setUnderrunCount(Int64(i))
            try? await Task.sleep(for: .milliseconds(600))
        }

        if goExternalAfterError {
            await engine.setExternalSource(true)
            try? await Task.sleep(for: .milliseconds(600))
        }

        if recover {
            // Hold the count stable for > recoveryTicks polls to recover.
            try? await Task.sleep(for: .milliseconds(1_800))
        }

        await engine.shutdown()
        return await output.recordedCalls.filter { $0.hasPrefix("setMute(") }
    }

    /// Spec: on cannot-maintain-sync the client must MUTE its audio output (not
    /// just report `state: 'error'`). Mutation proof: remove the safety mute on
    /// `.toError` and no `setMute(true)` is ever recorded.
    @Test("Underrun error transition mutes the output")
    func underrunErrorMutesOutput() async throws {
        let muteCalls = try await driveUnderrunMuteScenario(recover: false)
        // .first, not .last: under suite load the monitor can see two stable polls
        // before shutdown and legitimately recover (recovery itself is pinned by
        // the dedicated recovery tests). The contract HERE is that entering the
        // error state mutes — and with no user mute, that must be the first call.
        #expect(
            muteCalls.first == "setMute(true)",
            "entering error must safety-mute the output; got \(muteCalls)"
        )
    }

    /// Spec: after recovery (`state: 'synchronized'`) audible playback resumes —
    /// the safety mute must lift for a user who is not muted.
    @Test("Underrun recovery restores unmuted output")
    func underrunRecoveryRestoresUnmutedOutput() async throws {
        let muteCalls = try await driveUnderrunMuteScenario(recover: true)
        #expect(
            muteCalls.contains("setMute(true)"),
            "positive control: the error leg must have muted; got \(muteCalls)"
        )
        #expect(
            muteCalls.last == "setMute(false)",
            "recovery must lift the safety mute; got \(muteCalls)"
        )
    }

    /// The safety mute is OR'd with user mute: recovery must NOT unmute a player
    /// the user muted. Mutation proof: make the recovery path call
    /// `setMute(false)` unconditionally and this fails.
    @Test("Underrun recovery preserves an explicit user mute")
    func underrunRecoveryPreservesUserMute() async throws {
        let muteCalls = try await driveUnderrunMuteScenario(userMutedFirst: true, recover: true)
        #expect(
            muteCalls.first == "setMute(true)",
            "positive control: the user mute must reach the output; got \(muteCalls)"
        )
        #expect(
            !muteCalls.contains("setMute(false)"),
            "recovery must never unmute a user-muted output; got \(muteCalls)"
        )
    }

    /// Entering external source drops the tracked error without a transition
    /// (`resetBaseline`), so it must also clear the safety mute — otherwise the
    /// output comes back from external source permanently silenced.
    @Test("Entering external source clears the safety mute")
    func externalSourceClearsSafetyMute() async throws {
        let muteCalls = try await driveUnderrunMuteScenario(goExternalAfterError: true, recover: false)
        #expect(
            muteCalls.contains("setMute(true)"),
            "positive control: the error leg must have muted; got \(muteCalls)"
        )
        #expect(
            muteCalls.last == "setMute(false)",
            "external source must clear the safety mute; got \(muteCalls)"
        )
    }

    // MARK: - Single-use lifecycle

    /// The engine is single-use: `start()` after `shutdown()` must be a no-op.
    /// Pre-fix, a post-shutdown start() passed `guard !running`, reset
    /// `shuttingDown`, and respawned the telemetry task — a zombie loop that
    /// could drive real `output.setMute` calls against a closed output.
    @Test("start() after shutdown() is a no-op (no zombie telemetry)")
    func startAfterShutdownIsNoOp() async {
        let clock = StubClock()
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)

        await engine.start()
        await engine.shutdown()
        let callsAfterShutdown = await output.recordedCalls.count

        await engine.start()
        // Drive a rising underrun count: a zombie telemetry loop would observe
        // the rise, enter the error state, and safety-mute the output.
        for i in 0 ... 1 {
            await output.setUnderrunCount(Int64(i))
            try? await Task.sleep(for: .milliseconds(600))
        }

        let newCalls = await output.recordedCalls.dropFirst(callsAfterShutdown)
        #expect(
            !newCalls.contains { $0.hasPrefix("setMute(") },
            "a shut-down engine must stay dead; zombie telemetry drove: \(Array(newCalls))"
        )
    }

    /// Start failures surface as engine reports rather than being silently ignored.
    @Test("start failure surfaces as EngineReport.startFailed")
    func startFailureReport() async throws {
        struct TestError: Error, CustomStringConvertible {
            var description: String {
                "Test start error"
            }
        }

        let clock = StubClock()
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)

        await engine.start()

        await output.setForcedStartThrow(TestError())

        let fmt = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        await engine.commands.enqueue(.streamStart(fmt, codecHeader: nil))
        try? await Task.sleep(for: .milliseconds(200))

        let startOutcomeResult: Result<EngineReport?, Error>? = await outcomeOfUnstructuredOperation(
            timeout: .milliseconds(100),
            onTimeout: { await engine.shutdown() },
            operation: {
                for await report in engine.reports {
                    if case .startFailed = report { return report }
                    if case .started = report { return report }
                }
                return nil
            }
        )
        let startOutcome = try? startOutcomeResult?.get()
        await engine.shutdown()

        let sawStartFailed = if case .startFailed = startOutcome {
            true
        } else {
            false
        }
        #expect(sawStartFailed)
    }

    /// Shutdown terminates all tasks so the engine can deallocate.
    @Test("shutdown terminates all tasks and deallocates the engine")
    func shutdownDeallocProof() async throws {
        var engine: AudioEngine? = AudioEngine(
            output: SpyAudioOutput(),
            scheduler: AudioScheduler(clockSync: StubClock()),
            clock: StubClock()
        )
        weak let weakEngine = engine

        await engine?.start()

        let fmt = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        await engine?.commands.enqueue(.streamStart(fmt, codecHeader: nil))
        try? await Task.sleep(for: .milliseconds(100))

        // Shutdown and release
        await engine?.shutdown()
        engine = nil

        // The subject of this test: no spawned task retained the engine, so the
        // weak ref is nil once the strong ref is dropped. (No wall-clock timing
        // assertion here — shutdown promptness can't be tested with a stopwatch
        // without flaking when the machine is briefly starved, e.g. post-build
        // Spotlight indexing.)
        #expect(weakEngine == nil)
    }

    /// Shutdown drains buffered commands so command depth reaches zero.
    @Test("shutdown drains buffered commands and returns depth to zero")
    func shutdownDrainsBufferedCommands() async throws {
        let clock = StubClock()
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)

        await engine.start()

        let fmt = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)

        // Enqueue several commands
        await engine.commands.enqueue(.streamStart(fmt, codecHeader: nil))
        for i in 0 ..< 5 {
            await engine.commands.enqueue(.chunk(Data(repeating: UInt8(i), count: 100), ts: Int64(i) * 1_000_000))
        }
        engine.commands.enqueue(.streamEnd(roles: nil))

        // Shutdown
        await engine.shutdown()

        // Depth must reach 0 (all commands drained and decremented)
        let depth = engine.commands.depth
        #expect(depth == 0)
    }

    /// streamEnd truncates scheduled-but-unplayed audio (immediate stop, not
    /// drain-to-completion). Ten chunks are queued far in the future so none play before
    /// the end; streamEnd must clear them. Mutation proof: removing audioScheduler.clear()
    /// from applyStreamEnd leaves queueSize == 10 → this test fails.
    @Test("streamEnd truncates queued-but-unplayed audio")
    func streamEndTruncation() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)

        await engine.start()

        let fmt = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        await engine.commands.enqueue(.streamStart(fmt, codecHeader: nil))
        try? await Task.sleep(for: .milliseconds(100))

        // Far-future timestamps (~10s ahead): queued but never within the playback window,
        // so they sit unplayed until the stream ends.
        let chunkCount = 10
        for i in 0 ..< chunkCount {
            await engine.commands.enqueue(.chunk(Data(repeating: UInt8(i), count: 100), ts: 10_000_000 + Int64(i) * 1_000))
        }
        try? await Task.sleep(for: .milliseconds(150))

        // All chunks should be queued and unplayed before the end.
        let before = await scheduler.stats
        #expect(before.queueSize == chunkCount)
        #expect(before.played == 0)

        engine.commands.enqueue(.streamEnd(roles: nil))
        try? await Task.sleep(for: .milliseconds(100))

        let kinds = await engine.appliedCommandKinds()
        #expect(kinds.last == .streamEnd)
        let isPlayingAfter = await output.isPlaying
        #expect(!isPlayingAfter)

        // Truncation: the queue is cleared and nothing was played to completion.
        let after = await scheduler.stats
        #expect(after.received == chunkCount)
        #expect(after.played == 0)
        #expect(after.queueSize == 0)

        await engine.shutdown()
    }

    /// The decode-discard gate (`guard !shuttingDown` at the head of `apply()`):
    /// commands buffered behind an in-flight slow decode must be discarded once
    /// shutdown begins, never decoded or played. This is also the freeze-robust
    /// guarantee that a slow decode does not block shutdown from making progress:
    /// it counts decodes (deleting the gate decodes the buffered chunk and fails)
    /// rather than stopwatching wall-clock shutdown time, which flakes under load.
    @Test("Shutdown discards commands buffered behind an in-flight decode")
    func shutdownDiscardsBufferedCommandsBehindSlowDecode() async throws {
        let clock = StubClock()
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)

        await engine.start()
        await output.setDecodeDelay(1.0)

        let fmt = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        await engine.commands.enqueue(.streamStart(fmt, codecHeader: nil))
        await engine.commands.enqueue(.chunk(Data(repeating: 0, count: 100), ts: 1_000_000))
        // Positively wait for the first chunk to ENTER its slow decode (a fixed
        // sleep flakes under suite load: shutdown would discard both chunks).
        #expect(
            await waitUntil {
                await output.recordedCalls.contains(where: { $0.hasPrefix("decode(") })
            },
            "positive control: the first chunk must begin decoding before shutdown"
        )
        await engine.commands.enqueue(.chunk(Data(repeating: 1, count: 100), ts: 1_025_000))

        // shutdown() sets shuttingDown mid-decode, then awaits the drain, which
        // must discard the buffered second chunk at the apply() gate.
        await engine.shutdown()

        let decodes = await output.recordedCalls.count(where: { $0.hasPrefix("decode(") })
        #expect(decodes == 1, "the buffered chunk must be discarded at the gate, not decoded; got \(decodes)")
        let plays = await output.recordedCalls.filter { $0.hasPrefix("playPCM(") }
        #expect(plays.isEmpty, "no decoded PCM may reach playPCM across shutdown; got \(plays)")
    }
}

/// Helpers for SpyAudioOutput mutation
extension SpyAudioOutput {
    func setForcedStartThrow(_ error: Error) {
        forcedStartThrow = error
    }

    func setForcedSwapThrow(_ error: Error) {
        forcedSwapThrow = error
    }

    func setDecodeDelay(_ delay: TimeInterval) {
        decodeDelay = delay
    }

    func setUnderrunCount(_ count: Int64) {
        underrunCountValue = count
    }
}
