import Foundation

/// Validation errors for public configuration types.
///
/// A library must never crash the host process for invalid input. All public
/// initializers that validate parameters throw ``ConfigurationError`` instead
/// of trapping. Consumers can catch specific cases for targeted error handling
/// or treat the entire enum as a generic validation failure.
public enum ConfigurationError: SendspinError, Hashable {
    // MARK: - AudioFormatSpec

    /// Channel count must be between 1 and ``AudioFormatSpec/maxChannels``.
    case invalidChannelCount(Int)
    /// Sample rate must be between 1 and ``AudioFormatSpec/maxSampleRate`` Hz.
    case invalidSampleRate(Int)
    /// Bit depth must be one of ``AudioFormatSpec/supportedBitDepths``.
    case unsupportedBitDepth(Int)

    // MARK: - PlayerConfiguration

    /// Buffer capacity must be positive.
    case nonPositiveBufferCapacity
    /// At least one supported audio format is required.
    case emptySupportedFormats
    /// Output delay must be between 0 and 5000 milliseconds.
    case outputDelayOutOfRange(Int)
    /// Required lead time must be non-negative.
    case negativeRequiredLeadTime(Int)
    /// Minimum buffer must be non-negative.
    case negativeMinBuffer(Int)

    // MARK: - ArtworkConfiguration / ArtworkChannel

    /// At least one artwork channel is required.
    case emptyArtworkChannels
    /// Maximum 4 artwork channels are allowed.
    case tooManyArtworkChannels(Int)
    /// Active artwork channels (source != `.none`) require positive dimensions.
    case artworkDimensionNotPositive(field: String, value: Int)
    /// Disabled artwork channels (source == `.none`) require non-negative dimensions.
    case artworkDimensionNegative(field: String, value: Int)
    /// Artwork channel index must refer to a configured channel.
    case artworkChannelOutOfRange(Int)
    /// Artwork role state is unavailable for a configured active role.
    case artworkStateUnavailable

    // MARK: - PlayerStateObject

    /// Volume must be between 0 and 100.
    case volumeOutOfRange(Int)
    /// A required field is missing from a full role state object.
    case missingRequiredStateField(String)
    /// Artwork state channel fields are inconsistent with its source.
    case invalidArtworkStateChannel
    /// Spectrum configuration is required when spectrum is requested.
    case missingSpectrumConfiguration

    // MARK: - ClientAdvertiser

    /// The advertised WebSocket path must be absolute (begin with "/").
    case invalidWebSocketPath(String)

    // MARK: - SendspinClient

    /// Player role was requested but no ``PlayerConfiguration`` was provided.
    case playerRoleRequiresConfiguration
    /// Artwork role was requested but no ``ArtworkConfiguration`` was provided.
    case artworkRoleRequiresConfiguration
    /// Visualizer role was requested but no ``VisualizerStateObject`` was provided.
    case visualizerRoleRequiresConfiguration
}

extension ConfigurationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidChannelCount(v):
            "Channel count must be between 1 and \(AudioFormatSpec.maxChannels), got \(v)"
        case let .invalidSampleRate(v):
            "Sample rate must be between 1 and \(AudioFormatSpec.maxSampleRate) Hz, got \(v)"
        case let .unsupportedBitDepth(v):
            "Bit depth must be one of \(AudioFormatSpec.supportedBitDepths.sorted()), got \(v)"
        case .nonPositiveBufferCapacity:
            "Buffer capacity must be positive"
        case .emptySupportedFormats:
            "Must support at least one audio format"
        case let .outputDelayOutOfRange(v):
            "Output delay must be 0–5000 ms, got \(v)"
        case let .negativeRequiredLeadTime(v):
            "Required lead time must be non-negative, got \(v)"
        case let .negativeMinBuffer(v):
            "Minimum buffer must be non-negative, got \(v)"
        case .emptyArtworkChannels:
            "Must have at least one artwork channel"
        case let .tooManyArtworkChannels(v):
            "Maximum 4 artwork channels allowed, got \(v)"
        case let .artworkDimensionNotPositive(field, value):
            "\(field) must be positive for active channels, got \(value)"
        case let .artworkDimensionNegative(field, value):
            "\(field) must be non-negative, got \(value)"
        case let .artworkChannelOutOfRange(v):
            "Artwork channel must be 0–3, got \(v)"
        case .artworkStateUnavailable:
            "Artwork state is unavailable for the active role"
        case let .volumeOutOfRange(v):
            "Volume must be 0–100, got \(v)"
        case let .missingRequiredStateField(v):
            "Missing required client/state field: \(v)"
        case .invalidArtworkStateChannel:
            "Artwork state channel fields do not match its source"
        case .missingSpectrumConfiguration:
            "Visualizer spectrum configuration is required when spectrum is requested"
        case let .invalidWebSocketPath(v):
            "WebSocket path must be absolute (begin with \"/\"), got \"\(v)\""
        case .playerRoleRequiresConfiguration:
            "Player role requires a PlayerConfiguration"
        case .artworkRoleRequiresConfiguration:
            "Artwork role requires an ArtworkConfiguration"
        case .visualizerRoleRequiresConfiguration:
            "Visualizer role requires a VisualizerStateObject"
        }
    }
}
