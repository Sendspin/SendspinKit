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

/// Create a SendspinClient configured for testing with both player and controller roles.
@MainActor
private func makeTestClient(roles: Set<VersionedRole> = [.playerV1, .controllerV1]) -> SendspinClient {
    var playerConfig: PlayerConfiguration?
    if roles.contains(.playerV1) {
        playerConfig = PlayerConfiguration(
            bufferCapacity: 1_024,
            supportedFormats: [
                AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
            ]
        )
    }

    return SendspinClient(
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
/// `performInitialSync` sends 5 clock sync rounds with 100ms sleeps (~500ms total).
/// We don't inject server/time responses, so `isClockSynced` stays false, but
/// `connectionState` becomes `.connected` immediately after server/hello is processed
/// (well before initial sync finishes). The 3s timeout accommodates CI scheduling jitter.
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

// MARK: - Tests

@MainActor
struct ClientIntegrationTests {
    // MARK: 1. Rollback on external source failure

    @Test
    func `enter external source rolls back on send failure`() async throws {
        let client = makeTestClient()
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
    func `stream clear injects stream cleared event`() async throws {
        let client = makeTestClient()
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
        #expect(event == .streamCleared)

        await client.disconnect()
    }

    // MARK: 3. lastPlayedServerChanged event

    @Test
    func `group update with playing emits last played server changed`() async throws {
        let client = makeTestClient()
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
    func `set repeat mode one sends correct command`() async throws {
        let client = makeTestClient()
        let mock = try await connectClient(client)

        let countBefore = await mock.sentTextMessages.count

        try await client.setRepeatMode(.one)

        let command = try await lastSentCommand(from: mock, after: countBefore)
        let sent = try #require(command, "Expected a ClientCommandMessage after setRepeatMode(.one)")
        #expect(sent.payload.controller?.command == .repeatOne)

        await client.disconnect()
    }

    @Test
    func `set shuffle true sends shuffle command`() async throws {
        let client = makeTestClient()
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
    func `play throws send failed when transport fails`() async throws {
        let client = makeTestClient()
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
    func `server hello populates active roles`() async throws {
        let client = makeTestClient()
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

    // MARK: 7. connect throws alreadyConnected

    @Test
    func `connect throws already connected when connected`() async throws {
        let client = makeTestClient()
        _ = try await connectClient(client)

        await #expect(throws: SendspinClientError.alreadyConnected) {
            try await client.connect(to: #require(URL(string: "ws://localhost:9999")))
        }

        await client.disconnect()
    }
}
