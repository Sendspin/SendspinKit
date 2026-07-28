import Foundation
@testable import SendspinKit
import Testing

/// The transport's terminal cause must survive to the public `.disconnected` event.
///
/// Pins only that *when* the transport can distinguish causes the distinction reaches the
/// host app — not that a server is obliged to provide one.
@MainActor
struct CloseReasonPropagationTests {
    private func connectedClient() async throws -> (SendspinClient, MockTransport) {
        let client = try SendspinClient(
            clientId: "close-reason-client",
            name: "Close Reason Client",
            roles: [.metadataV1]
        )
        let mock = MockTransport()
        try await client.acceptConnection(mock)
        await mock.injectText("""
        {"type":"server/hello","payload":{"server_id":"srv-1","name":"S","version":1,\
        "active_roles":["metadata@v1"],"connection_reason":"playback"}}
        """)
        #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })
        return (client, mock)
    }

    private func firstDisconnectReason(
        from client: SendspinClient,
        while trigger: @Sendable () async -> Void
    ) async -> DisconnectReason? {
        let box = TestBox<DisconnectReason?>(nil)
        // Subscribe before triggering, so the terminal event cannot be missed.
        let events = client.events()
        let watcher = Task {
            for await event in events {
                if case let .disconnected(reason) = event {
                    await box.set(reason)
                    return
                }
            }
        }
        await trigger()
        _ = await waitUntil { await box.value != nil }
        watcher.cancel()
        return await box.value
    }

    @Test("a peer close frame surfaces as .connectionLost(.peerClosed) with its close code")
    func peerCloseSurfacesWithCode() async throws {
        let (client, mock) = try await connectedClient()

        let reason = await firstDisconnectReason(from: client) {
            await mock.simulateClose(.peerClosed(code: 1_001))
        }

        guard case let .connectionLost(closeReason) = reason else {
            #expect(Bool(false), "expected .connectionLost, got \(String(describing: reason))")
            return
        }
        #expect(closeReason == .peerClosed(code: 1_001), "the peer's close code must not be discarded")
    }

    @Test("a network failure surfaces as .connectionLost(.failed) carrying the cause")
    func networkFailureSurfacesWithDescription() async throws {
        let (client, mock) = try await connectedClient()

        let reason = await firstDisconnectReason(from: client) {
            await mock.simulateClose(.failed(description: "posix(54) connection reset"))
        }

        guard case let .connectionLost(closeReason) = reason else {
            #expect(Bool(false), "expected .connectionLost, got \(String(describing: reason))")
            return
        }
        guard case let .failed(description) = closeReason else {
            #expect(Bool(false), "expected .failed, got \(String(describing: closeReason))")
            return
        }
        #expect(description.contains("connection reset"), "the NWError cause must survive for diagnostics")
    }

    @Test("a clean peer close and a network failure are distinguishable")
    func peerCloseAndFailureAreDistinguishable() async throws {
        let (clientA, mockA) = try await connectedClient()
        let cleanReason = await firstDisconnectReason(from: clientA) {
            await mockA.simulateClose(.peerClosed(code: 1_000))
        }

        let (clientB, mockB) = try await connectedClient()
        let failedReason = await firstDisconnectReason(from: clientB) {
            await mockB.simulateClose(.failed(description: "posix(54)"))
        }

        #expect(cleanReason != failedReason, "the two causes must not collapse to the same reason")
    }

    @Test("an explicit disconnect still reports .explicit, not the transport's cause")
    func explicitDisconnectWins() async throws {
        let (client, _) = try await connectedClient()

        let reason = await firstDisconnectReason(from: client) {
            await client.disconnect(reason: .userRequest)
        }

        #expect(reason == .explicit(.userRequest), "a local disconnect must not be reported as connection loss")
    }

    /// The post-close receive error must not overwrite the real cause.
    @Test("a trailing failure does not overwrite an already-observed peer close")
    func firstObservedCauseWins() async {
        let mock = MockTransport()
        await mock.simulateClose(.peerClosed(code: 1_000))
        await mock.simulateClose(.failed(description: "post-close artifact"))

        #expect(await mock.closeReason == .peerClosed(code: 1_000))
    }
}
