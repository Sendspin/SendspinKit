import CryptoKit
import Foundation
@testable import SendspinKit
import Testing

private struct DynamicFixtureResource: Decodable {
    let dynamicTranscript: DynamicFixture

    enum CodingKeys: String, CodingKey { case dynamicTranscript = "dynamic_transcript" }
}

private struct DynamicFixture: Decodable {
    let handshakeHash: String
    let counter: UInt32
    let nonceA: String
    let nonceB: String
    let scalarA: String
    let scalarB: String
    let digitsCode: String
    let qrCodeBytes: String
    let qrToken: String
    let commitB: String
    let pakeMsg2: String
    let clientKc: String
    let wrappedNonceB: String
    let wrappedPsk: String

    enum CodingKeys: String, CodingKey {
        case handshakeHash = "handshake_hash"
        case counter
        case nonceA = "nonce_A"
        case nonceB = "nonce_B"
        case scalarA = "scalar_A"
        case scalarB = "scalar_B"
        case digitsCode = "digits_code"
        case qrCodeBytes = "qr_code_bytes"
        case qrToken = "qr_token"
        case commitB = "commit_B"
        case pakeMsg2 = "pake_msg_2"
        case clientKc = "client_kc"
        case wrappedNonceB = "wrapped_nonce_B"
        case wrappedPsk = "wrapped_psk"
    }
}

private enum DynamicTestError: Error { case missingFixture, missingEvent, missingMessage(String) }

private func dynamicFixture() throws -> DynamicFixture {
    let url = try #require(Bundle.module.url(
        forResource: "cpace-mcf-known-answer",
        withExtension: "json",
        subdirectory: "Resources"
    ))
    return try JSONDecoder().decode(DynamicFixtureResource.self, from: Data(contentsOf: url)).dynamicTranscript
}

private struct DynamicTestSession {
    let client: SendspinClient
    let server: MockNoiseServer
    let store: any PairingRecordStore
    let events: AsyncStream<ClientEvent>
    let pairingHandshakeHashOverride: Data?
    let deterministic: Bool
}

@MainActor
private func makeDynamicTestSession(
    store: (any PairingRecordStore)? = nil,
    attemptTimeout: Duration = .seconds(120),
    windowLifetime: Duration = .seconds(300),
    nonceBOverride: Data? = nil,
    pairingHandshakeHashOverride: Data? = nil,
    pairingScalarBOverride: Data? = nil
) async throws -> DynamicTestSession {
    let pairingPsk = Psk.generate()
    let resolvedStore: any PairingRecordStore = store ?? InMemoryPairingRecordStore(pairingPsk: pairingPsk)
    let client = try SendspinClient(
        identity: .generate(),
        name: "Dynamic Pairing Test Client",
        roles: [],
        pairing: PairingConfiguration(
            pairingPsk: pairingPsk,
            store: resolvedStore,
            enabled: false,
            dynamicPairingCodeEnabled: true
        ),
        audioOutputCapabilityProvider: AudioOutputCapabilityService(),
        pairingAttemptTimeout: attemptTimeout,
        pairingWindowLifetime: windowLifetime,
        nonceBOverride: nonceBOverride,
        pairingHandshakeHashOverride: pairingHandshakeHashOverride,
        pairingScalarBOverride: pairingScalarBOverride
    )
    let transport = MockTransport()
    let server = MockNoiseServer(transport: transport, psk: .sentinel)
    let events = client.events()
    async let accepted: Void = client.acceptConnection(transport)
    try await server.establishSession(activities: [], activeRoles: [])
    try await accepted
    #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })
    return DynamicTestSession(
        client: client,
        server: server,
        store: resolvedStore,
        events: events,
        pairingHandshakeHashOverride: pairingHandshakeHashOverride,
        deterministic: nonceBOverride != nil && pairingHandshakeHashOverride != nil && pairingScalarBOverride != nil
    )
}

private func activateDynamic(_ server: MockNoiseServer, format: PairingCodeFormat = .digits) async throws {
    let raw = format.rawValue
    let json = """
    {"type":"server/activate","payload":{"activities":["pairing"],"active_roles":[],"pairing":{"method":"dynamic_pairing_code","format":"\(raw)"}}}
    """
    try await server.sendJSON(json)
}

private func waitForClientMessage(
    _ server: MockNoiseServer,
    type: String,
    count: Int = 1
) async throws -> Data {
    #expect(await waitUntil(timeout: .seconds(3)) {
        await server.clientJSONMessages(ofType: type).count >= count
    })
    guard let message = await server.clientJSONMessages(ofType: type).last else {
        throw DynamicTestError.missingMessage(type)
    }
    return message
}

private func endedEvent(_ stream: AsyncStream<ClientEvent>, reason: PairAbortReason) async -> ClientEvent? {
    await collectClientEvent(from: stream, timeout: .seconds(3)) {
        if case .pairingAttemptEnded(reason) = $0 {
            return true
        }
        return false
    }
}

private extension ClientEvent {
    func unwrapEmission() throws -> PairingCodeEmission {
        guard case let .pairingCodeChanged(value?) = self else { throw DynamicTestError.missingEvent }
        return value
    }
}

private func codeEvent(_ stream: AsyncStream<ClientEvent>) async -> ClientEvent? {
    await collectClientEvent(from: stream, timeout: .seconds(3)) {
        if case .pairingCodeChanged(.some) = $0 {
            return true
        }
        return false
    }
}

private func pairingMessageTypes(_ server: MockNoiseServer) async -> [String] {
    await server.decryptedMessages.compactMap { message in
        guard message.first == NoiseFrameType.json else { return nil }
        let json = String(data: Data(message.dropFirst()), encoding: .utf8) ?? ""
        guard let data = json.data(using: .utf8) else { return nil }
        return SendspinEncoding.messageType(of: data)
    }
}

private func dynamicServerTranscript(
    _ session: DynamicTestSession,
    format: PairingCodeFormat = .digits,
    badServerConfirmation: Bool = false
) async throws -> (PairingCodeEmission, [String]) {
    let fixture = try dynamicFixture()
    try await activateDynamic(session.server, format: format)
    let initData = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
    let initMessage = try JSONDecoder().decode(ClientPairInitMessage.self, from: initData)
    #expect(initMessage.payload.pairingIndex == fixture.counter)
    if session.pairingHandshakeHashOverride != nil {
        #expect(initMessage.payload.commitB == Base64URL.encode(dataFromHex(fixture.commitB)))
    }
    guard let commit = Base64URL.decode(initMessage.payload.commitB ?? "", count: 32) else {
        throw DynamicTestError.missingMessage(String(data: initData, encoding: .utf8) ?? "invalid init")
    }
    let eventTask = Task { await codeEvent(session.events) }
    let nonceA = dataFromHex(fixture.nonceA)
    try await session.server.sendJSON(
        String(data: JSONEncoder().encode(ServerPairInitMessage(
            payload: ServerPairInitPayload(nonceA: Base64URL.encode(nonceA))
        )), encoding: .utf8)!
    )
    let event = try #require(await eventTask.value)
    let emission: PairingCodeEmission = if case let .pairingCodeChanged(value?) = event {
        value
    } else {
        throw DynamicTestError.missingEvent
    }
    let handshakeHash: Data = if let override = session.pairingHandshakeHashOverride {
        override
    } else {
        try #require(await session.server.establishedHandshakeHash)
    }
    let sid = CPaceSessionIdentifier.make(
        handshakeHash: handshakeHash,
        counter: fixture.counter
    )
    let prs = emission.format == .digits ? Data(emission.payload.utf8) : try qrPayload(emission.payload)
    let cpace = try CPace(
        role: .initiator,
        prs: prs,
        sid: sid,
        scalarOverride: dataFromHex(fixture.scalarA)
    )
    try await session.server.sendJSON(
        String(data: JSONEncoder().encode(ServerPairAuthMessage(
            payload: ServerPairAuthPayload(pakeMsg1: Base64URL.encode(cpace.publicShare))
        )), encoding: .utf8)!
    )
    let clientAuthData = try await waitForClientMessage(session.server, type: ClientPairAuthMessage.typeString)
    let clientAuth = try JSONDecoder().decode(ClientPairAuthMessage.self, from: clientAuthData)
    if session.deterministic {
        #expect(clientAuth.payload.pakeMsg2 == Base64URL.encode(dataFromHex(fixture.pakeMsg2)))
    }
    let clientShare = try #require(Base64URL.decode(clientAuth.payload.pakeMsg2, count: 32))
    let secrets = try cpace.derive(remoteShare: clientShare)
    var serverTag = CPaceX25519.mcfTag(
        isk: secrets.isk,
        sid: sid,
        share: cpace.publicShare,
        associatedData: CPaceX25519.defaultInitiatorAD
    )
    if badServerConfirmation {
        serverTag[serverTag.startIndex] ^= 1
    }
    try await session.server.sendJSON(
        String(data: JSONEncoder().encode(ServerPairConfirmMessage(
            payload: ServerPairConfirmPayload(serverKc: Base64URL.encode(serverTag))
        )), encoding: .utf8)!
    )
    return (emission, [commit.base64EncodedString(), Base64URL.encode(cpace.publicShare)])
}

private func qrPayload(_ token: String) throws -> Data {
    let body = token.hasPrefix("SP:1") ? String(token.dropFirst(4)) : ""
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    let restored = body.replacingOccurrences(of: "9", with: "2")
    var accumulator = 0
    var bits = 0
    var bytes = Data()
    for character in restored {
        guard let value = alphabet.firstIndex(of: character) else { throw DynamicTestError.missingFixture }
        accumulator = (accumulator << 5) | value
        bits += 5
        if bits >= 8 {
            bits -= 8
            bytes.append(UInt8((accumulator >> bits) & 0xFF))
        }
    }
    return Data(bytes.prefix(24))
}

@Suite("Dynamic pairing transcripts", .timeLimit(.minutes(1)))
struct DynamicPairingTranscriptTests {
    @Test("happy path uses fixture-exact code and persists only after acknowledgement")
    func happyPath() async throws {
        let fixture = try dynamicFixture()
        let session = try await makeDynamicTestSession(
            nonceBOverride: dataFromHex(fixture.nonceB),
            pairingHandshakeHashOverride: dataFromHex(fixture.handshakeHash),
            pairingScalarBOverride: dataFromHex(fixture.scalarB)
        )
        let (emission, _) = try await dynamicServerTranscript(session)
        #expect(emission.format == .digits)
        #expect(emission.payload == fixture.digitsCode)
        #expect(emission.payload == "268386")
        let confirms = try await waitForClientMessage(session.server, type: ClientPairConfirmMessage.typeString)
        let finalize = try await waitForClientMessage(session.server, type: ClientPairFinalizeMessage.typeString)
        #expect(await session.store.listRecords().filter { $0.serverId != nil }.isEmpty)
        let confirmJSON = try #require(String(data: confirms, encoding: .utf8))
        #expect(confirmJSON.contains(#""wrapped_nonce_B":"#))
        #expect(!confirmJSON.contains("wrapped_nonce__b"))
        let messageTypes = await pairingMessageTypes(session.server)
        let pairingTypes = messageTypes.filter {
            $0 == ClientPairInitMessage.typeString
                || $0 == ClientPairAuthMessage.typeString
                || $0 == ClientPairConfirmMessage.typeString
                || $0 == ClientPairFinalizeMessage.typeString
        }
        let expected = [
            ClientPairInitMessage.typeString,
            ClientPairAuthMessage.typeString,
            ClientPairConfirmMessage.typeString,
            ClientPairFinalizeMessage.typeString
        ]
        #expect(pairingTypes == expected)
        let confirmIndex = await session.server.clientJSONMessages(ofType: ClientPairConfirmMessage.typeString).count
        #expect(confirmIndex == 1)
        let confirm = try JSONDecoder().decode(ClientPairConfirmMessage.self, from: confirms)
        let final = try JSONDecoder().decode(ClientPairFinalizeMessage.self, from: finalize)
        if session.deterministic {
            #expect(confirm.payload.clientKc == Base64URL.encode(dataFromHex(fixture.clientKc)))
            #expect(confirm.payload.wrappedNonceB == Base64URL.encode(dataFromHex(fixture.wrappedNonceB)))
        }
        let wrappedPsk = try #require(final.payload.wrappedPsk)
        #expect(Base64URL.decode(wrappedPsk, count: 48) != nil)
        #expect(wrappedPsk.count == Base64URL.encode(dataFromHex(fixture.wrappedPsk)).count)
        #expect(final.payload.longTermPsk.isEmpty)
        try await session.server.sendJSON(#"{"type":"server/pair-finalize","payload":{}}"#)
        #expect(await waitUntil { await session.store.listRecords().filter { $0.serverId != nil }.count == 1 })
        #expect(await session.store.listRecords().filter { $0.serverId != nil }.count == 1)
        #expect(await collectClientEvent(from: session.events) { $0 == .pairingCodeChanged(nil) } != nil)
        await session.client.disconnect()
    }

    @Test("QR format emits the fixture-exact version-one pairing token")
    func qrVariant() async throws {
        let fixture = try dynamicFixture()
        let session = try await makeDynamicTestSession(
            nonceBOverride: dataFromHex(fixture.nonceB),
            pairingHandshakeHashOverride: dataFromHex(fixture.handshakeHash)
        )
        let (emission, _) = try await dynamicServerTranscript(session, format: .qrCode)
        #expect(emission.format == .qrCode)
        #expect(emission.payload == fixture.qrToken)
        #expect(emission.payload == "SP:1HYXJG6UC5JAU69DKMFK3GYUGIDXDBU75VBO4SMI")
        #expect(try qrPayload(emission.payload) == dataFromHex(fixture.qrCodeBytes))
        await session.client.disconnect()
    }

    @Test("binding mismatch aborts with pairing_code_mismatch and keeps the socket open")
    func bindingMismatch() async throws {
        let session = try await makeDynamicTestSession()
        _ = try await dynamicServerTranscript(session, badServerConfirmation: true)
        let abortData = try await waitForClientMessage(session.server, type: PairAbortMessage.typeString)
        let abort = try JSONDecoder().decode(PairAbortMessage.self, from: abortData)
        #expect(abort.payload.reason.rawValue == "pairing_code_mismatch")
        #expect(await session.store.listRecords().allSatisfy { $0.serverId == nil })
        #expect(await endedEvent(session.events, reason: .pairingCodeMismatch) != nil)
        #expect(await collectClientEvent(from: session.events) { $0 == .pairingCodeChanged(nil) } != nil)
        #expect(await MainActor.run { session.client.connectionState == .connected })
        try await session.server.sendJSON(#"{"type":"server/state","payload":{}}"#)
        #expect(await MainActor.run { session.client.connectionState == .connected })
        await session.client.disconnect()
    }

    @Test("invalid server confirmation increments once, clears code, and keeps connection open")
    func serverConfirmationFailure() async throws {
        let session = try await makeDynamicTestSession()
        _ = try await dynamicServerTranscript(session, badServerConfirmation: true)
        _ = try await waitForClientMessage(session.server, type: PairAbortMessage.typeString)
        #expect(await session.store.dynamicPairingFailureCount() == 1)
        #expect(await endedEvent(session.events, reason: .pairingCodeMismatch) != nil)
        #expect(await collectClientEvent(from: session.events) { $0 == .pairingCodeChanged(nil) } != nil)
        #expect(await MainActor.run { session.client.connectionState == .connected })
        await session.client.disconnect()
    }

    @Test("unsupported activation can be retried and an in-flight retry remains exclusive")
    func unsupportedActivationDoesNotPoisonNextAttempt() async throws {
        let fixture = try dynamicFixture()
        let session = try await makeDynamicTestSession()
        let server = session.server

        try await server.sendJSON(
            #"""
            {"type":"server/activate","payload":{"activities":["pairing"],"active_roles":[],
            "pairing":{"method":"dynamic_pairing_code","format":"bad"}}}
            """#
        )
        let firstAbortData = try await waitForClientMessage(
            server,
            type: PairAbortMessage.typeString
        )
        let firstAbort = try JSONDecoder().decode(
            PairAbortMessage.self,
            from: firstAbortData
        )
        #expect(firstAbort.payload.reason == .methodNotSupported)
        #expect(await MainActor.run { session.client.connectionState == .connected })
        #expect(await !server.disconnectCalled)

        try await activateDynamic(server)
        let retryInitData = try await waitForClientMessage(server, type: ClientPairInitMessage.typeString)
        let retryInit = try JSONDecoder().decode(ClientPairInitMessage.self, from: retryInitData)
        #expect(retryInit.payload.pairingIndex == fixture.counter + 1)
        #expect(await server.clientJSONMessages(ofType: PairAbortMessage.typeString).count == 1)
        #expect(await MainActor.run { session.client.connectionState == .connected })
        #expect(await !server.disconnectCalled)

        try await activateDynamic(server)
        let concurrentAbortData = try await waitForClientMessage(server, type: PairAbortMessage.typeString, count: 2)
        let concurrentAbort = try JSONDecoder().decode(PairAbortMessage.self, from: concurrentAbortData)
        #expect(concurrentAbort.payload.reason == .concurrentAttempt)
        #expect(await waitUntil { await server.disconnectCalled })
        #expect(await waitUntil {
            await MainActor.run { session.client.connectionState == .disconnected }
        })
    }

    @Test("re-handshake resets the dynamic pairing index")
    func rehandshakeResetsPairingIndex() async throws {
        let fixture = try dynamicFixture()
        let session = try await makeDynamicTestSession()
        let server = session.server

        try await activateDynamic(server)
        let firstInitData = try await waitForClientMessage(server, type: ClientPairInitMessage.typeString)
        let firstInit = try JSONDecoder().decode(ClientPairInitMessage.self, from: firstInitData)
        #expect(firstInit.payload.pairingIndex == fixture.counter)
        try await server.sendJSON(#"{"type":"pair/abort","payload":{"reason":"user_cancelled"}}"#)
        #expect(await endedEvent(session.events, reason: .userCancelled) != nil)
        #expect(await MainActor.run { session.client.connectionState == .connected })

        let helloCountBefore = await server.clientJSONMessages(ofType: ClientHelloMessage.typeString).count
        try await server.beginRehandshake(to: .sentinel)
        #expect(await waitUntil { await server.rehandshakeComplete })
        try await server.sendJSON(#"{"type":"server/hello","payload":{"name":"Test Server"}}"#)
        #expect(await waitUntil {
            await server.clientJSONMessages(ofType: ClientHelloMessage.typeString).count == helloCountBefore + 1
        })

        try await activateDynamic(server)
        let secondInitData = try await waitForClientMessage(server, type: ClientPairInitMessage.typeString, count: 2)
        let secondInit = try JSONDecoder().decode(ClientPairInitMessage.self, from: secondInitData)
        #expect(secondInit.payload.pairingIndex == fixture.counter)
        #expect(await MainActor.run { session.client.connectionState == .connected })
        await session.client.disconnect()
    }
}

@Suite("Dynamic pairing failure counter", .timeLimit(.minutes(1)))
struct DynamicPairingFailureCounterTests {
    @Test("counter increments only for server confirmation failures and resets after success")
    func counterSemantics() async throws {
        let store = InMemoryPairingRecordStore()
        let session = try await makeDynamicTestSession(store: store)
        _ = try await dynamicServerTranscript(session, badServerConfirmation: true)
        _ = try await waitForClientMessage(session.server, type: PairAbortMessage.typeString)
        #expect(await store.dynamicPairingFailureCount() == 1)
        #expect(await MainActor.run { session.client.connectionState == .connected })
        await session.client.disconnect()

        let success = try await makeDynamicTestSession(store: store)
        _ = try await dynamicServerTranscript(success)
        _ = try await waitForClientMessage(success.server, type: ClientPairConfirmMessage.typeString)
        _ = try await waitForClientMessage(success.server, type: ClientPairFinalizeMessage.typeString)
        #expect(await store.dynamicPairingFailureCount() == 0)
        await success.client.disconnect()

        let escalatedStore = InMemoryPairingRecordStore()
        for _ in 0 ..< 5 {
            _ = await escalatedStore.incrementDynamicPairingFailureCount()
        }
        let escalated = try await makeDynamicTestSession(store: escalatedStore)
        try await activateDynamic(escalated.server)
        _ = try await waitForClientMessage(escalated.server, type: ClientPairPendingMessage.typeString)
        #expect(await escalated.server.clientJSONMessages(ofType: ClientPairInitMessage.typeString).isEmpty)
        try await escalated.client.openPairingWindow()
        _ = try await waitForClientMessage(escalated.server, type: ClientPairInitMessage.typeString)
        try await escalated.client.cancelPairingAttempt()
        await escalated.client.disconnect()
    }
}

@Suite("Pairing window", .timeLimit(.minutes(1)))
struct PairingWindowTests {
    @Test("escalated dynamic attempt waits for one open window and does not time out while pending")
    func dynamicEscalation() async throws {
        let store = InMemoryPairingRecordStore()
        for _ in 0 ..< 5 {
            _ = await store.incrementDynamicPairingFailureCount()
        }
        let session = try await makeDynamicTestSession(store: store, attemptTimeout: .milliseconds(100))
        try await activateDynamic(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        #expect(await session.server.clientJSONMessages(ofType: ClientPairInitMessage.typeString).isEmpty)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).isEmpty)
        try await session.client.openPairingWindow()
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        try await session.client.cancelPairingAttempt()
        await session.client.disconnect()
    }
}

@Suite("Dynamic pairing protocol errors", .timeLimit(.minutes(1)))
struct DynamicPairingProtocolErrorTests {
    @Test("wrong nonce length silently closes without abort or persistence")
    func wrongLengthNonceClosesSilently() async throws {
        let session = try await makeDynamicTestSession()
        try await activateDynamic(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        try await session.server.sendJSON(#"{"type":"server/pair-init","payload":{"nonce_A":"AA"}}"#)
        #expect(await waitUntil { await session.server.disconnectCalled })
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).isEmpty)
        #expect(await session.store.listRecords().allSatisfy { $0.serverId == nil })
        await session.client.disconnect()
    }

    @Test("low-order pake share silently closes without abort or counter mutation")
    func lowOrderShareClosesSilently() async throws {
        let session = try await makeDynamicTestSession()
        try await activateDynamic(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        let fixture = try dynamicFixture()
        let pairInit = """
        {"type":"server/pair-init","payload":{"nonce_A":"\(fixture.nonceA)"}}
        """
        try await session.server.sendJSON(pairInit)
        try await Task.sleep(for: .milliseconds(20))
        try await session.server.sendJSON(#"{"type":"server/pair-auth","payload":{"pake_msg_1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}"#)
        #expect(await waitUntil { await session.server.disconnectCalled })
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).isEmpty)
        #expect(await session.store.dynamicPairingFailureCount() == 0)
        await session.client.disconnect()
    }
}

@Suite("Dynamic pairing timeout and admissibility", .timeLimit(.minutes(1)))
struct DynamicPairingTimeoutTests {
    @Test("attempt timeout uses the exact attempt_timeout reason")
    func attemptTimeout() async throws {
        let session = try await makeDynamicTestSession(attemptTimeout: .milliseconds(100))
        try await activateDynamic(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        let abortData = try await waitForClientMessage(session.server, type: PairAbortMessage.typeString)
        let abort = try JSONDecoder().decode(PairAbortMessage.self, from: abortData)
        #expect(abort.payload.reason.rawValue == "attempt_timeout")
        #expect(await endedEvent(session.events, reason: .attemptTimeout) != nil)
        #expect(await collectClientEvent(from: session.events) { $0 == .pairingCodeChanged(nil) } != nil)
        #expect(await session.store.listRecords().allSatisfy { $0.serverId == nil })
        await session.client.disconnect()
    }

    @Test("server abort clears the emitted code and surfaces its reason")
    func serverAbortClearsCode() async throws {
        let session = try await makeDynamicTestSession()
        try await activateDynamic(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        let fixture = try dynamicFixture()
        let pairInit = "{\"type\":\"server/pair-init\",\"payload\":{\"nonce_A\":\"\(Base64URL.encode(dataFromHex(fixture.nonceA)))\"}}"
        try await session.server.sendJSON(pairInit)
        let initialCode = await codeEvent(session.events)
        #expect(initialCode != nil)
        let endedTask = Task { await endedEvent(session.events, reason: .userCancelled) }
        let clearedTask = Task { await collectClientEvent(from: session.events) { $0 == .pairingCodeChanged(nil) } }
        try await session.server.sendJSON("{\"type\":\"pair/abort\",\"payload\":{\"reason\":\"user_cancelled\"}}")
        #expect(await endedTask.value != nil)
        #expect(await clearedTask.value != nil)
        await session.client.disconnect()
    }

    @Test("unknown method and unsupported format use method_not_supported")
    func methodNotSupported() async throws {
        let session = try await makeDynamicTestSession()
        try await session.server
            .sendJSON(#"{"type":"server/activate","payload":{"activities":["pairing"],"active_roles":[],"pairing":{"method":"unknown_method"}}}"#)
        let unknown = try await JSONDecoder().decode(
            PairAbortMessage.self,
            from: waitForClientMessage(session.server, type: PairAbortMessage.typeString)
        )
        #expect(unknown.payload.reason.rawValue == "method_not_supported")
        let unsupportedActivation = """
        {"type":"server/activate","payload":{"activities":["pairing"],"active_roles":[],"pairing":{"method":"dynamic_pairing_code","format":"bad"}}}
        """
        try await session.server.sendJSON(unsupportedActivation)
        let unsupported = try await JSONDecoder().decode(
            PairAbortMessage.self,
            from: waitForClientMessage(session.server, type: PairAbortMessage.typeString, count: 2)
        )
        #expect(unsupported.payload.reason.rawValue == "method_not_supported")
        await session.client.disconnect()
    }
}
