// ABOUTME: Configuration for artwork role capabilities
// ABOUTME: Specifies artwork channels the client can display (format, resolution, source)

/// Configuration for the artwork role, provided when creating a ``SendspinClient``.
///
/// Declares 1–4 artwork channels the client supports. Each channel can independently
/// display album art, artist images, or be disabled (`source: .none`). The array index
/// determines the channel number and corresponding binary message type (8–11).
///
/// This is a client-side configuration container, not a wire type — it is not `Codable`.
/// The individual ``ArtworkChannel`` values it wraps handle their own serialization.
public struct ArtworkConfiguration: Sendable, Hashable {
    /// Supported artwork channels (1–4). Array index is the channel number.
    public let channels: [ArtworkChannel]

    public init(channels: [ArtworkChannel]) {
        precondition(!channels.isEmpty, "Must have at least one artwork channel")
        precondition(channels.count <= 4, "Maximum 4 artwork channels")
        self.channels = channels
    }
}
