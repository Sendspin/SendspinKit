import CryptoKit
import Foundation
@testable import SendspinKit
import Testing

/// Establishment against a genuine Noise-speaking peer (``MockNoiseServer``), never
/// a mirror of the client's own code.
@Suite("Noise session establishment", .timeLimit(.minutes(1)))
struct NoiseSessionEstablisherTests {
    private let identity = SendspinIdentity.generate()

    /// Run the client and server sides concurrently and return both results.
    private func establish(
        transport: MockTransport,
        server: MockNoiseServer,
        candidates: [PskCandidate]? = nil,
        suite: NoiseCipherSuite = .chaChaPoly,
        phaseTimeout: Duration = .seconds(5),
        serverInitVersion: Int = sendspinCoreVersion,
        pskIdOverride: String? = nil,
        pskCategoryOverride: PskCategory? = nil
    ) async throws -> NoiseSessionOutcome {
        let psk = server.psk
        async let serverSide: Void = server.respondToHandshake(
            serverInitVersion: serverInitVersion,
            pskIdOverride: pskIdOverride,
            pskCategoryOverride: pskCategoryOverride
        )
        let outcome = try await NoiseSessionEstablisher.establish(
            on: transport,
            identity: identity,
            suite: suite,
            candidates: candidates ?? [PskCandidate(psk: psk, category: .longTerm)],
            phaseTimeout: phaseTimeout
        )
        try await serverSide
        return outcome
    }

    @Test("Full establishment and encrypted round trip", arguments: NoiseCipherSuite.allCases)
    func happyPath(suite: NoiseCipherSuite) async throws {
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport)
        var outcome = try await establish(transport: transport, server: server, suite: suite)

        #expect(await outcome.serverId == server.serverId)
        #expect(outcome.matchedCandidate.category == .longTerm)
        // The spec fixes Noise message 2's inner payload as the literal two bytes {}.
        #expect(await server.message2Payload == noiseMessage2Payload)

        // Server → client under the session keys.
        var serverMessage = Data([NoiseFrameType.json])
        serverMessage.append(Data("{\"type\":\"server/hello\"}".utf8))
        try await server.sendEncrypted(serverMessage)
        guard case let .binary(frame) = await transport.nextFrame() else {
            Issue.record("expected a binary frame")
            return
        }
        #expect(try outcome.channel.decryptFrame(frame) == serverMessage)

        // Client → server, including a fragmented message.
        var clientMessage = Data([NoiseFrameType.json])
        clientMessage.append(Data(repeating: 0x42, count: NoiseChannel.maxSinglePayload + 100))
        for frame in try outcome.channel.encryptMessage(clientMessage) {
            try await transport.sendBinary(frame)
        }
        #expect(try await server.nextDecryptedMessage() == clientMessage)
    }

    @Test("Stored-pubkey candidate bound to this server matches")
    func storedPubkeyMatch() async throws {
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport)
        let candidates = await [
            PskCandidate(psk: server.psk, category: .longTerm, requiredServerId: server.serverId)
        ]
        let outcome = try await establish(transport: transport, server: server, candidates: candidates)
        #expect(await outcome.serverId == server.serverId)
    }

    @Test("Initial psk_id lookup miss falls back to Sentinel")
    func initialPskLookupMissFallsBackToSentinel() async throws {
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport)
        let outcome = try await establish(
            transport: transport,
            server: server,
            candidates: [PskCandidate(psk: .sentinel, category: .sentinel)]
        )
        #expect(outcome.matchedCandidate.psk == .sentinel)
        #expect(outcome.matchedCandidate.category == .sentinel)
        #expect(await transport.disconnectCalled == false)
        #expect(await server.message2Payload == noiseMessage2Payload)
    }

    @Test("A PSK held under the wrong category falls back to Sentinel")
    func wrongCategoryFallsBackToSentinel() async throws {
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport)
        let outcome = try await establish(
            transport: transport,
            server: server,
            candidates: [PskCandidate(psk: server.psk, category: .longTerm)],
            pskCategoryOverride: .pairing
        )
        #expect(outcome.matchedCandidate.category == .sentinel)
        #expect(outcome.matchedCandidate.psk == .sentinel)
        #expect(await transport.disconnectCalled == false)
    }

    @Test("Stored-pubkey candidate bound to a different server is a misbinding")
    func storedPubkeyMismatch() async throws {
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport)
        let candidates = [
            PskCandidate(
                psk: server.psk,
                category: .longTerm,
                requiredServerId: Base64URL.encode(Data(repeating: 0x11, count: 32))
            )
        ]
        await #expect(throws: HandshakeError.pskLookupMiss) {
            _ = try await establish(transport: transport, server: server, candidates: candidates)
        }
    }

    @Test("A server/init version other than the core version aborts")
    func versionMismatch() async throws {
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport)
        await #expect(throws: HandshakeError.unsupportedVersion) {
            _ = try await establish(
                transport: transport,
                server: server,
                serverInitVersion: sendspinCoreVersion + 1
            )
        }
        #expect(await transport.disconnectCalled)
    }

    @Test("A tampered init exchange fails via the prologue binding")
    func prologueTamperFails() async throws {
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport)
        await server.setTamperProloguePostSend(true)
        await #expect(throws: HandshakeError.noise(.decryptFailed)) {
            _ = try await establish(transport: transport, server: server)
        }
        #expect(await transport.disconnectCalled)
    }

    /// Start client-side establishment as a task the test can fail with `#expect(throws:)`.
    /// Returns `Void` because a noncopyable outcome cannot ride in a `Task` payload —
    /// these tests exercise failure paths only.
    private func establishmentTask(
        transport: MockTransport,
        phaseTimeout: Duration = .seconds(5)
    ) -> Task<Void, Error> {
        let identity = identity
        return Task {
            _ = try await NoiseSessionEstablisher.establish(
                on: transport,
                identity: identity,
                suite: .chaChaPoly,
                candidates: [PskCandidate(psk: .sentinel, category: .sentinel)],
                phaseTimeout: phaseTimeout
            )
        }
    }

    @Test("Malformed server/init aborts without crashing")
    func malformedServerInit() async throws {
        let transport = MockTransport()
        let clientSide = establishmentTask(transport: transport)
        _ = await transport.nextSentFrame() // consume client/init
        await transport.injectText("{\"type\":\"server/init\",\"payload\":{\"bogus\":true}}")
        await #expect(throws: HandshakeError.malformed) {
            _ = try await clientSide.value
        }
    }

    @Test("A binary frame during the cleartext phase is a protocol violation")
    func binaryFrameDuringCleartext() async throws {
        let transport = MockTransport()
        let clientSide = establishmentTask(transport: transport)
        _ = await transport.nextSentFrame()
        await transport.injectBinary(Data([0x00, 0x01]))
        await #expect(throws: HandshakeError.malformed) {
            _ = try await clientSide.value
        }
    }

    @Test("A silent server times out the phase")
    func phaseTimeout() async throws {
        let transport = MockTransport()
        let clientSide = establishmentTask(transport: transport, phaseTimeout: .milliseconds(50))
        _ = await transport.nextSentFrame() // client/init went out; server never replies
        await #expect(throws: HandshakeError.timeout) {
            _ = try await clientSide.value
        }
        #expect(await transport.disconnectCalled)
    }

    @Test("Peer close during the cleartext phase surfaces as transport closed")
    func peerCloseDuringHandshake() async throws {
        let transport = MockTransport()
        let clientSide = establishmentTask(transport: transport)
        _ = await transport.nextSentFrame()
        await transport.simulateClose(.peerClosed(code: nil))
        await #expect(throws: HandshakeError.transportClosed) {
            _ = try await clientSide.value
        }
    }

    @Test("client/init carries the identity, core version, and chosen suite")
    func clientInitContents() async throws {
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport)
        _ = try await establish(transport: transport, server: server, suite: .aesGCM)
        let firstSend = try #require(await transport.sentTextMessages.first)
        let decoded = try JSONDecoder().decode(ClientInitMessage.self, from: firstSend)
        #expect(decoded.payload.clientId == identity.clientId)
        #expect(decoded.payload.version == sendspinCoreVersion)
        #expect(decoded.payload.suite == .aesGCM)

        // Pin the exact wire key names independently of the Codable machinery, so a
        // key-strategy regression that still self-round-trips cannot slip through.
        let object = try #require(
            try JSONSerialization.jsonObject(with: firstSend) as? [String: Any]
        )
        #expect(object["type"] as? String == ClientInitMessage.typeString)
        let payload = try #require(object["payload"] as? [String: Any])
        #expect(Set(payload.keys) == ["client_id", "version", "suite"])
    }

    @Test("The prologue binds the received server/init bytes, not a re-encoding")
    func prologueUsesRawServerInitBytes() async throws {
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport)
        // A noncanonical-but-valid spelling (whitespace, reordered keys): if the
        // client re-encoded the parsed message for its prologue instead of hashing
        // the received bytes, the handshake would fail at Noise message 1.
        let noncanonical = await """
        { "payload" : {"version": \(sendspinCoreVersion),  "server_id":"\(server.serverId)"} , "type" : "server/init" }
        """
        await server.setServerInitTextOverride(noncanonical)
        let outcome = try await establish(transport: transport, server: server)
        #expect(await outcome.serverId == server.serverId)
    }
}
