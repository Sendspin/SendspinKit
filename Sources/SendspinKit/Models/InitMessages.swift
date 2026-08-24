import Foundation

/// The single core message-format version this implementation speaks. Both sides
/// send it in their init message and abort the handshake on any other value —
/// exact match, not a minimum (spec `client/init` note).
let sendspinCoreVersion = 1

// MARK: - Cleartext handshake messages

/// `client/init` — the first message on a fresh WebSocket, sent as a cleartext text
/// frame. Carries what the server needs to conduct the Noise handshake. The exact
/// bytes as transmitted become the first half of the Noise prologue.
struct ClientInitMessage: SendspinMessage, Equatable {
    static let typeString = "client/init"
    let type = Self.typeString
    let payload: ClientInitPayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ClientInitPayload: Codable, Equatable {
    /// The client's static public key: 43-character base64url Curve25519 (`client_id`).
    let clientId: String
    let version: Int
    /// The cipher suite the client picked; servers support both, so no negotiation.
    let suite: NoiseCipherSuite

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case version
        case suite
    }
}

/// `server/init` — the cleartext reply to `client/init`. The exact bytes as received
/// become the second half of the Noise prologue.
struct ServerInitMessage: SendspinMessage, Equatable {
    static let typeString = "server/init"
    let type = Self.typeString
    let payload: ServerInitPayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ServerInitPayload: Codable, Equatable {
    /// The server's static public key: 43-character base64url Curve25519 (`server_id`).
    let serverId: String
    let version: Int

    enum CodingKeys: String, CodingKey {
        case serverId = "server_id"
        case version
    }
}

/// `noise/handshake` — carries one Noise handshake message, base64url-encoded.
/// Travels as a cleartext text frame during initial establishment, and as an
/// encrypted JSON message (binary frame, message type 0) during a re-handshake.
struct NoiseHandshakeMessage: SendspinMessage, Equatable {
    static let typeString = "noise/handshake"
    let type = Self.typeString
    let payload: NoiseHandshakePayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct NoiseHandshakePayload: Codable, Equatable {
    /// Base64url-encoded Noise handshake message bytes (no padding).
    let data: String
}

/// The encrypted JSON object inside Noise message 1: the `psk_id` the client uses
/// to select its PSK before processing message 2.
struct NoiseMessage1Payload: Codable, Equatable {
    let pskId: String

    enum CodingKeys: String, CodingKey {
        case pskId = "psk_id"
    }
}

/// The encrypted payload inside Noise message 2: the spec fixes it as the literal
/// two bytes `{}` (an empty JSON object, not a zero-length Noise payload).
let noiseMessage2Payload = Data("{}".utf8)
