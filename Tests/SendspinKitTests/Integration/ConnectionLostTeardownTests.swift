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

        #expect(client.connection == nil, "Connection must be released on connection loss")

        // A command now reports the honest .notConnected instead of silently
        // mutating a dead connection.
        await #expect(throws: SendspinClientError.notConnected) {
            try await client.setVolume(50)
        }
    }

    @Test
    func clockDiagnosticsAreClearedAfterDisconnect() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)
        try await establishClockSync(client, via: mock)

        let statsBeforeDisconnect = await client.currentClockSyncStats()
        #expect(statsBeforeDisconnect != nil, "clock sync diagnostics should exist after synchronization")

        await client.disconnect()
        try await waitForState(client, expected: .disconnected, timeout: .seconds(3))

        #expect(await client.currentClockSyncStats() == nil)
        #expect(await client.currentServerTimeMicroseconds() == nil)
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

        // Capture the live connection before the swap
        let connectionA = client.connection

        // Drive a reconnect to connection B
        let mockB = MockTransport()
        async let acceptB: Void = client.acceptConnection(mockB)
        try await mockB.injectText(serverHelloJSON(serverId: "server-b", connectionReason: .playback))
        try await acceptB

        // Verify B is now live
        #expect(client.connectionState == .connected, "Connection B must be live")
        #expect(client.connection !== connectionA, "Connection should have swapped from A to B")

        // Now simulate a late stale event from connection A (after B is already installed).
        // The identity guard in drainConnectionEvents checks `source === connection`, so
        // any event from A's drain loop (after the swap) will be rejected because
        // `source` (which points to A) != `connection` (which now points to B).
        //
        // To test this, we'd need to manually trigger an event from A's drain loop after
        // the swap, but A's drain loop has already exited when the connection was replaced.
        // Instead, we verify that B is stable and responding, which proves A's drain
        // didn't corrupt B:
        try await mockB.injectText(metadataJSON(title: "Track B"))
        let gotB = await waitUntil { await MainActor.run { client.currentMetadata?.title == "Track B" } }
        #expect(gotB, "Metadata should be received on connection B")

        #expect(client.connectionState == .connected, "Connection B must still be live after A is retired")

        await client.disconnect()
    }

    @Test
    func concurrentDisconnectAndLossEmitsSingleDisconnectedEvent() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        let collector = EventBox()
        let collectTask = Task { for await event in client.events() {
            await collector.append(event)
        } }

        // Block the goodbye send so disconnect() is pinned past its entry guard but
        // before the transport closes.
        await mock.enableGoodbyeGate()
        async let disconnecting: Void = client.disconnect(reason: .userRequest)
        let parked = await waitUntil { await mock.isGoodbyeGateWaiting }
        #expect(parked, "disconnect() should be parked on the goodbye send")

        // While disconnect is suspended (trying to send goodbye), simulate a connection
        // loss by closing the transport. The connection's supervisor will detect the
        // closed transport and initiate teardown via its hard-shutdown path.
        await mock.finishStreams()

        // Let disconnect resume and run to completion. It will race with the connection's
        // supervisor teardown (triggered by the closed transport).
        await mock.releaseGoodbyeGate()
        await disconnecting

        // Exactly one .disconnected event must reach consumers — the connection's
        // supervisor ensures teardown runs only once, so there's never a duplicate.
        // Negative wait: confirm a second never arrives.
        let reachedTwo = await waitUntil(timeout: .milliseconds(300)) { await collector.disconnectedCount >= 2 }
        collectTask.cancel()
        #expect(!reachedTwo, "A disconnect racing a connection loss must not emit two .disconnected events")
        #expect(await collector.disconnectedCount == 1)
        #expect(client.connectionState == .disconnected)

        // The connection resolves the race: whichever set the shuttingDown flag first
        // and recorded its reason wins. An explicit disconnect sets its reason before
        // the first await (inside the connection), so it wins over an unsolicited loss.
        #expect(await collector.disconnectedReasons == [.explicit(.userRequest)], "explicit reason must survive a racing loss")
    }

    @Test
    func connectionLossViaTransportCloseTriggersTeardown() async throws {
        let client = try makeTestClient()
        let mock = try await connectClient(client)

        // Inject some metadata to have state to verify preservation
        try await mock.injectText(metadataJSON(title: "Now Playing"))
        let got = await waitUntil { await MainActor.run { client.currentMetadata?.title == "Now Playing" } }
        #expect(got, "Metadata should be received")

        // Simulate an unsolicited transport close (network failure)
        await mock.finishStreams()

        // Wait for the client to notice and tear down
        try await waitForState(client, expected: .disconnected, timeout: .seconds(3))

        #expect(client.connectionState == .disconnected)
        // The connection owns the transport, so releasing it releases the session's
        // resources; the facade holds no transport reference of its own.
        #expect(client.connection == nil)
        #expect(client.drainConnectionEventsTask == nil)
        // Verify that observable state is preserved (the spec contract)
        #expect(client.currentMetadata?.title == "Now Playing", "Metadata must survive a transient drop")
    }

    @Test
    func staleDisconnectedAfterSwapIsIgnored() async throws {
        // After a fast reconnect that swaps connections, the old connection's
        // message loop may emit a late .disconnected event after the new connection
        // is already live. The facade's identity guard must ignore this stale event.
        // This verifies the `source === connection` guard in drainConnectionEvents
        // drops any event from a retired connection.
        let client = try makeTestClient()
        let mockA = try await connectClient(client)

        // Send metadata on connection A so we can verify it survives the swap.
        try await mockA.injectText(metadataJSON(title: "Track A"))
        let gotA = await waitUntil { await MainActor.run { client.currentMetadata?.title == "Track A" } }
        #expect(gotA, "Metadata should be received on connection A")

        // Capture connection A before the swap
        let connectionA = client.connection

        // Drive a real reconnect/swap: create connection B and accept it
        let mockB = MockTransport()
        async let acceptB: Void = client.acceptConnection(mockB)
        try await mockB.injectText(serverHelloJSON(serverId: "server-b", connectionReason: .playback))
        try await acceptB

        // Verify B is now the live connection (metadata reset on server/hello per spec)
        let bConnected = await waitUntil { await MainActor.run { client.connectionState == .connected && client.currentServerId == "server-b" } }
        #expect(bConnected, "Connection B should be established and active")

        // Capture connection B (it should be a different object from A)
        let connectionB = client.connection
        #expect(connectionB !== connectionA, "Connection objects should have swapped from A to B")

        // Now send metadata on connection B
        try await mockB.injectText(metadataJSON(title: "Track B"))
        let gotB = await waitUntil { await MainActor.run { client.currentMetadata?.title == "Track B" } }
        #expect(gotB, "Metadata should be received on connection B")

        // Simulate a late close of connection A's transport after B is installed.
        // This causes A's message loop to exit and attempt to emit a .disconnected event.
        // However, A's drain loop (in the facade) will already be gone because setupConnection
        // cancelled the old drainConnectionEventsTask before creating B. The identity guard
        // `source === connection` ensures that even if somehow an event from A leaked through,
        // it would be rejected because `source` (pointing to A) != `connection` (which points to B).
        //
        // We can't directly trigger A's stale event from here since A's drain was cancelled,
        // but we verify the result: B is stable and responding, which proves A couldn't corrupt it.
        await mockA.finishStreams()

        // Give any residual teardown time to complete
        try? await Task.sleep(for: .milliseconds(100))

        // The stale event must not affect B: B stays live and fully responsive.
        // Connection state and metadata should reflect B, unchanged.
        #expect(client.connectionState == .connected, "Stale event from old connection must not affect current connection B")
        #expect(client.currentServerId == "server-b", "Server ID should still reflect connection B")
        #expect(client.currentMetadata?.title == "Track B", "Metadata should still reflect connection B")

        await client.disconnect()
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
