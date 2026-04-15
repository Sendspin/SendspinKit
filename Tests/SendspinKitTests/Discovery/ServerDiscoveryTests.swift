// ABOUTME: Tests for ServerDiscovery lifecycle and state management
// ABOUTME: Verifies termination semantics, idempotent stop, and TerminatedError behavior

import Foundation
@testable import SendspinKit
import Testing

struct ServerDiscoveryTests {
    @Test
    func `newly created instance is not terminated`() async {
        let discovery = ServerDiscovery()
        let terminated = await discovery.isTerminated
        #expect(!terminated)
    }

    @Test
    func `isTerminated becomes true after stopDiscovery`() async {
        let discovery = ServerDiscovery()
        await discovery.stopDiscovery()
        let terminated = await discovery.isTerminated
        #expect(terminated)
    }

    @Test
    func `startDiscovery throws TerminatedError after stopDiscovery`() async {
        let discovery = ServerDiscovery()
        await discovery.stopDiscovery()

        await #expect(throws: TerminatedError.self) {
            try await discovery.startDiscovery()
        }
    }

    @Test
    func `stopDiscovery is idempotent`() async {
        let discovery = ServerDiscovery()
        await discovery.stopDiscovery()
        // Second stop should not crash or change state
        await discovery.stopDiscovery()

        let terminated = await discovery.isTerminated
        #expect(terminated)
    }

    @Test
    func `multiple stopDiscovery calls remain safe`() async {
        let discovery = ServerDiscovery()
        for _ in 0 ..< 5 {
            await discovery.stopDiscovery()
        }
        let terminated = await discovery.isTerminated
        #expect(terminated)
    }

    @Test
    func `servers stream exists on new instance`() async {
        let discovery = ServerDiscovery()
        // The servers property should be accessible immediately after init
        _ = await discovery.servers
        await discovery.stopDiscovery()
    }

    @Test
    func `servers stream finishes after stopDiscovery`() async {
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
    func `TerminatedError has meaningful description`() {
        let error = TerminatedError()
        #expect(error.description.contains("permanently stopped"))
        #expect(error.errorDescription?.contains("permanently stopped") == true)
    }

    @Test
    func `TerminatedError conforms to SendspinError`() {
        let error: any Error = TerminatedError()
        #expect(error is any SendspinError)
    }
}
