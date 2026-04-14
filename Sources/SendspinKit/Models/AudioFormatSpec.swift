// ABOUTME: Specifies an audio format with codec, sample rate, channels, and bit depth
// ABOUTME: Used to negotiate audio format between client and server in client/hello

/// Validation error for audio format parameters.
private enum FormatError: Error, CustomStringConvertible {
    case invalidChannels(Int)
    case invalidSampleRate(Int)
    case invalidBitDepth(Int)

    var description: String {
        switch self {
        case .invalidChannels(let v):
            "channels must be between 1 and \(AudioFormatSpec.maxChannels), got \(v)"
        case .invalidSampleRate(let v):
            "sample_rate must be between 1 and \(AudioFormatSpec.maxSampleRate) Hz, got \(v)"
        case .invalidBitDepth(let v):
            "bit_depth must be one of \(AudioFormatSpec.supportedBitDepths.sorted()), got \(v)"
        }
    }
}

/// Specification for an audio format per Sendspin spec.
///
/// Used in the `player@v1_support.supported_formats` array of `client/hello`
/// and internally to track the current stream format.
public struct AudioFormatSpec: Codable, Sendable, Hashable {
    /// Maximum supported channel count.
    public static let maxChannels = 32
    /// Maximum supported sample rate in Hz.
    public static let maxSampleRate = 384_000
    /// Supported bit depths.
    public static let supportedBitDepths: Set<Int> = [16, 24, 32]

    /// Audio codec
    public let codec: AudioCodec
    /// Number of channels (1 = mono, 2 = stereo)
    public let channels: Int
    /// Sample rate in Hz (e.g., 44100, 48000)
    public let sampleRate: Int
    /// Bit depth (16, 24, or 32)
    public let bitDepth: Int

    enum CodingKeys: String, CodingKey {
        case codec
        case channels
        case sampleRate = "sample_rate"
        case bitDepth = "bit_depth"
    }

    /// Validates audio format parameters.
    private static func validate(
        channels: Int, sampleRate: Int, bitDepth: Int
    ) throws(FormatError) {
        guard channels > 0, channels <= maxChannels else { throw .invalidChannels(channels) }
        guard sampleRate > 0, sampleRate <= maxSampleRate else { throw .invalidSampleRate(sampleRate) }
        guard supportedBitDepths.contains(bitDepth) else { throw .invalidBitDepth(bitDepth) }
    }

    public init(codec: AudioCodec, channels: Int, sampleRate: Int, bitDepth: Int) {
        do {
            try Self.validate(channels: channels, sampleRate: sampleRate, bitDepth: bitDepth)
        } catch {
            preconditionFailure("\(error)")
        }
        self.codec = codec
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let codec = try container.decode(AudioCodec.self, forKey: .codec)
        let channels = try container.decode(Int.self, forKey: .channels)
        let sampleRate = try container.decode(Int.self, forKey: .sampleRate)
        let bitDepth = try container.decode(Int.self, forKey: .bitDepth)

        do {
            try Self.validate(channels: channels, sampleRate: sampleRate, bitDepth: bitDepth)
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "\(error)")
            )
        }

        self.codec = codec
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
    }

    /// The actual bit depth after decoding to PCM for AudioQueue output.
    ///
    /// All decoders except 16-bit/32-bit PCM passthrough produce Int32 output:
    /// - 24-bit PCM: unpacked from 3 bytes to 4 bytes, left-shifted 8 bits
    /// - FLAC: libFLAC always outputs Int32, shifted to fill 32-bit range
    /// - Opus: decoded to float32, then converted to Int32
    var effectiveOutputBitDepth: Int {
        let decoderOutputs32Bit = (bitDepth == 24 || codec == .flac || codec == .opus)
        return decoderOutputs32Bit ? 32 : bitDepth
    }
}
