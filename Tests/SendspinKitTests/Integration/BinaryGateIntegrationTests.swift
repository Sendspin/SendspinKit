import Foundation
@testable import SendspinKit
import Testing

private actor BinaryGateValues<Element: Sendable> {
    private var values: [Element] = []
    var count: Int {
        values.count
    }

    func append(_ value: Element) {
        values.append(value)
    }
}

@Suite("Binary state gates")
struct BinaryGateIntegrationTests {
    @Test("player binary requires the player state send")
    func playerBinaryIsDroppedBeforeStateAndDeliveredAfter() async throws {
        let audio = AsyncStream<AudioChunk>.makeStream()
        let fixture = try await makeEstablishedConnection(audioSink: audio.1)
        let values = BinaryGateValues<AudioChunk>()
        let consumer = Task {
            for await value in audio.0 {
                await values.append(value)
            }
        }
        await fixture.connection.handleStreamStart(StreamStartMessage(payload: StreamStartPayload(
            player: StreamStartPlayer(codec: AudioCodec.pcm.rawValue, sampleRate: 44_100, channels: 2, bitDepth: 16, codecHeader: nil),
            artwork: nil, visualizer: nil
        )))
        let frame = try #require(BinaryMessage(data: playerFrame()))
        await fixture.connection.handleAudioChunk(frame)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await values.count == 0)

        try await fixture.connection.publishClientState()
        await fixture.connection.handleAudioChunk(frame)
        #expect(await waitUntil(timeout: .seconds(3)) { await values.count == 1 })
        consumer.cancel()
        await fixture.connection.shutdown()
        // Mutation claim: removing playerStateSent from the handler guard fails the pre-state count.
    }

    @Test("visualizer binary requires the visualizer state send")
    func visualizerBinaryIsDroppedBeforeStateAndDeliveredAfter() async throws {
        let visualizer = AsyncStream<VisualizerData>.makeStream()
        let clock = StubClock()
        let visualizerState = try VisualizerStateObject(types: [.loudness], rateMax: 30)
        let fixture = try await makeEstablishedConnection(
            clock: clock, activeRoles: [.visualizerV1], visualizerSink: visualizer.1, roles: [.visualizerV1],
            initialVisualizerState: visualizerState
        )
        let values = BinaryGateValues<VisualizerData>()
        let consumer = Task {
            for await value in visualizer.0 {
                await values.append(value)
            }
        }
        await fixture.connection.handleStreamStart(StreamStartMessage(payload: StreamStartPayload(
            player: nil,
            artwork: nil,
            visualizer: StreamStartVisualizer()
        )))
        let frame = try #require(BinaryMessage(data: visualizerFrame()))
        await fixture.connection.handleVisualizerBinary(frame)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await values.count == 0)

        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        await fixture.connection.handleServerTime(
            ServerTimeMessage(payload: ServerTimePayload(clientTransmitted: now, serverReceived: now, serverTransmitted: now)),
            clientReceived: now
        )
        try await fixture.connection.publishClientState()
        await fixture.connection.handleVisualizerBinary(frame)
        #expect(await waitUntil(timeout: .seconds(3)) { await values.count == 1 })
        consumer.cancel()
        await fixture.connection.shutdown()
        // Mutation claim: removing visualizerStateSent from the handler guard fails the pre-state count.
    }

    @Test("role-changing activation resets the player binary gate")
    func roleChangingActivationRequiresFreshPlayerState() async throws {
        let audio = AsyncStream<AudioChunk>.makeStream()
        let fixture = try await makeEstablishedConnection(audioSink: audio.1)
        let values = BinaryGateValues<AudioChunk>()
        let consumer = Task {
            for await value in audio.0 {
                await values.append(value)
            }
        }
        try await fixture.connection.publishClientState()
        await fixture.connection.handleStreamStart(StreamStartMessage(payload: StreamStartPayload(
            player: StreamStartPlayer(codec: AudioCodec.pcm.rawValue, sampleRate: 44_100, channels: 2, bitDepth: 16, codecHeader: nil),
            artwork: nil, visualizer: nil
        )))
        let active = ServerActivateMessage(payload: ServerActivatePayload(activities: [.playback], activeRoles: [.playerV1]))
        await fixture.connection.handleServerActivate(active)
        #expect(await fixture.connection.playerStateSent)

        let roleChange = ServerActivateMessage(payload: ServerActivatePayload(activities: [], activeRoles: []))
        await fixture.connection.handleServerActivate(roleChange)
        #expect(await fixture.connection.playerStateSent == false)
        // The role is inactive, so even a stream-start-like frame cannot pass the reset gate.
        await fixture.connection.handleStreamStart(StreamStartMessage(payload: StreamStartPayload(
            player: StreamStartPlayer(codec: AudioCodec.pcm.rawValue, sampleRate: 44_100, channels: 2, bitDepth: 16, codecHeader: nil),
            artwork: nil, visualizer: nil
        )))
        try await fixture.connection.handleAudioChunk(#require(BinaryMessage(data: playerFrame())))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await values.count == 0)

        let reactivate = ServerActivateMessage(payload: ServerActivatePayload(activities: [.playback], activeRoles: [.playerV1]))
        await fixture.connection.handleServerActivate(reactivate)
        // The activation's fresh full state send reopens the binary gate.
        #expect(await fixture.connection.playerStateSent)
        await fixture.connection.handleStreamStart(StreamStartMessage(payload: StreamStartPayload(
            player: StreamStartPlayer(codec: AudioCodec.pcm.rawValue, sampleRate: 44_100, channels: 2, bitDepth: 16, codecHeader: nil),
            artwork: nil, visualizer: nil
        )))
        try await fixture.connection.handleAudioChunk(#require(BinaryMessage(data: playerFrame())))
        #expect(await waitUntil(timeout: .seconds(3)) { await values.count == 1 })
        consumer.cancel()
        await fixture.connection.shutdown()
        // Mutation claim: removing the rolesChanged reset makes the post-reactivation pre-state frame leak.
    }

    private func playerFrame() -> Data {
        var data = Data([BinaryMessageType.audioChunk.rawValue])
        var timestamp = Int64(1_000_000).bigEndian
        data.append(Data(bytes: &timestamp, count: MemoryLayout<Int64>.size))
        data.append(contentsOf: [0, 0, 0, 0])
        data.append(contentsOf: [0x7F, 0x7F])
        return data
    }

    private func visualizerFrame() -> Data {
        var data = Data([BinaryMessageType.visualizerData.rawValue])
        var timestamp = Int64(1_000_000).bigEndian
        data.append(Data(bytes: &timestamp, count: MemoryLayout<Int64>.size))
        data.append(contentsOf: [0xAB])
        return data
    }
}
