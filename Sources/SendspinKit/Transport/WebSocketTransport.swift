// ABOUTME: WebSocket transport layer for Sendspin protocol communication
// ABOUTME: Provides AsyncStreams for text (JSON) and binary messages

import Foundation
import os
import Starscream

/// Mutable state shared between the actor and the Starscream callback queue.
/// Protected by `OSAllocatedUnfairLock` so `StarscreamDelegate` can be
/// properly `Sendable` without `@unchecked`.
private struct DelegateState {
    var connectionContinuation: CheckedContinuation<Void, Error>?
    var connected: Bool = false
}

/// Delegate to handle WebSocket events and receiving.
///
/// All mutable state lives in a lock-protected `DelegateState`, making this
/// class genuinely `Sendable` — no `@unchecked` needed. The lock is held
/// briefly (just setting a bool or consuming a continuation), so contention
/// is negligible.
private final class StarscreamDelegate: WebSocketDelegate, Sendable {
    let textContinuation: AsyncStream<String>.Continuation
    let binaryContinuation: AsyncStream<Data>.Continuation
    let state = OSAllocatedUnfairLock(initialState: DelegateState())

    init(textContinuation: AsyncStream<String>.Continuation, binaryContinuation: AsyncStream<Data>.Continuation) {
        self.textContinuation = textContinuation
        self.binaryContinuation = binaryContinuation
    }

    /// Whether the WebSocket is connected. Thread-safe read.
    var isConnected: Bool {
        state.withLock { $0.connected }
    }

    func didReceive(event: WebSocketEvent, client _: any WebSocketClient) {
        switch event {
        case .connected:
            let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
                state.connected = true
                let cont = state.connectionContinuation
                state.connectionContinuation = nil
                return cont
            }
            continuation?.resume()

        case let .disconnected(reason, code):
            handleDisconnection(error: TransportError.disconnected(reason: reason, code: code))

        case .cancelled, .peerClosed:
            handleDisconnection(error: TransportError.connectionFailed)

        case let .error(error):
            handleDisconnection(error: error ?? TransportError.connectionFailed)

        case let .text(string):
            textContinuation.yield(string)

        case let .binary(data):
            binaryContinuation.yield(data)

        case .ping, .pong, .viabilityChanged, .reconnectSuggested:
            break
        }
    }

    // MARK: - Disconnection (called by Starscream callbacks AND the actor's disconnect())

    /// Mark as disconnected, finish streams, and resume any pending connection
    /// continuation.
    ///
    /// The continuation is consumed under the lock, then resumed outside it
    /// to avoid deadlock if the resumed task synchronously re-enters.
    /// Multiple concurrent calls are safe: the lock ensures only one caller
    /// gets the continuation, and `AsyncStream.Continuation.finish()` is
    /// idempotent.
    func handleDisconnection(error: Error) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
            state.connected = false
            let cont = state.connectionContinuation
            state.connectionContinuation = nil
            return cont
        }
        continuation?.resume(throwing: error)
        textContinuation.finish()
        binaryContinuation.finish()
    }
}

/// WebSocket transport for Sendspin protocol (outbound, client-initiated connections)
actor WebSocketTransport: SendspinTransport {
    private nonisolated let delegate: StarscreamDelegate
    private var webSocket: WebSocket?
    private let url: URL

    /// Confined to actor isolation — do not pass across isolation boundaries.
    private let encoder = SendspinEncoding.makeEncoder()

    /// Stream of incoming text messages (JSON)
    nonisolated let textMessages: AsyncStream<String>

    /// Stream of incoming binary messages (audio, artwork, etc.)
    nonisolated let binaryMessages: AsyncStream<Data>

    init(url: URL) {
        self.url = url

        // Create streams and pass continuations to delegate
        let (textStream, textCont) = AsyncStream<String>.makeStream()
        let (binaryStream, binaryCont) = AsyncStream<Data>.makeStream()

        textMessages = textStream
        binaryMessages = binaryStream
        delegate = StarscreamDelegate(textContinuation: textCont, binaryContinuation: binaryCont)
    }

    /// Connect to the WebSocket server
    /// - Throws: TransportError if already connected or connection fails
    func connect() async throws {
        // Prevent multiple connections
        guard webSocket == nil else {
            throw TransportError.alreadyConnected
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        // Create socket with delegate callbacks on background queue
        // Note: Cannot use DispatchQueue.main in CLI apps without RunLoop
        let socket = WebSocket(request: request)
        socket.callbackQueue = DispatchQueue(label: "com.sendspin.websocket", qos: .userInitiated)
        socket.delegate = delegate

        webSocket = socket

        // Store the continuation under the lock, then kick off connect().
        // If Starscream fires .connected synchronously (unlikely but not contractually
        // impossible), CheckedContinuation handles resume-before-suspension correctly.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.state.withLock { $0.connectionContinuation = continuation }
            socket.connect()
        }
    }

    /// Whether the underlying WebSocket connection is alive.
    /// Reads from the lock-protected delegate state — `nonisolated` because
    /// the lock is the actual synchronization mechanism, not actor isolation.
    nonisolated var isConnected: Bool {
        delegate.isConnected
    }

    /// Send a text message (JSON).
    ///
    /// Note: the `isConnected` check is best-effort — the connection could drop
    /// between the guard and the write (inherent TOCTOU). Starscream handles
    /// writes to a closing socket gracefully (they're silently dropped).
    func send(_ message: some Codable & Sendable) async throws {
        guard let webSocket, isConnected else {
            throw TransportError.notConnected
        }

        // JSONEncoder always produces valid UTF-8.
        let data = try encoder.encode(message)
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: data, as: UTF8.self)
        webSocket.write(string: text)
    }

    /// Send a binary message
    func sendBinary(_ data: Data) async throws {
        guard let webSocket, isConnected else {
            throw TransportError.notConnected
        }
        webSocket.write(data: data)
    }

    /// Disconnect from server.
    /// Delegates to `handleDisconnection` on the delegate for consistent
    /// state management, then nils out the socket.
    func disconnect() async {
        webSocket?.disconnect()
        webSocket = nil
        delegate.handleDisconnection(error: CancellationError())
    }
}

/// Errors that can occur during WebSocket transport.
///
/// `errorDescription` delegates to `description` — keep both in sync when adding cases.
enum TransportError: LocalizedError, CustomStringConvertible {
    /// WebSocket is not connected — call connect() first
    case notConnected

    /// Already connected — call disconnect() before reconnecting
    case alreadyConnected

    /// Connection failed during handshake
    case connectionFailed

    /// WebSocket was disconnected by the remote peer
    case disconnected(reason: String, code: UInt16)

    var description: String {
        switch self {
        case .notConnected: "WebSocket is not connected"
        case .alreadyConnected: "WebSocket is already connected"
        case .connectionFailed: "WebSocket connection failed"
        case let .disconnected(reason, code): "WebSocket disconnected (code \(code): \(reason))"
        }
    }

    var errorDescription: String? {
        description
    }
}
