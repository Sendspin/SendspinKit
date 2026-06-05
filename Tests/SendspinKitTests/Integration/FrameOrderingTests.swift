// ABOUTME: Verifies incoming frames are dispatched in wire order
// ABOUTME: Audio chunks and stream lifecycle messages must not reorder relative to each other

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

private func streamStartPCMJSON() throws -> String {
    let message = StreamStartMessage(
        payload: StreamStartPayload(
            player: StreamStartPlayer(codec: "pcm", sampleRate: 8_000, channels: 1, bitDepth: 16, codecHeader: nil),
            artwork: nil,
            visualizer: nil
        )
    )
    return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
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
    func rawAudioChunks_emittedEvenWhenArrivingBeforeStreamStart() async throws {
        // Frames are dispatched in wire order on a single task, so audio chunks that
        // arrive before stream/start are processed before it. shouldEmitRawAudio must
        // therefore already be true at connection setup (not deferred to
        // handleStreamStart) or these chunks emit no raw events.
        let client = try makePlayerClient()
        let mock = MockTransport()
        try await client.acceptConnection(mock)
        try await mock.injectText(serverHelloJSON())
        try await waitForState(client, expected: .connected, timeout: .seconds(3))

        // Inject audio chunks BEFORE stream/start.
        let chunkCount = 3
        for i in 0 ..< chunkCount {
            await mock.injectBinary(audioChunkFrame(index: i))
        }
        try await mock.injectText(streamStartPCMJSON())

        let stream = client.events
        let collected = await withTaskGroup(of: Int.self) { group in
            group.addTask {
                var count = 0
                for await event in stream {
                    if case .rawAudioChunk = event { count += 1 }
                    if count >= chunkCount { break }
                }
                return count
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return -1 // sentinel for timeout
            }
            for await result in group {
                group.cancelAll()
                return result
            }
            return 0
        }

        #expect(collected == chunkCount, "Expected \(chunkCount) rawAudioChunk events but got \(collected)")

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
        // rawAudioChunk precedes streamEnded.
        let client = try makePlayerClient()
        let mock = MockTransport()
        try await client.acceptConnection(mock)
        try await mock.injectText(serverHelloJSON())
        try await waitForState(client, expected: .connected, timeout: .seconds(3))

        // stream/start, then many audio chunks, then stream/end — exact wire order.
        // Enough chunks to expose the race: the old binary task lagged the text task
        // by dozens of chunks before stream/end overtook them.
        try await mock.injectText(streamStartPCMJSON())
        let chunkCount = 64
        for i in 0 ..< chunkCount {
            await mock.injectBinary(audioChunkFrame(index: i))
        }
        try await mock.injectText(#require(String(data: JSONEncoder().encode(StreamEndMessage()), encoding: .utf8)))

        // Count rawAudioChunk events seen before the streamEnded event.
        let stream = client.events
        let outcome: (chunksBeforeEnd: Int, sawEnd: Bool) = await withTaskGroup(of: (Int, Bool)?.self) { group in
            group.addTask {
                var chunks = 0
                for await event in stream {
                    switch event {
                    case .rawAudioChunk: chunks += 1
                    case .streamEnded: return (chunks, true)
                    default: break
                    }
                }
                return (chunks, false)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            for await result in group {
                group.cancelAll()
                return result ?? (-1, false)
            }
            return (0, false)
        }

        #expect(outcome.sawEnd, "Expected a streamEnded event")
        #expect(
            outcome.chunksBeforeEnd == chunkCount,
            "All \(chunkCount) rawAudioChunk events must precede streamEnded; saw \(outcome.chunksBeforeEnd)"
        )

        await client.disconnect()
    }
}
