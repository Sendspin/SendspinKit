import CryptoKit
import Foundation

/// Which trust bucket a PSK belongs to. The spec's three categories share one
/// `psk_id` namespace; on a handshake match, the stored category determines how the
/// session proceeds (allowed activity sets, trust level).
enum PskCategory: Sendable, Equatable {
    /// A long-term Sendspin PSK from a pairing record.
    case longTerm
    /// The client's Sendspin Pairing PSK (admits only the `pairing` activity).
    case pairing
    /// The published Sentinel PSK — no authentication on its own.
    case sentinel
}

/// A 32-byte Noise pre-shared key.
struct Psk: Sendable, Equatable {
    /// UTF-8 label prefixed to the PSK when deriving its `psk_id`.
    static let pskIdLabel = "sendspin-psk-id-v1"
    /// UTF-8 label whose SHA-256 hash is the published Sentinel PSK value.
    static let sentinelLabel = "sendspin-sentinel-psk-v1"

    let bytes: Data

    /// Fails unless `bytes` is exactly 32 bytes.
    init?(bytes: Data) {
        guard bytes.count == 32 else { return nil }
        self.bytes = bytes
    }

    /// Draw a fresh PSK from the system CSPRNG.
    static func generate() -> Psk {
        let key = SymmetricKey(size: .bits256)
        // Force-unwrap is safe: a 256-bit key is exactly 32 bytes by construction.
        return Psk(bytes: key.withUnsafeBytes { Data($0) })!
    }

    /// The published Sentinel PSK: `SHA-256("sendspin-sentinel-psk-v1")`.
    static let sentinel: Psk = {
        let digest = SHA256.hash(data: Data(sentinelLabel.utf8))
        return Psk(bytes: Data(digest))!
    }()

    /// The spec's PSK identifier: `base64url(SHA-256("sendspin-psk-id-v1" || PSK))`,
    /// 43 characters, no padding.
    var pskId: String {
        var input = Data(Self.pskIdLabel.utf8)
        input.append(bytes)
        return Base64URL.encode(Data(SHA256.hash(data: input)))
    }

    /// The 43-character base64url form used on the wire and in pairing tokens.
    var base64URL: String {
        Base64URL.encode(bytes)
    }

    /// Decode a 43-character base64url PSK. Returns `nil` for malformed input.
    init?(base64URL: String) {
        guard let data = Base64URL.decode(base64URL, count: 32) else { return nil }
        bytes = data
    }
}

extension Psk: CustomStringConvertible, CustomDebugStringConvertible {
    /// Prints only the public `psk_id` — never the secret bytes — so reflection,
    /// interpolation, and logging cannot leak the PSK.
    var description: String {
        "Psk(psk_id: \(pskId))"
    }

    var debugDescription: String {
        description
    }
}

/// One entry in the client's handshake PSK candidate set: sentinel + pairing PSK +
/// every enabled pairing record.
struct PskCandidate: Sendable, Equatable {
    let psk: Psk
    let category: PskCategory
    /// For stored-pubkey records: the `server_id` this PSK is bound to. After a
    /// `psk_id` match, the handshake fails unless the connection's `server_id`
    /// equals this value. `nil` for shared-PSK records and the sentinel/pairing PSKs.
    let requiredServerId: String?

    init(psk: Psk, category: PskCategory, requiredServerId: String? = nil) {
        self.psk = psk
        self.category = category
        self.requiredServerId = requiredServerId
    }
}

extension PskCandidate {
    /// Select the candidate matching the `psk_id` from Noise message 1, enforcing the
    /// stored-pubkey post-match check against the `server_id` from `server/init`.
    /// `nil` means lookup miss → the handshake fails (spec Failure Handling).
    /// Candidates must carry unique `psk_id`s — the spec enforces uniqueness where
    /// records are *configured*, so a duplicate here resolves arbitrarily.
    static func select(
        from candidates: [PskCandidate],
        pskId: String,
        serverId: String
    ) -> PskCandidate? {
        guard let match = candidates.first(where: { $0.psk.pskId == pskId }) else {
            return nil
        }
        if let required = match.requiredServerId, required != serverId {
            return nil
        }
        return match
    }
}
