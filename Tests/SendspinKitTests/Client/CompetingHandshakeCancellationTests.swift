import Foundation
@testable import SendspinKit
import Testing

/// `performHandshake`'s reader parks in `nextFrame()`, which only transport closure
/// releases. External cancellation makes the timeout child report `.ended`, which used to
/// skip the close — so `cancelAll()` was a no-op and the group's drain never returned.
@MainActor
struct CompetingHandshakeCancellationTests {
    /// Must stay under `performHandshake`'s own 5s timeout, or the test would pass even
    /// with the bug once that timeout fired.
    private static let cancellationBound: Duration = .seconds(3)

    @Test("cancelling a competing-connection handshake terminates instead of hanging")
    func cancellationTerminatesHandshake() async throws {
        let client = try makeTestClient()
        let existing = try await connectClient(client, connectionReason: .discovery)

        // Accepts the client/hello but never answers: leaves the reader child parked.
        let candidate = MockTransport()
        let finished = TestBox<Bool>(false)

        let task = Task {
            // The handshake is expected to fail; we only care that it *returns*.
            try? await client.acceptConnection(candidate)
            await finished.set(true)
        }

        // Cancelling before the handshake starts would pass trivially.
        #expect(
            await waitUntil { await !candidate.sentTextMessages.isEmpty },
            "the handshake must have sent client/hello on the candidate before cancelling"
        )

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
        #expect(client.currentServerId == testServerId)

        await client.disconnect()
    }
}
