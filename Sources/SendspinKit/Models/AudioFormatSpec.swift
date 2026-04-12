// ABOUTME: Specifies an audio format with codec, sample rate, channels, and bit depth
// ABOUTME: Used to negotiate audio format between client and server

/// Specification for an audio format
public struct AudioFormatSpec: Codable, Sendable, Hashable {
    /// Audio codec
    public let codec: AudioCodec
    /// Number of channels (1 = mono, 2 = stereo)
    public let channels: Int
    /// Sample rate in Hz (e.g., 44100, 48000)
    public let sampleRate: Int
    /// Bit depth (16, 24, or 32)
    public let bitDepth: Int

    public init(codec: AudioCodec, channels: Int, sampleRate: Int, bitDepth: Int) {
        precondition(channels > 0 && channels <= 32, "Channels must be between 1 and 32")
        precondition(sampleRate > 0 && sampleRate <= 384_000, "Sample rate must be between 1 and 384000 Hz")
        precondition(bitDepth == 16 || bitDepth == 24 || bitDepth == 32, "Bit depth must be 16, 24, or 32")

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
