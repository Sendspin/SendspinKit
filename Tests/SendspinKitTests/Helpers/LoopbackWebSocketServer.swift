import Foundation
import Network

/// Run `body` against a started `LoopbackWebSocketServer` and guarantee `stop()`
/// before returning — including when `body` throws.
///
/// Swift has no async `defer`, so every direct caller of `LoopbackWebSocketServer`
/// would otherwise need to thread `await server.stop()` through each early-return
/// path manually. Wrapping the lifecycle here keeps each test focused on the
/// actual behavior under test and makes a forgotten `stop()` impossible.
func withLoopbackServer<Result>(
    _ body: (_ server: LoopbackWebSocketServer, _ port: UInt16) async throws -> Result
) async throws -> Result {
    let server = LoopbackWebSocketServer()
    let port = try await server.start()
    do {
        let result = try await body(server, port)
        await server.stop()
        return result
    } catch {
        await server.stop()
        throw error
    }
}

/// A simple loopback WebSocket server for testing NWWebSocketTransport outbound connections.
actor LoopbackWebSocketServer {
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var readyContinuation: CheckedContinuation<Void, Error>?
    /// Hold references to connections so they stay alive (don't get deallocated immediately)
    private var activeConnections: [NWConnection] = []

    /// Start the server on an ephemeral port.
    /// - Returns: The port the server is listening on.
    func start() async throws -> UInt16 {
        guard listener == nil else {
            throw NSError(domain: "LoopbackWebSocketServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Already started"])
        }

        // Configure WebSocket protocol options
        let wsOptions = NWProtocolWebSocket.Options()

        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleListenerState(state) }
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handleNewConnection(connection) }
        }

        listener.start(queue: DispatchQueue(label: "loopback.websocket.server"))

        // Await listener reaching .ready before returning the port
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.readyContinuation = continuation
        }

        return port
    }

    /// Stop the server.
    func stop() async {
        listener?.cancel()
        listener = nil
        for conn in activeConnections {
            conn.cancel()
        }
        activeConnections.removeAll()
    }

    // MARK: - Private

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port {
                self.port = port.rawValue
            }
            let continuation = readyContinuation
            readyContinuation = nil
            continuation?.resume()

        case .failed, .cancelled:
            let continuation = readyContinuation
            readyContinuation = nil
            continuation?.resume(throwing: NSError(
                domain: "LoopbackWebSocketServer",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Listener failed to reach ready state"]
            ))

        case .setup, .waiting:
            break

        @unknown default:
            break
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        // Keep a strong reference to the connection so it doesn't get deallocated
        activeConnections.append(connection)

        // Set up state handler to start receiving (creating an in-flight receiveMessage)
        connection.stateUpdateHandler = { [weak self] state in
            if state == .ready {
                // Start an in-flight receive so cancel() on the client side will truly block
                // on an in-flight NWConnection.receiveMessage. This call will hang on the
                // server side until the connection is cancelled externally.
                Task { await self?.startReceivingOnConnection(connection) }
            }
        }

        connection.start(queue: DispatchQueue(label: "loopback.websocket.connection"))
    }

    private func startReceivingOnConnection(_ connection: NWConnection) {
        // Issue a receiveMessage that will block indefinitely, simulating the server
        // waiting for client data. This creates a real in-flight receive scenario.
        connection.receiveMessage { _, _, _, _ in
            // This callback will not fire until the connection is cancelled or fails.
            // That's the point: we want the receiveMessage to be in-flight when the
            // client disconnects, so we can test if the mitigation (finishStreams())
            // is needed to unblock the client's pending nextFrame().
        }
    }
}
