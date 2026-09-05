import Foundation
@testable import SendspinKit
import Testing

struct MinBufferDerivationTests {
    @Test("pre-sync chunks do not contribute arrival-delay samples")
    func preSyncChunksAreExcludedFromArrivalDelaySamples() async throws {
        let fixture = try await makeEstablishedConnection(clock: PreSyncClock(), minBufferMs: 1)
        await fixture.connection.handleStreamStart(validStreamStart())
        try await fixture.connection.sendClientState()
        for index in 0 ..< 16 {
            await fixture.connection.handleAudioChunk(
                audioMessage(timestamp: 100_000 + Int64(index), sendAhead: 10_000),
                arrival: 91_000 + Int64(index)
            )
        }
        #expect(await fixture.connection.arrivalDelaySamples.isEmpty)
        await fixture.connection.shutdown()
    }

    @Test("send_ahead saturation sentinels are excluded from arrival-delay samples")
    func sentinelSendAheadValuesAreExcluded() async throws {
        let fixture = try await makeEstablishedConnection(
            clock: MockClockSynchronizer(offset: 0, drift: 0),
            minBufferMs: 1
        )
        await fixture.connection.handleServerTime(
            ServerTimeMessage(payload: ServerTimePayload(clientTransmitted: 0, serverReceived: 0, serverTransmitted: 0)),
            clientReceived: 0
        )
        await fixture.connection.handleStreamStart(validStreamStart())
        try await fixture.connection.sendClientState()
        let server = fixture.server
        #expect(
            await waitUntil(timeout: .seconds(2)) { await clientStateCount(server) >= 2 },
            "The first-sync and explicit state publications must be observed before taking the baseline"
        )
        let baseline = await clientStateCount(server)

        for index in 0 ..< 16 {
            await fixture.connection.handleAudioChunk(
                audioMessage(timestamp: 100_000 + Int64(index), sendAhead: 10_000),
                arrival: 91_000 + Int64(index)
            )
        }
        for sendAhead in [UInt32(0), UInt32.max] {
            for index in 0 ..< 4 {
                await fixture.connection.handleAudioChunk(
                    audioMessage(timestamp: 100_000 + Int64(index), sendAhead: sendAhead),
                    arrival: 500_000_000 + Int64(index)
                )
            }
        }

        #expect(await fixture.connection.arrivalDelaySamples.count == 16)
        #expect(await fixture.connection.lastPublishedMinBufferMs == 1)
        #expect(await clientStateCount(fixture.server) == baseline, "Sentinels cannot trigger a debounced client/state publication")
        await fixture.connection.shutdown()
    }

    @Test("derived min_buffer publishes only after four stable observations and honors the configured floor")
    func derivedBufferDebouncesAndUsesFloor() async throws {
        let fixture = try await makeEstablishedConnection(
            clock: MockClockSynchronizer(offset: 0, drift: 0),
            minBufferMs: 7
        )
        await fixture.connection.handleServerTime(
            ServerTimeMessage(payload: ServerTimePayload(clientTransmitted: 0, serverReceived: 0, serverTransmitted: 0)),
            clientReceived: 0
        )
        await fixture.connection.handleStreamStart(validStreamStart())
        try await fixture.connection.sendClientState()
        let server = fixture.server
        #expect(
            await waitUntil(timeout: .seconds(2)) { await clientStateCount(server) >= 2 },
            "The first-sync and explicit state publications must be observed before taking the baseline"
        )
        let baseline = await clientStateCount(server)

        for index in 0 ..< 16 {
            await fixture.connection.handleAudioChunk(
                audioMessage(timestamp: 100_000 + Int64(index), sendAhead: 10_000),
                arrival: 91_000 + Int64(index)
            )
        }
        #expect(await fixture.connection.lastPublishedMinBufferMs == 7)
        #expect(await clientStateCount(fixture.server) == baseline)

        for index in 0 ..< 3 {
            await fixture.connection.handleAudioChunk(
                audioMessage(timestamp: 200_000 + Int64(index), sendAhead: 10_000),
                arrival: 203_000 + Int64(index)
            )
        }
        #expect(await fixture.connection.lastPublishedMinBufferMs == 7, "A changed estimate must not publish before four stable observations")
        #expect(await clientStateCount(server) == baseline)

        await fixture.connection.handleAudioChunk(
            audioMessage(timestamp: 200_003, sendAhead: 10_000),
            arrival: 203_003
        )
        #expect(
            await fixture.connection.lastPublishedMinBufferMs == 13,
            "The estimate is rounded up to milliseconds and published after four stable observations"
        )
        #expect(
            await waitUntil(timeout: .seconds(2)) { await clientStateCount(server) == baseline + 1 },
            "The debounced client/state publication must reach the server before decoding it"
        )
        let state = try #require(await lastClientState(server))
        #expect(state.payload.player?.minBufferMs == 13)
        await fixture.connection.shutdown()
    }

    @Test("fragmented audio is measured once after Noise reassembly")
    func fragmentedAudioArrivalMeasurementUsesCompletedMessage() async throws {
        let fixture = try await makeEstablishedConnection(clock: MockClockSynchronizer(offset: 0, drift: 0), minBufferMs: 1)
        await fixture.connection.handleServerTime(
            ServerTimeMessage(payload: ServerTimePayload(clientTransmitted: 0, serverReceived: 0, serverTransmitted: 0)),
            clientReceived: 0
        )
        await fixture.connection.handleStreamStart(validStreamStart())
        try await fixture.connection.sendClientState()

        var oversized = Data([BinaryMessageType.audioChunk.rawValue])
        var timestamp = Int64(1_000_000).bigEndian
        var sendAhead = UInt32(100_000).bigEndian
        oversized.append(Data(bytes: &timestamp, count: MemoryLayout<Int64>.size))
        oversized.append(Data(bytes: &sendAhead, count: MemoryLayout<UInt32>.size))
        oversized.append(Data(repeating: 0x7F, count: NoiseChannel.maxSinglePayload))
        try await fixture.server.sendEncrypted(oversized)
        let connection = fixture.connection
        #expect(
            await waitUntil(timeout: .seconds(2)) { await connection.arrivalDelaySamples.count == 1 },
            "arrival delay is measured once after fragmented reassembly"
        )
        await fixture.connection.shutdown()
    }

    private func validStreamStart() -> StreamStartMessage {
        StreamStartMessage(payload: StreamStartPayload(
            player: StreamStartPlayer(codec: AudioCodec.pcm.rawValue, sampleRate: 44_100, channels: 2, bitDepth: 16, codecHeader: nil),
            artwork: nil,
            visualizer: nil
        ))
    }

    private func audioMessage(timestamp: Int64, sendAhead: UInt32) -> BinaryMessage {
        var bytes = Data([BinaryMessageType.audioChunk.rawValue])
        var timestamp = timestamp.bigEndian
        var sendAhead = sendAhead.bigEndian
        bytes.append(Data(bytes: &timestamp, count: MemoryLayout<Int64>.size))
        bytes.append(Data(bytes: &sendAhead, count: MemoryLayout<UInt32>.size))
        bytes.append(Data([0x7F]))
        return BinaryMessage(data: bytes)!
    }

    private func clientStateCount(_ server: MockNoiseServer) async -> Int {
        await server.clientJSONMessages(ofType: ClientStateMessage.typeString).count
    }

    private func lastClientState(_ server: MockNoiseServer) async -> ClientStateMessage? {
        await server.clientJSONMessages(ofType: ClientStateMessage.typeString).last.flatMap {
            try? JSONDecoder().decode(ClientStateMessage.self, from: $0)
        }
    }
}

private actor PreSyncClock: ClockSyncProtocol {
    var hasSynced: Bool {
        false
    }

    func processServerTime(clientTransmitted _: Int64, serverReceived _: Int64, serverTransmitted _: Int64, clientReceived _: Int64) {}
    func serverTimeToLocal(_ serverTime: Int64) -> Int64 {
        serverTime
    }

    func localTimeToServer(_ localTime: Int64) -> Int64 {
        localTime
    }

    func snapshot() -> TimeFilterSnapshot? {
        nil
    }

    func diagnosticSnapshot() -> ClockSynchronizer.DiagnosticSnapshot? {
        nil
    }
}
