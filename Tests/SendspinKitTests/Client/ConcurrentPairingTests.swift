import Foundation
@testable import SendspinKit
import Testing

/// End-to-end coverage for a playback holder and one concurrently parked pairing side.
@MainActor
@Suite("Concurrent pairing", .timeLimit(.minutes(1)))
struct ConcurrentPairingTests {
    @Test("pairing side is admitted beside playback and emits its dynamic code without changing primary UI")
    func pairingSideRetainsPrimary() async throws {
        let session = try await makeSession()
        let primaryId = session.client.currentServerId
        let primaryConnection = session.client.connection
        try await session.primary.injectText(metadataStateJSON(title: "Primary Track"))
        #expect(await waitUntil { await MainActor.run { session.client.currentMetadata?.title == "Primary Track" } })
        let primaryMetadata = session.client.currentMetadata

        let codeTask = Task {
            await collectClientEvent(from: session.events) {
                if case let .pairingCodeChanged(snapshot) = $0, snapshot.code != nil {
                    return true
                }
                return false
            }
        }
        let side = try await admitPairingSide(to: session.client)
        _ = try await waitForClientJSON(side, type: ClientPairInitMessage.typeString)
        let nonceA = Base64URL.encode(Data(repeating: 0, count: 32))
        let pairInit = ServerPairInitMessage(payload: ServerPairInitPayload(nonceA: nonceA))
        try await side.sendJSON(#require(String(data: JSONEncoder().encode(pairInit), encoding: .utf8)))
        let code = await codeTask.value

        #expect(code != nil)
        #expect(session.client.connection === primaryConnection)
        #expect(session.client.pairingConnection != nil)
        #expect(session.client.currentServerId == primaryId)
        #expect(session.client.currentMetadata == primaryMetadata)
        #expect(session.client.currentActivities == [.playback])
        #expect(await side.disconnectCalled == false)

        await session.client.disconnect()
    }

    @Test("a second pairing side is rejected while the first side is parked")
    func secondPairingIsRejected() async throws {
        let session = try await makeSession()
        _ = try await admitPairingSide(to: session.client)
        let secondTransport = MockTransport()
        let second = MockNoiseServer(transport: secondTransport, psk: .sentinel)

        let accepted = Task {
            try? await session.client.acceptConnection(secondTransport)
        }
        try await second.beginAdmission(name: "Second Pairing")
        try await sendDynamicPairingActivation(to: second)
        _ = await accepted.value

        let abort = try await waitForClientJSON(second, type: PairAbortMessage.typeString)
        let decoded = try JSONDecoder().decode(PairAbortMessage.self, from: abort)
        #expect(decoded.payload.reason == .concurrentAttempt)
        #expect(await second.disconnectCalled)
        #expect(session.client.connection != nil)
        #expect(session.client.pairingConnection != nil)

        await session.client.disconnect()
    }

    @Test("playback activation promotes the pairing side at the equal playback rank")
    func pairingSidePromotesWithoutRehandshake() async throws {
        let session = try await makeSession()
        try await session.primary.injectText(metadataStateJSON(title: "Primary Track"))
        #expect(await waitUntil { await MainActor.run { session.client.currentMetadata?.title == "Primary Track" } })
        let side = try await admitPairingSide(to: session.client)
        let sideConnection = session.client.pairingConnection
        let primary = session.primary
        let primaryConnection = session.client.connection
        let primaryGoodbyesBefore = await primary.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).count
        let sideHelloCountBefore = await side.clientJSONMessages(ofType: ClientHelloMessage.typeString).count
        let sideHandshakeMessagesBefore = await side.clientJSONMessages(ofType: ClientInitMessage.typeString).count
        let audio = ConcurrentCollectedValues<AudioChunk>()
        let audioTask = Task {
            for await chunk in session.client.audioChunks {
                await audio.append(chunk)
                if await audio.count == 1 {
                    break
                }
            }
        }

        try await side.sendActivation(activities: [.playback], activeRoles: [.playerV1])

        #expect(await waitUntil(timeout: .seconds(3)) {
            await MainActor.run {
                session.client.connection === sideConnection && session.client.pairingConnection == nil
            }
        })
        #expect(session.client.connection !== primaryConnection)
        #expect(session.client.currentMetadata == nil)
        let sideServerId = await side.serverId
        #expect(session.client.currentServerId == sideServerId)
        #expect(await side.clientJSONMessages(ofType: ClientHelloMessage.typeString).count == sideHelloCountBefore)
        #expect(await side.clientJSONMessages(ofType: ClientInitMessage.typeString).count == sideHandshakeMessagesBefore)
        #expect(await primary.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).count == primaryGoodbyesBefore + 1)
        #expect(await sentGoodbyeReasons(from: primary).last == .anotherServer)
        #expect(await primary.disconnectCalled)

        try await side.injectText(metadataStateJSON(title: "Promoted Track"))
        #expect(await waitUntil { await MainActor.run { session.client.currentMetadata?.title == "Promoted Track" } })
        try await side.injectText(streamStartPCMJSON())
        try await establishClockSync(session.client, via: side)
        await side.injectBinary(audioChunkFrame(index: 1))
        #expect(await waitUntil(timeout: .seconds(3)) { await audio.count == 1 })
        #expect(await audio.all.first?.serverTimestamp == audioChunkTimestamp(index: 1))
        audioTask.cancel()

        await session.client.disconnect()
    }

    @Test("promotion cannot resurrect a parked side after disconnect during primary shutdown")
    func disconnectDuringPromotionTeardownDoesNotResurrectSide() async throws {
        let session = try await makeSession()
        let side = try await admitPairingSide(to: session.client)
        let primary = session.primary
        let connection = try #require(session.client.connection)
        try #require(await waitUntil { await connection.clockSyncTask != nil })
        await connection.clockSyncTask?.cancel()
        await connection.clockSyncTask?.value
        try #require(await waitUntil { await !connection.outboundInFlight })
        await primary.parkNextOutboundFrame()
        let promotion = Task {
            try await sideTransportActivation(from: side)
        }

        #expect(await waitUntil { await primary.isOutboundFrameParked })
        await session.client.disconnect(reason: .userRequest)
        await primary.releaseOutboundFrame()
        _ = try await promotion.value

        #expect(session.client.connection == nil)
        #expect(session.client.pairingConnection == nil)
        #expect(session.client.connectionState == .disconnected)
        #expect(await waitUntil { await side.disconnectCalled })
    }

    @Test("empty activation is rejected by the pairing side without affecting playback")
    func emptyActivationRejectsSide() async throws {
        let session = try await makeSession()
        let side = try await admitPairingSide(to: session.client)
        let primaryConnection = session.client.connection
        let primaryId = session.client.currentServerId
        let goodbyeTask = Task {
            try? await waitForClientJSON(side, type: ClientGoodbyeMessage.typeString)
        }

        try await side.sendActivation(activities: [], activeRoles: [])

        let goodbye = try #require(await goodbyeTask.value)
        let decoded = try JSONDecoder().decode(ClientGoodbyeMessage.self, from: goodbye)
        #expect(decoded.payload.reason == .concurrentAttempt)
        #expect(await side.disconnectCalled)
        #expect(await waitUntil { await MainActor.run { session.client.pairingConnection == nil } })
        #expect(session.client.connection === primaryConnection)
        #expect(session.client.currentServerId == primaryId)
        #expect(session.client.connectionState == .connected)

        await session.client.disconnect()
    }

    @Test("cancelPairing targets the parked side and leaves playback connected")
    func cancelTargetsPairingSide() async throws {
        let session = try await makeSession()
        let side = try await admitPairingSide(to: session.client)
        _ = try await waitForClientJSON(side, type: ClientPairInitMessage.typeString)
        let pairInit = ServerPairInitMessage(payload: ServerPairInitPayload(nonceA: Base64URL.encode(Data(repeating: 0, count: 32))))
        try await side.sendJSON(#require(String(data: JSONEncoder().encode(pairInit), encoding: .utf8)))
        let code = await collectClientEvent(from: session.events) {
            if case let .pairingCodeChanged(snapshot) = $0, snapshot.code != nil {
                return true
            }
            return false
        }
        _ = try #require(code)

        try await session.client.cancelPairing(attemptID: #require(await MainActor.run { session.client.currentPairing?.id }))

        let abort = try await waitForClientJSON(side, type: PairAbortMessage.typeString)
        let decoded = try JSONDecoder().decode(PairAbortMessage.self, from: abort)
        #expect(decoded.payload.reason == .userCancelled)
        #expect(session.client.connection === session.primaryConnection)
        #expect(session.client.pairingConnection != nil)
        #expect(await side.disconnectCalled == false)
        #expect(session.client.connectionState == .connected)

        await session.client.disconnect()
    }

    @Test("pairing-side transport failure does not disconnect playback")
    func sideFailureDoesNotDisconnectPrimary() async throws {
        let session = try await makeSession()
        let side = try await admitPairingSide(to: session.client)
        let primaryConnection = session.client.connection
        let primaryId = session.client.currentServerId

        await side.simulateClose(.failed(description: "pairing side failed"))

        #expect(await waitUntil { await MainActor.run { session.client.pairingConnection == nil } })
        #expect(session.client.connection === primaryConnection)
        #expect(session.client.currentServerId == primaryId)
        #expect(session.client.connectionState == .connected)
        #expect(await session.primary.disconnectCalled == false)

        await session.client.disconnect()
    }

    @Test("disconnecting the primary closes both the primary and parked pairing side")
    func primaryDisconnectClosesBoth() async throws {
        let session = try await makeSession()
        let side = try await admitPairingSide(to: session.client)

        await session.primary.simulateClose(.peerClosed(code: nil))

        #expect(await waitUntil { await MainActor.run {
            session.client.connection == nil && session.client.pairingConnection == nil
        } })
        #expect(session.client.connectionState == .disconnected)
        #expect(await side.disconnectCalled)
    }

    private struct Session {
        let client: SendspinClient
        let primary: MockNoiseServer
        let events: AsyncStream<ClientEvent>
        let primaryConnection: SendspinConnection?
    }

    private func makeSession() async throws -> Session {
        let pairingPsk = Psk.generate()
        let store = InMemoryPairingRecordStore(pairingPsk: pairingPsk)
        let client = try SendspinClient(
            identity: .generate(),
            name: "Concurrent Pairing Client",
            roles: [.playerV1, .controllerV1],
            playerConfig: PlayerConfiguration(
                bufferCapacity: 65_536,
                supportedFormats: [AudioFormatSpec(codec: .pcm, channels: 1, sampleRate: 8_000, bitDepth: 16)],
                volumeMode: .none,
                emitRawAudioEvents: true
            ),
            pairing: PairingConfiguration(
                pairingPsk: pairingPsk,
                store: store,
                enabled: false,
                dynamicPairingCodeEnabled: true
            ),
            audioOutputCapabilityProvider: makeInertAudioOutputCapabilityProvider(),
            handshakeTimeout: .seconds(3),
            pairingAttemptTimeout: .seconds(30),
            pairingWindowLifetime: .seconds(30),
            audioOutputFactory: { _, _ in NoOpAudioOutput() }
        )
        let events = client.events()
        let primary = try await connectClient(client, activeRoles: [.playerV1, .controllerV1], activities: [.playback])
        let primaryConnection = client.connection
        return Session(client: client, primary: primary, events: events, primaryConnection: primaryConnection)
    }

    private func admitPairingSide(to client: SendspinClient) async throws -> MockNoiseServer {
        let transport = MockTransport()
        let side = MockNoiseServer(transport: transport, psk: .sentinel)
        async let accepted: Void = client.acceptConnection(transport)
        try await side.beginAdmission(name: "Pairing Side")
        try await sendDynamicPairingActivation(to: side)
        try await accepted
        #expect(await waitUntil { await MainActor.run { client.pairingConnection != nil } })
        return side
    }
}

private func sideTransportActivation(from side: MockNoiseServer) async throws {
    try await side.sendActivation(activities: [.playback], activeRoles: [.playerV1])
}

private func sendDynamicPairingActivation(to server: MockNoiseServer) async throws {
    let activation = ServerActivateMessage(
        payload: ServerActivatePayload(
            activities: [.pairing],
            activeRoles: [],
            pairing: PairingDirective(method: PairMethod.dynamicPairingCode, format: PairingCodeFormat.digits.rawValue)
        )
    )
    let data = try JSONEncoder().encode(activation)
    try await server.sendJSON(#require(String(data: data, encoding: .utf8)))
}

private func waitForClientJSON(_ server: MockNoiseServer, type: String) async throws -> Data {
    #expect(await waitUntil(timeout: .seconds(3)) {
        await server.clientJSONMessages(ofType: type).count >= 1
    })
    guard let message = await server.clientJSONMessages(ofType: type).last else {
        throw ConcurrentPairingTestError.missingMessage(type)
    }
    return message
}

private func metadataStateJSON(title: String) throws -> String {
    let message = ServerStateMessage(payload: ServerStatePayload(
        metadata: ServerMetadataState(title: .value(title))
    ))
    return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
}

private func streamStartPCMJSON() throws -> String {
    let message = StreamStartMessage(payload: StreamStartPayload(
        player: StreamStartPlayer(codec: AudioCodec.pcm.rawValue, sampleRate: 8_000, channels: 1, bitDepth: 16, codecHeader: nil),
        artwork: nil,
        visualizer: nil
    ))
    return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
}

private func audioChunkTimestamp(index: Int, baseTimestamp: Int64 = 1_000_000) -> Int64 {
    baseTimestamp + Int64(index) * 25_000
}

private func audioChunkFrame(index: Int, baseTimestamp: Int64 = 1_000_000) -> Data {
    var frame = Data([BinaryMessageType.audioChunk.rawValue])
    var timestamp = audioChunkTimestamp(index: index, baseTimestamp: baseTimestamp).bigEndian
    frame.append(Data(bytes: &timestamp, count: MemoryLayout<Int64>.size))
    frame.append(contentsOf: [0, 0, 0, 0])
    frame.append(Data(repeating: 0x7F, count: 400))
    return frame
}

private func sentGoodbyeReasons(from server: MockNoiseServer) async -> [GoodbyeReason] {
    await server.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).compactMap {
        try? JSONDecoder().decode(ClientGoodbyeMessage.self, from: $0).payload.reason
    }
}

private actor ConcurrentCollectedValues<Element: Sendable> {
    private var values: [Element] = []

    var count: Int {
        values.count
    }

    var all: [Element] {
        values
    }

    func append(_ value: Element) {
        values.append(value)
    }
}

private enum ConcurrentPairingTestError: Error {
    case missingMessage(String)
}
