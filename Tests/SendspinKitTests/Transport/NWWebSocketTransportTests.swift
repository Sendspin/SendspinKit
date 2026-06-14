import Foundation
import Network
@testable import SendspinKit
import Testing

private let kTestWebSocketPort = 8_927

struct NWWebSocketTransportInboundTests {
    /// Inbound transports (server dialed us; `init(connection:)` + `startReceiving()`)
    /// must promptly unblock a pending `nextFrame()` when the remote cancels
    /// abruptly. This guards the COMMON path: the in-flight receiveMessage errors
    /// out and `handleReceiveError` finishes the streams. The `stateUpdateHandler`
    /// installed by `startReceiving()` is belt-and-suspenders for the ~60s NW
    /// pathology where receiveMessage never answers on a dead connection — that
    /// pathology is non-deterministic, so it cannot be pinned by a test (see the
    /// outbound `ac44` test comment for the same trade-off).
    @Test
    func inboundAbruptRemoteCancelUnblocksNextFrame() async throws {
        let harness = InboundAcceptHarness()
        let port = try await harness.start()

        // Act as the remote server dialing the client's listener.
        let remote = try NWConnection(
            to: NWWebSocketTransport.endpoint(for: #require(URL(string: "ws://127.0.0.1:\(port)"))),
            using: NWWebSocketTransport.parameters(tls: false)
        )
        remote.start(queue: DispatchQueue(label: "inbound.test.remote"))

        // The accepted connection becomes the inbound transport (advertiser path).
        let accepted = try await harness.nextAcceptedConnection(timeout: .seconds(3))
        let transport = NWWebSocketTransport(connection: accepted)
        await transport.startReceiving()

        let frameTask = Task {
            await transport.nextFrame()
        }
        try await Task.sleep(for: .milliseconds(100))

        // Abrupt remote cancel: no close frame, just kill the socket.
        remote.cancel()

        // Bounded: a hang is a failure, not a wedge.
        let observation = await observeTask(
            frameTask,
            timeout: .seconds(2),
            onTimeout: { await transport.disconnect() }
        )
        switch observation {
        case let .completed(frame):
            #expect(frame == nil, "the unblocked nextFrame() must report end-of-stream (nil)")
        case .timedOut:
            Issue.record("nextFrame() must unblock sub-second after an abrupt remote cancel")
        }

        await transport.disconnect()
        await harness.stop()
    }
}

/// Minimal WS listener that hands accepted connections to the test instead of
/// receiving on them (unlike `LoopbackWebSocketServer`), so the test can wrap
/// one in an inbound `NWWebSocketTransport` exactly like `ClientAdvertiser` does.
private actor InboundAcceptHarness {
    private var listener: NWListener?
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var accepted: [NWConnection] = []

    func start() async throws -> UInt16 {
        let wsOptions = NWProtocolWebSocket.Options()
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleListenerState(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            // Mirror ClientAdvertiser: start the connection; the test awaits .ready.
            connection.start(queue: DispatchQueue(label: "inbound.test.accepted"))
            Task { await self?.recordAccepted(connection) }
        }

        listener.start(queue: DispatchQueue(label: "inbound.test.listener"))
        return try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
        }
    }

    /// Poll for the first accepted connection to reach `.ready`.
    func nextAcceptedConnection(timeout: Duration) async throws -> NWConnection {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let ready = accepted.first(where: { $0.state == .ready }) {
                return ready
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "InboundAcceptHarness",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "No accepted connection reached .ready within \(timeout)"]
        )
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in accepted {
            connection.cancel()
        }
        accepted.removeAll()
    }

    private func recordAccepted(_ connection: NWConnection) {
        accepted.append(connection)
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            let continuation = readyContinuation
            readyContinuation = nil
            continuation?.resume(returning: listener?.port?.rawValue ?? 0)
        case .failed, .cancelled:
            let continuation = readyContinuation
            readyContinuation = nil
            continuation?.resume(throwing: NSError(
                domain: "InboundAcceptHarness",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Listener failed to reach ready"]
            ))
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }
}

struct NWWebSocketTransportStaticHelpersTests {
    // MARK: - Endpoint URL/path/query preservation

    @Test
    func endpointPreservesPathAndQuery() {
        guard let url = URL(string: "ws://host:\(kTestWebSocketPort)/sendspin?x=1") else {
            Issue.record("Failed to create URL")
            return
        }
        let endpoint = NWWebSocketTransport.endpoint(for: url)

        guard case let .url(endpointURL) = endpoint else {
            Issue.record("Expected URL endpoint, got different type")
            return
        }

        #expect(endpointURL.path == "/sendspin")
        #expect(endpointURL.query == "x=1")
    }

    @Test
    func endpointPreservesPort() {
        guard let url = URL(string: "ws://host:\(kTestWebSocketPort)/") else {
            Issue.record("Failed to create URL")
            return
        }
        let endpoint = NWWebSocketTransport.endpoint(for: url)

        guard case let .url(endpointURL) = endpoint else {
            Issue.record("Expected URL endpoint, got different type")
            return
        }

        #expect(endpointURL.port == kTestWebSocketPort)
    }

    @Test
    func endpointPreservesScheme() {
        guard let url = URL(string: "ws://host/path") else {
            Issue.record("Failed to create URL")
            return
        }
        let endpoint = NWWebSocketTransport.endpoint(for: url)

        guard case let .url(endpointURL) = endpoint else {
            Issue.record("Expected URL endpoint, got different type")
            return
        }

        #expect(endpointURL.scheme == "ws")
    }

    // MARK: - TLS selection from scheme

    @Test
    func usesTLSReturnsTrueForWss() {
        guard let url = URL(string: "wss://host/") else {
            Issue.record("Failed to create URL")
            return
        }
        let result = NWWebSocketTransport.usesTLS(for: url)
        #expect(result == true)
    }

    @Test
    func usesTLSReturnsFalseForWs() {
        guard let url = URL(string: "ws://host/") else {
            Issue.record("Failed to create URL")
            return
        }
        let result = NWWebSocketTransport.usesTLS(for: url)
        #expect(result == false)
    }

    @Test
    func usesTLSIsCaseInsensitive() {
        guard let urlUpper = URL(string: "WSS://host/") else {
            Issue.record("Failed to create URL")
            return
        }
        guard let urlLower = URL(string: "wss://host/") else {
            Issue.record("Failed to create URL")
            return
        }
        let resultUpper = NWWebSocketTransport.usesTLS(for: urlUpper)
        let resultLower = NWWebSocketTransport.usesTLS(for: urlLower)
        #expect(resultUpper == true)
        #expect(resultLower == true)
    }

    // MARK: - Parameters creation

    @Test
    func parametersWithTLSAndWithoutTLSCreateDifferentParameters() {
        let tlsParams = NWWebSocketTransport.parameters(tls: true)
        let tcpParams = NWWebSocketTransport.parameters(tls: false)

        // Verify TLS presence is introspectable via applicationProtocols.
        let tlsHasTLS = tlsParams.defaultProtocolStack.applicationProtocols.contains {
            $0 is NWProtocolTLS.Options
        }
        #expect(
            tlsHasTLS,
            "wss params must carry TLS in the protocol stack"
        )

        let tcpHasTLS = tcpParams.defaultProtocolStack.applicationProtocols.contains {
            $0 is NWProtocolTLS.Options
        }
        #expect(
            !tcpHasTLS,
            "ws params must NOT carry TLS"
        )

        // Verify both have WebSocket in application protocols
        #expect(tlsParams.defaultProtocolStack.applicationProtocols.count > 0)
        #expect(tcpParams.defaultProtocolStack.applicationProtocols.count > 0)
    }

    @Test
    func parametersWithTLSCreatesValidParameters() {
        let params = NWWebSocketTransport.parameters(tls: true)
        // Verify we get valid parameters back with application protocols
        #expect(params.defaultProtocolStack.applicationProtocols.count > 0)
    }

    @Test
    func parametersWithoutTLSCreatesValidParameters() {
        let params = NWWebSocketTransport.parameters(tls: false)
        // Verify we get valid parameters back with application protocols
        #expect(params.defaultProtocolStack.applicationProtocols.count > 0)
    }

    // MARK: - WebSocket protocol presence

    @Test
    func parametersContainsWebSocketProtocol() {
        let params = NWWebSocketTransport.parameters(tls: false)

        // Verify WebSocket is in applicationProtocols
        var hasWebSocket = false
        for appProto in params.defaultProtocolStack.applicationProtocols
            where appProto is NWProtocolWebSocket.Options {
            hasWebSocket = true
            break
        }
        #expect(hasWebSocket == true)
    }

    @Test
    func parametersWebSocketProtocolIsFirst() {
        let params = NWWebSocketTransport.parameters(tls: false)

        // Verify WebSocket is the first application protocol (as per the phase spec)
        guard params.defaultProtocolStack.applicationProtocols.first is NWProtocolWebSocket.Options else {
            Issue.record("WebSocket options not found as first application protocol")
            return
        }
    }
}
