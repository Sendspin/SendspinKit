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
    private func playerStreamStartJSON(codec: String = AudioCodec.pcm.rawValue) throws -> String {
        let message = StreamStartMessage(payload: StreamStartPayload(
            player: StreamStartPlayer(codec: codec, sampleRate: 8_000, channels: 1, bitDepth: 16, codecHeader: nil),
            artwork: nil,
            visualizer: nil
        ))
        return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
    }

    private func playerArtworkStreamStartJSON() throws -> String {
        let message = StreamStartMessage(payload: StreamStartPayload(
            player: StreamStartPlayer(codec: AudioCodec.pcm.rawValue, sampleRate: 8_000, channels: 1, bitDepth: 16, codecHeader: nil),
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

    private func streamClearJSON(roles: [String]? = nil) throws -> String {
        let message = StreamClearMessage(payload: StreamClearPayload(roles: roles))
        return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
    }

    /// Subscribe to the public event stream and wait (bounded) for `.streamCleared`.
    /// Subscribes before the caller injects, so AsyncStream buffering removes the race.
    private func streamClearedWaiter(for client: SendspinClient) -> Task<Bool, Never> {
        let stream = client.events()
        return Task {
            await collectClientEvent(from: stream, timeout: .seconds(3)) {
                if case .streamCleared = $0 { true } else { false }
            } != nil
        }
    }

    /// Subscribe to the public event stream and wait (bounded) for `.streamEnded` with roles.
    /// Subscribes before the caller injects, so AsyncStream buffering removes the race.
    private func streamEndedWaiter(for client: SendspinClient, expectedRoles: [String]?) -> Task<Bool, Never> {
        let stream = client.events()
        return Task {
            await collectClientEvent(from: stream, timeout: .seconds(3)) {
                if case let .streamEnded(roles) = $0, roles == expectedRoles { true } else { false }
            } != nil
        }
    }

    /// Decode every emitted `stream/request-format`. The message's `type` is a
    /// non-decoded constant, so frames are discriminated by the wire `type` field
    /// instead. The transport encodes snake_case keys that match the explicit
    /// `CodingKeys`, so a plain decoder (no key strategy) round-trips correctly.
    private func sentRequestFormats(_ mock: MockTransport) async throws -> [StreamRequestFormatMessage] {
        let referenceType = StreamRequestFormatMessage.typeString
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
    func requestPlayerFormat_throwsNotConnectedWhenDisconnected() async throws {
        let client = try makePlayerClient()

        await #expect(throws: SendspinClientError.notConnected) {
            try await client.requestPlayerFormat(codec: .flac)
        }
    }

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

        try await mock.injectText(playerStreamStartJSON())
        // The mid-stream start is classified as a *change* only once format A is
        // recorded (via the engine's `.started` report). Without this wait, the
        // second start races the report and is misread as a fresh start.
        try await waitForStreamFormat(client)
        #expect(client.currentStreamFormat?.codec == .pcm, "First stream/start should establish format A")

        try await mock.injectText(playerStreamStartJSON(codec: "flac"))

        // `currentStreamFormat` is render-applied: the engine emits `.formatApplied`
        // (which updates it) only when new-format audio actually renders. With no
        // chunks flowing, that never fires, so we assert the renegotiation through
        // the deterministic engine command channel instead — the client must enqueue
        // a `.formatChange` (not tear the stream down).
        let engine = try #require(client.connection?.audioEngineForTesting, "AudioEngine should exist after player stream start")
        try await waitForEngineDrain(engine) { $0.contains(.formatChange) }
        #expect(client.playerStreamActive, "Gate must remain open across a mid-stream format change")

        try await client.requestPlayerFormat(codec: .pcm)
        let sent = try await sentRequestFormats(mock)
        #expect(sent.count == 1)

        await client.disconnect()
    }

    @Test
    func midStreamFormatChange_classifiedWithoutAwaitingStartedReport() async throws {
        // Classification uses the synchronously-tracked
        // announced format, not the async render-applied currentStreamFormat. A
        // second stream/start arriving before the first `.started` report drains
        // must still be classified as a format *change* (enqueue `.formatChange`),
        // not a fresh start. The deliberate absence of waitForStreamFormat is the
        // point. Mutation proof: keying isFormatChange off currentStreamFormat (the
        // prior behavior) leaves it nil here → misclassified as `.streamStart` → no
        // `.formatChange` → waitForEngineDrain times out → this test fails.
        let client = try makePlayerClient()
        let mock = try await connectClient(client, activeRoles: [.playerV1])

        try await mock.injectText(playerStreamStartJSON())
        try await mock.injectText(playerStreamStartJSON(codec: AudioCodec.flac.rawValue))

        let engine = try #require(client.connection?.audioEngineForTesting)
        try await waitForEngineDrain(engine) { $0.contains(.formatChange) }
        // The facade learns playerStreamActive from its own control-event drain,
        // which races the engine command drain awaited above — poll, don't snapshot.
        let active = await waitUntil { await MainActor.run { client.playerStreamActive } }
        #expect(active)

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
        // must detach the facade from the connection, so a later request fails
        // cleanly with notConnected rather than passing the gate and failing with
        // a misleading sendFailed.
        let client = try makePlayerClient()
        let mock = try await connectClient(client, activeRoles: [.playerV1])

        try await mock.injectText(playerStreamStartJSON())
        _ = await waitUntil { await MainActor.run { client.playerStreamActive } }

        await mock.finishStreams()
        let closed = await waitUntil { await MainActor.run { !client.playerStreamActive } }
        #expect(closed, "Connection loss must clear the player stream gate")

        await #expect(throws: SendspinClientError.notConnected) {
            try await client.requestPlayerFormat(codec: .flac)
        }

        await client.disconnect()
    }

    // MARK: Artwork gating

    @Test
    func requestArtworkFormat_throwsNotConnectedWhenDisconnected() async throws {
        let client = try makeArtworkClient()

        await #expect(throws: SendspinClientError.notConnected) {
            try await client.requestArtworkFormat(channel: 0, format: .png)
        }
    }

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

    // MARK: stream/clear (spec: clear buffers WITHOUT ending the stream)

    @Test
    func streamClear_keepsRequestFormatGatesOpen() async throws {
        // Spec: stream/clear "instructs clients to clear buffers without ending
        // the stream" — clients "continue with chunks received after this
        // message". The stream stays protocol-active, so both request-format
        // gates must remain open (a seek must not break format renegotiation).
        let client = try makePlayerArtworkClient()
        let mock = try await connectClient(client, activeRoles: [.playerV1, .artworkV1])

        try await mock.injectText(playerArtworkStreamStartJSON())
        let bothActive = await waitUntil {
            await MainActor.run { client.playerStreamActive && client.artworkStreamActive }
        }
        #expect(bothActive, "Both streams should be active after a combined stream/start")

        let cleared = streamClearedWaiter(for: client)
        try await mock.injectText(streamClearJSON())
        #expect(await cleared.value, "Expected a streamCleared event")

        #expect(client.playerStreamActive, "stream/clear must not close the player gate")
        #expect(client.artworkStreamActive, "stream/clear must not close the artwork gate")

        try await client.requestPlayerFormat(codec: .pcm)
        try await client.requestArtworkFormat(channel: 0, format: .png)

        let sent = try await sentRequestFormats(mock)
        #expect(sent.count == 2, "Both roles must remain renegotiable after stream/clear")

        await client.disconnect()
    }

    @Test
    func streamClear_preservesCurrentStreamFormat() async throws {
        // stream/clear clears buffers WITHOUT ending the stream, so the negotiated
        // format must survive it. The complementary gate-survival is covered by
        // `streamClear_keepsRequestFormatGatesOpen`; here we pin the *format* half
        // of "both sides survive a clear": the render-applied `currentStreamFormat`
        // mirror AND the still-open player gate.
        let client = try makePlayerClient()
        let mock = try await connectClient(client, activeRoles: [.playerV1])

        try await mock.injectText(playerStreamStartJSON())
        try await waitForStreamFormat(client)
        let before = await MainActor.run { client.currentStreamFormat }
        #expect(before?.codec == .pcm, "positive control: stream/start must establish the format")

        let cleared = streamClearedWaiter(for: client)
        try await mock.injectText(streamClearJSON())
        #expect(await cleared.value, "Expected a streamCleared event")

        let after = await MainActor.run { client.currentStreamFormat }
        #expect(after == before, "stream/clear must NOT drop the negotiated stream format")
        #expect(client.playerStreamActive, "stream/clear must NOT close the player gate")

        await client.disconnect()
    }

    // MARK: Gate authority (connection, not facade mirror)

    @Test
    func requestPlayerFormat_gateAuthorityLivesInConnection() async throws {
        // The connection owns the protocol-intent gates; the facade boolean is a
        // render-applied observability mirror. Falsifying the mirror must not
        // block a request while the connection's gate (opened at stream/start)
        // is open. Mutation proof: re-gating the facade API on its own boolean
        // makes this throw streamNotActive.
        let client = try makePlayerClient()
        let mock = try await connectClient(client, activeRoles: [.playerV1])

        try await mock.injectText(playerStreamStartJSON())
        let active = await waitUntil { await MainActor.run { client.playerStreamActive } }
        #expect(active)

        client.playerStreamActive = false // mirror only — must not gate
        try await client.requestPlayerFormat(codec: .flac)

        let sent = try await sentRequestFormats(mock)
        #expect(sent.count == 1)

        await client.disconnect()
    }

    @Test
    func requestArtworkFormat_gateAuthorityLivesInConnection() async throws {
        let client = try makeArtworkClient()
        let mock = try await connectClient(client, activeRoles: [.artworkV1])

        try await mock.injectText(artworkStreamStartJSON())
        let active = await waitUntil { await MainActor.run { client.artworkStreamActive } }
        #expect(active)

        client.artworkStreamActive = false // mirror only — must not gate
        try await client.requestArtworkFormat(channel: 0, format: .png)

        let sent = try await sentRequestFormats(mock)
        #expect(sent.count == 1)

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

        try await mock.injectText(streamEndJSON(roles: [StreamRole.player.rawValue]))
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

    @Test
    func endingArtworkStreamLeavesPlayerRequestable() async throws {
        // player and artwork are independent streams: a stream/end naming only
        // "artwork" must close the artwork gate while leaving player's open.
        let client = try makePlayerArtworkClient()
        let mock = try await connectClient(client, activeRoles: [.playerV1, .artworkV1])

        try await mock.injectText(playerArtworkStreamStartJSON())
        let bothActive = await waitUntil {
            await MainActor.run { client.playerStreamActive && client.artworkStreamActive }
        }
        #expect(bothActive, "Both streams should be active after a combined stream/start")

        let ended = streamEndedWaiter(for: client, expectedRoles: [StreamRole.artwork.rawValue])
        try await mock.injectText(streamEndJSON(roles: [StreamRole.artwork.rawValue]))
        #expect(await ended.value, "Expected a role-aware artwork streamEnded event")

        let artworkClosed = await waitUntil { await MainActor.run { !client.artworkStreamActive } }
        #expect(artworkClosed, "Ending artwork must close the artwork mirror")
        #expect(client.playerStreamActive, "Ending artwork must not touch player")

        await #expect(throws: SendspinClientError.streamNotActive(.artwork)) {
            try await client.requestArtworkFormat(channel: 0, format: .png)
        }
        try await client.requestPlayerFormat(codec: .pcm)

        let sent = try await sentRequestFormats(mock)
        #expect(sent.count == 1)
        #expect(sent.first?.payload.player?.codec == .pcm)

        await client.disconnect()
    }

    @Test
    func streamEndWithoutRolesClosesAllFacadeMirrors() async throws {
        let client = try makePlayerArtworkClient()
        let mock = try await connectClient(client, activeRoles: [.playerV1, .artworkV1])

        try await mock.injectText(playerArtworkStreamStartJSON())
        let bothActive = await waitUntil {
            await MainActor.run { client.playerStreamActive && client.artworkStreamActive }
        }
        #expect(bothActive, "Both streams should be active after a combined stream/start")

        let ended = streamEndedWaiter(for: client, expectedRoles: nil)
        try await mock.injectText(streamEndJSON())
        #expect(await ended.value, "Expected a role-aware all-streams streamEnded event")

        let bothClosed = await waitUntil {
            await MainActor.run { !client.playerStreamActive && !client.artworkStreamActive }
        }
        #expect(bothClosed, "stream/end without roles must close all known stream mirrors")

        await #expect(throws: SendspinClientError.streamNotActive(.player)) {
            try await client.requestPlayerFormat(codec: .pcm)
        }
        await #expect(throws: SendspinClientError.streamNotActive(.artwork)) {
            try await client.requestArtworkFormat(channel: 0, format: .png)
        }

        await client.disconnect()
    }
}
