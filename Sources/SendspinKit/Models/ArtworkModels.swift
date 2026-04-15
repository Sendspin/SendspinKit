// ABOUTME: Wire-format data models for the artwork role in the Sendspin protocol
// ABOUTME: Defines artwork sources, image formats, and channel configs used across artwork messages

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
    /// Image format. Required by the spec even for disabled channels (`source: .none`);
    /// use ``disabled`` for a convenient placeholder.
    public let format: ImageFormat
    /// Max width in pixels
    public let mediaWidth: Int
    /// Max height in pixels
    public let mediaHeight: Int

    // A disabled channel placeholder. Format is `.jpeg` by arbitrary convention;
    // any format is valid since the server ignores it for `source: .none` channels.
    // Uses `try!` because `.none` source with zero dimensions always passes validation.
    // swiftlint:disable:next force_try
    public static let disabled = try! ArtworkChannel(source: .none, format: .jpeg, mediaWidth: 0, mediaHeight: 0)

    enum CodingKeys: String, CodingKey {
        case source
        case format
        case mediaWidth = "media_width"
        case mediaHeight = "media_height"
    }

    /// Validates dimensions for the given source type.
    ///
    /// Active channels require positive dimensions; disabled channels (`.none`) allow zero.
    private static func validateDimensions(
        source: ArtworkSource, width: Int, height: Int
    ) throws(ConfigurationError) {
        if source != .none {
            guard width > 0 else { throw .artworkDimensionNotPositive(field: "media_width", value: width) }
            guard height > 0 else { throw .artworkDimensionNotPositive(field: "media_height", value: height) }
        } else {
            guard width >= 0 else { throw .artworkDimensionNegative(field: "media_width", value: width) }
            guard height >= 0 else { throw .artworkDimensionNegative(field: "media_height", value: height) }
        }
    }

    /// Creates an artwork channel configuration.
    ///
    /// - Throws: ``ConfigurationError`` if dimensions are invalid for the source type.
    ///   Active channels (`source` != `.none`) require positive dimensions.
    ///   Disabled channels (`.none`) allow zero dimensions.
    public init(source: ArtworkSource, format: ImageFormat, mediaWidth: Int, mediaHeight: Int) throws(ConfigurationError) {
        try Self.validateDimensions(source: source, width: mediaWidth, height: mediaHeight)
        self.source = source
        self.format = format
        self.mediaWidth = mediaWidth
        self.mediaHeight = mediaHeight
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decode(ArtworkSource.self, forKey: .source)
        let format = try container.decode(ImageFormat.self, forKey: .format)
        let width = try container.decode(Int.self, forKey: .mediaWidth)
        let height = try container.decode(Int.self, forKey: .mediaHeight)

        do {
            try Self.validateDimensions(source: source, width: width, height: height)
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: error.errorDescription ?? "\(error)"
                )
            )
        }

        self.source = source
        self.format = format
        mediaWidth = width
        mediaHeight = height
    }
}

/// Configuration for a single artwork channel as received in stream/start.
///
/// Uses `width`/`height` (not `media_width`/`media_height`) per spec.
/// This is a server-provided type — we trust the server's values and
/// perform no validation beyond what `Decodable` provides.
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
