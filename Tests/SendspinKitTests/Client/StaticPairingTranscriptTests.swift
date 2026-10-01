import CryptoKit
import Foundation
@testable import SendspinKit
import Testing

private struct StaticFixtureResource: Decodable {
    let staticTranscript: StaticFixture

    enum CodingKeys: String, CodingKey { case staticTranscript = "static_transcript" }
}

private struct StaticFixture: Decodable {
    let provenance: String
    let handshakeHash: String
    let counter: UInt32
    let sid: String
    let code: String
    let scalarA: String
    let scalarB: String
    let generator: String
    let pakeMsg1: String
    let pakeMsg2: String
    let isk: String
    let serverKc: String
    let clientKc: String
    let wrappedPsk: String

    enum CodingKeys: String, CodingKey {
        case provenance
        case handshakeHash = "handshake_hash"
        case counter
        case sid
        case code
        case scalarA = "scalar_A"
        case scalarB = "scalar_B"
        case generator
        case pakeMsg1 = "pake_msg_1"
        case pakeMsg2 = "pake_msg_2"
        case isk
        case serverKc = "server_kc"
        case clientKc = "client_kc"
        case wrappedPsk = "wrapped_psk"
    }
}

private enum StaticTestError: Error { case missingMessage(String) }

private func staticFixture() throws -> StaticFixture {
    let url = try #require(Bundle.module.url(
        forResource: "cpace-mcf-known-answer",
        withExtension: "json",
        subdirectory: "Resources"
    ))
    return try JSONDecoder().decode(StaticFixtureResource.self, from: Data(contentsOf: url)).staticTranscript
}

private func pairingRecords(_ store: any PairingRecordStore) async -> [PairingRecord] {
    do {
        return try await store.listRecords()
    } catch {
        Issue.record("Pairing record listing failed: \(error)")
        return []
    }
}

private struct StaticTestSession {
    let client: SendspinClient
    let server: MockNoiseServer
    let store: any PairingRecordStore
    let events: AsyncStream<ClientEvent>
}

@MainActor
private func makeStaticTestSession(
    store: (any PairingRecordStore)? = nil,
    primary: Bool = false,
    attemptTimeout: Duration = .seconds(120),
    windowLifetime: Duration = .seconds(300),
    pairingHandshakeHashOverride: Data? = nil,
    pairingScalarBOverride: Data? = nil
) async throws -> StaticTestSession {
    let pairingPsk = Psk.generate()
    let resolvedStore: any PairingRecordStore = store ?? InMemoryPairingRecordStore(pairingPsk: pairingPsk)
    let client = try SendspinClient(
        identity: .generate(),
        name: "Static Pairing Test Client",
        roles: primary ? [.playerV1, .controllerV1] : [],
        playerConfig: primary ? PlayerConfiguration(
            bufferCapacity: 65_536,
            supportedFormats: [AudioFormatSpec(codec: .pcm, channels: 1, sampleRate: 8_000, bitDepth: 16)],
            volumeMode: .none,
            emitRawAudioEvents: true
        ) : nil,
        pairing: PairingConfiguration(
            pairingPsk: pairingPsk,
            store: resolvedStore,
            enabled: false,
            staticPairingCode: "12345678",
            staticPairingCodeEnabled: true
        ),
        audioOutputCapabilityProvider: AudioOutputCapabilityService(),
        pairingAttemptTimeout: attemptTimeout,
        pairingWindowLifetime: windowLifetime,
        pairingHandshakeHashOverride: pairingHandshakeHashOverride,
        pairingScalarBOverride: pairingScalarBOverride
    )
    let transport = MockTransport()
    let server = MockNoiseServer(transport: transport, psk: .sentinel)
    let events = client.events()
    async let accepted: Void = client.acceptConnection(transport)
    try await server.establishSession(
        activities: primary ? [.playback] : [],
        activeRoles: primary ? [.playerV1, .controllerV1] : []
    )
    try await accepted
    #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })
    if primary {
        let sideTransport = MockTransport()
        let side = MockNoiseServer(transport: sideTransport, psk: .sentinel)
        async let sideAccepted: Void = client.acceptConnection(sideTransport)
        try await side.beginAdmission(name: "Static Pairing Side")
        try await activateStatic(side)
        try await sideAccepted
        return StaticTestSession(client: client, server: side, store: resolvedStore, events: events)
    }
    return StaticTestSession(client: client, server: server, store: resolvedStore, events: events)
}

private func activateStatic(_ server: MockNoiseServer) async throws {
    let activation = ServerActivateMessage(payload: ServerActivatePayload(
        activities: [.pairing],
        activeRoles: [],
        pairing: PairingDirective(method: PairMethod.staticPairingCode)
    ))
    let data = try JSONEncoder().encode(activation)
    let text = try #require(String(data: data, encoding: .utf8))
    try await server.sendJSON(text)
}

private func waitForStaticClientMessage(
    _ server: MockNoiseServer,
    type: String,
    count: Int = 1
) async throws -> Data {
    #expect(await waitUntil(timeout: .seconds(3)) {
        await server.clientJSONMessages(ofType: type).count >= count
    })
    guard let message = await server.clientJSONMessages(ofType: type).last else {
        throw StaticTestError.missingMessage(type)
    }
    return message
}

@MainActor
private func pairingWireBarrier(_ session: StaticTestSession) async throws {
    let marker = UUID().uuidString
    try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(GroupUpdateMessage(
        payload: GroupUpdatePayload(playbackState: .stopped, groupId: marker, groupName: marker)
    )), encoding: .utf8)))
    #expect(await waitUntil { await MainActor.run { session.client.currentGroup?.groupId == marker } })
}

private func pairingTypes(_ server: MockNoiseServer) async -> [String] {
    await server.decryptedMessages.compactMap { message in
        guard message.first == NoiseFrameType.json else { return nil }
        return SendspinEncoding.messageType(of: Data(message.dropFirst()))
    }
}

private func staticServerTranscript(_ session: StaticTestSession, operatorOpen: Bool = false) async throws -> (Data, Data) {
    let fixture = try staticFixture()
    let initData: Data
    if operatorOpen {
        let attemptID = try #require(await MainActor.run { session.client.currentPairing?.id })
        try await session.client.openPairingWindow(for: attemptID)
        initData = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString)
    } else {
        initData = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString)
    }
    let initMessage = try JSONDecoder().decode(ClientPairInitMessage.self, from: initData)
    #expect(initMessage.payload.pairingIndex == fixture.counter)
    #expect(initMessage.payload.commitB == nil)

    let sid = dataFromHex(fixture.sid)
    let cpace = try CPace(
        role: .initiator,
        prs: Data(fixture.code.utf8),
        sid: sid,
        scalarOverride: dataFromHex(fixture.scalarA)
    )
    #expect(cpace.publicShare == dataFromHex(fixture.pakeMsg1))
    try await session.server.sendJSON(String(data: JSONEncoder().encode(ServerPairAuthMessage(
        payload: ServerPairAuthPayload(pakeMsg1: Base64URL.encode(cpace.publicShare))
    )), encoding: .utf8)!)
    let clientAuthData = try await waitForStaticClientMessage(session.server, type: ClientPairAuthMessage.typeString)
    let clientAuth = try JSONDecoder().decode(ClientPairAuthMessage.self, from: clientAuthData)
    #expect(clientAuth.payload.pakeMsg2 == Base64URL.encode(dataFromHex(fixture.pakeMsg2)))
    let clientShare = try #require(Base64URL.decode(clientAuth.payload.pakeMsg2, count: 32))
    let secrets = try cpace.derive(remoteShare: clientShare)
    #expect(secrets.isk == dataFromHex(fixture.isk))
    #expect(CPaceX25519.mcfTag(
        isk: secrets.isk,
        sid: sid,
        share: cpace.publicShare,
        associatedData: CPaceX25519.defaultInitiatorAD
    ) == dataFromHex(fixture.serverKc))

    try await session.server.sendJSON(String(data: JSONEncoder().encode(ServerPairConfirmMessage(
        payload: ServerPairConfirmPayload(serverKc: Base64URL.encode(dataFromHex(fixture.serverKc)))
    )), encoding: .utf8)!)
    let confirmData = try await waitForStaticClientMessage(session.server, type: ClientPairConfirmMessage.typeString)
    let finalizeData = try await waitForStaticClientMessage(session.server, type: ClientPairFinalizeMessage.typeString)
    return (confirmData, finalizeData)
}

@MainActor
@Suite("Static pairing windows", .timeLimit(.minutes(1)))
struct StaticPairingWindowTests {
    @Test("malformed pairing payload is ignored during client abort discard")
    func malformedPairingFrameDuringDiscardIsIgnored() async throws {
        let session = try await makeStaticTestSession()
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        let id = try #require(session.client.currentPairing?.id)
        try await session.client.cancelPairing(attemptID: id)
        _ = try await waitForStaticClientMessage(session.server, type: PairAbortMessage.typeString)
        try await session.server.sendJSON("{\"type\":\"\(ServerPairAuthMessage.typeString)\",\"payload\":\"garbage\"}")
        try await pairingWireBarrier(session)
        #expect(session.client.connectionState == .connected)
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).count == 1)
        #expect(await session.server.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).isEmpty)
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString, count: 2)
        #expect(session.client.connectionState == .connected)
        await session.client.disconnect()
    }

    @Test("idle finalize closes without an application response")
    func idleFinalizeClosesSilently() async throws {
        let session = try await makeStaticTestSession()
        _ = try await waitForStaticClientMessage(session.server, type: ClientHelloMessage.typeString)
        try await session.server.sendJSON("{\"type\":\"\(ServerPairFinalizeMessage.typeString)\",\"payload\":{}}")
        #expect(await waitUntil { await MainActor.run { session.client.connectionState == .disconnected } })
        let outboundPairingTypes: Set<String> = [
            ClientPairPendingMessage.typeString, ClientPairInitMessage.typeString,
            ClientPairAuthMessage.typeString, ClientPairRetryMessage.typeString,
            ClientPairConfirmMessage.typeString, ClientPairFinalizeMessage.typeString, PairAbortMessage.typeString
        ]
        #expect(await pairingTypes(session.server).filter { outboundPairingTypes.contains($0) }.isEmpty)
        #expect(await session.server.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).isEmpty)
        await session.client.disconnect()
    }

    @Test("server abort does not authorize later pairing messages")
    func serverAbortThenAuthClosesSilently() async throws {
        let fixture = try staticFixture()
        let session = try await makeStaticTestSession()
        let connection = try #require(session.client.connection)
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(PairAbortMessage(
            payload: PairAbortPayload(reason: .userCancelled)
        )), encoding: .utf8)))
        #expect(await waitUntil { await connection.pairingAttemptID == nil })
        let before = await pairingTypes(session.server)
        try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(ServerPairAuthMessage(
            payload: ServerPairAuthPayload(pakeMsg1: Base64URL.encode(dataFromHex(fixture.pakeMsg1)))
        )), encoding: .utf8)))
        #expect(await waitUntil { await MainActor.run { session.client.connectionState == .disconnected } })
        #expect(await pairingTypes(session.server) == before)
        await session.client.disconnect()
    }

    @Test("method rejection discards in-flight messages until activation")
    func methodNotSupportedAbortDiscardsLateServerMessages() async throws {
        let session = try await makeStaticTestSession()
        let connection = try #require(session.client.connection)
        try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(ServerActivateMessage(
            payload: ServerActivatePayload(
                activities: [.pairing],
                activeRoles: [],
                pairing: PairingDirective(method: PairMethod.dynamicPairingCode, format: PairingCodeFormat.digits.rawValue)
            )
        )), encoding: .utf8)))
        _ = try await waitForStaticClientMessage(session.server, type: PairAbortMessage.typeString)
        try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(ServerPairInitMessage(
            payload: ServerPairInitPayload(nonceA: Base64URL.encode(Psk.generate().bytes))
        )), encoding: .utf8)))
        try await pairingWireBarrier(session)
        #expect(await connection.discardingPairingMessages)
        #expect(session.client.connectionState == .connected)
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).count == 1)
        #expect(await session.server.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).isEmpty)
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        #expect(await !(connection.discardingPairingMessages))
        await session.client.disconnect()
    }

    @Test("late abort after client cancellation has no effect")
    func lateAbortAfterClientEndedIsNoOp() async throws {
        let session = try await makeStaticTestSession()
        let connection = try #require(session.client.connection)
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        let id = try #require(await connection.pairingAttemptID)
        try await session.client.cancelPairing(attemptID: id)
        _ = try await waitForStaticClientMessage(session.server, type: PairAbortMessage.typeString)
        try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(PairAbortMessage(
            payload: PairAbortPayload(reason: .userCancelled)
        )), encoding: .utf8)))
        try await pairingWireBarrier(session)
        #expect(await connection.pairingAttemptID == nil)
        #expect(await connection.discardingPairingMessages)
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).count == 1)
        #expect(await session.server.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).isEmpty)
        #expect(session.client.connectionState == .connected)
        await session.client.disconnect()
    }

    @Test("operator can close a surviving window by its published identity")
    func cancelSurvivingWindowAfterTimeout() async throws {
        let session = try await makeStaticTestSession()
        let connection = try #require(session.client.connection)
        let id = try #require(session.client.currentPairing?.id)
        try await session.client.openPairingWindow(for: id)
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString)
        await connection.pairingAttemptTimedOut(attemptID: connection.pairingAttemptID)
        #expect(await connection.pairingWindowOpen)
        let windowID = try #require(session.client.pairingWindow?.attemptID)
        try await session.client.cancelPairing(attemptID: windowID)
        #expect(await !(connection.pairingWindowOpen))
        #expect(await waitUntil { await MainActor.run { session.client.pairingWindow == nil } })
        await session.client.disconnect()
    }

    @Test("side drop clears only the side-owned window", arguments: [false, true])
    func pairingSideDropClearsWindow(primaryWindow: Bool) async throws {
        let session = try await makeStaticTestSession(primary: true)
        let side = try #require(session.client.pairingConnection)
        let owner = try #require(primaryWindow ? session.client.connection : side)
        if primaryWindow {
            await owner.admitPairingAttempt()
        }
        let id = try #require(await owner.pairingAttemptID)
        try await session.client.openPairingWindow(for: id)
        #expect(await waitUntil { await MainActor.run { session.client.pairingWindow?.attemptID == id } })
        let window = session.client.pairingWindow
        session.client.dropPairingConnection(side)
        #expect(session.client.pairingWindow == (primaryWindow ? window : nil))
        #expect(session.client.connectionState == .connected)
        await session.client.disconnect()
    }

    @Test("valid auth on a fresh idle session closes silently")
    func freshIdleAuthClosesSilently() async throws {
        let fixture = try staticFixture()
        let session = try await makeStaticTestSession()
        try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(ServerPairAuthMessage(
            payload: ServerPairAuthPayload(pakeMsg1: Base64URL.encode(dataFromHex(fixture.pakeMsg1)))
        )), encoding: .utf8)))
        #expect(await waitUntil { await MainActor.run { session.client.connectionState == .disconnected } })
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).isEmpty)
        #expect(await session.server.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).isEmpty)
        await session.client.disconnect()
    }

    @Test("window expiry leaves its active attempt running")
    func lifetimeExpiryPreservesActiveAttempt() async throws {
        let session = try await makeStaticTestSession(windowLifetime: .milliseconds(100))
        let connection = try #require(session.client.connection)
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        let id = try #require(await connection.pairingAttemptID)
        try await session.client.openPairingWindow(for: id)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString)
        #expect(await waitUntil { await !(connection.pairingWindowOpen) })
        #expect(await connection.pairingAttemptID == id)
        #expect(await connection.staticPairingAttempt?.cpace != nil)
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).isEmpty)
        await session.client.disconnect()
    }

    @Test("timeout and server cancellation preserve the connection window")
    func windowSurvivesTimeoutAndServerCancellation() async throws {
        let session = try await makeStaticTestSession()
        let connection = try #require(session.client.connection)
        let reservedID = try #require(session.client.currentPairing?.id)
        try await session.client.openPairingWindow(for: reservedID)
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString)
        let firstID = try #require(await connection.pairingAttemptID)
        await connection.pairingAttemptTimedOut(attemptID: firstID)
        #expect(await connection.pairingWindowOpen)
        #expect(session.client.pairingWindow != nil)
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString, count: 2)
        try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(PairAbortMessage(
            payload: PairAbortPayload(reason: .userCancelled)
        )), encoding: .utf8)))
        #expect(await waitUntil { await connection.staticPairingAttempt == nil })
        #expect(await connection.pairingWindowOpen)
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString, count: 3)
        let currentID = try #require(await connection.pairingAttemptID)
        try await session.client.cancelPairing(attemptID: currentID)
        #expect(await !(connection.pairingWindowOpen))
        await session.client.disconnect()
    }

    @Test("supersession replaces CPace and pending PSK while preserving the window")
    func supersedingActivationStartsFreshAttempt() async throws {
        let fixture = try staticFixture()
        let session = try await makeStaticTestSession(
            pairingHandshakeHashOverride: dataFromHex(fixture.handshakeHash),
            pairingScalarBOverride: dataFromHex(fixture.scalarB)
        )
        let connection = try #require(session.client.connection)
        let reservedID = try #require(session.client.currentPairing?.id)
        try await session.client.openPairingWindow(for: reservedID)
        try await activateStatic(session.server)
        _ = try await staticServerTranscript(session)
        #expect(await connection.pendingPairingPsk != nil)
        _ = try await session.store.reserveDynamicPairingRound(limit: dynamicPairingRoundLimit)
        let budget = try await session.store.dynamicPairingRoundCount()
        let oldID = try #require(await connection.pairingAttemptID)
        let oldTask = try #require(await connection.pairingAttemptTask)
        try await activateStatic(session.server)
        let data = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString, count: 2)
        let message = try JSONDecoder().decode(ClientPairInitMessage.self, from: data)
        #expect(message.payload.pairingIndex == fixture.counter + 1)
        #expect(await connection.pairingAttemptID != oldID)
        #expect(oldTask.isCancelled)
        #expect(await connection.staticPairingAttempt?.sid == CPaceSessionIdentifier.make(
            handshakeHash: dataFromHex(fixture.handshakeHash), counter: fixture.counter + 1, round: 1
        ))
        #expect(await connection.staticPairingAttempt?.serverShare == nil)
        #expect(await connection.pendingPairingPsk == nil)
        #expect(await pairingRecords(session.store).isEmpty)
        #expect(try await session.store.dynamicPairingRoundCount() == budget)
        #expect(await connection.pairingWindowOpen)
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).isEmpty)
        #expect(session.client.connectionState == .connected)
        try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(ServerActivateMessage(
            payload: ServerActivatePayload(activities: [], activeRoles: [])
        )), encoding: .utf8)))
        #expect(await waitUntil { await connection.staticPairingAttempt == nil })
        #expect(await connection.pairingWindowOpen)
        #expect(await connection.pairingAttemptID == nil)
        #expect(await waitUntil { await MainActor.run { session.client.currentPairing == nil } })
        #expect(await collectClientEvent(from: session.events) {
            if case let .pairingAttemptSuperseded(id) = $0 {
                return id == oldID
            }
            return false
        } != nil)
        await session.client.disconnect()
    }

    @Test("the fifth failed confirmation closes the static window")
    func fifthFailedConfirmationClosesWindow() async throws {
        let fixture = try staticFixture()
        let hash = dataFromHex(fixture.handshakeHash)
        let session = try await makeStaticTestSession(pairingHandshakeHashOverride: hash)
        let connection = try #require(session.client.connection)
        let reservedID = try #require(session.client.currentPairing?.id)
        try await session.client.openPairingWindow(for: reservedID)
        for index in 1 ... staticPairingWindowFailureLimit {
            try await activateStatic(session.server)
            _ = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString, count: index)
            let cpace = try CPace(role: .initiator, prs: Data(fixture.code.utf8), sid: CPaceSessionIdentifier.make(
                handshakeHash: hash, counter: UInt32(index), round: 1
            ))
            try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(ServerPairAuthMessage(
                payload: ServerPairAuthPayload(pakeMsg1: Base64URL.encode(cpace.publicShare))
            )), encoding: .utf8)))
            _ = try await waitForStaticClientMessage(session.server, type: ClientPairAuthMessage.typeString, count: index)
            try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(ServerPairConfirmMessage(
                payload: ServerPairConfirmPayload(serverKc: Base64URL.encode(Data(repeating: 0, count: dataFromHex(fixture.serverKc).count)))
            )), encoding: .utf8)))
            _ = try await waitForStaticClientMessage(session.server, type: PairAbortMessage.typeString, count: index)
            #expect(await connection.pairingWindowOpen == (index < staticPairingWindowFailureLimit))
        }
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        #expect(await session.server.clientJSONMessages(ofType: ClientPairInitMessage.typeString).count == staticPairingWindowFailureLimit)
        await session.client.disconnect()
    }

    @Test("idle auth closes silently outside the client abort discard interval")
    func idleAuthAndAbortDiscard() async throws {
        let fixture = try staticFixture()
        let session = try await makeStaticTestSession()
        let connection = try #require(session.client.connection)
        let auth = ServerPairAuthMessage(payload: ServerPairAuthPayload(pakeMsg1: Base64URL.encode(dataFromHex(fixture.pakeMsg1))))
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        let id = try #require(await connection.pairingAttemptID)
        try await session.client.cancelPairing(attemptID: id)
        _ = try await waitForStaticClientMessage(session.server, type: PairAbortMessage.typeString)
        #expect(await waitUntil { await connection.discardingPairingMessages })
        try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(auth), encoding: .utf8)))
        try await pairingWireBarrier(session)
        #expect(session.client.connectionState == .connected)
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).count == 1)
        #expect(await session.server.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).isEmpty)
        try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(ServerActivateMessage(
            payload: ServerActivatePayload(activities: [], activeRoles: [])
        )), encoding: .utf8)))
        #expect(await waitUntil { await !(connection.discardingPairingMessages) })
        try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(auth), encoding: .utf8)))
        #expect(await waitUntil { await MainActor.run { session.client.connectionState == .disconnected } })
        #expect(await session.server.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).isEmpty)
        await session.client.disconnect()
    }

    @Test("static attempt is pending until the window opens, without starting its timeout")
    func staticAttemptWaitsForWindow() async throws {
        let session = try await makeStaticTestSession(attemptTimeout: .milliseconds(100))
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).isEmpty)
        #expect(await session.server.clientJSONMessages(ofType: ClientPairInitMessage.typeString).isEmpty)
        let attemptID = try #require(session.client.currentPairing?.id)
        try await session.client.openPairingWindow(for: attemptID)
        let initData = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString)
        let pairInit = try JSONDecoder().decode(ClientPairInitMessage.self, from: initData)
        #expect(pairInit.payload.commitB == nil)
        await session.client.disconnect()
    }

    @Test("a pre-opened window admits static activation directly")
    func preOpenedWindowSendsInitDirectly() async throws {
        let session = try await makeStaticTestSession()
        let attemptID = try #require(session.client.currentPairing?.id)
        try await session.client.openPairingWindow(for: attemptID)
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString)
        #expect(await session.server.clientJSONMessages(ofType: ClientPairPendingMessage.typeString).isEmpty)
        await session.client.disconnect()
    }

    @Test("an expired window makes a later static activation pending")
    func expiredWindowGatesStaticActivation() async throws {
        let session = try await makeStaticTestSession(windowLifetime: .milliseconds(100))
        let attemptID = try #require(session.client.currentPairing?.id)
        try await session.client.openPairingWindow(for: attemptID)
        try await Task.sleep(for: .milliseconds(150))
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        #expect(await session.server.clientJSONMessages(ofType: ClientPairInitMessage.typeString).isEmpty)
        await session.client.disconnect()
    }

    @Test("a rejected static activation cancels its attempt and allows a fresh activation")
    func rejectedStaticActivationCleansUpAttempt() async throws {
        let session = try await makeStaticTestSession()
        let attemptID = try #require(session.client.currentPairing?.id)
        try await session.client.openPairingWindow(for: attemptID)
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString)
        let connection = try #require(await MainActor.run { session.client.connection })
        let attemptTask = try #require(await connection.pairingAttemptTask)
        #expect(!attemptTask.isCancelled)

        let runtime = try #require(await MainActor.run { session.client.pairingConfiguration?.runtime })
        let pairingPsk = await runtime.snapshot().pairingPsk
        await runtime.update(PairingManagementConfiguration(
            pairingPsk: pairingPsk,
            pairingPskEnabled: false,
            unpairedAccessEnabled: true,
            staticPairingCodeEnabled: true,
            staticPairingCode: nil
        ))
        try await activateStatic(session.server)
        let firstAbort = try await waitForStaticClientMessage(session.server, type: PairAbortMessage.typeString)
        #expect(try JSONDecoder().decode(PairAbortMessage.self, from: firstAbort).payload.reason == .methodNotSupported)
        #expect(attemptTask.isCancelled)
        #expect(await connection.pairingAttemptTask == nil)
        // Clean up even when the cancellation assertion fails.
        attemptTask.cancel()
        if case .timedOut = await observeTask(attemptTask, timeout: .seconds(2)) {
            Issue.record("cancelled pairing timer did not finish")
        }
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).count == 1)

        await runtime.update(PairingManagementConfiguration(
            pairingPsk: pairingPsk,
            pairingPskEnabled: false,
            unpairedAccessEnabled: true,
            staticPairingCodeEnabled: true,
            staticPairingCode: "12345678"
        ))
        try await activateStatic(session.server)
        #expect(await waitUntil { await MainActor.run {
            guard let current = session.client.currentPairing else { return false }
            return current.id != attemptID && current.phase == .pending
        } })
        let refreshedAttemptID = try #require(session.client.currentPairing?.id)
        try await session.client.openPairingWindow(for: refreshedAttemptID)
        let refreshedInit = try await waitForStaticClientMessage(
            session.server,
            type: ClientPairInitMessage.typeString,
            count: 2
        )
        let refreshedPairInit = try JSONDecoder().decode(ClientPairInitMessage.self, from: refreshedInit)
        #expect(refreshedPairInit.payload.commitB == nil)
        let replacementTask = try #require(await connection.pairingAttemptTask)
        #expect(!replacementTask.isCancelled)
        #expect(await MainActor.run { session.client.connectionState == .connected })
        await session.client.disconnect()
    }
}

@MainActor
@Suite("Static pairing transcripts", .timeLimit(.minutes(1)))
struct StaticPairingTranscriptTests {
    @Test("static code validation uses exactly eight configured ASCII digits")
    func staticCodeValidation() async throws {
        let fixture = try staticFixture()
        #expect(fixture.code.utf8.count == 8)
        #expect(fixture.code.utf8.allSatisfy { (48 ... 57).contains($0) })
        let session = try await makeStaticTestSession()
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        let codeEvent = await collectClientEvent(from: session.events, timeout: .milliseconds(200)) {
            if case .pairingCodeChanged = $0 {
                return true
            }
            return false
        }
        #expect(codeEvent == nil)
        await session.client.disconnect()
    }

    @Test("parked static pairing succeeds after operator authorization")
    func parkedSideHappyPath() async throws {
        let fixture = try staticFixture()
        let session = try await makeStaticTestSession(
            primary: true,
            pairingHandshakeHashOverride: dataFromHex(fixture.handshakeHash),
            pairingScalarBOverride: dataFromHex(fixture.scalarB)
        )
        let windowEventsTask = Task { () -> [ClientEvent] in
            var events = [ClientEvent]()
            for await event in session.events {
                if case .pairingWindowChanged = event {
                    events.append(event)
                    if events.count == 2 {
                        return events
                    }
                }
            }
            return events
        }
        _ = try await staticServerTranscript(session, operatorOpen: true)
        try await session.server.sendJSON(#"{"type":"server/pair-finalize","payload":{}}"#)
        let serverID = await session.server.serverId
        #expect(await waitUntil { await pairingRecords(session.store).contains { $0.serverId == serverID } })
        let windowEvents = await observeTask(windowEventsTask, timeout: .seconds(2))
        guard case let .completed(events) = windowEvents else {
            Issue.record("parked static pairing window did not emit open then nil")
            await session.client.disconnect()
            return
        }
        #expect(events.count == 2)
        guard case .pairingWindowChanged(.some) = events[0],
              case .pairingWindowChanged(nil) = events[1] else {
            Issue.record("parked static pairing window did not emit open then nil")
            await session.client.disconnect()
            return
        }
        #expect(session.client.pairingWindow == nil)
        await session.client.disconnect()
    }

    @Test("static transcript sends fixture-exact CPace bytes and wrapped finalize shape")
    func messageShape() async throws {
        let fixture = try staticFixture()
        let session = try await makeStaticTestSession(
            pairingHandshakeHashOverride: dataFromHex(fixture.handshakeHash),
            pairingScalarBOverride: dataFromHex(fixture.scalarB)
        )
        _ = try await session.store.reserveDynamicPairingRound(limit: dynamicPairingRoundLimit)
        _ = try await session.store.reserveDynamicPairingRound(limit: dynamicPairingRoundLimit)
        try await activateStatic(session.server)
        let (confirmData, finalizeData) = try await staticServerTranscript(session, operatorOpen: true)
        #expect(try await session.store.dynamicPairingRoundCount() == 0)
        #expect(session.client.pairingWindow != nil)
        let confirm = try JSONDecoder().decode(ClientPairConfirmMessage.self, from: confirmData)
        let finalize = try JSONDecoder().decode(ClientPairFinalizeMessage.self, from: finalizeData)
        #expect(confirm.payload.clientKc == Base64URL.encode(dataFromHex(fixture.clientKc)))
        #expect(confirm.payload.wrappedNonceB == nil)
        #expect(finalize.payload.longTermPsk.isEmpty)
        let wrapped = try #require(finalize.payload.wrappedPsk)
        #expect(wrapped.count == Base64URL.encode(dataFromHex(fixture.wrappedPsk)).count)
        #expect(Base64URL.decode(wrapped, count: 48) != nil)
        #expect(await pairingRecords(session.store).filter { $0.serverId != nil }.isEmpty)
        let types = await pairingTypes(session.server).filter {
            $0 == ClientPairInitMessage.typeString || $0 == ClientPairAuthMessage.typeString
                || $0 == ClientPairConfirmMessage.typeString || $0 == ClientPairFinalizeMessage.typeString
        }
        #expect(types == [
            ClientPairInitMessage.typeString,
            ClientPairAuthMessage.typeString,
            ClientPairConfirmMessage.typeString,
            ClientPairFinalizeMessage.typeString
        ])
        try await session.server.sendJSON(#"{"type":"server/pair-finalize","payload":{}}"#)
        #expect(await waitUntil {
            let records = await pairingRecords(session.store)
            let serverId = await session.server.serverId
            return records.contains { $0.serverId == serverId }
        })
        let connection = try #require(session.client.connection)
        #expect(await waitUntil { await !(connection.pairingWindowOpen) })
        await session.client.disconnect()
    }

    @Test("static confirmation mismatch does not touch dynamic counter")
    func mismatchDoesNotTouchDynamicCounter() async throws {
        let store = InMemoryPairingRecordStore()
        let fixture = try staticFixture()
        let handshakeHash = dataFromHex(fixture.handshakeHash)
        let scalarB = dataFromHex(fixture.scalarB)
        let session = try await makeStaticTestSession(
            store: store,
            pairingHandshakeHashOverride: handshakeHash,
            pairingScalarBOverride: scalarB
        )
        try await activateStatic(session.server)
        let attemptID = try #require(session.client.currentPairing?.id)
        try await session.client.openPairingWindow(for: attemptID)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString)
        let cpace = try CPace(
            role: .initiator,
            prs: Data(fixture.code.utf8),
            sid: dataFromHex(fixture.sid),
            scalarOverride: dataFromHex(fixture.scalarA)
        )
        let auth = ServerPairAuthMessage(
            payload: ServerPairAuthPayload(pakeMsg1: Base64URL.encode(cpace.publicShare))
        )
        let authData = try JSONEncoder().encode(auth)
        guard let authText = String(data: authData, encoding: .utf8) else {
            throw StaticTestError.missingMessage("server/pair-auth")
        }
        try await session.server.sendJSON(authText)
        let clientAuth = try await waitForStaticClientMessage(session.server, type: ClientPairAuthMessage.typeString)
        let clientAuthMessage = try JSONDecoder().decode(ClientPairAuthMessage.self, from: clientAuth)
        let clientShare = try #require(Base64URL.decode(clientAuthMessage.payload.pakeMsg2, count: 32))
        _ = try cpace.derive(remoteShare: clientShare)
        var wrong = dataFromHex(fixture.serverKc)
        wrong[wrong.startIndex] ^= 1
        let confirm = ServerPairConfirmMessage(
            payload: ServerPairConfirmPayload(serverKc: Base64URL.encode(wrong))
        )
        let confirmData = try JSONEncoder().encode(confirm)
        guard let confirmText = String(data: confirmData, encoding: .utf8) else {
            throw StaticTestError.missingMessage("server/pair-confirm")
        }
        try await session.server.sendJSON(confirmText)
        let abortData = try await waitForStaticClientMessage(session.server, type: PairAbortMessage.typeString)
        let abort = try JSONDecoder().decode(PairAbortMessage.self, from: abortData)
        #expect(abort.payload.reason == .pairingCodeMismatch)
        #expect(try await store.dynamicPairingRoundCount() == 0)
        #expect(await pairingRecords(store).allSatisfy { $0.serverId == nil })
        #expect(await MainActor.run { session.client.connectionState == .connected })
        await session.client.disconnect()
    }
}

@MainActor
@Suite("Static pairing protocol errors", .timeLimit(.minutes(1)))
struct StaticPairingProtocolErrorTests {
    @Test("static activation with a format aborts as unsupported and keeps connection open")
    func staticFormatAbortsWithoutClosing() async throws {
        let session = try await makeStaticTestSession()
        let activation = ServerActivateMessage(payload: ServerActivatePayload(
            activities: [.pairing],
            activeRoles: [],
            pairing: PairingDirective(method: PairMethod.staticPairingCode, format: "digits")
        ))
        let data = try JSONEncoder().encode(activation)
        let text = try #require(String(data: data, encoding: .utf8))
        try await session.server.sendJSON(text)
        let abortData = try await waitForStaticClientMessage(session.server, type: PairAbortMessage.typeString)
        #expect(try JSONDecoder().decode(PairAbortMessage.self, from: abortData).payload.reason == .methodNotSupported)
        #expect(await !session.server.disconnectCalled)
        #expect(await MainActor.run { session.client.connectionState == .connected })
        await session.client.disconnect()
    }

    @Test("server pair-init during static attempt silently closes")
    func serverPairInitClosesSilently() async throws {
        let session = try await makeStaticTestSession()
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        let attemptID = try #require(session.client.currentPairing?.id)
        try await session.client.openPairingWindow(for: attemptID)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString)
        try await session.server.sendJSON(#"{"type":"server/pair-init","payload":{"nonce_A":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}"#)
        #expect(await waitUntil { await session.server.disconnectCalled })
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).isEmpty)
        #expect(await pairingRecords(session.store).allSatisfy { $0.serverId == nil })
        #expect(try await session.store.dynamicPairingRoundCount() == 0)
        await session.client.disconnect()
    }

    @Test("malformed and low-order static shares silently close")
    func malformedAndLowOrderSharesCloseSilently() async throws {
        for share in ["AA", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"] {
            let session = try await makeStaticTestSession()
            try await activateStatic(session.server)
            let attemptID = try #require(session.client.currentPairing?.id)
            try await session.client.openPairingWindow(for: attemptID)
            _ = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString)
            try await session.server.sendJSON(#"{"type":"server/pair-auth","payload":{"pake_msg_1":"\#(share)"}}"#)
            #expect(await waitUntil { await session.server.disconnectCalled })
            #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).isEmpty)
            #expect(await pairingRecords(session.store).allSatisfy { $0.serverId == nil })
            #expect(try await session.store.dynamicPairingRoundCount() == 0)
            await session.client.disconnect()
        }
    }
}

@MainActor
@Suite("Static pairing cancellation", .timeLimit(.minutes(1)))
struct PairingCancellationTests {
    @Test("cancelling static activate discards state without changing counter")
    func cancellingActivateDiscardsState() async throws {
        let session = try await makeStaticTestSession()
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        try await session.server.sendJSON(#"{"type":"server/activate","payload":{"activities":[],"active_roles":[]}}"#)
        #expect(try await session.store.dynamicPairingRoundCount() == 0)
        #expect(await pairingRecords(session.store).allSatisfy { $0.serverId == nil })
        await session.client.disconnect()
    }

    @Test("server user cancellation surfaces attempt-ended")
    func serverAbortUserCancelledSurfaces() async throws {
        let session = try await makeStaticTestSession()
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        try await session.server.sendJSON(#"{"type":"pair/abort","payload":{"reason":"user_cancelled"}}"#)
        #expect(await collectClientEvent(from: session.events) {
            if case let .pairingAttemptEnded(snapshot) = $0, snapshot.phase == .ended(.userCancelled) {
                return true
            }
            return false
        } != nil)
        #expect(try await session.store.dynamicPairingRoundCount() == 0)
        await session.client.disconnect()
    }

    @Test("static attempt timeout sends attempt_timeout")
    func attemptTimeout() async throws {
        let session = try await makeStaticTestSession(attemptTimeout: .milliseconds(100))
        await session.server.transport.setHonorCancellationSends(true)
        try await activateStatic(session.server)
        let attemptID = try #require(session.client.currentPairing?.id)
        try await session.client.openPairingWindow(for: attemptID)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString)
        let abortData = try await waitForStaticClientMessage(session.server, type: PairAbortMessage.typeString)
        let abort = try JSONDecoder().decode(PairAbortMessage.self, from: abortData)
        #expect(abort.payload.reason == .attemptTimeout)
        #expect(try await session.store.dynamicPairingRoundCount() == 0)
        #expect(await pairingRecords(session.store).allSatisfy { $0.serverId == nil })
        await session.client.disconnect()
    }
}

@MainActor
@Suite("Pairing index sequence", .timeLimit(.minutes(1)))
struct PairingIndexSequenceTests {
    @Test("successive static activations carry increasing pairing indexes")
    func successiveStaticActivationsCarryIncreasingIndexes() async throws {
        let fixture = try staticFixture()
        let session = try await makeStaticTestSession(
            pairingHandshakeHashOverride: dataFromHex(fixture.handshakeHash),
            pairingScalarBOverride: dataFromHex(fixture.scalarB)
        )
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        let pendingMessages = await session.server.clientJSONMessages(ofType: ClientPairPendingMessage.typeString)
        let firstPendingData = try #require(pendingMessages.last)
        let firstPending = try JSONDecoder().decode(ClientPairPendingMessage.self, from: firstPendingData)
        #expect(firstPending.payload.pairingIndex == fixture.counter)
        try await session.server.sendJSON(#"{"type":"pair/abort","payload":{"reason":"user_cancelled"}}"#)
        try await activateStatic(session.server)
        let secondPendingData = try await waitForStaticClientMessage(
            session.server,
            type: ClientPairPendingMessage.typeString,
            count: 2
        )
        let secondPending = try JSONDecoder().decode(ClientPairPendingMessage.self, from: secondPendingData)
        #expect(secondPending.payload.pairingIndex == fixture.counter + 1)
        await session.client.disconnect()
    }

    @Test("static pairing index resets after a Noise re-handshake")
    func staticIndexResetsAfterRehandshake() async throws {
        let fixture = try staticFixture()
        let session = try await makeStaticTestSession(
            pairingHandshakeHashOverride: dataFromHex(fixture.handshakeHash),
            pairingScalarBOverride: dataFromHex(fixture.scalarB)
        )
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        try await session.server.sendJSON(#"{"type":"pair/abort","payload":{"reason":"user_cancelled"}}"#)
        try await session.server.beginRehandshake(to: .sentinel)
        #expect(await waitUntil { await session.server.rehandshakeComplete })
        try await activateStatic(session.server)
        let pendingData = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString, count: 2)
        let pending = try JSONDecoder().decode(ClientPairPendingMessage.self, from: pendingData)
        #expect(pending.payload.pairingIndex == fixture.counter)
        await session.client.disconnect()
    }
}
