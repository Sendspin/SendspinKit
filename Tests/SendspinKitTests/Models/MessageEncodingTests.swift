import Foundation
@testable import SendspinKit
import Testing

@Suite("Message Encoding Tests")
struct MessageEncodingTests {
    @Test("ClientHello encodes to snake_case JSON")
    func clientHelloEncoding() throws {
        let payload = ClientHelloPayload(
            clientId: "test-client",
            name: "Test Client",
            deviceInfo: nil,
            version: 1,
            supportedRoles: [.player],
            playerSupport: PlayerSupport(
                supportFormats: [
                    AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16)
                ],
                bufferCapacity: 1024,
                supportedCommands: [.volume, .mute]
            ),
            metadataSupport: nil,
            artworkSupport: nil,
            visualizerSupport: nil
        )

        let message = ClientHelloMessage(payload: payload)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(message)
        let json = try #require(String(data: data, encoding: .utf8))

        // Swift escapes forward slashes in JSON, so we check for both possibilities
        #expect(json.contains("\"type\":\"client/hello\"") || json.contains("\"type\":\"client\\/hello\""))
        #expect(json.contains("\"client_id\":\"test-client\""))
        #expect(json.contains("\"supported_roles\":[\"player\"]"))
    }

    @Test("ServerHello decodes from snake_case JSON")
    func serverHelloDecoding() throws {
        let json = """
        {
            "type": "server/hello",
            "payload": {
                "server_id": "test-server",
                "name": "Test Server",
                "version": 1
            }
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = try #require(json.data(using: .utf8))
        let message = try decoder.decode(ServerHelloMessage.self, from: data)

        #expect(message.type == "server/hello")
        #expect(message.payload.serverId == "test-server")
        #expect(message.payload.name == "Test Server")
        #expect(message.payload.version == 1)
    }
}
