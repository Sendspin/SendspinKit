// swiftlint:disable file_length

import Foundation
@testable import SendspinKit
import Testing

// MARK: - Test helpers

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
    roles: [VersionedRole] = [.playerV1, .controllerV1],
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

/// Records the terminal outcome of an async operation for bounded observation.
private actor AsyncVoidOutcomeBox {
    private(set) var outcome: Result<Void, Error>?

    var hasOutcome: Bool {
        outcome != nil
    }

    func record(_ result: Result<Void, Error>) {
        outcome = result
    }
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

/// Drive a connected client to `isClockSynced == true`.
///
/// Injects two well-formed `server/time` responses whose `clientTransmitted`
/// is sampled from the client's own monotonic clock. The RTT gate sees
/// `clientReceived - clientTransmitted` (a sub-millisecond test latency), so
/// both samples are accepted; the filter reaches `isSynchronized` (count >= 2)
/// on the second, at which point `handleServerTime` flips `isClockSynced`.
///
/// Without this, `handleAudioChunk` drops every chunk before sync, so no
/// `.chunk` command ever reaches the engine.
@MainActor
func establishClockSync(
    _ client: SendspinClient,
    via mock: MockTransport,
    timeout: Duration = .seconds(3)
) async throws {
    // Inject fresh samples until sync establishes, not a fixed two-shot: each
    // sample's RTT is measured from its injection-time stamp to processing, and
    // under suite load that lag can exceed the synchronizer's 100ms RTT gate,
    // silently rejecting the sample. Re-stamping until two land keeps the
    // helper deterministic on a loaded machine.
    let deadline = ContinuousClock.now + timeout
    while !client.isClockSynced {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for isClockSynced; clock sync was not established")
            return
        }
        let now = client.getCurrentMicroseconds()
        try await mock.injectText(serverTimeJSON(
            clientTransmitted: now,
            serverReceived: now,
            serverTransmitted: now
        ))
        // Let the frame loop process this server/time before sampling the next.
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Wait until the client has applied a player stream format — i.e. the engine's
/// `.started` report has drained and set `currentStreamFormat`. A mid-stream
/// format change is only classified as a change (not a fresh start) once a prior
/// format is recorded, so tests must await this before injecting the new format.
@MainActor
func waitForStreamFormat(_ client: SendspinClient, timeout: Duration = .seconds(3)) async throws {
    let deadline = ContinuousClock.now + timeout
    while client.currentStreamFormat == nil {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for currentStreamFormat to be set")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Wait until the engine has applied the wire-terminal command and fully drained.
///
/// The client enqueues commands in wire (FIFO) order and the engine applies them
/// in the same order, so once `isDrained(appliedKinds)` holds AND the sink depth
/// is zero, every command the test injected has been applied — in order. Replaces
/// fixed sleeps, which flake when `AudioQueueNewOutput` is slow under suite load
/// and the drain falls behind the 500 ms window.
@MainActor
func waitForEngineDrain(
    _ engine: AudioEngine,
    timeout: Duration = .seconds(5),
    until isDrained: @Sendable ([DataPlaneCommandKind]) -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while true {
        let kinds = await engine.appliedCommandKinds()
        if engine.commands.depth == 0, isDrained(kinds) {
            return
        }
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for engine drain; depth=\(engine.commands.depth), kinds=\(kinds)")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
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
    await collectClientEvent(from: client.events(), timeout: timeout, where: predicate)
}

/// Decode the last `client/command` sent after `offset`.
///
/// The mock encodes with `.convertToSnakeCase` (via `SendspinEncoding`),
/// so we must decode with `.convertFromSnakeCase` to round-trip correctly.
///
/// Dispatches on `SendspinEncoding.messageType` — the same wire-tag read the client
/// uses to route inbound frames — so background `client/time` traffic (which decodes
/// "successfully" as an empty command) can't be mistaken for the real command.
private func lastSentCommand(from mock: MockTransport, after offset: Int) async throws -> ClientCommandMessage? {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let messages = await mock.sentTextMessages
    return messages.dropFirst(offset)
        .filter { SendspinEncoding.messageType(of: $0) == ClientCommandMessage.typeString }
        .compactMap { try? decoder.decode(ClientCommandMessage.self, from: $0) }
        .last
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

/// Reasons from every `client/goodbye` the client sent on `mock`, in send order.
private func sentGoodbyeReasons(from mock: MockTransport) async -> [GoodbyeReason] {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let messages = await mock.sentTextMessages
    return messages
        .filter { SendspinEncoding.messageType(of: $0) == ClientGoodbyeMessage.typeString }
        .compactMap { (try? decoder.decode(ClientGoodbyeMessage.self, from: $0))?.payload.reason }
}

/// Decode the last `client/state` payload sent after `offset`.
///
/// Uses a plain decoder (no snake-case conversion) because the nested
/// `PlayerStateObject` defines explicit snake_case `CodingKeys`.
private func clientStates(from mock: MockTransport, after offset: Int) async -> [ClientStatePayload] {
    let messages = await mock.sentTextMessages
    return messages.dropFirst(offset)
        .filter { SendspinEncoding.messageType(of: $0) == ClientStateMessage.typeString }
        .compactMap { try? JSONDecoder().decode(ClientStateMessage.self, from: $0).payload }
}

private func lastClientState(from mock: MockTransport, after offset: Int) async -> ClientStatePayload? {
    await clientStates(from: mock, after: offset).last
}

private func streamEndJSON(roles: [String]? = nil) throws -> String {
    let message = StreamEndMessage(payload: StreamEndPayload(roles: roles))
    return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
}

/// `stream/start` matching `makeTestClient`'s supported format (pcm 48k/2/16).
private func promotionStreamStartJSON() throws -> String {
    let message = StreamStartMessage(payload: StreamStartPayload(
        player: StreamStartPlayer(codec: "pcm", sampleRate: 48_000, channels: 2, bitDepth: 16, codecHeader: nil),
        artwork: nil,
        visualizer: nil
    ))
    return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
}

/// Timestamp for the `index`-th promotion-continuity chunk (shared by the frame
/// builder and the test's ordering assertion).
private func promotionChunkTimestamp(index: Int, baseTimestamp: Int64 = 1_000_000) -> Int64 {
    baseTimestamp + Int64(index) * 25_000
}

/// Binary audio frame (type byte + big-endian timestamp + PCM payload).
private func promotionAudioChunkFrame(index: Int) -> Data {
    var frame = Data()
    frame.append(BinaryMessageType.audioChunk.rawValue)
    var timestamp = promotionChunkTimestamp(index: index).bigEndian
    frame.append(Data(bytes: &timestamp, count: 8))
    frame.append(Data(repeating: 0x7F, count: 400))
    return frame
}

/// Build a `server/state` frame carrying a metadata `title` for ordering tests.
private func metadataStateJSON(title: String) throws -> String {
    let message = ServerStateMessage(payload: ServerStatePayload(
        metadata: ServerMetadataState(title: .value(title))
    ))
    return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
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
        #expect(
            await client.connection?.audioEngineForTesting.isParticipatingInPlaybackForTesting() == true,
            "failed enterExternalSource must not leave the engine suppressing playback telemetry"
        )

        await client.disconnect()
    }

    @Test
    func exitExternalSource_rollsBackEngineModeOnSendFailure() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        try await client.enterExternalSource()
        #expect(client.clientOperationalState == .externalSource)
        #expect(await client.connection?.audioEngineForTesting.isParticipatingInPlaybackForTesting() == false)

        await mock.setShouldFailOnSend(true)
        await #expect(throws: SendspinClientError.self) {
            try await client.exitExternalSource()
        }

        #expect(client.clientOperationalState == .externalSource)
        #expect(
            await client.connection?.audioEngineForTesting.isParticipatingInPlaybackForTesting() == false,
            "failed exitExternalSource must leave the engine in external-source mode"
        )

        await client.disconnect()
    }

    @Test
    func streamEndAfterExternalSourcePreservesExternalSourceState() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        try await client.enterExternalSource()
        #expect(client.clientOperationalState == .externalSource)

        let countBeforeStreamEnd = await mock.sentTextMessages.count
        try await mock.injectText(streamEndJSON())

        let sawStreamEnded = await collectEvent(from: client) {
            if case .streamEnded = $0 { true } else { false }
        }
        #expect(sawStreamEnded != nil, "stream/end should still surface while external_source is active")
        #expect(client.clientOperationalState == .externalSource, "stream/end must not exit external_source")

        let statesAfterStreamEnd = await clientStates(from: mock, after: countBeforeStreamEnd)
        #expect(
            !statesAfterStreamEnd.contains(where: { $0.state == .synchronized }),
            "server-mandated stream/end cleanup must not send a synchronized client/state while external_source is active"
        )

        await client.disconnect()
    }

    @Test
    func streamStartAfterExternalSourcePreservesExternalSourceState() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        try await client.enterExternalSource()
        #expect(client.clientOperationalState == .externalSource)

        let countBeforeStreamStart = await mock.sentTextMessages.count
        try await mock.injectText(promotionStreamStartJSON())

        #expect(await waitUntil(timeout: .seconds(2)) { await MainActor.run { client.playerStreamActive } })
        #expect(client.clientOperationalState == .externalSource, "stream/start must not exit external_source")

        let statesAfterStreamStart = await clientStates(from: mock, after: countBeforeStreamStart)
        #expect(
            !statesAfterStreamStart.contains(where: { $0.state == .synchronized }),
            "late stream/start must not send a synchronized client/state while external_source is active"
        )

        await client.disconnect()
    }

    // MARK: Control-stream depth drains via the facade

    @Test
    func eventsMethodMulticastsControlEventsToIndependentSubscribers() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)
        let streamA = client.events()
        let streamB = client.events()
        let expectedTitle = "multicast-control-event"
        let seenBy = AtomicList<String>()

        let taskA = Task {
            for await event in streamA {
                if case let .metadataReceived(metadata) = event, metadata.title == expectedTitle {
                    seenBy.append("A")
                    break
                }
            }
        }
        let taskB = Task {
            for await event in streamB {
                if case let .metadataReceived(metadata) = event, metadata.title == expectedTitle {
                    seenBy.append("B")
                    break
                }
            }
        }

        try await mock.injectText(metadataStateJSON(title: expectedTitle))

        #expect(
            await waitUntil(timeout: .seconds(1)) { seenBy.count == 2 },
            "both subscribers should receive the same metadata event; saw \(seenBy.all)"
        )
        #expect(Set(seenBy.all) == ["A", "B"])

        taskA.cancel()
        taskB.cancel()
        await client.disconnect()
    }

    @Test
    func controlEventDepthDrainsToZero() async throws {
        // The facade drain decrements the connection's control-event depth as it
        // consumes each event; a missing decrement leaves the counter stuck above
        // zero forever. Not vacuous: connectClient only returns .connected after
        // the drain has processed at least .serverConnected.
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        try await mock.injectText(metadataStateJSON(title: "depth-probe"))

        let connection = try #require(client.connection)
        #expect(
            await waitUntil { connection.controlSink.depth == 0 },
            "the facade drain must decrement control-event depth back to zero"
        )

        await client.disconnect()
    }

    // MARK: Deinit safety net

    @Test
    func droppingConnectedClientShutsDownConnection() async throws {
        // The last user reference going away must tear down the live connection
        // graph. Two coupled requirements: the facade drain must hold the client
        // weakly while parked (a strong capture is a self-retain cycle and deinit
        // never runs), and deinit must shut the connection down.
        weak var clientRef: SendspinClient?
        let mock: MockTransport
        do {
            let client = try makeTestClient()
            clientRef = client
            mock = try await connectClient(client)
        }

        let disconnected = await waitUntil { await mock.disconnectCalled }
        #expect(disconnected, "dropping the last client reference must close the transport")
        #expect(clientRef == nil, "the dropped client must deallocate (no drain self-retain cycle)")
    }

    // MARK: Setter idempotency (spec: state is sent "whenever any state changes")

    @Test
    func groupVolumeAndMuteOptimisticallyUpdateControllerState() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)
        try await mock.injectText(serverStateControllerJSON(ServerControllerState(
            supportedCommands: [.volume, .mute], volume: 25, muted: false,
            repeat: .off, shuffle: false
        )))
        #expect(await waitUntil { await MainActor.run { client.currentControllerState?.volume == 25 } })

        try await client.setGroupVolume(70)
        #expect(client.currentControllerState?.volume == 70)
        #expect(client.currentControllerState?.muted == false)

        try await client.setGroupMute(true)
        #expect(client.currentControllerState?.volume == 70)
        #expect(client.currentControllerState?.muted == true)

        await mock.setShouldFailOnSend(true)
        await #expect(throws: SendspinClientError.self) {
            try await client.setGroupVolume(10)
        }
        #expect(client.currentControllerState?.volume == 70, "failed optimistic group volume write must roll back")
        #expect(client.currentControllerState?.muted == true)

        await client.disconnect()
    }

    @Test
    func serverStateOverridesOptimisticGroupVolumeOnReject() async throws {
        // The send-fail path rolls back locally. This covers the OTHER half: the send
        // SUCCEEDS, but the server rejects the change and re-asserts its authoritative
        // value in a server/state. The facade must reconcile to the server's value,
        // not keep the optimistic local write. (Server state is authoritative.)
        let client = try makeTestClient()
        let mock = try await connectClient(client)
        try await mock.injectText(serverStateControllerJSON(ServerControllerState(
            supportedCommands: [.volume, .mute], volume: 25, muted: false,
            repeat: .off, shuffle: false
        )))
        #expect(await waitUntil { await MainActor.run { client.currentControllerState?.volume == 25 } })

        // Optimistic local write (send succeeds — no failure injected).
        try await client.setGroupVolume(70)
        #expect(client.currentControllerState?.volume == 70, "optimistic write applies immediately")

        // Server rejects: it re-asserts 25 as the authoritative group volume.
        try await mock.injectText(serverStateControllerJSON(ServerControllerState(
            supportedCommands: [.volume, .mute], volume: 25, muted: false,
            repeat: .off, shuffle: false
        )))

        #expect(
            await waitUntil { await MainActor.run { client.currentControllerState?.volume == 25 } },
            "an authoritative server/state must override the optimistic local volume"
        )

        await client.disconnect()
    }

    @Test
    func repeatedIdenticalSettersSendNoDuplicateClientState() async throws {
        // Spec sends client/state when state CHANGES; an unchanged set is not a
        // change. setStaticDelay already early-returns — volume and mute must too.
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        func clientStateCount() async -> Int {
            await mock.sentTextMessages.count(where: { SendspinEncoding.messageType(of: $0) == ClientStateMessage.typeString })
        }

        try await client.setVolume(42)
        let afterFirstVolume = await clientStateCount()
        try await client.setVolume(42)
        #expect(await clientStateCount() == afterFirstVolume, "an unchanged volume must not send client/state")

        try await client.setMute(true)
        let afterFirstMute = await clientStateCount()
        try await client.setMute(true)
        #expect(await clientStateCount() == afterFirstMute, "an unchanged mute must not send client/state")

        // Positive controls: the CHANGING sets each sent state.
        #expect(afterFirstVolume >= 1, "a changed volume must send client/state")
        #expect(afterFirstMute > afterFirstVolume, "a changed mute must send client/state")

        await client.disconnect()
    }

    // MARK: Command APIs apply observable state synchronously

    @Test
    func setVolumeAppliesObservableStateImmediately() async throws {
        // After `await setVolume`, currentVolume is immediately the new value.
        let client = try makeTestClient()
        let mock = try await connectClient(client)
        let newVolume = client.currentVolume == 100 ? 42 : 100

        try await client.setVolume(newVolume)
        #expect(client.currentVolume == newVolume)

        await client.disconnect()
        _ = mock
    }

    @Test
    func setMuteAppliesObservableStateImmediately() async throws {
        // After `await setMute`, currentMuted is immediately the new value.
        let client = try makeTestClient()
        let mock = try await connectClient(client)
        let newMuted = !client.currentMuted

        try await client.setMute(newMuted)
        #expect(client.currentMuted == newMuted)

        await client.disconnect()
        _ = mock
    }

    @Test
    func setStaticDelayAppliesObservableStateAndReachesEngine() async throws {
        // Observable state updates immediately AND the delay reaches the engine via
        // the ordered command channel.
        let client = try makeTestClient()
        let mock = try await connectClient(client)
        let newDelay = client.staticDelayMs == 0 ? 250 : 0

        try await client.setStaticDelay(newDelay)
        #expect(client.staticDelayMs == newDelay)

        // The delay is enqueued to the engine's ordered channel and applied.
        var sawDelayCommand = false
        for _ in 0 ..< 50 {
            if let kinds = await client.connection?.audioEngineForTesting.appliedCommandKinds(),
               kinds.contains(.setStaticDelay) {
                sawDelayCommand = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(sawDelayCommand, "setStaticDelay must reach the engine via the ordered channel")

        await client.disconnect()
        _ = mock
    }

    @Test
    func failedClientStateSendDoesNotRevertOptimisticState() async throws {
        // A failed client/state send must not revert the optimistic local state.
        let client = try makeTestClient()
        let mock = try await connectClient(client)
        await mock.setShouldFailOnSend(true)

        let newVolume = client.currentVolume == 100 ? 33 : 100
        let newMuted = !client.currentMuted
        let newDelay = client.staticDelayMs == 0 ? 175 : 0

        try await client.setVolume(newVolume)
        try await client.setMute(newMuted)
        try await client.setStaticDelay(newDelay)

        #expect(client.currentVolume == newVolume, "volume must stand despite a failed client/state send")
        #expect(client.currentMuted == newMuted, "mute must stand despite a failed client/state send")
        #expect(client.staticDelayMs == newDelay, "delay must stand despite a failed client/state send")

        await client.disconnect()
    }

    @Test
    func disconnectedSettersThrowWithoutMutating() async throws {
        // On a disconnected client the three setters throw .notConnected
        // and leave observable state unchanged (validate-before-mutate).
        let client = try makeTestClient()
        let volumeBefore = client.currentVolume
        let mutedBefore = client.currentMuted
        let delayBefore = client.staticDelayMs

        await #expect(throws: SendspinClientError.notConnected) { try await client.setVolume(50) }
        await #expect(throws: SendspinClientError.notConnected) { try await client.setMute(true) }
        await #expect(throws: SendspinClientError.notConnected) { try await client.setStaticDelay(300) }

        #expect(client.currentVolume == volumeBefore)
        #expect(client.currentMuted == mutedBefore)
        #expect(client.staticDelayMs == delayBefore)
    }

    @Test
    func playerSettersThrowRoleNotActiveForNonPlayerClient() async throws {
        let client = try SendspinClient(
            clientId: "metadata-only",
            name: "Metadata Only",
            roles: [.metadataV1]
        )
        let mock = try await connectClient(client, activeRoles: [.metadataV1])

        await #expect(throws: SendspinClientError.roleNotActive(.playerV1)) { try await client.setVolume(50) }
        await #expect(throws: SendspinClientError.roleNotActive(.playerV1)) { try await client.setMute(true) }
        await #expect(throws: SendspinClientError.roleNotActive(.playerV1)) { try await client.setStaticDelay(300) }

        #expect(client.currentVolume == 100)
        #expect(client.currentMuted == false)
        #expect(client.staticDelayMs == 0)

        await client.disconnect()
        _ = mock
    }

    @Test
    func roleNotActiveErrorDescriptionNamesRole() {
        #expect(SendspinClientError.roleNotActive(.playerV1).errorDescription == "The player@v1 role is not active for this connection")
    }

    @Test
    func metadataObservableWhenMetadataEventFires() async throws {
        // A host reading client.currentMetadata when it observes metadataReceived
        // sees the new value. The facade applies @Observable state on the line *before*
        // it yields the event; the strict apply-before-yield ordering is a same-actor
        // structural guarantee (verifiable by inspection — a consumer cannot observe the
        // window between yield and apply on one actor). This test verifies the end-to-end
        // result: state IS populated at the moment the event is delivered (it fails if the
        // facade ever stops applying the metadata).
        let client = try makeTestClient()
        let mock = try await connectClient(client)
        let expectedTitle = "Now Playing"

        // Listen concurrently and capture the observable state at the exact moment the
        // metadata event is observed (the facade applies state before yielding the event).
        let observed = Task { @MainActor () -> String? in
            for await event in client.events() {
                if case let .metadataReceived(metadata) = event, metadata.title == expectedTitle {
                    return client.currentMetadata?.title
                }
            }
            return nil
        }

        try await mock.injectText(metadataStateJSON(title: expectedTitle))

        // Bound the wait so a regression fails cleanly instead of hanging.
        let observedTitleAtEvent = await observeTask(observed, timeout: .seconds(3))

        switch observedTitleAtEvent {
        case let .completed(title):
            #expect(
                title == expectedTitle,
                "currentMetadata must be applied before metadataReceived is emitted (state-before-event)"
            )
        case .timedOut:
            Issue.record("Timed out waiting for metadataReceived")
        }

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
        // The superseded old connection's teardown must not have clobbered the new
        // session: a stale loss event interleaving the switch is dropped by the
        // identity guard. The connection owns the transport, so a live connection
        // is the facade-side proof the new transport survived the switch.
        #expect(client.connection != nil, "Competing-switch must leave the new session live")
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
    func competingConnectionNonHelloFirstFrameIsRejectedWithoutGoodbye() async throws {
        let client = try makeTestClient()
        let mock1 = try await connectClient(client, connectionReason: .discovery)
        let mock2 = MockTransport()
        async let accepted: Void = client.acceptConnection(mock2)

        let now = client.getCurrentMicroseconds()
        try await mock2.injectText(serverTimeJSON(
            clientTransmitted: now,
            serverReceived: now,
            serverTransmitted: now
        ))
        try await mock2.injectText(serverHelloJSON(serverId: "server-2", connectionReason: .playback))
        try await accepted

        #expect(client.currentServerId == testServerId)
        #expect(client.connectionState == .connected)
        let oldDisconnected = await mock1.disconnectCalled
        #expect(await mock2.disconnectCalled)
        #expect(await sentGoodbyeReasons(from: mock2).isEmpty)
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
    func serverSwitchCarriesPlayerStateToNewSession() async throws {
        // A multi-server switch skips the .disconnected facade reset (identity
        // guard), so the user's volume/mute/delay survive on the facade — the NEW
        // connection and its fresh engine must be seeded from that state, not
        // protocol defaults. Pre-fix, the promoted session reported volume 100,
        // unmuted, and the playerConfig initial delay.
        let client = try makeTestClient()
        _ = try await connectClient(client, connectionReason: .discovery)

        try await client.setVolume(42)
        try await client.setMute(true)
        try await client.setStaticDelay(250)

        // A playback-reason competitor wins over the discovery incumbent.
        let mockB = try await acceptCompeting(client, serverId: "server-b", connectionReason: .playback)

        let stateArrived = await waitUntil {
            await lastClientState(from: mockB, after: 0)?.player != nil
        }
        #expect(stateArrived, "the promoted session must send an initial client/state with player state")
        let player = await lastClientState(from: mockB, after: 0)?.player
        #expect(player?.volume == 42, "the carried volume must survive the switch")
        #expect(player?.muted == true, "the carried mute must survive the switch")
        #expect(player?.staticDelayMs == 250, "the carried static delay must survive the switch")

        await client.disconnect()
    }

    @Test
    func framesBufferedBehindHelloSurvivePromotionInOrder() async throws {
        // SPLIT_CONCERNS_PLAN claim, previously unproven: frames the new server
        // sends right behind its server/hello during arbitration sit buffered in
        // the transport and must reach the promoted session's engine in order —
        // neither dropped by the handshake reader nor reordered by the handoff.
        let client = try SendspinClient(
            clientId: "test-client",
            name: "Test Client",
            roles: [.playerV1, .controllerV1],
            playerConfig: PlayerConfiguration(
                bufferCapacity: 1_024,
                supportedFormats: [
                    AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
                ],
                emitRawAudioEvents: true
            )
        )
        _ = try await connectClient(client, connectionReason: .discovery)

        let mockB = MockTransport()
        async let accepted: Void = client.acceptConnection(mockB)
        try await mockB.injectText(serverHelloJSON(
            serverId: "server-b",
            activeRoles: [.playerV1],
            connectionReason: .playback
        ))

        // Observe binary continuity on the raw-emit path (no clock gate; the
        // engine-enqueue path would need clock sync, whose 100ms RTT gate makes
        // buffered-behind-hello server/time samples load-sensitive).
        let chunkTimestamps = AtomicList<Int64>()
        let collector = Task {
            for await chunk in client.audioChunks {
                chunkTimestamps.append(chunk.serverTimestamp)
            }
        }

        // Buffered behind the hello BEFORE promotion completes: a stream start
        // (opens the player gate) and three chunks with ascending timestamps.
        try await mockB.injectText(promotionStreamStartJSON())
        let chunkCount = 3
        for index in 0 ..< chunkCount {
            await mockB.injectBinary(promotionAudioChunkFrame(index: index))
        }
        try await accepted

        let engine = try #require(client.connection?.audioEngineForTesting)
        #expect(
            await waitUntil { await engine.appliedCommandKinds().contains(.streamStart) },
            "the buffered stream/start must reach the promoted engine"
        )
        #expect(
            await waitUntil { chunkTimestamps.count == chunkCount },
            "every chunk buffered behind the hello must survive promotion"
        )
        let expectedTimestamps = (0 ..< chunkCount).map { promotionChunkTimestamp(index: $0) }
        #expect(
            chunkTimestamps.all == expectedTimestamps,
            "buffered chunks must arrive complete and in send order; got \(chunkTimestamps.all)"
        )

        collector.cancel()
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
        await mock2.finishStreams() // never sends server/hello
        try await accepted

        let oldDisconnected = await mock1.disconnectCalled
        let newDisconnected = await mock2.disconnectCalled
        #expect(client.currentServerId == testServerId)
        #expect(client.connectionState == .connected)
        #expect(!oldDisconnected)
        #expect(newDisconnected)

        await client.disconnect()
    }

    @Test
    func competingConnection_silentOpenHandshakeTimesOutAndKeepsExisting() async throws {
        let client = try makeTestClient()
        let mock1 = try await connectClient(client, connectionReason: .discovery)

        let mock2 = MockTransport()
        let outcome = AsyncVoidOutcomeBox()
        Task {
            do {
                try await client.acceptConnection(mock2)
                await outcome.record(.success(()))
            } catch {
                await outcome.record(.failure(error))
            }
        }

        let completed = await waitUntil(timeout: .seconds(6)) { await outcome.hasOutcome }
        #expect(completed, "A silent competing connection must time out rather than wedge arbitration")
        if completed, case let .failure(error) = await outcome.outcome {
            Issue.record("Silent competing connection should be dropped without surfacing an error, got \(error)")
        }

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
        let mock1 = try await connectClient(client, connectionReason: .discovery)
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
        #expect(client.connectionState == .connected)
        let newDisconnected = await mock2.disconnectCalled
        #expect(await sentGoodbyeReasons(from: mock1) == [.anotherServer])
        #expect(await mock1.disconnectCalled)
        #expect(!newDisconnected)

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

    @Test
    func switchGroup_sendsSwitchCommand() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        let countBefore = await mock.sentTextMessages.count

        try await client.switchGroup()

        let command = try await lastSentCommand(from: mock, after: countBefore)
        let sent = try #require(command, "Expected a ClientCommandMessage after switchGroup()")
        #expect(sent.payload.controller?.command == .switch)

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

        await client.disconnect()

        // Exactly one goodbye, carrying .restart. sentGoodbyeReasons filters on the
        // decoded `type`, so background client/time traffic can't masquerade as one.
        let reasons = await sentGoodbyeReasons(from: mock)
        #expect(reasons == [.restart], "disconnect() must send one client/goodbye with reason .restart")
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

        // The guard must leave external-source untouched and send no client/state.
        // (Asserting on raw message count is wrong: a connected client emits
        // background client/time traffic that would inflate the count regardless.)
        #expect(client.clientOperationalState == .externalSource)
        let stateAfter = await lastClientState(from: mock, after: countBefore)
        #expect(stateAfter == nil, "An ignored underrun transition must not send a client/state")
    }
}
