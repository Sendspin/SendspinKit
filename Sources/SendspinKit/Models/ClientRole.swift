// ABOUTME: Defines the possible roles a Sendspin client can assume
// ABOUTME: Clients can have multiple roles simultaneously (e.g., player + controller)

/// Roles that a Sendspin client can assume
public enum ClientRole: String, Codable, Sendable, Hashable {
    /// Outputs synchronized audio
    case player
    /// Controls the Sendspin group
    case controller
    /// Displays text metadata
    case metadata
    /// Displays artwork images
    case artwork
    /// Visualizes audio
    case visualizer
}
