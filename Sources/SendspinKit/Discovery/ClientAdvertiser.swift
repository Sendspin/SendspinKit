// ABOUTME: mDNS advertisement and WebSocket server for server-initiated connections
// ABOUTME: Advertises _sendspin._tcp.local. and accepts incoming server WebSocket connections

import Foundation
import Network

/// Advertises this client via mDNS and accepts incoming WebSocket connections from servers.
///
/// This implements the spec's recommended "Server Initiated Connections" flow:
/// the client advertises `_sendspin._tcp.local.` via Bonjour, and servers discover
/// and connect to the client via WebSocket.
///
/// Usage:
/// ```swift
/// let advertiser = ClientAdvertiser(name: "Living Room Speaker", port: 8928)
/// await advertiser.start()
///
/// for await transport in advertiser.connections {
///     try await client.acceptConnection(transport)
/// }
/// ```
public actor ClientAdvertiser {
    /// Friendly name advertised in TXT records
    private let name: String?
    /// Port to listen on (spec recommends 8928)
    private let port: UInt16
    /// WebSocket endpoint path (spec recommends "/sendspin")
    private let path: String

    private var listener: NWListener?
    private var connectionsContinuation: AsyncStream<any SendspinTransport>.Continuation?

    /// Stream of incoming server connections, each as a ready-to-use transport.
    public nonisolated let connections: AsyncStream<any SendspinTransport>

    /// Whether the advertiser is currently running
    public var isRunning: Bool {
        listener != nil
    }

    /// Create a client advertiser.
    /// - Parameters:
    ///   - name: Friendly name for this client (advertised in TXT records, optional)
    ///   - port: Port to listen on (default: 8928 per spec)
    ///   - path: WebSocket endpoint path (default: "/sendspin" per spec)
    public init(name: String? = nil, port: UInt16 = 8928, path: String = "/sendspin") {
        self.name = name
        self.port = port
        self.path = path

        var continuation: AsyncStream<any SendspinTransport>.Continuation?
        connections = AsyncStream { continuation = $0 }
        connectionsContinuation = continuation
    }

    /// Start advertising and listening for server connections.
    public func start() throws {
        guard listener == nil else { return }

        // Configure WebSocket protocol options on top of TCP.
        // setClientRequestHandler tells NWProtocolWebSocket to accept
        // incoming HTTP Upgrade requests (server-side WebSocket handshake).
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        // NOTE: Not setting clientRequestHandler — NWProtocolWebSocket
        // auto-accepts WebSocket upgrade requests by default on the server side.

        // Build parameters: TCP base with WebSocket application protocol
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

        // Advertise via Bonjour with TXT records
        let txtItems: [(key: String, value: String)] = {
            var items = [("path", path)]
            if let name = name {
                items.append(("name", name))
            }
            return items
        }()

        // Build raw TXT record data per DNS-SD spec:
        // each entry is a length-prefixed "key=value" string
        var txtData = Data()
        for (key, value) in txtItems {
            let entry = "\(key)=\(value)"
            let entryData = Data(entry.utf8)
            txtData.append(UInt8(entryData.count))
            txtData.append(entryData)
        }

        listener.service = NWListener.Service(
            type: "_sendspin._tcp",
            txtRecord: txtData
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
    public func stop() {
        listener?.cancel()
        listener = nil
        connectionsContinuation?.finish()
    }

    // MARK: - Private

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            let actualPort = listener?.port?.rawValue ?? port
            fputs("[ClientAdvertiser] listening on port \(actualPort), advertising _sendspin._tcp\n", stderr)
        case let .failed(error):
            fputs("[ClientAdvertiser] listener failed: \(error)\n", stderr)
            // Try to restart
            listener?.cancel()
            listener = nil
            try? start()
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

    private func connectionReady(_ connection: NWConnection) {
        let transport = NWWebSocketTransport(connection: connection)
        let continuation = connectionsContinuation

        // Start the receive loop before yielding so nothing is missed
        Task {
            await transport.startReceiving()
            continuation?.yield(transport)
        }
    }

    deinit {
        listener?.cancel()
        connectionsContinuation?.finish()
    }
}
