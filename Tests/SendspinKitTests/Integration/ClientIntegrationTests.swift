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
func serverHelloJSON(
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

/// Encode a `server/state` message carrying only a controller object.
private func serverStateControllerJSON(_ controller: ServerControllerState) throws -> String {
    let message = ServerStateMessage(payload: ServerStatePayload(controller: controller))
    let data = try JSONEncoder().encode(message)
    return String(bytes: data, encoding: .utf8) ?? ""
}

/// Create a SendspinClient configured for testing with both player and controller roles.
@MainActor
func makeTestClient(
    roles: Set<VersionedRole> = [.playerV1, .controllerV1],
    persistenceProvider: (any SendspinPersistenceProvider)? = nil
) throws -> SendspinClient {
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
        playerConfig: playerConfig,
        persistenceProvider: persistenceProvider
    )
}

/// In-memory ``SendspinPersistenceProvider`` for tests. Records every saved
/// `server_id` and serves a preloaded value back from `load`.
private actor MockPersistenceProvider: SendspinPersistenceProvider {
    private(set) var savedServerIds: [String] = []
    private var storedServerId: String?

    init(stored storedServerId: String? = nil) {
        self.storedServerId = storedServerId
    }

    func loadLastPlayedServerId() async -> String? {
        storedServerId
    }

    func saveLastPlayedServerId(_ serverId: String) async {
        savedServerIds.append(serverId)
        storedServerId = serverId
    }
}

/// Poll `condition` until it returns `true` or the deadline passes.
/// Returns the final evaluation so callers can assert positively or negatively.
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
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
func connectClient(
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
func waitForState(
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

/// Drive a competing connection to completion: start `acceptConnection` and,
/// concurrently, inject the new server's `server/hello` (which `performHandshake`
/// blocks on). Returns the new mock once `acceptConnection` resolves.
@MainActor
private func acceptCompeting(
    _ client: SendspinClient,
    serverId: String,
    connectionReason: ConnectionReason,
    activeRoles: [VersionedRole] = [.playerV1, .controllerV1]
) async throws -> MockTransport {
    let mock = MockTransport()
    async let accepted: Void = client.acceptConnection(mock)
    try await mock.injectText(serverHelloJSON(
        serverId: serverId,
        activeRoles: activeRoles,
        connectionReason: connectionReason
    ))
    try await accepted
    return mock
}

/// Reasons from every `client/goodbye` the client sent on `mock`.
///
/// `ClientGoodbyeMessage`'s synthesized decoder overwrites its constant `type`
/// from the JSON, so other message types decode "successfully" — filter on the
/// decoded `type` to keep only real goodbyes.
private func sentGoodbyeReasons(from mock: MockTransport) async -> [GoodbyeReason] {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let messages = await mock.sentTextMessages
    return messages
        .compactMap { try? decoder.decode(ClientGoodbyeMessage.self, from: $0) }
        .filter { $0.type == "client/goodbye" }
        .compactMap { $0.payload?.reason }
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
    // MARK: Rollback on external source failure

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

    // MARK: streamCleared event

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

    // MARK: lastPlayedServerChanged event

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

    @Test
    func groupUpdate_withPlayingSavesServerIdToProvider() async throws {
        let provider = MockPersistenceProvider()
        let client = try makeTestClient(persistenceProvider: provider)
        let mock = try await connectClient(client)

        try await mock.injectText(groupUpdateJSON(
            groupId: "group-1",
            groupName: "Living Room",
            playbackState: .playing
        ))

        let saved = await waitUntil { await provider.savedServerIds == [testServerId] }
        #expect(saved, "Expected the provider to persist the last-played server_id")

        await client.disconnect()
    }

    @Test
    func groupUpdate_withStoppedDoesNotSaveServerId() async throws {
        let provider = MockPersistenceProvider()
        let client = try makeTestClient(persistenceProvider: provider)
        let mock = try await connectClient(client)

        try await mock.injectText(groupUpdateJSON(
            groupId: "group-1",
            groupName: "Living Room",
            playbackState: .stopped
        ))

        // Negative assertion: give the message time to be processed, then confirm
        // nothing was persisted. A non-playing update must not touch storage.
        let savedSomething = await waitUntil(timeout: .milliseconds(200)) {
            await !provider.savedServerIds.isEmpty
        }
        #expect(!savedSomething, "Stopped playback must not persist a last-played server")

        await client.disconnect()
    }

    // MARK: Multi-server arbitration (handshake-first)

    @Test
    func competingPlayback_overExistingDiscovery_switches() async throws {
        let client = try makeTestClient()
        let mock1 = try await connectClient(client, connectionReason: .discovery)
        let newServerId = "server-2"

        let mock2 = try await acceptCompeting(client, serverId: newServerId, connectionReason: .playback)

        #expect(client.currentServerId == newServerId)
        #expect(client.connectionState == .connected)
        // Left the old server with `another_server`, and dropped it.
        let oldGoodbyes = await sentGoodbyeReasons(from: mock1)
        let oldDisconnected = await mock1.disconnectCalled
        let newDisconnected = await mock2.disconnectCalled
        #expect(oldGoodbyes == [.anotherServer])
        #expect(oldDisconnected)
        #expect(!newDisconnected)

        await client.disconnect()
    }

    @Test
    func competingDiscovery_underExistingPlayback_keepsExisting() async throws {
        let client = try makeTestClient()
        let mock1 = try await connectClient(client, connectionReason: .playback)

        let mock2 = try await acceptCompeting(client, serverId: "server-2", connectionReason: .discovery)

        #expect(client.currentServerId == testServerId)
        #expect(client.connectionState == .connected)
        // The losing (new) server is told `another_server` and dropped; old untouched.
        let newGoodbyes = await sentGoodbyeReasons(from: mock2)
        let newDisconnected = await mock2.disconnectCalled
        let oldDisconnected = await mock1.disconnectCalled
        #expect(newGoodbyes == [.anotherServer])
        #expect(newDisconnected)
        #expect(!oldDisconnected)

        await client.disconnect()
    }

    @Test
    func competingDiscovery_bothDiscoveryLastPlayedIsNew_switches() async throws {
        let newServerId = "server-2"
        let provider = MockPersistenceProvider(stored: newServerId)
        let client = try makeTestClient(persistenceProvider: provider)
        let mock1 = try await connectClient(client, connectionReason: .discovery)

        _ = try await acceptCompeting(client, serverId: newServerId, connectionReason: .discovery)

        #expect(client.currentServerId == newServerId)
        #expect(await mock1.disconnectCalled)

        await client.disconnect()
    }

    @Test
    func competingDiscovery_bothDiscoveryNoLastPlayed_keepsExisting() async throws {
        let client = try makeTestClient()
        let mock1 = try await connectClient(client, connectionReason: .discovery)

        let mock2 = try await acceptCompeting(client, serverId: "server-2", connectionReason: .discovery)

        let newDisconnected = await mock2.disconnectCalled
        let oldDisconnected = await mock1.disconnectCalled
        #expect(client.currentServerId == testServerId)
        #expect(newDisconnected)
        #expect(!oldDisconnected)

        await client.disconnect()
    }

    /// A new server whose handshake never completes must not disturb the existing
    /// connection. Closing the new transport's streams makes `performHandshake`
    /// fail fast (no 5 s timeout wait).
    @Test
    func competingConnection_handshakeNeverCompletes_keepsExisting() async throws {
        let client = try makeTestClient()
        let mock1 = try await connectClient(client, connectionReason: .discovery)

        let mock2 = MockTransport()
        async let accepted: Void = client.acceptConnection(mock2)
        try await mock2.finishStreams() // never sends server/hello
        try await accepted

        let oldDisconnected = await mock1.disconnectCalled
        let newDisconnected = await mock2.disconnectCalled
        #expect(client.currentServerId == testServerId)
        #expect(client.connectionState == .connected)
        #expect(!oldDisconnected)
        #expect(newDisconnected)

        await client.disconnect()
    }

    /// On a switch, frames the new server sent immediately after `server/hello`
    /// must still be processed once the message loop resumes the (already-read)
    /// stream. Guards the sequential-iterator handoff in `performHandshake`.
    @Test
    func competingSwitch_processesFramesBufferedAfterHello() async throws {
        let client = try makeTestClient()
        _ = try await connectClient(client, connectionReason: .discovery)
        let newServerId = "server-2"

        let mock2 = MockTransport()
        async let accepted: Void = client.acceptConnection(mock2)
        try await mock2.injectText(serverHelloJSON(serverId: newServerId, connectionReason: .playback))
        try await mock2.injectText(groupUpdateJSON(
            groupId: "group-2",
            groupName: "Kitchen",
            playbackState: .playing
        ))
        try await accepted

        let sawPlaying = await waitUntil {
            let state = await MainActor.run { client.currentGroup?.playbackState }
            return state == .playing
        }
        #expect(sawPlaying, "Frame buffered after server/hello must be handled once the loop resumes")
        #expect(client.currentServerId == newServerId)

        await client.disconnect()
    }

    // MARK: setRepeatMode and setShuffle wire format

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

    // MARK: server-initiated controller repeat/shuffle

    @Test
    func serverState_controllerRepeatShuffle_surfacesAndMergesOnPublicState() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        try await mock.injectText(serverStateControllerJSON(ServerControllerState(
            supportedCommands: [.repeatAll, .shuffle], volume: 50, muted: false,
            repeat: .all, shuffle: true
        )))

        let sawValues = await waitUntil {
            let state = await MainActor.run { client.currentControllerState }
            return state?.repeatMode == .all && state?.shuffle == true
        }
        #expect(sawValues, "Controller repeat/shuffle must surface on the public state")

        // A later delta that omits repeat/shuffle must preserve the prior values.
        try await mock.injectText(serverStateControllerJSON(ServerControllerState(volume: 60)))

        let preserved = await waitUntil {
            let state = await MainActor.run { client.currentControllerState }
            return state?.volume == 60 && state?.repeatMode == .all && state?.shuffle == true
        }
        #expect(preserved, "Absent repeat/shuffle in a delta must keep previous values")

        await client.disconnect()
    }

    // MARK: sendFailed wrapping

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

    // MARK: activeRoles populated from server/hello

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

    // MARK: connect throws alreadyConnected

    @Test
    func connect_throwsAlreadyConnectedWhenConnected() async throws {
        let client = try makeTestClient()
        _ = try await connectClient(client)

        await #expect(throws: SendspinClientError.alreadyConnected) {
            try await client.connect(to: #require(URL(string: "ws://localhost:9999")))
        }

        await client.disconnect()
    }

    // MARK: set_static_delay server command drives state and notifies the host

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

    // MARK: set_static_delay clamps out-of-range server input to the spec maximum

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

    // MARK: default disconnect sends restart so the server keeps auto-reconnect

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

    // MARK: underrun-driven operational state reporting is guarded

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
