import Foundation
@testable import SendspinKit
import Testing

private extension SendspinConnection {
    func invalidateTestRoute() {
        routeInvalidationPending = true
    }
}

struct PlayerStreamConfigurationTests {
    @Test("Successful outcomes emit one start across configuration updates", arguments: [true, false])
    func successfulOutcomesStartOnce(staleFirstReport: Bool) async throws {
        let fixture = try await makeEstablishedConnection(startConnection: false)
        let connection = fixture.connection
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
        await connection.handleStreamStart(announcement(format))
        let first = await connection.playerStartGeneration
        if !staleFirstReport {
            await connection.applyEngineReport(.started(format, startGeneration: first))
        }
        await connection.handleStreamStart(announcement(format, header: Data("second".utf8)))
        let second = await connection.playerStartGeneration
        if staleFirstReport {
            await connection.applyEngineReport(.started(format, startGeneration: first))
        }
        await connection.applyEngineReport(.formatApplied(format, startGeneration: second))
        if staleFirstReport {
            await connection.handleStreamStart(announcement(format, header: Data("third".utf8)))
            let third = await connection.playerStartGeneration
            await connection.applyEngineReport(.formatApplied(format, startGeneration: third))
        }
        connection.controlSink.finish()
        var outcomes: [ConnectionEvent] = []
        for await event in connection.events {
            if case .streamStarted = event {
                outcomes.append(event)
            }
            if case .streamFormatChanged = event {
                outcomes.append(event)
            }
        }
        #expect(outcomes == [.streamStarted(format), .streamFormatChanged(format)])
        await connection.shutdown()
    }

    @Test("An active stream rebuild changes format and an ended stream starts again")
    func rebuildAndStreamBoundaryChooseEvents() async throws {
        let fixture = try await makeEstablishedConnection(startConnection: false)
        let connection = fixture.connection
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
        await connection.handleStreamStart(announcement(format))
        await connection.applyEngineReport(.started(format, startGeneration: connection.playerStartGeneration))
        let beforeRebuild = await connection.playerStartGeneration
        await connection.invalidateTestRoute()
        await connection.handleStreamStart(announcement(format))
        #expect(await connection.playerStartGeneration > beforeRebuild)
        await connection.applyEngineReport(.started(format, startGeneration: connection.playerStartGeneration))
        await connection.handleStreamEnd(StreamEndMessage(payload: .init(roles: [StreamRole.player.rawValue])))
        await connection.handleStreamStart(announcement(format))
        await connection.applyEngineReport(.formatApplied(format, startGeneration: connection.playerStartGeneration))
        connection.controlSink.finish()
        var outcomes: [ConnectionEvent] = []
        for await event in connection.events {
            if case .streamStarted = event {
                outcomes.append(event)
            }
            if case .streamFormatChanged = event {
                outcomes.append(event)
            }
        }
        #expect(outcomes == [.streamStarted(format), .streamFormatChanged(format), .streamStarted(format)])
        await connection.shutdown()
    }

    @Test("Player role removal resets the first-success event")
    func playerRoleRemovalResetsStart() async throws {
        let fixture = try await makeEstablishedConnection(startConnection: false)
        let connection = fixture.connection
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
        await connection.handleStreamStart(announcement(format))
        await connection.applyEngineReport(.started(format, startGeneration: connection.playerStartGeneration))
        await connection.handleServerActivate(ServerActivateMessage(payload: .init(activities: [], activeRoles: [])))
        #expect(await connection.activeRoles.isEmpty)
        #expect(await connection.playerStartedEventEmitted == false)
        await connection.handleServerActivate(ServerActivateMessage(payload: .init(activities: [.playback], activeRoles: [.playerV1])))
        #expect(await connection.activeRoles == [.playerV1])
        await connection.handleStreamStart(announcement(format))
        await connection.applyEngineReport(.formatApplied(format, startGeneration: connection.playerStartGeneration))
        #expect(await lifecycleOutcomes(connection) == [.streamStarted(format), .streamStarted(format)])
        await connection.shutdown()
    }

    @Test("Stream clear preserves the first-success event")
    func streamClearPreservesStart() async throws {
        let fixture = try await makeEstablishedConnection(startConnection: false)
        let connection = fixture.connection
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
        await connection.handleStreamStart(announcement(format))
        await connection.applyEngineReport(.started(format, startGeneration: connection.playerStartGeneration))
        await connection.handleStreamClear(StreamClearMessage(payload: .init(roles: [StreamRole.player.rawValue])))
        await connection.handleStreamStart(announcement(format, header: Data("updated".utf8)))
        await connection.applyEngineReport(.formatApplied(format, startGeneration: connection.playerStartGeneration))
        #expect(await lifecycleOutcomes(connection) == [.streamStarted(format), .streamFormatChanged(format)])
        await connection.shutdown()
    }

    @Test("A failed start does not consume the first-success event")
    func failedStartRetryEmitsStart() async throws {
        let fixture = try await makeEstablishedConnection(startConnection: false)
        let connection = fixture.connection
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
        await connection.handleStreamStart(announcement(format))
        await connection.applyEngineReport(.startFailed(reason: "test output failure", startGeneration: connection.playerStartGeneration))
        await connection.handleStreamStart(announcement(format))
        await connection.applyEngineReport(.started(format, startGeneration: connection.playerStartGeneration))
        #expect(await lifecycleOutcomes(connection) == [.streamStarted(format)])
        await connection.shutdown()
    }

    private func lifecycleOutcomes(_ connection: SendspinConnection) async -> [ConnectionEvent] {
        connection.controlSink.finish()
        var outcomes: [ConnectionEvent] = []
        for await event in connection.events {
            switch event {
            case .streamStarted, .streamFormatChanged: outcomes.append(event)
            default: break
            }
        }
        return outcomes
    }

    @MainActor
    @Test("Reactivation updates activities without repeating serverConnected")
    func reactivationDoesNotRepeatConnection() async throws {
        let client = try SendspinClient(identity: .generate(), name: "Lifecycle", roles: [.metadataV1])
        let events = client.events()
        let info = ServerInfo(serverId: "server", name: "Named server", trustLevel: .none, activeRoles: [.metadataV1], activities: [])
        client.applyConnectionEvent(.serverConnected(info))
        client.applyConnectionEvent(.serverActivated(activities: [.playback], activeRoles: [.metadataV1]))
        #expect(client.currentActivities == [.playback])
        client.applyConnectionEvent(.serverActivated(activities: [], activeRoles: [.metadataV1]))
        #expect(client.currentActivities.isEmpty)
        await client.close()
        var connected: [ServerInfo] = []
        for await event in events {
            if case let .serverConnected(server) = event {
                connected.append(server)
            }
        }
        #expect(connected == [info])
    }

    private func announcement(_ format: AudioFormatSpec, header: Data? = nil) -> StreamStartMessage {
        StreamStartMessage(payload: StreamStartPayload(
            player: StreamStartPlayer(
                codec: format.codec.rawValue,
                sampleRate: format.sampleRate,
                channels: format.channels,
                bitDepth: format.bitDepth,
                codecHeader: header?.base64EncodedString()
            ),
            artwork: nil, visualizer: nil
        ))
    }

    @Test("Opus-only player catalogs are rejected")
    func opusOnlyCatalogIsRejected() throws {
        let opus = try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16)
        #expect(throws: ConfigurationError.missingLosslessFormat) {
            try PlayerConfiguration(bufferCapacity: 1, supportedFormats: [opus])
        }
    }

    @Test("Current-output catalogs require FLAC or PCM at the route rate")
    func currentOutputRequiresLosslessFormat() throws {
        let opus = try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let pcm = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
        #expect(throws: OutputFormatError.noMatchingLosslessFormat) {
            try effectiveSupportedFormats([opus, pcm], policy: .requireCurrentOutput, outputSampleRate: opus.sampleRate)
        }
        #expect(try effectiveSupportedFormats([opus, pcm], policy: .requireCurrentOutput, outputSampleRate: pcm.sampleRate) == [pcm])
    }

    @Test("Opus depth is ignored for validation and matching but retained on the wire")
    func opusDepthIsIgnoredForValidationAndMatching() throws {
        let catalog = try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let incoming = try JSONDecoder().decode(AudioFormatSpec.self, from: Data(
            #"{"codec":"opus","channels":2,"sample_rate":48000,"bit_depth":7}"#.utf8
        ))
        #expect(incoming.bitDepth == 7)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(incoming)) as? [String: Any])
        #expect(encoded["bit_depth"] as? Int == 7)
        #expect(incoming == catalog)
        #expect(Set([incoming, catalog]).count == 1)
        #expect(try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 7) == catalog)
        #expect(throws: ConfigurationError.unsupportedBitDepth(7)) {
            try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 7)
        }
    }
}
