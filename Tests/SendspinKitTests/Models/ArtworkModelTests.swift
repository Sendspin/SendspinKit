import Foundation
@testable import SendspinKit
import Testing

struct ArtworkModelTests {
    // MARK: - ArtworkChannel

    @Test
    func artworkChannel_roundTripsThroughJSON() throws {
        let channel = try ArtworkChannel(
            source: .album,
            format: .jpeg,
            width: 800,
            height: 800
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(channel)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["source"] as? String == "album")
        #expect(json["format"] as? String == "jpeg")
        #expect(json["width"] as? Int == 800)
        #expect(json["height"] as? Int == 800)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ArtworkChannel.self, from: data)
        #expect(decoded.source == .album)
        #expect(decoded.format == .jpeg)
        #expect(decoded.width == 800)
        #expect(decoded.height == 800)
    }

    @Test
    func artworkChannel_disabledPlaceholderEncodesCorrectly() throws {
        let channel = ArtworkChannel.disabled

        let encoder = JSONEncoder()
        let data = try encoder.encode(channel)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["source"] as? String == "none")
        #expect(json["width"] as? Int == 0)
        #expect(json["height"] as? Int == 0)
    }

    @Test
    func artworkChannel_supportsAllImageFormats() throws {
        let formats: [ImageFormat] = [.jpeg, .png]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for format in formats {
            let channel = try ArtworkChannel(
                source: .album,
                format: format,
                width: 300,
                height: 300
            )
            let data = try encoder.encode(channel)
            let decoded = try decoder.decode(ArtworkChannel.self, from: data)
            #expect(decoded.format == format)
        }
    }

    @Test
    func artworkChannel_supportsActiveAndDisabledSourceTypes() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for source in [ArtworkSource.album, .artist] {
            let channel = try ArtworkChannel(
                source: source,
                format: .jpeg,
                width: 300,
                height: 300
            )
            let data = try encoder.encode(channel)
            let decoded = try decoder.decode(ArtworkChannel.self, from: data)
            #expect(decoded.source == source)
        }

        // Disabled channel round-trips with zero dimensions
        let disabled = ArtworkChannel.disabled
        let data = try encoder.encode(disabled)
        let decoded = try decoder.decode(ArtworkChannel.self, from: data)
        #expect(decoded.source == .none)
        #expect(decoded.format == .jpeg)
        #expect(decoded.width == 0)
        #expect(decoded.height == 0)
    }

    // MARK: - ArtworkChannel decode validation

    @Test(arguments: [
        ("ArtworkChannel", "{\"source\":\"album\",\"format\":\"bmp\",\"width\":300,\"height\":300}"),
        ("StreamArtworkChannelConfig", "{\"source\":\"album\",\"format\":\"bmp\",\"width\":300,\"height\":300}"),
        ("ArtworkStateChannel", "{\"source\":\"album\",\"format\":\"bmp\",\"width\":300,\"height\":300}")
    ])
    func artworkDecodersRejectBMP(type: String, json: String) {
        let data = Data(json.utf8)
        switch type {
        case "ArtworkChannel":
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(ArtworkChannel.self, from: data) }
        case "StreamArtworkChannelConfig":
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(StreamArtworkChannelConfig.self, from: data) }
        default:
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(ArtworkStateChannel.self, from: data) }
        }
    }

    @Test
    func artworkChannel_rejectsNegativeWidthForActiveChannelViaDecode() {
        let json = Data("""
        {"source": "album", "format": "jpeg", "media_width": -1, "media_height": 300}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ArtworkChannel.self, from: json)
        }
    }

    @Test
    func artworkChannel_rejectsZeroWidthForActiveChannelViaDecode() {
        let json = Data("""
        {"source": "album", "format": "jpeg", "media_width": 0, "media_height": 300}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ArtworkChannel.self, from: json)
        }
    }

    @Test
    func artworkChannel_rejectsZeroHeightForActiveChannelViaDecode() {
        let json = Data("""
        {"source": "album", "format": "jpeg", "media_width": 300, "media_height": 0}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ArtworkChannel.self, from: json)
        }
    }

    @Test
    func artworkChannel_rejectsNegativeHeightForActiveChannelViaDecode() {
        let json = Data("""
        {"source": "album", "format": "jpeg", "media_width": 300, "media_height": -1}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ArtworkChannel.self, from: json)
        }
    }

    @Test
    func artworkChannel_rejectsNegativeWidthForNoneChannelViaDecode() {
        let json = Data("""
        {"source": "none", "format": "jpeg", "media_width": -1, "media_height": 0}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ArtworkChannel.self, from: json)
        }
    }

    @Test
    func artworkChannel_rejectsNegativeHeightForNoneChannelViaDecode() {
        let json = Data("""
        {"source": "none", "format": "jpeg", "media_width": 0, "media_height": -1}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ArtworkChannel.self, from: json)
        }
    }

    @Test
    func artworkChannel_rejectsBothDimensionsBadForActiveChannelViaDecode() {
        // Documents first-failure-wins: width is checked before height
        let json = Data("""
        {"source": "album", "format": "jpeg", "media_width": -1, "media_height": -1}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ArtworkChannel.self, from: json)
        }
    }

    @Test
    func artworkChannel_acceptsZeroDimensionsForNoneChannelViaDecode() throws {
        let json = Data("""
        {"source": "none", "format": "jpeg", "width": 0, "height": 0}
        """.utf8)

        let channel = try JSONDecoder().decode(ArtworkChannel.self, from: json)
        #expect(channel.source == .none)
        #expect(channel.width == 0)
        #expect(channel.height == 0)
    }

    // MARK: - ArtworkChannel init validation (ConfigurationError)

    @Test
    func artworkChannel_initRejectsNegativeWidthForActiveChannel() {
        #expect(throws: ConfigurationError.self) {
            try ArtworkChannel(source: .album, format: .jpeg, width: -1, height: 300)
        }
    }

    @Test
    func artworkChannel_initRejectsZeroWidthForActiveChannel() {
        #expect(throws: ConfigurationError.self) {
            try ArtworkChannel(source: .album, format: .jpeg, width: 0, height: 300)
        }
    }

    @Test
    func artworkChannel_initRejectsZeroHeightForActiveChannel() {
        #expect(throws: ConfigurationError.self) {
            try ArtworkChannel(source: .album, format: .jpeg, width: 300, height: 0)
        }
    }

    @Test
    func artworkChannel_initRejectsNegativeHeightForActiveChannel() {
        #expect(throws: ConfigurationError.self) {
            try ArtworkChannel(source: .album, format: .jpeg, width: 300, height: -1)
        }
    }

    // MARK: - Artwork state in client/state

    @Test
    func clientStateArtworkEncodesWidthAndHeight() throws {
        let channel = try ArtworkStateChannel(source: .album, format: .jpeg, width: 800, height: 800)
        let state = try ArtworkStateObject(channels: [channel])
        let data = try JSONEncoder().encode(ClientStateMessage(payload: ClientStatePayload(available: true, artwork: state)))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payloadJSON = try #require(json["payload"] as? [String: Any])
        let artworkJSON = try #require(payloadJSON["artwork"] as? [String: Any])
        let channelJSON = try #require((artworkJSON["channels"] as? [[String: Any]])?.first)
        #expect(channelJSON["source"] as? String == "album")
        #expect(channelJSON["format"] as? String == "jpeg")
        #expect(channelJSON["width"] as? Int == 800)
        #expect(channelJSON["height"] as? Int == 800)
        #expect(channelJSON["media_width"] == nil)
        #expect(channelJSON["media_height"] == nil)
    }

    // MARK: - StreamStartArtwork

    @Test
    func streamStartArtwork_decodesStreamStartArtworkPayload() throws {
        let json = Data("""
        {
            "type": "stream/start",
            "payload": {
                "artwork": {
                    "channels": [
                        {"source": "album", "format": "jpeg", "width": 800, "height": 800},
                        {"source": "artist", "format": "png", "width": 400, "height": 400}
                    ]
                }
            }
        }
        """.utf8)

        let decoder = JSONDecoder()
        let message = try decoder.decode(StreamStartMessage.self, from: json)
        #expect(message.payload.player == nil)

        let artwork = try #require(message.payload.artwork)
        #expect(artwork.channels.count == 2)
        #expect(artwork.channels[0].source == .album)
        #expect(artwork.channels[0].format == .jpeg)
        #expect(artwork.channels[0].width == 800)
        #expect(artwork.channels[0].height == 800)
        #expect(artwork.channels[1].source == .artist)
        #expect(artwork.channels[1].format == .png)
        #expect(artwork.channels[1].width == 400)
    }

    @Test
    func streamStartArtwork_withNoneSourceChannel() throws {
        let json = Data("""
        {
            "type": "stream/start",
            "payload": {
                "artwork": {
                    "channels": [
                        {"source": "none", "format": "jpeg", "width": 0, "height": 0}
                    ]
                }
            }
        }
        """.utf8)

        let decoder = JSONDecoder()
        let message = try decoder.decode(StreamStartMessage.self, from: json)
        let artwork = try #require(message.payload.artwork)
        #expect(artwork.channels[0].source == .none)
    }

    @Test
    func streamArtworkChannelConfig_acceptsValuesThatArtworkChannelWouldReject() throws {
        // StreamArtworkChannelConfig is server-provided — it intentionally has no validation.
        // This test documents the asymmetry: the server can send zero dimensions for an
        // active channel (e.g., during format negotiation), and we accept it without error.
        let config = StreamArtworkChannelConfig(
            source: .album,
            format: .jpeg,
            width: 0,
            height: 0
        )
        #expect(config.source == .album)
        #expect(config.width == 0)
        #expect(config.height == 0)

        // Also verify it decodes from JSON without validation
        let json = Data("""
        {"source": "album", "format": "jpeg", "width": -1, "height": -1}
        """.utf8)
        let decoded = try JSONDecoder().decode(StreamArtworkChannelConfig.self, from: json)
        #expect(decoded.width == -1)
        #expect(decoded.height == -1)
    }

    // MARK: - Artwork state validation

    @Test
    func artworkStateNoneOmitsFormatAndDimensions() throws {
        let state = try ArtworkStateChannel(source: .none)
        let data = try JSONEncoder().encode(state)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["source"] as? String == "none")
        #expect(json["format"] == nil)
        #expect(json["width"] == nil)
        #expect(json["height"] == nil)
    }

    // MARK: - StreamEndMessage with roles

    @Test
    func streamEnd_withRolesDecodesCorrectly() throws {
        let json = Data("""
        {"type": "stream/end", "payload": {"roles": ["player", "artwork"]}}
        """.utf8)

        let decoder = JSONDecoder()
        let message = try decoder.decode(StreamEndMessage.self, from: json)
        let roles = try #require(message.payload.roles)
        #expect(roles.contains("player"))
        #expect(roles.contains("artwork"))
    }

    @Test
    func streamEnd_withoutRolesDecodesEndsAllStreams() throws {
        let json = Data("""
        {"type": "stream/end", "payload": {}}
        """.utf8)

        let decoder = JSONDecoder()
        let message = try decoder.decode(StreamEndMessage.self, from: json)
        #expect(message.payload.roles == nil)
    }

    // MARK: - ArtworkConfiguration

    @Test
    func artworkConfiguration_validatesChannelCount() throws {
        // Valid: 1-4 channels
        let config = try ArtworkConfiguration(channels: [
            ArtworkChannel(source: .album, format: .jpeg, width: 300, height: 300)
        ])
        #expect(config.channels.count == 1)

        let config4 = try ArtworkConfiguration(channels: [
            ArtworkChannel(source: .album, format: .jpeg, width: 300, height: 300),
            ArtworkChannel(source: .artist, format: .png, width: 200, height: 200),
            .disabled,
            ArtworkChannel(source: .album, format: .jpeg, width: 400, height: 400)
        ])
        #expect(config4.channels.count == 4)
    }

    @Test
    func artworkConfiguration_equalityAndHashing() throws {
        let channels = try [
            ArtworkChannel(source: .album, format: .jpeg, width: 300, height: 300),
            .disabled
        ]
        let a = try ArtworkConfiguration(channels: channels)
        let b = try ArtworkConfiguration(channels: channels)
        let c = try ArtworkConfiguration(channels: [
            ArtworkChannel(source: .artist, format: .png, width: 200, height: 200)
        ])

        #expect(a == b)
        #expect(a != c)

        // Verify Hashable: equal values deduplicate in a Set
        let set: Set = [a, b]
        #expect(set.count == 1)
        #expect(!set.contains(c))
    }

    // MARK: - Wire format interoperability

    @Test
    func artworkChannel_jsonMatchesRustPythonWireFormat() throws {
        // This JSON was taken from the sendspin-rs test suite
        let rustJson = Data("""
        {
            "source": "album",
            "format": "jpeg",
            "width": 300,
            "height": 300
        }
        """.utf8)

        let decoder = JSONDecoder()
        let channel = try decoder.decode(ArtworkChannel.self, from: rustJson)
        #expect(channel.source == .album)
        #expect(channel.format == .jpeg)
        #expect(channel.width == 300)
        #expect(channel.height == 300)

        // Re-encode and verify keys match wire format
        let encoder = JSONEncoder()
        let reencoded = try encoder.encode(channel)
        let json = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        #expect(json.keys.contains("width"))
        #expect(json.keys.contains("height"))
        // Verify no camelCase keys leaked
        #expect(json.keys.contains("width"))
        #expect(json.keys.contains("height"))
    }

    @Test
    func streamStart_withBothPlayerAndArtworkDecodes() throws {
        // Real-world scenario: server sends stream/start for both roles
        let json = Data("""
        {
            "type": "stream/start",
            "payload": {
                "player": {
                    "codec": "opus",
                    "sample_rate": 48000,
                    "channels": 2,
                    "bit_depth": 16
                },
                "artwork": {
                    "channels": [
                        {"source": "album", "format": "jpeg", "width": 800, "height": 800}
                    ]
                }
            }
        }
        """.utf8)

        let decoder = JSONDecoder()
        let message = try decoder.decode(StreamStartMessage.self, from: json)
        #expect(message.payload.player != nil)
        #expect(message.payload.player?.codec == "opus")
        #expect(message.payload.artwork != nil)
        #expect(message.payload.artwork?.channels.count == 1)
    }
}
