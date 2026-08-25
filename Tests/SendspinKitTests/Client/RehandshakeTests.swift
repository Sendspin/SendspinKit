import CryptoKit
import Foundation
@testable import SendspinKit
import Testing

/// The in-band re-handshake against a genuine Noise initiator: key promotion for
/// pairing, the hard key-swap boundary, and the write gate around the exchange.
@Suite("In-band re-handshake", .timeLimit(.minutes(1)))
struct RehandshakeTests {
    struct Session {
        let client: SendspinClient
        let server: MockNoiseServer
        let store: InMemoryPairingRecordStore
        let pairingPsk: Psk
    }

    /// A facade session established on the sentinel PSK, with a pairing
    /// configuration whose Pairing PSK the mock server also holds. When
    /// `seededLongTermPsk` is set, a stored-pubkey record bound to the mock server
    /// is pre-seeded so tests can promote straight to a long-term session.
    @MainActor
    private func makePairableSession(
        activities: Set<Activity> = [.playback],
        activeRoles: [VersionedRole] = [.playerV1],
        seededLongTermPsk: Psk? = nil
    ) async throws -> Session {
        let pairingPsk = Psk.generate()
        let store = InMemoryPairingRecordStore(pairingPsk: pairingPsk)
        let playerConfig = try PlayerConfiguration(
            bufferCapacity: 1_024,
            supportedFormats: [
                AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
            ]
        )
        let client = try SendspinClient(
            identity: .generate(),
            name: "Rehandshake Client",
            roles: [.playerV1],
            playerConfig: playerConfig,
            pairing: PairingConfiguration(pairingPsk: pairingPsk, store: store)
        )
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport, psk: .sentinel)
        if let seededLongTermPsk {
            try await store.insert(PairingRecord(psk: seededLongTermPsk, serverId: server.serverId))
        }
        async let accepted: Void = client.acceptConnection(transport)
        try await server.establishSession(activities: activities, activeRoles: activeRoles)
        try await accepted
        #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })
        return Session(client: client, server: server, store: store, pairingPsk: pairingPsk)
    }

    /// Drive one re-handshake and the post-swap `server/hello`, returning once the
    /// client's fresh `client/hello` is on the wire.
    private func rehandshake(
        _ server: MockNoiseServer,
        to psk: Psk,
        mintStaleFrame: Bool = false
    ) async throws {
        let helloCountBefore = await server.clientJSONMessages(ofType: ClientHelloMessage.typeString).count
        try await server.beginRehandshake(to: psk, mintStaleFrame: mintStaleFrame)
        #expect(await waitUntil { await server.rehandshakeComplete })
        try await server.sendJSON(#"{"type":"server/hello","payload":{"name":"Test Server"}}"#)
        #expect(await waitUntil {
            await server.clientJSONMessages(ofType: ClientHelloMessage.typeString).count == helloCountBefore + 1
        })
    }

    private func trustLevel(inHello hello: Data) throws -> String {
        let object = try #require(JSONSerialization.jsonObject(with: hello) as? [String: Any])
        let payload = try #require(object["payload"] as? [String: Any])
        return try #require(payload["trust_level"] as? String)
    }

    @Test("Pairing promotion: sentinel to pairing PSK to persisted long-term PSK")
    func pairingPromotionEndToEnd() async throws {
        let session = try await makePairableSession()
        let server = session.server

        try await rehandshake(server, to: session.pairingPsk)
        try await server.sendJSON(
            #"{"type":"server/activate","payload":{"activities":["pairing"],"active_roles":[],"pairing":{"method":"pairing_psk"}}}"#
        )

        #expect(await waitUntil {
            await server.clientJSONMessages(ofType: ClientPairFinalizeMessage.typeString).count == 1
        })
        let finalizeData = await server.clientJSONMessages(ofType: ClientPairFinalizeMessage.typeString)[0]
        let finalize = try JSONDecoder().decode(ClientPairFinalizeMessage.self, from: finalizeData)
        let longTermPsk = try #require(try Psk(base64URL: #require(finalize.payload.longTermPsk)))

        // Nothing persists until the server acknowledges.
        #expect(await session.store.listRecords().isEmpty)
        try await server.sendJSON(#"{"type":"server/pair-finalize","payload":{}}"#)
        #expect(await waitUntil { await !session.store.listRecords().isEmpty })
        let record = try #require(await session.store.listRecords().first)
        #expect(record.psk == longTermPsk)
        #expect(await record.serverId == server.serverId)

        // Promotion to the delivered long-term PSK; the fresh hello asserts user trust.
        try await rehandshake(server, to: longTermPsk)
        let hellos = await server.clientJSONMessages(ofType: ClientHelloMessage.typeString)
        #expect(try trustLevel(inHello: #require(hellos.last)) == TrustLevel.user.rawValue)

        let timeCountBeforeActivate = await server.clientJSONMessages(ofType: ClientTimeMessage.typeString).count
        try await server.sendActivation(activities: [.playback], activeRoles: [.playerV1])
        #expect(await waitUntil { await MainActor.run { session.client.trustLevel == .user } })
        // Traffic resumes under the new keys: the count must GROW past the
        // pre-activate baseline (a player's client/state waits for sync, so
        // clock-sync traffic is the readiness signal here).
        #expect(await waitUntil {
            await server.clientJSONMessages(ofType: ClientTimeMessage.typeString).count > timeCountBeforeActivate
        })
        await session.client.disconnect()
    }

    @Test("The key swap is a hard boundary: pre-swap frames kill the session")
    func oldKeysAreDeadAfterSwap() async throws {
        let session = try await makePairableSession()
        let server = session.server

        try await rehandshake(server, to: session.pairingPsk, mintStaleFrame: true)
        try await server.sendJSON(
            #"{"type":"server/activate","payload":{"activities":["pairing"],"active_roles":[],"pairing":{"method":"pairing_psk"}}}"#
        )
        #expect(await waitUntil {
            await server.clientJSONMessages(ofType: ClientPairFinalizeMessage.typeString).count == 1
        })
        #expect(await server.staleFrames.isEmpty == false)

        await server.deliverStaleFrames()
        #expect(
            await waitUntil { await MainActor.run { session.client.connectionState == .disconnected } },
            "a frame under retired keys must fail AEAD and end the session"
        )
    }

    @Test("A psk_id lookup miss on re-handshake closes silently")
    func pskLookupMissClosesSilently() async throws {
        let session = try await makePairableSession()
        let server = session.server
        let goodbyesBefore = await server.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).count

        try await server.beginRehandshake(to: Psk.generate(), pskIdOverride: Psk.generate().pskId)
        #expect(await waitUntil { await MainActor.run { session.client.connectionState == .disconnected } })
        #expect(await !server.rehandshakeComplete)
        #expect(
            await server.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).count == goodbyesBefore,
            "handshake-phase failures close without an application-level message"
        )
    }

    @Test("Application sends are gated until the post-swap activation")
    func writeGateHoldsUntilActivation() async throws {
        let longTermPsk = Psk.generate()
        let session = try await makePairableSession(seededLongTermPsk: longTermPsk)
        let server = session.server
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)

        try await rehandshake(server, to: longTermPsk)
        // Between the swap and the post-swap activate, application sends are rejected.
        await #expect(throws: SendspinClientError.self) {
            try await session.client.requestPlayerFormat(format)
        }

        let timeCountBeforeActivate = await server.clientJSONMessages(ofType: ClientTimeMessage.typeString).count
        try await server.sendActivation(activities: [.playback], activeRoles: [.playerV1])
        #expect(await waitUntil {
            await server.clientJSONMessages(ofType: ClientTimeMessage.typeString).count > timeCountBeforeActivate
        })
        try await session.client.requestPlayerFormat(format)
        #expect(await waitUntil {
            await server.clientJSONMessages(ofType: StreamRequestFormatMessage.typeString).count == 1
        })
        await session.client.disconnect()
    }

    @Test("Post-swap wire order: hello first, client traffic only after activation")
    func postSwapSequencing() async throws {
        let longTermPsk = Psk.generate()
        let session = try await makePairableSession(seededLongTermPsk: longTermPsk)
        let server = session.server

        try await rehandshake(server, to: longTermPsk)
        // Give any stray sender time to violate the gate before asserting silence.
        try await Task.sleep(for: .milliseconds(60))

        let messages = await server.decryptedMessages.compactMap { message -> String? in
            guard message.first == NoiseFrameType.json else { return nil }
            return SendspinEncoding.messageType(of: Data(message.dropFirst()))
        }
        let replyIndex = try #require(messages.lastIndex(of: NoiseHandshakeMessage.typeString))
        let tail = Array(messages[(replyIndex + 1)...])
        #expect(
            tail == [ClientHelloMessage.typeString],
            "between the key swap and the post-swap activate, only client/hello may flow"
        )

        try await server.sendActivation(activities: [.playback], activeRoles: [.playerV1])
        #expect(
            await waitUntil {
                await server.clientJSONMessages(ofType: ClientTimeMessage.typeString).count >= 1
            },
            "clock-sync traffic resumes after the post-swap activation"
        )
        await session.client.disconnect()
    }
}
