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
        let outputLatencyUs: Int64 = 92_000
        let nowUs = firstPlayTime - 5_000_000 // well before playback is due

        // A single chunk — the shortest possible stream, far under any min-buffer.
        let single = AudioEngine.startupReleaseCandidate(
            playTimes: [firstPlayTime],
            nowUs: nowUs,
            outputLatencyUs: outputLatencyUs
        )
        #expect(single?.index == 0)
        #expect(single?.releaseTimeUs == firstPlayTime - outputLatencyUs)

        // Adding more content does not change when we start.
        let longer = AudioEngine.startupReleaseCandidate(
            playTimes: [firstPlayTime, firstPlayTime + 20_000, firstPlayTime + 40_000],
            nowUs: nowUs,
            outputLatencyUs: outputLatencyUs
        )
        #expect(longer?.releaseTimeUs == single?.releaseTimeUs)
    }

    /// `buffer_capacity` caps queued duration below the requested `min_buffer_ms`,
    /// which the spec explicitly permits for high byte-rate codecs. Such a
    /// stream is perfectly normal and must start.
    @Test("a stream whose queued duration stays under min-buffer still starts")
    func capacityBoundStreamStillStarts() {
        let firstPlayTime: Int64 = 1_000_000
        let outputLatencyUs: Int64 = 92_000
        let minBufferUs = Int64(defaultMinBufferMs) * 1_000
        // Queued duration permanently below the requested minimum.
        let playTimes = [firstPlayTime, firstPlayTime + minBufferUs / 4]

        let candidate = AudioEngine.startupReleaseCandidate(
            playTimes: playTimes,
            nowUs: firstPlayTime - 1_000_000,
            outputLatencyUs: outputLatencyUs
        )

        #expect(candidate?.index == 0)
        #expect(candidate?.releaseTimeUs == firstPlayTime - outputLatencyUs)
    }

    @Test("startup release candidate skips stale join-in-progress chunks")
    func startupReleaseCandidateSkipsStaleJoinInProgressChunks() {
        let firstPlayTime: Int64 = 1_000_000
        let chunkStepUs: Int64 = 100_000
        let playTimes = (0 ... 7).map { firstPlayTime + Int64($0) * chunkStepUs }
        let outputLatencyUs: Int64 = 90_000
        let nowUs = playTimes[0] - outputLatencyUs + CorrectionPlanner.defaultEngageUs + 1

        let candidate = AudioEngine.startupReleaseCandidate(
            playTimes: playTimes,
            nowUs: nowUs,
            outputLatencyUs: outputLatencyUs
        )
        #expect(candidate?.index == 1)
        #expect(candidate?.releaseTimeUs == playTimes[1] - outputLatencyUs)
    }

    /// Every buffered chunk is already too late to start on, so there is nothing to start:
    /// wait for a chunk far enough ahead rather than beginning mid-chunk.
    @Test("startup release candidate waits when every buffered chunk is stale")
    func startupReleaseCandidateWaitsWhenAllChunksAreStale() {
        let firstPlayTime: Int64 = 1_000_000
        let outputLatencyUs: Int64 = 92_000
        let playTimes = [firstPlayTime, firstPlayTime + 20_000]
        // Past the last chunk's start moment, beyond the lateness tolerance.
        let nowUs = playTimes[1] - outputLatencyUs + CorrectionPlanner.defaultEngageUs + 1

        let candidate = AudioEngine.startupReleaseCandidate(
            playTimes: playTimes,
            nowUs: nowUs,
            outputLatencyUs: outputLatencyUs
        )
        #expect(candidate == nil)
    }

    /// `serverTimeToLocal` saturates rather than trapping, so a malformed wire timestamp
    /// reaches this helper sitting at the `Int64` bounds. Unguarded, `playTime -
    /// outputLatencyUs` traps at `Int64.min` and kills the engine actor.
    @Test("startup release candidate skips unrepresentable play times")
    func startupReleaseCandidateSkipsUnrepresentablePlayTimes() {
        let outputLatencyUs: Int64 = 92_000
        let nowUs: Int64 = 1_700_000_000_000_000
        let viable = nowUs + 500_000

        let candidate = AudioEngine.startupReleaseCandidate(
            playTimes: [.min, Int64.min + 1, viable],
            nowUs: nowUs,
            outputLatencyUs: outputLatencyUs
        )

        #expect(candidate?.index == 2, "the saturated entries must be skipped, not selected")
        #expect(candidate?.releaseTimeUs == viable - outputLatencyUs)
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
            outputLatencyUs: 92_000
        )
        let releaseTime = try #require(candidate?.releaseTimeUs)

        #expect(
            AudioEngine.startupWaitMicroseconds(releaseTimeUs: releaseTime, nowUs: nowUs)
                == AudioEngine.startupRecheckIntervalUs
        )
    }

    /// Once the release is closer than the re-check interval, the wait must be the exact
    /// remaining time — that is what keeps startup accurate to the microsecond rather than
    /// landing on an interval boundary.
    @Test("a release within the re-check interval is waited for exactly")
    func imminentReleaseWaitIsExact() {
        let nowUs: Int64 = 1_700_000_000_000_000
        let remainingUs = AudioEngine.startupRecheckIntervalUs / 2
        let releaseTime = nowUs + remainingUs

        #expect(
            AudioEngine.startupWaitMicroseconds(releaseTimeUs: releaseTime, nowUs: nowUs) == remainingUs
        )
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

    /// The all-stale branch deliberately arms no timer, because advancing the clock only
    /// makes stale chunks staler. That leaves `applyChunk`'s re-entry into
    /// `releaseStartupBufferIfReady` as the *only* thing that can start such a stream —
    /// remove it and startup stalls permanently and silently. This pins that re-entry.
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

        // Wait for them to be *applied* rather than sleeping: otherwise the assertion
        // below would also pass simply because the engine had not caught up yet.
        #expect(
            await waitUntil { await engine.appliedCommandKinds().count(where: { $0 == .chunk }) == staleCount },
            "the stale chunks should have reached the engine"
        )
        #expect(
            await !output.recordedCalls.contains("startPrepared()"),
            "no buffered chunk is viable, so output must not have started"
        )

        // A viable, future-dated chunk arrives. Only the append re-entry can notice it.
        await engine.commands.enqueue(.chunk(Data(repeating: 0xAA, count: 100), ts: 1_500_000))

        #expect(
            await waitUntil(timeout: .seconds(3)) { await output.recordedCalls.contains("startPrepared()") },
            "the newly arrived viable chunk must start the stream"
        )
        await engine.shutdown()
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
        let align = try #require(calls.firstIndex { $0.hasPrefix("alignPreparedStartCursor(") })
        #expect(prepare < play && play < align && align < start)
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
        // ~40ms of content against a 200ms min-buffer. The lead must comfortably exceed
        // both the output latency (~256ms here) and any scheduling delay under parallel
        // load — otherwise every chunk is already stale when the engine first evaluates
        // them, which is a correct "joined too late" result but not what this test is for.
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

    /// Both copies of the latency model (`AudioEngine` and `AudioPlayer`) must use the
    /// count `prepare()` primes. A mismatch is a constant offset that the grace-expiry
    /// rebaseline makes permanent — ~85ms per buffer at 48kHz/stereo/16-bit.
    @Test("the pipeline latency model matches the number of buffers actually primed")
    func latencyModelMatchesPrimedBufferCount() throws {
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let bytesPerFrame = format.channels * (format.effectiveOutputBitDepth / 8)

        // Derived from the primed buffer count, independently of the production helper.
        let expected = Int64(audioQueueBufferCount) * Int64(audioQueueBufferByteSize) * 1_000_000
            / Int64(format.sampleRate * bytesPerFrame)

        #expect(AudioEngine.outputLatencyUs(format: format) == expected)

        #expect(audioQueueBufferCount == 3, "prepare() allocates this many AudioQueue buffers")
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
