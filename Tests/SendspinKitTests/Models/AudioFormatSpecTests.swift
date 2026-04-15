// ABOUTME: Tests for AudioFormatSpec wire format and validation
// ABOUTME: Validates CodingKeys, decode validation, and effectiveOutputBitDepth logic

import Foundation
@testable import SendspinKit
import Testing

struct AudioFormatSpecTests {
    // MARK: - Wire format

    @Test
    func `AudioFormatSpec encodes with snake_case keys`() throws {
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
    func `AudioFormatSpec round-trips through JSON`() throws {
        let original = try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 24)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioFormatSpec.self, from: data)

        #expect(decoded == original)
    }

    @Test
    func `AudioFormatSpec decodes from spec-compliant JSON`() throws {
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
    func `AudioFormatSpec supports all codecs`() throws {
        for codec in [AudioCodec.opus, .flac, .pcm] {
            let spec = try AudioFormatSpec(codec: codec, channels: 2, sampleRate: 48_000, bitDepth: 16)
            let data = try JSONEncoder().encode(spec)
            let decoded = try JSONDecoder().decode(AudioFormatSpec.self, from: data)
            #expect(decoded.codec == codec)
        }
    }

    // MARK: - Decode validation

    @Test
    func `AudioFormatSpec rejects zero channels via decode`() {
        let json = Data("""
        {"codec": "pcm", "channels": 0, "sample_rate": 48000, "bit_depth": 16}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        }
    }

    @Test
    func `AudioFormatSpec rejects negative channels via decode`() {
        let json = Data("""
        {"codec": "pcm", "channels": -1, "sample_rate": 48000, "bit_depth": 16}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        }
    }

    @Test
    func `AudioFormatSpec rejects channels above max via decode`() {
        let overMax = AudioFormatSpec.maxChannels + 1
        let json = Data("""
        {"codec": "pcm", "channels": \(overMax), "sample_rate": 48000, "bit_depth": 16}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        }
    }

    @Test
    func `AudioFormatSpec rejects zero sample rate via decode`() {
        let json = Data("""
        {"codec": "pcm", "channels": 2, "sample_rate": 0, "bit_depth": 16}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        }
    }

    @Test
    func `AudioFormatSpec rejects sample rate above max via decode`() {
        let overMax = AudioFormatSpec.maxSampleRate + 1
        let json = Data("""
        {"codec": "pcm", "channels": 2, "sample_rate": \(overMax), "bit_depth": 16}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        }
    }

    @Test
    func `AudioFormatSpec rejects invalid bit depth via decode`() {
        let json = Data("""
        {"codec": "pcm", "channels": 2, "sample_rate": 48000, "bit_depth": 8}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        }
    }

    @Test
    func `AudioFormatSpec rejects unknown codec via decode`() {
        // AudioCodec is a String-backed enum — unknown values fail at the Codable layer
        let json = Data("""
        {"codec": "aac", "channels": 2, "sample_rate": 48000, "bit_depth": 16}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        }
    }

    @Test
    func `AudioFormatSpec accepts boundary values`() throws {
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
    func `AudioFormatSpec accepts all supported bit depths`() throws {
        for bitDepth in AudioFormatSpec.supportedBitDepths.sorted() {
            let spec = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: bitDepth)
            let data = try JSONEncoder().encode(spec)
            let decoded = try JSONDecoder().decode(AudioFormatSpec.self, from: data)
            #expect(decoded.bitDepth == bitDepth)
        }
    }

    // MARK: - Init validation (ConfigurationError)

    @Test
    func `AudioFormatSpec init rejects zero channels`() {
        #expect(throws: ConfigurationError.self) {
            try AudioFormatSpec(codec: .pcm, channels: 0, sampleRate: 48_000, bitDepth: 16)
        }
    }

    @Test
    func `AudioFormatSpec init rejects negative channels`() {
        #expect(throws: ConfigurationError.self) {
            try AudioFormatSpec(codec: .pcm, channels: -1, sampleRate: 48_000, bitDepth: 16)
        }
    }

    @Test
    func `AudioFormatSpec init rejects zero sample rate`() {
        #expect(throws: ConfigurationError.self) {
            try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 0, bitDepth: 16)
        }
    }

    @Test
    func `AudioFormatSpec init rejects unsupported bit depth`() {
        #expect(throws: ConfigurationError.self) {
            try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 8)
        }
    }

    // MARK: - effectiveOutputBitDepth

    @Test
    func `effectiveOutputBitDepth returns 32 for FLAC regardless of bit depth`() throws {
        // FLAC always decodes to Int32 via libFLAC
        let spec16 = try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 16)
        let spec24 = try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 24)
        let spec32 = try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 32)
        #expect(spec16.effectiveOutputBitDepth == 32)
        #expect(spec24.effectiveOutputBitDepth == 32)
        #expect(spec32.effectiveOutputBitDepth == 32)
    }

    @Test
    func `effectiveOutputBitDepth returns 32 for Opus regardless of bit depth`() throws {
        let spec = try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16)
        #expect(spec.effectiveOutputBitDepth == 32)
    }

    @Test
    func `effectiveOutputBitDepth returns 32 for 24-bit PCM`() throws {
        let spec = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 24)
        #expect(spec.effectiveOutputBitDepth == 32)
    }

    @Test
    func `effectiveOutputBitDepth passes through 16-bit PCM`() throws {
        let spec = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        #expect(spec.effectiveOutputBitDepth == 16)
    }

    @Test
    func `effectiveOutputBitDepth passes through 32-bit PCM`() throws {
        let spec = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 32)
        #expect(spec.effectiveOutputBitDepth == 32)
    }
}
