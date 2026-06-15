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
}

/// Goodbye payload with required reason
struct GoodbyePayload: Codable, Equatable {
    let reason: GoodbyeReason
}
