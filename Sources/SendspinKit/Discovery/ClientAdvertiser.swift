// ABOUTME: mDNS advertisement and WebSocket server for server-initiated connections
// ABOUTME: Advertises _sendspin._tcp and accepts incoming server WebSocket connections

import Foundation
import Network

/// Advertises this client via mDNS and accepts incoming WebSocket connections from servers.
///
/// This implements the spec's recommended "Server Initiated Connections" flow:
/// the client advertises `_sendspin._tcp.local.` via Bonjour, and servers discover
/// and connect to the client via WebSocket.
///
/// Once ``stop()`` is called, the ``connections`` stream is finished and cannot be
/// restarted. Create a new `ClientAdvertiser` instance to advertise again.
///
/// Usage:
/// ```swift
/// let advertiser = ClientAdvertiser(name: "Living Room Speaker")
/// try advertiser.start()
///
/// for await transport in advertiser.connections {
///     try await client.acceptConnection(transport)
/// }
/// ```
public actor ClientAdvertiser {
    /// Friendly name advertised in TXT records
    private let name: String?
    /// Port to listen on
    private let port: UInt16
    /// WebSocket endpoint path
    private let path: String

    private var listener: NWListener?
    /// Marked `nonisolated(unsafe)` because it is accessed in `deinit` (non-isolated).
    /// `AsyncStream.Continuation` is thread-safe; `finish()` is safe to call from any context.
    private nonisolated(unsafe) var connectionsContinuation: AsyncStream<any SendspinTransport>.Continuation?
    private var consecutiveFailures = 0
    private static let maxConsecutiveFailures = 3

    /// Stream of incoming server connections, each as a ready-to-use transport.
    public nonisolated let connections: AsyncStream<any SendspinTransport>

    /// Whether the advertiser is currently listening for connections.
    public var isRunning: Bool {
        listener != nil
    }

    /// Whether this advertiser has been permanently stopped.
    /// Once `true`, ``start()`` will throw and a new instance must be created.
    public var isTerminated: Bool {
        connectionsContinuation == nil
    }

    /// Create a client advertiser.
    /// - Parameters:
    ///   - name: Friendly name for this client (advertised in TXT records, optional)
    ///   - port: Port to listen on (default: ``SendspinDefaults/clientPort``). Pass 0 for OS-assigned port.
    ///   - path: WebSocket endpoint path (default: ``SendspinDefaults/webSocketPath``)
    public init(
        name: String? = nil,
        port: UInt16 = SendspinDefaults.clientPort,
        path: String = SendspinDefaults.webSocketPath
    ) {
        self.name = name
        self.port = port
        self.path = path

        var continuation: AsyncStream<any SendspinTransport>.Continuation?
        connections = AsyncStream { continuation = $0 }
        connectionsContinuation = continuation
    }

    /// Start advertising and listening for server connections.
    /// - Throws: ``TerminatedError`` if this instance has been permanently stopped.
    public func start() throws {
        guard listener == nil else { return }
        guard connectionsContinuation != nil else { throw TerminatedError() }

        // Configure WebSocket protocol options on top of TCP.
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true

        // Build parameters: TCP base with WebSocket application protocol
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        // NWEndpoint.Port(rawValue:) only returns nil for 0, handled by the .any branch.
        let nwPort: NWEndpoint.Port = port == 0
            ? .any
            // swiftlint:disable:next force_unwrapping
            : NWEndpoint.Port(rawValue: port)!

        let listener = try NWListener(using: parameters, on: nwPort)

        // Build TXT record for Bonjour advertisement
        var txtRecord = NWTXTRecord()
        txtRecord["path"] = path
        if let name {
            txtRecord["name"] = name
        }

        listener.service = NWListener.Service(
            type: SendspinDefaults.clientServiceType,
            txtRecord: txtRecord
        )

        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleListenerState(state) }
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handleNewConnection(connection) }
        }

        self.listener = listener
        listener.start(queue: .global(qos: .userInitiated))
    }

    /// Stop advertising and close all pending connections.
    /// Finishes the ``connections`` stream — any `for await` loop consuming it will exit.
    /// This is terminal; create a new instance to advertise again.
    public func stop() {
        listener?.cancel()
        listener = nil
        terminateStream()
    }

    // MARK: - Private

    /// Finish the connections stream and nil out the continuation, making this
    /// advertiser permanently unable to yield new connections.
    private func terminateStream() {
        connectionsContinuation?.finish()
        connectionsContinuation = nil
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            consecutiveFailures = 0
            let actualPort = listener?.port?.rawValue ?? port
            fputs("[ClientAdvertiser] listening on port \(actualPort), advertising \(SendspinDefaults.clientServiceType)\n", stderr)
        case let .failed(error):
            fputs("[ClientAdvertiser] listener failed: \(error)\n", stderr)
            listener?.cancel()
            listener = nil

            consecutiveFailures += 1
            guard consecutiveFailures < Self.maxConsecutiveFailures else {
                fputs(
                    "[ClientAdvertiser] \(consecutiveFailures) consecutive failures — giving up\n",
                    stderr
                )
                terminateStream()
                return
            }
            do {
                try start()
            } catch {
                fputs("[ClientAdvertiser] restart failed: \(error) — giving up\n", stderr)
                terminateStream()
            }
        case .cancelled:
            fputs("[ClientAdvertiser] listener cancelled\n", stderr)
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        fputs("[ClientAdvertiser] incoming connection from \(connection.endpoint)\n", stderr)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { await self?.connectionReady(connection) }
            case let .failed(error):
                fputs("[ClientAdvertiser] connection from \(connection.endpoint) failed: \(error)\n", stderr)
                connection.cancel()
            case .cancelled:
                break
            case .setup, .preparing, .waiting:
                break
            @unknown default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
    }

    private func connectionReady(_ connection: NWConnection) async {
        let transport = NWWebSocketTransport(connection: connection)
        // Start the receive loop before yielding so consumers don't miss early frames.
        // There's an unavoidable actor-hop gap between NWConnection reporting .ready
        // and this method executing; NWConnection buffers incoming WebSocket frames
        // during that window, so no data is lost.
        await transport.startReceiving()
        connectionsContinuation?.yield(transport)
    }

    // Callers should call stop() before releasing. The cancel/finish calls
    // below are thread-safe no-ops if stop() was already called.
    deinit {
        listener?.cancel()
        connectionsContinuation?.finish()
    }
}
