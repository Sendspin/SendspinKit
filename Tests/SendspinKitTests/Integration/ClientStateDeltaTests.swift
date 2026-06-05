// ABOUTME: Tests that client/state is sent as deltas after the initial full payload
// ABOUTME: Covers issue #19 — only changed fields go on the wire; the server merges them

import Foundation
@testable import SendspinKit
import Testing

/// Decode every `client/state` payload sent after `offset`, filtering on the
/// JSON `type` field. Necessary because `ClientStatePayload`'s fields are all
/// optional, so other message types decode "successfully" as an empty payload.
private func clientStatePayloads(from mock: MockTransport, after offset: Int = 0) async -> [ClientStatePayload] {
    let messages = await mock.sentTextMessages
    return messages.dropFirst(offset).compactMap { data -> ClientStatePayload? in
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "client/state" else { return nil }
        return try? JSONDecoder().decode(ClientStateMessage.self, from: data).payload
    }
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
    func reconnectResendsFullBaseline() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        let newVolume = client.currentVolume == 100 ? 42 : 100
        try await client.setVolume(newVolume)

        // A fresh server/hello means the server holds no prior state, so the
        // next send must be the full baseline — even though nothing changed.
        let countBefore = await mock.sentTextMessages.count
        try await mock.injectText(serverHelloJSON())
        let appeared = await waitUntil {
            await !clientStatePayloads(from: mock, after: countBefore).isEmpty
        }
        #expect(appeared, "Expected a client/state after re-hello")

        let baseline = try #require(
            await clientStatePayloads(from: mock, after: countBefore).first,
            "Expected a full client/state after re-hello"
        )
        #expect(baseline.state == .synchronized)
        #expect(baseline.player?.volume == newVolume)
        #expect(baseline.player?.staticDelayMs == client.staticDelayMs)

        await client.disconnect()
    }
}
