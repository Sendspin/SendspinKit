import Foundation
@testable import SendspinKit
import Testing

@MainActor
struct SessionStateResetTests {
    // MARK: Fixtures

    private func serverStateColorJSON(_ color: ServerColorState) throws -> String {
        let message = ServerStateMessage(payload: ServerStatePayload(color: color))
        let data = try JSONEncoder().encode(message)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func serverStateMetadataJSON(
        title: Nullable<String> = .absent,
        album: Nullable<String> = .absent,
        progress: Nullable<MetadataProgress> = .absent
    ) throws -> String {
        let message = ServerStateMessage(payload: ServerStatePayload(
            metadata: ServerMetadataState(title: title, album: album, progress: progress)
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

    private func streamStartPCMJSON() throws -> String {
        let message = StreamStartMessage(payload: StreamStartPayload(
            player: StreamStartPlayer(codec: AudioCodec.pcm.rawValue, sampleRate: 48_000, channels: 2, bitDepth: 16, codecHeader: nil),
            artwork: nil,
            visualizer: nil
        ))
        return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
    }

    /// Drop the connection the way a network failure does — the frame stream ends
    /// without an explicit `disconnect()` — and wait for the client to notice.
    private func loseConnection(_ client: SendspinClient, _ mock: MockNoiseServer) async {
        await mock.finishStreams()
        _ = await waitUntil { await MainActor.run { client.connectionState == .disconnected } }
    }

    @Test
    func colorStateMergesDeltasAndPublishesStateBeforeEvent() async throws {
        let client = try makeTestClient(roles: [.colorV1])
        let mock = try await connectClient(client, activeRoles: [.colorV1])
        let initial = SendspinColor(red: 10, green: 20, blue: 30)
        let accent = SendspinColor(red: 200, green: 100, blue: 50)

        let observed = Task { @MainActor () -> ColorState? in
            for await event in client.events() {
                if case let .colorStateUpdated(state) = event, state.serverTimestamp == 2 {
                    return client.currentColorState
                }
            }
            return nil
        }

        let initialColorJSON = try serverStateColorJSON(ServerColorState(
            timestamp: 1,
            backgroundDark: .value(initial),
            primary: .value(accent)
        ))
        await mock.injectText(initialColorJSON)
        #expect(await waitUntil { await MainActor.run { client.currentColorState?.serverTimestamp == 1 } })
        #expect(client.currentColorState?.localDisplayTime == nil)

        let deltaColorJSON = try serverStateColorJSON(ServerColorState(
            timestamp: 2,
            backgroundDark: .absent,
            primary: .null
        ))
        await mock.injectText(deltaColorJSON)
        let result = await observeTask(observed, timeout: .seconds(3))

        switch result {
        case let .completed(state):
            #expect(state?.backgroundDark == initial)
            #expect(state?.primary == nil)
            #expect(state?.accent == nil)
        case .timedOut:
            Issue.record("Timed out waiting for colorStateUpdated")
        }

        await client.disconnect()
    }

    // MARK: Cross-connection bleed

    @Test
    func colorStateDoesNotBleedAcrossConnectionLostReconnect() async throws {
        let client = try makeTestClient(roles: [.colorV1])
        let mock1 = try await connectClient(client, activeRoles: [.colorV1])
        let oldColor = SendspinColor(red: 80, green: 90, blue: 100)

        try await mock1.injectText(serverStateColorJSON(ServerColorState(
            timestamp: 1,
            backgroundDark: .value(oldColor),
            backgroundLight: .value(oldColor),
            primary: .value(oldColor),
            accent: .value(oldColor),
            onDark: .value(oldColor),
            onLight: .value(oldColor)
        )))
        let gotOld = await waitUntil {
            await MainActor.run {
                let state = client.currentColorState
                return state?.backgroundDark == oldColor
                    && state?.backgroundLight == oldColor
                    && state?.primary == oldColor
                    && state?.accent == oldColor
                    && state?.onDark == oldColor
                    && state?.onLight == oldColor
            }
        }
        #expect(gotOld)

        await loseConnection(client, mock1)

        let mock2 = try await connectClient(client, activeRoles: [.colorV1])
        let newColor = SendspinColor(red: 1, green: 2, blue: 3)
        try await mock2.injectText(serverStateColorJSON(ServerColorState(
            timestamp: 2,
            backgroundDark: .absent,
            backgroundLight: .absent,
            primary: .value(newColor),
            accent: .absent,
            onDark: .absent,
            onLight: .absent
        )))
        let gotNew = await waitUntil {
            await MainActor.run { client.currentColorState?.primary == newColor }
        }
        #expect(gotNew)
        #expect(client.currentColorState?.backgroundDark == nil)

        await client.disconnect()
    }

    @Test
    func metadataStateDoesNotChangeExistingColorState() async throws {
        let client = try makeTestClient(roles: [.colorV1, .metadataV1])
        let mock = try await connectClient(client, activeRoles: [.colorV1, .metadataV1])
        let color = SendspinColor(red: 10, green: 20, blue: 30)

        try await mock.injectText(serverStateColorJSON(ServerColorState(
            timestamp: 1,
            primary: .value(color)
        )))
        #expect(await waitUntil { await MainActor.run { client.currentColorState?.primary == color } })

        try await mock.injectText(serverStateMetadataJSON(title: .value("Track")))
        #expect(await waitUntil { await MainActor.run { client.currentMetadata?.title == "Track" } })
        #expect(client.currentColorState?.primary == color)

        await client.disconnect()
    }

    @Test
    func colorStateClearsWhenServerSendsWholeRoleNull() async throws {
        let client = try makeTestClient(roles: [.colorV1])
        let mock = try await connectClient(client, activeRoles: [.colorV1])
        let color = SendspinColor(red: 10, green: 20, blue: 30)

        try await mock.injectText(serverStateColorJSON(ServerColorState(
            timestamp: 1,
            primary: .value(color)
        )))
        #expect(await waitUntil { await MainActor.run { client.currentColorState?.primary == color } })

        let clear = ServerStateMessage(payload: ServerStatePayload(colorDelta: .null))
        let clearJSON = try #require(String(data: JSONEncoder().encode(clear), encoding: .utf8))
        await mock.injectText(clearJSON)

        #expect(await waitUntil { await MainActor.run { client.currentColorState == nil } })
        await client.disconnect()
    }

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
        // reset must preserve group identity while clearing session-scoped playback state.
        let client = try makeTestClient()
        let mock1 = try await connectClient(client)

        try await mock1.injectText(groupUpdateJSON(groupId: "g1", groupName: "Kitchen", playbackState: .playing))
        let gotGroup = await waitUntil { await MainActor.run { client.currentGroup?.groupId == "g1" } }
        #expect(gotGroup)

        await loseConnection(client, mock1)

        _ = try await connectClient(client)
        #expect(client.currentGroup?.groupId == "g1", "Group membership must survive a reconnect (spec)")
        #expect(client.currentGroup?.groupName == "Kitchen")
        // Observe the cleared state with bounded polling so the check does not depend on
        // task scheduling around connection setup.
        let clearedPlayback = await waitUntil { await MainActor.run { client.currentGroup?.playbackState == nil } }
        #expect(clearedPlayback, "Playback state is session-scoped and must not survive reconnect")
        let clearedStatus = await waitUntil { await MainActor.run { client.currentPlaybackStatus == nil } }
        #expect(clearedStatus, "Derived playback status must not report stale playback after reconnect")

        await client.disconnect()
    }

    @Test
    func currentPlaybackStatusTracksGroupAndProgress() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        try await mock.injectText(groupUpdateJSON(groupId: "g1", groupName: "Kitchen", playbackState: .playing))
        let gotPlaying = await waitUntil { await MainActor.run { client.currentPlaybackStatus == .playing } }
        #expect(gotPlaying)

        try await mock.injectText(serverStateMetadataJSON(
            progress: .value(MetadataProgress(trackProgress: 10_000, trackDuration: 120_000, playbackSpeed: 0))
        ))
        let gotPaused = await waitUntil { await MainActor.run { client.currentPlaybackStatus == .paused } }
        #expect(gotPaused)

        try await mock.injectText(groupUpdateJSON(playbackState: .stopped))
        let gotStopped = await waitUntil { await MainActor.run { client.currentPlaybackStatus == .stopped } }
        #expect(gotStopped)

        await client.disconnect()
    }

    @Test
    func activePlayerStreamOverridesStalePausedProgress() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        try await mock.injectText(groupUpdateJSON(groupId: "g1", groupName: "Kitchen", playbackState: .stopped))
        try await mock.injectText(serverStateMetadataJSON(
            progress: .value(MetadataProgress(trackProgress: 32_000, trackDuration: 312_000, playbackSpeed: 0))
        ))
        let gotStopped = await waitUntil { await MainActor.run { client.currentPlaybackStatus == .stopped } }
        #expect(gotStopped)

        try await mock.injectText(groupUpdateJSON(playbackState: .playing))
        let staleProgressMakesPaused = await waitUntil { await MainActor.run { client.currentPlaybackStatus == .paused } }
        #expect(staleProgressMakesPaused)

        try await mock.injectText(streamStartPCMJSON())
        let gotPlayingFromActiveStream = await waitUntil { await MainActor.run { client.currentPlaybackStatus == .playing } }
        #expect(gotPlayingFromActiveStream, "An active local player stream must override stale paused progress metadata")

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
        let transportB = MockTransport()
        let mockB = MockNoiseServer(transport: transportB, psk: .sentinel)
        async let accepted: Void = client.acceptConnection(transportB)
        try await mockB.establishSession(name: "Server B", activities: [.playback], activeRoles: [.playerV1, .controllerV1])
        try await accepted
        let admittedServerId = await mockB.serverId

        // Connection B should be live and metadata should be reset (per spec, server/hello resets state)
        #expect(client.connectionState == .connected, "Connection B must be live")
        #expect(client.currentServerId == admittedServerId, "Must be connected to server B")

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
