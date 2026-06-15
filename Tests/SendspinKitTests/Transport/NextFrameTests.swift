import Foundation
@testable import SendspinKit
import Testing

// MARK: - Tests

struct NextFrameTests {
    // MARK: - Close returns nil

    @Test("Close → nil: injected frames then nil after finish")
    func closeReturnsNilAfterStreamFinish() async {
        let mock = MockTransport()

        await mock.injectText(#"{"type": "text-1"}"#)
        await mock.injectBinary(Data([0x01, 0x02]))

        let frame1 = await mock.nextFrame()
        #expect(frame1 != nil)
        if case let .text(json) = frame1 {
            #expect(json == #"{"type": "text-1"}"#)
        } else {
            Issue.record("Expected text frame, got \(String(describing: frame1))")
        }

        let frame2 = await mock.nextFrame()
        #expect(frame2 != nil)
        if case let .binary(data) = frame2 {
            #expect(data == Data([0x01, 0x02]))
        } else {
            Issue.record("Expected binary frame, got \(String(describing: frame2))")
        }

        await mock.finishStreams()

        let frameNil = await mock.nextFrame()
        #expect(frameNil == nil)
    }

    @Test("Close → nil: disconnect() finishes stream")
    func disconnectFinishesStream() async {
        let mock = MockTransport()

        await mock.injectText(#"{"type": "test"}"#)

        let frame = await mock.nextFrame()
        #expect(frame != nil)

        await mock.disconnect()

        let frameNil = await mock.nextFrame()
        #expect(frameNil == nil)
    }

    // MARK: - Exactly-once handoff

    @Test("Exactly-once handoff: every post-hello frame consumed once, none lost or duplicated")
    func exactlyOnceHandoff() async throws {
        func audioChunkWithSequence(_ seq: UInt8) -> Data {
            var frame = Data()
            frame.append(BinaryMessageType.audioChunk.rawValue)
            var timestamp = Int64(1_000_000 + Int64(seq) * 25_000).bigEndian
            frame.append(Data(bytes: &timestamp, count: 8))
            frame.append(seq)
            frame.append(Data(repeating: 0x7F, count: 399))
            return frame
        }

        let client = try await Task { @MainActor () -> SendspinClient in
            return try SendspinClient(
                clientId: "test-client",
                name: "Test Client",
                roles: [.playerV1],
                playerConfig: PlayerConfiguration(
                    bufferCapacity: 65_536,
                    supportedFormats: [
                        AudioFormatSpec(codec: .pcm, channels: 1, sampleRate: 8_000, bitDepth: 16)
                    ],
                    volumeMode: .none,
                    emitRawAudioEvents: true
                )
            )
        }.value

        let mock = MockTransport()
        try await client.acceptConnection(mock)

        try await mock.injectText(serverHelloJSON())

        let reachedConnected = await waitUntil(timeout: .seconds(3)) {
            await Task { @MainActor in client.connectionState == .connected }.value
        }
        #expect(reachedConnected, "Client failed to reach .connected state")

        let streamStartMessage = StreamStartMessage(
            payload: StreamStartPayload(
                player: StreamStartPlayer(codec: "pcm", sampleRate: 8_000, channels: 1, bitDepth: 16, codecHeader: nil),
                artwork: nil,
                visualizer: nil
            )
        )
        let streamStartData = try JSONEncoder().encode(streamStartMessage)
        let streamStartJSON = String(bytes: streamStartData, encoding: .utf8) ?? ""
        await mock.injectText(streamStartJSON)

        let collected = AtomicList<UInt8>()
        let audioChunks = await Task { @MainActor in client.audioChunks }.value
        let collector = Task {
            for await chunk in audioChunks {
                if let seq = chunk.data.first {
                    collected.append(seq)
                }
            }
        }

        // Sequence bytes: [1, 2, 3, 4, 5]. We can detect:
        // - Loss: fewer AudioChunk values than expected
        // - Duplication: more AudioChunk values than expected
        // - Reordering: sequence bytes out of order
        let chunkSequence: [UInt8] = [1, 2, 3, 4, 5]
        for seqByte in chunkSequence {
            await mock.injectBinary(audioChunkWithSequence(seqByte))
        }

        let delivered = await waitUntil(timeout: .seconds(5)) {
            collected.count == chunkSequence.count
        }
        collector.cancel()

        await mock.finishStreams()

        let outcome = (count: collected.count, sequences: collected.all)
        #expect(delivered, "Timed out waiting for typed audio chunk events")

        #expect(
            outcome.count == chunkSequence.count,
            "Injected \(chunkSequence.count) audio chunks, got \(String(describing: outcome.count)) rawAudioChunk events"
        )
        #expect(
            outcome.sequences == chunkSequence,
            "Expected sequence \(String(describing: chunkSequence)), got \(String(describing: outcome.sequences))"
        )
    }

    // MARK: - Single-consumer contract

    // The single-consumer contract for nextFrame() is enforced via a precondition
    // that traps on overlapping calls. Since a precondition failure is a fatal error
    // (not catchable in-process), we do NOT write a test that deliberately trips it
    // — that would crash the entire test process.
    //
    // Instead, we rely on the exactly-once handoff test above to indirectly verify
    // single-consumer semantics: if the client's message loop maintained multiple
    // concurrent readers (violating the contract), the precondition guard in
    // MockTransport.nextFrame() would fire, causing the test process to crash.
    // The fact that the handoff test completes successfully proves the contract
    // is respected.
    //
    // See: MockTransport.nextFrame(), which documents:
    // precondition(!isReading,
    //   "SendspinTransport.nextFrame() is single-consumer; overlapping calls are a contract violation")

    // MARK: - Mutation Verification

    //
    // The exactlyOnceHandoff test above is mutation-proven to catch frame loss AND duplication.
    //
    // Mutation test 1 (DROP): Skip the 3rd binary frame in runMessageLoop by adding:
    // ```swift
    // var binaryFrameCount = 0
    // if case .binary = frame {
    //     binaryFrameCount += 1
    //     if binaryFrameCount == 3 { continue }
    // }
    // ```
    // Result: Test FAILS. Expected 5 chunks, got 4 (one dropped).
    //
    // Mutation test 2 (DUPLICATE): Call handleBinaryMessage(data) twice per binary frame:
    // ```swift
    // case let .binary(data):
    //     await handleBinaryMessage(data)
    //     await handleBinaryMessage(data)  // duplicate call
    // ```
    // Result: Test FAILS. Expected 5 chunks, got 10 (each frame received twice).
    //
    // Both mutations are detectable via AudioChunk count, which has no idempotence guard.
    // Frame count and order are the invariants.
}
