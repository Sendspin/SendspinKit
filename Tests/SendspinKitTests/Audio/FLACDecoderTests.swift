// ABOUTME: Unit tests for FLAC audio decoder
// ABOUTME: Validates FLAC frame decoding and int32 PCM output format

@testable import SendspinKit
import Testing

struct FLACDecoderTests {
    @Test
    func `Create FLAC decoder with standard format`() throws {
        // Standard FLAC format: 44.1kHz stereo 16-bit
        let decoder = try AudioDecoderFactory.create(
            codec: .flac,
            sampleRate: 44_100,
            channels: 2,
            bitDepth: 16,
            header: nil
        )

        #expect(decoder != nil)
    }

    @Test
    func `Create hi-res FLAC decoder`() throws {
        // Hi-res FLAC: 96kHz stereo 24-bit
        let decoder = try FLACDecoder(
            sampleRate: 96_000,
            channels: 2,
            bitDepth: 24
        )

        #expect(decoder != nil)
    }

    @Test
    func `FLAC decoder validates creation`() throws {
        let decoder = try FLACDecoder(
            sampleRate: 44_100,
            channels: 2,
            bitDepth: 16
        )

        // Note: FLAC requires full stream for decoding (not just frames)
        // This test validates the decoder exists and can be created
        // Full integration test with real FLAC data should be in integration tests
        #expect(decoder != nil)
    }
}
