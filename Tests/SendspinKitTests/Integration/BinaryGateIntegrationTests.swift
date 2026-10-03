import Foundation
@testable import SendspinKit
import Testing

private actor BinaryGateValues<Element: Sendable> {
    private var values: [Element] = []
    var count: Int {
        values.count
    }

    var first: Element? {
        values.first
    }

    var all: [Element] {
        values
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
        let fixture = try await makeEstablishedConnection(clock: StubClock(), audioSink: audio.1)
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

        await fixture.connection.establishTestClockSync()
        try await fixture.connection.publishClientState()
        await fixture.connection.handleAudioChunk(frame)
        #expect(await waitUntil(timeout: .seconds(3)) { await values.count == 1 })
        consumer.cancel()
        await fixture.connection.shutdown()
        // Mutation claim: removing playerStateSent from the handler guard fails the pre-state count.
    }

    @Test("invalid visualizer configuration does not reject a valid player stream")
    func invalidVisualizerConfigurationContinuesPlayerHandling() async throws {
        let audio = AsyncStream<AudioChunk>.makeStream()
        let visualizer = AsyncStream<VisualizerFrame>.makeStream()
        let visualizerState = try VisualizerStateObject(types: [.loudness], rateMax: 30)
        let fixture = try await makeEstablishedConnection(
            clock: StubClock(), activeRoles: [.playerV1, .visualizerV1],
            audioSink: audio.1,
            visualizerSink: visualizer.1,
            roles: [.playerV1, .visualizerV1],
            initialVisualizerState: visualizerState
        )
        let audioEngine = fixture.connection.audioEngineForTesting
        let audioValues = BinaryGateValues<AudioChunk>()
        let visualizerValues = BinaryGateValues<VisualizerFrame>()
        let audioConsumer = Task {
            for await value in audio.0 {
                await audioValues.append(value)
            }
        }
        let visualizerConsumer = Task {
            for await value in visualizer.0 {
                await visualizerValues.append(value)
            }
        }
        await fixture.connection.handleStreamStart(StreamStartMessage(payload: StreamStartPayload(
            player: StreamStartPlayer(
                codec: AudioCodec.pcm.rawValue,
                sampleRate: 44_100,
                channels: 2,
                bitDepth: 16,
                codecHeader: nil
            ),
            artwork: nil,
            visualizer: StreamStartVisualizer(types: [.loudness], rateMax: 31)
        )))

        #expect(await fixture.connection.playerStreamActive)
        #expect(await fixture.connection.visualizerStreamActive == false)
        #expect(
            await waitUntil(timeout: .seconds(3)) {
                await audioEngine.appliedCommandKinds().contains(DataPlaneCommandKind.streamStart)
            },
            "A valid player payload must still reach the engine when visualizer setup is invalid"
        )
        await fixture.connection.establishTestClockSync()
        try await fixture.connection.publishClientState()
        let frame = try #require(BinaryMessage(data: visualizerFrame()))
        await fixture.connection.handleVisualizerBinary(frame, arrival: 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await visualizerValues.count == 0, "A rejected visualizer stream must keep its frame gate closed")

        let playerMessage = try #require(BinaryMessage(data: playerFrame()))
        await fixture.connection.handleAudioChunk(playerMessage)
        #expect(await waitUntil(timeout: .seconds(3)) { await audioValues.count == 1 })
        audioConsumer.cancel()
        visualizerConsumer.cancel()
        await fixture.connection.shutdown()
    }

    @Test("visualizer binary requires the visualizer state send")
    func visualizerBinaryIsDroppedBeforeStateAndDeliveredAfter() async throws {
        let visualizer = AsyncStream<VisualizerFrame>.makeStream()
        let clock = StubClock()
        let visualizerState = try VisualizerStateObject(types: [.loudness], rateMax: 30)
        let fixture = try await makeEstablishedConnection(
            clock: clock, activeRoles: [.visualizerV1], visualizerSink: visualizer.1, roles: [.visualizerV1],
            initialVisualizerState: visualizerState
        )
        let values = BinaryGateValues<VisualizerFrame>()
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
        await fixture.connection.handleVisualizerBinary(frame, arrival: 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await values.count == 0)

        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        await fixture.connection.handleServerTime(
            ServerTimeMessage(payload: ServerTimePayload(clientTransmitted: now, serverReceived: now, serverTransmitted: now)),
            clientReceived: now
        )
        try await fixture.connection.publishClientState()
        await fixture.connection.handleVisualizerBinary(frame, arrival: 0)
        #expect(await waitUntil(timeout: .seconds(3)) { await values.count == 1 })
        consumer.cancel()
        await fixture.connection.shutdown()
        // Mutation claim: removing visualizerStateSent from the handler guard fails the pre-state count.
    }

    @Test("valid visualizer binary shapes reach the visualizer stream")
    func validVisualizerTypesDeliverTheirDocumentedPayloadShapes() async throws {
        let visualizer = AsyncStream<VisualizerFrame>.makeStream()
        let spectrum = SpectrumConfiguration(nDispBins: 2, scale: .lin, fMin: 20, fMax: 20_000)
        let visualizerState = try VisualizerStateObject(
            types: [.loudness, .beat, .fPeak, .spectrum, .peak],
            rateMax: 30,
            spectrum: spectrum
        )
        let fixture = try await makeEstablishedConnection(
            clock: StubClock(),
            activeRoles: [.visualizerV1],
            visualizerSink: visualizer.1,
            roles: [.visualizerV1],
            initialVisualizerState: visualizerState
        )
        let values = BinaryGateValues<VisualizerFrame>()
        let consumer = Task {
            for await value in visualizer.0 {
                await values.append(value)
            }
        }

        await fixture.connection.handleStreamStart(StreamStartMessage(payload: StreamStartPayload(
            player: nil,
            artwork: nil,
            visualizer: StreamStartVisualizer(
                types: [.loudness, .beat, .fPeak, .spectrum, .peak],
                rateMax: 30,
                tracksDownbeats: true,
                spectrum: spectrum
            )
        )))
        try await fixture.connection.publishClientState()
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        await fixture.connection.handleServerTime(
            ServerTimeMessage(payload: ServerTimePayload(clientTransmitted: now, serverReceived: now, serverTransmitted: now)),
            clientReceived: now
        )

        let frames: [(BinaryMessageType, Data)] = [
            (.visualizerLoudness, Data([0x12, 0x34])),
            (.visualizerBeat, Data([0x01])),
            (.visualizerFPeak, Data([0x01, 0x00, 0x02, 0x00])),
            (.visualizerSpectrum, Data([0x00, 0x01, 0x00, 0x02])),
            (.visualizerPeak, Data([0x7F]))
        ]
        let expectedTypes: [VisualizerType] = [.loudness, .beat, .fPeak, .spectrum, .peak]
        for (index, frame) in frames.enumerated() {
            let message = try #require(BinaryMessage(data: visualizerFrame(type: frame.0, payload: frame.1, timestamp: 2_000_000 + Int64(index))))
            await fixture.connection.handleVisualizerBinary(message, arrival: 1_000_000)
        }

        #expect(await waitUntil(timeout: .seconds(3)) { await values.count == frames.count })
        #expect(await values.all.map(\.type) == expectedTypes)
        consumer.cancel()
        await fixture.connection.shutdown()
    }

    @Test("malformed visualizer payloads are dropped before the public stream")
    func malformedVisualizerPayloadDoesNotCrossTheEmissionBarrier() async throws {
        let visualizer = AsyncStream<VisualizerFrame>.makeStream()
        let state = try VisualizerStateObject(types: [.loudness], rateMax: 30)
        let fixture = try await makeEstablishedConnection(
            clock: StubClock(),
            activeRoles: [.visualizerV1],
            visualizerSink: visualizer.1,
            roles: [.visualizerV1],
            initialVisualizerState: state
        )
        await fixture.connection.handleStreamStart(StreamStartMessage(payload: StreamStartPayload(
            player: nil,
            artwork: nil,
            visualizer: StreamStartVisualizer()
        )))
        try await fixture.connection.publishClientState()
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        await fixture.connection.handleServerTime(
            ServerTimeMessage(payload: ServerTimePayload(clientTransmitted: now, serverReceived: now, serverTransmitted: now)),
            clientReceived: now
        )

        var iterator = visualizer.0.makeAsyncIterator()
        let valid = try #require(BinaryMessage(data: visualizerFrame(payload: Data([0x00, 0x01]), timestamp: 2_000_000)))
        await fixture.connection.handleVisualizerBinary(valid, arrival: 1_000_000)
        let emittedValidPayload = await iterator.next()
        #expect(emittedValidPayload?.data == Data([0x00, 0x01]))

        let malformed = try #require(BinaryMessage(data: visualizerFrame(payload: Data([0x01]), timestamp: 2_000_001)))
        await fixture.connection.handleVisualizerBinary(malformed, arrival: 1_000_000)
        let pendingRead = Task { await iterator.next() }
        visualizer.1.finish()
        #expect(await pendingRead.value == nil)
        await fixture.connection.shutdown()
    }

    @Test("stale visualizer frames are dropped using their arrival instant")
    func staleVisualizerFrameIsDroppedAtArrival() async throws {
        let visualizer = AsyncStream<VisualizerFrame>.makeStream()
        let clock = StubClock()
        let visualizerState = try VisualizerStateObject(types: [.loudness], rateMax: 30)
        let fixture = try await makeEstablishedConnection(
            clock: clock, activeRoles: [.visualizerV1], visualizerSink: visualizer.1, roles: [.visualizerV1],
            initialVisualizerState: visualizerState
        )
        let values = BinaryGateValues<VisualizerFrame>()
        let consumer = Task {
            for await value in visualizer.0 {
                await values.append(value)
            }
        }
        await fixture.connection.handleStreamStart(StreamStartMessage(payload: StreamStartPayload(
            player: nil, artwork: nil, visualizer: StreamStartVisualizer()
        )))
        try await fixture.connection.publishClientState()
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        await fixture.connection.handleServerTime(
            ServerTimeMessage(payload: ServerTimePayload(clientTransmitted: now, serverReceived: now, serverTransmitted: now)),
            clientReceived: now
        )

        let frame = try #require(BinaryMessage(data: visualizerFrame(timestamp: 2_000_000)))
        await fixture.connection.handleVisualizerBinary(frame, arrival: 2_000_000)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await values.count == 0)

        await fixture.connection.handleVisualizerBinary(frame, arrival: 1_000_000)
        #expect(await waitUntil(timeout: .seconds(3)) { await values.count == 1 })
        let value = try #require(await values.first)
        #expect(value.type == .loudness)
        consumer.cancel()
        await fixture.connection.shutdown()
    }

    @Test("visualizer frame validity changes at clear and end boundaries")
    func visualizerFramesAreInvalidatedByClearAndEnd() async throws {
        let visualizer = AsyncStream<VisualizerFrame>.makeStream()
        let clock = StubClock()
        let state = try VisualizerStateObject(types: [.loudness], rateMax: 30)
        let fixture = try await makeEstablishedConnection(
            clock: clock, activeRoles: [.visualizerV1], visualizerSink: visualizer.1, roles: [.visualizerV1],
            initialVisualizerState: state
        )
        await fixture.connection.handleStreamStart(StreamStartMessage(payload: StreamStartPayload(
            player: nil, artwork: nil, visualizer: StreamStartVisualizer()
        )))
        try await fixture.connection.publishClientState()
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        await fixture.connection.handleServerTime(
            ServerTimeMessage(payload: ServerTimePayload(clientTransmitted: now, serverReceived: now, serverTransmitted: now)),
            clientReceived: now
        )

        let frame = try #require(BinaryMessage(data: visualizerFrame(timestamp: 2_000_000)))
        await fixture.connection.handleVisualizerBinary(frame, arrival: 1_000_000)
        let consumer = Task { await visualizer.0.first(where: { _ in true }) }
        let beforeClear = try #require(await consumer.value)
        #expect(beforeClear.isValid)
        #expect(beforeClear.isValid)
        #expect(beforeClear.eligibilityForScheduling(at: PresentationInstant(rawMicroseconds: 1_000_000)))
        #expect(beforeClear.eligibilityForScheduling(at: PresentationInstant(rawMicroseconds: 2_000_000)) == false)

        await fixture.connection.handleStreamClear(StreamClearMessage(payload: StreamClearPayload(roles: ["visualizer"])))
        #expect(beforeClear.isValid == false)
        await fixture.connection.handleVisualizerBinary(frame, arrival: 1_000_000)
        let afterClear = try #require(await visualizer.0.first(where: { _ in true }))
        #expect(afterClear.isValid)

        await fixture.connection.handleStreamEnd(StreamEndMessage(payload: StreamEndPayload(roles: ["visualizer"])))
        #expect(afterClear.isValid == false)

        await fixture.connection.handleStreamStart(StreamStartMessage(payload: StreamStartPayload(
            player: nil, artwork: nil, visualizer: StreamStartVisualizer()
        )))
        try await fixture.connection.publishClientState()
        await fixture.connection.handleVisualizerBinary(frame, arrival: 1_000_000)
        let afterEnd = try #require(await visualizer.0.first(where: { _ in true }))
        await fixture.connection.shutdown()
        #expect(afterEnd.isValid == false)
    }

    @Test("role-changing activation resets the player binary gate")
    func roleChangingActivationRequiresFreshPlayerState() async throws {
        let audio = AsyncStream<AudioChunk>.makeStream()
        let fixture = try await makeEstablishedConnection(clock: StubClock(), audioSink: audio.1)
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
        await fixture.connection.establishTestClockSync()
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

    private func visualizerFrame(
        type: BinaryMessageType = .visualizerData,
        payload: Data = Data([0x00, 0x01]),
        timestamp: Int64 = 1_000_000
    ) -> Data {
        var data = Data([type.rawValue])
        var timestamp = timestamp.bigEndian
        data.append(Data(bytes: &timestamp, count: MemoryLayout<Int64>.size))
        data.append(payload)
        return data
    }
}
