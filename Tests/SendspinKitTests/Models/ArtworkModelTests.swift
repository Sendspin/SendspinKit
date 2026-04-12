// ABOUTME: Tests for artwork role data models and message encoding
// ABOUTME: Validates ArtworkChannel, ArtworkSupport, StreamStartArtwork, and stream/request-format

import Foundation
import Testing

@testable import SendspinKit

@Suite("Artwork Models")
struct ArtworkModelTests {
    // MARK: - ArtworkChannel

    @Test("ArtworkChannel round-trips through JSON")
    func artworkChannelCodable() throws {
        let channel = ArtworkChannel(
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

    @Test("ArtworkChannel with none source for disabled channel")
    func artworkChannelNoneSource() throws {
        let channel = ArtworkChannel(
            source: .none,
            format: .jpeg,
            mediaWidth: 1,
            mediaHeight: 1
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(channel)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["source"] as? String == "none")
    }

    @Test("ArtworkChannel supports all image formats")
    func allImageFormats() throws {
        let formats: [ImageFormat] = [.jpeg, .png, .bmp]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for format in formats {
            let channel = ArtworkChannel(
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

    @Test("ArtworkChannel supports all source types")
    func allSourceTypes() throws {
        let sources: [ArtworkSource] = [.album, .artist, .none]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for source in sources {
            let channel = ArtworkChannel(
                source: source,
                format: .jpeg,
                mediaWidth: 300,
                mediaHeight: 300
            )
            let data = try encoder.encode(channel)
            let decoded = try decoder.decode(ArtworkChannel.self, from: data)
            #expect(decoded.source == source)
        }
    }

    // MARK: - ArtworkSupport in client/hello

    @Test("ArtworkSupport encodes channels array for client/hello")
    func artworkSupportEncoding() throws {
        let support = ArtworkSupport(channels: [
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

    @Test("ArtworkSupport decodes from server-like JSON")
    func artworkSupportDecoding() throws {
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

    @Test("client/hello with artwork@v1_support encodes correctly")
    func clientHelloWithArtwork() throws {
        let payload = ClientHelloPayload(
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

    @Test("StreamStartArtwork decodes stream/start artwork payload")
    func streamStartArtworkDecoding() throws {
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

    @Test("StreamStartArtwork with none source channel")
    func streamStartArtworkNoneChannel() throws {
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

    // MARK: - StreamRequestFormat (artwork)

    @Test("stream/request-format with artwork encodes correctly")
    func streamRequestFormatArtwork() throws {
        let request = ArtworkFormatRequest(
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

    @Test("stream/request-format with partial artwork update")
    func streamRequestFormatPartialUpdate() throws {
        // Per spec: only include fields that are changing
        let request = ArtworkFormatRequest(
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

    @Test("stream/end with roles decodes correctly")
    func streamEndWithRoles() throws {
        let json = Data("""
        {"type": "stream/end", "payload": {"roles": ["player", "artwork"]}}
        """.utf8)

        let decoder = JSONDecoder()
        let message = try decoder.decode(StreamEndMessage.self, from: json)
        let roles = try #require(message.payload.roles)
        #expect(roles.contains("player"))
        #expect(roles.contains("artwork"))
    }

    @Test("stream/end without roles decodes (ends all streams)")
    func streamEndWithoutRoles() throws {
        let json = Data("""
        {"type": "stream/end", "payload": {}}
        """.utf8)

        let decoder = JSONDecoder()
        let message = try decoder.decode(StreamEndMessage.self, from: json)
        #expect(message.payload.roles == nil)
    }

    // MARK: - ArtworkConfiguration

    @Test("ArtworkConfiguration validates channel count")
    func artworkConfigValidation() {
        // Valid: 1-4 channels
        let config = ArtworkConfiguration(channels: [
            ArtworkChannel(source: .album, format: .jpeg, mediaWidth: 300, mediaHeight: 300)
        ])
        #expect(config.channels.count == 1)

        let config4 = ArtworkConfiguration(channels: [
            ArtworkChannel(source: .album, format: .jpeg, mediaWidth: 300, mediaHeight: 300),
            ArtworkChannel(source: .artist, format: .png, mediaWidth: 200, mediaHeight: 200),
            ArtworkChannel(source: .none, format: .bmp, mediaWidth: 100, mediaHeight: 100),
            ArtworkChannel(source: .album, format: .jpeg, mediaWidth: 400, mediaHeight: 400)
        ])
        #expect(config4.channels.count == 4)
    }

    // MARK: - Wire format interoperability

    @Test("Artwork channel JSON matches Rust/Python wire format")
    func wireFormatInterop() throws {
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

    @Test("stream/start with both player and artwork decodes")
    func streamStartCombined() throws {
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
