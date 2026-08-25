import CryptoKit
import Foundation
@testable import SendspinKit
import Testing

/// A test-side Sendspin server speaking real Noise as the KKpsk2 initiator over a
/// ``MockTransport``. Drives the cleartext establishment (`client/init` →
/// `server/init` → `noise/handshake` ×2) and then exchanges encrypted frames, so
/// client-side code is tested against a genuine peer rather than a mirror of itself.
actor MockNoiseServer {
    enum Failure: Error {
        case unexpectedFrame
        case malformedClientMessage
    }

    let staticKey: Curve25519.KeyAgreement.PrivateKey
    let psk: Psk
    let transport: MockTransport

    /// When set, the server encodes a *different* `server/init` into its prologue
    /// than the bytes it actually sent — simulating on-the-wire tampering with the
    /// cleartext init exchange, which the prologue binding must catch.
    var tamperProloguePostSend = false

    /// When set, this exact text goes on the wire as `server/init` (and into the
    /// prologue), so tests can prove the client hashes received bytes as-is.
    var serverInitTextOverride: String?

    /// The decrypted inner payload of Noise message 2 (spec: the literal `{}`).
    private(set) var message2Payload: Data?
    private(set) var decryptedMessages: [Data] = []
    private var nextClientMessageIndex = 0
    private var readbackTask: Task<Void, Never>?

    /// The server-side encrypted channel, available once the handshake completes.
    private(set) var channel: NoiseChannel?

    var serverId: String {
        Base64URL.encode(staticKey.publicKey.rawRepresentation)
    }

    var sentTextMessages: [Data] {
        get async {
            let deadline = ContinuousClock.now + .milliseconds(500)
            while !decryptedMessages.contains(where: { $0.first == NoiseFrameType.json }), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return decryptedMessages.compactMap { message in
                guard message.first == NoiseFrameType.json else { return nil }
                return Data(message.dropFirst())
            }
        }
    }

    var sentBinaryMessages: [Data] {
        get async { await transport.sentBinaryMessages }
    }

    func injectText(_ text: String) async {
        try? await sendJSON(text)
    }

    func injectBinary(_ data: Data) async {
        try? await sendEncrypted(data)
    }

    func sendBinary(_ data: Data) async {
        await transport.injectBinary(data)
    }

    func finishStreams() async {
        await transport.finishStreams()
    }

    var disconnectCalled: Bool {
        get async { await transport.disconnectCalled }
    }

    func setShouldFailOnSend(_ value: Bool) async {
        await transport.setShouldFailOnSend(value)
    }

    func enableGoodbyeGate() async {
        await transport.enableGoodbyeGate()
    }

    var isGoodbyeGateWaiting: Bool {
        get async { await transport.isGoodbyeGateWaiting }
    }

    func releaseGoodbyeGate() async {
        await transport.releaseGoodbyeGate()
    }

    func simulateClose(_ reason: TransportCloseReason) async {
        await transport.simulateClose(reason)
    }

    init(
        transport: MockTransport,
        staticKey: Curve25519.KeyAgreement.PrivateKey = .init(),
        psk: Psk = .generate()
    ) {
        self.transport = transport
        self.staticKey = staticKey
        self.psk = psk
    }

    func setTamperProloguePostSend(_ value: Bool) {
        tamperProloguePostSend = value
    }

    func setServerInitTextOverride(_ text: String?) {
        serverInitTextOverride = text
    }

    /// Respond to a client establishment attempt already in flight on the transport.
    /// Overrides let tests inject spec violations at each step.
    func respondToHandshake(
        serverInitVersion: Int = sendspinCoreVersion,
        pskIdOverride: String? = nil
    ) async throws {
        // client/init — learn the client's static key (KK pre-known via client_id).
        guard case let .text(clientInitText) = await transport.nextSentFrame() else {
            throw Failure.unexpectedFrame
        }
        let clientInitBytes = Data(clientInitText.utf8)
        guard SendspinEncoding.messageType(of: clientInitBytes) == ClientInitMessage.typeString,
              let clientInit = try? JSONDecoder().decode(ClientInitMessage.self, from: clientInitBytes),
              let clientKeyBytes = Base64URL.decode(clientInit.payload.clientId, count: 32),
              let clientStaticKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientKeyBytes)
        else { throw Failure.malformedClientMessage }
        let suite = clientInit.payload.suite

        // server/init — keep the exact bytes for the prologue.
        let encoder = SendspinEncoding.makeEncoder()
        let serverInitBytes: Data
        if let override = serverInitTextOverride {
            serverInitBytes = Data(override.utf8)
            await transport.injectText(override)
        } else {
            let serverInit = ServerInitMessage(
                payload: ServerInitPayload(serverId: serverId, version: serverInitVersion)
            )
            serverInitBytes = try encoder.encode(serverInit)
            guard let serverInitText = String(bytes: serverInitBytes, encoding: .utf8) else {
                throw Failure.malformedClientMessage
            }
            await transport.injectText(serverInitText)
        }

        var prologue = clientInitBytes
        if tamperProloguePostSend {
            prologue.append(Data("tampered".utf8))
        } else {
            prologue.append(serverInitBytes)
        }

        var handshake = NoiseHandshake(
            suite: suite,
            role: .initiator,
            localStaticKey: staticKey,
            remoteStaticPublicKey: clientStaticKey,
            prologue: prologue
        )

        // Noise message 1 with the psk_id payload.
        let message1Payload = try JSONEncoder().encode(
            NoiseMessage1Payload(pskId: pskIdOverride ?? psk.pskId)
        )
        let message1 = try handshake.writeMessage1(payload: message1Payload)
        let message1Bytes = try encoder.encode(
            NoiseHandshakeMessage(payload: NoiseHandshakePayload(data: Base64URL.encode(message1)))
        )
        guard let message1Text = String(bytes: message1Bytes, encoding: .utf8) else {
            throw Failure.malformedClientMessage
        }
        await transport.injectText(message1Text)

        // Noise message 2 from the client.
        guard case let .text(message2Text) = await transport.nextSentFrame() else {
            throw Failure.unexpectedFrame
        }
        guard let message2 = try? JSONDecoder().decode(
            NoiseHandshakeMessage.self, from: Data(message2Text.utf8)
        ), let noiseMessage2 = Base64URL.decode(message2.payload.data) else {
            throw Failure.malformedClientMessage
        }
        message2Payload = try handshake.readMessage2(noiseMessage2, psk: psk)
        channel = try NoiseChannel(transport: handshake.makeTransport())
    }

    /// Send the server hello and consume the client's hello, leaving activation
    /// for the caller so tests can queue encrypted frames behind the handshake.
    func beginAdmission(name: String = "Test Server") async throws {
        try await respondToHandshake()
        try await sendJSON(#"{"type":"server/hello","payload":{"name":"\#(name)"}}"#)
        let hello = try await nextClientJSON()
        let object = try #require(JSONSerialization.jsonObject(with: hello) as? [String: Any])
        let payload = try #require(object["payload"] as? [String: Any])
        #expect(object["type"] as? String == ClientHelloMessage.typeString)
        #expect(payload["name"] is String)
        #expect(payload["trust_level"] as? String == TrustLevel.none.rawValue)
        #expect((payload["supported_pair_methods"] as? [Any])?.isEmpty == true)
        #expect(payload["unpaired_access"] is [String: Any])
        startReadback()
    }

    func sendActivation(activities: Set<Activity> = [], activeRoles: [VersionedRole] = []) async throws {
        let activate = ServerActivateMessage(
            payload: ServerActivatePayload(
                activities: Array(activities),
                activeRoles: activeRoles
            )
        )
        let data = try JSONEncoder().encode(activate)
        try await sendJSON(String(bytes: data, encoding: .utf8) ?? "")
    }

    /// Establish the encrypted session through the first admitted activation.
    func establishSession(
        name: String = "Test Server",
        activities: Set<Activity> = [],
        activeRoles: [VersionedRole] = []
    ) async throws {
        try await beginAdmission(name: name)
        try await sendActivation(activities: activities, activeRoles: activeRoles)
    }

    /// Record and decrypt one client-sent encrypted frame for observational readback.
    func startReadback() {
        readbackTask = Task { [self] in
            while !Task.isCancelled {
                guard case let .binary(frame) = await transport.nextSentFrame() else { return }
                observeClientFrame(frame)
            }
        }
    }

    func observeClientFrame(_ frame: Data) {
        if let message = try? channel?.decryptFrame(frame) {
            decryptedMessages.append(message)
        }
    }

    /// Encrypt and deliver one JSON message to the client.
    func encryptedTextSender() -> @Sendable (String) async throws -> Void {
        { [self] text in
            try await sendJSON(text)
        }
    }

    func encryptedBinarySender() -> @Sendable (Data) async throws -> Void {
        { [self] data in
            try await sendEncrypted(data)
        }
    }

    func sendJSON(_ text: String) async throws {
        var message = Data([NoiseFrameType.json])
        message.append(contentsOf: text.utf8)
        try await sendEncrypted(message)
    }

    /// Encrypt and deliver one plaintext message (`[type][payload]`) to the client,
    /// fragmenting as needed.
    func sendEncrypted(_ message: Data) async throws {
        let frames = try channel!.encryptMessage(message)
        for frame in frames {
            await transport.injectBinary(frame)
        }
    }

    /// Pull client-sent binary frames until one complete JSON message reassembles.
    func nextClientJSON() async throws -> Data {
        let message = try await nextDecryptedMessage()
        guard message.first == NoiseFrameType.json else { throw Failure.unexpectedFrame }
        return Data(message.dropFirst())
    }

    /// Pull client-sent binary frames until one complete plaintext message reassembles.
    func nextDecryptedMessage() async throws -> Data {
        if nextClientMessageIndex < decryptedMessages.count {
            let message = decryptedMessages[nextClientMessageIndex]
            nextClientMessageIndex += 1
            return message
        }

        while true {
            guard case let .binary(frame) = await transport.nextSentFrame() else {
                throw Failure.unexpectedFrame
            }
            if let message = try channel!.decryptFrame(frame) {
                decryptedMessages.append(message)
                nextClientMessageIndex += 1
                return message
            }
        }
    }
}
