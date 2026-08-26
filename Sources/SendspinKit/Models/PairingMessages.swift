import Foundation

/// `pair/abort` — aborts a pairing attempt, started or not. With reason
/// `concurrent_attempt` the sender closes the connection after sending; otherwise
/// the connection stays open.
struct PairAbortMessage: SendspinMessage, Equatable {
    static let typeString = "pair/abort"
    let type = Self.typeString
    let payload: PairAbortPayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct PairAbortPayload: Codable, Equatable, Sendable {
    let reason: PairAbortReason
}

/// `client/pair-pending` reports that a gesture-gated attempt is waiting.
struct ClientPairPendingMessage: SendspinMessage, Equatable {
    static let typeString = "client/pair-pending"
    let type = Self.typeString
    let payload: ClientPairPendingPayload
    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ClientPairPendingPayload: Codable, Equatable, Sendable {
    let pairingIndex: UInt32
    enum CodingKeys: String, CodingKey { case pairingIndex = "pairing_index" }
}

/// `client/pair-init` starts a code-based pairing attempt.
struct ClientPairInitMessage: SendspinMessage, Equatable {
    static let typeString = "client/pair-init"
    let type = Self.typeString
    let payload: ClientPairInitPayload
    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ClientPairInitPayload: Codable, Equatable, Sendable {
    let pairingIndex: UInt32
    let commitB: String?
    enum CodingKeys: String, CodingKey {
        case pairingIndex = "pairing_index"
        case commitB = "commit_B"
    }
}

struct ServerPairInitMessage: SendspinMessage, Equatable {
    static let typeString = "server/pair-init"
    let type = Self.typeString
    let payload: ServerPairInitPayload
    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ServerPairInitPayload: Codable, Equatable, Sendable {
    let nonceA: String
    enum CodingKeys: String, CodingKey { case nonceA = "nonce_A" }
}

struct ServerPairAuthMessage: SendspinMessage, Equatable {
    static let typeString = "server/pair-auth"
    let type = Self.typeString
    let payload: ServerPairAuthPayload
    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ServerPairAuthPayload: Codable, Equatable, Sendable {
    let pakeMsg1: String
    enum CodingKeys: String, CodingKey { case pakeMsg1 = "pake_msg_1" }
}

struct ClientPairAuthMessage: SendspinMessage, Equatable {
    static let typeString = "client/pair-auth"
    let type = Self.typeString
    let payload: ClientPairAuthPayload
    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ClientPairAuthPayload: Codable, Equatable, Sendable {
    let pakeMsg2: String
    enum CodingKeys: String, CodingKey { case pakeMsg2 = "pake_msg_2" }
}

struct ServerPairConfirmMessage: SendspinMessage, Equatable {
    static let typeString = "server/pair-confirm"
    let type = Self.typeString
    let payload: ServerPairConfirmPayload
    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ServerPairConfirmPayload: Codable, Equatable, Sendable {
    let serverKc: String
    enum CodingKeys: String, CodingKey { case serverKc = "server_kc" }
}

struct ClientPairConfirmMessage: SendspinMessage, Equatable {
    static let typeString = "client/pair-confirm"
    let type = Self.typeString
    let payload: ClientPairConfirmPayload
    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ClientPairConfirmPayload: Codable, Equatable, Sendable {
    let clientKc: String
    let wrappedNonceB: String?
    enum CodingKeys: String, CodingKey {
        case clientKc = "client_kc"
        case wrappedNonceB = "wrapped_nonce_B"
    }
}

/// `client/pair-finalize` carries either a direct or CPace-wrapped PSK.
struct ClientPairFinalizeMessage: SendspinMessage, Equatable {
    static let typeString = "client/pair-finalize"
    let type = Self.typeString
    let payload: ClientPairFinalizePayload
    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ClientPairFinalizePayload: Codable, Equatable, Sendable {
    let longTermPsk: String
    let wrappedPsk: String?
    enum CodingKeys: String, CodingKey {
        case longTermPsk = "long_term_psk"
        case wrappedPsk = "wrapped_psk"
    }

    init(longTermPsk: String) {
        self.longTermPsk = longTermPsk
        wrappedPsk = nil
    }

    init(wrappedPsk: String) {
        longTermPsk = ""
        self.wrappedPsk = wrappedPsk
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        longTermPsk = try container.decodeIfPresent(String.self, forKey: .longTermPsk) ?? ""
        wrappedPsk = try container.decodeIfPresent(String.self, forKey: .wrappedPsk)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !longTermPsk.isEmpty {
            try container.encode(longTermPsk, forKey: .longTermPsk)
        }
        if let wrappedPsk {
            try container.encode(wrappedPsk, forKey: .wrappedPsk)
        }
    }
}

/// `server/pair-finalize` confirms that the server persisted the new record.
struct ServerPairFinalizeMessage: SendspinMessage, Equatable {
    static let typeString = "server/pair-finalize"
    let type = Self.typeString
    let payload: ServerPairFinalizePayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ServerPairFinalizePayload: Codable, Equatable, Sendable {}

/// `server/unpair` asks the client to discard its server-bound record.
struct ServerUnpairMessage: SendspinMessage, Equatable {
    static let typeString = "server/unpair"
    let type = Self.typeString
    let payload: ServerUnpairPayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ServerUnpairPayload: Codable, Equatable, Sendable {}

public enum PairAbortReason: String, Codable, Sendable, Hashable {
    case attemptTimeout = "attempt_timeout"
    case concurrentAttempt = "concurrent_attempt"
    case methodNotSupported = "method_not_supported"
    case pairingCodeMismatch = "pairing_code_mismatch"
    case userCancelled = "user_cancelled"
}

/// The trust level the client extends to a server in `client/hello`: `user`
/// reflects a pairing record for this server; `none` covers pairing handshakes
/// and unpaired access.
public enum TrustLevel: String, Codable, Sendable, Hashable {
    case user
    case none
}

/// One entry in `client/hello`'s `supported_pair_methods`.
struct PairMethodDescriptor: Codable, Equatable, Sendable {
    let method: String
    let outChannels: [String]?
    let formats: [String]?
    let locations: [String]?

    enum CodingKeys: String, CodingKey {
        case method
        case outChannels = "out_channels"
        case formats
        case locations
    }

    init(method: String, outChannels: [String]? = nil, formats: [String]? = nil, locations: [String]? = nil) {
        self.method = method
        self.outChannels = outChannels
        self.formats = formats
        self.locations = locations
    }
}

/// The `unpaired_access` object in `client/hello`.
struct UnpairedAccessAdvertisement: Codable, Equatable, Sendable {
    let enabled: Bool
}
