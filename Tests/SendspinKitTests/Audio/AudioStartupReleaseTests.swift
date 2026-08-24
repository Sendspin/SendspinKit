// ABOUTME: Tests startup release timing helpers for primed AudioQueue startup.
// ABOUTME: Covers startup release timing and join-in-progress stale chunk selection.
import Foundation
@testable import SendspinKit
import Testing

@Suite("Audio startup release")
struct AudioStartupReleaseTests {
    /// Startup timing follows the server's schedule, not a local accumulation target.
    /// The server already schedules the first chunk far enough ahead; `min_buffer_ms` is a
    /// request for ongoing depth during playback, not a precondition for starting.
    @Test("startup releases on the first chunk's play time regardless of buffered span")
    func startupReleasesOnFirstChunkPlayTime() {
        let firstPlayTime: Int64 = 1_000_000
        let startupLeadUs: Int64 = 92_000
        let nowUs = firstPlayTime - 5_000_000 // well before playback is due

        // A single chunk — the shortest possible stream, far under any min-buffer.
        let single = AudioEngine.startupReleaseCandidate(
            playTimes: [firstPlayTime],
            nowUs: nowUs,
            startupLeadUs: startupLeadUs
        )
        #expect(single?.index == 0)
        #expect(single?.releaseTimeUs == firstPlayTime - startupLeadUs)

        // Adding more content does not change when we start.
        let longer = AudioEngine.startupReleaseCandidate(
            playTimes: [firstPlayTime, firstPlayTime + 20_000, firstPlayTime + 40_000],
            nowUs: nowUs,
            startupLeadUs: startupLeadUs
        )
        #expect(longer?.releaseTimeUs == single?.releaseTimeUs)
    }

    /// `buffer_capacity` caps queued duration below the requested `min_buffer_ms`,
    /// which the spec explicitly permits for high byte-rate codecs. Such a
    /// stream is perfectly normal and must start.
    @Test("a stream whose queued duration stays under min-buffer still starts")
    func capacityBoundStreamStillStarts() {
        let firstPlayTime: Int64 = 1_000_000
        let startupLeadUs: Int64 = 92_000
        let minBufferUs = Int64(defaultMinBufferMs) * 1_000
        // Queued duration permanently below the requested minimum.
        let playTimes = [firstPlayTime, firstPlayTime + minBufferUs / 4]

        let candidate = AudioEngine.startupReleaseCandidate(
            playTimes: playTimes,
            nowUs: firstPlayTime - 1_000_000,
            startupLeadUs: startupLeadUs
        )

        #expect(candidate?.index == 0)
        #expect(candidate?.releaseTimeUs == firstPlayTime - startupLeadUs)
    }

    @Test("startup release candidate skips stale join-in-progress chunks")
    func startupReleaseCandidateSkipsStaleJoinInProgressChunks() {
        let firstPlayTime: Int64 = 1_000_000
        let chunkStepUs: Int64 = 100_000
        let playTimes = (0 ... 7).map { firstPlayTime + Int64($0) * chunkStepUs }
        let startupLeadUs: Int64 = 90_000
        let nowUs = playTimes[0] - startupLeadUs + CorrectionPlanner.defaultEngageUs + 1

        let candidate = AudioEngine.startupReleaseCandidate(
            playTimes: playTimes,
            nowUs: nowUs,
            startupLeadUs: startupLeadUs
        )
        #expect(candidate?.index == 1)
        #expect(candidate?.releaseTimeUs == playTimes[1] - startupLeadUs)
    }

    /// Every buffered chunk is already too late to start on, so there is nothing to start:
    /// wait for a chunk far enough ahead rather than beginning mid-chunk.
    @Test("startup release candidate waits when every buffered chunk is stale")
    func startupReleaseCandidateWaitsWhenAllChunksAreStale() {
        let firstPlayTime: Int64 = 1_000_000
        let startupLeadUs: Int64 = 92_000
        let playTimes = [firstPlayTime, firstPlayTime + 20_000]
        // Past the last chunk's start moment, beyond the lateness tolerance.
        let nowUs = playTimes[1] - startupLeadUs + CorrectionPlanner.defaultEngageUs + 1

        let candidate = AudioEngine.startupReleaseCandidate(
            playTimes: playTimes,
            nowUs: nowUs,
            startupLeadUs: startupLeadUs
        )
        #expect(candidate == nil)
    }

    /// `serverTimeToLocal` saturates rather than trapping, so a malformed wire timestamp
    /// reaches this helper sitting at the `Int64` bounds. Unguarded, `playTime -
    /// startupLeadUs` traps at `Int64.min` and kills the engine actor.
    @Test("startup release candidate skips unrepresentable play times")
    func startupReleaseCandidateSkipsUnrepresentablePlayTimes() {
        let startupLeadUs: Int64 = 92_000
        let nowUs: Int64 = 1_700_000_000_000_000
        let viable = nowUs + 500_000

        let candidate = AudioEngine.startupReleaseCandidate(
            playTimes: [.min, Int64.min + 1, viable],
            nowUs: nowUs,
            startupLeadUs: startupLeadUs
        )

        #expect(candidate?.index == 2, "the saturated entries must be skipped, not selected")
        #expect(candidate?.releaseTimeUs == viable - startupLeadUs)
    }

    /// A play time saturated at `Int64.max` does not overflow, so it is selected — and the
    /// resulting release instant is ~292,000 years out. The wait must end so the release
    /// is re-examined instead of committing for the life of the process.
    @Test("an absurd release instant yields a bounded wait, not a permanent one")
    func absurdReleaseInstantYieldsBoundedWait() throws {
        let nowUs: Int64 = 1_700_000_000_000_000
        let candidate = AudioEngine.startupReleaseCandidate(
            playTimes: [.max],
            nowUs: nowUs,
            startupLeadUs: 92_000
        )
        let releaseTime = try #require(candidate?.releaseTimeUs)

        #expect(
            AudioEngine.startupWaitMicroseconds(releaseTimeUs: releaseTime, nowUs: nowUs)
                == AudioEngine.startupRecheckIntervalUs
        )
    }

    /// The wait stops short of the release instant so the final approach can use
    /// `yieldUntilReleaseInstant`. Sleeping the exact remainder can overshoot the target
    /// because timer granularity adds scheduling error.
    @Test("a wait stops short of the release instant")
    func waitStopsShortOfReleaseInstant() {
        let nowUs: Int64 = 1_700_000_000_000_000
        let remainingUs = AudioEngine.startupRecheckIntervalUs / 2
        let releaseTime = nowUs + remainingUs

        #expect(
            AudioEngine.startupWaitMicroseconds(releaseTimeUs: releaseTime, nowUs: nowUs)
                == remainingUs - AudioEngine.startupSpinThresholdUs
        )
    }

    /// Inside the spin window there is nothing left to sleep for: the remaining distance is
    /// closed by yielding, so any sleep here would only overshoot it.
    @Test("a release inside the spin window is not slept for at all")
    func imminentReleaseIsNotSlept() {
        let nowUs: Int64 = 1_700_000_000_000_000
        let releaseTime = nowUs + AudioEngine.startupSpinThresholdUs / 2

        #expect(AudioEngine.startupWaitMicroseconds(releaseTimeUs: releaseTime, nowUs: nowUs) == 0)
    }

    /// The yield loop handles only the final approach. A still-distant instant belongs to
    /// another sleep hop, so it must be declined without polling.
    @Test("the yield loop declines a distant release instant")
    func yieldLoopDeclinesDistantInstant() async {
        let distant = MonotonicClock.absoluteMicroseconds() + AudioEngine.startupSpinThresholdUs * 10

        let start = MonotonicClock.absoluteMicroseconds()
        await AudioEngine.yieldUntilReleaseInstant(distant)
        let elapsed = MonotonicClock.absoluteMicroseconds() - start

        // Between the cost of declining (an actor hop) and the cost of not declining
        // (the full budget), so neither load nor scheduling noise can flip the verdict.
        #expect(
            elapsed < AudioEngine.startupSpinThresholdUs * 2,
            "declining must not poll: took \(elapsed)us"
        )
    }

    /// A due wait releases the chunk it was armed for even when wake-up exceeds the lateness
    /// tolerance. Re-testing lateness would incorrectly slide a deliberately scheduled start
    /// to the next chunk.
    @Test("a release the wait was armed for survives a late wake")
    func awaitedReleaseSurvivesLateWake() {
        let startupLeadUs: Int64 = 100_000
        let playTimes: [Int64] = [1_000_000, 1_100_000]
        let awaited = playTimes[0] - startupLeadUs
        // Woken an order of magnitude later than the tolerance permits.
        let nowUs = awaited + CorrectionPlanner.defaultEngageUs * 10

        let honoured = AudioEngine.releaseSelection(
            playTimes: playTimes,
            nowUs: nowUs,
            startupLeadUs: startupLeadUs,
            awaitedReleaseTimeUs: awaited
        )
        #expect(honoured?.index == 0, "the awaited chunk must be released, not skipped")
        #expect(honoured?.releaseTimeUs == awaited)

        // With no wait to honour, the same chunk is correctly skipped as unplayable.
        let unawaited = AudioEngine.releaseSelection(
            playTimes: playTimes,
            nowUs: nowUs,
            startupLeadUs: startupLeadUs,
            awaitedReleaseTimeUs: nil
        )
        #expect(unawaited?.index == 1, "a chunk nobody waited for stays subject to the tolerance")
    }

    /// The wait sleeps through the schedule rather than polling it. Cancellation ends a
    /// superseded wait, and its token prevents a late continuation from re-arming it.
    @Test("the startup wait sleeps through the schedule rather than polling it")
    func startupWaitDoesNotPoll() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock, enableStartupBuffering: true)
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        await engine.start()

        await engine.commands.enqueue(.streamStart(format, codecHeader: nil))
        for index in 0 ..< 8 {
            await engine.commands.enqueue(
                .chunk(Data(repeating: UInt8(index), count: 100), ts: 500_000 + Int64(index) * 100_000)
            )
        }

        #expect(
            await waitUntil(timeout: .seconds(3)) { await output.recordedCalls.contains("startPrepared()") },
            "the stream must start"
        )
        let evaluations = await engine.startupReleaseEvaluations
        await engine.shutdown()

        // One evaluation per chunk arrival plus one per sleep hop keeps this well below a
        // polling loop, while allowing for scheduling noise.
        #expect(evaluations < 200, "the release was evaluated \(evaluations) times — the wait is polling")
    }

    /// Later chunks must not replace a pending deadline when the earliest candidate is unchanged.
    @Test("later startup chunks keep the existing release deadline")
    func laterChunksKeepExistingReleaseDeadline() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock, enableStartupBuffering: true)
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        await engine.start()
        await engine.commands.enqueue(.streamStart(format, codecHeader: nil))

        let firstTimestamp: Int64 = 1_000_000
        await output.blockNextOutputDeviceProbe()
        await engine.commands.enqueue(.chunk(Data(repeating: 0x01, count: 100), ts: firstTimestamp))
        #expect(
            await waitUntil(timeout: .seconds(5)) { await output.outputDeviceProbeCount == 1 },
            "the first release must reach the device probe before later chunks are processed"
        )

        let laterChunkCount = 32
        for index in 0 ..< laterChunkCount {
            await engine.commands.enqueue(
                .chunk(
                    Data(repeating: UInt8(index + 2), count: 100),
                    ts: firstTimestamp + Int64(index + 1) * 100_000
                )
            )
        }
        let expectedChunkCount = laterChunkCount + 1
        #expect(
            await waitUntil { await engine.appliedCommandKinds().count(where: { $0 == .chunk }) == expectedChunkCount },
            "the later chunks must be processed before checking deadline churn"
        )
        let callsBeforeRelease = await output.recordedCalls
        #expect(!callsBeforeRelease.contains("startPrepared()"))
        await output.releaseBlockedOutputDeviceProbe()

        #expect(
            await waitUntil(timeout: .seconds(3)) { await output.recordedCalls.contains("startPrepared()") },
            "the original deadline must still produce one startup commit"
        )
        let commits = await engine.startupReleaseCommits
        let calls = await output.recordedCalls
        await engine.shutdown()

        #expect(commits == 1)
        #expect(calls.count(where: { $0 == "startPrepared()" }) == 1)
    }

    /// And the yield loop must genuinely wait for an imminent instant. Returning early is what
    /// a sleep does, and what leaves the release outside the tolerance.
    @Test("the yield loop waits for an imminent release instant")
    func yieldLoopWaitsForImminentInstant() async {
        // Inside the spin window, so the loop engages rather than declining.
        let target = MonotonicClock.absoluteMicroseconds() + AudioEngine.startupSpinThresholdUs / 4

        await AudioEngine.yieldUntilReleaseInstant(target)

        #expect(MonotonicClock.absoluteMicroseconds() >= target, "returned before the release instant")
    }

    /// A legitimately distant schedule (servers pre-buffer tens of seconds) is not an
    /// error: it sleeps one interval and re-checks, rather than being truncated to play
    /// early or rejected outright.
    @Test("a distant release sleeps one interval and re-checks")
    func distantReleaseSleepsOneInterval() {
        let nowUs: Int64 = 1_700_000_000_000_000
        let twentyFiveSecondsUs: Int64 = 25_000_000
        let releaseTime = nowUs + twentyFiveSecondsUs

        #expect(
            AudioEngine.startupWaitMicroseconds(releaseTimeUs: releaseTime, nowUs: nowUs)
                == AudioEngine.startupRecheckIntervalUs
        )
    }

    /// The all-stale branch deliberately arms no timer because advancing the clock cannot
    /// make stale chunks viable. A newly arrived chunk re-enters startup evaluation and can
    /// provide the first viable release point.
    @Test("a stream whose first chunks are stale still starts when a viable chunk arrives")
    func staleFirstChunksDoNotStallStartup() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock, enableStartupBuffering: true)
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        await engine.start()
        await engine.commands.enqueue(.streamStart(format, codecHeader: nil))

        // Past-dated on arrival, so every one is beyond the lateness tolerance.
        let staleCount = 3
        for index in 0 ..< staleCount {
            await engine.commands.enqueue(
                .chunk(Data(repeating: UInt8(index), count: 100), ts: -1_000_000 + Int64(index) * 20_000)
            )
        }

        // Wait until the engine has applied them so the next assertion observes processing,
        // not merely a delayed command queue.
        #expect(
            await waitUntil { await engine.appliedCommandKinds().count(where: { $0 == .chunk }) == staleCount },
            "the stale chunks should have reached the engine"
        )
        #expect(
            await !output.recordedCalls.contains("startPrepared()"),
            "no buffered chunk is viable, so output must not have started"
        )

        // A viable, future-dated chunk arrives; appending it re-enters startup evaluation.
        await engine.commands.enqueue(.chunk(Data(repeating: 0xAA, count: 100), ts: 1_500_000))

        #expect(
            await waitUntil(timeout: .seconds(3)) { await output.recordedCalls.contains("startPrepared()") },
            "the newly arrived viable chunk must start the stream"
        )
        await engine.shutdown()
    }

    @Test("startup release remains single-flight while a deadline probe is suspended")
    func startupReleaseRemainsSingleFlightWhileDeadlineProbeIsSuspended() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(
            output: output,
            scheduler: scheduler,
            clock: clock,
            enableStartupBuffering: true,
            startupMinBufferMs: 200
        )
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        await engine.start()
        await engine.commands.enqueue(.streamStart(format, codecHeader: nil))

        // Second arrival lands while the deadline task is suspended in the device-live probe;
        // without the deferred mailbox the stale snapshot drops or duplicates one timestamp.
        let firstTimestamp: Int64 = 1_000_000
        let secondTimestamp: Int64 = 1_100_000
        await output.blockNextOutputDeviceProbe()
        await engine.commands.enqueue(.chunk(Data(repeating: 0x01, count: 100), ts: firstTimestamp))
        #expect(await waitUntil { await output.outputDeviceProbeCount >= 1 })
        await engine.commands.enqueue(.chunk(Data(repeating: 0x02, count: 100), ts: secondTimestamp))
        #expect(
            await waitUntil { await engine.appliedCommandKinds().count(where: { $0 == .chunk }) == 2 },
            "the second chunk must be applied while the release probe is suspended"
        )
        await output.releaseBlockedOutputDeviceProbe()

        #expect(await waitUntil(timeout: .seconds(3)) { await output.recordedCalls.contains("startPrepared()") })
        let calls = await output.recordedCalls
        let playedTimestamps = await output.playedPCMTimestamps
        let commits = await engine.startupReleaseCommits
        await engine.shutdown()

        #expect(calls.count(where: { $0 == "startPrepared()" }) == 1)
        #expect(commits == 1)
        #expect(playedTimestamps.sorted() == [firstTimestamp, secondTimestamp])
    }

    @Test("chunks arriving during PCM priming are scheduled after the startup commit")
    func chunksDuringPCMPrimingAreDeferredUntilAfterCommit() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(
            output: output,
            scheduler: scheduler,
            clock: clock,
            enableStartupBuffering: true,
            startupMinBufferMs: 200
        )
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let firstTimestamp: Int64 = 1_000_000
        let deferredTimestamp: Int64 = 1_100_000
        await engine.start()
        await engine.commands.enqueue(.streamStart(format, codecHeader: nil))
        await output.blockNextPCM()
        await engine.commands.enqueue(.chunk(Data(repeating: 0x01, count: 100), ts: firstTimestamp))
        #expect(await waitUntil { await output.playedPCMTimestamps.contains(firstTimestamp) })

        await engine.commands.enqueue(.chunk(Data(repeating: 0x02, count: 100), ts: deferredTimestamp))
        #expect(await waitUntil { await engine.appliedCommandKinds().count(where: { $0 == .chunk }) == 2 })
        #expect(await !output.recordedCalls.contains("startPrepared()"))
        await output.releaseBlockedPCM()

        #expect(await waitUntil(timeout: .seconds(3)) { await output.recordedCalls.contains("startPrepared()") })
        #expect(await waitUntil(timeout: .seconds(3)) { await scheduler.stats.received == 1 })
        let calls = await output.recordedCalls
        let timestamps = await output.playedPCMTimestamps
        let commits = await engine.startupReleaseCommits
        await engine.shutdown()

        let startIndex = try #require(calls.firstIndex(of: "startPrepared()"))
        #expect(timestamps == [firstTimestamp])
        #expect(calls[..<startIndex].filter { $0.hasPrefix("playPCM(") }.count == 1)
        #expect(commits == 1)
    }

    @Test("stream end invalidates a suspended startup release")
    func streamEndInvalidatesSuspendedStartupRelease() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock, enableStartupBuffering: true)
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        await engine.start()
        await engine.commands.enqueue(.streamStart(format, codecHeader: nil))
        await output.blockNextOutputDeviceProbe()
        await engine.commands.enqueue(.chunk(Data(repeating: 0x01, count: 100), ts: 1_000_000))
        #expect(await waitUntil { await output.outputDeviceProbeCount == 1 })
        await engine.commands.enqueue(.streamEnd(roles: ["player"]))
        #expect(await waitUntil { await engine.appliedCommandKinds().last == .streamEnd })
        await output.releaseBlockedOutputDeviceProbe()
        try? await Task.sleep(for: .milliseconds(100))

        let commits = await engine.startupReleaseCommits
        let calls = await output.recordedCalls
        await engine.shutdown()

        #expect(commits == 0)
        #expect(!calls.contains("startPrepared()"))
    }

    @Test("shutdown invalidates a suspended startup release")
    func shutdownInvalidatesSuspendedStartupRelease() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock, enableStartupBuffering: true)
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        await engine.start()
        await engine.commands.enqueue(.streamStart(format, codecHeader: nil))
        await output.blockNextOutputDeviceProbe()
        await engine.commands.enqueue(.chunk(Data(repeating: 0x01, count: 100), ts: 1_000_000))
        #expect(await waitUntil { await output.outputDeviceProbeCount == 1 })
        let shutdown = Task { await engine.shutdown() }
        await output.releaseBlockedOutputDeviceProbe()
        await shutdown.value

        let commits = await engine.startupReleaseCommits
        let calls = await output.recordedCalls
        #expect(commits == 0)
        #expect(!calls.contains("startPrepared()"))
    }

    @Test("startup buffering primes PCM before starting prepared output")
    func startupBufferingPrimesBeforeStartingOutput() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock, enableStartupBuffering: true)
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        await engine.start()
        await engine.commands.enqueue(.streamStart(format, codecHeader: nil))
        for index in 0 ..< 8 {
            await engine.commands.enqueue(.chunk(Data(repeating: UInt8(index), count: 100), ts: 500_000 + Int64(index) * 100_000))
        }
        #expect(await waitUntil(timeout: .seconds(3)) { await output.recordedCalls.contains("startPrepared()") })

        let calls = await output.recordedCalls
        await engine.shutdown()
        let prepare = try #require(calls.firstIndex { $0.hasPrefix("prepare(") })
        let play = try #require(calls.firstIndex { $0.hasPrefix("playPCM(") })
        let start = try #require(calls.firstIndex(of: "startPrepared()"))
        // The pre-fill inside startPrepared() reads the ring, so PCM must already be in it:
        // priming after the start is silence, and the corrector has to insert its way out.
        #expect(prepare < play && play < start)
    }

    /// End-to-end counterpart to `startupReleasesOnFirstChunkPlayTime`: a stream whose
    /// entire content is shorter than the requested min-buffer must still play.
    @Test("a stream shorter than min-buffer still starts")
    func shortStreamStarts() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        // Injected engines default this to 0, which would make the min-buffer irrelevant.
        let minBufferMs = 200
        let engine = AudioEngine(
            output: output,
            scheduler: scheduler,
            clock: clock,
            enableStartupBuffering: true,
            startupMinBufferMs: minBufferMs
        )
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        await engine.start()

        await engine.commands.enqueue(.streamStart(format, codecHeader: nil))
        // The lead leaves time for output latency and scheduling before the engine evaluates
        // the chunks, so this test exercises startup buffering rather than a late join.
        let leadUs: Int64 = 1_500_000
        for index in 0 ..< 3 {
            await engine.commands.enqueue(
                .chunk(Data(repeating: UInt8(index), count: 100), ts: leadUs + Int64(index) * 20_000)
            )
        }

        let report = await awaitFirstReport(from: engine, timeoutMs: 4_000) { report in
            if case .started = report {
                return true
            }
            if case .startFailed = report {
                return true
            }
            return false
        }
        let calls = await output.recordedCalls
        await engine.shutdown()

        guard case .started = report else {
            #expect(Bool(false), "a short stream must eventually start, not buffer forever")
            return
        }
        #expect(
            calls.contains("startPrepared()"),
            "the prepared output must be started"
        )
        #expect(
            calls.contains { $0.hasPrefix("playPCM(") },
            "the buffered chunks must be primed into the ring, not discarded"
        )
    }

    @Test("startup buffering does not report started if prepared output fails")
    func startupBufferingDoesNotReportStartedWhenPreparedOutputFails() async throws {
        struct TestError: Error {}
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        await output.setForcedStartPreparedThrow(TestError())
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock, enableStartupBuffering: true)
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        await engine.start()

        await engine.commands.enqueue(.streamStart(format, codecHeader: nil))
        for index in 0 ..< 8 {
            await engine.commands.enqueue(.chunk(Data(repeating: UInt8(index), count: 100), ts: 500_000 + Int64(index) * 100_000))
        }
        let firstTerminalReport = await awaitFirstReport(from: engine, timeoutMs: 3_000) { report in
            if case .started = report {
                return true
            }
            if case .startFailed = report {
                return true
            }
            return false
        }
        let callsBeforeShutdown = await output.recordedCalls
        await engine.shutdown()

        guard case .startFailed = firstTerminalReport else {
            #expect(Bool(false), "prepared-start failure must surface before any .started report")
            return
        }
        #expect(
            callsBeforeShutdown.contains("stop()"),
            "prepared-start failure must tear down the prepared output before shutdown cleanup"
        )
    }

    @Test("startup buffering does not report started if priming PCM fails")
    func startupBufferingDoesNotReportStartedWhenPrimingPCMFails() async throws {
        struct TestError: Error {}
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        await output.setForcedPlayPCMThrow(TestError())
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock, enableStartupBuffering: true)
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        await engine.start()

        await engine.commands.enqueue(.streamStart(format, codecHeader: nil))
        for index in 0 ..< 8 {
            await engine.commands.enqueue(.chunk(Data(repeating: UInt8(index), count: 100), ts: 500_000 + Int64(index) * 100_000))
        }
        let firstTerminalReport = await awaitFirstReport(from: engine, timeoutMs: 3_000) { report in
            if case .started = report {
                return true
            }
            if case .startFailed = report {
                return true
            }
            return false
        }
        let callsBeforeShutdown = await output.recordedCalls
        await engine.shutdown()

        guard case .startFailed = firstTerminalReport else {
            #expect(Bool(false), "priming failure must surface before any .started report")
            return
        }
        #expect(
            callsBeforeShutdown.contains("stop()"),
            "priming failure must tear down the prepared output before shutdown cleanup"
        )
    }

    @Test("repeated stream start uses prepared startup buffering")
    func repeatedStreamStartUsesPreparedStartupBuffering() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock, enableStartupBuffering: true)
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        await engine.start()

        await engine.commands.enqueue(.streamStart(format, codecHeader: nil))
        for index in 0 ..< 8 {
            await engine.commands.enqueue(.chunk(Data(repeating: UInt8(index), count: 100), ts: 500_000 + Int64(index) * 100_000))
        }
        #expect(await waitUntil(timeout: .seconds(3)) { await output.recordedCalls.contains("startPrepared()") })

        await engine.commands.enqueue(.streamStart(format, codecHeader: nil))
        for index in 0 ..< 8 {
            await engine.commands.enqueue(.chunk(Data(repeating: UInt8(index), count: 100), ts: 1_500_000 + Int64(index) * 100_000))
        }
        #expect(await waitUntil(timeout: .seconds(3)) { await output.recordedCalls.count(where: { $0 == "startPrepared()" }) == 2 })

        let calls = await output.recordedCalls
        await engine.shutdown()
        #expect(!calls.contains { $0.hasPrefix("start(") }, "prepared startup path must not fall back to direct start")
    }

    @Test("stream clear during startup buffering discards pre-clear chunks and re-primes")
    func streamClearDuringStartupBufferingReprimesWithPostClearChunks() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock, enableStartupBuffering: true)
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        await engine.start()

        await engine.commands.enqueue(.streamStart(format, codecHeader: nil))
        await engine.commands.enqueue(.chunk(Data(repeating: 0xAA, count: 100), ts: 500_000))
        engine.commands.enqueue(.streamClear(roles: ["player"]))
        for index in 0 ..< 8 {
            await engine.commands.enqueue(.chunk(Data(repeating: UInt8(index), count: 100), ts: 900_000 + Int64(index) * 100_000))
        }
        #expect(await waitUntil(timeout: .seconds(3)) { await output.recordedCalls.contains("startPrepared()") })

        let calls = await output.recordedCalls
        await engine.shutdown()
        let clear = try #require(calls.firstIndex(of: "clearBuffer()"))
        let firstPlay = try #require(calls.firstIndex { $0.hasPrefix("playPCM(") })
        let start = try #require(calls.firstIndex(of: "startPrepared()"))
        #expect(clear < firstPlay && firstPlay < start)
    }

    /// Wait (up to `timeoutMs`) for the first report matching `predicate`, consuming
    /// the engine's single-consumer report stream. Returns nil on timeout.
    private func awaitFirstReport(
        from engine: AudioEngine,
        timeoutMs: Int,
        where predicate: @escaping @Sendable (EngineReport) -> Bool
    ) async -> EngineReport? {
        let result = await outcomeOfUnstructuredOperation(
            timeout: .milliseconds(timeoutMs),
            onTimeout: { await engine.shutdown() },
            operation: { () async -> EngineReport? in
                for await report in engine.reports where predicate(report) {
                    return report
                }
                return nil
            }
        )
        return try? result?.get()
    }
}
