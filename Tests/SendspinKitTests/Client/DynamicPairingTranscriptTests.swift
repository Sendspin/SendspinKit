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

private func pairingRecords(_ store: any PairingRecordStore) async -> [PairingRecord] {
    do {
        return try await store.listRecords()
    } catch {
        Issue.record("Pairing record listing failed: \(error)")
        return []
    }
}

private struct DynamicTestSession {
    let client: SendspinClient
    let server: MockNoiseServer
    let store: any PairingRecordStore
    let events: AsyncStream<ClientEvent>
    let pairingHandshakeHashOverride: Data?
    let deterministic: Bool
    let hasPrimary: Bool
}

@MainActor
private func makeDynamicTestSession(
    store: (any PairingRecordStore)? = nil,
    primary: Bool = false,
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
        try await side.beginAdmission(name: "Dynamic Pairing Side")
        for _ in 0 ..< dynamicPairingRoundLimit {
            _ = try await resolvedStore.reserveDynamicPairingRound(limit: dynamicPairingRoundLimit)
        }
        try await activateDynamic(side)
        try await sideAccepted
        #expect(await waitUntil { await MainActor.run { client.pairingConnection != nil } })
        return DynamicTestSession(
            client: client,
            server: side,
            store: resolvedStore,
            events: events,
            pairingHandshakeHashOverride: pairingHandshakeHashOverride,
            deterministic: nonceBOverride != nil && pairingHandshakeHashOverride != nil && pairingScalarBOverride != nil,
            hasPrimary: true
        )
    }
    return DynamicTestSession(
        client: client,
        server: server,
        store: resolvedStore,
        events: events,
        pairingHandshakeHashOverride: pairingHandshakeHashOverride,
        deterministic: nonceBOverride != nil && pairingHandshakeHashOverride != nil && pairingScalarBOverride != nil,
        hasPrimary: false
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
        if case let .pairingAttemptEnded(snapshot) = $0, snapshot.phase == .ended(reason) {
            return true
        }
        return false
    }
}

private extension ClientEvent {
    func unwrapEmission() throws -> PairingCodeEmission {
        guard case let .pairingCodeChanged(snapshot) = self, let value = snapshot.code else { throw DynamicTestError.missingEvent }
        return value
    }
}

private func codeEvent(_ stream: AsyncStream<ClientEvent>) async -> ClientEvent? {
    await collectClientEvent(from: stream, timeout: .seconds(3)) {
        if case let .pairingCodeChanged(snapshot) = $0, snapshot.code != nil {
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
    badServerConfirmation: Bool = false,
    operatorOpen: Bool = false
) async throws -> (PairingCodeEmission, [String]) {
    let fixture = try dynamicFixture()
    if operatorOpen, !session.hasPrimary {
        for _ in 0 ..< dynamicPairingRoundLimit {
            _ = try await session.store.reserveDynamicPairingRound(limit: dynamicPairingRoundLimit)
        }
    }
    if !session.hasPrimary {
        try await activateDynamic(session.server, format: format)
    }
    let initData: Data
    if operatorOpen {
        _ = try await waitForClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        let attemptID = try #require(await MainActor.run { session.client.currentPairing?.id })
        try await session.client.openPairingWindow(for: attemptID)
        initData = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
    } else {
        initData = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
    }
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
    let emission = try event.unwrapEmission()
    let handshakeHash: Data = if let override = session.pairingHandshakeHashOverride {
        override
    } else {
        try #require(await session.server.establishedHandshakeHash)
    }
    let sid = CPaceSessionIdentifier.make(
        handshakeHash: handshakeHash,
        counter: initMessage.payload.pairingIndex,
        round: 1
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

@MainActor
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
        let (emission, _) = try await dynamicServerTranscript(session, operatorOpen: true)
        #expect(emission.format == .digits)
        #expect(session.client.pairingWindow == nil)
        #expect(emission.payload == fixture.digitsCode)
        #expect(emission.payload == "268386")
        let confirms = try await waitForClientMessage(session.server, type: ClientPairConfirmMessage.typeString)
        let finalize = try await waitForClientMessage(session.server, type: ClientPairFinalizeMessage.typeString)
        #expect(await pairingRecords(session.store).filter { $0.serverId != nil }.isEmpty)
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
        #expect(await waitUntil { await pairingRecords(session.store).filter { $0.serverId != nil }.count == 1 })
        #expect(await pairingRecords(session.store).filter { $0.serverId != nil }.count == 1)
        #expect(await collectClientEvent(from: session.events) {
            if case let .pairingCodeChanged(snapshot) = $0 {
                return snapshot.code == nil
            }
            return false
        } != nil)
        await session.client.disconnect()
    }

    @Test("parked dynamic pairing succeeds after operator authorization")
    func parkedSideHappyPath() async throws {
        let fixture = try dynamicFixture()
        let session = try await makeDynamicTestSession(
            primary: true,
            nonceBOverride: dataFromHex(fixture.nonceB),
            pairingHandshakeHashOverride: dataFromHex(fixture.handshakeHash),
            pairingScalarBOverride: dataFromHex(fixture.scalarB)
        )
        let windowEventsTask = Task { () -> [ClientEvent] in
            var events = [ClientEvent]()
            for await event in session.client.events() {
                if case .pairingWindowChanged = event {
                    events.append(event)
                    if events.count == 2 {
                        return events
                    }
                }
            }
            return events
        }
        let (emission, _) = try await dynamicServerTranscript(session, operatorOpen: true)
        #expect(emission.payload == fixture.digitsCode)
        let finalize = try await waitForClientMessage(session.server, type: ClientPairFinalizeMessage.typeString)
        #expect(finalize.isEmpty == false)
        try await session.server.sendJSON(#"{"type":"server/pair-finalize","payload":{}}"#)
        let serverID = await session.server.serverId
        #expect(await waitUntil { await pairingRecords(session.store).contains { $0.serverId == serverID } })
        let windowEvents = await observeTask(windowEventsTask, timeout: .seconds(2))
        guard case let .completed(events) = windowEvents else {
            Issue.record("parked dynamic pairing window did not emit open then nil")
            await session.client.disconnect()
            return
        }
        #expect(events.count == 2)
        guard case .pairingWindowChanged(.some) = events[0],
              case .pairingWindowChanged(nil) = events[1] else {
            Issue.record("parked dynamic pairing window did not emit open then nil")
            await session.client.disconnect()
            return
        }
        #expect(session.client.pairingWindow == nil)
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

    @Test("binding mismatch retries with pairing_code_mismatch still available to a later round")
    func bindingMismatch() async throws {
        let session = try await makeDynamicTestSession()
        _ = try await dynamicServerTranscript(session, badServerConfirmation: true)
        _ = try await waitForClientMessage(session.server, type: ClientPairRetryMessage.typeString)
        #expect(await pairingRecords(session.store).allSatisfy { $0.serverId == nil })
        #expect(await MainActor.run { session.client.connectionState == .connected })
        #expect(await collectClientEvent(from: session.events, timeout: .milliseconds(100)) {
            if case .pairingAttemptEnded = $0 {
                return true
            }
            return false
        } == nil)
        #expect(await collectClientEvent(from: session.events, timeout: .milliseconds(100)) {
            if case let .pairingCodeChanged(snapshot) = $0 {
                return snapshot.code == nil
            }
            return false
        } == nil)
        try await session.server.sendJSON(#"{"type":"server/state","payload":{}}"#)
        #expect(await MainActor.run { session.client.connectionState == .connected })
        await session.client.disconnect()
    }

    @Test("a fresh attempt uses round one after an earlier failed round consumes budget")
    func freshAttemptUsesRoundOne() async throws {
        let fixture = try dynamicFixture()
        let store = InMemoryPairingRecordStore()
        let first = try await makeDynamicTestSession(store: store)
        _ = try await dynamicServerTranscript(first, badServerConfirmation: true)
        _ = try await waitForClientMessage(first.server, type: ClientPairRetryMessage.typeString)
        #expect(try await store.dynamicPairingRoundCount() == 1)
        let firstID = try #require(first.client.currentPairing?.id)
        try await first.client.cancelPairing(attemptID: firstID)
        await first.client.disconnect()

        let next = try await makeDynamicTestSession(
            store: store,
            nonceBOverride: dataFromHex(fixture.nonceB),
            pairingHandshakeHashOverride: dataFromHex(fixture.handshakeHash),
            pairingScalarBOverride: dataFromHex(fixture.scalarB)
        )
        try await activateDynamic(next.server)
        let initData = try await waitForClientMessage(next.server, type: ClientPairInitMessage.typeString)
        let pairInit = try JSONDecoder().decode(ClientPairInitMessage.self, from: initData)
        try await next.server.sendJSON(#require(String(data: JSONEncoder().encode(ServerPairInitMessage(
            payload: ServerPairInitPayload(nonceA: Base64URL.encode(dataFromHex(fixture.nonceA)))
        )), encoding: .utf8)))
        _ = try #require(await codeEvent(next.events))
        let connection = try #require(next.client.connection)
        let expectedSID = CPaceSessionIdentifier.make(
            handshakeHash: dataFromHex(fixture.handshakeHash),
            counter: pairInit.payload.pairingIndex,
            round: 1
        )
        #expect(await connection.dynamicPairingAttempt?.sid == expectedSID)
        #expect(try await store.dynamicPairingRoundCount() == 2)
        let expectedCPace = try CPace(
            role: .responder,
            prs: Data(fixture.digitsCode.utf8),
            sid: expectedSID,
            scalarOverride: dataFromHex(fixture.scalarB)
        )
        #expect(await connection.dynamicPairingAttempt?.cpace?.publicShare == expectedCPace.publicShare)
        await next.client.disconnect()
    }

    @Test("a second attempt on the same connection starts at round one")
    func secondAttemptOnSameConnectionUsesRoundOne() async throws {
        let fixture = try dynamicFixture()
        let session = try await makeDynamicTestSession(
            nonceBOverride: dataFromHex(fixture.nonceB),
            pairingHandshakeHashOverride: dataFromHex(fixture.handshakeHash)
        )
        _ = try await dynamicServerTranscript(session, badServerConfirmation: true)
        _ = try await waitForClientMessage(session.server, type: ClientPairRetryMessage.typeString)
        #expect(try await session.store.dynamicPairingRoundCount() == 1)
        let firstID = try #require(session.client.currentPairing?.id)
        try await session.client.cancelPairing(attemptID: firstID)
        _ = try await waitForClientMessage(session.server, type: PairAbortMessage.typeString)
        try await activateDynamic(session.server)
        let initData = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString, count: 2)
        let pairInit = try JSONDecoder().decode(ClientPairInitMessage.self, from: initData)
        let expectedPairingIndex: UInt32 = 2
        let expectedRound: UInt32 = 1
        #expect(pairInit.payload.pairingIndex == expectedPairingIndex)
        try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(ServerPairInitMessage(
            payload: ServerPairInitPayload(nonceA: Base64URL.encode(dataFromHex(fixture.nonceA)))
        )), encoding: .utf8)))
        _ = try #require(await codeEvent(session.events))
        let connection = try #require(session.client.connection)
        let expectedSID = CPaceSessionIdentifier.make(
            handshakeHash: dataFromHex(fixture.handshakeHash),
            counter: expectedPairingIndex,
            round: expectedRound
        )
        #expect(await connection.dynamicPairingAttempt?.sid == expectedSID)
        #expect(try await session.store.dynamicPairingRoundCount() == 2)
        await session.client.disconnect()
    }

    @Test("duplicate server pair-init before auth closes silently without charging", arguments: [false, true])
    func duplicatePairInitBeforeAuthClosesSilently(afterRetry: Bool) async throws {
        let session = try await makeDynamicTestSession()
        if afterRetry {
            _ = try await dynamicServerTranscript(session, badServerConfirmation: true)
            _ = try await waitForClientMessage(session.server, type: ClientPairRetryMessage.typeString)
        } else {
            try await activateDynamic(session.server)
            _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        }
        let nonceA = afterRetry ? nil : Base64URL.encode(Psk.generate().bytes)
        try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(ServerPairInitMessage(
            payload: ServerPairInitPayload(nonceA: nonceA)
        )), encoding: .utf8)))
        _ = try #require(await codeEvent(session.events))
        let budgetBeforeDuplicate = try await session.store.dynamicPairingRoundCount()
        let authCount = await session.server.clientJSONMessages(ofType: ClientPairAuthMessage.typeString).count
        try await session.server.sendJSON(#"{"type":"server/pair-init","payload":{}}"#)
        #expect(await waitUntil { await session.server.disconnectCalled })
        #expect(try await session.store.dynamicPairingRoundCount() == budgetBeforeDuplicate)
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).isEmpty)
        #expect(await session.server.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).isEmpty)
        #expect(await session.server.clientJSONMessages(ofType: ClientPairAuthMessage.typeString).count == authCount)
        await session.client.disconnect()
    }

    @Test("server pair-init accepts an empty payload and ignores an unknown field")
    func pairInitDecodingIgnoresUnknownFields() throws {
        let plain = try JSONDecoder().decode(ServerPairInitMessage.self, from: Data(#"{"type":"server/pair-init","payload":{}}"#.utf8))
        let encodedNonce = Base64URL.encode(Psk.generate().bytes)
        let extended = try JSONDecoder().decode(
            ServerPairInitMessage.self,
            from: Data("{\"type\":\"server/pair-init\",\"payload\":{\"nonce_A\":\"\(encodedNonce)\",\"x_unknown_field\":{\"unexpected\":true}}}".utf8)
        )
        #expect(plain.payload.nonceA == nil)
        #expect(extended.payload.nonceA == encodedNonce)
    }

    @Test("invalid server confirmation retries with a fresh round and can then succeed")
    func serverConfirmationFailure() async throws {
        let fixture = try dynamicFixture()
        let session = try await makeDynamicTestSession(
            nonceBOverride: dataFromHex(fixture.nonceB),
            pairingHandshakeHashOverride: dataFromHex(fixture.handshakeHash)
        )
        let (emission, _) = try await dynamicServerTranscript(session, badServerConfirmation: true)
        _ = try await waitForClientMessage(session.server, type: ClientPairRetryMessage.typeString)
        #expect(try await session.store.dynamicPairingRoundCount() == 1)
        #expect(await session.server.clientJSONMessages(ofType: ClientPairInitMessage.typeString).count == 1)
        #expect(emission.payload.count == 6)

        let retryEventTask = Task { await codeEvent(session.events) }
        try await session.server.sendJSON(#"{"type":"server/pair-init","payload":{}}"#)
        let retryEmissionEvent = try #require(await retryEventTask.value)
        let retryEmission = try retryEmissionEvent.unwrapEmission()
        #expect(retryEmission.payload == emission.payload)
        #expect(try await session.store.dynamicPairingRoundCount() == 2)
        #expect(await session.server.clientJSONMessages(ofType: ClientPairInitMessage.typeString).count == 1)
        let roundTwoSID = CPaceSessionIdentifier.make(
            handshakeHash: dataFromHex(fixture.handshakeHash),
            counter: fixture.counter,
            round: 2
        )
        let retryCPace = try CPace(
            role: .initiator,
            prs: Data(retryEmission.payload.utf8),
            sid: roundTwoSID,
            scalarOverride: dataFromHex(fixture.scalarA)
        )
        try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(ServerPairAuthMessage(
            payload: ServerPairAuthPayload(pakeMsg1: Base64URL.encode(retryCPace.publicShare))
        )), encoding: .utf8)))
        let retryAuth = try await JSONDecoder().decode(
            ClientPairAuthMessage.self,
            from: waitForClientMessage(session.server, type: ClientPairAuthMessage.typeString, count: 2)
        )
        let retryShare = try #require(Base64URL.decode(retryAuth.payload.pakeMsg2, count: 32))
        let retrySecrets = try retryCPace.derive(remoteShare: retryShare)
        let retryTag = CPaceX25519.mcfTag(
            isk: retrySecrets.isk,
            sid: roundTwoSID,
            share: retryCPace.publicShare,
            associatedData: CPaceX25519.defaultInitiatorAD
        )
        try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(ServerPairConfirmMessage(
            payload: ServerPairConfirmPayload(serverKc: Base64URL.encode(retryTag))
        )), encoding: .utf8)))
        _ = try await waitForClientMessage(session.server, type: ClientPairConfirmMessage.typeString, count: 1)
        _ = try await waitForClientMessage(session.server, type: ClientPairFinalizeMessage.typeString, count: 1)
        #expect(try await session.store.dynamicPairingRoundCount() == 0)
        try await session.server.sendJSON(#"{"type":"server/pair-finalize","payload":{}}"#)
        #expect(await waitUntil { await pairingRecords(session.store).contains { $0.serverId != nil } })
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

        try await server.beginRehandshake(to: .sentinel)
        #expect(await waitUntil { await server.rehandshakeComplete })

        try await activateDynamic(server)
        let secondInitData = try await waitForClientMessage(server, type: ClientPairInitMessage.typeString, count: 2)
        let secondInit = try JSONDecoder().decode(ClientPairInitMessage.self, from: secondInitData)
        #expect(secondInit.payload.pairingIndex == fixture.counter)
        #expect(await MainActor.run { session.client.connectionState == .connected })
        await session.client.disconnect()
    }
}

@MainActor
@Suite("Dynamic pairing budget", .timeLimit(.minutes(1)))
struct DynamicPairingFailureCounterTests {
    @Test("verified confirmation resets the dynamic budget")
    func counterSemantics() async throws {
        let store = InMemoryPairingRecordStore()
        let session = try await makeDynamicTestSession(store: store)
        _ = try await dynamicServerTranscript(session, badServerConfirmation: true)
        _ = try await waitForClientMessage(session.server, type: ClientPairRetryMessage.typeString)
        #expect(try await store.dynamicPairingRoundCount() == 1)
        #expect(await MainActor.run { session.client.connectionState == .connected })
        await session.client.disconnect()

        let successStore = InMemoryPairingRecordStore()
        let success = try await makeDynamicTestSession(store: successStore)
        _ = try await dynamicServerTranscript(success)
        _ = try await waitForClientMessage(success.server, type: ClientPairConfirmMessage.typeString)
        _ = try await waitForClientMessage(success.server, type: ClientPairFinalizeMessage.typeString)
        #expect(try await successStore.dynamicPairingRoundCount() == 0)
        await success.client.disconnect()

        await session.client.disconnect()
    }
}

@MainActor
@Suite("Pairing window", .timeLimit(.minutes(1)))
struct PairingWindowTests {
    @Test("round-limit attempts wait for an operator window and do not start the timeout")
    func roundLimitWaitsForWindow() async throws {
        let store = InMemoryPairingRecordStore()
        for _ in 0 ..< dynamicPairingRoundLimit {
            _ = try await store.reserveDynamicPairingRound(limit: dynamicPairingRoundLimit)
        }
        let session = try await makeDynamicTestSession(store: store, attemptTimeout: .milliseconds(100))
        try await activateDynamic(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        #expect(await session.server.clientJSONMessages(ofType: ClientPairInitMessage.typeString).isEmpty)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).isEmpty)
        let attemptID = try #require(await MainActor.run { session.client.currentPairing?.id })
        try await session.client.openPairingWindow(for: attemptID)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        let refreshedAttemptID = try #require(await MainActor.run { session.client.currentPairing?.id })
        try await session.client.cancelPairing(attemptID: refreshedAttemptID)
        await session.client.disconnect()
    }
}

@MainActor
@Suite("Pairing final fences", .timeLimit(.minutes(1)))
struct PairingFinalFenceTests {
    @Test("reset failure publishes no authorization window or code and disconnects")
    func resetFailureIsTerminalBeforeWindowPublication() async throws {
        let store = FinalFenceStore(initialRounds: dynamicPairingRoundLimit, reset: .throws)
        let session = try await makeDynamicTestSession(store: store)
        try await activateDynamic(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        let attemptID = try #require(session.client.currentPairing?.id)

        await #expect(throws: PairingRecordStoreError.storageExhausted) {
            try await session.client.openPairingWindow(for: attemptID)
        }
        #expect(await waitUntil { await session.server.disconnectCalled })
        #expect(session.client.pairingWindow == nil)
        #expect(session.client.currentPairing?.code == nil)
        #expect(await session.server.clientJSONMessages(ofType: ClientPairInitMessage.typeString).isEmpty)
        await session.client.disconnect()
    }

    @Test("reserve failure at round start publishes no code and disconnects")
    func reserveFailureIsTerminalBeforeWindowPublication() async throws {
        let store = FinalFenceStore(initialRounds: dynamicPairingRoundLimit, reset: .succeeds, reserve: .throwsAfterReset)
        let session = try await makeDynamicTestSession(store: store)
        try await activateDynamic(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        let attemptID = try #require(session.client.currentPairing?.id)

        try await session.client.openPairingWindow(for: attemptID)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(ServerPairInitMessage(
            payload: ServerPairInitPayload(nonceA: Base64URL.encode(Psk.generate().bytes))
        )), encoding: .utf8)))
        #expect(await waitUntil { await session.server.disconnectCalled })
        #expect(session.client.pairingWindow == nil)
        #expect(session.client.currentPairing?.code == nil)
        await session.client.disconnect()
    }

    @Test("cancellation while reset is blocked makes the public open stale")
    func cancellationDuringResetCannotPublishWindow() async throws {
        let store = FinalFenceStore(initialRounds: dynamicPairingRoundLimit, reset: .blocks)
        let session = try await makeDynamicTestSession(store: store)
        try await activateDynamic(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        let attemptID = try #require(session.client.currentPairing?.id)
        let open = Task { () -> Result<Void, Error> in
            do {
                try await session.client.openPairingWindow(for: attemptID)
                return .success(())
            } catch { return .failure(error) }
        }
        #expect(await waitUntil { await store.resetStarted })

        try await session.client.cancelPairing(attemptID: attemptID)
        _ = try await waitForClientMessage(session.server, type: PairAbortMessage.typeString)
        await store.releaseReset()
        let result = await open.value
        guard case let .failure(error) = result else {
            Issue.record("opening a cancelled attempt must not report success")
            await session.client.disconnect()
            return
        }
        #expect(error as? SendspinClientError == .stalePairingAttempt(attemptID))
        #expect(session.client.pairingWindow == nil)
        #expect(await session.server.clientJSONMessages(ofType: ClientPairInitMessage.typeString).isEmpty)
        #expect(await MainActor.run { session.client.connectionState == .connected })
        await session.client.disconnect()
    }

    @Test("retry exhaustion sends a terminal abort and leaves no live attempt")
    func retryExhaustionAbortsTerminally() async throws {
        let store = InMemoryPairingRecordStore()
        for _ in 0 ..< dynamicPairingRoundLimit - 1 {
            _ = try await store.reserveDynamicPairingRound(limit: dynamicPairingRoundLimit)
        }
        let session = try await makeDynamicTestSession(store: store)
        _ = try await dynamicServerTranscript(session, badServerConfirmation: true)

        let abort = try await waitForClientMessage(session.server, type: PairAbortMessage.typeString)
        #expect(try JSONDecoder().decode(PairAbortMessage.self, from: abort).payload.reason == .pairingCodeMismatch)
        #expect(await endedEvent(session.events, reason: .pairingCodeMismatch) != nil)
        #expect(await collectClientEvent(from: session.events, timeout: .milliseconds(100)) {
            if case let .pairingCodeChanged(snapshot) = $0 {
                return snapshot.code == nil
            }
            return false
        } != nil)
        #expect(await MainActor.run { session.client.connectionState == .connected })
        await session.client.disconnect()
    }
}

private enum FinalFenceReset: Sendable {
    case succeeds
    case `throws`
    case blocks
}

private enum FinalFenceReserve: Sendable {
    case succeeds
    case throwsAfterReset
}

private actor FinalFenceStore: PairingRecordStore {
    private var rounds: UInt32
    private let resetMode: FinalFenceReset
    private let reserveMode: FinalFenceReserve
    private var resetContinuation: CheckedContinuation<Void, Never>?
    private(set) var resetStarted = false

    init(
        initialRounds: UInt32 = 0,
        reset: FinalFenceReset = .succeeds,
        reserve: FinalFenceReserve = .succeeds
    ) {
        rounds = initialRounds
        resetMode = reset
        reserveMode = reserve
    }

    func listRecords() async throws -> [PairingRecord] {
        []
    }

    func insertOrReplace(_: PairingRecord) async throws {
        throw PairingRecordStoreError.storageExhausted
    }

    func insertOrReplaceAndProtect(_: PairingRecord) async throws -> PairingRecordProtectionLease {
        throw PairingRecordStoreError.storageExhausted
    }

    func remove(pskId _: String) async throws {}
    func markUsed(pskId _: String) async throws {}
    func storageAccounting() async throws -> PairingStorageAccounting? {
        nil
    }

    func acquireProtection(pskId: String, serverId _: String?) async throws -> PairingRecordProtectionLease {
        PairingRecordProtectionLease(id: UUID(), pskIds: [pskId])
    }

    func releaseProtection(_: PairingRecordProtectionLease) async throws {}
    func dynamicPairingRoundCount() async throws -> UInt32 {
        rounds
    }

    func reserveDynamicPairingRound(limit: UInt32) async throws -> DynamicPairingRoundReservation {
        if reserveMode == .throwsAfterReset, rounds == 0 {
            throw PairingRecordStoreError.storageExhausted
        }
        guard rounds < limit else { return .exhausted }
        rounds += 1
        return .reserved(round: rounds, remaining: limit - rounds)
    }

    func resetDynamicPairingBudget() async throws {
        switch resetMode {
        case .succeeds:
            rounds = 0
        case .throws:
            throw PairingRecordStoreError.storageExhausted
        case .blocks:
            resetStarted = true
            await withCheckedContinuation { resetContinuation = $0 }
            rounds = 0
        }
    }

    func releaseReset() {
        resetContinuation?.resume()
        resetContinuation = nil
    }
}

@MainActor
@Suite("Dynamic pairing protocol errors", .timeLimit(.minutes(1)))
struct DynamicPairingProtocolErrorTests {
    @Test("wrong nonce length silently closes without abort or persistence")
    func wrongLengthNonceClosesSilently() async throws {
        let session = try await makeDynamicTestSession()
        try await activateDynamic(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        try await session.server.sendJSON(#"{"type":"server/pair-init","payload":{"nonce_A":"AA"}}"#)
        #expect(await waitUntil { await session.server.disconnectCalled })
        #expect(try await session.store.dynamicPairingRoundCount() == 0)
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).isEmpty)
        #expect(await pairingRecords(session.store).allSatisfy { $0.serverId == nil })
        await session.client.disconnect()
    }

    @Test("low-order pake share silently closes without abort or counter mutation")
    func lowOrderShareClosesSilently() async throws {
        let session = try await makeDynamicTestSession()
        try await activateDynamic(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        let fixture = try dynamicFixture()
        let pairInit = """
        {"type":"server/pair-init","payload":{"nonce_A":"\(Base64URL.encode(dataFromHex(fixture.nonceA)))"}}
        """
        try await session.server.sendJSON(pairInit)
        try await Task.sleep(for: .milliseconds(20))
        try await session.server.sendJSON(#"{"type":"server/pair-auth","payload":{"pake_msg_1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}"#)
        #expect(await waitUntil { await session.server.disconnectCalled })
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).isEmpty)
        #expect(try await session.store.dynamicPairingRoundCount() == 1)
        await session.client.disconnect()
    }
}

@MainActor
@Suite("Dynamic pairing timeout and admissibility", .timeLimit(.minutes(1)))
struct DynamicPairingTimeoutTests {
    @Test("attempt timeout uses the exact attempt_timeout reason")
    func attemptTimeout() async throws {
        let session = try await makeDynamicTestSession(attemptTimeout: .milliseconds(100))
        await session.server.transport.setHonorCancellationSends(true)
        try await activateDynamic(session.server)
        _ = try await waitForClientMessage(session.server, type: ClientPairInitMessage.typeString)
        let abortData = try await waitForClientMessage(session.server, type: PairAbortMessage.typeString)
        let abort = try JSONDecoder().decode(PairAbortMessage.self, from: abortData)
        #expect(abort.payload.reason.rawValue == "attempt_timeout")
        #expect(await endedEvent(session.events, reason: .attemptTimeout) != nil)
        #expect(await collectClientEvent(from: session.events) {
            if case let .pairingCodeChanged(snapshot) = $0 {
                return snapshot.code == nil
            }
            return false
        } != nil)
        #expect(await pairingRecords(session.store).allSatisfy { $0.serverId == nil })
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
        try await session.server.sendJSON("{\"type\":\"pair/abort\",\"payload\":{\"reason\":\"user_cancelled\"}}")
        // The events stream is single-consumer and the connection enqueues the
        // ended reason before the code clear, so sequential reads are ordered.
        #expect(await endedEvent(session.events, reason: .userCancelled) != nil)
        #expect(await collectClientEvent(from: session.events) {
            if case let .pairingCodeChanged(snapshot) = $0 {
                return snapshot.code == nil
            }
            return false
        } != nil)
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
