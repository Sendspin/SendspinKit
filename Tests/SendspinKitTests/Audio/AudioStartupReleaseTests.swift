// ABOUTME: Tests startup release timing helpers for primed AudioQueue startup.
// ABOUTME: Covers min-buffer readiness and join-in-progress stale chunk selection.
import Foundation
@testable import SendspinKit
import Testing

@Suite("Audio startup release")
struct AudioStartupReleaseTests {
    @Test("startup release waits for min-buffer span")
    func startupReleaseWaitsForMinBufferSpan() {
        let firstPlayTime: Int64 = 1_000_000
        let minBufferUs = Int64(defaultMinBufferMs) * 1_000
        let outputLatencyUs: Int64 = 92_000

        let insufficient = AudioEngine.startupReleaseTimeMicroseconds(
            firstPlayTime: firstPlayTime,
            lastPlayTime: firstPlayTime + minBufferUs - 1,
            outputLatencyUs: outputLatencyUs,
            minBufferUs: minBufferUs
        )
        #expect(insufficient == nil)

        let ready = AudioEngine.startupReleaseTimeMicroseconds(
            firstPlayTime: firstPlayTime,
            lastPlayTime: firstPlayTime + minBufferUs,
            outputLatencyUs: outputLatencyUs,
            minBufferUs: minBufferUs
        )
        #expect(ready == firstPlayTime - outputLatencyUs)
    }

    @Test("startup release candidate skips stale join-in-progress chunks")
    func startupReleaseCandidateSkipsStaleJoinInProgressChunks() {
        let firstPlayTime: Int64 = 1_000_000
        let chunkStepUs: Int64 = 100_000
        let playTimes = (0 ... 7).map { firstPlayTime + Int64($0) * chunkStepUs }
        let outputLatencyUs: Int64 = 90_000
        let minBufferUs: Int64 = 300_000
        let nowUs = playTimes[0] - outputLatencyUs + CorrectionPlanner.defaultEngageUs + 1

        let candidate = AudioEngine.startupReleaseCandidate(
            playTimes: playTimes,
            nowUs: nowUs,
            outputLatencyUs: outputLatencyUs,
            minBufferUs: minBufferUs
        )
        #expect(candidate?.index == 1)
        #expect(candidate?.releaseTimeUs == playTimes[1] - outputLatencyUs)
    }

    @Test("startup release candidate waits when only viable candidate is stale")
    func startupReleaseCandidateWaitsWhenOnlyViableCandidateIsStale() {
        let firstPlayTime: Int64 = 1_000_000
        let minBufferUs = Int64(defaultMinBufferMs) * 1_000
        let playTimes = [firstPlayTime, firstPlayTime + minBufferUs]
        let outputLatencyUs: Int64 = 92_000
        let nowUs = firstPlayTime - outputLatencyUs + CorrectionPlanner.defaultEngageUs + 1

        let candidate = AudioEngine.startupReleaseCandidate(
            playTimes: playTimes,
            nowUs: nowUs,
            outputLatencyUs: outputLatencyUs,
            minBufferUs: minBufferUs
        )
        #expect(candidate == nil)
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
            if case .started = report { return true }
            if case .startFailed = report { return true }
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
            if case .started = report { return true }
            if case .startFailed = report { return true }
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
