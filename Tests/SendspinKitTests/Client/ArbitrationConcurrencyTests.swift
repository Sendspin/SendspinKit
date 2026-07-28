import Foundation
@testable import SendspinKit
import Testing

/// `MultiServerArbitrationTests` covers the pure decision table; these cover the
/// concurrent paths around it, which had no coverage.
@MainActor
struct ArbitrationConcurrencyTests {
    /// Two servers dialling in within the 5s handshake window is ordinary on a
    /// multi-server network. Both used to arbitrate against a stale incumbent and switch.
    @Test("a second competing connection arriving mid-arbitration is dropped, not arbitrated")
    func concurrentArbitrationDropsTheSecondCandidate() async throws {
        let client = try makeTestClient()
        let incumbent = try await connectClient(client, connectionReason: .discovery)

        // Candidate A stays silent, so its arbitration is still in flight.
        let candidateA = MockTransport()
        let candidateB = MockTransport()

        let taskA = Task { try? await client.acceptConnection(candidateA) }

        // A's handshake must be underway before B arrives, or this proves nothing.
        #expect(
            await waitUntil { await !candidateA.sentTextMessages.isEmpty },
            "candidate A's handshake should be in flight"
        )

        // B arrives while A holds the arbitration.
        try await client.acceptConnection(candidateB)

        #expect(
            await candidateB.disconnectCalled,
            "a candidate arriving mid-arbitration must be dropped"
        )
        // No goodbye is owed: the spec forbids messages before a handshake completes.
        #expect(
            await candidateB.sentTextMessages.isEmpty,
            "the dropped candidate must not be sent anything"
        )
        // The incumbent is untouched throughout.
        #expect(await !incumbent.disconnectCalled)
        #expect(client.connectionState == .connected)
        #expect(client.currentServerId == testServerId)

        taskA.cancel()
        await candidateA.finishStreams()
        _ = await taskA.value
        await client.disconnect()
    }

    /// `connection` is nil for the whole dial and handshake window, so a `disconnect()`
    /// landing there has nothing to detach. Without an epoch the call is a silent no-op:
    /// the client stays `.connecting` forever and the dial goes on to install a session
    /// the caller explicitly cancelled.
    @Test("disconnect during a pending session transition still lands")
    func disconnectDuringPendingTransitionApplies() async throws {
        let client = try makeTestClient()

        // The state a dial occupies while its transport is still being established.
        client.updateConnectionState(.connecting)
        #expect(client.connection == nil, "the dial window has no connection yet")

        await client.disconnect(reason: .userRequest)

        #expect(
            client.connectionState == .disconnected,
            "the caller's intent must land even with no connection to detach"
        )
    }

    /// The incumbent is read after a suspension of up to 5s. If it dies in that window,
    /// arbitrating against it can yield `.keepExisting`, which closes the healthy
    /// candidate and leaves the client with no connection at all.
    @Test("a candidate is adopted when the incumbent dies mid-arbitration")
    func candidateAdoptedWhenIncumbentDiesMidArbitration() async throws {
        let client = try makeTestClient()
        let incumbent = try await connectClient(client, connectionReason: .playback)

        let candidate = MockTransport()
        let arbitration = Task { try? await client.acceptConnection(candidate) }

        #expect(
            await waitUntil { await !candidate.sentTextMessages.isEmpty },
            "the candidate's handshake should be in flight"
        )

        // The incumbent drops on its own — not via disconnect(), so this is a lost
        // connection rather than the caller changing their mind.
        await incumbent.finishStreams()
        #expect(
            await waitUntil { await MainActor.run { client.connection == nil } },
            "the incumbent should have been retired"
        )

        // Now let the candidate finish its handshake.
        try await candidate.injectText(serverHelloJSON(connectionReason: .discovery))
        _ = await arbitration.value

        try await waitForState(client, expected: .connected, timeout: .seconds(3))
        #expect(await !candidate.disconnectCalled, "the adopted candidate must stay open")

        await client.disconnect()
    }

    /// Otherwise the first competing connection would block all later ones forever.
    @Test("the arbitration gate reopens after an arbitration completes")
    func arbitrationGateReopens() async throws {
        let client = try makeTestClient()
        _ = try await connectClient(client, connectionReason: .playback)

        // First candidate: closes immediately, so arbitration ends fast (handshake fails).
        let first = MockTransport()
        await first.finishStreams()
        try await client.acceptConnection(first)

        // Second candidate must actually be arbitrated, not rejected by a stuck gate.
        let second = MockTransport()
        await second.finishStreams()
        try await client.acceptConnection(second)

        #expect(
            await second.sentTextMessages.contains { SendspinEncoding.messageType(of: $0) == "client/hello" },
            "the gate must have reopened, letting the second candidate begin its handshake"
        )

        await client.disconnect()
    }
}
