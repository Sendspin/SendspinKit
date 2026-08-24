import CryptoKit
import Foundation

// Implements the Noise Protocol Framework (revision 34) restricted to what Sendspin
// uses: the KKpsk2 pattern over the two spec cipher suites, plus transport mode.
// The client is always the Noise responder; the initiator side exists so tests and
// the in-process mock server can drive real handshakes against the responder.

/// One direction of Noise AEAD traffic: a key plus a monotonically increasing
/// 64-bit counter. Decryption failure at any point is terminal for the connection —
/// the counter is never rewound, which is what gives Noise its replay protection.
struct NoiseCipherState: Sendable {
    let suite: NoiseCipherSuite
    private(set) var key: SymmetricKey?
    private(set) var counter: UInt64 = 0

    init(suite: NoiseCipherSuite, key: SymmetricKey? = nil, counter: UInt64 = 0) {
        self.suite = suite
        self.key = key
        self.counter = counter
    }

    /// `EncryptWithAd`: with no key yet, plaintext passes through (only possible
    /// during the earliest handshake steps).
    mutating func encrypt(associatedData: Data, plaintext: Data) throws -> Data {
        guard let key else { return plaintext }
        // The maximum counter value is reserved by the Noise spec; reaching it
        // means the session must end, never wrap.
        guard counter != .max else { throw NoiseError.nonceExhausted }
        let ciphertext = try suite.encrypt(
            key: key, counter: counter, associatedData: associatedData, plaintext: plaintext
        )
        counter += 1
        return ciphertext
    }

    /// `DecryptWithAd`: with no key yet, ciphertext passes through.
    mutating func decrypt(associatedData: Data, ciphertext: Data) throws -> Data {
        guard let key else { return ciphertext }
        guard counter != .max else { throw NoiseError.nonceExhausted }
        let plaintext = try suite.decrypt(
            key: key, counter: counter, associatedData: associatedData, ciphertext: ciphertext
        )
        counter += 1
        return plaintext
    }
}

/// Noise SymmetricState: the chaining key `ck`, the transcript hash `h`, and an
/// embedded CipherState for handshake-phase encryption.
struct NoiseSymmetricState {
    let suite: NoiseCipherSuite
    private(set) var chainingKey: Data
    private(set) var hash: Data
    private var cipher: NoiseCipherState

    init(suite: NoiseCipherSuite) {
        self.suite = suite
        // InitializeSymmetric: a name of 32 bytes or fewer is used directly as h,
        // zero-padded; a longer one is hashed. Both branches are live here — the
        // AESGCM protocol name is exactly 32 bytes, the ChaChaPoly one is 36.
        var name = Data(suite.protocolName.utf8)
        if name.count <= 32 {
            name.append(Data(count: 32 - name.count))
            hash = name
        } else {
            hash = Data(SHA256.hash(data: name))
        }
        chainingKey = hash
        cipher = NoiseCipherState(suite: suite)
    }

    /// Noise HKDF: RFC 5869 extract-and-expand with `ck` as salt and empty info.
    static func hkdf(chainingKey: Data, inputKeyMaterial: Data, outputs: Int) -> [Data] {
        let tempKey = SymmetricKey(
            data: HMAC<SHA256>.authenticationCode(
                for: inputKeyMaterial, using: SymmetricKey(data: chainingKey)
            )
        )
        var results: [Data] = []
        var previous = Data()
        for index in 1 ... outputs {
            var input = previous
            input.append(UInt8(index))
            previous = Data(HMAC<SHA256>.authenticationCode(for: input, using: tempKey))
            results.append(previous)
        }
        return results
    }

    mutating func mixHash(_ data: Data) {
        var input = hash
        input.append(data)
        hash = Data(SHA256.hash(data: input))
    }

    mutating func mixKey(_ inputKeyMaterial: Data) {
        let outputs = Self.hkdf(chainingKey: chainingKey, inputKeyMaterial: inputKeyMaterial, outputs: 2)
        chainingKey = outputs[0]
        cipher = NoiseCipherState(suite: suite, key: SymmetricKey(data: outputs[1]))
    }

    /// Used by the `psk` token: folds the PSK into both the key schedule and the
    /// transcript hash.
    mutating func mixKeyAndHash(_ inputKeyMaterial: Data) {
        let outputs = Self.hkdf(chainingKey: chainingKey, inputKeyMaterial: inputKeyMaterial, outputs: 3)
        chainingKey = outputs[0]
        mixHash(outputs[1])
        cipher = NoiseCipherState(suite: suite, key: SymmetricKey(data: outputs[2]))
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encrypt(associatedData: hash, plaintext: plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decrypt(associatedData: hash, ciphertext: ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    /// Derive the two transport CipherStates. First key encrypts initiator→responder.
    func split() -> (initiatorToResponder: NoiseCipherState, responderToInitiator: NoiseCipherState) {
        let outputs = Self.hkdf(chainingKey: chainingKey, inputKeyMaterial: Data(), outputs: 2)
        return (
            NoiseCipherState(suite: suite, key: SymmetricKey(data: outputs[0])),
            NoiseCipherState(suite: suite, key: SymmetricKey(data: outputs[1]))
        )
    }
}

/// The two transport-mode directions plus the final handshake hash `h` (which
/// becomes the prologue of a future re-handshake).
struct NoiseTransport: Sendable {
    var send: NoiseCipherState
    var receive: NoiseCipherState
    let handshakeHash: Data
}

/// A KKpsk2 handshake in progress.
///
/// ```text
/// KKpsk2:
///   -> s
///   <- s
///   ...
///   -> e, es, ss          (message 1: server → client, carries the psk_id payload)
///   <- e, ee, se, psk     (message 2: client → server)
/// ```
///
/// The PSK is not needed until message 2 — that is the property the spec's deferred
/// PSK selection relies on: the responder decrypts message 1, reads `psk_id`, picks
/// the matching PSK, and only then supplies it to ``writeMessage2(psk:payload:)``.
struct NoiseHandshake {
    enum Role: Sendable {
        case initiator
        case responder
    }

    private enum Phase {
        case awaitingMessage1
        case awaitingMessage2
        case complete
        case transportIssued
    }

    private var symmetric: NoiseSymmetricState
    private let role: Role
    private let localStatic: Curve25519.KeyAgreement.PrivateKey
    private let remoteStatic: Curve25519.KeyAgreement.PublicKey
    private var localEphemeral: Curve25519.KeyAgreement.PrivateKey?
    private var remoteEphemeral: Curve25519.KeyAgreement.PublicKey?
    private var phase: Phase = .awaitingMessage1
    /// Test seam: inject a deterministic ephemeral so known-answer vectors with
    /// fixed ephemerals can be replayed byte-for-byte. Production always passes nil.
    private let ephemeralOverride: Curve25519.KeyAgreement.PrivateKey?

    /// The running transcript hash. After message 2 this is the session's `h`.
    var handshakeHash: Data {
        symmetric.hash
    }

    init(
        suite: NoiseCipherSuite,
        role: Role,
        localStaticKey: Curve25519.KeyAgreement.PrivateKey,
        remoteStaticPublicKey: Curve25519.KeyAgreement.PublicKey,
        prologue: Data,
        ephemeralOverride: Curve25519.KeyAgreement.PrivateKey? = nil
    ) {
        self.role = role
        localStatic = localStaticKey
        remoteStatic = remoteStaticPublicKey
        self.ephemeralOverride = ephemeralOverride
        symmetric = NoiseSymmetricState(suite: suite)
        symmetric.mixHash(prologue)
        // KK pre-messages: the initiator's static, then the responder's static.
        switch role {
        case .initiator:
            symmetric.mixHash(localStatic.publicKey.rawRepresentation)
            symmetric.mixHash(remoteStatic.rawRepresentation)
        case .responder:
            symmetric.mixHash(remoteStatic.rawRepresentation)
            symmetric.mixHash(localStatic.publicKey.rawRepresentation)
        }
    }

    private static func dh(
        _ privateKey: Curve25519.KeyAgreement.PrivateKey,
        _ publicKey: Curve25519.KeyAgreement.PublicKey
    ) throws -> Data {
        do {
            let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
            return secret.withUnsafeBytes { Data($0) }
        } catch {
            // CryptoKit surfaces DH failures (e.g. an all-zero shared secret from a
            // degenerate peer point) as errors; any handshake-phase failure is
            // terminal for the connection, so the distinction does not matter here.
            throw NoiseError.malformedMessage
        }
    }

    private mutating func generateEphemeral() -> Curve25519.KeyAgreement.PrivateKey {
        let key = ephemeralOverride ?? Curve25519.KeyAgreement.PrivateKey()
        localEphemeral = key
        return key
    }

    /// Initiator writes message 1 (`e, es, ss` + encrypted payload).
    mutating func writeMessage1(payload: Data) throws -> Data {
        guard role == .initiator, phase == .awaitingMessage1 else { throw NoiseError.invalidState }
        let ephemeral = generateEphemeral()
        let ephemeralPublic = ephemeral.publicKey.rawRepresentation
        var message = ephemeralPublic
        symmetric.mixHash(ephemeralPublic)
        // In psk-modified patterns every `e` token also feeds the key schedule.
        symmetric.mixKey(ephemeralPublic)
        try symmetric.mixKey(Self.dh(ephemeral, remoteStatic)) // es
        try symmetric.mixKey(Self.dh(localStatic, remoteStatic)) // ss
        try message.append(symmetric.encryptAndHash(payload))
        phase = .awaitingMessage2
        return message
    }

    /// Responder reads message 1, returning the decrypted payload (the JSON object
    /// carrying `psk_id`). No PSK involved yet.
    mutating func readMessage1(_ message: Data) throws -> Data {
        guard role == .responder, phase == .awaitingMessage1 else { throw NoiseError.invalidState }
        guard message.count >= 32 + NoiseCipherSuite.tagLength else { throw NoiseError.malformedMessage }
        let ephemeralBytes = message.prefix(32)
        guard let peerEphemeral = try? Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: ephemeralBytes
        ) else { throw NoiseError.malformedMessage }
        remoteEphemeral = peerEphemeral
        symmetric.mixHash(Data(ephemeralBytes))
        symmetric.mixKey(Data(ephemeralBytes))
        try symmetric.mixKey(Self.dh(localStatic, peerEphemeral)) // es
        try symmetric.mixKey(Self.dh(localStatic, remoteStatic)) // ss
        let payload = try symmetric.decryptAndHash(Data(message.dropFirst(32)))
        phase = .awaitingMessage2
        return payload
    }

    /// Responder writes message 2 (`e, ee, se, psk` + encrypted payload). The PSK
    /// chosen from the message-1 `psk_id` is mixed here — the psk2 placement.
    mutating func writeMessage2(psk: Psk, payload: Data) throws -> Data {
        guard role == .responder, phase == .awaitingMessage2 else { throw NoiseError.invalidState }
        guard let remoteEphemeral else { throw NoiseError.invalidState }
        let ephemeral = generateEphemeral()
        let ephemeralPublic = ephemeral.publicKey.rawRepresentation
        var message = ephemeralPublic
        symmetric.mixHash(ephemeralPublic)
        symmetric.mixKey(ephemeralPublic)
        try symmetric.mixKey(Self.dh(ephemeral, remoteEphemeral)) // ee
        try symmetric.mixKey(Self.dh(ephemeral, remoteStatic)) // se
        symmetric.mixKeyAndHash(psk.bytes)
        try message.append(symmetric.encryptAndHash(payload))
        phase = .complete
        return message
    }

    /// Initiator reads message 2, mixing the same PSK, returning the payload.
    mutating func readMessage2(_ message: Data, psk: Psk) throws -> Data {
        guard role == .initiator, phase == .awaitingMessage2 else { throw NoiseError.invalidState }
        guard message.count >= 32 + NoiseCipherSuite.tagLength else { throw NoiseError.malformedMessage }
        guard let localEphemeral else { throw NoiseError.invalidState }
        let ephemeralBytes = message.prefix(32)
        guard let peerEphemeral = try? Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: ephemeralBytes
        ) else { throw NoiseError.malformedMessage }
        remoteEphemeral = peerEphemeral
        symmetric.mixHash(Data(ephemeralBytes))
        symmetric.mixKey(Data(ephemeralBytes))
        try symmetric.mixKey(Self.dh(localEphemeral, peerEphemeral)) // ee
        try symmetric.mixKey(Self.dh(localStatic, peerEphemeral)) // se
        symmetric.mixKeyAndHash(psk.bytes)
        let payload = try symmetric.decryptAndHash(Data(message.dropFirst(32)))
        phase = .complete
        return payload
    }

    /// Enter transport mode, consuming the handshake. Valid exactly once, after
    /// message 2: a second call would mint a duplicate transport whose ciphers share
    /// keys and restart at counter zero — AEAD nonce reuse — so it throws instead.
    mutating func makeTransport() throws -> NoiseTransport {
        guard phase == .complete else { throw NoiseError.invalidState }
        phase = .transportIssued
        let (initiatorToResponder, responderToInitiator) = symmetric.split()
        switch role {
        case .initiator:
            return NoiseTransport(
                send: initiatorToResponder,
                receive: responderToInitiator,
                handshakeHash: symmetric.hash
            )
        case .responder:
            return NoiseTransport(
                send: responderToInitiator,
                receive: initiatorToResponder,
                handshakeHash: symmetric.hash
            )
        }
    }
}
