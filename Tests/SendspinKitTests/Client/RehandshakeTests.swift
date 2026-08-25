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
        let store: any PairingRecordStore
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
        seededLongTermPsk: Psk? = nil,
        seededLongTermShared: Bool = false,
        initialPsk: Psk = .sentinel,
        store suppliedStore: (any PairingRecordStore)? = nil,
        pairingAttemptTimeout: Duration = .seconds(120)
    ) async throws -> Session {
        let pairingPsk = Psk.generate()
        let store: any PairingRecordStore = suppliedStore ?? InMemoryPairingRecordStore(pairingPsk: pairingPsk)
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
            pairing: PairingConfiguration(pairingPsk: pairingPsk, store: store),
            audioOutputCapabilityProvider: AudioOutputCapabilityService(),
            pairingAttemptTimeout: pairingAttemptTimeout
        )
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport, psk: initialPsk)
        if let seededLongTermPsk {
            try await store.insert(
                PairingRecord(psk: seededLongTermPsk, serverId: seededLongTermShared ? nil : server.serverId)
            )
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
        #expect(await session.store.listRecords().first?.used == true)

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

    @Test("Pairing attempt timeout aborts without persistence")
    func pairingAttemptTimeoutAbortsWithoutPersistence() async throws {
        let session = try await makePairableSession(pairingAttemptTimeout: .milliseconds(100))
        let server = session.server

        try await rehandshake(server, to: session.pairingPsk)
        try await server.sendJSON(
            #"{"type":"server/activate","payload":{"activities":["pairing"],"active_roles":[],"pairing":{"method":"pairing_psk"}}}"#
        )
        #expect(await waitUntil {
            await server.clientJSONMessages(ofType: PairAbortMessage.typeString).count == 1
        }, "the pending attempt must expire")
        let abort = try #require(await server.clientJSONMessages(ofType: PairAbortMessage.typeString).first)
        #expect(try JSONDecoder().decode(PairAbortMessage.self, from: abort).payload.reason == .attemptTimeout)
        #expect(await session.store.listRecords().isEmpty)
        #expect(await session.client.connectionState == .connected)
        await session.client.disconnect()
    }

    @Test("Malformed transport-mode noise handshake closes silently")
    func malformedTransportNoiseHandshakeClosesSilently() async throws {
        let session = try await makePairableSession()
        let server = session.server
        let goodbyesBefore = await server.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).count

        try await server.sendJSON(#"{"type":"noise/handshake","payload":{"data":123}}"#)
        #expect(await waitUntil { await session.client.connectionState == .disconnected })
        #expect(await server.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).count == goodbyesBefore)
    }

    @Test("Rejected post-swap pairing leaves state unchanged and reopens sends")
    func rejectedPostSwapPairingReopensGate() async throws {
        let session = try await makePairableSession(activities: [.playback], activeRoles: [.playerV1])
        let server = session.server

        try await rehandshake(server, to: .sentinel)
        try await server.sendJSON(
            #"{"type":"server/activate","payload":{"activities":["pairing"],"active_roles":[],"pairing":{"method":"dynamic_pairing_code"}}}"#
        )
        #expect(await waitUntil {
            await server.clientJSONMessages(ofType: PairAbortMessage.typeString).count == 1
        })
        #expect(await session.client.connectionState == .connected)
        #expect(await session.client.connection?.isRehandshakeInProgress == false)
        await session.client.disconnect()
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

    @Test("Cancelling pairing discards the attempt and ignores a late finalize")
    func cancellingPairingDiscardsLateFinalize() async throws {
        // On a Pairing PSK session the only admissible activity set is ['pairing'],
        // so a server cancels by re-handshaking away — which discards all pairing
        // state — rather than by activating something else.
        let session = try await makePairableSession()
        let server = session.server

        try await rehandshake(server, to: session.pairingPsk)
        try await server.sendJSON(
            #"{"type":"server/activate","payload":{"activities":["pairing"],"active_roles":[],"pairing":{"method":"pairing_psk"}}}"#
        )
        #expect(await waitUntil {
            await server.clientJSONMessages(ofType: ClientPairFinalizeMessage.typeString).count == 1
        })

        // The server abandons the attempt: back to the sentinel PSK, then a plain
        // empty activation. The pending PSK must be gone, so the late finalize
        // that follows persists nothing.
        try await rehandshake(server, to: .sentinel)
        try await server.sendActivation(activities: [], activeRoles: [])
        try await server.sendJSON(#"{"type":"server/pair-finalize","payload":{}}"#)

        #expect(await !waitUntil(timeout: .milliseconds(300)) { await !session.store.listRecords().isEmpty })
        #expect(await MainActor.run { session.client.connectionState == .connected })
        await session.client.disconnect()
    }

    @Test("Server unpair removes bound records, keeps shared records, and ignores sentinel sessions")
    func serverUnpairTranscript() async throws {
        let boundPsk = Psk.generate()
        let bound = try await makePairableSession(
            seededLongTermPsk: boundPsk,
            initialPsk: boundPsk
        )
        let boundServer = bound.server
        try await boundServer.sendJSON(#"{"type":"server/unpair","payload":{}}"#)
        #expect(await waitUntil { await MainActor.run { bound.client.connectionState == .disconnected } })
        #expect(await bound.store.listRecords().isEmpty)
        let boundGoodbye = try #require(await boundServer.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).first)
        #expect(try JSONDecoder().decode(ClientGoodbyeMessage.self, from: boundGoodbye).payload.reason == .unpaired)

        let sharedPsk = Psk.generate()
        let shared = try await makePairableSession(
            seededLongTermPsk: sharedPsk,
            seededLongTermShared: true,
            initialPsk: sharedPsk
        )
        let sharedServer = shared.server
        try await sharedServer.sendJSON(#"{"type":"server/unpair","payload":{}}"#)
        #expect(await waitUntil { await MainActor.run { shared.client.connectionState == .disconnected } })
        #expect(await shared.store.listRecords().count == 1)
        let sharedGoodbye = try #require(await sharedServer.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).first)
        #expect(try JSONDecoder().decode(ClientGoodbyeMessage.self, from: sharedGoodbye).payload.reason == .unpaired)

        let sentinel = try await makePairableSession()
        let sentinelServer = sentinel.server
        try await sentinelServer.sendJSON(#"{"type":"server/unpair","payload":{}}"#)
        #expect(await !waitUntil(timeout: .milliseconds(300)) {
            await MainActor.run { sentinel.client.connectionState == .disconnected }
        })
        #expect(await sentinel.store.listRecords().isEmpty)
        #expect(await !waitUntil(timeout: .milliseconds(300)) {
            await sentinelServer.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).count > 0
        })
        await sentinel.client.disconnect()
    }

    @Test("Sentinel pairing activation aborts without a pair finalize")
    func sentinelPairingObligationTwoTranscript() async throws {
        let session = try await makePairableSession()
        let server = session.server
        try await server.sendJSON(
            #"{"type":"server/activate","payload":{"activities":["pairing"],"active_roles":[],"pairing":{"method":"pairing_psk"}}}"#
        )

        #expect(await waitUntil {
            await server.clientJSONMessages(ofType: PairAbortMessage.typeString).count == 1
        })
        let abort = try #require(await server.clientJSONMessages(ofType: PairAbortMessage.typeString).first)
        #expect(try JSONDecoder().decode(PairAbortMessage.self, from: abort).payload.reason == .methodNotSupported)
        #expect(await !waitUntil(timeout: .milliseconds(300)) {
            await !server.clientJSONMessages(ofType: ClientPairFinalizeMessage.typeString).isEmpty
        })
        #expect(await MainActor.run { session.client.connectionState == .connected })
        await session.client.disconnect()
    }

    @Test("Pairing persistence failure terminates the connection")
    func pairingPersistenceFailureTerminatesConnection() async throws {
        let session = try await makePairableSession(store: ThrowingPairingRecordStore())
        let server = session.server

        try await rehandshake(server, to: session.pairingPsk)
        try await server.sendJSON(
            #"{"type":"server/activate","payload":{"activities":["pairing"],"active_roles":[],"pairing":{"method":"pairing_psk"}}}"#
        )
        #expect(await waitUntil {
            await server.clientJSONMessages(ofType: ClientPairFinalizeMessage.typeString).count == 1
        })
        try await server.sendJSON(#"{"type":"server/pair-finalize","payload":{}}"#)
        #expect(await waitUntil { await MainActor.run { session.client.connectionState == .disconnected } })
    }
}

private actor ThrowingPairingRecordStore: PairingRecordStore {
    func listRecords() async -> [PairingRecord] {
        []
    }

    func insert(_: PairingRecord) async throws {
        throw PairingRecordStoreError.duplicatePskId
    }

    func remove(pskId _: String) async {}

    func markUsed(pskId _: String) async {}
}
