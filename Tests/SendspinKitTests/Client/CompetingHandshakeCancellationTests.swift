import Foundation
@testable import SendspinKit
import Testing

/// `performHandshake`'s reader parks in `nextFrame()`, which only transport closure
/// releases. Cancellation must therefore close the candidate transport so the task group
/// can drain.
@MainActor
struct CompetingHandshakeCancellationTests {
    /// Must stay under `performHandshake`'s own 5s timeout, or the test would pass even
    /// with the bug once that timeout fired.
    private static let cancellationBound: Duration = .seconds(3)

    @Test("cancelling a competing-connection handshake terminates instead of hanging")
    func cancellationTerminatesHandshake() async throws {
        let client = try makeTestClient()
        let existing = try await connectClient(client, connectionReason: .discovery)

        // Complete Noise establishment, then leave the encrypted server/hello unanswered.
        let candidate = MockTransport()
        let server = MockNoiseServer(transport: candidate, psk: .sentinel)
        let finished = TestBox<Bool>(false)

        let task = Task {
            // The handshake is expected to fail; we only care that it *returns*.
            try? await client.acceptConnection(candidate)
            await finished.set(true)
        }

        // Cancelling before the handshake starts would pass trivially.
        let handshakeStarted = await waitUntil { await candidate.hasSentFrames }
        #expect(handshakeStarted, "the handshake must have started before cancelling")
        try await server.respondToHandshake()

        task.cancel()

        #expect(
            await waitUntil(timeout: Self.cancellationBound) { await finished.value },
            "a cancelled competing handshake must terminate, not hang on the parked reader"
        )
        #expect(
            await candidate.disconnectCalled,
            "the abandoned candidate transport must be closed, not leaked half-open"
        )

        // The incumbent connection must be entirely undisturbed by the cancelled candidate.
        #expect(await !existing.disconnectCalled)
        #expect(client.connectionState == .connected)
        let incumbentServerId = await existing.serverId
        #expect(client.currentServerId == incumbentServerId)

        await client.disconnect()
    }
}
