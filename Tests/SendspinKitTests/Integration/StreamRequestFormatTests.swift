// ABOUTME: Verifies stream/request-format is emitted only while the role's stream is active
// ABOUTME: A format request renegotiates an existing stream, so it is gated on stream/start..stream/end

import Foundation
@testable import SendspinKit
import Testing

@MainActor
struct StreamRequestFormatTests {
    // MARK: Fixtures

    private func makePlayerClient() throws -> SendspinClient {
        try SendspinClient(
            clientId: "test-client",
            name: "Test Client",
            roles: [.playerV1],
            playerConfig: PlayerConfiguration(
                bufferCapacity: 65_536,
                supportedFormats: [
                    AudioFormatSpec(codec: .pcm, channels: 1, sampleRate: 8_000, bitDepth: 16),
                    AudioFormatSpec(codec: .flac, channels: 1, sampleRate: 8_000, bitDepth: 16)
                ],
                volumeMode: .none,
                emitRawAudioEvents: true
            )
        )
    }

    private func makeArtworkClient() throws -> SendspinClient {
        try SendspinClient(
            clientId: "test-client",
            name: "Test Client",
            roles: [.artworkV1],
            artworkConfig: ArtworkConfiguration(channels: [
                ArtworkChannel(source: .album, format: .jpeg, mediaWidth: 300, mediaHeight: 300)
            ])
        )
    }

    private func makePlayerArtworkClient() throws -> SendspinClient {
        try SendspinClient(
            clientId: "test-client",
            name: "Test Client",
            roles: [.playerV1, .artworkV1],
            playerConfig: PlayerConfiguration(
                bufferCapacity: 65_536,
                supportedFormats: [
                    AudioFormatSpec(codec: .pcm, channels: 1, sampleRate: 8_000, bitDepth: 16)
                ],
                volumeMode: .none,
                emitRawAudioEvents: true
            ),
            artworkConfig: ArtworkConfiguration(channels: [
                ArtworkChannel(source: .album, format: .jpeg, mediaWidth: 300, mediaHeight: 300)
            ])
        )
    }

    /// `codec` is a raw wire string so callers can inject codecs the client does
    /// not support (e.g. to exercise the unsupported-codec path).
    private func playerStreamStartJSON(codec: String = "pcm") throws -> String {
        let message = StreamStartMessage(payload: StreamStartPayload(
            player: StreamStartPlayer(codec: codec, sampleRate: 8_000, channels: 1, bitDepth: 16, codecHeader: nil),
            artwork: nil,
            visualizer: nil
        ))
        return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
    }

    private func playerArtworkStreamStartJSON() throws -> String {
        let message = StreamStartMessage(payload: StreamStartPayload(
            player: StreamStartPlayer(codec: "pcm", sampleRate: 8_000, channels: 1, bitDepth: 16, codecHeader: nil),
            artwork: StreamStartArtwork(channels: [
                StreamArtworkChannelConfig(source: .album, format: .jpeg, width: 300, height: 300)
            ]),
            visualizer: nil
        ))
        return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
    }

    private func artworkStreamStartJSON() throws -> String {
        let message = StreamStartMessage(payload: StreamStartPayload(
            player: nil,
            artwork: StreamStartArtwork(channels: [
                StreamArtworkChannelConfig(source: .album, format: .jpeg, width: 300, height: 300)
            ]),
            visualizer: nil
        ))
        return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
    }

    private func streamEndJSON(roles: [String]? = nil) throws -> String {
        let message = StreamEndMessage(payload: StreamEndPayload(roles: roles))
        return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
    }

    /// Decode every emitted `stream/request-format`. The message's `type` is a
    /// non-decoded constant, so frames are discriminated by the wire `type` field
    /// instead. The transport encodes snake_case keys that match the explicit
    /// `CodingKeys`, so a plain decoder (no key strategy) round-trips correctly.
    private func sentRequestFormats(_ mock: MockTransport) async throws -> [StreamRequestFormatMessage] {
        let referenceType = StreamRequestFormatMessage(payload: StreamRequestFormatPayload()).type
        let decoder = JSONDecoder()
        let messages = await mock.sentTextMessages
        return try messages.compactMap { data in
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == referenceType else { return nil }
            return try decoder.decode(StreamRequestFormatMessage.self, from: data)
        }
    }

    // MARK: Player gating

    @Test
    func requestPlayerFormat_throwsBeforeAnyStream() async throws {
        let client = try makePlayerClient()
        let mock = try await connectClient(client, activeRoles: [.playerV1])

        await #expect(throws: SendspinClientError.streamNotActive(.player)) {
            try await client.requestPlayerFormat(codec: .flac)
        }
        let sent = try await sentRequestFormats(mock)
        #expect(sent.isEmpty, "No stream/request-format may be emitted without an active stream")

        await client.disconnect()
    }

    @Test
    func requestPlayerFormat_sendsWhileStreamActive() async throws {
        let client = try makePlayerClient()
        let mock = try await connectClient(client, activeRoles: [.playerV1])

        try await mock.injectText(playerStreamStartJSON())
        let active = await waitUntil { await MainActor.run { client.playerStreamActive } }
        #expect(active, "Player stream should be active after stream/start")

        try await client.requestPlayerFormat(codec: .flac)

        let sent = try await sentRequestFormats(mock)
        #expect(sent.count == 1)
        #expect(sent.first?.payload.player?.codec == .flac)
        #expect(sent.first?.payload.artwork == nil)

        await client.disconnect()
    }

    @Test
    func requestPlayerFormat_throwsAfterStreamEnd() async throws {
        let client = try makePlayerClient()
        let mock = try await connectClient(client, activeRoles: [.playerV1])

        try await mock.injectText(playerStreamStartJSON())
        _ = await waitUntil { await MainActor.run { client.playerStreamActive } }

        try await mock.injectText(streamEndJSON())
        let ended = await waitUntil { await MainActor.run { !client.playerStreamActive } }
        #expect(ended, "Player stream should be inactive after stream/end")

        await #expect(throws: SendspinClientError.streamNotActive(.player)) {
            try await client.requestPlayerFormat(codec: .flac)
        }

        await client.disconnect()
    }

    @Test
    func requestPlayerFormat_convenienceOverloadInheritsTheGate() async throws {
        let client = try makePlayerClient()
        let mock = try await connectClient(client, activeRoles: [.playerV1])

        let format = try AudioFormatSpec(codec: .flac, channels: 1, sampleRate: 8_000, bitDepth: 16)

        // Before a stream: the AudioFormatSpec overload must be gated just like the
        // parameterized one (it delegates to it).
        await #expect(throws: SendspinClientError.streamNotActive(.player)) {
            try await client.requestPlayerFormat(format)
        }

        try await mock.injectText(playerStreamStartJSON())
        _ = await waitUntil { await MainActor.run { client.playerStreamActive } }

        try await client.requestPlayerFormat(format)
        let sent = try await sentRequestFormats(mock)
        #expect(sent.count == 1)
        #expect(sent.first?.payload.player?.codec == .flac)

        await client.disconnect()
    }

    @Test
    func requestPlayerFormat_survivesMidStreamFormatChange() async throws {
        // A second stream/start while already streaming is a format renegotiation,
        // not a teardown — the gate must stay open across it.
        let client = try makePlayerClient()
        let mock = try await connectClient(client, activeRoles: [.playerV1])

        try await mock.injectText(playerStreamStartJSON(codec: "pcm"))
        _ = await waitUntil { await MainActor.run { client.currentStreamFormat?.codec == .pcm } }

        try await mock.injectText(playerStreamStartJSON(codec: "flac"))
        let changed = await waitUntil { await MainActor.run { client.currentStreamFormat?.codec == .flac } }
        #expect(changed, "Second stream/start should update the active format")
        #expect(client.playerStreamActive, "Gate must remain open across a mid-stream format change")

        try await client.requestPlayerFormat(codec: .pcm)
        let sent = try await sentRequestFormats(mock)
        #expect(sent.count == 1)

        await client.disconnect()
    }

    @Test
    func requestPlayerFormat_staysOpenWhenServerStartsUnsupportedCodec() async throws {
        // The server started a player stream the client cannot decode. The gate
        // still opens (the stream is active server-side) so the client can
        // renegotiate to a codec it supports — the gate tracks server intent.
        let client = try makePlayerClient()
        let mock = try await connectClient(client, activeRoles: [.playerV1])

        try await mock.injectText(playerStreamStartJSON(codec: "mp3"))
        let active = await waitUntil { await MainActor.run { client.playerStreamActive } }
        #expect(active, "Gate opens even when the codec is unsupported")

        try await client.requestPlayerFormat(codec: .flac)
        let sent = try await sentRequestFormats(mock)
        #expect(sent.count == 1)
        #expect(sent.first?.payload.player?.codec == .flac)

        await client.disconnect()
    }

    // MARK: Connection loss

    @Test
    func requestPlayerFormat_throwsAfterConnectionLost() async throws {
        // A dropped connection (frame stream ends without an explicit disconnect)
        // must close the gate, so a later request fails cleanly with streamNotActive
        // rather than passing the gate and failing with a misleading sendFailed.
        let client = try makePlayerClient()
        let mock = try await connectClient(client, activeRoles: [.playerV1])

        try await mock.injectText(playerStreamStartJSON())
        _ = await waitUntil { await MainActor.run { client.playerStreamActive } }

        await mock.finishStreams()
        let closed = await waitUntil { await MainActor.run { !client.playerStreamActive } }
        #expect(closed, "Connection loss must clear the player stream gate")

        await #expect(throws: SendspinClientError.streamNotActive(.player)) {
            try await client.requestPlayerFormat(codec: .flac)
        }

        await client.disconnect()
    }

    // MARK: Artwork gating

    @Test
    func requestArtworkFormat_throwsBeforeAnyStream() async throws {
        let client = try makeArtworkClient()
        let mock = try await connectClient(client, activeRoles: [.artworkV1])

        await #expect(throws: SendspinClientError.streamNotActive(.artwork)) {
            try await client.requestArtworkFormat(channel: 0, format: .png)
        }
        let sent = try await sentRequestFormats(mock)
        #expect(sent.isEmpty)

        await client.disconnect()
    }

    @Test
    func requestArtworkFormat_sendsWhileStreamActive() async throws {
        let client = try makeArtworkClient()
        let mock = try await connectClient(client, activeRoles: [.artworkV1])

        try await mock.injectText(artworkStreamStartJSON())
        let active = await waitUntil { await MainActor.run { client.artworkStreamActive } }
        #expect(active, "Artwork stream should be active after stream/start")

        try await client.requestArtworkFormat(channel: 0, format: .png)

        let sent = try await sentRequestFormats(mock)
        #expect(sent.count == 1)
        #expect(sent.first?.payload.artwork?.channel == 0)
        #expect(sent.first?.payload.artwork?.format == .png)
        #expect(sent.first?.payload.player == nil)

        await client.disconnect()
    }

    // MARK: Independent streams

    @Test
    func endingPlayerStreamLeavesArtworkRequestable() async throws {
        // player and artwork are independent streams: a stream/end naming only
        // "player" must close the player gate while leaving artwork's open.
        let client = try makePlayerArtworkClient()
        let mock = try await connectClient(client, activeRoles: [.playerV1, .artworkV1])

        try await mock.injectText(playerArtworkStreamStartJSON())
        let bothActive = await waitUntil {
            await MainActor.run { client.playerStreamActive && client.artworkStreamActive }
        }
        #expect(bothActive, "Both streams should be active after a combined stream/start")

        try await mock.injectText(streamEndJSON(roles: ["player"]))
        let playerClosed = await waitUntil { await MainActor.run { !client.playerStreamActive } }
        #expect(playerClosed)
        #expect(client.artworkStreamActive, "Ending the player stream must not touch artwork")

        await #expect(throws: SendspinClientError.streamNotActive(.player)) {
            try await client.requestPlayerFormat(codec: .flac)
        }
        try await client.requestArtworkFormat(channel: 0, format: .png)

        let sent = try await sentRequestFormats(mock)
        #expect(sent.count == 1)
        #expect(sent.first?.payload.artwork?.channel == 0)

        await client.disconnect()
    }
}
