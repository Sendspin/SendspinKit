import Foundation
@testable import SendspinKit
import Testing

struct MessageEncodingTests {
    @Test
    func clientHello_encodesWithVersionedRoles() throws {
        let payload = try ClientHelloPayload(
            name: "Test Client",
            deviceInfo: nil,
            trustLevel: .none,
            supportedPairMethods: [],
            unpairedAccess: UnpairedAccessAdvertisement(enabled: true),
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
        #expect(json.contains("\"supported_roles\":[\"player@v1\"]"))
        #expect(json.contains("\"player@v1_support\""))
    }

    @Test
    func serverHello_decodesNameOnlyPayload() throws {
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
        #expect(message.payload.name == "Test Server")
    }

    @Test
    func deviceInfo_encodesMacAddress() throws {
        let info = DeviceInfo(
            productName: "Host Product",
            manufacturer: "Host Manufacturer",
            softwareVersion: "1.2.3",
            macAddress: "aa:bb:cc:dd:ee:ff"
        )

        let data = try JSONEncoder().encode(info)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"product_name\":\"Host Product\""))
        #expect(json.contains("\"software_version\":\"1.2.3\""))
        #expect(json.contains("\"mac_address\":\"aa:bb:cc:dd:ee:ff\""))
    }

    @Test
    func clientState_encodesWithClientStateAndPlayerStateObject() throws {
        let playerState = try PlayerStateObject(volume: 80, muted: false, outputDelayMs: 0)
        let payload = ClientStatePayload(available: true, player: playerState)
        let message = ClientStateMessage(payload: payload)

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"type\":\"client/state\"") || json.contains("\"type\":\"client\\/state\""))
        #expect(json.contains("\"available\":true"))
        #expect(json.contains("\"volume\":80"))
        #expect(json.contains("\"muted\":false"))
        #expect(json.contains("\"static_delay_ms\":0"))
    }

    @Test
    func playerStateObject_acceptsSetOutputDelayInSupportedCommands() throws {
        let state = try PlayerStateObject(outputDelayMs: 0, supportedCommands: [.setOutputDelay])
        #expect(state.supportedCommands == [.setOutputDelay])
    }

    @Test
    func playerStateObject_rejectsVolumeMuteInSupportedCommands() {
        // client/state supported_commands is a subset of {set_output_delay}.
        #expect(throws: ConfigurationError.invalidStateCommands(["volume"])) {
            try PlayerStateObject(supportedCommands: [.volume])
        }
        #expect(throws: ConfigurationError.invalidStateCommands(["mute", "volume"])) {
            try PlayerStateObject(supportedCommands: [.volume, .mute])
        }
    }

    // MARK: - client/goodbye

    @Test
    func clientGoodbye_encodesWithShutdownReason() throws {
        let message = ClientGoodbyeMessage(payload: GoodbyePayload(reason: .shutdown))

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"reason\":\"shutdown\""))
    }

    @Test
    func clientGoodbye_encodesSnakeCaseReasonsCorrectly() throws {
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
    func clientGoodbye_decodesFromJSON() throws {
        let json = """
        {"type": "client/goodbye", "payload": {"reason": "another_server"}}
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(ClientGoodbyeMessage.self, from: data)

        #expect(message.payload.reason == .anotherServer)
    }

    @Test
    func clientGoodbye_rejectsMissingPayload() throws {
        let json = """
        {"type": "client/goodbye"}
        """
        let data = try #require(json.data(using: .utf8))

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ClientGoodbyeMessage.self, from: data)
        }
    }

    @Test
    func clientGoodbye_rejectsMissingReason() throws {
        let json = """
        {"type": "client/goodbye", "payload": {}}
        """
        let data = try #require(json.data(using: .utf8))

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ClientGoodbyeMessage.self, from: data)
        }
    }

    // MARK: - stream/clear

    @Test
    func streamClear_decodesWithRoles() throws {
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
    func streamClear_decodesWithoutRolesClearsAll() throws {
        let json = """
        {"type": "stream/clear", "payload": {}}
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(StreamClearMessage.self, from: data)

        #expect(message.payload.roles == nil)
    }

    // MARK: - server/command

    @Test
    func serverCommand_decodesVolumeCommand() throws {
        let json = """
        {"type": "server/command", "payload": {"player": {"command": "volume", "volume": 75}}}
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(ServerCommandMessage.self, from: data)

        let player = try #require(message.payload.player)
        #expect(player.command == .volume)
        #expect(player.volume == 75)
        #expect(player.mute == nil)
    }

    @Test
    func serverCommand_decodesMuteCommand() throws {
        let json = """
        {"type": "server/command", "payload": {"player": {"command": "mute", "mute": true}}}
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(ServerCommandMessage.self, from: data)

        let player = try #require(message.payload.player)
        #expect(player.command == .mute)
        #expect(player.mute == true)
    }

    @Test
    func serverCommand_decodesSetOutputDelayCommand() throws {
        let json = """
        {"type": "server/command", "payload": {"player": {"command": "set_static_delay", "static_delay_ms": 250}}}
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(ServerCommandMessage.self, from: data)

        let player = try #require(message.payload.player)
        #expect(player.command == .setOutputDelay)
        #expect(player.outputDelayMs == 250)
    }

    // MARK: - server/state

    @Test
    func serverState_decodesMetadataWithNullFieldsAsNull() throws {
        // When the server sends explicit null, it means "clear this field"
        let json = """
        {
            "type": "server/state",
            "payload": {
                "metadata": {
                    "timestamp": 12345678,
                    "title": null, "artist": null, "album": null,
                    "album_artist": null, "artwork_url": null, "year": null,
                    "track": null, "progress": null
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
    func serverState_decodesMetadataWithAbsentFieldsAsAbsent() throws {
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
        #expect(metadata.track.merge(previous: nil) == nil)
    }

    @Test
    func serverState_decodesColorArraysAndNullDeltas() throws {
        let json = """
        {
            "type": "server/state",
            "payload": {
                "color": {
                    "timestamp": 12345678,
                    "background_dark": [12, 34, 56],
                    "background_light": null,
                    "primary": [255, 128, 0]
                }
            }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(ServerStateMessage.self, from: data)
        let color = try #require(message.payload.color.merge(previous: nil))

        #expect(color.timestamp == 12_345_678)
        #expect(color.backgroundDark.merge(previous: nil) == SendspinColor(red: 12, green: 34, blue: 56))
        #expect(color.backgroundLight.merge(previous: SendspinColor(red: 1, green: 2, blue: 3)) == nil)
        #expect(color.primary.merge(previous: nil) == SendspinColor(red: 255, green: 128, blue: 0))
        #expect(color.accent.merge(previous: SendspinColor(red: 4, green: 5, blue: 6)) == SendspinColor(red: 4, green: 5, blue: 6))
    }

    @Test(arguments: [
        "[0, 256, 2]",
        "[-1, 0, 0]",
        "[1, 2]",
        "[1, 2, 3, 4]",
        "[]",
        "[null, 0, 0]",
        "[\"a\", \"b\", \"c\"]",
        "[1.5, 2, 3]"
    ])
    func serverState_rejectsInvalidColorArray(_ components: String) throws {
        let json = """
        {"type": "server/state", "payload": {"color": {"timestamp": 1, "primary": \(components)}}}
        """
        let data = try #require(json.data(using: .utf8))

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ServerStateMessage.self, from: data)
        }
    }

    @Test
    func serverState_acceptsBlackColorAtLowerBoundary() throws {
        let json = """
        {"type": "server/state", "payload": {"color": {"timestamp": 1, "primary": [0, 0, 0]}}}
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(ServerStateMessage.self, from: data)
        let color = try #require(message.payload.color.merge(previous: nil))
        #expect(color.primary.merge(previous: nil) == SendspinColor(red: 0, green: 0, blue: 0))
    }

    @Test
    func serverState_rejectsColorWithoutTimestamp() throws {
        let json = """
        {"type": "server/state", "payload": {"color": {"primary": [1, 2, 3]}}}
        """
        let data = try #require(json.data(using: .utf8))
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ServerStateMessage.self, from: data)
        }
    }

    @Test
    func serverState_encodesColorAbsentFieldsWithoutInventingNulls() throws {
        let message = ServerStateMessage(payload: ServerStatePayload(
            color: ServerColorState(
                timestamp: 42,
                backgroundLight: .value(SendspinColor(red: 4, green: 5, blue: 6)),
                primary: .value(SendspinColor(red: 1, green: 2, blue: 3)),
                accent: .null,
                onDark: .value(SendspinColor(red: 7, green: 8, blue: 9)),
                onLight: .value(SendspinColor(red: 10, green: 11, blue: 12))
            )
        ))
        let data = try JSONEncoder().encode(message)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"timestamp\":42"))
        #expect(json.contains("\"background_light\":[4,5,6]"))
        #expect(json.contains("\"primary\":[1,2,3]"))
        #expect(json.contains("\"accent\":null"))
        #expect(json.contains("\"on_dark\":[7,8,9]"))
        #expect(json.contains("\"on_light\":[10,11,12]"))
        #expect(!json.contains("background_dark"))
    }

    @Test
    func serverState_decodesWholeColorNull() throws {
        let json = """
        {"type": "server/state", "payload": {"color": null}}
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(ServerStateMessage.self, from: data)
        #expect(message.payload.color == .null)
    }

    @Test
    func serverState_decodesCompleteMetadataProgress() throws {
        let json = """
        {
            "type": "server/state",
            "payload": {
                "metadata": {
                    "timestamp": 12345678,
                    "progress": {
                        "track_progress": 12000,
                        "track_duration": 180000,
                        "playback_speed": 1000
                    }
                }
            }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(ServerStateMessage.self, from: data)

        let metadata = try #require(message.payload.metadata)
        let progress = try #require(metadata.progress.merge(previous: nil))
        #expect(progress.trackProgress == 12_000)
        #expect(progress.trackDuration == 180_000)
        #expect(progress.playbackSpeed == 1_000)
    }

    @Test
    func serverState_rejectsIncompleteMetadataProgress() throws {
        let json = """
        {
            "type": "server/state",
            "payload": {
                "metadata": {
                    "timestamp": 12345678,
                    "progress": {
                        "track_progress": 12000
                    }
                }
            }
        }
        """
        let data = try #require(json.data(using: .utf8))

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ServerStateMessage.self, from: data)
        }
    }

    @Test
    func serverState_decodesControllerRepeatAndShuffle() throws {
        // Per spec, repeat/shuffle live on the controller object, not metadata.
        let json = """
        {
            "type": "server/state",
            "payload": {
                "controller": {
                    "supported_commands": ["repeat_all", "shuffle"],
                    "volume": 50, "muted": false,
                    "repeat": "all", "shuffle": true
                }
            }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(ServerStateMessage.self, from: data)

        let controller = try #require(message.payload.controller)
        #expect(controller.repeat == .all)
        #expect(controller.shuffle == true)
    }

    @Test
    func serverState_decodesControllerSeekCommands() throws {
        let json = """
        {
            "type": "server/state",
            "payload": {
                "controller": {
                    "supported_commands": [
                        "play", "volume", "pause", "unshuffle", "repeat_one",
                        "seek_relative", "repeat_off", "previous", "stop", "switch",
                        "seek", "next", "shuffle", "repeat_all", "mute"
                    ],
                    "volume": 100,
                    "muted": false,
                    "repeat": "off",
                    "shuffle": false,
                    "seek_max_ms": 312000
                }
            }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(ServerStateMessage.self, from: data)

        let controller = try #require(message.payload.controller)
        #expect(controller.supportedCommands?.contains(.play) == true)
        #expect(controller.supportedCommands?.contains(.pause) == true)
        #expect(controller.supportedCommands?.contains(.previous) == true)
        #expect(controller.supportedCommands?.contains(.next) == true)
        #expect(controller.supportedCommands?.contains(.seekRelative) == true)
        #expect(controller.supportedCommands?.contains(.seek) == true)
        #expect(controller.seekMaxMs == 312_000)
    }

    @Test
    func serverState_decodesControllerClearedSeekRange() throws {
        let json = """
        {
            "type": "server/state",
            "payload": {
                "controller": {
                    "seek_max_ms": null
                }
            }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let message = try JSONDecoder().decode(ServerStateMessage.self, from: data)

        let controller = try #require(message.payload.controller)
        #expect(controller.seekMaxMsDelta == .null)
        #expect(controller.seekMaxMs == nil)
    }

    @Test
    func clientCommand_encodesSeekParameters() throws {
        let encoder = JSONEncoder()

        let seekMessage = ClientCommandMessage(payload: ClientCommandPayload(controller: ControllerCommand(
            command: .seek,
            positionMs: 123_456
        )))
        let seekData = try encoder.encode(seekMessage)
        let seekJson = try #require(String(data: seekData, encoding: .utf8))
        #expect(seekJson.contains("\"command\":\"seek\""))
        #expect(seekJson.contains("\"position_ms\":123456"))
        #expect(!seekJson.contains("offset_ms"))

        let relativeMessage = ClientCommandMessage(payload: ClientCommandPayload(controller: ControllerCommand(
            command: .seekRelative,
            offsetMs: -15_000
        )))
        let relativeData = try encoder.encode(relativeMessage)
        let relativeJson = try #require(String(data: relativeData, encoding: .utf8))
        #expect(relativeJson.contains("\"command\":\"seek_relative\""))
        #expect(relativeJson.contains("\"offset_ms\":-15000"))
        #expect(!relativeJson.contains("position_ms"))
    }

    // MARK: - Forward compatibility

    @Test
    func handshakeAndStreamMessages_ignoreUnrecognizedPayloadFields() throws {
        let decoder = JSONDecoder()

        let activateJSON = """
        {
            "type": "server/activate",
            "payload": {
                "activities": [],
                "active_roles": [],
                "pairing": null,
                "future_activate_field": true
            }
        }
        """
        let activateData = try #require(activateJSON.data(using: .utf8))
        let activate = try decoder.decode(ServerActivateMessage.self, from: activateData)
        #expect(activate.payload.activities.isEmpty)
        #expect(activate.payload.activeRoles?.isEmpty == true)

        let noiseJSON = """
        {
            "type": "noise/handshake",
            "payload": {
                "data": "AQ",
                "future_noise_field": "ignored"
            }
        }
        """
        let noiseData = try #require(noiseJSON.data(using: .utf8))
        let noise = try decoder.decode(NoiseHandshakeMessage.self, from: noiseData)
        #expect(noise.payload.data == "AQ")

        let managementJSON = """
        {
            "type": "management/set-pairing-config",
            "payload": {
                "pairing_psk": {"enabled": true},
                "static_pairing_code": null,
                "dynamic_pairing_code": null,
                "record_mode": null,
                "unpaired_access": null,
                "future_management_field": false
            }
        }
        """
        let managementData = try #require(managementJSON.data(using: .utf8))
        let management = try decoder.decode(ManagementSetPairingConfigMessage.self, from: managementData)
        #expect(management.payload.pairingPsk?.enabled == true)

        let serverHelloJSON = """
        {
            "type": "server/hello",
            "payload": {
                "server_id": "test-server",
                "name": "Test Server",
                "version": 1,
                "active_roles": ["player@v1"],
                "connection_reason": "discovery",
                "future_top_level": {"nested": true}
            }
        }
        """
        let serverHelloData = try #require(serverHelloJSON.data(using: .utf8))
        let serverHello = try decoder.decode(ServerHelloMessage.self, from: serverHelloData)
        #expect(serverHello.payload.name == "Test Server")

        let serverTimeJSON = """
        {
            "type": "server/time",
            "payload": {
                "client_transmitted": 100,
                "server_received": 200,
                "server_transmitted": 300,
                "server_clock_quality": "future-value"
            }
        }
        """
        let serverTimeData = try #require(serverTimeJSON.data(using: .utf8))
        let serverTime = try decoder.decode(ServerTimeMessage.self, from: serverTimeData)
        #expect(serverTime.payload.clientTransmitted == 100)
        #expect(serverTime.payload.serverReceived == 200)
        #expect(serverTime.payload.serverTransmitted == 300)

        let streamStartJSON = """
        {
            "type": "stream/start",
            "payload": {
                "player": {
                    "codec": "opus",
                    "sample_rate": 48000,
                    "channels": 2,
                    "bit_depth": 16,
                    "codec_header": "AQIDBA==",
                    "future_player_field": [1, 2, 3]
                },
                "future_payload_field": "ignored"
            }
        }
        """
        let streamStartData = try #require(streamStartJSON.data(using: .utf8))
        let streamStart = try decoder.decode(StreamStartMessage.self, from: streamStartData)
        let player = try #require(streamStart.payload.player)
        #expect(player.codec == "opus")
        #expect(player.sampleRate == 48_000)
        #expect(player.channels == 2)
        #expect(player.bitDepth == 16)
        #expect(player.codecHeader == "AQIDBA==")
    }

    @Test
    func stateCommandAndGroupMessages_ignoreUnrecognizedPayloadFields() throws {
        let decoder = JSONDecoder()

        let serverStateJSON = """
        {
            "type": "server/state",
            "payload": {
                "metadata": {
                    "timestamp": 12345678,
                    "title": "New Song",
                    "progress": {
                        "track_progress": 12000,
                        "track_duration": 180000,
                        "playback_speed": 1000,
                        "future_progress_field": true
                    },
                    "future_metadata_field": null
                },
                "controller": {
                    "volume": 50,
                    "future_controller_field": {"mode": "later"}
                },
                "future_state_field": "ignored"
            }
        }
        """
        let serverStateData = try #require(serverStateJSON.data(using: .utf8))
        let serverState = try decoder.decode(ServerStateMessage.self, from: serverStateData)
        let metadata = try #require(serverState.payload.metadata)
        let progress = try #require(metadata.progress.merge(previous: nil))
        #expect(metadata.title.merge(previous: nil) == "New Song")
        #expect(progress.trackProgress == 12_000)
        #expect(progress.trackDuration == 180_000)
        #expect(progress.playbackSpeed == 1_000)
        #expect(serverState.payload.controller?.volume == 50)

        let serverCommandJSON = """
        {
            "type": "server/command",
            "payload": {
                "player": {
                    "command": "set_static_delay",
                    "static_delay_ms": 250,
                    "future_command_field": "ignored"
                },
                "future_payload_field": "ignored"
            }
        }
        """
        let serverCommandData = try #require(serverCommandJSON.data(using: .utf8))
        let serverCommand = try decoder.decode(ServerCommandMessage.self, from: serverCommandData)
        #expect(serverCommand.payload.player?.command == .setOutputDelay)
        #expect(serverCommand.payload.player?.outputDelayMs == 250)

        let groupUpdateJSON = """
        {
            "type": "group/update",
            "payload": {
                "playback_state": "playing",
                "group_id": "group-1",
                "group_name": "Kitchen",
                "future_group_field": 42
            }
        }
        """
        let groupUpdateData = try #require(groupUpdateJSON.data(using: .utf8))
        let groupUpdate = try decoder.decode(GroupUpdateMessage.self, from: groupUpdateData)
        #expect(groupUpdate.payload.playbackState == .playing)
        #expect(groupUpdate.payload.groupId == "group-1")
        #expect(groupUpdate.payload.groupName == "Kitchen")
    }

    @Test
    func inboundMessages_rejectUnrecognizedValues() throws {
        let json = """
        {
            "type": "group/update",
            "payload": {
                "playback_state": "paused"
            }
        }
        """
        let data = try #require(json.data(using: .utf8))

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(GroupUpdateMessage.self, from: data)
        }
    }
}
