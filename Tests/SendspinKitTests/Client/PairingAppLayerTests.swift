import Foundation
@testable import SendspinKit
import Testing

/// App-facing pairing lifecycle tests. These deliberately exercise the facade
/// rather than reaching into connection-owned attempt state.
@MainActor
@Suite("Pairing app layer", .timeLimit(.minutes(1)))
struct PairingAppLayerTests {
    @Test("primary pairing can be cancelled by its snapshot identity")
    func cancelPrimaryPairing() async throws {
        let session = try await makeSession()
        let attempt = try #require(session.client.currentPairing)

        try await session.client.cancelPairing(attemptID: attempt.id)

        let abort = try await waitForMessage(session.server, type: PairAbortMessage.typeString)
        #expect(try JSONDecoder().decode(PairAbortMessage.self, from: abort).payload.reason == .userCancelled)
        #expect(session.client.currentPairing?.id == attempt.id)
        #expect(session.client.currentPairing?.phase == .ended(.userCancelled))
        #expect(session.client.connection != nil)
        await session.client.disconnect()
    }

    @Test("parked pairing side can be cancelled without retargeting playback")
    func cancelPairingSide() async throws {
        let session = try await makePlaybackSession()
        let side = try await admitPairingSide(to: session.client)
        let attempt = try #require(session.client.currentPairing)
        let primary = session.client.connection

        try await session.client.cancelPairing(attemptID: attempt.id)

        let abort = try await waitForMessage(side, type: PairAbortMessage.typeString)
        #expect(try JSONDecoder().decode(PairAbortMessage.self, from: abort).payload.reason == .userCancelled)
        #expect(session.client.connection === primary)
        #expect(session.client.currentPairing?.id == attempt.id)
        #expect(session.client.currentPairing?.phase == .ended(.userCancelled))
        await session.client.disconnect()
    }

    @Test("stale cancellation after A ends and B starts has no effect")
    func staleCancelCannotRetargetNewAttempt() async throws {
        let session = try await makeSession()
        let first = try #require(session.client.currentPairing)
        try await session.client.cancelPairing(attemptID: first.id)
        _ = try await waitForMessage(session.server, type: PairAbortMessage.typeString)

        try await activatePairing(session.server)
        #expect(await waitUntil { await MainActor.run {
            guard let current = session.client.currentPairing else { return false }
            return current.id != first.id && current.phase == .pending
        } })
        let second = try #require(session.client.currentPairing)
        let abortCount = await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).count

        await #expect(throws: SendspinClientError.stalePairingAttempt(first.id)) {
            try await session.client.cancelPairing(attemptID: first.id)
        }
        #expect(session.client.currentPairing == second)
        #expect(await session.server.clientJSONMessages(ofType: PairAbortMessage.typeString).count == abortCount)
        // A late observer reads the terminal/current projection rather than an actor handle.
        #expect(session.client.currentPairing?.id == second.id)
        await session.client.disconnect()
    }

    @Test("retry retains the attempt identity and terminal snapshot is observable")
    func retryRetainsIdentity() async throws {
        let session = try await makeSession()
        let first = try #require(session.client.currentPairing)
        let nonceA = Base64URL.encode(Data(repeating: 0, count: 32))
        let pairInit = ServerPairInitMessage(payload: ServerPairInitPayload(nonceA: nonceA))
        try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(pairInit), encoding: .utf8)))
        #expect(await waitUntil { await MainActor.run { session.client.currentPairing?.phase == .codeReady } })

        let initMessage = try await JSONDecoder().decode(
            ClientPairInitMessage.self,
            from: #require(session.server.clientJSONMessages(ofType: ClientPairInitMessage.typeString).last)
        )
        let code = try #require(session.client.currentPairing?.code?.payload)
        let handshakeHash = try #require(await session.server.establishedHandshakeHash)
        let sid = CPaceSessionIdentifier.make(
            handshakeHash: handshakeHash,
            counter: initMessage.payload.pairingIndex,
            round: 1
        )
        let serverCPace = try CPace(
            role: .initiator,
            prs: Data(code.utf8),
            sid: sid
        )
        let auth = ServerPairAuthMessage(payload: ServerPairAuthPayload(
            pakeMsg1: Base64URL.encode(serverCPace.publicShare)
        ))
        try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(auth), encoding: .utf8)))
        _ = try await waitForMessage(session.server, type: ClientPairAuthMessage.typeString)
        let invalidTag = Base64URL.encode(Data(repeating: 0, count: 64))
        let confirm = ServerPairConfirmMessage(payload: ServerPairConfirmPayload(serverKc: invalidTag))
        try await session.server.sendJSON(#require(String(data: JSONEncoder().encode(confirm), encoding: .utf8)))
        _ = try await waitForMessage(session.server, type: ClientPairRetryMessage.typeString)
        #expect(session.client.currentPairing?.id == first.id)

        try await session.client.cancelPairing(attemptID: first.id)
        #expect(await waitUntil { await MainActor.run { session.client.currentPairing?.phase == .ended(.userCancelled) } })
        #expect(session.client.currentPairing?.id == first.id)
        await session.client.disconnect()
    }

    @Test("a stale primary success does not close a newer authorization window")
    func stalePrimarySuccessPreservesNewerWindow() async throws {
        let session = try await makeSession()
        let oldAttempt = try #require(session.client.currentPairing)
        let newerAttemptID = PairingAttemptID()
        let newerWindow = PairingWindowSnapshot(attemptID: newerAttemptID, expiresAt: .now)

        session.client.applyConnectionEvent(.pairingWindowChanged(newerWindow))
        session.client.applyConnectionEvent(.paired(PairingAttemptSnapshot(
            id: oldAttempt.id,
            peer: oldAttempt.peer,
            phase: .succeeded
        )))

        #expect(session.client.pairingWindow == newerWindow)
        session.client.applyConnectionEvent(.paired(PairingAttemptSnapshot(
            id: newerAttemptID,
            peer: oldAttempt.peer,
            phase: .succeeded
        )))
        #expect(session.client.pairingWindow == nil)
        await session.client.disconnect()
    }

    @Test("a stale parked-side success does not close a newer authorization window")
    func stalePairingSideSuccessPreservesNewerWindow() async throws {
        let session = try await makePlaybackSession()
        let side = try await admitPairingSide(to: session.client)
        _ = side
        let oldAttempt = try #require(session.client.currentPairing)
        let newerAttemptID = PairingAttemptID()
        let newerWindow = PairingWindowSnapshot(attemptID: newerAttemptID, expiresAt: .now)

        session.client.applyPairingConnectionEvent(.pairingWindowChanged(newerWindow))
        session.client.applyPairingConnectionEvent(.paired(PairingAttemptSnapshot(
            id: oldAttempt.id,
            peer: oldAttempt.peer,
            phase: .succeeded
        )))

        #expect(session.client.pairingWindow == newerWindow)
        session.client.applyPairingConnectionEvent(.paired(PairingAttemptSnapshot(
            id: newerAttemptID,
            peer: oldAttempt.peer,
            phase: .succeeded
        )))
        #expect(session.client.pairingWindow == nil)
        await session.client.disconnect()
    }

    @Test("operator cancellation closes the surviving authorization window exactly once")
    func pairingWindowSurvivesPairInitUntilOperatorCancellation() async throws {
        let session = try await makeSession()
        let attempt = try #require(session.client.currentPairing)
        #expect(attempt.peer.trustLevel == .none)

        let windowEventsTask = Task { () -> [ClientEvent] in
            var windowEvents = [ClientEvent]()
            for await event in session.events {
                guard case .pairingWindowChanged = event else { continue }
                windowEvents.append(event)
                if windowEvents.count == 2 {
                    return windowEvents
                }
            }
            return windowEvents
        }
        try await session.client.openPairingWindow(for: attempt.id)
        try await activatePairing(session.server)
        _ = try await waitForMessage(session.server, type: ClientPairInitMessage.typeString)
        #expect(session.client.pairingWindow != nil)
        let windowID = try #require(session.client.pairingWindow?.attemptID)
        try await session.client.cancelPairing(attemptID: windowID)

        let windowEvents = await observeTask(windowEventsTask, timeout: .seconds(2))
        guard case let .completed(events) = windowEvents else {
            Issue.record("pairing window open and consume events were not both observed")
            await session.client.disconnect()
            return
        }
        guard case let .pairingWindowChanged(window?) = events.first,
              case .pairingWindowChanged(nil) = events.last else {
            Issue.record("pairing window did not emit open then nil")
            await session.client.disconnect()
            return
        }
        #expect(events.count == 2)
        #expect(window.attemptID == attempt.id)
        #expect(session.client.pairingWindow == nil)
        await session.client.disconnect()
    }

    private struct Session {
        let client: SendspinClient
        let server: MockNoiseServer
        let events: AsyncStream<ClientEvent>
    }

    private func makeSession(windowLifetime: Duration = .seconds(30)) async throws -> Session {
        let pairingPsk = Psk.generate()
        let store = InMemoryPairingRecordStore(pairingPsk: pairingPsk)
        let client = try SendspinClient(
            identity: .generate(),
            name: "Pairing App Layer Client",
            roles: [],
            pairing: PairingConfiguration(
                pairingPsk: pairingPsk,
                store: store,
                enabled: false,
                dynamicPairingCodeEnabled: true
            ),
            audioOutputCapabilityProvider: AudioOutputCapabilityService(),
            handshakeTimeout: .seconds(3),
            pairingAttemptTimeout: .seconds(30),
            pairingWindowLifetime: windowLifetime
        )
        let events = client.events()
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport, psk: .sentinel)
        async let accepted: Void = client.acceptConnection(transport)
        try await server.establishSession(activities: [], activeRoles: [])
        try await accepted
        try await activatePairing(server)
        #expect(await waitUntil { await MainActor.run { client.currentPairing != nil } })
        return Session(client: client, server: server, events: events)
    }

    private func makePlaybackSession() async throws -> Session {
        let pairingPsk = Psk.generate()
        let store = InMemoryPairingRecordStore(pairingPsk: pairingPsk)
        let client = try SendspinClient(
            identity: .generate(),
            name: "Pairing App Layer Playback Client",
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
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport, psk: .sentinel)
        async let accepted: Void = client.acceptConnection(transport)
        try await server.establishSession(activities: [.playback], activeRoles: [.playerV1, .controllerV1])
        try await accepted
        #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })
        return Session(client: client, server: server, events: events)
    }

    private func admitPairingSide(to client: SendspinClient) async throws -> MockNoiseServer {
        let transport = MockTransport()
        let side = MockNoiseServer(transport: transport, psk: .sentinel)
        async let accepted: Void = client.acceptConnection(transport)
        try await side.beginAdmission(name: "Pairing Side")
        try await activatePairing(side)
        try await accepted
        #expect(await waitUntil { await MainActor.run { client.pairingConnection != nil } })
        #expect(await waitUntil { await MainActor.run { client.currentPairing != nil } })
        return side
    }

    private func activatePairing(_ server: MockNoiseServer) async throws {
        let message = ServerActivateMessage(payload: ServerActivatePayload(
            activities: [.pairing],
            activeRoles: [],
            pairing: PairingDirective(method: PairMethod.dynamicPairingCode, format: PairingCodeFormat.digits.rawValue)
        ))
        try await server.sendJSON(#require(String(data: JSONEncoder().encode(message), encoding: .utf8)))
    }

    private func waitForMessage(_ server: MockNoiseServer, type: String) async throws -> Data {
        #expect(await waitUntil(timeout: .seconds(3)) {
            await server.clientJSONMessages(ofType: type).count >= 1
        })
        guard let message = await server.clientJSONMessages(ofType: type).last else {
            throw PairingAppLayerTestError.missingMessage(type)
        }
        return message
    }
}

private enum PairingAppLayerTestError: Error {
    case missingMessage(String)
}
