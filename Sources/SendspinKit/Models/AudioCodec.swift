/// Audio codecs supported by Sendspin
public enum AudioCodec: String, Codable, Sendable, Hashable {
    /// Opus codec - optimized for low latency
    case opus
    /// FLAC codec - lossless compression
    case flac
    /// PCM - uncompressed raw audio
    case pcm
}
