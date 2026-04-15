// ABOUTME: Unit tests for FLAC audio decoder
// ABOUTME: Validates FLAC decoder creation across standard and hi-res formats

import Foundation
@testable import SendspinKit
import Testing

struct FLACDecoderTests {
    @Test
    func createFLACDecoderViaFactory() throws {
        // Standard FLAC format: 44.1kHz stereo 16-bit
        // Validates factory creates a FLACDecoder for .flac codec
        let decoder = try AudioDecoderFactory.create(
            codec: .flac,
            sampleRate: 44_100,
            channels: 2,
            bitDepth: 16,
            header: nil
        )

        #expect(decoder is FLACDecoder)
    }

    @Test
    func createHiResFLACDecoder() throws {
        // Hi-res FLAC: 96kHz stereo 24-bit
        // Validates that libFLAC accepts hi-res parameters without error
        _ = try FLACDecoder(
            sampleRate: 96_000,
            channels: 2,
            bitDepth: 24
        )
    }

    @Test
    func flacDecoderCreationWithHeader() throws {
        // Validates that a decoder can be created with a codec header prepended.
        // Note: FLAC requires a valid stream (fLaC magic + STREAMINFO) to decode
        // actual frames. Full integration tests with real FLAC data belong elsewhere.
        let fakeHeader = Data([0x66, 0x4C, 0x61, 0x43]) // "fLaC" magic bytes
        _ = try FLACDecoder(
            sampleRate: 44_100,
            channels: 2,
            bitDepth: 16,
            header: fakeHeader
        )
    }
}
