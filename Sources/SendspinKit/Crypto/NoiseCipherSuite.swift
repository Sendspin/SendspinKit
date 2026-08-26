import CryptoKit
import Foundation

/// A Sendspin cipher suite: the `<DH>_<cipher>_<hash>` part of the full Noise
/// protocol name. Both suites share Curve25519 and SHA-256; only the AEAD differs.
/// The client announces its pick in `client/init`; servers must support both, so no
/// negotiation happens.
enum NoiseCipherSuite: String, CaseIterable, Sendable, Codable {
    case chaChaPoly = "25519_ChaChaPoly_SHA256"
    case aesGCM = "25519_AESGCM_SHA256"

    /// Full Noise protocol name for the spec's fixed handshake pattern.
    var protocolName: String {
        "Noise_KKpsk2_\(rawValue)"
    }

    /// Byte length of the AEAD authentication tag (16 for both suites).
    static let tagLength = 16

    /// Noise nonce formatting: 4 zero bytes followed by the 64-bit counter —
    /// little-endian for ChaChaPoly, big-endian for AES-GCM (Noise spec §12).
    private func nonceData(_ counter: UInt64) -> Data {
        var data = Data(repeating: 0, count: 4)
        let value = switch self {
        case .chaChaPoly: counter.littleEndian
        case .aesGCM: counter.bigEndian
        }
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        return data
    }

    /// AEAD-encrypt. Returns ciphertext with the 16-byte tag appended.
    func encrypt(
        key: SymmetricKey,
        counter: UInt64,
        associatedData: Data,
        plaintext: Data
    ) throws -> Data {
        switch self {
        case .chaChaPoly:
            let nonce = try ChaChaPoly.Nonce(data: nonceData(counter))
            let box = try ChaChaPoly.seal(
                plaintext, using: key, nonce: nonce, authenticating: associatedData
            )
            return box.ciphertext + box.tag
        case .aesGCM:
            let nonce = try AES.GCM.Nonce(data: nonceData(counter))
            let box = try AES.GCM.seal(
                plaintext, using: key, nonce: nonce, authenticating: associatedData
            )
            return box.ciphertext + box.tag
        }
    }

    /// AEAD-decrypt ciphertext-with-appended-tag. Throws ``NoiseError/decryptFailed``
    /// on any authentication failure — a tampered, replayed, or reordered message.
    func decrypt(
        key: SymmetricKey,
        counter: UInt64,
        associatedData: Data,
        ciphertext: Data
    ) throws -> Data {
        guard ciphertext.count >= Self.tagLength else { throw NoiseError.malformedMessage }
        let split = ciphertext.index(ciphertext.endIndex, offsetBy: -Self.tagLength)
        let body = ciphertext[ciphertext.startIndex ..< split]
        let tag = ciphertext[split...]
        do {
            switch self {
            case .chaChaPoly:
                let nonce = try ChaChaPoly.Nonce(data: nonceData(counter))
                let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: body, tag: tag)
                return try ChaChaPoly.open(box, using: key, authenticating: associatedData)
            case .aesGCM:
                let nonce = try AES.GCM.Nonce(data: nonceData(counter))
                let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: body, tag: tag)
                return try AES.GCM.open(box, using: key, authenticating: associatedData)
            }
        } catch {
            throw NoiseError.decryptFailed
        }
    }
}

/// Failures inside the Noise layer. Per the spec's Failure Handling section, every
/// one of these ends the connection: close the WebSocket, send nothing.
enum NoiseError: Error, Equatable {
    /// AEAD authentication failed — tampering, replay, reordering, or a wrong key/PSK.
    case decryptFailed
    /// A handshake or transport message violates the expected structure.
    case malformedMessage
    /// The per-direction 64-bit nonce counter is exhausted (Noise hard limit).
    case nonceExhausted
    /// A handshake step ran out of order (e.g. split before message 2).
    case invalidState
    /// A fragmentation rule was broken: fragment-end with nothing in flight, a
    /// non-fragment frame while a fragmented message is in flight, or a fragment
    /// type used as `orig_type` (spec Fragmentation, malformed sequences).
    case fragmentationViolation
    /// A fragmented message grew past the reassembly cap (DoS guard, not spec).
    case reassemblyLimitExceeded
}
