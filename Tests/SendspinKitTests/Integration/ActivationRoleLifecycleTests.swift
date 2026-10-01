import Foundation
@testable import SendspinKit
import Testing

private struct ActivationState: Sendable {
    let metadata: Bool
    let pending: Bool
    let controller: Bool
    let player: Bool
    let artwork: Bool
    let visualizer: Bool
    let transfer: Bool
}

private extension SendspinConnection {
    func seedActivationState() {
        let artworkChannel = 0
        let artworkSize: UInt32 = 1
        let serverTimestamp: Int64 = 0
        let pendingTimestamp = Int64.max
        let metadata = TrackMetadata(
            title: "Retained",
            artist: nil,
            album: nil,
            albumArtist: nil,
            track: nil,
            year: nil,
            artworkURL: nil,
            progress: nil
        )
        currentMetadata = metadata
        metadataPending = ScheduledMetadata(metadata: metadata, localDisplayTime: pendingTimestamp)
        currentControllerState = ControllerState(
            supportedCommands: [],
            volume: 0,
            muted: false,
            repeatMode: nil,
            shuffle: nil
        )
        let color = ColorState(
            serverTimestamp: serverTimestamp,
            localDisplayTime: nil,
            backgroundDark: nil,
            backgroundLight: nil,
            primary: nil,
            accent: nil,
            onDark: nil,
            onLight: nil
        )
        currentColorState = color
        colorPending = ScheduledColor(color: color, localDisplayTime: pendingTimestamp)
        playerStreamActive = true
        artworkStreamActive = true
        visualizerStreamActive = true
        artworkTransfer = ArtworkTransfer(channel: artworkChannel, timestamp: serverTimestamp, totalSize: artworkSize, deliver: true)
    }

    func seedAnnouncedFormat(_ format: AudioFormatSpec) {
        announcedPlayerStream = (format, nil)
    }

    func activationState() -> ActivationState {
        ActivationState(
            metadata: currentMetadata != nil,
            pending: metadataPending != nil,
            controller: currentControllerState != nil,
            player: playerStreamActive,
            artwork: artworkStreamActive,
            visualizer: visualizerStreamActive,
            transfer: artworkTransfer != nil
        )
    }
}

struct ActivationRoleLifecycleTests {
    private let allRoles: Set<VersionedRole> = [.metadataV1, .colorV1, .controllerV1, .playerV1, .artworkV1, .visualizerV1]

    @Test
    func combinedInitialPairingCountsAttemptWithoutStoppingPlayback() async throws {
        let fixture = try await makeEstablishedConnection(
            activities: [.playback, .pairing], activeRoles: allRoles, pskCategory: .pairing, roles: allRoles, startConnection: false
        )
        await fixture.connection.seedActivationState()
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
        await fixture.connection.seedAnnouncedFormat(format)
        await fixture.connection.applyInitialPairingActivation(PairingDirective(method: PairMethod.pairingPsk))
        #expect(await fixture.connection.pairingActivateCounter == 1)
        #expect(await fixture.connection.announcedPlayerStream?.format == format)
        let state = await fixture.connection.activationState()
        #expect(state.player)
        #expect(state.artwork)
        #expect(state.visualizer)
        #expect(state.metadata)
        #expect(state.transfer)
        await fixture.connection.shutdown()
    }

    @MainActor @Test
    func metadataRemovalClearsFacadeAndEmitsEvent() async throws {
        let client = try makeTestClient(roles: [.metadataV1])
        let server = try await connectClient(client, activeRoles: [.metadataV1])
        let state = ServerStateMessage(payload: ServerStatePayload(
            metadata: ServerMetadataState(title: .value("Visible"))
        ))
        try await server.injectText(#require(String(data: JSONEncoder().encode(state), encoding: .utf8)))
        #expect(await waitUntil { await MainActor.run { client.currentMetadata != nil } })
        let events = client.events()
        let cleared = Task { @MainActor in
            for await event in events {
                if case let .metadataReceived(metadata) = event, metadata == .empty {
                    return client.currentMetadata == nil
                }
            }
            return false
        }
        let activation = ServerActivateMessage(payload: ServerActivatePayload(activities: [.playback], activeRoles: []))
        try await server.injectText(#require(String(data: JSONEncoder().encode(activation), encoding: .utf8)))
        #expect(await cleared.value)
        #expect(client.currentMetadata == nil)
        await client.disconnect()
    }

    @Test
    func playerVersionReplacementEnqueuesEndThenClear() async throws {
        let replacement = VersionedRole(role: VersionedRole.playerV1.role, version: "_replacement")
        let fixture = try await makeEstablishedConnection(
            activeRoles: [.playerV1], roles: [.playerV1, replacement], startConnection: false
        )
        await fixture.connection.seedActivationState()
        let engine = await fixture.connection.audioEngine
        let commands = engine.commands.commands
        await fixture.connection.handleServerActivate(ServerActivateMessage(payload: ServerActivatePayload(
            activities: [.playback], activeRoles: [replacement]
        )))
        engine.commands.finish()
        var kinds: [DataPlaneCommandKind] = []
        for await command in commands {
            kinds.append(command.kind)
        }
        let end = try #require(kinds.firstIndex(of: .streamEnd))
        #expect(kinds.dropFirst(end) == [.streamEnd, .streamClear])
        #expect(await fixture.connection.playerStreamActive == false)
        #expect(await fixture.connection.announcedPlayerStream == nil)
        await fixture.connection.shutdown()
    }

    @Test
    func removedRolesDiscardSnapshotsAndStreams() async throws {
        let fixture = try await makeEstablishedConnection(activeRoles: allRoles, roles: allRoles, startConnection: false)
        await fixture.connection.seedActivationState()
        await fixture.connection.handleServerActivate(ServerActivateMessage(payload: ServerActivatePayload(
            activities: [.playback], activeRoles: []
        )))
        let state = await fixture.connection.activationState()
        #expect(!state.metadata)
        #expect(!state.pending)
        #expect(await fixture.connection.currentColorState == nil)
        #expect(await fixture.connection.colorPending == nil)
        #expect(!state.controller)
        #expect(!state.player)
        #expect(!state.artwork)
        #expect(!state.visualizer)
        #expect(!state.transfer)
        await fixture.connection.disconnect(reason: .userRequest)
    }

    @Test
    func unrelatedRoleRemovalPreservesArtworkTransferAndMetadata() async throws {
        let fixture = try await makeEstablishedConnection(activeRoles: allRoles, roles: allRoles, startConnection: false)
        await fixture.connection.seedActivationState()
        await fixture.connection.handleServerActivate(ServerActivateMessage(payload: ServerActivatePayload(
            activities: [.playback], activeRoles: Array(allRoles.subtracting([.controllerV1]))
        )))
        let state = await fixture.connection.activationState()
        #expect(state.metadata)
        #expect(state.pending)
        #expect(state.transfer)
        #expect(state.player)
        #expect(state.artwork)
        #expect(state.visualizer)
        #expect(!state.controller)
        await fixture.connection.disconnect(reason: .userRequest)
    }
}
