import Foundation
@testable import SendspinKit
import Testing

struct MessageEncodingTests {
    @Test
    func `ClientHello encodes with versioned roles`() throws {
        let payload = ClientHelloPayload(
            clientId: "test-client",
            name: "Test Client",
            deviceInfo: nil,
            version: 1,
            supportedRoles: [.playerV1],
            playerV1Support: PlayerSupport(
                supportedFormats: [
                    AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
                ],
                bufferCapacity: 1_024,
                supportedCommands: [.volume, .mute]
            ),
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

    @Test
    func `ServerHello decodes with active_roles and connection_reason`() throws {
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

    @Test
    func `ClientState encodes with client state and player state object`() throws {
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

    @Test
    func `ClientGoodbye encodes with shutdown reason`() throws {
        let message = ClientGoodbyeMessage(payload: GoodbyePayload(reason: .shutdown))

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"reason\":\"shutdown\""))
    }

    @Test
    func `ClientGoodbye encodes snake_case reasons correctly`() throws {
        let encoder = JSONEncoder()

        for (reason, expected) in [
            (GoodbyeReason.anotherServer, "another_server"),
            (.shutdown, "shutdown"),
            (.restart, "restart"),
            (.userRequest, "user_request")
        ] as [(GoodbyeReason, String)] {
            let message = ClientGoodbyeMessage(payload: GoodbyePayload(reason: reason))
            let data = try encoder.encode(message)
            let json = try #require(String(data: data, encoding: .utf8))
            #expect(json.contains("\"\(expected)\""), "Expected '\(expected)' in JSON for \(reason)")
        }
    }

    @Test
    func `ClientGoodbye decodes from JSON`() throws {
        let json = """
        {"type": "client/goodbye", "payload": {"reason": "another_server"}}
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(ClientGoodbyeMessage.self, from: data)

        #expect(message.payload?.reason == .anotherServer)
    }

    // MARK: - stream/clear

    @Test
    func `StreamClear decodes with roles`() throws {
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

    @Test
    func `StreamClear decodes without roles (clears all)`() throws {
        let json = """
        {"type": "stream/clear", "payload": {}}
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(StreamClearMessage.self, from: data)

        #expect(message.payload.roles == nil)
    }

    // MARK: - server/command

    @Test
    func `ServerCommand decodes volume command`() throws {
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

    @Test
    func `ServerCommand decodes mute command`() throws {
        let json = """
        {"type": "server/command", "payload": {"player": {"command": "mute", "mute": true}}}
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(ServerCommandMessage.self, from: data)

        let player = try #require(message.payload.player)
        #expect(player.command == "mute")
        #expect(player.mute == true)
    }

    @Test
    func `ServerCommand decodes set_static_delay command`() throws {
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

    @Test
    func `ServerState decodes metadata with null fields as .null`() throws {
        // When the server sends explicit null, it means "clear this field"
        let json = """
        {
            "type": "server/state",
            "payload": {
                "metadata": {
                    "timestamp": 12345678,
                    "title": null, "artist": null, "album": null,
                    "album_artist": null, "artwork_url": null, "year": null,
                    "track": null, "progress": null, "repeat": null, "shuffle": null
                }
            }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(ServerStateMessage.self, from: data)

        let metadata = try #require(message.payload.metadata)
        #expect(metadata.timestamp == 12_345_678)
        // Explicit null should decode as .null (clear), not .absent (keep previous)
        #expect(metadata.title.merge(previous: "old") == nil)
        #expect(metadata.artist.merge(previous: "old") == nil)
        #expect(metadata.album.merge(previous: "old") == nil)
        #expect(metadata.year.merge(previous: 2_024) == nil)
    }

    @Test
    func `ServerState decodes metadata with absent fields as .absent`() throws {
        // When a field is absent from JSON, it means "no change" — keep previous value
        let json = """
        {"type": "server/state", "payload": {"metadata": {"timestamp": 12345678, "title": "New Song"}}}
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(ServerStateMessage.self, from: data)

        let metadata = try #require(message.payload.metadata)
        #expect(metadata.timestamp == 12_345_678)
        // Present field should have the value
        #expect(metadata.title.merge(previous: "old") == "New Song")
        // Absent fields should preserve previous values
        #expect(metadata.artist.merge(previous: "Previous Artist") == "Previous Artist")
        #expect(metadata.album.merge(previous: "Previous Album") == "Previous Album")
        #expect(metadata.year.merge(previous: 2_024) == 2_024)
        // Absent with no previous should remain nil
        #expect(metadata.shuffle.merge(previous: nil) == nil)
    }
}
