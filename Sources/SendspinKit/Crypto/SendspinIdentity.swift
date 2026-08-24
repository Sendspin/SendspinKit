import CryptoKit
import Foundation

/// The client's long-lived Noise identity: a Curve25519 static keypair.
///
/// Per the spec's Identities section, the base64url-encoded public key (43 characters,
/// no padding) *is* the `client_id` — it serves both as the persistence/routing
/// identifier and as the client's static key in the `KKpsk2` Noise handshake.
/// Rotating the keypair changes the identity, so the secret key must be persisted
/// by the host app (see ``SendspinIdentityProvider``).
public struct SendspinIdentity: Sendable {
    /// Raw 32-byte Curve25519 secret key. Hand this to the host app's storage;
    /// treat it like any other long-lived credential.
    public let secretKeyBytes: Data

    let privateKey: Curve25519.KeyAgreement.PrivateKey

    /// The `client_id`: base64url (no padding) of the static public key, 43 characters.
    public var clientId: String {
        Base64URL.encode(privateKey.publicKey.rawRepresentation)
    }

    /// Raw 32-byte Curve25519 public key.
    public var publicKeyBytes: Data {
        privateKey.publicKey.rawRepresentation
    }

    /// Generate a fresh identity from the system CSPRNG.
    public static func generate() -> SendspinIdentity {
        SendspinIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    }

    /// Restore an identity from a previously persisted 32-byte secret key.
    /// Returns `nil` if `secretKeyBytes` is not a valid Curve25519 secret key.
    public init?(secretKeyBytes: Data) {
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secretKeyBytes) else {
            return nil
        }
        self.init(privateKey: key)
    }

    init(privateKey: Curve25519.KeyAgreement.PrivateKey) {
        self.privateKey = privateKey
        secretKeyBytes = privateKey.rawRepresentation
    }
}

extension SendspinIdentity: CustomStringConvertible, CustomDebugStringConvertible {
    /// Prints only the public `client_id` — never the secret key — so reflection,
    /// interpolation, and logging cannot leak the identity secret.
    public var description: String {
        "SendspinIdentity(client_id: \(clientId))"
    }

    public var debugDescription: String {
        description
    }
}

/// Storage hook for the client's static identity keypair.
///
/// The spec requires the identity to be persistent across reboots (it *is* the
/// `client_id`), but SendspinKit never persists anything itself: the host app backs
/// this with the Keychain, a file, or whatever fits its platform. Same contract shape
/// as ``SendspinPersistenceProvider`` — `async` so implementations may do I/O, and
/// `Sendable` because the provider crosses concurrency domains.
///
/// The expected pattern: `loadIdentitySecret()` returning `nil` means first run —
/// the caller generates a fresh ``SendspinIdentity`` and hands its
/// ``SendspinIdentity/secretKeyBytes`` to `saveIdentitySecret(_:)`.
public protocol SendspinIdentityProvider: Sendable {
    /// The persisted 32-byte identity secret key, or `nil` if none has been stored yet.
    func loadIdentitySecret() async -> Data?

    /// Persist `secret` as the client's identity secret key.
    func saveIdentitySecret(_ secret: Data) async
}
