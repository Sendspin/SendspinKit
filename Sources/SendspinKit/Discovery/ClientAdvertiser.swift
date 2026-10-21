import Foundation
import Network
import os

/// Advertises this client via mDNS and accepts incoming WebSocket connections.
/// Single-use: `stop()` finishes the stream; create a new instance to advertise again.
public actor ClientAdvertiser {
    private let name: String?
    private let port: UInt16
    private let path: String
    private let maximumPendingConnections: Int
    private let pendingConnectionTimeout: Duration
    private let listenerFactory: @Sendable (NWParameters, NWEndpoint.Port) throws -> any ClientListenerHandle

    private var listener: (any ClientListenerHandle)?
    private var listenerToken: UUID?
    private nonisolated(unsafe) var connectionsContinuation: AsyncStream<any SendspinTransport>.Continuation?
    private var readinessWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var listenerReady = false
    private var pendingConnections: [UUID: any ClientConnectionHandle] = [:]
    private var pendingConnectionTimeouts: [UUID: Task<Void, Never>] = [:]

    /// Stream of incoming server connections, each as a ready-to-use transport.
    public nonisolated let connections: AsyncStream<any SendspinTransport>

    /// Whether the advertiser is currently listening for connections.
    public var isRunning: Bool {
        listener != nil
    }

    /// Whether this advertiser was created for the requested endpoint.
    public func matches(port requestedPort: UInt16, path requestedPath: String) -> Bool {
        port == requestedPort && path == requestedPath
    }

    /// Whether this advertiser has been permanently stopped.
    public var isTerminated: Bool {
        connectionsContinuation == nil
    }

    public init(
        name: String? = nil,
        port: UInt16 = SendspinDefaults.clientPort,
        path: String = SendspinDefaults.webSocketPath
    ) {
        self.init(
            name: name,
            port: port,
            path: path,
            listenerFactory: { parameters, port in
                try NWClientListenerHandle(listener: NWListener(using: parameters, on: port))
            }
        )
    }

    init(
        name: String?,
        port: UInt16,
        path: String,
        maximumPendingConnections: Int = clientAdvertiserPendingLimit,
        pendingConnectionTimeout: Duration = clientAdvertiserPendingConnectionTimeout,
        listenerFactory: @escaping @Sendable (NWParameters, NWEndpoint.Port) throws -> any ClientListenerHandle
    ) {
        precondition(maximumPendingConnections > 0)
        self.name = name
        self.port = port
        self.path = path
        self.maximumPendingConnections = maximumPendingConnections
        self.pendingConnectionTimeout = pendingConnectionTimeout
        self.listenerFactory = listenerFactory

        var continuation: AsyncStream<any SendspinTransport>.Continuation?
        connections = AsyncStream(
            bufferingPolicy: .bufferingOldest(maximumPendingConnections)
        ) { continuation = $0 }
        connectionsContinuation = continuation
    }

    /// Start advertising and wait for `NWListener.State.ready`, not mere construction.
    /// Failed or cancelled startup throws instead of reporting an unusable listener.
    public func start() async throws {
        if listener != nil, listenerReady {
            return
        }
        guard listener == nil else {
            try Task.checkCancellation()
            return try await waitForReadiness()
        }
        guard connectionsContinuation != nil else { throw TerminatedError() }
        guard path.hasPrefix("/") else { throw ConfigurationError.invalidWebSocketPath(path) }
        try Task.checkCancellation()

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        let nwPort: NWEndpoint.Port = port == 0
            ? .any
            // swiftlint:disable:next force_unwrapping
            : NWEndpoint.Port(rawValue: port)!
        let listener = try listenerFactory(parameters, nwPort)

        var txtRecord = NWTXTRecord()
        txtRecord["path"] = path
        if let name {
            txtRecord["name"] = name
        }
        listener.service = NWListener.Service(type: SendspinDefaults.clientServiceType, txtRecord: txtRecord)

        let token = UUID()
        listenerToken = token
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleListenerState(state, token: token) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handleNewConnection(connection, token: token) }
        }

        self.listener = listener
        listener.start(queue: .global(qos: .userInitiated))

        return try await waitForReadiness()
    }

    private func waitForReadiness() async throws {
        if listenerReady {
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readinessWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancelReadinessWaiter(waiterID) }
        }
    }

    /// Stop advertising and close pending connections. This is terminal; admitted
    /// transports already yielded from `connections` are not touched.
    public func stop() {
        terminateListener(with: CancellationError())
    }

    private func terminateStream() {
        connectionsContinuation?.finish()
        connectionsContinuation = nil
    }

    private func terminateListener(with error: Error) {
        let currentListener = listener
        listener = nil
        listenerToken = nil
        listenerReady = false
        currentListener?.stateUpdateHandler = nil
        currentListener?.newConnectionHandler = nil
        currentListener?.cancel()

        for timeout in pendingConnectionTimeouts.values {
            timeout.cancel()
        }
        pendingConnectionTimeouts.removeAll()
        for connection in pendingConnections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        pendingConnections.removeAll()

        let waiters = readinessWaiters
        readinessWaiters.removeAll()
        for continuation in waiters.values {
            continuation.resume(throwing: error)
        }
        terminateStream()
    }

    private func cancelReadinessWaiter(_ id: UUID) {
        guard let continuation = readinessWaiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
        guard readinessWaiters.isEmpty, listener != nil, !listenerReady else { return }
        terminateListener(with: CancellationError())
    }

    private func handleListenerState(_ state: ClientListenerState, token: UUID) {
        guard listenerToken == token, listener != nil else { return }
        switch state {
        case .ready:
            listenerReady = true
            let actualPort = listener?.port ?? port
            Log.discovery.info("Listening on port \(actualPort), advertising \(SendspinDefaults.clientServiceType)")
            let waiters = readinessWaiters
            readinessWaiters.removeAll()
            for continuation in waiters.values {
                continuation.resume()
            }
        case let .failed(description):
            Log.discovery.error("Listener failed: \(description)")
            terminateListener(with: ClientAdvertiserError.listenerFailed(description))
        case .cancelled:
            Log.discovery.info("Listener cancelled")
            terminateListener(with: CancellationError())
        case .setup, .waiting:
            break
        }
    }

    private func handleNewConnection(_ connection: any ClientConnectionHandle, token: UUID) {
        guard listenerToken == token, listenerReady, connectionsContinuation != nil else {
            connection.cancel()
            return
        }
        guard pendingConnections.count < maximumPendingConnections else {
            Log.discovery.warning("Rejecting inbound connection because the pending connection limit is full")
            connection.cancel()
            return
        }

        let connectionID = UUID()
        pendingConnections[connectionID] = connection
        pendingConnectionTimeouts[connectionID] = Task { [weak self, pendingConnectionTimeout] in
            do {
                try await Task.sleep(for: pendingConnectionTimeout)
            } catch {
                return
            }
            await self?.expirePendingConnection(connectionID)
        }
        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleConnectionState(state, id: connectionID) }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    private func handleConnectionState(_ state: NWConnection.State, id: UUID) async {
        guard let connection = pendingConnections[id] else { return }
        switch state {
        case .ready:
            pendingConnections.removeValue(forKey: id)
            pendingConnectionTimeouts.removeValue(forKey: id)?.cancel()
            connection.stateUpdateHandler = nil
            guard connectionsContinuation != nil, listenerReady else {
                connection.cancel()
                return
            }
            let transport = await connection.makeTransport()
            guard connectionsContinuation != nil, listenerReady else {
                await transport.disconnect()
                return
            }
            if let result = connectionsContinuation?.yield(transport), case let .dropped(dropped) = result {
                Task { await dropped.disconnect() }
            }
        case let .failed(error):
            Log.discovery.error("Incoming connection failed: \(error)")
            removePendingConnection(id, cancel: true)
        case .cancelled:
            removePendingConnection(id, cancel: false)
        case .setup, .preparing, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func expirePendingConnection(_ id: UUID) {
        guard pendingConnections[id] != nil else { return }
        Log.discovery.info("Closing inbound connection that did not become ready in time")
        removePendingConnection(id, cancel: true)
    }

    private func removePendingConnection(_ id: UUID, cancel: Bool) {
        pendingConnectionTimeouts.removeValue(forKey: id)?.cancel()
        guard let connection = pendingConnections.removeValue(forKey: id) else { return }
        connection.stateUpdateHandler = nil
        if cancel {
            connection.cancel()
        }
    }

    deinit {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        for timeout in pendingConnectionTimeouts.values {
            timeout.cancel()
        }
        for connection in pendingConnections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        for continuation in readinessWaiters.values {
            continuation.resume(throwing: CancellationError())
        }
        connectionsContinuation?.finish()
    }
}

let clientAdvertiserPendingLimit = 4
let clientAdvertiserPendingConnectionTimeout: Duration = .seconds(30)

enum ClientAdvertiserError: Error, Equatable, LocalizedError {
    case listenerFailed(String)

    var errorDescription: String? {
        switch self {
        case let .listenerFailed(description):
            "Listener failed: \(description)"
        }
    }
}

enum ClientListenerState: Sendable {
    case setup
    case waiting
    case ready
    case failed(String)
    case cancelled
}

protocol ClientListenerHandle: AnyObject, Sendable {
    var stateUpdateHandler: (@Sendable (ClientListenerState) -> Void)? { get set }
    var newConnectionHandler: (@Sendable (any ClientConnectionHandle) -> Void)? { get set }
    var service: NWListener.Service? { get set }
    var port: UInt16? { get }
    func start(queue: DispatchQueue)
    func cancel()
}

private final class NWClientListenerHandle: ClientListenerHandle, @unchecked Sendable {
    private let listener: NWListener
    private var clientStateUpdateHandler: (@Sendable (ClientListenerState) -> Void)?

    var stateUpdateHandler: (@Sendable (ClientListenerState) -> Void)? {
        get { clientStateUpdateHandler }
        set {
            clientStateUpdateHandler = newValue
            let listenerHandler: (@Sendable (NWListener.State) -> Void)? = if let newValue {
                { state in
                    newValue(Self.map(state))
                }
            } else {
                nil
            }
            listener.stateUpdateHandler = listenerHandler
        }
    }

    var newConnectionHandler: (@Sendable (any ClientConnectionHandle) -> Void)? {
        didSet {
            let handler = newConnectionHandler
            let callback: (@Sendable (NWConnection) -> Void)? = if let handler {
                { connection in handler(connection) }
            } else {
                nil
            }
            listener.newConnectionHandler = callback
        }
    }

    var service: NWListener.Service? {
        get { listener.service }
        set { listener.service = newValue }
    }

    var port: UInt16? {
        listener.port?.rawValue
    }

    init(listener: NWListener) {
        self.listener = listener
    }

    func start(queue: DispatchQueue) {
        listener.start(queue: queue)
    }

    func cancel() {
        listener.cancel()
    }

    private static func map(_ state: NWListener.State) -> ClientListenerState {
        switch state {
        case .setup: .setup
        case .waiting: .waiting
        case .ready: .ready
        case let .failed(error): .failed(String(describing: error))
        case .cancelled: .cancelled
        @unknown default: .cancelled
        }
    }
}
