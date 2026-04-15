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
