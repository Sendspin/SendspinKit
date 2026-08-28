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

private struct StaticTestSession {
    let client: SendspinClient
    let server: MockNoiseServer
    let store: any PairingRecordStore
    let events: AsyncStream<ClientEvent>
}

@MainActor
private func makeStaticTestSession(
    store: (any PairingRecordStore)? = nil,
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
        roles: [],
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
    try await server.establishSession(activities: [], activeRoles: [])
    try await accepted
    #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })
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

private func pairingTypes(_ server: MockNoiseServer) async -> [String] {
    await server.decryptedMessages.compactMap { message in
        guard message.first == NoiseFrameType.json else { return nil }
        return SendspinEncoding.messageType(of: Data(message.dropFirst()))
    }
}

private func staticServerTranscript(_ session: StaticTestSession) async throws -> (Data, Data) {
    let fixture = try staticFixture()
    let initData = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString)
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

@Suite("Static pairing windows", .timeLimit(.minutes(1)))
struct StaticPairingWindowTests {
    @Test("static attempt is pending until the window opens, without starting its timeout")
    func staticAttemptWaitsForWindow() async throws {
        let session = try await makeStaticTestSession(attemptTimeout: .milliseconds(100))
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).isEmpty)
        #expect(await session.server.clientJSONMessages(ofType: ClientPairInitMessage.typeString).isEmpty)
        try await session.client.openPairingWindow()
        let initData = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString)
        let pairInit = try JSONDecoder().decode(ClientPairInitMessage.self, from: initData)
        #expect(pairInit.payload.commitB == nil)
        await session.client.disconnect()
    }

    @Test("a pre-opened window admits static activation directly")
    func preOpenedWindowSendsInitDirectly() async throws {
        let session = try await makeStaticTestSession()
        try await session.client.openPairingWindow()
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString)
        #expect(await session.server.clientJSONMessages(ofType: ClientPairPendingMessage.typeString).isEmpty)
        await session.client.disconnect()
    }

    @Test("an expired window makes a later static activation pending")
    func expiredWindowGatesStaticActivation() async throws {
        let session = try await makeStaticTestSession(windowLifetime: .milliseconds(100))
        try await session.client.openPairingWindow()
        try await Task.sleep(for: .milliseconds(150))
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        #expect(await session.server.clientJSONMessages(ofType: ClientPairInitMessage.typeString).isEmpty)
        await session.client.disconnect()
    }

    @Test("a rejected static activation cancels its attempt and allows a fresh activation")
    func rejectedStaticActivationCleansUpAttempt() async throws {
        let session = try await makeStaticTestSession(attemptTimeout: .milliseconds(100))
        try await session.client.openPairingWindow()
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString)

        let runtime = try #require(await MainActor.run { session.client.pairingConfiguration?.runtime })
        let pairingPsk = await runtime.snapshot().pairingPsk
        await runtime.update(PairingManagementConfiguration(
            pairingPsk: pairingPsk,
            pairingPskEnabled: false,
            recordModePskId: "",
            unpairedAccessEnabled: true,
            staticPairingCodeEnabled: true,
            staticPairingCode: nil
        ))
        try await activateStatic(session.server)
        let firstAbort = try await waitForStaticClientMessage(session.server, type: PairAbortMessage.typeString)
        #expect(try JSONDecoder().decode(PairAbortMessage.self, from: firstAbort).payload.reason == .methodNotSupported)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).count == 1)

        await runtime.update(PairingManagementConfiguration(
            pairingPsk: pairingPsk,
            pairingPskEnabled: false,
            recordModePskId: "",
            unpairedAccessEnabled: true,
            staticPairingCodeEnabled: true,
            staticPairingCode: "12345678"
        ))
        try await session.client.openPairingWindow()
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString)
        #expect(await MainActor.run { session.client.connectionState == .connected })
        await session.client.disconnect()
    }
}

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

    @Test("static transcript sends fixture-exact CPace bytes and wrapped finalize shape")
    func messageShape() async throws {
        let fixture = try staticFixture()
        let session = try await makeStaticTestSession(
            pairingHandshakeHashOverride: dataFromHex(fixture.handshakeHash),
            pairingScalarBOverride: dataFromHex(fixture.scalarB)
        )
        try await activateStatic(session.server)
        try await session.client.openPairingWindow()
        let (confirmData, finalizeData) = try await staticServerTranscript(session)
        let confirm = try JSONDecoder().decode(ClientPairConfirmMessage.self, from: confirmData)
        let finalize = try JSONDecoder().decode(ClientPairFinalizeMessage.self, from: finalizeData)
        #expect(confirm.payload.clientKc == Base64URL.encode(dataFromHex(fixture.clientKc)))
        #expect(confirm.payload.wrappedNonceB == nil)
        #expect(finalize.payload.longTermPsk.isEmpty)
        let wrapped = try #require(finalize.payload.wrappedPsk)
        #expect(wrapped.count == Base64URL.encode(dataFromHex(fixture.wrappedPsk)).count)
        #expect(Base64URL.decode(wrapped, count: 48) != nil)
        #expect(await session.store.listRecords().filter { $0.serverId != nil }.isEmpty)
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
            let records = await session.store.listRecords()
            let serverId = await session.server.serverId
            return records.contains { $0.serverId == serverId }
        })
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
        try await session.client.openPairingWindow()
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
        #expect(await store.dynamicPairingFailureCount() == 0)
        #expect(await store.listRecords().allSatisfy { $0.serverId == nil })
        #expect(await MainActor.run { session.client.connectionState == .connected })
        await session.client.disconnect()
    }
}

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
        try await session.client.openPairingWindow()
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString)
        try await session.server.sendJSON(#"{"type":"server/pair-init","payload":{"nonce_A":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}"#)
        #expect(await waitUntil { await session.server.disconnectCalled })
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).isEmpty)
        #expect(await session.store.listRecords().allSatisfy { $0.serverId == nil })
        #expect(await session.store.dynamicPairingFailureCount() == 0)
        await session.client.disconnect()
    }

    @Test("malformed and low-order static shares silently close")
    func malformedAndLowOrderSharesCloseSilently() async throws {
        for share in ["AA", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"] {
            let session = try await makeStaticTestSession()
            try await activateStatic(session.server)
            try await session.client.openPairingWindow()
            _ = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString)
            try await session.server.sendJSON(#"{"type":"server/pair-auth","payload":{"pake_msg_1":"\#(share)"}}"#)
            #expect(await waitUntil { await session.server.disconnectCalled })
            #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).isEmpty)
            #expect(await session.store.listRecords().allSatisfy { $0.serverId == nil })
            #expect(await session.store.dynamicPairingFailureCount() == 0)
            await session.client.disconnect()
        }
    }
}

@Suite("Static pairing cancellation", .timeLimit(.minutes(1)))
struct PairingCancellationTests {
    @Test("cancelling static activate discards state without changing counter")
    func cancellingActivateDiscardsState() async throws {
        let session = try await makeStaticTestSession()
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        try await session.server.sendJSON(#"{"type":"server/activate","payload":{"activities":[],"active_roles":[]}}"#)
        #expect(await session.store.dynamicPairingFailureCount() == 0)
        #expect(await session.store.listRecords().allSatisfy { $0.serverId == nil })
        await session.client.disconnect()
    }

    @Test("server user cancellation surfaces attempt-ended")
    func serverAbortUserCancelledSurfaces() async throws {
        let session = try await makeStaticTestSession()
        try await activateStatic(session.server)
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString)
        try await session.server.sendJSON(#"{"type":"pair/abort","payload":{"reason":"user_cancelled"}}"#)
        #expect(await collectClientEvent(from: session.events) {
            if case .pairingAttemptEnded(.userCancelled) = $0 {
                return true
            }
            return false
        } != nil)
        #expect(await session.store.dynamicPairingFailureCount() == 0)
        await session.client.disconnect()
    }

    @Test("static attempt timeout sends attempt_timeout")
    func attemptTimeout() async throws {
        let session = try await makeStaticTestSession(attemptTimeout: .milliseconds(100))
        try await activateStatic(session.server)
        try await session.client.openPairingWindow()
        _ = try await waitForStaticClientMessage(session.server, type: ClientPairInitMessage.typeString)
        let abortData = try await waitForStaticClientMessage(session.server, type: PairAbortMessage.typeString)
        let abort = try JSONDecoder().decode(PairAbortMessage.self, from: abortData)
        #expect(abort.payload.reason == .attemptTimeout)
        #expect(await session.store.dynamicPairingFailureCount() == 0)
        #expect(await session.store.listRecords().allSatisfy { $0.serverId == nil })
        await session.client.disconnect()
    }
}

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
        let helloCount = await session.server.clientJSONMessages(ofType: ClientHelloMessage.typeString).count
        try await session.server.beginRehandshake(to: .sentinel)
        #expect(await waitUntil { await session.server.rehandshakeComplete })
        try await session.server.sendJSON(#"{"type":"server/hello","payload":{"name":"Test Server"}}"#)
        #expect(await waitUntil {
            await session.server.clientJSONMessages(ofType: ClientHelloMessage.typeString).count == helloCount + 1
        })
        try await activateStatic(session.server)
        let pendingData = try await waitForStaticClientMessage(session.server, type: ClientPairPendingMessage.typeString, count: 2)
        let pending = try JSONDecoder().decode(ClientPairPendingMessage.self, from: pendingData)
        #expect(pending.payload.pairingIndex == fixture.counter)
        await session.client.disconnect()
    }
}
