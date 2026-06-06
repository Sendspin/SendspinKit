// ABOUTME: Verifies a connection lost without an explicit disconnect tears down live resources
// ABOUTME: while preserving observable session state, and that a superseded teardown is ignored

import Foundation
@testable import SendspinKit
import Testing

@MainActor
struct ConnectionLostTeardownTests {
    // MARK: Fixtures

    private func metadataJSON(title: String) throws -> String {
        let message = ServerStateMessage(payload: ServerStatePayload(
            metadata: ServerMetadataState(title: .value(title))
        ))
        return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
    }

    private func groupUpdateJSON(groupId: String, groupName: String) throws -> String {
        let message = GroupUpdateMessage(payload: GroupUpdatePayload(
            playbackState: nil,
            groupId: groupId,
            groupName: groupName
        ))
        return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
    }

    // MARK: Resource teardown

    @Test
    func connectionLossReleasesLiveResources() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        await mock.finishStreams()
        try await waitForState(client, expected: .disconnected, timeout: .seconds(3))

        #expect(client.transport == nil, "Transport must be released on connection loss")
        #expect(client.messageLoopTask == nil)
        #expect(client.clockSyncTask == nil)
        #expect(client.schedulerOutputTask == nil)
        #expect(client.syncTelemetryTask == nil)

        // A command now reports the honest .notConnected instead of silently
        // mutating a dead connection.
        await #expect(throws: SendspinClientError.notConnected) {
            try await client.setVolume(50)
        }
    }

    @Test
    func connectionLossPreservesObservableState() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        try await mock.injectText(metadataJSON(title: "Now Playing"))
        try await mock.injectText(groupUpdateJSON(groupId: "g1", groupName: "Kitchen"))
        _ = await waitUntil {
            await MainActor.run {
                client.currentMetadata?.title == "Now Playing" && client.currentGroup?.groupId == "g1"
            }
        }

        await mock.finishStreams()
        try await waitForState(client, expected: .disconnected, timeout: .seconds(3))

        // A transient drop must not blank the UI: last-known state stays observable
        // until the next connection replaces it.
        #expect(client.currentMetadata?.title == "Now Playing", "Metadata must survive a transient drop")
        #expect(client.currentGroup?.groupId == "g1", "Group must survive a transient drop")
    }

    // MARK: Generation guard

    @Test
    func staleConnectionLostIsIgnored() async throws {
        let client = try makeTestClient()
        _ = try await connectClient(client)

        // A teardown tagged for an older generation — a message loop superseded by
        // a fast reconnect holds the generation it started with, which is lower
        // than the current one — must not touch the connection that replaced it.
        await client.handleConnectionLost(generation: client.connectionGeneration &- 1)

        #expect(client.connectionState == .connected, "Stale teardown must not disconnect the live connection")
        #expect(client.transport != nil, "Stale teardown must not release the live transport")
        #expect(client.messageLoopTask != nil, "Stale teardown must not cancel the live tasks")

        await client.disconnect()
    }

    @Test
    func concurrentDisconnectAndLossEmitsSingleDisconnectedEvent() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        let collector = EventBox()
        let collectTask = Task { for await event in client.events {
            await collector.append(event)
        } }

        // Block the goodbye send so disconnect() is pinned past its entry guard but
        // before it settles state.
        await mock.enableGoodbyeGate()
        async let disconnecting: Void = client.disconnect(reason: .userRequest)
        let parked = await waitUntil { await mock.isGoodbyeGateWaiting }
        #expect(parked, "disconnect() should be parked on the goodbye send")

        // While disconnect is suspended, a connection-loss teardown completes and
        // settles the connection (yielding .connectionLost).
        await client.handleConnectionLost(generation: client.connectionGeneration)

        // Let disconnect resume and run to completion.
        await mock.releaseGoodbyeGate()
        await disconnecting

        // Exactly one .disconnected event must reach consumers — never a duplicate
        // because both teardown paths each emitted one. Negative wait: confirm a
        // second never arrives.
        let reachedTwo = await waitUntil(timeout: .milliseconds(300)) { await collector.disconnectedCount >= 2 }
        collectTask.cancel()
        #expect(!reachedTwo, "A disconnect racing a connection loss must not emit two .disconnected events")
        #expect(await collector.disconnectedCount == 1)
        #expect(client.connectionState == .disconnected)

        // The loss settled first, but the user's explicit intent must still win the
        // reported reason — a host app branches on it (no auto-reconnect on a user
        // request) and must not see a spurious .connectionLost.
        #expect(await collector.disconnectedReasons == [.explicit(.userRequest)], "explicit reason must survive a racing loss")
    }

    @Test
    func matchingConnectionLostTearsDown() async throws {
        let client = try makeTestClient()
        _ = try await connectClient(client)

        // The same call with the current generation does tear down — proving the
        // guard above rejects on generation, not because the method is inert.
        await client.handleConnectionLost(generation: client.connectionGeneration)

        #expect(client.connectionState == .disconnected)
        #expect(client.transport == nil)
        #expect(client.messageLoopTask == nil)
    }
}

/// Accumulates client events for assertions about how many of a kind were emitted.
private actor EventBox {
    private var events: [ClientEvent] = []

    func append(_ event: ClientEvent) {
        events.append(event)
    }

    var disconnectedCount: Int {
        events.count(where: { if case .disconnected = $0 { true } else { false } })
    }

    var disconnectedReasons: [DisconnectReason] {
        events.compactMap { if case let .disconnected(reason) = $0 { reason } else { nil } }
    }
}
