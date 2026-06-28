import Foundation
@testable import SendspinKit
import Testing

/// Build a binary `audio chunk` frame (type byte + big-endian timestamp + PCM bytes).
private func audioChunkFrame(index: Int, baseTimestamp: Int64 = 1_000_000) -> Data {
    var frame = Data()
    frame.append(BinaryMessageType.audioChunk.rawValue)
    var timestamp = (baseTimestamp + Int64(index) * 25_000).bigEndian
    frame.append(Data(bytes: &timestamp, count: 8))
    frame.append(Data(repeating: 0x7F, count: 400)) // 200 samples × 16-bit
    return frame
}

/// Build a binary `artwork` frame (type byte + big-endian timestamp + image data).
private func artworkFrame(
    channel: Int,
    index: Int = 0,
    baseTimestamp: Int64 = 1_000_000,
    imageByteCount: Int = 100
) -> Data {
    var frame = Data()
    frame.append(BinaryMessageType.artworkChannel0.rawValue + UInt8(channel))
    var timestamp = (baseTimestamp + Int64(index) * 25_000).bigEndian
    frame.append(Data(bytes: &timestamp, count: 8))
    frame.append(Data(repeating: 0xFF, count: imageByteCount)) // Dummy image data; 0 bytes means clear artwork.
    return frame
}

/// Build a binary `visualizer` frame (type byte + big-endian timestamp + visualizer data).
private func visualizerFrame(index: Int = 0, baseTimestamp: Int64 = 1_000_000) -> Data {
    var frame = Data()
    frame.append(BinaryMessageType.visualizerData.rawValue)
    var timestamp = (baseTimestamp + Int64(index) * 25_000).bigEndian
    frame.append(Data(bytes: &timestamp, count: 8))
    frame.append(Data(repeating: 0xAB, count: 64)) // Dummy visualizer data
    return frame
}

private func streamStartPCMJSON(sampleRate: Int = 8_000) throws -> String {
    let message = StreamStartMessage(
        payload: StreamStartPayload(
            player: StreamStartPlayer(codec: AudioCodec.pcm.rawValue, sampleRate: sampleRate, channels: 1, bitDepth: 16, codecHeader: nil),
            artwork: nil,
            visualizer: nil
        )
    )
    let data = try JSONEncoder().encode(message)
    // swiftlint:disable:next force_unwrapping
    return String(data: data, encoding: .utf8)!
}

private func streamStartWithArtworkJSON() throws -> String {
    let message = StreamStartMessage(
        payload: StreamStartPayload(
            player: nil,
            artwork: StreamStartArtwork(channels: [StreamArtworkChannelConfig(source: .album, format: .jpeg, width: 200, height: 200)]),
            visualizer: nil
        )
    )
    let data = try JSONEncoder().encode(message)
    // swiftlint:disable:next force_unwrapping
    return String(data: data, encoding: .utf8)!
}

private func streamStartWithVisualizerJSON() throws -> String {
    let message = StreamStartMessage(
        payload: StreamStartPayload(
            player: nil,
            artwork: nil,
            visualizer: StreamStartVisualizer()
        )
    )
    let data = try JSONEncoder().encode(message)
    // swiftlint:disable:next force_unwrapping
    return String(data: data, encoding: .utf8)!
}

private actor CollectedValues<Element: Sendable> {
    private var values: [Element] = []

    var isEmpty: Bool {
        values.isEmpty
    }

    var count: Int {
        values.count
    }

    var all: [Element] {
        values
    }

    func append(_ value: Element) {
        values.append(value)
    }
}

@MainActor
struct FrameOrderingTests {
    /// A headless player that surfaces raw audio frames.
    private func makePlayerClient() throws -> SendspinClient {
        try SendspinClient(
            clientId: "test-client",
            name: "Test Client",
            roles: [.playerV1],
            playerConfig: PlayerConfiguration(
                bufferCapacity: 65_536,
                supportedFormats: [
                    AudioFormatSpec(codec: .pcm, channels: 1, sampleRate: 8_000, bitDepth: 16)
                ],
                volumeMode: .none, // headless — skip real audio-output setup
                emitRawAudioEvents: true
            )
        )
    }

    @Test
    func playerAudioStreamHonorsEmitRawAudioEventsConfiguration() async throws {
        let client = try SendspinClient(
            clientId: "test-client",
            name: "Test Client",
            roles: [.playerV1],
            playerConfig: PlayerConfiguration(
                bufferCapacity: 65_536,
                supportedFormats: [
                    AudioFormatSpec(codec: .pcm, channels: 1, sampleRate: 8_000, bitDepth: 16)
                ],
                volumeMode: .none,
                emitRawAudioEvents: false
            )
        )
        let mock = try await connectClient(client)
        let chunks = CollectedValues<AudioChunk>()
        let collectTask = Task {
            for await chunk in client.audioChunks {
                await chunks.append(chunk)
            }
        }

        try await mock.injectText(streamStartPCMJSON())
        try await waitForStreamFormat(client)
        await mock.injectBinary(audioChunkFrame(index: 1))

        let leakedChunk = await waitUntil(timeout: .milliseconds(250)) { await chunks.isEmpty == false }
        collectTask.cancel()
        await client.disconnect()

        #expect(!leakedChunk, "emitRawAudioEvents=false must suppress public audio chunk stream events")
    }

    @Test
    func artworkDataStreamUpdatesCurrentArtwork() async throws {
        let client = try makePlayerClient()
        let mock = try await connectClient(client)
        let received = CollectedValues<ArtworkData>()
        let collectTask = Task {
            for await artwork in client.artwork {
                await received.append(artwork)
                break
            }
        }

        try await mock.injectText(streamStartWithArtworkJSON())
        await mock.injectBinary(artworkFrame(channel: 0))

        let sawArtwork = await waitUntil(timeout: .seconds(1)) { await received.isEmpty == false }
        collectTask.cancel()
        await client.disconnect()

        #expect(sawArtwork, "artwork stream should emit artwork bytes after artwork stream/start")
        let artwork = try #require(await received.all.first)
        #expect(artwork.localDisplayTime == nil, "Pre-sync artwork should emit immediately with no display deadline")
        #expect(client.currentArtwork == artwork)
    }

    @Test
    func emptyArtworkPayloadClearsCurrentArtwork() async throws {
        let client = try makePlayerClient()
        let mock = try await connectClient(client)
        let received = CollectedValues<ArtworkData>()
        let collectTask = Task {
            for await artwork in client.artwork {
                await received.append(artwork)
                if await received.count == 2 { break }
            }
        }

        try await mock.injectText(streamStartWithArtworkJSON())
        await mock.injectBinary(artworkFrame(channel: 0))

        #expect(
            await waitUntil(timeout: .seconds(1)) { await received.count == 1 },
            "initial artwork payload should be emitted"
        )
        let initialArtwork = try #require(await received.all.first)
        #expect(!initialArtwork.clearsArtwork)
        #expect(client.currentArtwork == initialArtwork)

        await mock.injectBinary(artworkFrame(channel: 0, index: 1, imageByteCount: 0))

        #expect(
            await waitUntil(timeout: .seconds(1)) { await received.count == 2 },
            "empty artwork payload should be emitted as a clear signal"
        )
        let clearArtwork = try #require(await received.all.last)
        collectTask.cancel()
        await client.disconnect()

        #expect(clearArtwork.channel == 0)
        #expect(clearArtwork.data.isEmpty)
        #expect(clearArtwork.clearsArtwork)
        #expect(client.currentArtwork == nil)
    }

    @Test
    func playerAudioDiscardedBeforeStreamStart_thenAcceptedAfter() async throws {
        // Pre-stream player audio is discarded by the protocol-intent gate
        // (`playerStreamActive`, set at frame receipt); audio after stream/start is
        // accepted. `.streamStarted` is render-applied from the engine's `.started`
        // report (async), so it interleaves non-deterministically with the typed
        // audio data stream. This therefore asserts the gate via event *counts* and
        // *eventual* lifecycle delivery — not the cross-class interleaving.
        let client = try makePlayerClient()
        let mock = try await connectClient(client)

        let stream = client.events()
        var events: [ClientEvent] = []
        let collectTask = Task { @MainActor in
            for await event in stream {
                events.append(event)
                if case .disconnected = event { break }
            }
        }
        let chunks = CollectedValues<AudioChunk>()
        let chunkTask = Task {
            for await chunk in client.audioChunks {
                await chunks.append(chunk)
            }
        }

        // Pre-stream audio: injected before stream/start, discarded by the gate.
        await mock.injectBinary(audioChunkFrame(index: 0))

        // stream/start opens the control-plane gate and records the format before
        // render-applied `.streamStarted`; with startup priming, a deliberately
        // underfilled stream may never emit the render-start event.
        try await mock.injectText(streamStartPCMJSON())
        try await waitForStreamFormat(client)

        // Post-stream audio: accepted, emits exactly one AudioChunk.
        await mock.injectBinary(audioChunkFrame(index: 1))

        #expect(
            await waitUntil(timeout: .seconds(3)) { await chunks.count == 1 },
            "Timed out waiting for the post-stream audio chunk"
        )

        let acceptedFormat = client.currentStreamFormat
        await client.disconnect()
        chunkTask.cancel()
        _ = await collectTask.value

        // Exactly one AudioChunk: the pre-stream chunk was gated (no event), the
        // post-stream chunk was accepted. A leaked pre-stream event would make this 2.
        #expect(await chunks.count == 1, "Pre-stream chunk discarded, post-stream chunk accepted → exactly one AudioChunk")
        #expect(acceptedFormat?.codec == .pcm, "stream/start must establish the accepted stream format")
    }

    @Test
    func artworkBinaryDiscardedBeforeStreamStart_thenAcceptedAfter() async throws {
        // Pre-stream artwork binary is discarded per spec (artworkStreamActive gate).
        // Subsequent stream/start + artwork is accepted.
        let client = try makePlayerClient()
        let mock = try await connectClient(client)

        // Single event stream that we'll analyze in two phases
        let stream = client.events()
        var allEvents: [ClientEvent] = []
        let artwork = CollectedValues<ArtworkData>()

        // Start collecting events in the background
        let collectTask = Task {
            for await event in stream {
                allEvents.append(event)
                // Collect for the injection window; stop early only on disconnect.
                if case .disconnected = event {
                    break
                }
            }
        }
        let artworkTask = Task {
            for await payload in client.artwork {
                await artwork.append(payload)
            }
        }

        // Inject artwork frame BEFORE artwork stream/start — should be discarded.
        await mock.injectBinary(artworkFrame(channel: 0))

        // Wait a brief moment for the frame to be processed
        try await Task.sleep(for: .milliseconds(100))

        // Now send artwork stream/start
        try await mock.injectText(streamStartWithArtworkJSON())

        // Now inject artwork — this SHOULD produce an ArtworkData payload.
        await mock.injectBinary(artworkFrame(channel: 0))

        #expect(
            await waitUntil(timeout: .seconds(1)) { await artwork.count == 1 },
            "Timed out waiting for the post-stream artwork payload"
        )
        let preSyncArtwork = try #require(await artwork.all.first)
        #expect(preSyncArtwork.localDisplayTime == nil, "Pre-sync artwork should emit immediately with no display deadline")

        try await establishClockSync(client, via: mock)
        await mock.injectBinary(artworkFrame(channel: 0, index: 1))
        #expect(
            await waitUntil(timeout: .seconds(1)) { await artwork.count == 2 },
            "Timed out waiting for the post-sync artwork payload"
        )
        let postSyncArtwork = try #require(await artwork.all.last)
        #expect(postSyncArtwork.localDisplayTime != nil, "Post-sync artwork should carry a local display deadline")

        collectTask.cancel()
        artworkTask.cancel()

        // The gate is the invariant, asserted by COUNT — not by cross-class ordering.
        // Binary artwork data takes the role data stream while `artworkStreamStarted`
        // takes the facade-drain path. What is deterministic: the pre-stream frame is
        // dropped by the gate and the two post-stream frames are accepted, so exactly
        // two artwork payloads are observed.
        #expect(
            await artwork.count == 2,
            "Exactly two artwork payloads: the pre-stream frame is discarded, post-stream frames are accepted"
        )

        let sawArtworkStart = allEvents.contains { if case .artworkStreamStarted = $0 { true } else { false } }
        #expect(sawArtworkStart, "artworkStreamStarted event should be seen")

        await client.disconnect()
    }

    @Test
    func visualizerBinaryRequiresActiveStreamAndClockSync() async throws {
        // Visualizer is time-sensitive like audio: pre-stream frames are discarded
        // by the role gate, and active-stream frames are still discarded until
        // clock sync can translate their server timestamps to local display times.
        let client = try makePlayerClient()
        let mock = try await connectClient(client)

        let visualizerData = CollectedValues<VisualizerData>()

        let collectTask = Task {
            for await payload in client.visualizerData {
                await visualizerData.append(payload)
            }
        }

        // Pre-stream visualizer frame: discarded by visualizerStreamActive gate.
        await mock.injectBinary(visualizerFrame(index: 0))
        try await Task.sleep(for: .milliseconds(100))

        // Active stream but pre-sync: still discarded because visualizer frames need
        // a reliable local display deadline.
        try await mock.injectText(streamStartWithVisualizerJSON())
        await mock.injectBinary(visualizerFrame(index: 1))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await visualizerData.count == 0, "Pre-sync visualizer payloads should be discarded")

        // Once synced, visualizer payloads are emitted with translated local display time.
        try await establishClockSync(client, via: mock)
        await mock.injectBinary(visualizerFrame(index: 2))

        #expect(
            await waitUntil(timeout: .seconds(1)) { await visualizerData.count == 1 },
            "Timed out waiting for the post-sync visualizer payload"
        )
        collectTask.cancel()

        let payload = try #require(await visualizerData.all.first)
        #expect(payload.localDisplayTime > 0, "Synced visualizer payload should carry a local display deadline")

        await client.disconnect()
    }

    @Test
    func streamEnd_isDeliveredAfterAllPrecedingAudioChunks() async throws {
        // The server sends all audio chunks then stream/end, in that wire order.
        // stream/end stops output and clears buffers on receipt, so it must NEVER
        // be surfaced before the audio frames the server sent before it. With
        // the old split text/binary dispatch, the text task could yield
        // streamEnded while the binary task was still draining chunks,
        // truncating the stream. A single ordered frame loop guarantees every
        // preceding audio frame is processed before streamEnded.
        let client = try makePlayerClient()
        let mock = MockTransport()
        try await client.acceptConnection(mock)
        try await mock.injectText(serverHelloJSON())
        try await waitForState(client, expected: .connected, timeout: .seconds(3))

        let chunks = CollectedValues<AudioChunk>()
        let chunkTask = Task {
            for await chunk in client.audioChunks {
                await chunks.append(chunk)
            }
        }
        let stream = client.events()
        let endTask = Task {
            await collectClientEvent(from: stream) {
                if case .streamEnded = $0 { true } else { false }
            }
        }

        // stream/start, then many audio chunks, then stream/end — exact wire order.
        // Public binary bytes now arrive on the typed data stream; engine-channel
        // processing order is covered by the stream-end processing-order test.
        try await mock.injectText(streamStartPCMJSON())
        let chunkCount = 64
        for i in 0 ..< chunkCount {
            await mock.injectBinary(audioChunkFrame(index: i))
        }
        try await mock.injectText(#require(String(data: JSONEncoder().encode(StreamEndMessage()), encoding: .utf8)))

        #expect(await endTask.value != nil, "Expected a streamEnded event")
        #expect(
            await waitUntil(timeout: .seconds(3)) { await chunks.count == chunkCount },
            "All \(chunkCount) audio chunks should be delivered on the typed data stream"
        )
        chunkTask.cancel()

        await client.disconnect()
    }

    @Test
    func streamClear_isDeliveredAfterAllPrecedingAudioChunks() async throws {
        // stream/clear stops draining and clears buffers without ending the stream.
        // Like streamEnded, it must NEVER be surfaced before audio chunks that
        // preceded it in wire order.
        let client = try makePlayerClient()
        let mock = MockTransport()
        try await client.acceptConnection(mock)
        try await mock.injectText(serverHelloJSON())
        try await waitForState(client, expected: .connected, timeout: .seconds(3))

        let chunks = CollectedValues<AudioChunk>()
        let chunkTask = Task {
            for await chunk in client.audioChunks {
                await chunks.append(chunk)
            }
        }
        let stream = client.events()
        let clearTask = Task {
            await collectClientEvent(from: stream) {
                if case .streamCleared = $0 { true } else { false }
            }
        }

        // stream/start, then audio chunks, then stream/clear — exact wire order.
        try await mock.injectText(streamStartPCMJSON())
        let chunkCount = 32
        for i in 0 ..< chunkCount {
            await mock.injectBinary(audioChunkFrame(index: i))
        }
        let clearMessage = StreamClearMessage(payload: StreamClearPayload())
        try await mock.injectText(#require(String(data: JSONEncoder().encode(clearMessage), encoding: .utf8)))

        #expect(await clearTask.value != nil, "Expected a streamCleared event")
        #expect(
            await waitUntil(timeout: .seconds(3)) { await chunks.count == chunkCount },
            "All \(chunkCount) audio chunks should be delivered on the typed data stream"
        )
        chunkTask.cancel()

        await client.disconnect()
    }

    @Test
    func midStreamFormatChange_preservesChunkOrdering() async throws {
        // A mid-stream format change (new stream/start, different sample rate) does NOT
        // clear buffers (spec README:380). This asserts the *within-class* binary contract:
        // every AudioChunk is delivered, in wire order, across the format-change
        // boundary — none dropped or reordered. The cross-class interleaving of
        // `.streamFormatChanged` (a render-applied lifecycle event, async via the engine
        // report) vs the typed audio data stream is non-deterministic by design;
        // engine-channel *processing* order across the change is asserted by the
        // mid-stream format-change processing-order test.
        let client = try makePlayerClient()
        let mock = MockTransport()
        try await client.acceptConnection(mock)
        try await mock.injectText(serverHelloJSON())
        try await waitForState(client, expected: .connected, timeout: .seconds(3))

        // Collect audio chunk server timestamps in arrival order. AudioChunk is
        // emitted for every post-gate chunk regardless of clock sync, so this needs no
        // sync — it isolates the binary delivery/ordering contract.
        let chunks = CollectedValues<AudioChunk>()
        let collectTask = Task {
            for await chunk in client.audioChunks {
                await chunks.append(chunk)
            }
        }

        // Format A (PCM 8kHz), chunks 0..<16.
        try await mock.injectText(streamStartPCMJSON())
        let formatAChunks = 16
        for i in 0 ..< formatAChunks {
            await mock.injectBinary(audioChunkFrame(index: i))
        }

        // Format B (different sample rate) mid-stream, chunks 16..<32.
        let formatBJSON = try streamStartPCMJSON(sampleRate: 16_000)
        await mock.injectText(formatBJSON)
        let formatBChunks = 16
        for i in 0 ..< formatBChunks {
            await mock.injectBinary(audioChunkFrame(index: i + formatAChunks))
        }

        let total = formatAChunks + formatBChunks
        #expect(
            await waitUntil(timeout: .seconds(3)) { await chunks.count == total },
            "Timed out waiting for \(total) audio chunk events"
        )

        await client.disconnect()
        collectTask.cancel()
        let timestamps = await chunks.all.map(\.serverTimestamp)

        #expect(
            timestamps.count == total,
            "All \(total) chunks must surface on the typed audio stream across the format change; saw \(timestamps.count)"
        )
        #expect(
            timestamps == timestamps.sorted(),
            "AudioChunk events must preserve wire (timestamp) order across the format change"
        )
    }

    // MARK: - Engine channel-based processing order

    @Test
    func streamEndIsProcessedAfterAllPrecedingAudioChunks() async throws {
        // Assert `.streamEnd` is *processed* by the engine after all chunks
        // the server sent before it — i.e. in `engine.appliedCommandKinds()`, the
        // `.streamEnd` entry follows all the preceding `.chunk` entries.
        let client = try makePlayerClient()
        let mock = MockTransport()
        try await client.acceptConnection(mock)
        try await mock.injectText(serverHelloJSON())
        try await waitForState(client, expected: .connected, timeout: .seconds(3))
        // Chunks are dropped before clock sync; establish it so `.chunk` commands reach the engine.
        try await establishClockSync(client, via: mock)

        // stream/start, then many audio chunks, then stream/end
        try await mock.injectText(streamStartPCMJSON())
        let chunkCount = 32
        for i in 0 ..< chunkCount {
            await mock.injectBinary(audioChunkFrame(index: i))
        }
        try await mock.injectText(#require(String(data: JSONEncoder().encode(StreamEndMessage()), encoding: .utf8)))

        // Access the connection-owned engine and wait until it has drained through the terminal command.
        guard let engine = client.connection?.audioEngineForTesting else {
            Issue.record("AudioEngine should be available after player stream start")
            return
        }
        // streamEnd is the last frame injected; FIFO guarantees all chunks applied before it.
        try await waitForEngineDrain(engine) { $0.last == .streamEnd }

        let kinds = await engine.appliedCommandKinds()

        // Verify that the last command kind is .streamEnd
        guard let lastKind = kinds.last else {
            Issue.record("Expected at least one applied command")
            return
        }
        #expect(lastKind == .streamEnd, "Last applied command should be .streamEnd")

        // Verify that all .chunk entries come before .streamEnd
        var chunksSeen = 0
        var foundStreamEnd = false
        for kind in kinds {
            switch kind {
            case .chunk:
                chunksSeen += 1
            case .streamEnd:
                foundStreamEnd = true
            default:
                break
            }
        }
        #expect(foundStreamEnd, "streamEnd command should be applied")
        #expect(chunksSeen == chunkCount, "All \(chunkCount) chunk commands should appear before streamEnd")

        await client.disconnect()
    }

    @Test
    func streamClearIsProcessedAfterAllPrecedingAudioChunks() async throws {
        // Assert `.streamClear` is processed by the engine after the
        // preceding `.chunk` entries in `appliedCommandKinds()`.
        let client = try makePlayerClient()
        let mock = MockTransport()
        try await client.acceptConnection(mock)
        try await mock.injectText(serverHelloJSON())
        try await waitForState(client, expected: .connected, timeout: .seconds(3))
        // Chunks are dropped before clock sync; establish it so `.chunk` commands reach the engine.
        try await establishClockSync(client, via: mock)

        // stream/start, then audio chunks, then stream/clear
        try await mock.injectText(streamStartPCMJSON())
        let chunkCount = 24
        for i in 0 ..< chunkCount {
            await mock.injectBinary(audioChunkFrame(index: i))
        }
        let clearMessage = StreamClearMessage(payload: StreamClearPayload())
        try await mock.injectText(#require(String(data: JSONEncoder().encode(clearMessage), encoding: .utf8)))

        guard let engine = client.connection?.audioEngineForTesting else {
            Issue.record("AudioEngine should be available after player stream start")
            return
        }
        // stream/clear is the last frame injected; FIFO guarantees all chunks applied before it.
        try await waitForEngineDrain(engine) { $0.last == .streamClear }

        let kinds = await engine.appliedCommandKinds()

        // Find streamClear and verify it comes after all chunks
        var chunksSeen = 0
        var streamClearIndex: Int?
        for (index, kind) in kinds.enumerated() {
            switch kind {
            case .chunk:
                chunksSeen += 1
            case .streamClear:
                streamClearIndex = index
            default:
                break
            }
        }

        #expect(streamClearIndex != nil, "streamClear should be applied")
        if let streamClearIndex {
            // Count chunks that appeared before streamClear
            let chunksBeforeClear = kinds[0 ..< streamClearIndex].count(where: { $0 == .chunk })
            #expect(chunksBeforeClear == chunkCount, "All \(chunkCount) chunks should be applied before streamClear")
        }

        await client.disconnect()
    }

    @Test
    func midStreamFormatChangeIsProcessedAfterPrecedingChunks() async throws {
        // Mid-stream format change is processed after preceding chunks;
        // old-generation chunks scheduled until the first new-generation chunk;
        // none dropped across the swap (generation tags monotonic/contiguous).
        let client = try makePlayerClient()
        let mock = MockTransport()
        try await client.acceptConnection(mock)
        try await mock.injectText(serverHelloJSON())
        try await waitForState(client, expected: .connected, timeout: .seconds(3))
        // Chunks are dropped before clock sync; establish it so `.chunk` commands reach the engine.
        try await establishClockSync(client, via: mock)

        // Start with format A
        try await mock.injectText(streamStartPCMJSON())

        // Inject chunks in format A
        let formatAChunks = 12
        for i in 0 ..< formatAChunks {
            await mock.injectBinary(audioChunkFrame(index: i))
        }

        // The mid-stream start is only classified as a format *change* once format A
        // is recorded (via the engine's `.started` report). Without this wait, format B
        // races the report and is misread as a fresh start — no `.formatChange` command.
        try await waitForStreamFormat(client)

        // Now inject format change
        let formatBJSON = try streamStartPCMJSON(sampleRate: 16_000)
        await mock.injectText(formatBJSON)

        // Inject chunks in format B
        let formatBChunks = 12
        for i in 0 ..< formatBChunks {
            await mock.injectBinary(audioChunkFrame(index: i + formatAChunks))
        }

        guard let engine = client.connection?.audioEngineForTesting else {
            Issue.record("AudioEngine should be available after player stream start")
            return
        }
        // Drain through both the formatChange and all format-B chunks (FIFO).
        //
        // No-drop is asserted via the engine *command channel* — every injected
        // chunk surfaces as an applied `.chunk` command in wire order, so an exact
        // count of `formatAChunks + formatBChunks` split around `.formatChange`
        // proves none were dropped across the generation swap. We do NOT inspect the
        // scheduler's per-chunk generation tags directly: that would require a
        // production accessor exposing scheduler internals purely for the test,
        // which contradicts this phase's minimal-surface / off-MainActor goal. The
        // command-count split is the intended proxy for generation contiguity.
        try await waitForEngineDrain(engine) { kinds in
            kinds.contains(.formatChange) && kinds.count(where: { $0 == .chunk }) == formatAChunks + formatBChunks
        }

        let kinds = await engine.appliedCommandKinds()

        // Verify formatChange appears after format-A chunks
        var chunksSeen = 0
        var formatChangeIndex: Int?
        for (index, kind) in kinds.enumerated() {
            if case .chunk = kind {
                chunksSeen += 1
            } else if case .formatChange = kind {
                formatChangeIndex = index
                break
            }
        }

        #expect(formatChangeIndex != nil, "formatChange should be applied")
        if let formatChangeIndex {
            // Count chunks before formatChange (format A)
            let chunksBeforeFormatChange = kinds[0 ..< formatChangeIndex].count(where: { $0 == .chunk })
            #expect(chunksBeforeFormatChange == formatAChunks, "All format-A chunks should be applied before formatChange")

            // Count chunks after formatChange (format B)
            let chunksAfterFormatChange = kinds[formatChangeIndex...].count(where: { $0 == .chunk })
            #expect(chunksAfterFormatChange == formatBChunks, "All format-B chunks should be applied after formatChange")
        }

        await client.disconnect()
    }
}
