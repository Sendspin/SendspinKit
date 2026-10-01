import CryptoKit
import Foundation
@testable import SendspinKit
import Testing

private func rehandshakeServerID(_ seed: Int) -> String {
    Base64URL.encode(Data(repeating: UInt8(seed & 0xFF), count: 32))
}

private func pairingRecords(_ store: any PairingRecordStore) async -> [PairingRecord] {
    do {
        return try await store.listRecords()
    } catch {
        Issue.record("Pairing record listing failed: \(error)")
        return []
    }
}

/// The in-band re-handshake against a genuine Noise initiator: key promotion for
/// pairing, the hard key-swap boundary, and the write gate around the exchange.
@Suite("In-band re-handshake", .timeLimit(.minutes(1)))
struct RehandshakeTests {
    struct Session {
        let client: SendspinClient
        let server: MockNoiseServer
        let store: any PairingRecordStore
        let pairingPsk: Psk
        let runtime: PairingConfigurationRuntime
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
        pairingPsk suppliedPairingPsk: Psk? = nil,
        serverStaticKey: Curve25519.KeyAgreement.PrivateKey = .init(),
        pairingEnabled: Bool = true,
        initialPsk: Psk = .sentinel,
        store suppliedStore: (any PairingRecordStore)? = nil,
        pairingAttemptTimeout: Duration = .seconds(120)
    ) async throws -> Session {
        let pairingPsk = suppliedPairingPsk ?? Psk.generate()
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
            pairing: PairingConfiguration(pairingPsk: pairingPsk, store: store, enabled: pairingEnabled),
            audioOutputCapabilityProvider: AudioOutputCapabilityService(),
            pairingAttemptTimeout: pairingAttemptTimeout
        )
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport, staticKey: serverStaticKey, psk: initialPsk)
        if let seededLongTermPsk {
            try await store.insertOrReplace(
                PairingRecord(psk: seededLongTermPsk, serverId: seededLongTermShared ? nil : server.serverId)
            )
        }
        async let accepted: Void = client.acceptConnection(transport)
        try await server.establishSession(activities: activities, activeRoles: activeRoles)
        try await accepted
        #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })
        let runtime = try #require(await MainActor.run { client.pairingConfiguration?.runtime })
        return Session(client: client, server: server, store: store, pairingPsk: pairingPsk, runtime: runtime)
    }

    /// Drive one re-handshake to the new-key activation boundary.
    private func rehandshake(
        _ server: MockNoiseServer,
        to psk: Psk,
        pskCategory: PskCategory? = nil,
        mintStaleFrame: Bool = false
    ) async throws {
        let helloCountBefore = await server.clientJSONMessages(ofType: ClientHelloMessage.typeString).count
        try await server.beginRehandshake(
            to: psk,
            pskCategoryOverride: pskCategory,
            mintStaleFrame: mintStaleFrame
        )
        #expect(await waitUntil { await server.rehandshakeComplete })
        #expect(await server.clientJSONMessages(ofType: ClientHelloMessage.typeString).count == helloCountBefore)
    }

    @Test("Re-handshake omits a pairing method disabled at runtime")
    func rehandshakeUsesLiveDisabledPairingAdvertisement() async throws {
        let session = try await makePairableSession()
        let runtime = session.runtime
        let current = await runtime.snapshot()
        await runtime.update(PairingManagementConfiguration(
            pairingPsk: current.pairingPsk,
            pairingPskEnabled: false,
            unpairedAccessEnabled: current.unpairedAccessEnabled
        ))

        try await rehandshake(session.server, to: .sentinel)
        let connection = try #require(await session.client.connection)
        #expect(await waitUntil { await connection.awaitingRehandshakeActivation })
        #expect(await connection.sessionContext.offeredPairMethods.isEmpty)
        try await session.server.sendActivation(activities: [], activeRoles: [])
        await session.client.disconnect()
    }

    @Test("Re-handshake enables pairing admission from a disabled session")
    func rehandshakeUsesLiveEnabledPairingAdvertisementAndAdmission() async throws {
        let session = try await makePairableSession(pairingEnabled: false)
        let runtime = session.runtime
        let current = await runtime.snapshot()
        await runtime.update(PairingManagementConfiguration(
            pairingPsk: current.pairingPsk,
            pairingPskEnabled: true,
            unpairedAccessEnabled: current.unpairedAccessEnabled
        ))

        try await rehandshake(session.server, to: session.pairingPsk)
        let connection = try #require(await session.client.connection)
        #expect(await waitUntil { await connection.awaitingRehandshakeActivation })
        #expect(await connection.sessionContext.offeredPairMethods == [PairMethod.pairingPsk])
        try await session.server.sendJSON(
            #"{"type":"server/activate","payload":{"activities":["pairing"],"active_roles":[],"pairing":{"method":"pairing_psk"}}}"#
        )
        #expect(await waitUntil {
            await session.server.clientJSONMessages(ofType: ClientPairFinalizeMessage.typeString).count == 1
        })
        await session.client.disconnect()
    }

    @Test("Pairing promotion: sentinel to pairing PSK to persisted long-term PSK")
    func pairingPromotionEndToEnd() async throws {
        let session = try await makePairableSession()
        let server = session.server
        let serverId = await server.serverId

        try await rehandshake(server, to: session.pairingPsk)
        try await server.sendJSON(
            #"{"type":"server/activate","payload":{"activities":["pairing"],"active_roles":[],"pairing":{"method":"pairing_psk"}}}"#
        )

        #expect(await waitUntil {
            await server.clientJSONMessages(ofType: ClientPairFinalizeMessage.typeString).count == 1
        })
        let finalizeData = await server.clientJSONMessages(ofType: ClientPairFinalizeMessage.typeString)[0]
        let finalize = try JSONDecoder().decode(ClientPairFinalizeMessage.self, from: finalizeData)
        let longTermPsk = try #require(Psk(base64URL: finalize.payload.longTermPsk))

        // The pending pairing PSK is not durable until the server acknowledges finalize.
        #expect(await pairingRecords(session.store).allSatisfy { $0.serverId == nil })
        try await server.sendJSON(#"{"type":"server/pair-finalize","payload":{}}"#)
        #expect(await waitUntil { await pairingRecords(session.store).contains { $0.serverId == serverId } })
        let record = try #require(await pairingRecords(session.store).first { $0.serverId == serverId })
        #expect(record.psk == longTermPsk)

        // Promotion to the delivered long-term PSK marks the record as used.
        try await rehandshake(server, to: longTermPsk, pskCategory: .longTerm)
        #expect(await pairingRecords(session.store).first { $0.serverId == serverId }?.used == true)

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

    @Test("A wrong-category PSK reference on re-handshake closes silently")
    func wrongCategoryLookupMissClosesSilently() async throws {
        let session = try await makePairableSession()
        let server = session.server
        let goodbyesBefore = await server.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).count

        try await server.beginRehandshake(
            to: session.pairingPsk,
            pskCategoryOverride: .longTerm
        )
        #expect(await waitUntil { await MainActor.run { session.client.connectionState == .disconnected } })
        #expect(await !server.rehandshakeComplete)
        #expect(
            await server.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).count == goodbyesBefore,
            "handshake-phase failures close without an application-level message"
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

    /// Timeout cleanup must leave the abort sender uncancelled; the
    /// cancellation-aware mock rejects a send that arrives pre-cancelled.
    @Test("Pairing attempt timeout aborts without persistence")
    func pairingAttemptTimeoutAbortsWithoutPersistence() async throws {
        let session = try await makePairableSession(pairingAttemptTimeout: .milliseconds(100))
        let server = session.server
        await server.transport.setHonorCancellationSends(true)

        try await rehandshake(server, to: session.pairingPsk)
        try await server.sendJSON(
            #"{"type":"server/activate","payload":{"activities":["pairing"],"active_roles":[],"pairing":{"method":"pairing_psk"}}}"#
        )
        #expect(
            await waitUntil(timeout: .seconds(3)) {
                await server.clientJSONMessages(ofType: PairAbortMessage.typeString).count == 1
            },
            "the pending attempt must expire AND the intentional pair/abort must reach the server"
        )
        let abort = try #require(await server.clientJSONMessages(ofType: PairAbortMessage.typeString).first)
        #expect(try JSONDecoder().decode(PairAbortMessage.self, from: abort).payload.reason == .attemptTimeout)
        #expect(await pairingRecords(session.store).allSatisfy { $0.serverId == nil }, "a timed-out attempt must not persist")
        #expect(await MainActor.run { session.client.connectionState == .connected })
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
        #expect(await MainActor.run { session.client.connectionState == ConnectionState.connected })
        #expect(await session.client.connection?.isRehandshakeInProgress == false)
        await session.client.disconnect()
    }

    @Test("Application sends are gated until the post-swap activation")
    func writeGateHoldsUntilActivation() async throws {
        let longTermPsk = Psk.generate()
        let session = try await makePairableSession(seededLongTermPsk: longTermPsk)
        let server = session.server
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)

        try await rehandshake(server, to: longTermPsk, pskCategory: .longTerm)
        // Between the swap and the post-swap activate, application sends are rejected.
        await #expect(throws: SendspinClientError.self) {
            try await session.client.setPlayerFormatPreference(format)
        }

        let timeCountBeforeActivate = await server.clientJSONMessages(ofType: ClientTimeMessage.typeString).count
        try await server.sendActivation(activities: [.playback], activeRoles: [.playerV1])
        #expect(await waitUntil {
            await server.clientJSONMessages(ofType: ClientTimeMessage.typeString).count > timeCountBeforeActivate
        })
        try await session.client.setPlayerFormatPreference(format)
        #expect(await waitUntil {
            await server.clientJSONMessages(ofType: ClientStateMessage.typeString).contains { data in
                (try? JSONDecoder().decode(ClientStateMessage.self, from: data))?.payload.player?.format == format
            }
        })
        await session.client.disconnect()
    }

    @Test("Post-swap wire order: client traffic only after activation")
    func postSwapSequencing() async throws {
        let longTermPsk = Psk.generate()
        let session = try await makePairableSession(seededLongTermPsk: longTermPsk)
        let server = session.server

        try await rehandshake(server, to: longTermPsk, pskCategory: .longTerm)
        // Give any stray sender time to violate the gate before asserting silence.
        try await Task.sleep(for: .milliseconds(60))

        let messages = await server.decryptedMessages.compactMap { message -> String? in
            guard message.first == NoiseFrameType.json else { return nil }
            return SendspinEncoding.messageType(of: Data(message.dropFirst()))
        }
        let replyIndex = try #require(messages.lastIndex(of: NoiseHandshakeMessage.typeString))
        let tail = Array(messages[(replyIndex + 1)...])
        #expect(
            tail.isEmpty,
            "between the key swap and the post-swap activate, no application messages may flow"
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

    /// A sender parked on the outbound queue before a rehandshake re-checks the
    /// gate once woken: the gate closes on message-1 receipt, ahead of the reply's
    /// key swap, so the woken sender is rejected while the swap is still pending.
    @Test("a queued sender woken under the closed rehandshake gate is rejected before the key swap")
    func queuedSenderWokenUnderClosedGateIsRejected() async throws {
        let longTermPsk = Psk.generate()
        let session = try await makePairableSession(seededLongTermPsk: longTermPsk)
        let server = session.server
        let transport = server.transport
        let connection = try #require(await MainActor.run { session.client.connection })
        // start() returns before messageLoop installs the clock-sync sampler;
        // wait for the handle first so cancel/join drains it deterministically.
        #expect(await waitUntil { await connection.clockSyncTask != nil }, "clock-sync task handle must appear before cancel")
        await connection.clockSyncTask?.cancel()
        await connection.clockSyncTask?.value

        // #1 takes the outbound slot and parks mid-fragment on the gate.
        await transport.enableGoodbyeGate()
        let first = Task { () -> Result<Void, Error> in
            do {
                try await connection.send(clientMessage:
                    OutboundTestMessage(
                        type: OutboundTestMessageType.padded,
                        note: String(repeating: "g", count: NoiseChannel.maxSinglePayload + 2_000)
                    )
                )
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        #expect(await waitUntil { await transport.isGoodbyeGateWaiting })

        // #2 queues behind #1 (it has NOT acquired the slot, so it has not checked
        // the gate — it will only do so once woken).
        let second = Task { () -> Result<Void, Error> in
            do {
                try await connection.send(clientMessage: OutboundTestMessage(type: OutboundTestMessageType.small, note: "queued-before-rekey"))
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        #expect(await waitUntil { await connection.outboundWaiters.count == 1 }, "the second sender must queue")

        // beginRehandshake only injects message 1; the gate closes when the
        // connection consumes it. Wait for that before releasing the sender, and
        // release unconditionally so failure cannot wedge the parked send.
        try await server.beginRehandshake(to: longTermPsk, pskCategoryOverride: .longTerm)
        #expect(await waitUntil { await connection.isRehandshakeInProgress })
        await transport.releaseGoodbyeGate()

        let firstResult = await first.value
        #expect((try? firstResult.get()) != nil, "the first send must complete")

        // #2 wakes under the (now closed) rehandshake gate and is rejected.
        let secondResult = await second.value
        let secondWasRejected: Bool = {
            guard case .failure = secondResult else { return false }
            return true
        }()
        #expect(secondWasRejected, "a sender that parked before the re-key swap must be gate-rejected when woken after it")

        // The reply sent bypass under the old keys; the swap lands on the client.
        #expect(await waitUntil { await server.rehandshakeComplete })

        // Neither queued-before-rekey send may have hit the wire under the old or
        // new keys: the small one was gate-rejected (no encrypt); the padded one
        // completed before the handshake and is legitimate old-key traffic.
        let wireTypes = await server.decryptedMessages.compactMap(typeOfDecryptedJSON)
        #expect(!wireTypes.contains(OutboundTestMessageType.small), "a gate-rejected send must not reach the wire at all")

        await session.client.disconnect()
    }

    @Test("Omitted roles persist across promotion without forced state publication")
    func postSwapActivationPreservesRoles() async throws {
        let longTermPsk = Psk.generate()
        let session = try await makePairableSession(seededLongTermPsk: longTermPsk)
        let connection = try #require(await session.client.connection)
        try await rehandshake(session.server, to: longTermPsk, pskCategory: .longTerm)
        #expect(await waitUntil { await connection.awaitingRehandshakeActivation })
        let statesBefore = await session.server.clientJSONMessages(ofType: ClientStateMessage.typeString).count
        try await session.server.sendJSON(
            #require(String(
                data: JSONEncoder().encode(ServerActivateMessage(payload: ServerActivatePayload(activities: [], activeRoles: nil))),
                encoding: .utf8
            ))
        )
        #expect(await waitUntil { await connection.isRehandshakeInProgress == false })
        #expect(await connection.activeRoles == [.playerV1])
        #expect(await connection.sessionContext.category == .longTerm)
        #expect(await session.server.clientJSONMessages(ofType: ClientStateMessage.typeString).count == statesBefore)
        await session.client.disconnect()
    }

    @Test("Re-handshake preserves open stream state and resets pairing index")
    func rehandshakePreservesStreamState() async throws {
        let session = try await makePairableSession()
        let connection = try #require(await session.client.connection)
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        await connection.seedRehandshakeStreamState(format: format)
        let engine = await connection.audioEngine
        let artworkValidity = await connection.artworkDeliveryValidity
        let visualizerValidity = await connection.visualizerFrameValidity
        await connection.clock.processServerTime(clientTransmitted: 0, serverReceived: 100, serverTransmitted: 100, clientReceived: 200)
        let clockBefore = try #require(await connection.clock.diagnosticSnapshot())
        try await rehandshake(session.server, to: .sentinel)
        #expect(await waitUntil { await connection.awaitingRehandshakeActivation })
        #expect(await connection.playerStreamActive)
        #expect(await connection.announcedPlayerStream?.format == format)
        #expect(await connection.artworkTransfer?.data == Data([BinaryMessageType.audioChunk.rawValue]))
        #expect(await connection.artworkTransfer?.received == 1)
        #expect(await connection.artworkDeliveryValidity === artworkValidity)
        #expect(await connection.visualizerFrameValidity === visualizerValidity)
        #expect(await connection.audioEngine === engine)
        #expect(await connection.pairingActivateCounter == 0)
        #expect(await connection.clock.diagnosticSnapshot()?.offset == clockBefore.offset)
        try await session.server.sendActivation(activities: [.playback], activeRoles: [.playerV1])
        #expect(await waitUntil { await connection.isRehandshakeInProgress == false })
        #expect(await connection.artworkTransfer != nil)
        await session.client.disconnect()
    }

    @Test("An omitted role set becomes empty when new credentials disallow playback")
    func postSwapPlaybackCapabilityClearsPersistedRoles() async throws {
        let longTermPsk = Psk.generate()
        let session = try await makePairableSession(seededLongTermPsk: longTermPsk, initialPsk: longTermPsk)
        let connection = try #require(await session.client.connection)
        let current = await session.runtime.snapshot()
        await session.runtime.update(PairingManagementConfiguration(
            pairingPsk: current.pairingPsk,
            pairingPskEnabled: true,
            unpairedAccessEnabled: false
        ))
        try await rehandshake(session.server, to: .sentinel)
        #expect(await waitUntil { await connection.awaitingRehandshakeActivation })
        #expect(await connection.activeRoles == [.playerV1])
        let activation = ServerActivateMessage(payload: ServerActivatePayload(activities: [], activeRoles: nil))
        try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(activation), encoding: .utf8)))
        #expect(await waitUntil { await connection.isRehandshakeInProgress == false })
        #expect(await connection.activeRoles.isEmpty)
        #expect(await MainActor.run { session.client.connectionState == .connected })
        await session.client.disconnect()
    }

    @Test("Rejected new-key activations send exactly one goodbye", arguments: [GoodbyeReason.unauthorized, .pairingRequired])
    func postSwapRejectedActivationSendsGoodbye(reason: GoodbyeReason) async throws {
        let longTermPsk = Psk.generate()
        let session = try await makePairableSession(seededLongTermPsk: longTermPsk)
        let connection = try #require(await session.client.connection)
        if reason == .pairingRequired {
            let current = await session.runtime.snapshot()
            await session.runtime.update(PairingManagementConfiguration(
                pairingPsk: current.pairingPsk, pairingPskEnabled: true, unpairedAccessEnabled: false
            ))
            try await rehandshake(session.server, to: session.pairingPsk)
        } else {
            try await rehandshake(session.server, to: longTermPsk, pskCategory: .longTerm)
        }
        #expect(await waitUntil { await connection.awaitingRehandshakeActivation })
        let activities: [Activity] = reason == .pairingRequired ? [.playback] : [.pairing]
        let directive = reason == .unauthorized ? PairingDirective(method: PairMethod.pairingPsk) : nil
        let activation = ServerActivateMessage(payload: ServerActivatePayload(
            activities: activities, activeRoles: [], pairing: directive
        ))
        try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(activation), encoding: .utf8)))
        #expect(await waitUntil { await MainActor.run { session.client.connectionState == .disconnected } })
        let messages = await session.server.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString)
        #expect(messages.count == 1)
        let goodbye = try JSONDecoder().decode(ClientGoodbyeMessage.self, from: #require(messages.first))
        #expect(goodbye.payload.reason == reason)
        await session.client.disconnect()
    }

    @Test("New-key audio before activation closes without engine enqueue")
    func postSwapAudioClosesWithoutEnqueue() async throws {
        let session = try await makePairableSession()
        let connection = try #require(await session.client.connection)
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        await connection.seedRehandshakeStreamState(format: format)
        let engine = await connection.audioEngine
        await connection.prepareRehandshakeAudioIngress(format: format)
        #expect(await waitUntil { await engine.appliedCommandKinds().contains(.streamStart) })
        let chunksBefore = await engine.appliedCommandKinds().filter { $0 == .chunk }.count
        try await rehandshake(session.server, to: .sentinel)
        #expect(await waitUntil { await connection.awaitingRehandshakeActivation })
        var audio = Data(repeating: 0, count: BinaryMessage.audioChunkHeaderSize)
        audio[0] = BinaryMessageType.audioChunk.rawValue
        try await session.server.sendEncrypted(audio)
        #expect(await waitUntil { await MainActor.run { session.client.connectionState == .disconnected } })
        #expect(await engine.appliedCommandKinds().filter { $0 == .chunk }.count == chunksBefore)
        await session.client.disconnect()
    }

    @Test("Changed roles publish the retained player preference under new keys")
    func postSwapChangedRolesPublishPlayerState() async throws {
        let session = try await makePairableSession()
        let connection = try #require(await session.client.connection)
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        try await session.client.setPlayerFormatPreference(format)
        try await session.server.sendActivation(activities: [], activeRoles: [])
        #expect(await waitUntil { await connection.activeRoles.isEmpty })
        try await rehandshake(session.server, to: .sentinel)
        #expect(await waitUntil { await connection.awaitingRehandshakeActivation })
        let before = await session.server.clientJSONMessages(ofType: ClientStateMessage.typeString).count
        try await session.server.sendActivation(activities: [.playback], activeRoles: [.playerV1])
        #expect(await waitUntil { await connection.isRehandshakeInProgress == false })
        let states = await session.server.clientJSONMessages(ofType: ClientStateMessage.typeString).dropFirst(before)
        #expect(states.count == 1)
        let state = try JSONDecoder().decode(ClientStateMessage.self, from: #require(states.first))
        #expect(state.payload.player?.format == format)
        await session.client.disconnect()
    }

    @Test("Post-swap player removal runs cleanup exactly once")
    func postSwapRoleRemovalClearsPlayerOnce() async throws {
        let session = try await makePairableSession()
        let connection = try #require(await session.client.connection)
        let engine = await connection.audioEngine
        let before = await engine.appliedCommandKinds().filter { $0 == .streamEnd }.count
        try await rehandshake(session.server, to: .sentinel)
        #expect(await waitUntil { await connection.awaitingRehandshakeActivation })
        #expect(await connection.activeRoles == [.playerV1])
        try await session.server.sendActivation(activities: [], activeRoles: [])
        #expect(await waitUntil { await engine.appliedCommandKinds().filter { $0 == .streamEnd }.count == before + 1 })
        let statesBefore = await session.server.clientJSONMessages(ofType: ClientStateMessage.typeString).count
        try await session.server.sendActivation(activities: [], activeRoles: [])
        #expect(await waitUntil { await session.server.clientJSONMessages(ofType: ClientStateMessage.typeString).count > statesBefore })
        #expect(await engine.appliedCommandKinds().filter { $0 == .streamEnd }.count == before + 1)
        await session.client.disconnect()
    }

    @Test("A new-key hello silently closes without a client hello")
    func newKeyHelloClosesWithoutReply() async throws {
        let session = try await makePairableSession()
        let connection = try #require(await session.client.connection)
        let hellosBefore = await session.server.clientJSONMessages(ofType: ClientHelloMessage.typeString).count
        try await rehandshake(session.server, to: .sentinel)
        #expect(await waitUntil { await connection.awaitingRehandshakeActivation })
        try await session.server.sendJSON(
            #require(String(data: JSONEncoder().encode(ServerHelloMessage(payload: ServerHelloPayload(name: "Forbidden"))), encoding: .utf8))
        )
        #expect(await waitUntil { await MainActor.run { session.client.connectionState == .disconnected } })
        #expect(await session.server.clientJSONMessages(ofType: ClientHelloMessage.typeString).count == hellosBefore)
        #expect(await session.server.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).isEmpty)
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

        #expect(await !waitUntil(timeout: .milliseconds(300)) {
            await pairingRecords(session.store).contains { $0.serverId != nil }
        })
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
        #expect(await pairingRecords(bound.store).isEmpty)
        let boundGoodbye = try #require(await boundServer.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).first)
        #expect(try JSONDecoder().decode(ClientGoodbyeMessage.self, from: boundGoodbye).payload.reason == .unpaired)

        let sharedPsk = Psk.generate()
        let shared = try await makePairableSession(
            seededLongTermPsk: sharedPsk,
            seededLongTermShared: true,
            initialPsk: sharedPsk
        )
        let sharedServer = shared.server
        let sharedRecordsBeforeUnpair = await pairingRecords(shared.store)
        try await sharedServer.sendJSON(#"{"type":"server/unpair","payload":{}}"#)
        #expect(await waitUntil { await MainActor.run { shared.client.connectionState == .disconnected } })
        #expect(await pairingRecords(shared.store) == sharedRecordsBeforeUnpair)
        #expect(await pairingRecords(shared.store).allSatisfy { $0.serverId == nil })
        let sharedGoodbye = try #require(await sharedServer.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).first)
        #expect(try JSONDecoder().decode(ClientGoodbyeMessage.self, from: sharedGoodbye).payload.reason == .unpaired)

        let sentinel = try await makePairableSession()
        let sentinelServer = sentinel.server
        let unrelatedRecord = PairingRecord(psk: .generate(), serverId: SendspinIdentity.generate().clientId)
        try await sentinel.store.insertOrReplace(unrelatedRecord)
        try await sentinelServer.sendJSON(#"{"type":"server/unpair","payload":{}}"#)
        #expect(await !waitUntil(timeout: .milliseconds(300)) {
            await MainActor.run { sentinel.client.connectionState == .disconnected }
        })
        #expect(await pairingRecords(sentinel.store) == [unrelatedRecord])
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

    @Test("A live pair-finalize fences eviction until teardown releases its lease")
    func liveFinalizeFencesEvictionUntilTeardown() async throws {
        let pairingPsk = Psk.generate()
        let store = RecordingPairingRecordStore(
            pairingPsk: pairingPsk,
            capacity: SendspinDevice.minimumCapacity
        )
        let session = try await makePairableSession(
            pairingPsk: pairingPsk,
            store: store
        )
        let server = session.server
        let serverId = await server.serverId

        try await rehandshake(server, to: pairingPsk)
        try await server.sendJSON(
            #"{"type":"server/activate","payload":{"activities":["pairing"],"active_roles":[],"pairing":{"method":"pairing_psk"}}}"#
        )
        #expect(await waitUntil {
            await server.clientJSONMessages(ofType: ClientPairFinalizeMessage.typeString).count == 1
        })
        let finalizeData = try #require(await server.clientJSONMessages(ofType: ClientPairFinalizeMessage.typeString).first)
        let finalize = try JSONDecoder().decode(ClientPairFinalizeMessage.self, from: finalizeData)
        let finalizedPsk = try #require(Psk(base64URL: finalize.payload.longTermPsk))
        try await server.sendJSON(#"{"type":"server/pair-finalize","payload":{}}"#)
        #expect(await waitUntil {
            await pairingRecords(store).contains { $0.serverId == serverId && $0.psk == finalizedPsk }
        })

        var otherRecords: [PairingRecord] = []
        for index in 60 ..< 64 {
            let record = PairingRecord(psk: .generate(), serverId: rehandshakeServerID(index))
            otherRecords.append(record)
            try await store.insertOrReplace(record)
        }
        var otherLeases: [PairingRecordProtectionLease] = []
        for record in otherRecords.dropLast() {
            try await otherLeases.append(
                store.acquireProtection(pskId: record.pskId, serverId: record.serverId)
            )
        }
        let firstInsertion = PairingRecord(psk: .generate(), serverId: rehandshakeServerID(70))
        try await store.insertOrReplace(firstInsertion)
        let whileConnected = try await store.records()
        #expect(whileConnected.contains { $0.psk == finalizedPsk })
        #expect(whileConnected.contains(firstInsertion))

        await session.client.disconnect()
        #expect(await waitUntil { await store.releaseCount == 1 })
        let secondInsertion = PairingRecord(psk: .generate(), serverId: rehandshakeServerID(71))
        try await store.insertOrReplace(secondInsertion)
        let afterTeardown = try await store.records()
        #expect(!afterTeardown.contains { $0.psk == finalizedPsk })
        #expect(afterTeardown.contains(secondInsertion))

        for lease in otherLeases {
            try await store.releaseProtection(lease)
        }
    }

    @Test("A same-session re-handshake succeeds at the protection limit")
    func rehandshakeRetainsLeaseAtProtectionLimit() async throws {
        let longTermPsk = Psk.generate()
        let pairingPsk = Psk.generate()
        let store = RecordingPairingRecordStore(
            pairingPsk: pairingPsk,
            capacity: SendspinDevice.minimumCapacity
        )
        let session = try await makePairableSession(
            seededLongTermPsk: longTermPsk,
            pairingPsk: pairingPsk,
            initialPsk: longTermPsk,
            store: store
        )
        var leases: [PairingRecordProtectionLease] = []
        for index in 0 ..< 3 {
            let record = PairingRecord(psk: .generate(), serverId: rehandshakeServerID(50 + index))
            try await store.insertOrReplace(record)
            try await leases.append(
                store.acquireProtection(pskId: record.pskId, serverId: record.serverId)
            )
        }

        try await rehandshake(session.server, to: longTermPsk, pskCategory: .longTerm)
        #expect(await MainActor.run { session.client.connectionState == .connected })
        #expect(await session.server.rehandshakeComplete)

        for lease in leases {
            try await store.releaseProtection(lease)
        }
        await session.client.disconnect()
    }

    @Test("Live pair-finalize invokes atomic commit for a same-server replacement while incumbent stays live")
    func liveFinalizeUsesAtomicCommitForSameServerReplacement() async throws {
        let oldPsk = Psk.generate()
        let pairingPsk = Psk.generate()
        let store = RecordingPairingRecordStore(pairingPsk: pairingPsk)
        let staticKey = Curve25519.KeyAgreement.PrivateKey()
        let incumbent = try await makePairableSession(
            seededLongTermPsk: oldPsk,
            pairingPsk: pairingPsk,
            serverStaticKey: staticKey,
            initialPsk: oldPsk,
            store: store
        )
        let serverId = await incumbent.server.serverId
        let replacement = try await makePairableSession(
            seededLongTermPsk: oldPsk,
            pairingPsk: pairingPsk,
            serverStaticKey: staticKey,
            initialPsk: .sentinel,
            store: store
        )
        let server = replacement.server

        try await rehandshake(server, to: pairingPsk)
        try await server.sendJSON(
            #"{"type":"server/activate","payload":{"activities":["pairing"],"active_roles":[],"pairing":{"method":"pairing_psk"}}}"#
        )
        #expect(await waitUntil {
            await server.clientJSONMessages(ofType: ClientPairFinalizeMessage.typeString).count == 1
        })
        let finalizeData = try #require(await server.clientJSONMessages(ofType: ClientPairFinalizeMessage.typeString).first)
        let finalize = try JSONDecoder().decode(ClientPairFinalizeMessage.self, from: finalizeData)
        let replacementPsk = try #require(Psk(base64URL: finalize.payload.longTermPsk))
        try await server.sendJSON(#"{"type":"server/pair-finalize","payload":{}}"#)

        #expect(await waitUntil { await store.atomicCommitCount == 1 })
        #expect(try await store.records() == [PairingRecord(psk: replacementPsk, serverId: serverId)])
        #expect(replacementPsk != oldPsk)
        #expect(await MainActor.run { incumbent.client.connectionState == ConnectionState.connected })

        await replacement.client.disconnect()
        await incumbent.client.disconnect()
        #expect(await waitUntil { await store.releaseCount >= 2 })
    }

    @Test("Connection teardown completes when lease release fails")
    func leaseReleaseFailureDoesNotWedgeTeardown() async throws {
        let oldPsk = Psk.generate()
        let store = RecordingPairingRecordStore(pairingPsk: Psk.generate())
        let session = try await makePairableSession(
            seededLongTermPsk: oldPsk,
            initialPsk: oldPsk,
            store: store
        )
        #expect(await store.releaseCount == 0)
        await store.setFailReleases(true)

        await session.client.disconnect()

        #expect(await waitUntil { await MainActor.run { session.client.connection == nil } })
        #expect(await session.client.connectionState == .disconnected)
        #expect(await store.releaseCount == 1)
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

    @Test("Pairing records persist one replacement per server")
    func pairingRecordsReplaceByServer() async throws {
        let store = InMemoryPairingRecordStore(capacity: minimumPairingRecordCapacity)
        let old = PairingRecord(psk: .generate(), serverId: "server")
        try await store.insertOrReplace(old)
        let replacement = PairingRecord(psk: .generate(), serverId: "server")
        try await store.insertOrReplace(replacement)
        let records = try await store.listRecords()
        #expect(records.count == 1)
        #expect(records.first == replacement)
    }
}

private actor RecordingPairingRecordStore: PairingRecordStore {
    private let base: InMemoryPairingRecordStore
    private(set) var atomicCommitCount = 0
    private(set) var releaseCount = 0
    private var failReleases = false

    init(pairingPsk: Psk, capacity: Int = minimumPairingRecordCapacity) {
        base = InMemoryPairingRecordStore(pairingPsk: pairingPsk, capacity: capacity)
    }

    func listRecords() async throws -> [PairingRecord] {
        try await base.listRecords()
    }

    func insertOrReplace(_ record: PairingRecord) async throws {
        try await base.insertOrReplace(record)
    }

    func insertOrReplaceAndProtect(_ record: PairingRecord) async throws -> PairingRecordProtectionLease {
        atomicCommitCount += 1
        return try await base.insertOrReplaceAndProtect(record)
    }

    func remove(pskId: String) async throws {
        try await base.remove(pskId: pskId)
    }

    func markUsed(pskId: String) async throws {
        try await base.markUsed(pskId: pskId)
    }

    func acquireProtection(pskId: String, serverId: String?) async throws -> PairingRecordProtectionLease {
        try await base.acquireProtection(pskId: pskId, serverId: serverId)
    }

    func releaseProtection(_ lease: PairingRecordProtectionLease) async throws {
        releaseCount += 1
        if failReleases {
            throw PairingRecordStoreError.storageUnavailable
        }
        try await base.releaseProtection(lease)
    }

    func setFailReleases(_ value: Bool) {
        failReleases = value
    }

    func storageAccounting() async throws -> PairingStorageAccounting? {
        try await base.storageAccounting()
    }

    func dynamicPairingRoundCount() async throws -> UInt32 {
        try await base.dynamicPairingRoundCount()
    }

    func reserveDynamicPairingRound(limit: UInt32) async throws -> DynamicPairingRoundReservation {
        try await base.reserveDynamicPairingRound(limit: limit)
    }

    func resetDynamicPairingBudget() async throws {
        try await base.resetDynamicPairingBudget()
    }

    func records() async throws -> [PairingRecord] {
        try await base.listRecords()
    }
}

private actor ThrowingPairingRecordStore: PairingRecordStore {
    func listRecords() async throws -> [PairingRecord] {
        []
    }

    func insertOrReplace(_: PairingRecord) async throws {
        throw PairingRecordStoreError.duplicatePskId
    }

    func insertOrReplaceAndProtect(_: PairingRecord) async throws -> PairingRecordProtectionLease {
        throw PairingRecordStoreError.duplicatePskId
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
        0
    }

    func reserveDynamicPairingRound(limit: UInt32) async throws -> DynamicPairingRoundReservation {
        .reserved(round: 1, remaining: limit > 0 ? limit - 1 : 0)
    }

    func resetDynamicPairingBudget() async throws {}
}
