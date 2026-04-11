// ABOUTME: Data models for the artwork role in the Sendspin protocol
// ABOUTME: Defines artwork sources, image formats, channel configs, and client configuration

/// Artwork source type per Sendspin spec
public enum ArtworkSource: String, Codable, Sendable, Hashable {
    /// Album artwork
    case album
    /// Artist artwork
    case artist
    /// No artwork — channel disabled (allows toggling channels via stream/request-format)
    case none
}

/// Supported image formats for artwork per Sendspin spec
public enum ImageFormat: String, Codable, Sendable, Hashable {
    case jpeg
    case png
    case bmp
}

/// Configuration for a single artwork channel in client/hello.
/// Array index determines the channel number (0-3) and corresponding binary message type (8-11).
public struct ArtworkChannel: Codable, Sendable, Hashable {
    /// Artwork source type
    public let source: ArtworkSource
    /// Image format
    public let format: ImageFormat
    /// Max width in pixels
    public let mediaWidth: Int
    /// Max height in pixels
    public let mediaHeight: Int

    enum CodingKeys: String, CodingKey {
        case source
        case format
        case mediaWidth = "media_width"
        case mediaHeight = "media_height"
    }

    public init(source: ArtworkSource, format: ImageFormat, mediaWidth: Int, mediaHeight: Int) {
        precondition(mediaWidth > 0, "media_width must be positive")
        precondition(mediaHeight > 0, "media_height must be positive")
        self.source = source
        self.format = format
        self.mediaWidth = mediaWidth
        self.mediaHeight = mediaHeight
    }
}

/// Configuration for a single artwork channel as received in stream/start.
/// Note: uses `width`/`height` (not `media_width`/`media_height`) per spec.
public struct StreamArtworkChannelConfig: Codable, Sendable, Hashable {
    /// Artwork source type
    public let source: ArtworkSource
    /// Format of the encoded image
    public let format: ImageFormat
    /// Width in pixels of the encoded image
    public let width: Int
    /// Height in pixels of the encoded image
    public let height: Int

    public init(source: ArtworkSource, format: ImageFormat, width: Int, height: Int) {
        self.source = source
        self.format = format
        self.width = width
        self.height = height
    }
}

/// Configuration for the artwork role, provided when creating a SendspinClient.
/// Mirrors PlayerConfiguration's role as a role-specific config container.
public struct ArtworkConfiguration: Sendable {
    /// Supported artwork channels (1-4). Array index is the channel number.
    public let channels: [ArtworkChannel]

    public init(channels: [ArtworkChannel]) {
        precondition(!channels.isEmpty, "Must have at least one artwork channel")
        precondition(channels.count <= 4, "Maximum 4 artwork channels")
        self.channels = channels
    }
}
