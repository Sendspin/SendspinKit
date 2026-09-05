/// Artwork source type per Sendspin spec
public enum ArtworkSource: String, Codable, Sendable, Hashable {
    /// Album artwork
    case album
    /// Artist artwork
    case artist
    /// No artwork — channel disabled.
    case none
}

/// Supported image formats for artwork per Sendspin spec
public enum ImageFormat: String, Codable, Sendable, Hashable {
    case jpeg
    case png
}

/// An explicit update to one artwork channel's client/state preference.
public enum ArtworkChannelPreference: Sendable, Hashable {
    /// Disable the channel and omit format and dimensions from client/state.
    case disable
    /// Enable the channel with a complete source, format, and size.
    case set(source: ArtworkSource, format: ImageFormat, width: Int, height: Int)
}

/// Configuration for a single artwork channel in the artwork `client/state` object.
/// Array index determines the channel number (0-3) and corresponding binary message type (8-11).
public struct ArtworkChannel: Codable, Sendable, Hashable {
    /// Artwork source type
    public let source: ArtworkSource
    /// Image format used for the channel's initial configuration. Disabled channels use
    /// ``ArtworkChannelPreference/disable`` when published in `client/state`.
    public let format: ImageFormat
    /// Max width in pixels
    public let width: Int
    /// Max height in pixels
    public let height: Int

    // A disabled channel placeholder. Format is `.jpeg` by arbitrary convention;
    // any format is valid since the server ignores it for `source: .none` channels.
    // Uses `try!` because `.none` source with zero dimensions always passes validation.
    // swiftlint:disable:next force_try
    public static let disabled = try! ArtworkChannel(source: .none, format: .jpeg, width: 0, height: 0)

    enum CodingKeys: String, CodingKey {
        case source
        case format
        case width
        case height
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
    public init(source: ArtworkSource, format: ImageFormat, width: Int, height: Int) throws(ConfigurationError) {
        try Self.validateDimensions(source: source, width: width, height: height)
        self.source = source
        self.format = format
        self.width = width
        self.height = height
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decode(ArtworkSource.self, forKey: .source)
        let format = try container.decode(ImageFormat.self, forKey: .format)
        let width = try container.decode(Int.self, forKey: .width)
        let height = try container.decode(Int.self, forKey: .height)

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
        self.width = width
        self.height = height
    }
}

/// Configuration for a single artwork channel as received in stream/start.
///
/// Uses `width`/`height` (not `media_width`/`media_height`) per spec.
/// This is a server-provided type: the library never reads `width`/`height`
/// internally, so they are forwarded to the consumer verbatim with no validation
/// beyond `Decodable`. Treat them as untrusted informational metadata — a
/// non-conforming server could report non-positive values, and the consumer is
/// responsible for sanity-checking before relying on them.
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
