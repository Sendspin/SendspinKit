import Foundation
@testable import SendspinKit
import Testing

@Suite("Message Encoding Tests")
struct MessageEncodingTests {
    @Test("ClientHello encodes with versioned roles")
    func clientHelloEncoding() throws {
        let payload = ClientHelloPayload(
            clientId: "test-client",
            name: "Test Client",
            deviceInfo: nil,
            version: 1,
            supportedRoles: [.playerV1],
            playerV1Support: PlayerSupport(
                supportedFormats: [
                    AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16)
                ],
                bufferCapacity: 1024,
                supportedCommands: [.volume, .mute]
            ),
            metadataV1Support: nil,
            artworkV1Support: nil,
            visualizerV1Support: nil
        )

        let message = ClientHelloMessage(payload: payload)

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = try #require(String(data: data, encoding: .utf8))

        // Swift escapes forward slashes in JSON, so we check for both possibilities
        #expect(json.contains("\"type\":\"client/hello\"") || json.contains("\"type\":\"client\\/hello\""))
        #expect(json.contains("\"client_id\":\"test-client\""))
        #expect(json.contains("\"supported_roles\":[\"player@v1\"]"))
        #expect(json.contains("\"player@v1_support\""))
    }

    @Test("ServerHello decodes with active_roles and connection_reason")
    func serverHelloDecoding() throws {
        let json = """
        {
            "type": "server/hello",
            "payload": {
                "server_id": "test-server",
                "name": "Test Server",
                "version": 1,
                "active_roles": ["player@v1", "metadata@v1"],
                "connection_reason": "playback"
            }
        }
        """

        let decoder = JSONDecoder()
        let data = try #require(json.data(using: .utf8))
        let message = try decoder.decode(ServerHelloMessage.self, from: data)

        #expect(message.type == "server/hello")
        #expect(message.payload.serverId == "test-server")
        #expect(message.payload.name == "Test Server")
        #expect(message.payload.version == 1)
        #expect(message.payload.activeRoles.count == 2)
        #expect(message.payload.activeRoles.contains(.playerV1))
        #expect(message.payload.activeRoles.contains(.metadataV1))
        #expect(message.payload.connectionReason == .playback)
    }

    @Test("ClientState encodes with client state and player state object")
    func clientStateEncoding() throws {
        let playerState = PlayerStateObject(volume: 80, muted: false, staticDelayMs: 0)
        let payload = ClientStatePayload(state: .synchronized, player: playerState)
        let message = ClientStateMessage(payload: payload)

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"type\":\"client/state\"") || json.contains("\"type\":\"client\\/state\""))
        #expect(json.contains("\"state\":\"synchronized\""))
        #expect(json.contains("\"volume\":80"))
        #expect(json.contains("\"muted\":false"))
        #expect(json.contains("\"static_delay_ms\":0"))
    }

    // MARK: - client/goodbye

    @Test("ClientGoodbye encodes with shutdown reason")
    func clientGoodbyeShutdown() throws {
        let message = ClientGoodbyeMessage(payload: GoodbyePayload(reason: .shutdown))

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"reason\":\"shutdown\""))
    }

    @Test("ClientGoodbye encodes snake_case reasons correctly")
    func clientGoodbyeReasons() throws {
        let encoder = JSONEncoder()

        for (reason, expected) in [
            (GoodbyeReason.anotherServer, "another_server"),
            (.shutdown, "shutdown"),
            (.restart, "restart"),
            (.userRequest, "user_request"),
        ] as [(GoodbyeReason, String)] {
            let message = ClientGoodbyeMessage(payload: GoodbyePayload(reason: reason))
            let data = try encoder.encode(message)
            let json = try #require(String(data: data, encoding: .utf8))
            #expect(json.contains("\"\(expected)\""), "Expected '\(expected)' in JSON for \(reason)")
        }
    }

    @Test("ClientGoodbye decodes from JSON")
    func clientGoodbyeDecoding() throws {
        let json = """
        {"type": "client/goodbye", "payload": {"reason": "another_server"}}
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(ClientGoodbyeMessage.self, from: data)

        #expect(message.payload?.reason == .anotherServer)
    }

    // MARK: - stream/clear

    @Test("StreamClear decodes with roles")
    func streamClearWithRoles() throws {
        let json = """
        {"type": "stream/clear", "payload": {"roles": ["player", "visualizer"]}}
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(StreamClearMessage.self, from: data)

        #expect(message.type == "stream/clear")
        let roles = try #require(message.payload.roles)
        #expect(roles.count == 2)
        #expect(roles.contains("player"))
        #expect(roles.contains("visualizer"))
    }

    @Test("StreamClear decodes without roles (clears all)")
    func streamClearWithoutRoles() throws {
        let json = """
        {"type": "stream/clear", "payload": {}}
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(StreamClearMessage.self, from: data)

        #expect(message.payload.roles == nil)
    }

    // MARK: - server/command

    @Test("ServerCommand decodes volume command")
    func serverCommandVolume() throws {
        let json = """
        {"type": "server/command", "payload": {"player": {"command": "volume", "volume": 75}}}
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(ServerCommandMessage.self, from: data)

        let player = try #require(message.payload.player)
        #expect(player.command == "volume")
        #expect(player.volume == 75)
        #expect(player.mute == nil)
    }

    @Test("ServerCommand decodes mute command")
    func serverCommandMute() throws {
        let json = """
        {"type": "server/command", "payload": {"player": {"command": "mute", "mute": true}}}
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(ServerCommandMessage.self, from: data)

        let player = try #require(message.payload.player)
        #expect(player.command == "mute")
        #expect(player.mute == true)
    }

    @Test("ServerCommand decodes set_static_delay command")
    func serverCommandStaticDelay() throws {
        let json = """
        {"type": "server/command", "payload": {"player": {"command": "set_static_delay", "static_delay_ms": 250}}}
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(ServerCommandMessage.self, from: data)

        let player = try #require(message.payload.player)
        #expect(player.command == "set_static_delay")
        #expect(player.staticDelayMs == 250)
    }

    // MARK: - server/state

    @Test("ServerState decodes metadata with null fields")
    func serverStateMetadata() throws {
        // This is what sendspin-cli actually sends
        let json = """
        {"type": "server/state", "payload": {"metadata": {"timestamp": 12345678, "title": null, "artist": null, "album": null, "album_artist": null, "artwork_url": null, "year": null, "track": null, "progress": null, "repeat": null, "shuffle": null}}}
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(ServerStateMessage.self, from: data)

        let metadata = try #require(message.payload.metadata)
        #expect(metadata.timestamp == 12345678)
        #expect(metadata.title == nil)
        #expect(metadata.artist == nil)
    }
}
