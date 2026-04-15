// ABOUTME: Tests for artwork role data models and message encoding
// ABOUTME: Validates ArtworkChannel, ArtworkSupport, StreamStartArtwork, and stream/request-format

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
            mediaWidth: 800,
            mediaHeight: 800
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(channel)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["source"] as? String == "album")
        #expect(json["format"] as? String == "jpeg")
        #expect(json["media_width"] as? Int == 800)
        #expect(json["media_height"] as? Int == 800)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ArtworkChannel.self, from: data)
        #expect(decoded.source == .album)
        #expect(decoded.format == .jpeg)
        #expect(decoded.mediaWidth == 800)
        #expect(decoded.mediaHeight == 800)
    }

    @Test
    func artworkChannel_disabledPlaceholderEncodesCorrectly() throws {
        let channel = ArtworkChannel.disabled

        let encoder = JSONEncoder()
        let data = try encoder.encode(channel)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["source"] as? String == "none")
        #expect(json["media_width"] as? Int == 0)
        #expect(json["media_height"] as? Int == 0)
    }

    @Test
    func artworkChannel_supportsAllImageFormats() throws {
        let formats: [ImageFormat] = [.jpeg, .png, .bmp]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for format in formats {
            let channel = try ArtworkChannel(
                source: .album,
                format: format,
                mediaWidth: 300,
                mediaHeight: 300
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
                mediaWidth: 300,
                mediaHeight: 300
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
        #expect(decoded.mediaWidth == 0)
        #expect(decoded.mediaHeight == 0)
    }

    // MARK: - ArtworkChannel decode validation

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
        {"source": "none", "format": "jpeg", "media_width": 0, "media_height": 0}
        """.utf8)

        let channel = try JSONDecoder().decode(ArtworkChannel.self, from: json)
        #expect(channel.source == .none)
        #expect(channel.mediaWidth == 0)
        #expect(channel.mediaHeight == 0)
    }

    // MARK: - ArtworkChannel init validation (ConfigurationError)

    @Test
    func artworkChannel_initRejectsNegativeWidthForActiveChannel() {
        #expect(throws: ConfigurationError.self) {
            try ArtworkChannel(source: .album, format: .jpeg, mediaWidth: -1, mediaHeight: 300)
        }
    }

    @Test
    func artworkChannel_initRejectsZeroWidthForActiveChannel() {
        #expect(throws: ConfigurationError.self) {
            try ArtworkChannel(source: .album, format: .jpeg, mediaWidth: 0, mediaHeight: 300)
        }
    }

    @Test
    func artworkChannel_initRejectsZeroHeightForActiveChannel() {
        #expect(throws: ConfigurationError.self) {
            try ArtworkChannel(source: .album, format: .jpeg, mediaWidth: 300, mediaHeight: 0)
        }
    }

    @Test
    func artworkChannel_initRejectsNegativeHeightForActiveChannel() {
        #expect(throws: ConfigurationError.self) {
            try ArtworkChannel(source: .album, format: .jpeg, mediaWidth: 300, mediaHeight: -1)
        }
    }

    // MARK: - ArtworkSupport in client/hello

    @Test
    func artworkSupport_encodesChannelsArrayForClientHello() throws {
        let support = try ArtworkSupport(channels: [
            ArtworkChannel(source: .album, format: .jpeg, mediaWidth: 800, mediaHeight: 800),
            ArtworkChannel(source: .artist, format: .png, mediaWidth: 400, mediaHeight: 400)
        ])

        let encoder = JSONEncoder()
        let data = try encoder.encode(support)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let channels = try #require(json["channels"] as? [[String: Any]])
        #expect(channels.count == 2)
        #expect(channels[0]["source"] as? String == "album")
        #expect(channels[0]["format"] as? String == "jpeg")
        #expect(channels[0]["media_width"] as? Int == 800)
        #expect(channels[1]["source"] as? String == "artist")
        #expect(channels[1]["format"] as? String == "png")
        #expect(channels[1]["media_width"] as? Int == 400)
    }

    @Test
    func artworkSupport_decodesFromServerLikeJSON() throws {
        let json = Data("""
        {
            "channels": [
                {"source": "album", "format": "jpeg", "media_width": 300, "media_height": 300}
            ]
        }
        """.utf8)

        let decoder = JSONDecoder()
        let support = try decoder.decode(ArtworkSupport.self, from: json)
        #expect(support.channels.count == 1)
        #expect(support.channels[0].source == .album)
        #expect(support.channels[0].mediaWidth == 300)
    }

    // MARK: - ArtworkSupport in full client/hello

    @Test
    func clientHello_withArtworkV1SupportEncodesCorrectly() throws {
        let payload = try ClientHelloPayload(
            clientId: "test-client",
            name: "Test Display",
            deviceInfo: nil,
            version: 1,
            supportedRoles: [.artworkV1],
            playerV1Support: nil,
            artworkV1Support: ArtworkSupport(channels: [
                ArtworkChannel(source: .album, format: .jpeg, mediaWidth: 800, mediaHeight: 800)
            ]),
            visualizerV1Support: nil
        )
        let message = ClientHelloMessage(payload: payload)

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payloadJson = try #require(json["payload"] as? [String: Any])

        // Check artwork@v1_support key is present with correct wire format
        let artworkSupport = try #require(payloadJson["artwork@v1_support"] as? [String: Any])
        let channels = try #require(artworkSupport["channels"] as? [[String: Any]])
        #expect(channels.count == 1)
        #expect(channels[0]["source"] as? String == "album")
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

    // MARK: - StreamRequestFormat (artwork)

    @Test
    func streamRequestFormat_withArtworkEncodesCorrectly() throws {
        let request = try ArtworkFormatRequest(
            channel: 0,
            source: .album,
            format: .jpeg,
            mediaWidth: 800,
            mediaHeight: 800
        )
        let message = StreamRequestFormatMessage(
            payload: StreamRequestFormatPayload(artwork: request)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["type"] as? String == "stream/request-format")
        let payloadJson = try #require(json["payload"] as? [String: Any])
        let artworkJson = try #require(payloadJson["artwork"] as? [String: Any])
        #expect(artworkJson["channel"] as? Int == 0)
        #expect(artworkJson["source"] as? String == "album")
        #expect(artworkJson["format"] as? String == "jpeg")
        #expect(artworkJson["media_width"] as? Int == 800)
        #expect(artworkJson["media_height"] as? Int == 800)
    }

    @Test
    func streamRequestFormat_withPartialArtworkUpdate() throws {
        // Per spec: only include fields that are changing
        let request = try ArtworkFormatRequest(
            channel: 1,
            format: .png
        )
        let message = StreamRequestFormatMessage(
            payload: StreamRequestFormatPayload(artwork: request)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payloadJson = try #require(json["payload"] as? [String: Any])
        let artworkJson = try #require(payloadJson["artwork"] as? [String: Any])

        #expect(artworkJson["channel"] as? Int == 1)
        #expect(artworkJson["format"] as? String == "png")
        // Optional fields should still be present (as null) since we encode all fields
        // The important thing is channel + format are correct
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
            ArtworkChannel(source: .album, format: .jpeg, mediaWidth: 300, mediaHeight: 300)
        ])
        #expect(config.channels.count == 1)

        let config4 = try ArtworkConfiguration(channels: [
            ArtworkChannel(source: .album, format: .jpeg, mediaWidth: 300, mediaHeight: 300),
            ArtworkChannel(source: .artist, format: .png, mediaWidth: 200, mediaHeight: 200),
            .disabled,
            ArtworkChannel(source: .album, format: .jpeg, mediaWidth: 400, mediaHeight: 400)
        ])
        #expect(config4.channels.count == 4)
    }

    @Test
    func artworkConfiguration_equalityAndHashing() throws {
        let channels = try [
            ArtworkChannel(source: .album, format: .jpeg, mediaWidth: 300, mediaHeight: 300),
            .disabled
        ]
        let a = try ArtworkConfiguration(channels: channels)
        let b = try ArtworkConfiguration(channels: channels)
        let c = try ArtworkConfiguration(channels: [
            ArtworkChannel(source: .artist, format: .png, mediaWidth: 200, mediaHeight: 200)
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
            "media_width": 300,
            "media_height": 300
        }
        """.utf8)

        let decoder = JSONDecoder()
        let channel = try decoder.decode(ArtworkChannel.self, from: rustJson)
        #expect(channel.source == .album)
        #expect(channel.format == .jpeg)
        #expect(channel.mediaWidth == 300)
        #expect(channel.mediaHeight == 300)

        // Re-encode and verify keys match wire format
        let encoder = JSONEncoder()
        let reencoded = try encoder.encode(channel)
        let json = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        #expect(json.keys.contains("media_width"))
        #expect(json.keys.contains("media_height"))
        // Verify no camelCase keys leaked
        #expect(!json.keys.contains("mediaWidth"))
        #expect(!json.keys.contains("mediaHeight"))
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
