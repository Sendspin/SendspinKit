import Foundation
@testable import SendspinKit
import Testing

@Suite("Client state snapshots")
@MainActor
struct ClientStateSnapshotTests {
    private func testFormat() throws -> AudioFormatSpec {
        try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
    }

    @Test("activation sends a complete player snapshot with required keys")
    func activationSendsCompletePlayerSnapshot() async throws {
        let client = try makeTestClient()
        let server = try await connectClient(client, activeRoles: [.playerV1])
        try await establishClockSync(client, via: server)
        let state = try #require(await nextState(server))
        let player = try #require(state.payload.player)

        #expect(state.payload.available)
        #expect(player.outputDelayMs == 0)
        #expect(player.supportedCommands.contains(.setOutputDelay))
        #expect(player.requiredLeadTimeMs == defaultRequiredLeadTimeMs)
        #expect(player.minBufferMs == defaultMinBufferMs)
        #expect(player.format == nil)
        await client.disconnect()
    }

    @Test("each player input change publishes another complete snapshot")
    func eachPlayerInputChangePublishesCompleteSnapshot() async throws {
        let client = try makeTestClient()
        let server = try await connectClient(client, activeRoles: [.playerV1])
        try await establishClockSync(client, via: server)
        #expect(await waitUntil(timeout: .seconds(3)) { await stateMessages(server).count >= 1 })

        let baseline = await stateMessages(server).count
        let format = try testFormat()
        try await client.updatePlayerSupportedCommands([.volume, .mute, .setOutputDelay])
        try await client.setPlayerFormatPreference(format)
        try await client.setVolume(42)
        try await client.setMute(true)
        try await client.setOutputDelay(250)

        #expect(await waitUntil(timeout: .seconds(3)) { await stateMessages(server).count >= baseline + 5 })
        let snapshots = await stateMessages(server)
        let changed = Array(snapshots.suffix(5))
        #expect(changed.count == 5)
        for state in changed {
            let player = try #require(state.payload.player)
            #expect(player.outputDelayMs >= 0 && player.outputDelayMs <= maxOutputDelayMs)
            #expect(Set(player.supportedCommands) == Set([.volume, .mute, .setOutputDelay]))
            #expect(player.volume != nil)
            #expect(player.muted != nil)
            #expect(player.requiredLeadTimeMs == defaultRequiredLeadTimeMs)
            #expect(player.minBufferMs == defaultMinBufferMs)
            #expect(player.format == format || player.format == nil)
        }
        await client.disconnect()
    }

    @Test("artwork preference publication retains complete unrelated role state")
    func artworkPreferencePublicationRetainsCompleteRoleSnapshot() async throws {
        let artworkChannel = try ArtworkChannel(source: .album, format: .jpeg, width: 320, height: 240)
        let artwork = try ArtworkConfiguration(channels: [artworkChannel])
        let visualizer = try VisualizerConfiguration(types: [.loudness], rateMax: 30)
        let player = try PlayerConfiguration(bufferCapacity: 1_024, supportedFormats: [testFormat()], volumeMode: .none)
        let client = try SendspinClient(
            identity: .generate(), name: "Snapshot Roles", roles: [.playerV1, .artworkV1, .visualizerV1],
            playerConfig: player, artworkConfig: artwork, visualizerConfig: visualizer,
            audioOutputCapabilityProvider: makeInertAudioOutputCapabilityProvider()
        )
        let server = try await connectClient(client, activeRoles: [.playerV1, .artworkV1, .visualizerV1])
        let before = await stateMessages(server).count
        try await client.setArtworkChannelPreference(channel: 0, preference: .disable)
        #expect(await waitUntil(timeout: .seconds(3)) { await stateMessages(server).count > before })
        let state = try #require(await stateMessages(server).last)
        #expect(state.payload.player != nil)
        #expect(state.payload.artwork?.channels.first?.source == ArtworkSource.none)
        #expect(state.payload.visualizer?.types == [.loudness])
        try await client.setArtworkChannelPreference(
            channel: 0,
            preference: .set(source: .artist, format: .png, width: 160, height: 120)
        )
        #expect(await waitUntil(timeout: .seconds(3)) {
            await stateMessages(server).last?.payload.artwork?.channels.first?.source == .artist
        })
        await #expect(throws: ConfigurationError.artworkChannelOutOfRange(1)) {
            try await client.setArtworkChannelPreference(channel: 1, preference: .disable)
        }
        await client.disconnect()
    }

    private func stateMessages(_ server: MockNoiseServer) async -> [ClientStateMessage] {
        await server.clientJSONMessages(ofType: ClientStateMessage.typeString).compactMap {
            try? JSONDecoder().decode(ClientStateMessage.self, from: $0)
        }
    }

    private func nextState(_ server: MockNoiseServer) async throws -> ClientStateMessage? {
        _ = await waitUntil(timeout: .seconds(3)) { await stateMessages(server).isEmpty == false }
        return await stateMessages(server).first
    }
}
