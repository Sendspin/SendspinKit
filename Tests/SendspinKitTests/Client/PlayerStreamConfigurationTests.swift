import Foundation
@testable import SendspinKit
import Testing

struct PlayerStreamConfigurationTests {
    @Test("Opus-only player catalogs are rejected")
    func opusOnlyCatalogIsRejected() throws {
        let opus = try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16)
        #expect(throws: ConfigurationError.missingLosslessFormat) {
            try PlayerConfiguration(bufferCapacity: 1, supportedFormats: [opus])
        }
    }

    @Test("Current-output catalogs require FLAC or PCM at the route rate")
    func currentOutputRequiresLosslessFormat() throws {
        let opus = try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let pcm = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
        #expect(throws: OutputFormatError.noMatchingLosslessFormat) {
            try effectiveSupportedFormats([opus, pcm], policy: .requireCurrentOutput, outputSampleRate: opus.sampleRate)
        }
        #expect(try effectiveSupportedFormats([opus, pcm], policy: .requireCurrentOutput, outputSampleRate: pcm.sampleRate) == [pcm])
    }

    @Test("Opus depth is ignored for validation and matching but retained on the wire")
    func opusDepthIsIgnoredForValidationAndMatching() throws {
        let catalog = try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let incoming = try JSONDecoder().decode(AudioFormatSpec.self, from: Data(
            #"{"codec":"opus","channels":2,"sample_rate":48000,"bit_depth":7}"#.utf8
        ))
        #expect(incoming.bitDepth == 7)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(incoming)) as? [String: Any])
        #expect(encoded["bit_depth"] as? Int == 7)
        #expect(incoming == catalog)
        #expect(Set([incoming, catalog]).count == 1)
        #expect(try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 7) == catalog)
        #expect(throws: ConfigurationError.unsupportedBitDepth(7)) {
            try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 7)
        }
    }
}
