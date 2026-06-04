// ABOUTME: Integration tests for SendspinClient using MockTransport
// ABOUTME: Tests message handling, error wrapping, state transitions, and wire format

import Foundation
@testable import SendspinKit
import Testing

// MARK: - Constants

/// Default server ID used by test helpers. Shared between `serverHelloJSON`
/// (which sets it on the mock server) and test assertions (which verify events
/// carry this ID). Using a constant ensures the two stay in sync.
private let testServerId = "test-server"

// MARK: - Test helpers

/// Encode a server/hello message using the actual Codable types.
private func serverHelloJSON(
    serverId: String = testServerId,
    name: String = "Test Server",
    version: Int = 1,
    activeRoles: [VersionedRole] = [.playerV1, .controllerV1],
    connectionReason: ConnectionReason = .discovery
) throws -> String {
    let message = ServerHelloMessage(
        payload: ServerHelloPayload(
            serverId: serverId,
            name: name,
            version: version,
            activeRoles: activeRoles,
            connectionReason: connectionReason
        )
    )
    let data = try JSONEncoder().encode(message)
    return String(bytes: data, encoding: .utf8) ?? ""
}

/// Encode a stream/clear message using the actual Codable types.
private func streamClearJSON() throws -> String {
    let message = StreamClearMessage(payload: StreamClearPayload())
    let data = try JSONEncoder().encode(message)
    return String(bytes: data, encoding: .utf8) ?? ""
}

/// Encode a group/update message using the actual Codable types.
///
/// `GroupUpdatePayload` uses custom `CodingKeys` that already produce snake_case
/// wire names, so no `.convertToSnakeCase` strategy is needed.
private func groupUpdateJSON(
    groupId: String? = nil,
    groupName: String? = nil,
    playbackState: PlaybackState? = nil
) throws -> String {
    let message = GroupUpdateMessage(
        payload: GroupUpdatePayload(
            playbackState: playbackState,
            groupId: groupId,
            groupName: groupName
        )
    )
    let data = try JSONEncoder().encode(message)
    return String(bytes: data, encoding: .utf8) ?? ""
}

/// Encode a `server/command` `set_static_delay` message using the actual Codable types.
private func setStaticDelayCommandJSON(_ delayMs: Int) throws -> String {
    let message = ServerCommandMessage(
        payload: ServerCommandPayload(
            player: PlayerCommandObject(command: .setStaticDelay, staticDelayMs: delayMs)
        )
    )
    let data = try JSONEncoder().encode(message)
    return String(bytes: data, encoding: .utf8) ?? ""
}

/// Create a SendspinClient configured for testing with both player and controller roles.
@MainActor
private func makeTestClient(roles: Set<VersionedRole> = [.playerV1, .controllerV1]) throws -> SendspinClient {
    var playerConfig: PlayerConfiguration?
    if roles.contains(.playerV1) {
        playerConfig = try PlayerConfiguration(
            bufferCapacity: 1_024,
            supportedFormats: [
                AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
            ]
        )
    }

    return try SendspinClient(
        clientId: "test-client",
        name: "Test Client",
        roles: roles,
        playerConfig: playerConfig
    )
}

/// Accept a mock transport connection and wait for the handshake to complete.
///
/// Injects a server/hello after the transport is accepted, then waits for
/// `connectionState == .connected`. Returns the mock transport for further interaction.
///
/// `runClockSync` fires its first two client/time samples 10 ms apart, then
/// settles into a 1 s cadence. We don't inject server/time responses here, so
/// `isClockSynced` stays false, but `connectionState` becomes `.connected`
/// immediately after server/hello is processed (the sync task is spawned
/// detached; `handleServerHello` doesn't await it). The 3s timeout accommodates
/// CI scheduling jitter.
@MainActor
private func connectClient(
    _ client: SendspinClient,
    activeRoles: [VersionedRole] = [.playerV1, .controllerV1],
    connectionReason: ConnectionReason = .discovery
) async throws -> MockTransport {
    let mock = MockTransport()
    try await client.acceptConnection(mock)

    try await mock.injectText(serverHelloJSON(
        activeRoles: activeRoles,
        connectionReason: connectionReason
    ))

    // Poll until the client processes server/hello and reaches .connected.
    // We can't use the events stream here because it's single-consumer and
    // tests may need it for their own assertions.
    try await waitForState(client, expected: .connected, timeout: .seconds(3))

    return mock
}

/// Poll until the client reaches the expected connection state.
@MainActor
private func waitForState(
    _ client: SendspinClient,
    expected: ConnectionState,
    timeout: Duration
) async throws {
    let deadline = ContinuousClock.now + timeout
    while client.connectionState != expected {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for connectionState == \(expected), got \(client.connectionState)")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Collect the first event matching a predicate from a client's event stream, or nil on timeout.
///
/// AsyncStream uses unbounded buffering by default, so events yielded before
/// iteration begins are retained — no sleep-based synchronization needed.
@MainActor
private func collectEvent(
    from client: SendspinClient,
    timeout: Duration = .seconds(3),
    where predicate: @Sendable @escaping (ClientEvent) -> Bool
) async -> ClientEvent? {
    let stream = client.events
    return await withTaskGroup(of: ClientEvent?.self) { group in
        group.addTask {
            for await event in stream where predicate(event) {
                return event
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        // Take the first completed result. If it's non-nil (a match), return it.
        // If it's nil (timeout fired first), cancel the event-listening task
        // to prevent it from hanging on an infinite stream, then return nil.
        for await result in group {
            group.cancelAll()
            return result
        }
        return nil
    }
}

/// Decode the last `ClientCommandMessage` from the mock's sent messages.
///
/// The mock encodes with `.convertToSnakeCase` (via `SendspinEncoding`),
/// so we must decode with `.convertFromSnakeCase` to round-trip correctly.
private func lastSentCommand(from mock: MockTransport, after offset: Int) async throws -> ClientCommandMessage? {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let messages = await mock.sentTextMessages
    return messages.dropFirst(offset).compactMap { data in
        try? decoder.decode(ClientCommandMessage.self, from: data)
    }.last
}

/// Decode the last `ClientStateMessage` payload sent after `offset`.
///
/// Uses a plain decoder (no snake-case conversion) because the nested
/// `PlayerStateObject` defines explicit snake_case `CodingKeys`.
private func lastClientState(from mock: MockTransport, after offset: Int) async -> ClientStatePayload? {
    let messages = await mock.sentTextMessages
    return messages.dropFirst(offset).compactMap { data in
        try? JSONDecoder().decode(ClientStateMessage.self, from: data)
    }.last?.payload
}

// MARK: - Tests

@MainActor
struct ClientIntegrationTests {
    // MARK: 1. Rollback on external source failure

    @Test
    func enterExternalSource_rollsBackOnSendFailure() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        await mock.setShouldFailOnSend(true)

        await #expect(throws: SendspinClientError.self) {
            try await client.enterExternalSource()
        }

        #expect(client.clientOperationalState == .synchronized)

        await client.disconnect()
    }

    // MARK: 2. streamCleared event

    @Test
    func streamClear_injectsStreamClearedEvent() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        // Start collecting events — AsyncStream buffers, so no sleep needed
        let eventTask = Task {
            await collectEvent(from: client) { event in
                if case .streamCleared = event { return true }
                return false
            }
        }

        try await mock.injectText(streamClearJSON())

        let event = await eventTask.value
        #expect(event == .streamCleared(roles: nil))

        await client.disconnect()
    }

    // MARK: 3. lastPlayedServerChanged event

    @Test
    func groupUpdate_withPlayingEmitsLastPlayedServerChanged() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        let eventTask = Task {
            await collectEvent(from: client) { event in
                if case .lastPlayedServerChanged = event { return true }
                return false
            }
        }

        try await mock.injectText(groupUpdateJSON(
            groupId: "group-1",
            groupName: "Living Room",
            playbackState: .playing
        ))

        let event = await eventTask.value
        #expect(event == .lastPlayedServerChanged(serverId: testServerId))

        await client.disconnect()
    }

    // MARK: 4. setRepeatMode and setShuffle wire format

    @Test
    func setRepeatMode_oneSendsCorrectCommand() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        let countBefore = await mock.sentTextMessages.count

        try await client.setRepeatMode(.one)

        let command = try await lastSentCommand(from: mock, after: countBefore)
        let sent = try #require(command, "Expected a ClientCommandMessage after setRepeatMode(.one)")
        #expect(sent.payload.controller?.command == .repeatOne)

        await client.disconnect()
    }

    @Test
    func setShuffle_trueSendsShuffleCommand() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        let countBefore = await mock.sentTextMessages.count

        try await client.setShuffle(true)

        let command = try await lastSentCommand(from: mock, after: countBefore)
        let sent = try #require(command, "Expected a ClientCommandMessage after setShuffle(true)")
        #expect(sent.payload.controller?.command == .shuffle)

        await client.disconnect()
    }

    // MARK: 5. sendFailed wrapping

    @Test
    func play_throwsSendFailedWhenTransportFails() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        await mock.setShouldFailOnSend(true)

        let error = try await #require(throws: SendspinClientError.self) {
            try await client.play()
        }
        guard case .sendFailed = error else {
            Issue.record("Expected .sendFailed, got \(error)")
            return
        }

        await client.disconnect()
    }

    // MARK: 6. activeRoles populated from server/hello

    @Test
    func serverHello_populatesActiveRoles() async throws {
        let client = try makeTestClient()
        let mock = MockTransport()

        // Start collecting events before accepting the connection
        let eventTask = Task {
            await collectEvent(from: client, timeout: .seconds(5)) { event in
                if case .serverConnected = event { return true }
                return false
            }
        }

        try await client.acceptConnection(mock)
        try await mock.injectText(serverHelloJSON(
            activeRoles: [.playerV1, .controllerV1]
        ))

        let event = await eventTask.value
        let info = try #require(
            event.flatMap { if case let .serverConnected(i) = $0 { i } else { nil } },
            "Expected .serverConnected event"
        )

        #expect(info.activeRoles.contains(.playerV1))
        #expect(info.activeRoles.contains(.controllerV1))
        #expect(info.hasRole(.playerV1) == true)
        #expect(info.hasRole(.controllerV1) == true)
        #expect(info.hasRole(.artworkV1) == false)

        await client.disconnect()
    }

    // MARK: 7. rawAudioChunk emitted for chunks arriving before stream/start

    @Test
    func rawAudioChunks_emittedEvenWhenArrivingBeforeStreamStart() async throws {
        // Regression test: binary and text messages are consumed by parallel tasks
        // in the message loop. If the binary task processes audio chunks before the
        // text task processes stream/start, shouldEmitRawAudio must already be true
        // (set at connection setup, not deferred to handleStreamStart).
        let client = try SendspinClient(
            clientId: "test-client",
            name: "Test Client",
            roles: [.playerV1],
            playerConfig: PlayerConfiguration(
                bufferCapacity: 1_024,
                supportedFormats: [
                    AudioFormatSpec(codec: .pcm, channels: 1, sampleRate: 8_000, bitDepth: 16)
                ],
                emitRawAudioEvents: true
            )
        )

        let mock = MockTransport()
        try await client.acceptConnection(mock)

        // Inject server/hello so the client reaches .connected state
        try await mock.injectText(serverHelloJSON())
        try await waitForState(client, expected: .connected, timeout: .seconds(3))

        // Inject binary audio chunks BEFORE stream/start text message.
        // This reproduces the race: the binary task may process these before
        // the text task gets to stream/start.
        let pcmSamples = Data(repeating: 0x7F, count: 400) // 200 samples × 16-bit
        let timestamp: Int64 = 1_000_000
        let chunkCount = 3
        for i in 0 ..< chunkCount {
            var frame = Data()
            frame.append(BinaryMessageType.audioChunk.rawValue)
            var ts = (timestamp + Int64(i) * 25_000).bigEndian
            frame.append(Data(bytes: &ts, count: 8))
            frame.append(pcmSamples)
            await mock.injectBinary(frame)
        }

        // Now inject stream/start — this is when handleStreamStart runs, but
        // the audio chunks above may already have been processed by then.
        let streamStart = StreamStartMessage(
            payload: StreamStartPayload(
                player: StreamStartPlayer(
                    codec: "pcm",
                    sampleRate: 8_000,
                    channels: 1,
                    bitDepth: 16,
                    codecHeader: nil
                ),
                artwork: nil,
                visualizer: nil
            )
        )
        let streamStartData = try JSONEncoder().encode(streamStart)
        let streamStartJSON = try #require(String(data: streamStartData, encoding: .utf8))
        await mock.injectText(streamStartJSON)

        // Collect rawAudioChunk events
        let stream = client.events
        let collected = await withTaskGroup(of: Int.self) { group in
            group.addTask {
                var count = 0
                for await event in stream {
                    if case .rawAudioChunk = event {
                        count += 1
                    }
                    // Stop after we've seen stream start + all chunks, or timeout
                    if count >= chunkCount { break }
                }
                return count
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return -1 // sentinel for timeout
            }
            for await result in group {
                group.cancelAll()
                return result
            }
            return 0
        }

        #expect(collected == chunkCount, "Expected \(chunkCount) rawAudioChunk events but got \(collected)")

        await client.disconnect()
    }

    // MARK: 8. connect throws alreadyConnected

    @Test
    func connect_throwsAlreadyConnectedWhenConnected() async throws {
        let client = try makeTestClient()
        _ = try await connectClient(client)

        await #expect(throws: SendspinClientError.alreadyConnected) {
            try await client.connect(to: #require(URL(string: "ws://localhost:9999")))
        }

        await client.disconnect()
    }

    // MARK: 9. set_static_delay server command drives state and notifies the host

    @Test
    func serverSetStaticDelay_updatesStateAndEmitsChangedEvent() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        let newDelayMs = 250
        let eventTask = Task {
            await collectEvent(from: client) { event in
                if case .staticDelayChanged = event { return true }
                return false
            }
        }

        try await mock.injectText(setStaticDelayCommandJSON(newDelayMs))

        let event = await eventTask.value
        #expect(event == .staticDelayChanged(milliseconds: newDelayMs))
        #expect(client.staticDelayMs == newDelayMs)

        await client.disconnect()
    }

    // MARK: 10. set_static_delay clamps out-of-range server input to the spec maximum

    @Test
    func serverSetStaticDelay_clampsAboveMaximumToSpecLimit() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        // Spec range is 0–5000; setStaticDelay clamps rather than trusting the server.
        let maxDelayMs = 5_000
        let eventTask = Task {
            await collectEvent(from: client) { event in
                if case .staticDelayChanged = event { return true }
                return false
            }
        }

        try await mock.injectText(setStaticDelayCommandJSON(maxDelayMs + 1_000))

        let event = await eventTask.value
        #expect(event == .staticDelayChanged(milliseconds: maxDelayMs))
        #expect(client.staticDelayMs == maxDelayMs)

        await client.disconnect()
    }

    // MARK: 11. default disconnect sends restart so the server keeps auto-reconnect

    @Test
    func disconnect_defaultReasonIsRestart() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        let countBefore = await mock.sentTextMessages.count
        await client.disconnect()

        let messages = await mock.sentTextMessages
        let goodbye = messages.dropFirst(countBefore).compactMap { data in
            try? JSONDecoder().decode(ClientGoodbyeMessage.self, from: data)
        }.last
        let sent = try #require(goodbye, "Expected a client/goodbye after disconnect()")
        #expect(sent.payload?.reason == .restart)
    }

    // MARK: 12. underrun-driven operational state reporting is guarded

    @Test
    func applyUnderrunTransition_toErrorFromSynchronizedReportsError() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        let countBefore = await mock.sentTextMessages.count
        await client.applyUnderrunTransition(.toError)

        #expect(client.clientOperationalState == .error)
        let payload = await lastClientState(from: mock, after: countBefore)
        #expect(payload?.state == .error)
    }

    @Test
    func applyUnderrunTransition_toSynchronizedRecoversFromError() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        await client.applyUnderrunTransition(.toError)
        #expect(client.clientOperationalState == .error)

        let countBefore = await mock.sentTextMessages.count
        await client.applyUnderrunTransition(.toSynchronized)

        #expect(client.clientOperationalState == .synchronized)
        let payload = await lastClientState(from: mock, after: countBefore)
        #expect(payload?.state == .synchronized)
    }

    @Test
    func applyUnderrunTransition_toErrorIsIgnoredDuringExternalSource() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        try await client.enterExternalSource()
        #expect(client.clientOperationalState == .externalSource)

        let countBefore = await mock.sentTextMessages.count
        await client.applyUnderrunTransition(.toError)

        // The guard must leave external-source untouched and send nothing.
        #expect(client.clientOperationalState == .externalSource)
        let sentAfter = await mock.sentTextMessages.count
        #expect(sentAfter == countBefore)
    }
}
