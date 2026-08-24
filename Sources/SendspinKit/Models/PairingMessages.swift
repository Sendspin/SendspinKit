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
enum TrustLevel: String, Codable, Sendable, Hashable {
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
