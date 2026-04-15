// ABOUTME: Integration tests for full message encoding/decoding round trips
// ABOUTME: Tests that messages can be encoded to JSON, decoded back, and maintain data integrity

import Foundation
@testable import SendspinKit
import Testing

struct MessageRoundTripTests {
    @Test
    func `ClientHello round trip maintains all data`() throws {
        // Create complete ClientHello with all fields populated
        let originalPayload = try ClientHelloPayload(
            clientId: "test-client-123",
            name: "Test Speaker",
            deviceInfo: DeviceInfo(
                productName: "HomePod",
                manufacturer: "Apple",
                softwareVersion: "17.0"
            ),
            version: 1,
            supportedRoles: [.playerV1, .controllerV1, .metadataV1],
            playerV1Support: PlayerSupport(
                supportedFormats: [
                    AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16),
                    AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 24),
                    AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
                ],
                bufferCapacity: 1_048_576,
                supportedCommands: [.volume, .mute]
            ),
            artworkV1Support: nil,
            visualizerV1Support: nil
        )

        let message = ClientHelloMessage(payload: originalPayload)

        // Encode to JSON (using custom CodingKeys, not convertToSnakeCase)
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(message)

        // Decode back
        let decoder = JSONDecoder()
        let decodedMessage = try decoder.decode(ClientHelloMessage.self, from: jsonData)

        // Verify all fields match
        #expect(decodedMessage.type == "client/hello")
        #expect(decodedMessage.payload.clientId == "test-client-123")
        #expect(decodedMessage.payload.name == "Test Speaker")
        #expect(decodedMessage.payload.version == 1)
        #expect(decodedMessage.payload.supportedRoles == [.playerV1, .controllerV1, .metadataV1])

        // Verify device info
        let deviceInfo = try #require(decodedMessage.payload.deviceInfo)
        #expect(deviceInfo.productName == "HomePod")
        #expect(deviceInfo.manufacturer == "Apple")
        #expect(deviceInfo.softwareVersion == "17.0")

        // Verify player support
        let playerSupport = try #require(decodedMessage.payload.playerV1Support)
        #expect(playerSupport.bufferCapacity == 1_048_576)
        #expect(playerSupport.supportedCommands == [.volume, .mute])
        #expect(playerSupport.supportedFormats.count == 3)

        // Verify first format
        let firstFormat = playerSupport.supportedFormats[0]
        #expect(firstFormat.codec == .opus)
        #expect(firstFormat.channels == 2)
        #expect(firstFormat.sampleRate == 48_000)
        #expect(firstFormat.bitDepth == 16)
    }

    @Test
    func `StreamStart round trip with codec header`() throws {
        let codecHeaderData = Data([0x66, 0x4C, 0x61, 0x43]) // "fLaC" FLAC signature
        let codecHeaderB64 = codecHeaderData.base64EncodedString()

        let originalPayload = StreamStartPayload(
            player: StreamStartPlayer(
                codec: "flac",
                sampleRate: 44_100,
                channels: 2,
                bitDepth: 24,
                codecHeader: codecHeaderB64
            ),
            artwork: nil,
            visualizer: nil
        )

        let message = StreamStartMessage(payload: originalPayload)

        // Encode (now uses custom CodingKeys, no strategy needed)
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(message)

        // Decode
        let decoder = JSONDecoder()
        let decodedMessage = try decoder.decode(StreamStartMessage.self, from: jsonData)

        // Verify
        let player = try #require(decodedMessage.payload.player)
        #expect(player.codec == "flac")
        #expect(player.sampleRate == 44_100)
        #expect(player.channels == 2)
        #expect(player.bitDepth == 24)
        #expect(player.codecHeader == codecHeaderB64)

        // Verify codec header can be decoded back
        let decodedHeader = try Data(base64Encoded: #require(player.codecHeader))
        #expect(decodedHeader == codecHeaderData)
    }

    @Test
    func `GroupUpdate with null fields`() throws {
        // Test partial updates with null fields (common in delta updates)
        let jsonWithNulls = Data("""
        {
            "type": "group/update",
            "payload": {
                "playback_state": "playing",
                "group_id": "group-123",
                "group_name": null
            }
        }
        """.utf8)

        // Now uses custom CodingKeys, no strategy needed
        let decoder = JSONDecoder()

        let message = try decoder.decode(GroupUpdateMessage.self, from: jsonWithNulls)

        #expect(message.type == "group/update")
        #expect(message.payload.playbackState == .playing)
        #expect(message.payload.groupId == "group-123")
        #expect(message.payload.groupName == nil)
    }
}
