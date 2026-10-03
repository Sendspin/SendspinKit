import Foundation
@testable import SendspinKit
import Testing

@Suite("Spoken pairing", .timeLimit(.minutes(1)))
@MainActor
struct SpokenPairingTests {
    @Test("speaker emits digits without server audio")
    func speakerEmitsCodeWithoutClips() async throws {
        try await assertSpeakerEmission()
    }

    @Test("speaker emission defaults to no language hint when hello omits languages")
    func speakerEmitsCodeWithoutLanguages() async throws {
        try await assertSpeakerEmission(languages: nil)
    }

    @Test("speaker emits after re-handshake and pairing index restarts")
    func speakerEmitsCodeAfterRehandshake() async throws {
        try await assertSpeakerEmission(rehandshake: true)
    }

    @Test("reserved core binary ID is ignored after activation", arguments: BinaryMessageType.reservedCoreIDs)
    func reservedBinaryIDDoesNotDisconnect(id: UInt8) async throws {
        try await assertSpeakerEmission(reservedID: id)
    }

    private func assertSpeakerEmission(
        reservedID: UInt8? = nil,
        languages: [String]? = ["ca", "es", "en"],
        rehandshake: Bool = false
    ) async throws {
        let device = SendspinDevice.ephemeral()
        let client = try SendspinClient(device: device, name: "Spoken Pairing", roles: [], pairing: .speaker, access: .pairedOnly)
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport, psk: .sentinel)
        let events = client.events()
        async let accepted: Void = client.acceptConnection(transport)
        try await server.respondToHandshake()
        let hello = ServerHelloMessage(payload: ServerHelloPayload(name: "Spoken Server", languages: languages))
        try await server.sendJSON(#require(String(bytes: JSONEncoder().encode(hello), encoding: .utf8)))
        _ = try await server.nextClientJSON()
        await server.startReadback()
        try await server.sendActivation(activities: [], activeRoles: [])
        try await accepted
        let activation = ServerActivateMessage(payload: ServerActivatePayload(
            activities: [.pairing],
            activeRoles: [],
            pairing: PairingDirective(method: PairMethod.dynamicPairingCode, format: PairingCodeFormat.digits.rawValue)
        ))
        try await server.sendJSON(#require(String(bytes: JSONEncoder().encode(activation), encoding: .utf8)))
        #expect(await waitUntil { await server.clientJSONMessages(ofType: ClientPairInitMessage.typeString).count == 1 })
        if rehandshake {
            let connection = try #require(client.connection)
            #expect(await connection.pairingActivateCounter == 1)
            #expect(client.currentPairing?.code == nil)
            try await server.beginRehandshake(to: .sentinel)
            #expect(await waitUntil { await server.rehandshakeComplete })
            #expect(await connection.pairingActivateCounter == 0)
            try await server.sendJSON(#require(String(bytes: JSONEncoder().encode(activation), encoding: .utf8)))
            #expect(await waitUntil { await server.clientJSONMessages(ofType: ClientPairInitMessage.typeString).count == 2 })
            let data = try #require(await server.clientJSONMessages(ofType: ClientPairInitMessage.typeString).last)
            let initMessage = try JSONDecoder().decode(ClientPairInitMessage.self, from: data)
            #expect(initMessage.payload.pairingIndex == 1)
            #expect(await server.rehandshakeComplete)
        }
        if let reservedID {
            await server.injectBinary(Data([reservedID]))
        }
        let nonce = Base64URL.encode(Data(repeating: 0, count: 32))
        let pairInit = ServerPairInitMessage(payload: ServerPairInitPayload(nonceA: nonce))
        try await server.sendJSON(#require(String(bytes: JSONEncoder().encode(pairInit), encoding: .utf8)))
        let event = try #require(await collectClientEvent(from: events, timeout: .seconds(3)) {
            if case let .pairingCodeChanged(snapshot) = $0 {
                return snapshot.code != nil
            }
            return false
        })
        guard case let .pairingCodeChanged(snapshot) = event else {
            Issue.record("Expected pairing code emission")
            await client.disconnect()
            return
        }
        let emission = try #require(snapshot.code)
        #expect(emission.format == .digits)
        #expect(emission.languages == (languages ?? []))
        if rehandshake {
            #expect(await server.rehandshakeComplete)
        }
        #expect(emission.payload.utf8.count == 6)
        #expect(emission.payload.utf8.allSatisfy { (48 ... 57).contains($0) })
        #expect(await !server.disconnectCalled)
        await client.disconnect()
    }
}
