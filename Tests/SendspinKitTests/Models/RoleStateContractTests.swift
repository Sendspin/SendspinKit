import Foundation
@testable import SendspinKit
import Testing

@Suite("Role state contracts")
struct RoleStateContractTests {
    @Test("artwork configuration rejects empty and more than four channels")
    func artworkConfigurationRejectsInvalidChannelCounts() throws {
        #expect(throws: ConfigurationError.emptyArtworkChannels) {
            try ArtworkStateObject(channels: [])
        }
        let channel = try ArtworkStateChannel(source: .none)
        #expect(throws: ConfigurationError.tooManyArtworkChannels(5)) {
            try ArtworkStateObject(channels: Array(repeating: channel, count: 5))
        }
        // Mutation claim: removing either cardinality guard must fail one of these constructions.
    }

    @Test("artwork state wire shape omits parameters for none")
    func disabledArtworkChannelUsesSpecWireShape() throws {
        let state = try ArtworkStateObject(channels: [ArtworkStateChannel(source: .none)])
        let data = try JSONEncoder().encode(state)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == #"{"channels":[{"source":"none"}]}"#)
        #expect(!json.contains("format"))
        #expect(!json.contains("width"))
        #expect(!json.contains("height"))
        // Mutation claim: encoding format/dimensions for none fails the hand-derived fixture.
    }

    @Test("active artwork channels require format and positive dimensions")
    func activeArtworkChannelRequiresCompletePositiveParameters() throws {
        #expect(throws: ConfigurationError.invalidArtworkStateChannel) {
            try ArtworkStateChannel(source: .album)
        }
        #expect(throws: ConfigurationError.invalidArtworkStateChannel) {
            try ArtworkStateChannel(source: .album, format: .jpeg, width: 0, height: 1)
        }
        #expect(throws: ConfigurationError.invalidArtworkStateChannel) {
            try ArtworkStateChannel(source: .album, format: .jpeg, width: 1, height: 0)
        }
        #expect(throws: ConfigurationError.invalidArtworkStateChannel) {
            try ArtworkStateChannel(source: .none, format: .jpeg, width: 1, height: 1)
        }
        // Mutation claim: removing any nil/positive/source validation must fail a named case above.
    }

    @Test("visualizer spectrum request requires spectrum configuration")
    func visualizerSpectrumRequirementIsEnforced() throws {
        #expect(throws: ConfigurationError.missingSpectrumConfiguration) {
            try VisualizerConfiguration(types: [.spectrum], rateMax: 30)
        }
        #expect(throws: ConfigurationError.missingSpectrumConfiguration) {
            try VisualizerStateObject(types: [.spectrum], rateMax: 30)
        }
        // Mutation claim: removing either construction-level guard must fail its corresponding case.
    }

    @Test("visualizer state encodes the complete requested object")
    func visualizerStateUsesSpecWireKeys() throws {
        let spectrum = SpectrumConfiguration(nDispBins: 32, scale: .log, fMin: 40, fMax: 16_000)
        let state = try VisualizerStateObject(types: [.loudness, .spectrum], rateMax: 30, spectrum: spectrum)
        let data = try JSONEncoder().encode(state)
        let expectedData = Data(
            #"{"types":["loudness","spectrum"],"rate_max":30,"spectrum":{"n_disp_bins":32,"scale":"log","f_min":40,"f_max":16000}}"#
                .utf8
        )
        let expectedObject = try JSONSerialization.jsonObject(with: expectedData)
        let actualObject = try JSONSerialization.jsonObject(with: data)
        let expected = try #require(expectedObject as? [String: Any])
        let actual = try #require(actualObject as? [String: Any])
        #expect(NSDictionary(dictionary: actual).isEqual(to: expected))
        // Mutation claim: dropping rate_max, spectrum, or a snake-case key fails this hand-derived fixture.
    }
}
