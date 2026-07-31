import Foundation
@testable import SendspinKit
import Testing

/// The design contract (SPLIT_CONCERNS_PLAN.md §reconnect): retire flips the
/// session-validity token *synchronously*, before awaiting the old connection's
/// shutdown, so both guards (token for binary, identity for control) reject the
/// dying connection's late events during teardown. The retire seam contains no
/// suspension points; that property is what makes the gating race-free.
@Suite("Session retire")
struct SessionRetireTests {
    /// The token must be invalidated synchronously, before asynchronous teardown begins,
    /// so late events cannot enter the retired session.
    @Test("retireSession gates late events before teardown begins")
    @MainActor
    func retireFlipsTokenAndDetachesConnectionSynchronously() async throws {
        let client = try SendspinClient(
            clientId: "retire-test",
            name: "Retire Test",
            roles: [.controllerV1]
        )
        let mock = try await connectClient(client, activeRoles: [.controllerV1])

        let token = try #require(client.sessionValidity)
        #expect(token.isValid)

        let retired = client.retireSession()

        // Synchronous consequences — observable before any suspension:
        #expect(!token.isValid)
        #expect(client.connection == nil)
        #expect(retired != nil)

        // Teardown has NOT begun: the flip did not ride on shutdown()'s own
        // invalidation (SendspinConnection.shutdown's first act).
        #expect(await mock.disconnectCalled == false)

        await retired?.shutdown()
    }

    /// The terminal `.disconnected` retire path must leave the facade with no
    /// live token either — uniform "retired implies invalid" invariant.
    @Test("connection-lost retire invalidates the stored session token")
    @MainActor
    func connectionLossInvalidatesStoredToken() async throws {
        let client = try SendspinClient(
            clientId: "retire-loss-test",
            name: "Retire Loss Test",
            roles: [.controllerV1]
        )
        let mock = try await connectClient(client, activeRoles: [.controllerV1])
        let token = try #require(client.sessionValidity)

        // Unsolicited loss: transport closes, supervisor tears down, facade retires.
        await mock.finishStreams()
        try await waitForState(client, expected: .disconnected, timeout: .seconds(3))

        #expect(!token.isValid)
        #expect(client.connection == nil)
    }
}
