import Foundation
@testable import SendspinKit
import Testing

/// Decode every `client/state` payload sent after `offset`, dispatching on the wire
/// `type` tag. Necessary because `ClientStatePayload`'s fields are all optional, so
/// other message types decode "successfully" as an empty payload.
private func clientStatePayloads(from mock: MockTransport, after offset: Int = 0) async -> [ClientStatePayload] {
    let messages = await mock.sentTextMessages
    return messages.dropFirst(offset)
        .filter { SendspinEncoding.messageType(of: $0) == ClientStateMessage.typeString }
        .compactMap { try? JSONDecoder().decode(ClientStateMessage.self, from: $0).payload }
}

@MainActor
struct ClientStateDeltaTests {
    @Test
    func initialSendIsFullPayload() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        let initial = try #require(
            await clientStatePayloads(from: mock).first,
            "Expected an initial client/state after server/hello"
        )

        #expect(initial.state == .synchronized)
        let player = try #require(initial.player, "Initial state must include the full player object")
        #expect(player.volume == client.currentVolume)
        #expect(player.muted == client.currentMuted)
        #expect(player.staticDelayMs == client.staticDelayMs)
        #expect(player.requiredLeadTimeMs == defaultRequiredLeadTimeMs, "Should send default required_lead_time_ms")
        #expect(player.minBufferMs == defaultMinBufferMs, "Should send default min_buffer_ms")

        // Per spec §489 the client/state supported_commands is a subset of
        // {set_static_delay} only — volume/mute are advertised in client/hello, never here.
        #expect(
            Set(player.supportedCommands ?? []) == [.setStaticDelay],
            "client/state supported_commands must be {set_static_delay}, got \(player.supportedCommands ?? [])"
        )

        await client.disconnect()
    }

    @Test
    func playerConfigurationRejectsNegativeTimingFields() throws {
        // Negative timing values throw their dedicated ConfigurationError cases.
        let formats = try [AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)]
        #expect(throws: ConfigurationError.negativeRequiredLeadTime(-1)) {
            _ = try PlayerConfiguration(bufferCapacity: 16_384, supportedFormats: formats, requiredLeadTimeMs: -1)
        }
        #expect(throws: ConfigurationError.negativeMinBuffer(-5)) {
            _ = try PlayerConfiguration(bufferCapacity: 16_384, supportedFormats: formats, minBufferMs: -5)
        }
    }

    @Test
    func initialPayloadIncludesTimingFields() async throws {
        // Test with custom timing values (spec §485-487)
        let playerConfig = try PlayerConfiguration(
            bufferCapacity: 16_384,
            supportedFormats: [AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)],
            requiredLeadTimeMs: 150,
            minBufferMs: 750
        )
        let client = try SendspinClient(
            clientId: "test-timing",
            name: "Timing Test",
            roles: [.playerV1],
            playerConfig: playerConfig
        )
        let mock = try await connectClient(client)

        let initial = try #require(
            await clientStatePayloads(from: mock).first,
            "Expected an initial client/state after server/hello"
        )

        let player = try #require(initial.player, "Initial state must include the full player object")
        #expect(player.requiredLeadTimeMs == 150, "Should send configured required_lead_time_ms")
        #expect(player.minBufferMs == 750, "Should send configured min_buffer_ms")

        await client.disconnect()
    }

    @Test
    func subsequentChangeSendsOnlyChangedFields() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        let countBefore = await mock.sentTextMessages.count
        let newVolume = client.currentVolume == 100 ? 42 : 100
        try await client.setVolume(newVolume)

        let delta = try #require(
            await clientStatePayloads(from: mock, after: countBefore).last,
            "Expected a client/state delta after setVolume"
        )

        // Only the changed field is present; unchanged fields are omitted.
        #expect(delta.state == nil)
        #expect(delta.player?.volume == newVolume)
        #expect(delta.player?.muted == nil)
        #expect(delta.player?.staticDelayMs == nil)
        #expect(delta.player?.supportedCommands == nil)

        await client.disconnect()
    }

    @Test
    func unchangedUpdateIsSuppressed() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        let countBefore = await mock.sentTextMessages.count
        // Re-set the current values: nothing changed, so nothing should be sent.
        try await client.setVolume(client.currentVolume)
        try await client.setMute(client.currentMuted)

        let deltas = await clientStatePayloads(from: mock, after: countBefore)
        #expect(deltas.isEmpty, "A no-op state update must not send a client/state message")

        await client.disconnect()
    }

    @Test
    func duplicateServerHelloDoesNotResetClientStateBaseline() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        let newVolume = client.currentVolume == 100 ? 42 : 100
        try await client.setVolume(newVolume)

        // A duplicate server/hello on the same established connection is ignored:
        // it must not reset the client/state delta baseline or emit a fresh full state.
        let countBefore = await mock.sentTextMessages.count
        try await mock.injectText(serverHelloJSON())
        let appeared = await waitUntil(timeout: .milliseconds(300)) {
            await !clientStatePayloads(from: mock, after: countBefore).isEmpty
        }
        #expect(!appeared, "Duplicate same-connection server/hello must not send a new client/state")

        await client.disconnect()
    }
}
