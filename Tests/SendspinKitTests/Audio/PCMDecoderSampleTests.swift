// ABOUTME: Tests for PCM decoding to Sample values
// ABOUTME: Translated from sendspin-rs/tests/pcm_decoder.rs

import Testing
@testable import SendspinKit

@Suite("PCM Decoder (Sample-based)")
struct PCMDecoderSampleTests {

    // MARK: - 16-bit decoding

    @Test("decode 16-bit PCM to samples")
    func decodePCM16Bit() throws {
        let decoder = SamplePCMDecoder(bitDepth: 16)

        // 4 samples (8 bytes) of 16-bit PCM little-endian
        let data: [UInt8] = [
            0x00, 0x04, // 1024 in little-endian
            0x00, 0x08, // 2048
            0xFF, 0xFF, // -1
            0x00, 0x00, // 0
        ]

        let samples = try decoder.decode(data)

        #expect(samples.count == 4)
        #expect(samples[0].toI16() == 1024)
        #expect(samples[1].toI16() == 2048)
        #expect(samples[2].toI16() == -1)
        #expect(samples[3].toI16() == 0)
    }

    // MARK: - 24-bit decoding

    @Test("decode 24-bit PCM to samples")
    func decodePCM24Bit() throws {
        let decoder = SamplePCMDecoder(bitDepth: 24)

        // 2 samples (6 bytes) of 24-bit PCM little-endian
        let data: [UInt8] = [
            0x00, 0x10, 0x00, // 4096 in 24-bit LE
            0xFF, 0xFF, 0xFF, // -1 in 24-bit
        ]

        let samples = try decoder.decode(data)

        #expect(samples.count == 2)
        #expect(samples[0] == Sample(4096))
        #expect(samples[1] == Sample(-1))
    }

    // MARK: - Empty input

    @Test("decode 16-bit empty input")
    func decodePCM16BitEmptyInput() throws {
        let decoder = SamplePCMDecoder(bitDepth: 16)
        let samples = try decoder.decode([])
        #expect(samples.count == 0)
    }

    @Test("decode 24-bit empty input")
    func decodePCM24BitEmptyInput() throws {
        let decoder = SamplePCMDecoder(bitDepth: 24)
        let samples = try decoder.decode([])
        #expect(samples.count == 0)
    }

    // MARK: - Misaligned input (trailing bytes dropped)

    @Test("decode 16-bit misaligned trailing byte dropped")
    func decodePCM16BitMisalignedTrailingByteDropped() throws {
        let decoder = SamplePCMDecoder(bitDepth: 16)
        // 3 bytes: one complete 16-bit sample + 1 trailing byte
        let data: [UInt8] = [0x00, 0x04, 0xFF]
        let samples = try decoder.decode(data)
        // Silently drops trailing byte
        #expect(samples.count == 1)
        #expect(samples[0].toI16() == 1024)
    }

    @Test("decode 24-bit misaligned trailing bytes dropped")
    func decodePCM24BitMisalignedTrailingBytesDropped() throws {
        let decoder = SamplePCMDecoder(bitDepth: 24)
        // 5 bytes: one complete 24-bit sample + 2 trailing bytes
        let data: [UInt8] = [0x00, 0x10, 0x00, 0xAB, 0xCD]
        let samples = try decoder.decode(data)
        #expect(samples.count == 1)
        #expect(samples[0] == Sample(4096))
    }

    // MARK: - Boundary values

    @Test("decode 16-bit max value")
    func decodePCM16BitSingleSampleMax() throws {
        let decoder = SamplePCMDecoder(bitDepth: 16)
        let data: [UInt8] = [0xFF, 0x7F] // i16 max = 32767
        let samples = try decoder.decode(data)
        #expect(samples.count == 1)
        #expect(samples[0].toI16() == Int16.max)
    }

    @Test("decode 16-bit min value")
    func decodePCM16BitSingleSampleMin() throws {
        let decoder = SamplePCMDecoder(bitDepth: 16)
        let data: [UInt8] = [0x00, 0x80] // i16 min = -32768 in LE
        let samples = try decoder.decode(data)
        #expect(samples.count == 1)
        #expect(samples[0].toI16() == Int16.min)
    }

    @Test("decode 24-bit max value")
    func decodePCM24BitSingleSampleMax() throws {
        let decoder = SamplePCMDecoder(bitDepth: 24)
        let data: [UInt8] = [0xFF, 0xFF, 0x7F]
        let samples = try decoder.decode(data)
        #expect(samples.count == 1)
        #expect(samples[0] == Sample.max)
    }

    @Test("decode 24-bit min value")
    func decodePCM24BitSingleSampleMin() throws {
        let decoder = SamplePCMDecoder(bitDepth: 24)
        let data: [UInt8] = [0x00, 0x00, 0x80] // -8388608 in 24-bit LE
        let samples = try decoder.decode(data)
        #expect(samples.count == 1)
        #expect(samples[0] == Sample.min)
    }

    // MARK: - Unsupported bit depths

    @Test("decode 0-bit depth unsupported")
    func decodePCMZeroBitDepthUnsupported() throws {
        let decoder = SamplePCMDecoder(bitDepth: 0)
        #expect(throws: (any Error).self) {
            _ = try decoder.decode([0x00])
        }
    }

    @Test("decode 8-bit unsupported")
    func decodePCMUnsupportedBitDepth() throws {
        let decoder = SamplePCMDecoder(bitDepth: 8)
        #expect(throws: (any Error).self) {
            _ = try decoder.decode([0x00, 0x01])
        }
    }

    @Test("decode 32-bit unsupported")
    func decodePCM32BitUnsupported() throws {
        let decoder = SamplePCMDecoder(bitDepth: 32)
        #expect(throws: (any Error).self) {
            _ = try decoder.decode([UInt8](repeating: 0x00, count: 4))
        }
    }

    // MARK: - Sub-sample input

    @Test("decode 16-bit sub-sample input returns empty")
    func decodePCM16BitSubSampleInput() throws {
        let decoder = SamplePCMDecoder(bitDepth: 16)
        // Single byte - not enough for one 16-bit sample
        let samples = try decoder.decode([0xFF])
        #expect(samples.count == 0)
    }

    @Test("decode 24-bit sub-sample input returns empty")
    func decodePCM24BitSubSampleInput() throws {
        let decoder = SamplePCMDecoder(bitDepth: 24)
        // Two bytes - not enough for one 24-bit sample
        let samples = try decoder.decode([0xFF, 0xFF])
        #expect(samples.count == 0)
    }
}
