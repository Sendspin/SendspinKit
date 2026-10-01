import Foundation
@testable import SendspinKit
import Testing

struct NonPlayerRoleAlignmentTests {
    @Test("controller commands require the latest received supported commands")
    func controllerCommandsRequireLatestSnapshot() async throws {
        let fixture = try await makeEstablishedConnection(activeRoles: [.controllerV1], roles: [.controllerV1])
        let command = ControllerCommand(command: .play)
        await #expect(throws: SendspinClientError.controllerStateUnavailable) {
            try await fixture.connection.sendControllerCommand(command)
        }
        let unsupported = try JSONDecoder().decode(
            ServerStateMessage.self,
            from: Data(
                #"""
                {"type":"server/state","payload":{"controller":{
                  "supported_commands":["pause"],"volume":100,"muted":false,"repeat":"off","shuffle":false
                }}}
                """#
                .utf8
            )
        )
        await fixture.connection.handleServerState(unsupported)
        await #expect(throws: SendspinClientError.controllerCommandUnsupported(.play)) {
            try await fixture.connection.sendControllerCommand(command)
        }
        let supported = try JSONDecoder().decode(
            ServerStateMessage.self,
            from: Data(
                #"""
                {"type":"server/state","payload":{"controller":{
                  "supported_commands":["play"],"volume":100,"muted":false,"repeat":"off","shuffle":false
                }}}
                """#
                .utf8
            )
        )
        await fixture.connection.handleServerState(supported)
        try await fixture.connection.sendControllerCommand(command)
        let server = fixture.server
        #expect(await waitUntil { await server.clientJSONMessages(ofType: ClientCommandMessage.typeString).count == 1 })
        let messages = await fixture.server.clientJSONMessages(ofType: ClientCommandMessage.typeString)
        #expect(messages.count == 1)
        #expect(try JSONDecoder().decode(ClientCommandMessage.self, from: #require(messages.first)).payload.controller?.command == .play)
        let connection = fixture.connection
        let transport = fixture.transport
        await transport.enableGoodbyeGate()
        let blocker = Task { try await connection.sendClientState() }
        #expect(await waitUntil { await transport.isGoodbyeGateWaiting })
        let queued = Task {
            await #expect(throws: SendspinClientError.controllerCommandUnsupported(.play)) {
                try await connection.sendControllerCommand(command)
            }
        }
        #expect(await waitUntil { await connection.outboundWaiters.isEmpty == false })
        await connection.handleServerState(unsupported)
        await transport.releaseGoodbyeGate()
        try await blocker.value
        _ = await queued.value
        #expect(await server.clientJSONMessages(ofType: ClientCommandMessage.typeString).count == 1)
        await fixture.connection.shutdown()
    }

    @Test("disabled artwork channels decode alone and preserve mixed positional channels")
    func disabledArtworkChannelsDecodeAndApply() async throws {
        let disabled = try JSONDecoder().decode(StreamArtworkChannelConfig.self, from: Data(#"{"source":"none"}"#.utf8))
        #expect(disabled.source == .none)
        #expect(disabled.format == nil && disabled.width == nil && disabled.height == nil)
        let stray = try JSONDecoder().decode(
            StreamArtworkChannelConfig.self,
            from: Data(#"{"source":"none","format":"png","width":12,"height":34}"#.utf8)
        )
        #expect(stray.source == .none && stray.format == .png && stray.width == 12 && stray.height == 34)
        #expect(StreamArtworkChannelConfig(source: .none).format == nil)
        let start = try JSONDecoder().decode(
            StreamStartMessage.self,
            from: Data(
                #"""
                {"type":"stream/start","payload":{"server_transmitted":0,"artwork":{"channels":[
                  {"source":"none"},{"source":"album","format":"jpeg","width":64,"height":64}
                ]}}}
                """#
                .utf8
            )
        )
        let fixture = try await makeEstablishedConnection(activeRoles: [.artworkV1], roles: [.artworkV1])
        await fixture.connection.handleStreamStart(start)
        let channels = await fixture.connection.artworkStreamChannels
        #expect(channels.count == 2)
        #expect(channels[0].source == .none)
        #expect(channels[1].source == .album && channels[1].width == 64)
        #expect(await fixture.connection.artworkStreamActive)
        do {
            _ = try JSONDecoder().decode(StreamArtworkChannelConfig.self, from: Data(#"{"source":"album"}"#.utf8))
            Issue.record("An enabled channel requires format and dimensions")
        } catch DecodingError.keyNotFound {
            // Enabled channels require their metadata keys even though the properties are optional.
        }
        await fixture.connection.shutdown()
    }

    @Test("visualizer subsets omit unstreamed spectrum and accept an empty subset")
    func visualizerSubsetsAcceptOmittedSpectrumAndEmptyTypes() async throws {
        let spectrum = SpectrumConfiguration(nDispBins: 2, scale: .lin, fMin: 20, fMax: 20_000)
        let requested = try VisualizerStateObject(types: [.loudness, .spectrum], rateMax: 30, spectrum: spectrum)
        let fixture = try await makeEstablishedConnection(activeRoles: [.visualizerV1], roles: [.visualizerV1], initialVisualizerState: requested)
        await fixture.connection.handleStreamStart(start(visualizer: StreamStartVisualizer(types: [.loudness], rateMax: 30)))
        #expect(await fixture.connection.visualizerStreamConfiguration?.types == [.loudness])
        #expect(await fixture.connection.visualizerStreamActive)
        await fixture.connection.handleStreamStart(start(visualizer: StreamStartVisualizer(types: [], rateMax: 30)))
        #expect(await fixture.connection.visualizerStreamConfiguration?.types == [])
        #expect(await fixture.connection.visualizerStreamActive)
        await fixture.connection.handleStreamStart(start(visualizer: StreamStartVisualizer(types: [.peak], rateMax: 30)))
        #expect(await fixture.connection.visualizerStreamConfiguration == nil)
        await fixture.connection.shutdown()
    }

    @Test("empty visualizer requests publish a full state snapshot")
    func emptyVisualizerRequestPublishes() async throws {
        let configuration = try VisualizerConfiguration(types: [], rateMax: 30)
        #expect(configuration.types.isEmpty)
        let requested = try VisualizerStateObject(types: [.loudness], rateMax: 30)
        let fixture = try await makeEstablishedConnection(
            clock: StubClock(),
            activeRoles: [.playerV1, .visualizerV1],
            roles: [.playerV1, .visualizerV1],
            initialVisualizerState: requested
        )
        let empty = try VisualizerStateObject(types: [], rateMax: 30)
        try await fixture.connection.setVisualizerPreference(empty)
        let server = fixture.server
        #expect(await waitUntil { await server.clientJSONMessages(ofType: ClientStateMessage.typeString).isEmpty == false })
        let bytes = try #require(await fixture.server.clientJSONMessages(ofType: ClientStateMessage.typeString).last)
        let snapshot = try JSONDecoder().decode(ClientStateMessage.self, from: bytes)
        #expect(snapshot.payload.available == false)
        #expect(snapshot.payload.player != nil)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let payload = try #require(object["payload"] as? [String: Any])
        #expect(payload["available"] as? Bool == false)
        #expect(snapshot.payload.visualizer?.types == [])
        #expect(snapshot.payload.visualizer?.rateMax == 30)
        #expect(snapshot.payload.visualizer?.spectrum == nil)
        await fixture.connection.shutdown()
    }

    @Test("failed visualizer preference publication restores the previous preference")
    func visualizerPreferenceRollsBackOnPublishFailure() async throws {
        let previous = try VisualizerStateObject(types: [.loudness], rateMax: 30)
        let fixture = try await makeEstablishedConnection(
            activeRoles: [.visualizerV1], roles: [.visualizerV1], initialVisualizerState: previous
        )
        await fixture.transport.setShouldFailOnSend(true)
        await #expect(throws: MockTransportError.simulatedFailure) {
            try await fixture.connection.setVisualizerPreference(VisualizerStateObject(types: [], rateMax: 30))
        }
        #expect(await fixture.connection.visualizerState == previous)
        await fixture.connection.shutdown()
    }

    @Test("controller sends preserve the shutdown handshake error")
    func controllerCommandAfterShutdownPreservesError() async throws {
        let fixture = try await makeEstablishedConnection(activeRoles: [.controllerV1], roles: [.controllerV1])
        await fixture.connection.shutdown()
        await #expect(throws: SendspinClientError.handshakeIncomplete) {
            try await fixture.connection.sendControllerCommand(ControllerCommand(command: .play))
        }
    }

    @Test("unavailable clients discard binaries while retaining streams and artwork accounting")
    func unavailableBinariesDropAndResume() async throws {
        let audio = AsyncStream<AudioChunk>.makeStream()
        let artwork = AsyncStream<ArtworkData>.makeStream()
        let visualizer = AsyncStream<VisualizerFrame>.makeStream()
        let artworkState = try ArtworkStateObject(channels: [ArtworkStateChannel(source: .album, format: .jpeg, width: 64, height: 64)])
        let requested = try VisualizerStateObject(types: [.loudness], rateMax: 30)
        let roles: Set<VersionedRole> = [.playerV1, .artworkV1, .visualizerV1]
        let fixture = try await makeEstablishedConnection(
            clock: StubClock(),
            activeRoles: roles,
            audioSink: audio.1,
            artworkSink: artwork.1,
            visualizerSink: visualizer.1,
            roles: roles,
            initialArtworkState: artworkState,
            initialVisualizerState: requested,
            scheduleNow: { 100 }
        )
        await fixture.connection.handleServerTime(
            ServerTimeMessage(payload: ServerTimePayload(clientTransmitted: 0, serverReceived: 0, serverTransmitted: 0)),
            clientReceived: 0
        )
        try await fixture.connection.sendClientState()
        await fixture.connection.handleStreamStart(StreamStartMessage(payload: StreamStartPayload(
            player: StreamStartPlayer(codec: AudioCodec.pcm.rawValue, sampleRate: 44_100, channels: 2, bitDepth: 16, codecHeader: nil),
            artwork: StreamStartArtwork(channels: [StreamArtworkChannelConfig(source: .album, format: .jpeg, width: 64, height: 64)]),
            visualizer: StreamStartVisualizer(types: [.loudness], rateMax: 30)
        )))
        try await fixture.connection.handleArtworkBinary(announce(size: 3))
        try await fixture.connection.handleArtworkBinary(part([1]))
        try await fixture.connection.setOperationalState(.externalSource)
        #expect(await fixture.connection.publishedAvailability == false)
        await fixture.connection.handleAudioChunk(binary(.audioChunk, bytes: [0, 0, 0, 0]))
        await fixture.connection.handleVisualizerBinary(binary(.visualizerLoudness, bytes: [0, 1]), arrival: 0)
        try await fixture.connection.handleArtworkBinary(part([2]))
        #expect(await fixture.connection.artworkTransfer?.received == 2)
        #expect(await fixture.connection.artworkTransfer?.deliver == false)
        try await fixture.connection.setOperationalState(.synchronized)
        #expect(await fixture.connection.publishedAvailability)
        try await fixture.connection.handleArtworkBinary(part([3]))
        #expect(await fixture.connection.artworkTransfer == nil)
        try await fixture.connection.handleArtworkBinary(announce(size: 1))
        try await fixture.connection.handleArtworkBinary(part([9]))
        await fixture.connection.handleAudioChunk(binary(.audioChunk, bytes: [1, 0, 1, 0]))
        await fixture.connection.handleVisualizerBinary(binary(.visualizerLoudness, bytes: [0, 9]), arrival: 0)
        #expect(await fixture.transport.disconnectCalled == false)
        #expect(await fixture.connection.playerStreamActive)
        #expect(await fixture.connection.artworkStreamActive)
        #expect(await fixture.connection.visualizerStreamActive)
        audio.1.finish()
        artwork.1.finish()
        visualizer.1.finish()
        var audios: [AudioChunk] = []
        for await value in audio.0 {
            audios.append(value)
        }
        var images: [ArtworkData] = []
        for await value in artwork.0 {
            images.append(value)
        }
        var frames: [VisualizerFrame] = []
        for await value in visualizer.0 {
            frames.append(value)
        }
        #expect(audios.map(\.data) == [Data([1, 0, 1, 0])])
        #expect(images.map(\.data) == [Data([9])])
        #expect(frames.map(\.data) == [Data([0, 9])])
        await fixture.connection.shutdown()
    }

    private func start(visualizer: StreamStartVisualizer) -> StreamStartMessage {
        StreamStartMessage(payload: StreamStartPayload(player: nil, artwork: nil, visualizer: visualizer))
    }

    private func binary(_ type: BinaryMessageType, bytes: [UInt8]) -> BinaryMessage {
        var data = Data([type.rawValue])
        var timestamp = Int64(10).bigEndian
        data.append(Data(bytes: &timestamp, count: MemoryLayout<Int64>.size))
        if type == .audioChunk {
            data.append(Data(repeating: 0, count: MemoryLayout<UInt32>.size))
        }
        data.append(contentsOf: bytes)
        return BinaryMessage(data: data)!
    }

    private func announce(size: UInt32) -> Data {
        var data = Data([BinaryMessageType.artworkChannel0.rawValue, ArtworkWireMessage.announceFlag])
        var timestamp = Int64(10).bigEndian
        var size = size.bigEndian
        data.append(Data(bytes: &timestamp, count: MemoryLayout<Int64>.size))
        data.append(Data(bytes: &size, count: MemoryLayout<UInt32>.size))
        return data
    }

    private func part(_ bytes: [UInt8]) -> Data {
        Data([BinaryMessageType.artworkChannel0.rawValue, 0] + bytes)
    }
}
