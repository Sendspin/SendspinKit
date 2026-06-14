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

    // MARK: Same-connection delta merge

    @Test
    func metadataDeltasMergeWithinConnection() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        try await mock.injectText(serverStateMetadataJSON(
            title: .value("Song A"),
            album: .value("Album A")
        ))
        let gotInitial = await waitUntil {
            await MainActor.run {
                client.currentMetadata?.title == "Song A" && client.currentMetadata?.album == "Album A"
            }
        }
        #expect(gotInitial)

        try await mock.injectText(serverStateMetadataJSON(title: .value("Song B")))
        let preservedAlbum = await waitUntil {
            await MainActor.run {
                client.currentMetadata?.title == "Song B" && client.currentMetadata?.album == "Album A"
            }
        }
        #expect(preservedAlbum, "Absent metadata fields in a delta must keep previous values")

        try await mock.injectText(serverStateMetadataJSON(album: .null))
        let clearedAlbum = await waitUntil {
            await MainActor.run {
                client.currentMetadata?.title == "Song B" && client.currentMetadata?.album == nil
            }
        }
        #expect(clearedAlbum, "Explicit null metadata fields in a delta must clear previous values")

        await client.disconnect()
    }

    @Test
    func groupUpdateDeltasMergeWithinConnection() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        try await mock.injectText(groupUpdateJSON(groupId: "g1", groupName: "Kitchen", playbackState: .stopped))
        let gotInitial = await waitUntil {
            await MainActor.run {
                client.currentGroup?.groupId == "g1" && client.currentGroup?.groupName == "Kitchen"
                    && client.currentGroup?.playbackState == .stopped
            }
        }
        #expect(gotInitial)

        try await mock.injectText(groupUpdateJSON(playbackState: .playing))
        let preservedGroup = await waitUntil {
            await MainActor.run {
                client.currentGroup?.groupId == "g1" && client.currentGroup?.groupName == "Kitchen"
                    && client.currentGroup?.playbackState == .playing
            }
        }
        #expect(preservedGroup, "Absent group/update fields in a delta must keep previous values")

        await mock.injectText("""
        {"type":"group/update","payload":{"group_name":null}}
        """)
        let clearedName = await waitUntil {
            await MainActor.run {
                client.currentGroup?.groupId == "g1" && client.currentGroup?.groupName == ""
                    && client.currentGroup?.playbackState == .playing
            }
        }
        #expect(clearedName, "Explicit null group/update fields in a delta must clear previous values")

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

        // Duplicate server/hello on the same established connection is ignored.
        try await mock.injectText(serverHelloJSON(serverId: "server-after-rehello"))
        let processed = await waitUntil(timeout: .milliseconds(300)) {
            await MainActor.run { client.currentServerId == "server-after-rehello" }
        }
        #expect(!processed, "Duplicate same-connection server/hello should be ignored")

        #expect(client.currentMetadata?.title == "Now Playing", "Ignored duplicate server/hello must not wipe accumulated metadata")

        await client.disconnect()
    }

    // MARK: Reconnect-while-draining

    @Test
    func reconnectWhileDrainingCompletesCleanly() async throws {
        // When reconnecting while audio is still draining from a previous connection,
        // the old connection must teardown without hanging, releasing its resources.
        // This is the observable baseline for reconnect teardown.
        let client = try makeTestClient()
        let mockA = try await connectClient(client)

        // Start playback on connection A to set up state
        try await mockA.injectText(serverStateMetadataJSON(title: .value("Track A")))
        let gotA = await waitUntil { await MainActor.run { client.currentMetadata?.title == "Track A" } }
        #expect(gotA, "Metadata should be received on connection A")

        // Capture connection A before the swap (for identity verification)
        let connectionA = client.connection

        // Now drive a reconnect to B while A is still potentially draining
        // (we don't need real audio to test this; the concern is task cleanup)
        let mockB = MockTransport()
        async let accepted: Void = client.acceptConnection(mockB)
        try await mockB.injectText(serverHelloJSON(serverId: "server-b", connectionReason: .playback))
        try await accepted

        // Connection B should be live and metadata should be reset (per spec, server/hello resets state)
        #expect(client.connectionState == .connected, "Connection B must be live")
        #expect(client.currentServerId == "server-b", "Must be connected to server B")

        // Inject new metadata on B (this proves B is the active connection)
        try await mockB.injectText(serverStateMetadataJSON(title: .value("Track B")))
        let gotB = await waitUntil { await MainActor.run { client.currentMetadata?.title == "Track B" } }
        #expect(gotB, "Track B metadata should be received on new connection")

        // Verify A's resources have been released (same surface as ConnectionLostTeardownTests)
        // After B takes over, the client's live connection should be B's, not A's.
        // The connection object identity has changed from A to B (drop A / install B).
        let connectionB = client.connection
        #expect(connectionB !== connectionA, "Connection object identity should have changed from A to B")

        // The current live resources belong to B. Disconnecting should release them cleanly.
        await client.disconnect()
        try await waitForState(client, expected: .disconnected, timeout: .seconds(3))
        #expect(client.connectionState == .disconnected, "Client should disconnect cleanly")
        // The connection owns the transport; releasing the connection releases it.
        #expect(client.connection == nil, "Connection (and its transport) must be released after disconnect")
        #expect(client.drainConnectionEventsTask == nil, "Drain task must be released after disconnect")
    }
}
