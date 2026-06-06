// ABOUTME: Verifies server-reported session state is reset at each new connection
// ABOUTME: server/state deltas merge onto the previous value, so stale state must not bleed across a reconnect

import Foundation
@testable import SendspinKit
import Testing

@MainActor
struct SessionStateResetTests {
    // MARK: Fixtures

    private func serverStateMetadataJSON(
        title: Nullable<String> = .absent,
        album: Nullable<String> = .absent
    ) throws -> String {
        let message = ServerStateMessage(payload: ServerStatePayload(
            metadata: ServerMetadataState(title: title, album: album)
        ))
        return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
    }

    private func serverStateControllerJSON(
        supportedCommands: [ControllerCommandType]? = nil,
        volume: Int? = nil,
        muted: Bool? = nil,
        repeat repeatMode: RepeatMode? = nil,
        shuffle: Bool? = nil
    ) throws -> String {
        let controller = ServerControllerState(
            supportedCommands: supportedCommands,
            volume: volume,
            muted: muted,
            repeat: repeatMode,
            shuffle: shuffle
        )
        let message = ServerStateMessage(payload: ServerStatePayload(controller: controller))
        return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
    }

    private func groupUpdateJSON(
        groupId: String? = nil,
        groupName: String? = nil,
        playbackState: PlaybackState? = nil
    ) throws -> String {
        let message = GroupUpdateMessage(payload: GroupUpdatePayload(
            playbackState: playbackState,
            groupId: groupId,
            groupName: groupName
        ))
        return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
    }

    /// Drop the connection the way a network failure does — the frame stream ends
    /// without an explicit `disconnect()` — and wait for the client to notice.
    private func loseConnection(_ client: SendspinClient, _ mock: MockTransport) async {
        await mock.finishStreams()
        _ = await waitUntil { await MainActor.run { client.connectionState == .disconnected } }
    }

    // MARK: Cross-connection bleed

    @Test
    func metadataDoesNotBleedAcrossConnectionLostReconnect() async throws {
        let client = try makeTestClient()
        let mock1 = try await connectClient(client)

        try await mock1.injectText(serverStateMetadataJSON(title: .value("Old Track")))
        let gotOld = await waitUntil { await MainActor.run { client.currentMetadata?.title == "Old Track" } }
        #expect(gotOld)

        await loseConnection(client, mock1)

        // Reconnect to a server whose first delta omits the title (absent = keep
        // previous). On a clean session there is no previous, so title stays nil.
        let mock2 = try await connectClient(client)
        try await mock2.injectText(serverStateMetadataJSON(album: .value("New Album")))
        let gotNew = await waitUntil { await MainActor.run { client.currentMetadata?.album == "New Album" } }
        #expect(gotNew)

        #expect(client.currentMetadata?.title == nil, "Stale metadata must not survive a reconnect")

        await client.disconnect()
    }

    @Test
    func controllerStateDoesNotBleedAcrossConnectionLostReconnect() async throws {
        let client = try makeTestClient()
        let mock1 = try await connectClient(client)

        try await mock1.injectText(serverStateControllerJSON(
            supportedCommands: [.play, .pause],
            volume: 80
        ))
        let gotOld = await waitUntil { await MainActor.run { client.currentControllerState?.volume == 80 } }
        #expect(gotOld)

        await loseConnection(client, mock1)

        // New server sends only a repeat-mode delta; volume and commands are absent.
        let mock2 = try await connectClient(client)
        try await mock2.injectText(serverStateControllerJSON(repeat: .all))
        let gotNew = await waitUntil { await MainActor.run { client.currentControllerState?.repeatMode == .all } }
        #expect(gotNew)

        let state = try #require(client.currentControllerState)
        #expect(state.volume == 0, "Stale controller volume must not survive a reconnect")
        #expect(state.supportedCommands.isEmpty, "Stale supported commands must not survive a reconnect")

        await client.disconnect()
    }

    // MARK: Deliberate exclusions

    @Test
    func groupMembershipSurvivesReconnect() async throws {
        // The spec keeps group membership across reconnections, so the session
        // reset must leave `currentGroup` untouched.
        let client = try makeTestClient()
        let mock1 = try await connectClient(client)

        try await mock1.injectText(groupUpdateJSON(groupId: "g1", groupName: "Kitchen", playbackState: .playing))
        let gotGroup = await waitUntil { await MainActor.run { client.currentGroup?.groupId == "g1" } }
        #expect(gotGroup)

        await loseConnection(client, mock1)

        _ = try await connectClient(client)
        #expect(client.currentGroup?.groupId == "g1", "Group membership must survive a reconnect (spec)")
        #expect(client.currentGroup?.groupName == "Kitchen")

        await client.disconnect()
    }

    @Test
    func sameConnectionRehelloPreservesMetadata() async throws {
        // A server may re-send server/hello on the *same* connection (e.g. to
        // restart clock sync). That is not a new session, so accumulated metadata
        // must survive — this is why the session reset lives in setupConnection,
        // not handleServerHello.
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        try await mock.injectText(serverStateMetadataJSON(title: .value("Now Playing")))
        let got = await waitUntil { await MainActor.run { client.currentMetadata?.title == "Now Playing" } }
        #expect(got)

        // Re-hello on the same connection, with a distinct server id so we can tell
        // the re-hello has been processed before asserting.
        try await mock.injectText(serverHelloJSON(serverId: "server-after-rehello"))
        let processed = await waitUntil { await MainActor.run { client.currentServerId == "server-after-rehello" } }
        #expect(processed, "Re-hello should be processed")

        #expect(client.currentMetadata?.title == "Now Playing", "Same-connection re-hello must not wipe accumulated metadata")

        await client.disconnect()
    }
}
