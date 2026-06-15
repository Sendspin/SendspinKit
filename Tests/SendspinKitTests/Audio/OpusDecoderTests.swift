import Foundation
@testable import SendspinKit
import Testing

struct OpusDecoderTests {
    @Test
    func opusDecoderCreation() throws {
        // Opus standard format: 48kHz stereo
        _ = try AudioDecoderFactory.create(
            codec: .opus,
            sampleRate: 48_000,
            channels: 2,
            bitDepth: 16,
            header: nil
        )
    }

    @Test
    func opusDecodeProducesInt32Output() throws {
        let decoder = try OpusDecoder(sampleRate: 48_000, channels: 2, bitDepth: 16)

        // Create a minimal valid Opus packet (silence frame)
        // Opus TOC byte for 20ms SILK frame: 0x3C
        let silencePacket = Data([0x3C, 0xFC, 0xFF, 0xFE])

        let decoded = try decoder.decode(silencePacket)

        // Should output int32 samples (4 bytes per sample)
        #expect(decoded.count % 4 == 0, "Output should be int32 samples")
        #expect(decoded.count > 0, "Should decode some samples")
    }

    @Test
    func opusDecoderSampleRates() throws {
        // Test all standard Opus sample rates
        for sampleRate in [8_000, 12_000, 16_000, 24_000, 48_000] {
            _ = try OpusDecoder(
                sampleRate: sampleRate,
                channels: 2,
                bitDepth: 16
            )
        }
    }
}
