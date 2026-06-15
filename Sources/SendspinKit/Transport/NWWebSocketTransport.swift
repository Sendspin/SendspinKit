import Foundation
import Network
import os

/// WebSocket transport wrapping a Network.framework `NWConnection`.
///
/// Supports both inbound connections accepted by `ClientAdvertiser` and outbound
/// client-initiated dials to `ws://` / `wss://` URLs.
actor NWWebSocketTransport: SendspinTransport {
    private var connection: NWConnection?
    /// `nonisolated` so the receive callback feeds frames directly in arrival order.
    /// Hopping onto the actor via a per-frame `Task` would let independent tasks run
    /// out of order and shuffle frames (audio included). Safe as a plain `nonisolated
    /// let`: `FrameInbox` is `Sendable` and the reference never changes.
    private nonisolated let inbox = FrameInbox()
    /// Confined to actor isolation — do not pass across isolation boundaries.
    private let encoder = SendspinEncoding.makeEncoder()

    /// Per-send deadline used by `timedSend`. The default is intentionally generous
    /// (a healthy send completes in microseconds); only a wedged/dead NWConnection
    /// can plausibly hit it. `nonisolated let` so the `nonisolated` helper can read
    /// it without hopping back onto the actor mid-send.
    private nonisolated let sendTimeout: Duration

    /// Set when a WebSocket close frame is received. Used by `finishStreams()`
    /// to distinguish a clean server-initiated close from an unexpected error,
    /// so we can suppress the noisy (but expected) post-close receive error log.
    private var closeReceived = false

    /// Continuation for outbound connect awaiting `.ready` state.
    private var connectionContinuation: CheckedContinuation<Void, Error>?

    /// Initialize with an already-established NWConnection that has WebSocket framing.
    /// The connection should be in the `.ready` state.
    /// - Parameter sendTimeout: per-send deadline (see ``sendTimeout``). Tests
    ///   inject a short timeout to exercise the timed-send failure path without
    ///   waiting the production default.
    init(connection: NWConnection, sendTimeout: Duration = defaultSendTimeout) {
        self.connection = connection
        self.sendTimeout = sendTimeout
    }

    /// Initialize for outbound connection to a WebSocket URL.
    /// Call `connect()` to establish the connection.
    /// - Parameter sendTimeout: per-send deadline (see ``sendTimeout``). Tests
    ///   inject a short timeout to exercise the timed-send failure path without
    ///   waiting the production default.
    init(url: URL, sendTimeout: Duration = defaultSendTimeout) {
        let endpoint = Self.endpoint(for: url)
        let parameters = Self.parameters(tls: Self.usesTLS(for: url))
        connection = NWConnection(to: endpoint, using: parameters)
        self.sendTimeout = sendTimeout
    }

    // MARK: - Static helpers for endpoint and parameters construction

    /// Constructs an NWEndpoint from a URL, preserving scheme, host, port, path, and query.
    nonisolated static func endpoint(for url: URL) -> NWEndpoint {
        NWEndpoint.url(url)
    }

    /// Constructs NWParameters with optional TLS and WebSocket framing.
    /// - Parameters:
    ///   - tls: If true, includes TLS in the protocol stack; if false, uses TCP only.
    /// - Returns: Configured NWParameters with WebSocket application protocol.
    nonisolated static func parameters(tls: Bool) -> NWParameters {
        let params: NWParameters = tls
            ? NWParameters(tls: NWProtocolTLS.Options())
            : NWParameters.tcp

        // Create WebSocket options with autoReplyPing enabled before inserting
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        return params
    }

    /// Determines whether the URL scheme requires TLS.
    /// - Parameter url: The WebSocket URL to inspect.
    /// - Returns: true if scheme is "wss", false for "ws" or other schemes.
    nonisolated static func usesTLS(for url: URL) -> Bool {
        url.scheme?.lowercased() == "wss"
    }

    /// Connect to a remote WebSocket server (outbound path).
    /// For inbound connections, the connection is already established.
    func connect() async throws {
        guard let connection else {
            throw TransportError.connectionFailed
        }

        // Await `.ready` state via stored continuation. Install the continuation
        // before starting NWConnection so a fast `.ready`/`.failed` callback cannot
        // be dropped and leave connect() parked forever.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.connectionContinuation = continuation
            connection.stateUpdateHandler = { [weak self] state in
                Task { await self?.handleConnectionState(state) }
            }
            connection.start(queue: DispatchQueue(label: "com.sendspin.nwwebsocket", qos: .userInitiated))
        }

        startReceiving()
    }

    /// Start receiving messages from the connection.
    /// Must be called after init to begin pumping messages into the async streams.
    func startReceiving() {
        guard let connection else { return }
        // Own state observation from here (inbound path: replaces the advertiser's
        // post-ready handler, which only logs/cancels). The receive-error callback
        // surfaces death promptly in the common case, but the outbound path needed
        // three redundant finish paths to dodge a ~60s hang when receiveMessage
        // never answers on a dead connection — same belt-and-suspenders inbound.
        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleConnectionState(state) }
        }
        receiveNext(on: connection)
    }

    var isConnected: Bool {
        connection?.state == .ready
    }

    func nextFrame() async -> TransportFrame? {
        await inbox.next()
    }

    func send(_ message: some Codable & Sendable) async throws {
        // state == .ready also rejects a dead-but-non-nil connection: NW behavior
        // on a failed/cancelled connection is undefined here (raw POSIX errors,
        // or a completion that never fires — an unbounded hang).
        guard let connection, connection.state == .ready else {
            throw TransportError.notConnected
        }

        let sendData = try encoder.encode(message)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "wsText",
            metadata: [metadata]
        )

        try await timedSend(sendData, context: context, on: connection)
    }

    func sendBinary(_ data: Data) async throws {
        // Same dead-but-non-nil guard as send() above.
        guard let connection, connection.state == .ready else {
            throw TransportError.notConnected
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(
            identifier: "binary",
            metadata: [metadata]
        )

        try await timedSend(data, context: context, on: connection)
    }

    // MARK: - Timed send

    /// Send `content` with a bounded deadline. Completes on whichever of the NW
    /// completion handler, timeout, or task cancellation fires first; losers are no-ops.
    ///
    /// Two caveats worth understanding before touching this code:
    ///
    /// 1. The `guard !completion.isCompleted else { return }` below is a TOCTOU
    ///    check, not an atomic gate. A cancellation/timeout landing between the
    ///    guard and `connection.send` still lets bytes reach NW's outbound queue,
    ///    because `NWConnection.send` has no abort handle (see #2). The guard is
    ///    a best-effort suppressor that wins the common race; it is not a
    ///    correctness barrier.
    ///
    /// 2. Once `connection.send` is dispatched, Network.framework owns the bytes.
    ///    Resuming the caller via `CancellationError`/`sendTimedOut` does NOT
    ///    abort the underlying send — it only frees the awaiting task. Buffered
    ///    bytes drain (or get discarded) when the connection is cancelled. Callers
    ///    that observe `sendTimedOut` must tear the connection down rather than
    ///    retry on the same NWConnection; otherwise duplicates can appear on the
    ///    wire if the connection later recovers.
    private nonisolated func timedSend(
        _ content: Data,
        context: NWConnection.ContentContext,
        on connection: NWConnection
    ) async throws {
        let completion = SendCompletion()
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: sendTimeout)
                completion.complete(with: .failure(TransportError.sendTimedOut))
            } catch {
                // Cancelled by our defer (the send finished or was cancelled).
                // Either way the completion has already been decided — no-op.
            }
        }
        defer { timeoutTask.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                completion.install(continuation)
                // See caveat #1 on `timedSend`: best-effort, not atomic.
                guard !completion.isCompleted else { return }
                connection.send(
                    content: content,
                    contentContext: context,
                    isComplete: true,
                    completion: .contentProcessed { error in
                        if let error {
                            completion.complete(with: .failure(error))
                        } else {
                            completion.complete(with: .success(()))
                        }
                    }
                )
            }
        } onCancel: {
            completion.complete(with: .failure(CancellationError()))
        }
    }

    func disconnect() async {
        // Finish the stream before cancelling the connection so parked nextFrame()
        // callers are unblocked — cancellation alone doesn't release them.
        finishStreams()
        connection?.cancel()
        connection = nil
    }

    // MARK: - Private

    /// Recursively receive WebSocket messages from the NWConnection.
    ///
    /// On `.close` frames we set `closeReceived` but do NOT finish the stream
    /// continuations or cancel the connection. The receive loop continues —
    /// NWConnection will deliver any buffered frames and then produce an error,
    /// which calls `finishStreams()` to terminate naturally. This avoids a race
    /// between `cancel()` aborting pending receives and frames still in the buffer.
    private nonisolated func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }

            if let error {
                Task { await self.handleReceiveError(error) }
                return
            }

            // Extract WebSocket metadata to determine frame type
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata {
                switch metadata.opcode {
                case .text:
                    if let data = content, let text = String(data: data, encoding: .utf8) {
                        inbox.yield(.text(text))
                    }
                case .binary:
                    if let data = content {
                        inbox.yield(.binary(data))
                    }
                case .close:
                    // Note the close but keep receiving — data frames may be queued
                    // behind it. Streams finish when the receive loop terminates.
                    Task { await self.handleClose() }
                case .ping, .pong, .cont:
                    break
                @unknown default:
                    break
                }
            }

            receiveNext(on: connection)
        }
    }

    /// Called on WebSocket close frame. We note it but do NOT finish the stream
    /// continuations yet — data frames may still be queued behind the close in the
    /// NWConnection buffer. The streams are finished when the receive loop terminates
    /// naturally (error or connection teardown) via `finishStreams()`.
    private func handleClose() {
        closeReceived = true
    }

    /// Handle connection state changes (outbound path).
    /// On .cancelled or .failed, finish the buffer so pending nextFrame() calls unblock.
    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            let continuation = connectionContinuation
            connectionContinuation = nil
            continuation?.resume()

        case .cancelled, .failed:
            finishStreams()
            let continuation = connectionContinuation
            connectionContinuation = nil
            continuation?.resume(throwing: TransportError.connectionFailed)

        case let .waiting(error):
            // .waiting means NW will retry indefinitely until conditions change
            // (refused, unreachable, no route). A pending dial must not hang on
            // that — fail it promptly; retry policy belongs to the caller.
            // Without a pending dial (post-ready .waiting), leave the connection
            // to NWConnection's own recovery, matching previous behavior.
            guard connectionContinuation != nil else { break }
            Log.transport.error("Dial failed, connection stuck waiting: \(error)")
            let continuation = connectionContinuation
            connectionContinuation = nil
            connection?.cancel()
            connection = nil
            continuation?.resume(throwing: TransportError.connectionFailed)

        case .preparing, .setup:
            break

        @unknown default:
            break
        }
    }

    /// Called when the receive loop encounters an error.
    /// After a clean close frame, the post-close error is expected — suppress the log.
    private func handleReceiveError(_ error: NWError) {
        if !closeReceived {
            Log.transport.error("Receive error: \(error)")
        }
        finishStreams()
    }

    /// Called when the receive loop terminates (error or connection gone).
    private func finishStreams() {
        inbox.finish()
    }
}

/// Default per-send deadline. Generous: a healthy send completes in microseconds,
/// so this only fires on a wedged/dead connection. Per-transport overridable via
/// the `sendTimeout:` init parameter (tests inject a short value).
private let defaultSendTimeout: Duration = .seconds(5)

/// Coordinates completion of an `NWConnection.send` continuation.
///
/// Exactly one contender wins: Network.framework completion, our timeout, or
/// task cancellation. The winning result is retained so cancellation that fires
/// before the continuation is installed still resumes the continuation once it
/// appears; every later contender is a no-op.
///
/// Cancellation of the timeout task is the caller's responsibility (via `defer`
/// at the `timedSend` call site) — keeping it out of this type's surface lets the
/// lock guard only the two pieces of state it truly co-owns (result + continuation).
final class SendCompletion: Sendable {
    private struct State {
        var result: Result<Void, Error>?
        var continuation: CheckedContinuation<Void, Error>?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var isCompleted: Bool {
        lock.withLock { $0.result != nil }
    }

    /// Store the continuation, or resume it immediately if a result has already
    /// landed (e.g. cancellation fired before `withCheckedThrowingContinuation`
    /// even installed us).
    func install(_ continuation: CheckedContinuation<Void, Error>) {
        let result = lock.withLock { state -> Result<Void, Error>? in
            if let result = state.result {
                return result
            }
            state.continuation = continuation
            return nil
        }

        if let result {
            continuation.resume(with: result)
        }
    }

    /// Record the terminal result; resume any waiting continuation. Subsequent
    /// callers are no-ops by design — see the type doc-comment. Resumption
    /// happens after the lock is released to match `FrameInbox` / `WatermarkedSink`
    /// and to avoid resuming a continuation under a held unfair lock.
    func complete(with result: Result<Void, Error>) {
        let continuation = lock.withLock { state -> CheckedContinuation<Void, Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }

        continuation?.resume(with: result)
    }
}
