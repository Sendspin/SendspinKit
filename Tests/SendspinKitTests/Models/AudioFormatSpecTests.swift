// ABOUTME: Tests for AudioFormatSpec wire format and validation
// ABOUTME: Validates CodingKeys, decode validation, and effectiveOutputBitDepth logic

import Foundation
@testable import SendspinKit
import Testing

struct AudioFormatSpecTests {
    // MARK: - Wire format

    @Test
    func audioFormatSpec_encodesWithSnakeCaseKeys() throws {
        let spec = try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16)

        let data = try JSONEncoder().encode(spec)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["codec"] as? String == "opus")
        #expect(json["channels"] as? Int == 2)
        #expect(json["sample_rate"] as? Int == 48_000)
        #expect(json["bit_depth"] as? Int == 16)
        // Verify no camelCase keys leaked
        #expect(!json.keys.contains("sampleRate"))
        #expect(!json.keys.contains("bitDepth"))
    }

    @Test
    func audioFormatSpec_roundTripsThroughJSON() throws {
        let original = try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 24)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioFormatSpec.self, from: data)

        #expect(decoded == original)
    }

    @Test
    func audioFormatSpec_decodesFromSpecCompliantJSON() throws {
        let json = Data("""
        {"codec": "pcm", "channels": 1, "sample_rate": 44100, "bit_depth": 16}
        """.utf8)

        let spec = try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        #expect(spec.codec == .pcm)
        #expect(spec.channels == 1)
        #expect(spec.sampleRate == 44_100)
        #expect(spec.bitDepth == 16)
    }

    @Test
    func audioFormatSpec_supportsAllCodecs() throws {
        for codec in [AudioCodec.opus, .flac, .pcm] {
            let spec = try AudioFormatSpec(codec: codec, channels: 2, sampleRate: 48_000, bitDepth: 16)
            let data = try JSONEncoder().encode(spec)
            let decoded = try JSONDecoder().decode(AudioFormatSpec.self, from: data)
            #expect(decoded.codec == codec)
        }
    }

    // MARK: - Decode validation

    @Test
    func audioFormatSpec_rejectsZeroChannelsViaDecode() {
        let json = Data("""
        {"codec": "pcm", "channels": 0, "sample_rate": 48000, "bit_depth": 16}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        }
    }

    @Test
    func audioFormatSpec_rejectsNegativeChannelsViaDecode() {
        let json = Data("""
        {"codec": "pcm", "channels": -1, "sample_rate": 48000, "bit_depth": 16}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        }
    }

    @Test
    func audioFormatSpec_rejectsChannelsAboveMaxViaDecode() {
        let overMax = AudioFormatSpec.maxChannels + 1
        let json = Data("""
        {"codec": "pcm", "channels": \(overMax), "sample_rate": 48000, "bit_depth": 16}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        }
    }

    @Test
    func audioFormatSpec_rejectsZeroSampleRateViaDecode() {
        let json = Data("""
        {"codec": "pcm", "channels": 2, "sample_rate": 0, "bit_depth": 16}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        }
    }

    @Test
    func audioFormatSpec_rejectsSampleRateAboveMaxViaDecode() {
        let overMax = AudioFormatSpec.maxSampleRate + 1
        let json = Data("""
        {"codec": "pcm", "channels": 2, "sample_rate": \(overMax), "bit_depth": 16}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        }
    }

    @Test
    func audioFormatSpec_rejectsInvalidBitDepthViaDecode() {
        let json = Data("""
        {"codec": "pcm", "channels": 2, "sample_rate": 48000, "bit_depth": 8}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        }
    }

    @Test
    func audioFormatSpec_rejectsUnknownCodecViaDecode() {
        // AudioCodec is a String-backed enum — unknown values fail at the Codable layer
        let json = Data("""
        {"codec": "aac", "channels": 2, "sample_rate": 48000, "bit_depth": 16}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        }
    }

    @Test
    func audioFormatSpec_acceptsBoundaryValues() throws {
        // Upper bounds
        let specMax = try AudioFormatSpec(
            codec: .pcm,
            channels: AudioFormatSpec.maxChannels,
            sampleRate: AudioFormatSpec.maxSampleRate,
            bitDepth: 32
        )
        let dataMax = try JSONEncoder().encode(specMax)
        let decodedMax = try JSONDecoder().decode(AudioFormatSpec.self, from: dataMax)
        #expect(decodedMax.channels == AudioFormatSpec.maxChannels)
        #expect(decodedMax.sampleRate == AudioFormatSpec.maxSampleRate)
        #expect(decodedMax.bitDepth == 32)

        // Lower bounds
        let specMin = try AudioFormatSpec(codec: .pcm, channels: 1, sampleRate: 1, bitDepth: 16)
        let dataMin = try JSONEncoder().encode(specMin)
        let decodedMin = try JSONDecoder().decode(AudioFormatSpec.self, from: dataMin)
        #expect(decodedMin.channels == 1)
        #expect(decodedMin.sampleRate == 1)
    }

    @Test
    func audioFormatSpec_acceptsAllSupportedBitDepths() throws {
        for bitDepth in AudioFormatSpec.supportedBitDepths.sorted() {
            let spec = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: bitDepth)
            let data = try JSONEncoder().encode(spec)
            let decoded = try JSONDecoder().decode(AudioFormatSpec.self, from: data)
            #expect(decoded.bitDepth == bitDepth)
        }
    }

    // MARK: - Init validation (ConfigurationError)

    @Test
    func audioFormatSpec_initRejectsZeroChannels() {
        #expect(throws: ConfigurationError.self) {
            try AudioFormatSpec(codec: .pcm, channels: 0, sampleRate: 48_000, bitDepth: 16)
        }
    }

    @Test
    func audioFormatSpec_initRejectsNegativeChannels() {
        #expect(throws: ConfigurationError.self) {
            try AudioFormatSpec(codec: .pcm, channels: -1, sampleRate: 48_000, bitDepth: 16)
        }
    }

    @Test
    func audioFormatSpec_initRejectsZeroSampleRate() {
        #expect(throws: ConfigurationError.self) {
            try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 0, bitDepth: 16)
        }
    }

    @Test
    func audioFormatSpec_initRejectsUnsupportedBitDepth() {
        #expect(throws: ConfigurationError.self) {
            try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 8)
        }
    }

    // MARK: - effectiveOutputBitDepth

    @Test
    func effectiveOutputBitDepth_returns32ForFLACRegardlessOfBitDepth() throws {
        // FLAC always decodes to Int32 via libFLAC
        let spec16 = try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 16)
        let spec24 = try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 24)
        let spec32 = try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 32)
        #expect(spec16.effectiveOutputBitDepth == 32)
        #expect(spec24.effectiveOutputBitDepth == 32)
        #expect(spec32.effectiveOutputBitDepth == 32)
    }

    @Test
    func effectiveOutputBitDepth_returns32ForOpusRegardlessOfBitDepth() throws {
        let spec = try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16)
        #expect(spec.effectiveOutputBitDepth == 32)
    }

    @Test
    func effectiveOutputBitDepth_returns32For24BitPCM() throws {
        let spec = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 24)
        #expect(spec.effectiveOutputBitDepth == 32)
    }

    @Test
    func effectiveOutputBitDepth_passesThrough16BitPCM() throws {
        let spec = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        #expect(spec.effectiveOutputBitDepth == 16)
    }

    @Test
    func effectiveOutputBitDepth_passesThrough32BitPCM() throws {
        let spec = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 32)
        #expect(spec.effectiveOutputBitDepth == 32)
    }
}
