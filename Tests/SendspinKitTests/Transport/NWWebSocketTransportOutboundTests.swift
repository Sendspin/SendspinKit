import Foundation
import Network
@testable import SendspinKit
import Testing

struct NWWebSocketTransportOutboundTests {
    // MARK: - Outbound init structural test

    @Test
    func outboundInitCreatesTransport() {
        guard let url = URL(string: "ws://localhost/test") else {
            Issue.record("Failed to create URL")
            return
        }
        // Just verify the initializer doesn't crash
        _ = NWWebSocketTransport(url: url)
    }

    // MARK: - Prompt cancel via disconnect() finishStreams()

    /// Tests prompt nextFrame() unblocking after disconnect with a live WebSocket loopback.
    /// This test verifies that a pending nextFrame() call returns promptly (nil) after disconnect(),
    /// not hanging indefinitely on an in-flight receiveMessage.
    ///
    /// Root mechanism: Stream finishes via any of three co-equal redundant paths:
    /// the in-flight receiveMessage error callback (handleReceiveError → finishStreams()),
    /// the connection state handler reaching .cancelled (handleConnectionState → finishStreams()),
    /// or the explicit finishStreams() call in disconnect(). All three ensure the stream
    /// finishes and unblocks nextFrame(); removing all three reproduces the ~60s hang.
    ///
    /// The test:
    /// 1. Stands up a loopback NWListener server listening on an ephemeral port.
    /// 2. Server holds incoming connections open with an in-flight receiveMessage (realistic scenario).
    /// 3. Connects an NWWebSocketTransport to the server (reaching .ready state).
    /// 4. Starts a pending nextFrame() task (blocks waiting for incoming frames).
    /// 5. Calls disconnect() and asserts nextFrame() returns nil sub-second (not a timeout).
    ///
    /// This verifies end-to-end that a live outbound connection's pending receive unblocks promptly
    /// after cancel, not hanging on the in-flight receiveMessage that Network.framework warns about.
    @Test
    func disconnectPromptlyUnblocksPendingNextFrame() async throws {
        try await withLoopbackServer { _, port in
            let url = try #require(URL(string: "ws://127.0.0.1:\(port)/test"))
            let transport = NWWebSocketTransport(url: url)

            // Connect with a bounded budget: if not .ready in 3s, fail explicitly.
            let connectStartTime = CFAbsoluteTimeGetCurrent()
            try await runUnstructuredWithDeadline(
                .seconds(3),
                label: "connect()",
                onTimeout: { await transport.disconnect() },
                operation: { try await transport.connect() }
            )
            let connectElapsed = CFAbsoluteTimeGetCurrent() - connectStartTime
            #expect(connectElapsed < 3.0, "Connected in \(String(format: "%.3f", connectElapsed))s (expected <3s)")

            // Verify connection is ready
            let isReady = await transport.isConnected
            #expect(isReady, "Transport must be .ready before testing nextFrame()")

            // Spawn a pending nextFrame() task (will block on in-flight receiveMessage
            // since the server accepts the connection but sends no frames).
            let frameTask = Task { await transport.nextFrame() }

            // Give nextFrame() a moment to start waiting on the async stream.
            try await Task.sleep(for: .milliseconds(100))

            // Disconnect: this should trigger connection.cancel() → stateUpdateHandler(.cancelled)
            // → finishStreams(), causing the pending nextFrame() to return nil promptly.
            let disconnectStartTime = CFAbsoluteTimeGetCurrent()
            await transport.disconnect()
            let disconnectElapsed = CFAbsoluteTimeGetCurrent() - disconnectStartTime
            #expect(disconnectElapsed < 0.5, "disconnect() itself returned in \(String(format: "%.3f", disconnectElapsed))s")

            // Observe nextFrame() completion with a non-cancellable-safe deadline.
            // CRITICAL: If timeout fires, the test FAILS instead of wedging on task-group scope exit.
            let frameObservation = await observeTask(
                frameTask,
                timeout: .seconds(2),
                onTimeout: { await transport.disconnect() }
            )
            switch frameObservation {
            case let .completed(frame):
                #expect(frame == nil, "nextFrame() after disconnect() must return nil, got \(String(describing: frame))")
            case .timedOut:
                Issue.record("nextFrame() must return (nil) sub-second after disconnect()")
            }
        }
    }

    // MARK: - Send on a dead-but-non-nil connection

    /// `send`/`sendBinary` guarded only `connection == nil`, so a connection that
    /// died underneath us (server gone, NWConnection no longer `.ready`) attempted
    /// a real Network.framework send instead of failing fast with
    /// `TransportError.notConnected`. Both sends are bounded so a pre-fix NW
    /// pathology (completion never called on a dead connection) fails the test
    /// instead of wedging it.
    @Test
    func sendOnDeadConnectionThrowsNotConnected() async throws {
        let server = LoopbackWebSocketServer()
        let port = try await server.start()

        let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))
        let transport = NWWebSocketTransport(url: url)
        try await transport.connect()
        #expect(await transport.isConnected, "positive control: transport must be .ready after connect")

        // Kill the server side. The NWConnection does NOT leave .ready on its own —
        // TCP death is only observed on I/O — so poison the socket with sends
        // (ignoring their outcomes) until the failed I/O flips the state.
        await server.stop()
        let died = await waitUntil(timeout: .seconds(3)) {
            _ = await outcomeOfUnstructuredOperation(timeout: .seconds(2)) {
                try await transport.send(Ping())
            }
            return await !transport.isConnected
        }
        #expect(died, "a failed send must flip the NWConnection out of .ready")

        // Locally-known-dead (state != .ready, connection non-nil): both send
        // paths must fail fast with the typed error, no NW I/O attempted.
        let textOutcome = await outcomeOfUnstructuredOperation(timeout: .seconds(2)) {
            try await transport.send(Ping())
        }
        expectNotConnected(textOutcome, "send")
        let binaryOutcome = await outcomeOfUnstructuredOperation(timeout: .seconds(2)) {
            try await transport.sendBinary(Data([0x01]))
        }
        expectNotConnected(binaryOutcome, "sendBinary")

        await transport.disconnect()
    }

    private func expectNotConnected(_ outcome: Result<Void, Error>?, _ label: String) {
        switch outcome {
        case nil:
            Issue.record("\(label) on a dead connection timed out instead of throwing promptly")
        case .success:
            Issue.record("\(label) on a dead connection unexpectedly succeeded")
        case let .failure(error):
            if case TransportError.notConnected = error {} else {
                Issue.record("\(label) threw \(error) instead of TransportError.notConnected")
            }
        }
    }

    // MARK: - Dial failure: refused port must fail promptly, not hang in .waiting

    /// A refused connection (no listener on the port) parks NWConnection in
    /// `.waiting` — Network.framework retries indefinitely waiting for conditions
    /// to change. The dial must surface that as a prompt error, not an unbounded
    /// hang of `connect()`. Deterministic repro: dial a loopback port whose
    /// listener was just shut down.
    ///
    /// Pre-fix this fails via the poll timeout (connect() never completes); the
    /// trailing `disconnect()` unparks the orphaned dial so the test process
    /// doesn't leak a parked continuation either way.
    @Test
    func dialRefusedPortFailsPromptlyInsteadOfHangingInWaiting() async throws {
        let server = LoopbackWebSocketServer()
        let port = try await server.start()
        await server.stop()

        let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))
        let transport = NWWebSocketTransport(url: url)

        do {
            try await runUnstructuredWithDeadline(
                .seconds(3),
                label: "connect() to a refused port",
                onTimeout: { await transport.disconnect() },
                operation: { try await transport.connect() }
            )
            Issue.record("connect() to a refused port unexpectedly succeeded")
        } catch is AsyncTestDeadlineError {
            Issue.record("connect() to a refused port must fail promptly, not hang in .waiting")
        } catch {
            // Expected: a refused dial should surface a connection failure promptly.
        }

        await transport.disconnect()
    }
}

/// Minimal Codable payload for exercising the text send path.
private struct Ping: Codable {
    var v = 1
}
