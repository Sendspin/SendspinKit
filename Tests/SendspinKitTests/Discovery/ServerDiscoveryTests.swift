// ABOUTME: Tests for ServerDiscovery lifecycle and state management
// ABOUTME: Verifies termination semantics, idempotent stop, and TerminatedError behavior

import Foundation
@testable import SendspinKit
import Testing

struct ServerDiscoveryTests {
    @Test
    func newlyCreatedInstanceIsNotTerminated() async {
        let discovery = ServerDiscovery()
        let terminated = await discovery.isTerminated
        #expect(!terminated)
    }

    @Test
    func isTerminatedBecomesTrueAfterStopDiscovery() async {
        let discovery = ServerDiscovery()
        await discovery.stopDiscovery()
        let terminated = await discovery.isTerminated
        #expect(terminated)
    }

    @Test
    func startDiscovery_throwsTerminatedErrorAfterStopDiscovery() async {
        let discovery = ServerDiscovery()
        await discovery.stopDiscovery()

        await #expect(throws: TerminatedError.self) {
            try await discovery.startDiscovery()
        }
    }

    @Test
    func stopDiscoveryIsIdempotent() async {
        let discovery = ServerDiscovery()
        await discovery.stopDiscovery()
        // Second stop should not crash or change state
        await discovery.stopDiscovery()

        let terminated = await discovery.isTerminated
        #expect(terminated)
    }

    @Test
    func multipleStopDiscoveryCallsRemainSafe() async {
        let discovery = ServerDiscovery()
        for _ in 0 ..< 5 {
            await discovery.stopDiscovery()
        }
        let terminated = await discovery.isTerminated
        #expect(terminated)
    }

    @Test
    func serversStreamExistsOnNewInstance() async {
        let discovery = ServerDiscovery()
        // The servers property should be accessible immediately after init
        _ = await discovery.servers
        await discovery.stopDiscovery()
    }

    @Test
    func serversStreamFinishesAfterStopDiscovery() async {
        let discovery = ServerDiscovery()
        let servers = await discovery.servers

        await discovery.stopDiscovery()

        // After stop, iterating the stream should complete immediately
        // (the continuation has been finished)
        var count = 0
        for await _ in servers {
            count += 1
        }
        #expect(count == 0)
    }

    // MARK: - Interface scope stripping

    @Test
    func stripInterfaceScope_removesPercentSuffix() {
        // IPv4 with interface scope (common on macOS)
        #expect(ServerDiscovery.stripInterfaceScope("192.168.1.181%en0") == "192.168.1.181")
    }

    @Test
    func stripInterfaceScope_preservesBareAddress() {
        // No scope — should pass through unchanged
        #expect(ServerDiscovery.stripInterfaceScope("192.168.1.181") == "192.168.1.181")
    }

    @Test
    func stripInterfaceScope_handlesIPv6WithScope() {
        #expect(ServerDiscovery.stripInterfaceScope("fe80::1%en0") == "fe80::1")
    }

    @Test
    func stripInterfaceScope_handlesEmptyString() {
        #expect(ServerDiscovery.stripInterfaceScope("") == "")
    }

    // MARK: - TerminatedError

    @Test
    func terminatedError_hasMeaningfulDescription() {
        let error = TerminatedError()
        #expect(error.description.contains("permanently stopped"))
        #expect(error.errorDescription?.contains("permanently stopped") == true)
    }

    @Test
    func terminatedError_conformsToSendspinError() {
        let error: any Error = TerminatedError()
        #expect(error is any SendspinError)
    }
}
