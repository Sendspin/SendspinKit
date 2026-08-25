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

/// `client/pair-finalize` carries the newly generated long-term PSK.
struct ClientPairFinalizeMessage: SendspinMessage, Equatable {
    static let typeString = "client/pair-finalize"
    let type = Self.typeString
    let payload: ClientPairFinalizePayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ClientPairFinalizePayload: Codable, Equatable, Sendable {
    let longTermPsk: String

    enum CodingKeys: String, CodingKey {
        case longTermPsk = "long_term_psk"
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

enum PairAbortReason: String, Codable, Sendable, Hashable {
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
