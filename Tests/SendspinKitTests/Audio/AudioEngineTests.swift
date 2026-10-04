import Foundation
@testable import SendspinKit
import Testing

// MARK: - Helpers

/// Test clock that returns deterministic server→local conversions.
actor StubClock: ClockSyncProtocol {
    private var synchronized = true
    private let offset: Int64 // offset = server - client
    private let anchorToNow: Bool
    private let absoluteAnchorMicroseconds: Int64?

    /// - Parameter anchorToNow: when true, `serverTimeToLocal` maps a (small) server
    ///   timestamp to the current monotonic instant plus `serverTime`.
    /// - Parameter absoluteAnchorMicroseconds: optional fixed absolute instant for tests that
    ///   need server-to-local conversion without elapsed wall-clock time.
    init(
        offsetMicroseconds: Int64 = 0,
        anchorToNow: Bool = false,
        absoluteAnchorMicroseconds: Int64? = nil
    ) {
        offset = offsetMicroseconds
        self.anchorToNow = anchorToNow
        self.absoluteAnchorMicroseconds = absoluteAnchorMicroseconds
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
            return (absoluteAnchorMicroseconds ?? MonotonicClock.absoluteMicroseconds()) + serverTime
        }
        // Stub: local = server - offset
        return serverTime - offset
    }

    func localTimeToServer(_ localTime: Int64) -> Int64 {
        if anchorToNow {
            return localTime - (absoluteAnchorMicroseconds ?? MonotonicClock.absoluteMicroseconds())
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
    // A blocking test double owns its executor so it never blocks the cooperative pool.
    private let queue = DispatchSerialQueue(label: "SendspinKitTests.SpyAudioOutput")
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    var recordedCalls: [String] = []
    /// Set at `prepare`, so `pipelineLatencyMicroseconds` can answer the way a real player does.
    var preparedFormat: AudioFormatSpec?
    /// Stands in for the device path a real output would measure. Zero keeps engine timing
    /// dependent only on buffer depth, which is what the startup-release tests reason about.
    var stubDeviceLatencyUs: Int64 = 0
    var outputDelayUs: Int64 = 0
    var forcedStartThrow: Error?
    var forcedStartPreparedThrow: Error?
    var forcedSwapThrow: Error?
    var forcedPlayPCMThrow: Error?
    var decodeDelay: TimeInterval = 0
    var forcedDecodeThrow: Error?
    private(set) var decodedInputs: [Data] = []
    private var decoderFormat: AudioFormatSpec?
    private(set) var decodedFormats: [AudioFormatSpec?] = []
    var decodeOutputs: [Data: Data] = [:]
    var playbackState: Bool = false
    var underrunCountValue: Int64 = 0
    var outputDeviceProbeDelay: Duration = .zero
    var outputDeviceProbeDelayAfterFirst: Duration = .zero
    private(set) var outputDeviceProbeCount = 0
    private var shouldBlockNextOutputDeviceProbe = false
    private var blockedOutputDeviceProbe: CheckedContinuation<Void, Never>?
    private var shouldBlockNextPCM = false
    private var blockedPCM: CheckedContinuation<Void, Never>?
    private var shouldBlockNextDecode = false
    private var blockedDecode: CheckedContinuation<Void, Never>?
    private var shouldBlockNextStart = false
    private nonisolated let startBlock = DispatchSemaphore(value: 0)
    func blockNextStart() {
        shouldBlockNextStart = true
    }

    nonisolated func releaseBlockedStart() {
        startBlock.signal()
    }

    private var shouldBlockNextSwitch = false
    private var blockedSwitch: CheckedContinuation<Void, Never>?
    private(set) var playedPCMTimestamps: [Int64] = []
    private(set) var playedPCMData: [Data] = []

    func blockNextOutputDeviceProbe() {
        shouldBlockNextOutputDeviceProbe = true
    }

    func releaseBlockedOutputDeviceProbe() {
        blockedOutputDeviceProbe?.resume()
        blockedOutputDeviceProbe = nil
    }

    func blockNextPCM() {
        shouldBlockNextPCM = true
    }

    func releaseBlockedPCM() {
        blockedPCM?.resume()
        blockedPCM = nil
    }

    func blockNextSwitch() {
        shouldBlockNextSwitch = true
    }

    func releaseBlockedSwitch() {
        blockedSwitch?.resume()
        blockedSwitch = nil
    }

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
            pcmBytesDropped: 0,
            startupOffsetUs: nil,
            spinUpUs: -1,
            startupPadFrames: 0,
            framesConsumed: 0,
            silentBuffers: 0,
            enqueueFailures: 0,
            peakOutputLevel: 0,
            appliedVolume: 0,
            queueGain: -1,
            deviceVolume: -1,
            deviceMuted: false,
            framesInFlight: 0
        )
    }

    func prepare(format: AudioFormatSpec, codecHeader _: Data?) throws {
        recordedCalls.append("prepare(\(format.codec))")
        preparedFormat = format
        decoderFormat = format
        if let error = forcedStartThrow {
            throw error
        }
    }

    func pipelineLatencyMicroseconds() -> Int64 {
        guard let format = preparedFormat else { return 0 }
        let depth = Int64(audioQueueBufferCount) * Int64(audioQueueBufferSize(for: format).frames) * 1_000_000
            / Int64(format.sampleRate)
        return depth + stubDeviceLatencyUs
    }

    func setOutputDelayMicroseconds(_ delay: Int64) {
        outputDelayUs = delay
    }

    /// Tests drive release timing directly; no real device to wait on.
    func waitUntilOutputDeviceIsLive() async throws {
        outputDeviceProbeCount += 1
        if shouldBlockNextOutputDeviceProbe {
            shouldBlockNextOutputDeviceProbe = false
            await withCheckedContinuation { continuation in
                blockedOutputDeviceProbe = continuation
            }
        }
        let delay = outputDeviceProbeCount == 1 ? outputDeviceProbeDelay : outputDeviceProbeDelayAfterFirst
        if delay != .zero {
            try? await Task.sleep(for: delay)
        }
    }

    /// Mirrors the real player: only the path beyond the primed buffers.
    func startupLeadMicroseconds() -> Int64 {
        preparedFormat == nil ? 0 : stubDeviceLatencyUs
    }

    func startPrepared() throws {
        recordedCalls.append("startPrepared()")
        if let error = forcedStartPreparedThrow ?? forcedStartThrow {
            throw error
        }
        playbackState = true
    }

    func start(format: AudioFormatSpec, codecHeader _: Data?) throws {
        recordedCalls.append("start(\(format.codec))")
        let capturedError = forcedStartThrow
        if shouldBlockNextStart {
            shouldBlockNextStart = false
            forcedStartThrow = nil
            #expect(startBlock.wait(timeout: .now() + 5) == .success)
        }
        if let error = capturedError {
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
        decoderFormat = format
        if let error = forcedSwapThrow {
            throw error
        }
    }

    func switchHardwareFormat(format: AudioFormatSpec) async throws {
        recordedCalls.append("switchHardwareFormat(\(format.codec))")
        if shouldBlockNextSwitch {
            shouldBlockNextSwitch = false
            await withCheckedContinuation { continuation in
                blockedSwitch = continuation
            }
        }
        if let error = forcedStartThrow {
            throw error
        }
        playbackState = true
    }

    func decode(_ data: Data) async throws -> Data {
        decodedInputs.append(data)
        decodedFormats.append(decoderFormat)
        recordedCalls.append("decode(\(data.count) bytes)")
        if shouldBlockNextDecode {
            shouldBlockNextDecode = false
            await withCheckedContinuation { continuation in
                blockedDecode = continuation
            }
        }
        if decodeDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(decodeDelay * 1_000_000_000))
        }
        if let error = forcedDecodeThrow {
            throw error
        }
        // Return a minimal PCM payload (2 samples per channel for testing)
        return decodeOutputs[data] ?? Data(repeating: 0, count: 4)
    }

    func playPCM(
        _ pcm: Data,
        serverTimestamp: Int64,
        playTimeMicroseconds _: Int64? = nil
    ) async throws {
        recordedCalls.append("playPCM(\(pcm.count) bytes)")
        playedPCMTimestamps.append(serverTimestamp)
        playedPCMData.append(pcm)
        if shouldBlockNextPCM {
            shouldBlockNextPCM = false
            await withCheckedContinuation { continuation in
                blockedPCM = continuation
            }
        }
        if let error = forcedPlayPCMThrow {
            throw error
        }
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

        let reports = EngineReportObservation()
        await reports.start(engine: engine) {
            if case .started = $0 {
                return true
            }
            return false
        }
        try #require(await waitUntil { await reports.isReady })

        // Enqueue and process streamStart + chunk
        await engine.commands.enqueue(.streamStart(format, codecHeader: nil))
        try #require(await waitUntil { await engine.appliedCommandKinds().contains(.streamStart) })
        await engine.commands.enqueue(.chunk(Data(repeating: 0, count: 100), ts: 1_000_000))
        try #require(await waitUntil { await engine.appliedCommandKinds().contains(.chunk) })

        let started = await waitUntil(timeout: .milliseconds(100)) { await reports.matched }
        await reports.stop()
        await engine.shutdown()

        #expect(started, "Should emit .started")

        // Assert scheduler received the chunk
        let stats = await scheduler.stats
        #expect(stats.received > 0)
    }

    @Test("output delay shifts scheduled timestamps by milliseconds converted to microseconds")
    func outputDelayAdjustsScheduledChunkTimestamp() async throws {
        let clock = StubClock(offsetMicroseconds: 0)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)

        await engine.start()

        let delayMs = 200
        let serverTimestamp = MonotonicClock.absoluteMicroseconds() + 60_000_000
        engine.commands.enqueue(.setOutputDelay(delayMs))
        engine.commands.enqueue(.chunk(Data(repeating: 0, count: 100), ts: serverTimestamp))

        let received = await waitUntil(timeout: .seconds(3)) { await scheduler.queuedChunks.count == 1 }
        let queued = await scheduler.queuedChunks
        await engine.shutdown()

        #expect(received, "Expected the chunk to reach the scheduler")
        let chunk = try #require(queued.first)
        #expect(chunk.originalTimestamp == serverTimestamp)
        #expect(chunk.playTimeMicroseconds == serverTimestamp - Int64(delayMs) * 1_000)
        let appliedDelayUs = await output.outputDelayUs
        #expect(appliedDelayUs == Int64(delayMs) * 1_000)
    }

    @Test("local output delay is applied after clock mapping exactly once")
    func localOutputDelayIsIndependentOfClockOffsetAndDrift() {
        let mappedLocalTime: Int64 = 9_876_543
        let delayUs: Int64 = 237_000
        #expect(
            AudioEngine.localPlayTime(mappedLocalTime: mappedLocalTime, outputDelayMicroseconds: delayUs)
                == mappedLocalTime - delayUs
        )
        #expect(
            AudioEngine.localPlayTime(mappedLocalTime: mappedLocalTime, outputDelayMicroseconds: -1)
                == mappedLocalTime
        )
        #expect(
            AudioEngine.localPlayTime(mappedLocalTime: .min, outputDelayMicroseconds: 1) == nil
        )
    }

    @Test("send_ahead never changes timestamp-based scheduling")
    func sendAheadDoesNotAffectScheduling() async throws {
        let clock = StubClock()
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)
        await engine.start()

        let timestamp = MonotonicClock.absoluteMicroseconds() + 10_000_000
        engine.commands.enqueue(.chunkAtGenerationWithSendAhead(
            Data(repeating: 0, count: 100), ts: timestamp, sendAhead: UInt32.max, generation: 0
        ))
        let received = await waitUntil(timeout: .seconds(3)) { await scheduler.queuedChunks.count == 1 }
        let queued = await scheduler.queuedChunks
        await engine.shutdown()

        #expect(received)
        let chunk = try #require(queued.first)
        #expect(chunk.originalTimestamp == timestamp)
        #expect(chunk.playTimeMicroseconds == timestamp)
    }

    @Test("initial stream scheduling preserves wire timestamps across cadence mismatch")
    func initialStreamPreservesWireCadence() async throws {
        let clock = StubClock()
        let output = SpyAudioOutput()
        // Keep the future-dated chunks in the scheduler so the assertion observes receipt rather
        // than racing the scheduler output task, which consumes chunks inside its playback window.
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)
        await engine.start()

        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let firstTimestamp = MonotonicClock.absoluteMicroseconds() + 10_000_000
        let secondTimestamp = firstTimestamp + 100_000
        await engine.commands.enqueue(.streamStart(format, codecHeader: nil))
        await engine.commands.enqueue(.chunk(Data(repeating: 1, count: 100), ts: firstTimestamp))
        await engine.commands.enqueue(.chunk(Data(repeating: 2, count: 100), ts: secondTimestamp))

        let received = await waitUntil(timeout: .seconds(3)) { await scheduler.queuedChunks.count == 2 }
        let queued = await scheduler.queuedChunks
        await engine.shutdown()

        #expect(received, "both initial chunks must reach the scheduler")
        #expect(queued.map(\.playTimeMicroseconds) == [firstTimestamp, secondTimestamp])
    }

    /// Seamless format change is engine-internal (no MainActor.run).
    /// Chunks are anchored near "now" so the scheduler emits them, and the generation
    /// bump routes new chunks through the rebuild before `.formatApplied` is reported.
    @Test("seamless format change rebuilds and emits .formatApplied")
    func seamlessFormatChange() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        // A wide playback window keeps delivery reliable when the test process is busy.
        let scheduler = AudioScheduler(clockSync: clock, playbackWindow: 30)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)

        await engine.start()

        let fmt0 = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let fmt1 = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)

        await engine.commands.enqueue(.streamStart(fmt0, codecHeader: nil))
        #expect(await waitUntil(timeout: .seconds(3)) { await output.recordedCalls.contains(where: { $0.hasPrefix("start(") }) })

        // gen0 chunks, near-now timestamps so the scheduler emits them within its window.
        for i in 0 ..< 3 {
            await engine.commands.enqueue(.chunk(Data(repeating: UInt8(i), count: 100), ts: Int64(i) * 5_000))
        }
        #expect(await waitUntil(timeout: .seconds(3)) { await output.playedPCMData.count == 3 })

        await engine.commands.enqueue(.formatChange(fmt1, codecHeader: nil))
        #expect(await waitUntil(timeout: .seconds(3)) { await engine.appliedCommandKinds().last == .formatChange })

        // gen1 chunks: at least formatTransitionPreBuffer (2) must arrive for the rebuild
        // to complete and emit .formatApplied — send extra to clear the pre-buffer.
        for i in 0 ..< 4 {
            await engine.commands.enqueue(.chunk(Data(repeating: UInt8(i + 10), count: 100), ts: Int64(i + 4) * 5_000))
        }
        let formatApplied = await awaitReport(from: engine, timeoutMs: 3_000) {
            if case let .formatApplied(applied, _) = $0 {
                applied == fmt1
            } else {
                false
            }
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

    @Test("route invalidation drops old ingress and preserves FIFO clear/end")
    func routeInvalidationDropsOldIngressAndPreservesFIFO() async throws {
        let clock = StubClock()
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock, playbackWindow: 30)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)
        await engine.start()

        let oldFormat = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
        let newFormat = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let inFlightOld = Data([0xA1])
        let invalidatedOld = Data([0xA2])
        let postRouteNew = Data([0xB1])
        await engine.commands.enqueue(.streamStart(oldFormat, codecHeader: nil))
        #expect(
            await waitUntil { await engine.appliedCommandKinds().contains(.streamStart) },
            "the initial stream start must apply before testing the route barrier"
        )

        await output.blockNextDecode()
        engine.enqueueAudioChunk(data: inFlightOld, timestamp: 1)
        #expect(
            await waitUntil { await output.recordedCalls.contains("decode(1 bytes)") },
            "the pre-invalidation chunk must be in flight"
        )

        // Invalidation precedes the replacement stream announcement. Bytes arriving in this
        // window are old-format wire data and must be discarded, not retained for the new decoder.
        engine.beginRouteInvalidation()
        engine.enqueueAudioChunk(data: invalidatedOld, timestamp: 2)
        engine.enqueueRouteInvalidatedFormatChange(format: newFormat, codecHeader: nil)
        engine.enqueueAudioChunk(data: postRouteNew, timestamp: 3)
        await output.releaseBlockedDecode()

        let rebuilt = await waitUntil(timeout: .seconds(3)) {
            let calls = await output.recordedCalls
            let kinds = await engine.appliedCommandKinds()
            let decodedInputs = await output.decodedInputs
            return calls.contains("stop()")
                && kinds.contains(.routeInvalidatedFormatChange)
                && decodedInputs.contains(postRouteNew)
        }
        #expect(rebuilt)

        let decoded = await output.decodedInputs
        #expect(decoded.contains(inFlightOld), "the pre-invalidation in-flight decode may finish under the old decoder")
        #expect(!decoded.contains(invalidatedOld), "old bytes received during invalidation must never be decoded")
        #expect(decoded.contains(postRouteNew), "bytes after the route command must use the new decoder")
        #expect(decoded.last == postRouteNew, "the post-route sentinel must remain after the route barrier")

        // Clear and end stay in the same FIFO; no hidden route buffer may release data after them.
        engine.commands.enqueue(.streamClear(roles: ["player"]))
        engine.commands.enqueue(.streamEnd(roles: ["player"]))
        #expect(
            await waitUntil {
                let kinds = await engine.appliedCommandKinds()
                return kinds.suffix(2).elementsEqual([.streamClear, .streamEnd])
            }
        )
        let decodedAfterLifecycle = await output.decodedInputs
        await engine.shutdown()

        #expect(decodedAfterLifecycle == decoded, "clear/end must not release invalidated chunks later")
        #expect(await output.recordedCalls.contains("stop()"))
    }

    @Test("route invalidation closes at end and reopens for the next stream")
    func routeInvalidationResetsAtStreamBoundary() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock, playbackWindow: 30)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)
        let oldFormat = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
        let newFormat = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let inFlightOld = Data([0xC1])
        let invalidatedOld = Data([0xC2])
        let newInput = Data([0xD1])
        let oldPCM = Data([0xE1])
        let newPCM = Data([0xF1])

        await engine.start()
        engine.enqueueStreamStart(format: oldFormat, codecHeader: nil)
        #expect(await waitUntil { await engine.appliedCommandKinds().contains(.streamStart) })
        await output.setDecodeOutput(inFlightOld, pcm: oldPCM)
        await output.setDecodeOutput(invalidatedOld, pcm: oldPCM)
        await output.setDecodeOutput(newInput, pcm: newPCM)
        await output.blockNextDecode()
        engine.enqueueAudioChunk(data: inFlightOld, timestamp: 0)
        #expect(
            await waitUntil { await output.recordedCalls.contains("decode(1 bytes)") },
            "the old decode must be in flight before the lifecycle boundary"
        )

        engine.beginRouteInvalidation()
        #expect(await engine.isRouteInvalidatedForTesting())
        engine.enqueueAudioChunk(data: invalidatedOld, timestamp: 1)
        engine.enqueueStreamEnd(roles: [StreamRole.player.rawValue])
        #expect(await engine.isRouteInvalidatedForTesting())
        engine.enqueueStreamStart(format: newFormat, codecHeader: nil)
        let routeIsOpen = await engine.isRouteInvalidatedForTesting() == false
        #expect(routeIsOpen)
        engine.enqueueAudioChunk(data: newInput, timestamp: 0)
        await output.releaseBlockedDecode()

        #expect(
            await waitUntil(timeout: .seconds(3)) { await output.playedPCMData.contains(newPCM) },
            "the first PCM of the new stream must reach output"
        )
        let played = await output.playedPCMData
        let decoded = await output.decodedInputs
        await engine.shutdown()

        #expect(played == [newPCM], "neither invalidated nor in-flight old PCM may reach output")
        #expect(!decoded.contains(invalidatedOld), "bytes received while invalidated must be dropped")
        #expect(decoded.contains(inFlightOld), "the in-flight decode may finish but must not be scheduled")
    }

    @Test("a plain stream generation delivers its first PCM chunk")
    func plainGenerationFirstDelivery() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock, playbackWindow: 30)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let sentinel = Data([0xF1, 0x01])
        await engine.start()
        await engine.commands.enqueue(.streamStart(format, codecHeader: nil))
        await output.setDecodeOutput(sentinel, pcm: Data([0xA1, 0x01]))
        await engine.commands.enqueue(.chunk(sentinel, ts: 0))

        #expect(
            await waitUntil(timeout: .seconds(3)) { await output.playedPCMData.contains(Data([0xA1, 0x01])) },
            "the first boundaryless stream chunk must reach playback"
        )
        let played = await output.playedPCMData
        await engine.shutdown()
        #expect(played == [Data([0xA1, 0x01])])
    }

    @Test("startup buffering delivers its first PCM chunk")
    func startupGenerationFirstDelivery() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock, enableStartupBuffering: true)
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let sentinel = Data([0xF2, 0x02])
        let pcm = Data([0xA2, 0x02])
        await engine.start()
        await engine.commands.enqueue(.streamStart(format, codecHeader: nil))
        await output.setDecodeOutput(sentinel, pcm: pcm)
        await engine.commands.enqueue(.chunk(sentinel, ts: 1_000_000))

        #expect(
            await waitUntil(timeout: .seconds(3)) { await output.playedPCMData.contains(pcm) },
            "startup buffering must deliver the first primed chunk"
        )
        let calls = await output.recordedCalls
        await engine.shutdown()
        #expect(calls.contains("startPrepared()"))
    }

    @Test("startup deferred old PCM drains before same-rate or cross-rate format boundaries", arguments: [48_000, 44_100])
    func startupDeferredPCMDrainsBeforeFormatBoundary(newSampleRate: Int) async throws {
        let releaseInstant: Int64 = 500_000
        let clock = StubClock(anchorToNow: true, absoluteAnchorMicroseconds: 0)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock, playbackWindow: 30, now: { releaseInstant })
        let engine = AudioEngine(
            output: output, scheduler: scheduler, clock: clock,
            enableStartupBuffering: true, startupNow: { releaseInstant }
        )
        let oldFormat = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let newFormat = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: newSampleRate, bitDepth: 32)
        let primed = Data(repeating: 1, count: 192)
        let deferredOld = Data(repeating: 2, count: 192)
        let replacement = Data(repeating: 3, count: 352)
        for pcm in [primed, deferredOld, replacement] {
            await output.setDecodeOutput(pcm, pcm: pcm)
        }
        await output.blockNextPCM()
        await engine.start()
        engine.enqueueStreamStart(format: oldFormat, codecHeader: nil)
        engine.enqueueAudioChunk(data: primed, timestamp: 500_000)
        #expect(await waitUntil(timeout: .seconds(3)) { await output.playedPCMData.count == 1 })
        #expect(await engine.startupReleaseCommits == 0)
        engine.enqueueAudioChunk(data: deferredOld, timestamp: 501_000)
        #expect(await waitUntil { await output.decodedInputs.count == 2 })
        engine.enqueueFormatChange(format: newFormat, codecHeader: nil)
        engine.enqueueAudioChunk(data: replacement, timestamp: 502_000)
        #expect(await waitUntil { await output.decodedInputs.count == 3 })
        await output.releaseBlockedPCM()
        #expect(await waitUntil(timeout: .seconds(3)) { await output.playedPCMData.count == 3 })
        #expect(await output.playedPCMData == [primed, deferredOld, replacement], "all primed and deferred PCM survives in order")
        #expect(await output.decodedFormats == [oldFormat, oldFormat, newFormat])
        let calls = await output.recordedCalls
        let switchIndex = try #require(calls.firstIndex(of: "switchHardwareFormat(pcm)"))
        #expect(
            calls[..<switchIndex].filter { $0.hasPrefix("playPCM(") }.count == 2,
            "the hardware boundary follows the complete primed and deferred old-format PCM"
        )
        #expect(calls.filter { $0 == "prepare(pcm)" }.count == 1)
        await engine.shutdown()
    }

    @Test("startup format changes retain old PCM before new PCM")
    func startupFormatChangeRetainsOrderedPCM() async throws {
        let releaseInstant: Int64 = 500_000
        let clock = StubClock(anchorToNow: true, absoluteAnchorMicroseconds: 0)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock, playbackWindow: 30, now: { releaseInstant })
        let engine = AudioEngine(
            output: output, scheduler: scheduler, clock: clock,
            enableStartupBuffering: true, startupNow: { releaseInstant }
        )
        let oldFormat = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let newFormat = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 32)
        let oldPCM = Data([0xA1, 0x02, 0x03, 0x04])
        let newPCM = Data([0xB1, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        await output.setDecodeOutput(oldPCM, pcm: oldPCM)
        await output.setDecodeOutput(newPCM, pcm: newPCM)
        await engine.start()
        engine.enqueueStreamStart(format: oldFormat, codecHeader: nil)
        engine.enqueueAudioChunk(data: oldPCM, timestamp: 500_000)
        engine.enqueueFormatChange(format: newFormat, codecHeader: nil)
        engine.enqueueAudioChunk(data: newPCM, timestamp: 520_000)
        #expect(await waitUntil(timeout: .seconds(3)) { await output.playedPCMData.count == 2 })
        #expect(await output.playedPCMData == [oldPCM, newPCM], "startup preserves all PCM in format order")
        #expect(await output.decodedFormats == [oldFormat, newFormat], "each chunk uses its receipt-time decoder format")
        #expect(await output.recordedCalls.count(where: { $0 == "prepare(pcm)" }) == 1)
        #expect(await output.recordedCalls.contains("swapDecoder(pcm)"))
        await engine.shutdown()
    }

    @Test("a route rebuild delivers its first replacement PCM chunk")
    func routeRebuildFirstDelivery() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock, playbackWindow: 30)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)
        let oldFormat = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
        let newFormat = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let oldSentinel = Data([0xE3, 0x03])
        let oldPCM = Data([0x91, 0x03])
        let newSentinel = Data([0xF3, 0x03])
        let newPCM = Data([0xA3, 0x03])
        await engine.start()
        await engine.commands.enqueue(.streamStart(oldFormat, codecHeader: nil))
        #expect(await waitUntil { await engine.appliedCommandKinds().contains(.streamStart) })
        await output.setDecodeOutput(oldSentinel, pcm: oldPCM)
        await output.setDecodeOutput(newSentinel, pcm: newPCM)
        await engine.commands.enqueue(
            .chunk(oldSentinel, ts: MonotonicClock.absoluteMicroseconds() + 10_000_000)
        )
        #expect(await waitUntil { await scheduler.stats.received == 1 })

        engine.enqueueRouteInvalidatedFormatChange(format: newFormat, codecHeader: nil)
        engine.enqueueAudioChunk(data: newSentinel, timestamp: 0)

        #expect(
            await waitUntil(timeout: .seconds(3)) { await output.playedPCMData.contains(newPCM) },
            "the first chunk after a route rebuild must not be dropped"
        )
        let played = await output.playedPCMData
        let calls = await output.recordedCalls
        await engine.shutdown()
        #expect(played.contains(newPCM))
        #expect(!played.contains(oldPCM), "route rebuild must discard queued old-format PCM")
        #expect(calls.contains("start(pcm)"))
    }

    @Test("stream clear in active production buffering does not restart startup")
    func activeProductionBufferingClearContinuesPlayback() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock, playbackWindow: 30)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock, enableStartupBuffering: true)
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let first = Data([0xF4, 0x04])
        let replacement = Data([0xA4, 0x04])
        await engine.start()
        await engine.commands.enqueue(.streamStart(format, codecHeader: nil))
        await output.setDecodeOutput(first, pcm: Data([0xB4, 0x04]))
        await engine.commands.enqueue(.chunk(first, ts: 1_000_000))
        #expect(await waitUntil(timeout: .seconds(3)) { await output.recordedCalls.contains("startPrepared()") })
        let callsBeforeClear = await output.recordedCalls

        engine.commands.enqueue(.streamClear(roles: ["player"]))
        #expect(await waitUntil { await engine.appliedCommandKinds().count(where: { $0 == .streamClear }) == 1 })
        await output.setDecodeOutput(replacement, pcm: Data([0xB5, 0x04]))
        await engine.commands.enqueue(.chunk(replacement, ts: 0))

        #expect(
            await waitUntil(timeout: .seconds(3)) { await output.playedPCMData.contains(Data([0xB5, 0x04])) },
            "active buffering must continue directly after stream clear"
        )
        let callsAfterClear = await output.recordedCalls
        #expect(callsAfterClear.count(where: { $0.hasPrefix("prepare(") }) == callsBeforeClear.count(where: { $0.hasPrefix("prepare(") }))
        #expect(callsAfterClear.count(where: { $0 == "startPrepared()" }) == callsBeforeClear.count(where: { $0 == "startPrepared()" }))
        #expect(callsAfterClear.count(where: { $0 == "stop()" }) == callsBeforeClear.count(where: { $0 == "stop()" }))
        await engine.shutdown()
    }

    @Test("ordered clear invalidates a suspended hardware switch")
    func orderedClearWhileSwitchSuspendedDropsPendingChunk() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock, playbackWindow: 30)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)
        let oldFormat = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let newFormat = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
        let stale = Data([0xF5, 0x05])
        let replacement = Data([0xA5, 0x05])
        await engine.start()
        await engine.commands.enqueue(.streamStart(oldFormat, codecHeader: nil))
        await output.blockNextSwitch()
        await engine.commands.enqueue(.formatChange(newFormat, codecHeader: nil))
        await output.setDecodeOutput(stale, pcm: Data([0xB6, 0x05]))
        await engine.commands.enqueue(.chunk(stale, ts: 0))
        #expect(await waitUntil(timeout: .seconds(3)) { await output.recordedCalls.contains("switchHardwareFormat(pcm)") })

        engine.commands.enqueue(.streamClear(roles: ["player"]))
        #expect(await waitUntil { await engine.appliedCommandKinds().count(where: { $0 == .streamClear }) == 1 })
        await output.releaseBlockedSwitch()
        await output.setDecodeOutput(replacement, pcm: Data([0xB7, 0x05]))
        await engine.commands.enqueue(.chunk(replacement, ts: 0))

        #expect(await waitUntil(timeout: .seconds(3)) { await output.playedPCMData.contains(Data([0xB7, 0x05])) })
        let played = await output.playedPCMData
        await engine.shutdown()
        #expect(!played.contains(Data([0xB6, 0x05])))
    }

    @Test("rapid ordered changes deliver each generation in order")
    func rapidOrderedChangesDeliverSentinelsInOrder() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock, playbackWindow: 30)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)
        let initial = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let firstFormat = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
        let secondFormat = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 32_000, bitDepth: 16)
        let first = Data([0xF6, 0x06])
        let second = Data([0xF7, 0x07])
        let firstPCM = Data([0xB8, 0x06])
        let secondPCM = Data([0xB9, 0x07])
        await engine.start()
        await engine.commands.enqueue(.streamStart(initial, codecHeader: nil))
        await output.setDecodeOutput(first, pcm: firstPCM)
        await output.setDecodeOutput(second, pcm: secondPCM)
        await engine.commands.enqueue(.formatChange(firstFormat, codecHeader: nil))
        await engine.commands.enqueue(.chunk(first, ts: 0))
        await engine.commands.enqueue(.formatChange(secondFormat, codecHeader: nil))
        await engine.commands.enqueue(.chunk(second, ts: 0))

        #expect(
            await waitUntil(timeout: .seconds(3)) { await output.playedPCMData.count == 2 },
            "rapid ordered generations must both reach playback"
        )
        let played = await output.playedPCMData
        await engine.shutdown()
        #expect(played == [firstPCM, secondPCM])
    }

    /// A format change preserves PCM already scheduled for the previous output format.
    /// The render boundary must let that audio drain before switching hardware format.
    @Test("format changes preserve pre-scheduled old-format output")
    func formatChangePreservesPreScheduledOutput() async throws {
        let clock = StubClock()
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock, playbackWindow: 30)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)

        await engine.start()

        let replacementFormat = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
        let oldFormatTimestamp = MonotonicClock.absoluteMicroseconds() + 10_000_000
        await scheduler.schedule(
            pcm: Data(repeating: 1, count: 100),
            serverTimestamp: oldFormatTimestamp,
            playTimeMicroseconds: oldFormatTimestamp,
            generation: 0
        )
        #expect(await scheduler.queuedChunks.count == 1, "the old-format chunk should be pending in the scheduler")

        await engine.commands.enqueue(.formatChange(replacementFormat, codecHeader: nil))
        let decoderSwapped = await waitUntil(timeout: .seconds(3)) {
            await output.recordedCalls.contains("swapDecoder(pcm)")
        }
        #expect(decoderSwapped, "the replacement decoder should be ready")
        #expect(
            await scheduler.queuedChunks.contains(where: { $0.originalTimestamp == oldFormatTimestamp }),
            "old-format scheduled PCM must remain until its render boundary"
        )

        await engine.shutdown()
    }

    /// Chunks already in the command FIFO when renegotiation is announced are old-format
    /// audio too. FIFO application must decode them before the format boundary.
    @Test("format renegotiation preserves queued old-format commands before decode")
    func formatChangePreservesQueuedOldFormatCommands() async throws {
        let clock = StubClock()
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock, playbackWindow: 30, now: { 0 })
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)
        await engine.start()

        let oldData = Data(repeating: 0x11, count: 100)
        let newData = Data(repeating: 0x22, count: 100)
        let replacementFormat = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
        let oldTimestamp = MonotonicClock.absoluteMicroseconds() + 10_000_000
        let newTimestamp = oldTimestamp + 100_000

        await engine.commands.enqueue(.streamStart(replacementFormat, codecHeader: nil))
        engine.enqueueAudioChunk(data: oldData, timestamp: oldTimestamp)
        engine.enqueueFormatChange(format: replacementFormat, codecHeader: nil)
        engine.enqueueAudioChunk(data: newData, timestamp: newTimestamp)

        let sawSwap = await waitUntil(timeout: .seconds(3)) {
            await output.recordedCalls.contains("swapDecoder(pcm)")
        }
        #expect(sawSwap)
        #expect(await waitUntil { await scheduler.stats.received == 2 })

        let calls = await output.recordedCalls
        let decodeCalls = calls.filter { $0.hasPrefix("decode(") }
        #expect(decodeCalls.count == 2, "both FIFO-ordered chunks must be decoded")
        // streamStart establishes generation 1; the format command advances to generation 2.
        #expect(await scheduler.queuedChunks.contains(where: { $0.generation == 1 }))
        #expect(await scheduler.queuedChunks.contains(where: { $0.generation == 2 }))

        await engine.shutdown()
    }

    /// A deferred AudioQueue rebuild that fails must surface `.startFailed` rather
    /// than be silently swallowed. The seamless path reports `.formatApplied` at the
    /// first new-generation chunk, so a failed rebuild must still report the failure
    /// instead of leaving the client believing the format switch succeeded.
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
        #expect(await waitUntil(timeout: .seconds(3)) { await output.recordedCalls.contains(where: { $0.hasPrefix("start(") }) })

        for i in 0 ..< 3 {
            await engine.commands.enqueue(.chunk(Data(repeating: UInt8(i), count: 100), ts: Int64(i) * 5_000))
        }
        #expect(await waitUntil(timeout: .seconds(3)) { await output.playedPCMData.count == 3 })

        // Arm the deferred rebuild to fail: swapDecoder still succeeds (so we take the
        // deferred-rebuild path), but the rebuild's output.start() throws.
        await output.setForcedStartThrow(TestError())

        await engine.commands.enqueue(.formatChange(fmt1, codecHeader: nil))
        #expect(await waitUntil(timeout: .seconds(3)) { await engine.appliedCommandKinds().last == .formatChange })

        for i in 0 ..< 4 {
            await engine.commands.enqueue(.chunk(Data(repeating: UInt8(i + 10), count: 100), ts: Int64(i + 4) * 5_000))
        }
        let sawStartFailed = await awaitReport(from: engine, timeoutMs: 3_000) {
            if case .startFailed = $0 {
                true
            } else {
                false
            }
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

    /// `.formatApplied` is reported at the commitment point—the first new-generation
    /// chunk—not gated on the two-chunk audio pre-buffer. A single trailing chunk must
    /// therefore produce the report without waiting for shutdown.
    @Test(".formatApplied fires on the first new-generation chunk, not the pre-buffer threshold")
    func formatAppliedReportedOnFirstNewGenChunk() async throws {
        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        // A wide playback window keeps the single gen-1 chunk from being dropped when
        // the test process is busy.
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

        // Observe the report before shutdown so finishing the stream cannot satisfy the
        // assertion by itself. The generous timeout covers scheduler latency under load.
        let sawFormatApplied = await awaitReport(from: engine, timeoutMs: 5_000) { report in
            if case let .formatApplied(applied, _) = report {
                return applied == fmt1
            }
            return false
        }
        #expect(sawFormatApplied, ".formatApplied must be reported on the first new-gen chunk, before any 2nd chunk")

        await engine.shutdown()
    }

    /// A decoder failure leaves the old queue alive and quarantines the new generation.
    @Test("swapDecoder failure preserves old output and reports .startFailed")
    func swapDecoderFailurePreservesOldOutput() async throws {
        struct TestError: Error {}

        let clock = StubClock(anchorToNow: true)
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock, playbackWindow: 30)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)

        await engine.start()

        let fmt0 = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let fmt1 = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)

        await engine.commands.enqueue(.streamStart(fmt0, codecHeader: nil))
        try #require(await waitUntil { await engine.appliedCommandKinds().contains(.streamStart) })

        let reports = EngineReportObservation()
        await reports.start(engine: engine) {
            if case .startFailed = $0 {
                return true
            }
            return false
        }
        try #require(await waitUntil { await reports.isReady })
        await output.setForcedSwapThrow(TestError())
        await engine.commands.enqueue(.formatChange(fmt1, codecHeader: nil))
        await engine.commands.enqueue(.chunk(Data(repeating: 2, count: 100), ts: 0))
        try #require(await waitUntil { await engine.appliedCommandKinds().contains(.formatChange) })

        let startFailed = await waitUntil(timeout: .milliseconds(100)) { await reports.matched }
        await reports.stop()
        let calls = await output.recordedCalls
        await engine.shutdown()

        #expect(startFailed, "swap failure must report .startFailed")
        #expect(calls.filter { $0.hasPrefix("start(") }.count == 1, "old output must not restart")
        #expect(!calls.contains("stop()"), "decoder failure must not stop old hardware")
        #expect(!calls.contains("playPCM(4 bytes)"), "quarantined new-generation PCM must not render")
    }

    /// Advance ordered telemetry ticks across rising underrun counts, then inspect reports.
    private func observesUnderrunOperationalStateReport(
        external: Bool,
        ticks: Int = 3,
        where predicate: @escaping @Sendable (EngineReport) -> Bool
    ) async throws -> Bool {
        let clock = StubClock()
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let telemetry = TelemetryTickGate()
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock, telemetrySleep: { _ in await telemetry.sleep() })

        await engine.start()
        if external {
            await engine.setExternalSource(true)
        }

        for i in 0 ... ticks {
            await output.setUnderrunCount(Int64(i))
            try await telemetry.tick()
        }

        let emitted = await awaitReport(from: engine, timeoutMs: 200, where: predicate)
        await engine.shutdown()
        return emitted
    }

    /// While participating, a rising underrun count must drive an
    /// `.operationalState(.error)` report.
    @Test("Underrun while participating reports .operationalState(.error)")
    func underrunReportsErrorWhileParticipating() async throws {
        let emitted = try await observesUnderrunOperationalStateReport(external: false) {
            if case .operationalState(.error) = $0 {
                true
            } else {
                false
            }
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

    /// While an external source is active, underruns are not this client's error. Re-baseline
    /// the monitor without emitting a report so the external-source state remains authoritative.
    @Test("Underrun while external source emits no operational-state report")
    func underrunSuppressedWhileExternalSource() async throws {
        let emitted = try await observesUnderrunOperationalStateReport(external: true) {
            if case .operationalState = $0 {
                true
            } else {
                false
            }
        }
        #expect(!emitted)
    }

    // MARK: - Spec §Playback Synchronization: mute on error, restore on recovery

    /// Drive underrun error, optional external-source entry, and clean recovery ticks.
    /// Return the effective `setMute` calls after the ordered telemetry effects apply.
    private func driveUnderrunMuteScenario(
        userMutedFirst: Bool = false,
        goExternalAfterError: Bool = false,
        recover: Bool
    ) async throws -> [String] {
        let clock = StubClock()
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let telemetry = TelemetryTickGate()
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock, telemetrySleep: { _ in await telemetry.sleep() })

        await engine.start()
        if userMutedFirst {
            await engine.setMuted(true)
        }

        for i in 0 ... 1 {
            await output.setUnderrunCount(Int64(i))
            try await telemetry.tick()
        }

        if goExternalAfterError {
            await engine.setExternalSource(true)
            try await telemetry.tick()
        }

        if recover {
            let callsBeforeRecovery = await output.recordedCalls.count
            try #require(await waitUntil {
                try? await telemetry.tick()
                return await output.recordedCalls.dropFirst(callsBeforeRecovery).contains { $0.hasPrefix("setMute(") }
            })
        }

        await engine.shutdown()
        return await output.recordedCalls.filter { $0.hasPrefix("setMute(") }
    }

    /// On cannot-maintain-sync the client must mute its audio output, not only report
    /// `state: 'error'`.
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

    /// The safety mute is OR'd with user mute, so recovery must not unmute a player
    /// the user has muted.
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

    /// The engine is single-use: `start()` after `shutdown()` must be a no-op,
    /// including for its telemetry task and output.
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

        let reports = EngineReportObservation()
        await reports.start(engine: engine) {
            if case .startFailed = $0 {
                return true
            }
            return false
        }
        try #require(await waitUntil { await reports.isReady })
        await output.setForcedStartThrow(TestError())

        let fmt = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        await engine.commands.enqueue(.streamStart(fmt, codecHeader: nil))
        try #require(await waitUntil { await engine.appliedCommandKinds().contains(.streamStart) })

        let sawStartFailed = await waitUntil(timeout: .milliseconds(100)) { await reports.matched }
        await reports.stop()
        await engine.shutdown()
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

    /// `streamEnd` truncates scheduled-but-unplayed audio immediately rather than draining
    /// to completion. Future-dated chunks remain queued until the stream ends.
    @Test("streamEnd truncates queued-but-unplayed audio")
    func streamEndTruncation() async throws {
        let clock = StubClock()
        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock, now: { 0 })
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)

        await engine.start()

        let fmt = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        await engine.commands.enqueue(.streamStart(fmt, codecHeader: nil))
        #expect(await waitUntil { await engine.appliedCommandKinds().last == .streamStart })

        // Far-future timestamps (~10s ahead): queued but never within the playback window,
        // so they sit unplayed until the stream ends.
        let chunkCount = 10
        for i in 0 ..< chunkCount {
            await engine.commands.enqueue(.chunk(Data(repeating: UInt8(i), count: 100), ts: 10_000_000 + Int64(i) * 1_000))
        }
        #expect(await waitUntil { await scheduler.stats.received == chunkCount })

        // All chunks should be queued and unplayed before the end.
        let before = await scheduler.stats
        #expect(before.queueSize == chunkCount)
        #expect(before.played == 0)

        engine.commands.enqueue(.streamEnd(roles: nil))
        #expect(await waitUntil { await engine.appliedCommandKinds().last == .streamEnd })

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

/// Test controls for SpyAudioOutput.
extension SpyAudioOutput {
    func setForcedStartThrow(_ error: Error?) {
        forcedStartThrow = error
    }

    func setForcedStartPreparedThrow(_ error: Error) {
        forcedStartPreparedThrow = error
    }

    func setForcedSwapThrow(_ error: Error) {
        forcedSwapThrow = error
    }

    func setForcedPlayPCMThrow(_ error: Error) {
        forcedPlayPCMThrow = error
    }

    func setDecodeOutput(_ input: Data, pcm: Data) {
        decodeOutputs[input] = pcm
    }

    func setDecodeDelay(_ delay: TimeInterval) {
        decodeDelay = delay
    }

    func blockNextDecode() {
        shouldBlockNextDecode = true
    }

    func releaseBlockedDecode() {
        blockedDecode?.resume()
        blockedDecode = nil
    }

    func setUnderrunCount(_ count: Int64) {
        underrunCountValue = count
    }
}
