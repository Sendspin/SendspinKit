import CryptoKit
import Foundation

/// Why establishment failed. Per the spec's Failure Handling section every case has
/// the same wire behavior — close the WebSocket, send nothing — so these exist for
/// diagnostics and tests, not for the peer.
enum HandshakeError: Error, Equatable {
    /// The transport closed (or delivered a wrong-kind frame) before the phase completed.
    case transportClosed
    /// A phase timed out waiting for the peer's next handshake message.
    case timeout
    /// A cleartext message failed to parse or violated the expected shape.
    case malformed
    /// The peer's `version` is not the single core version this client speaks.
    case unsupportedVersion
    /// `server_id` is not a valid 43-character base64url Curve25519 public key.
    case invalidServerId
    /// No candidate PSK matches the `psk_id` from Noise message 1 (lookup miss),
    /// or the matched stored-pubkey record is bound to a different server.
    case pskLookupMiss
    /// The Noise layer failed (AEAD, state, or message structure).
    case noise(NoiseError)
}

/// The result of establishment: the channel, the authenticated peer identity, and
/// which PSK admitted the session (its category constrains later activity sets).
struct NoiseSessionOutcome: ~Copyable {
    var channel: NoiseChannel
    let serverId: String
    let serverStaticPublicKey: Curve25519.KeyAgreement.PublicKey
    let suite: NoiseCipherSuite
    let matchedCandidate: PskCandidate

    consuming func takeChannel() -> NoiseChannel {
        channel
    }
}

/// Runs the cleartext establishment phase on a fresh transport:
/// `client/init` → `server/init` → `noise/handshake` ×2 → transport mode.
/// The exact bytes of the two init messages, as sent and received, form the Noise
/// prologue — never a re-encoding. Any failure closes the transport silently and
/// rethrows. The encrypted session flow that follows belongs to the session layer.
enum NoiseSessionEstablisher {
    /// Spec-recommended limit for each side to receive the next expected message
    /// during the cleartext and Noise-handshake phases.
    static let defaultPhaseTimeout = Duration.seconds(30)

    static func establish(
        on transport: any SendspinTransport,
        identity: SendspinIdentity,
        suite: NoiseCipherSuite,
        candidates: [PskCandidate],
        phaseTimeout: Duration = defaultPhaseTimeout
    ) async throws -> NoiseSessionOutcome {
        do {
            return try await run(
                on: transport,
                identity: identity,
                suite: suite,
                candidates: candidates,
                phaseTimeout: phaseTimeout
            )
        } catch {
            // Failure Handling: close the WebSocket, send no application-level error.
            await transport.disconnect()
            throw error
        }
    }

    private static func run(
        on transport: any SendspinTransport,
        identity: SendspinIdentity,
        suite: NoiseCipherSuite,
        candidates: [PskCandidate],
        phaseTimeout: Duration
    ) async throws -> NoiseSessionOutcome {
        let encoder = SendspinEncoding.makeEncoder()

        // client/init — retain the exact bytes we put on the wire.
        let clientInit = ClientInitMessage(
            payload: ClientInitPayload(
                clientId: identity.clientId,
                version: sendspinCoreVersion,
                suite: suite
            )
        )
        let clientInitBytes = try encoder.encode(clientInit)
        guard let clientInitText = String(data: clientInitBytes, encoding: .utf8) else {
            throw HandshakeError.malformed
        }
        try await transport.sendRawText(clientInitText)

        // server/init — retain the exact bytes as received.
        let serverInitBytes = try await nextTextFrame(from: transport, timeout: phaseTimeout)
        guard SendspinEncoding.messageType(of: serverInitBytes) == ServerInitMessage.typeString,
              let serverInit = try? JSONDecoder().decode(ServerInitMessage.self, from: serverInitBytes)
        else { throw HandshakeError.malformed }
        guard serverInit.payload.version == sendspinCoreVersion else {
            throw HandshakeError.unsupportedVersion
        }
        let serverId = serverInit.payload.serverId
        guard let serverKeyBytes = Base64URL.decode(serverId, count: 32),
              let serverStaticKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverKeyBytes)
        else { throw HandshakeError.invalidServerId }

        var prologue = clientInitBytes
        prologue.append(serverInitBytes)

        var handshake = NoiseHandshake(
            suite: suite,
            role: .responder,
            localStaticKey: identity.privateKey,
            remoteStaticPublicKey: serverStaticKey,
            prologue: prologue
        )

        // Noise message 1: decryptable without a PSK; its payload names the psk_id.
        let message1Bytes = try await nextTextFrame(from: transport, timeout: phaseTimeout)
        guard SendspinEncoding.messageType(of: message1Bytes) == NoiseHandshakeMessage.typeString,
              let message1 = try? JSONDecoder().decode(NoiseHandshakeMessage.self, from: message1Bytes),
              let noiseMessage1 = Base64URL.decode(message1.payload.data)
        else { throw HandshakeError.malformed }

        let message1Payload: Data
        do {
            message1Payload = try handshake.readMessage1(noiseMessage1)
        } catch let error as NoiseError {
            throw HandshakeError.noise(error)
        }
        guard let inner = try? JSONDecoder().decode(NoiseMessage1Payload.self, from: message1Payload) else {
            throw HandshakeError.malformed
        }

        guard let candidate = PskCandidate.select(
            from: candidates, pskId: inner.pskId, serverId: serverId
        ) else { throw HandshakeError.pskLookupMiss }

        // Noise message 2, PSK mixed at the psk2 position; payload is the literal `{}`.
        let noiseMessage2: Data
        let transportStates: NoiseTransport
        do {
            noiseMessage2 = try handshake.writeMessage2(psk: candidate.psk, payload: noiseMessage2Payload)
            transportStates = try handshake.makeTransport()
        } catch let error as NoiseError {
            throw HandshakeError.noise(error)
        }
        let message2 = NoiseHandshakeMessage(
            payload: NoiseHandshakePayload(data: Base64URL.encode(noiseMessage2))
        )
        guard let message2Text = try String(data: encoder.encode(message2), encoding: .utf8) else {
            throw HandshakeError.malformed
        }
        try await transport.sendRawText(message2Text)

        return NoiseSessionOutcome(
            channel: NoiseChannel(transport: transportStates),
            serverId: serverId,
            serverStaticPublicKey: serverStaticKey,
            suite: suite,
            matchedCandidate: candidate
        )
    }

    /// Pull the next frame, requiring a text frame within `timeout`. The timeout is
    /// a watchdog that *disconnects the transport*: a parked `nextFrame()` pull is
    /// released by `disconnect()` finishing the frame stream, never by cancellation
    /// (the FrameInbox contract).
    private static func nextTextFrame(
        from transport: any SendspinTransport,
        timeout: Duration
    ) async throws -> Data {
        let watchdog = Task { () -> Bool in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return false // cancelled: the frame arrived in time
            }
            await transport.disconnect()
            return true
        }
        let frame = await transport.nextFrame()
        watchdog.cancel()
        let timedOut = await watchdog.value
        // The deadline wins a race with an arriving frame: the watchdog already
        // disconnected, so proceeding would run the next phase on a dead connection.
        if timedOut {
            throw HandshakeError.timeout
        }

        switch frame {
        case let .text(text):
            return Data(text.utf8)
        case .binary:
            throw HandshakeError.malformed
        case nil:
            throw HandshakeError.transportClosed
        }
    }
}
