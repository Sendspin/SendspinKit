import Foundation

// MARK: - Goodbye Messages

/// Client goodbye message (graceful disconnect)
struct ClientGoodbyeMessage: SendspinMessage, Equatable {
    static let typeString = "client/goodbye"
    let type = Self.typeString
    let payload: GoodbyePayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

/// Goodbye reason per spec
public enum GoodbyeReason: String, Codable, Sendable, Hashable {
    /// Switching to a different server
    case anotherServer = "another_server"
    /// Client is shutting down
    case shutdown
    /// Client is restarting and will reconnect
    case restart
    /// User explicitly requested disconnect
    case userRequest = "user_request"
    /// The client is no longer authorized for the connection (inadmissible
    /// activity set, or its own pairing record was removed)
    case unauthorized
    /// Unpaired access is disabled and the activation would need it
    case pairingRequired = "pairing_required"
    /// A higher-or-equal-priority connection is already active
    case concurrentAttempt = "concurrent_attempt"
    /// The client processed `server/unpair` from this server
    case unpaired
}

/// Goodbye payload with required reason
struct GoodbyePayload: Codable, Equatable {
    let reason: GoodbyeReason
}
