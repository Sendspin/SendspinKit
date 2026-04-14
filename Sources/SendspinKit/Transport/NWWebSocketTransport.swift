// ABOUTME: WebSocket transport backed by Network.framework NWConnection
// ABOUTME: Used for server-initiated connections where the server connects to the client

import Foundation
import Network
import os

/// WebSocket transport wrapping an NWConnection (inbound, server-initiated connections).
/// Created by `ClientAdvertiser` when a server connects to the client's WebSocket endpoint.
public actor NWWebSocketTransport: SendspinTransport {
    private var connection: NWConnection?
    private let textContinuation: AsyncStream<String>.Continuation
    private let binaryContinuation: AsyncStream<Data>.Continuation
    /// Confined to actor isolation — do not pass across isolation boundaries.
    private let encoder = SendspinEncoding.makeEncoder()

    /// Set when a WebSocket close frame is received. Used by `finishStreams()`
    /// to distinguish a clean server-initiated close from an unexpected error,
    /// so we can suppress the noisy (but expected) post-close receive error log.
    private var closeReceived = false

    public nonisolated let textMessages: AsyncStream<String>
    public nonisolated let binaryMessages: AsyncStream<Data>

    /// Initialize with an already-established NWConnection that has WebSocket framing.
    /// The connection should be in the `.ready` state.
    public init(connection: NWConnection) {
        self.connection = connection

        let (textStream, textCont) = AsyncStream<String>.makeStream()
        let (binaryStream, binaryCont) = AsyncStream<Data>.makeStream()
        textMessages = textStream
        binaryMessages = binaryStream
        textContinuation = textCont
        binaryContinuation = binaryCont
    }

    /// Start receiving messages from the connection.
    /// Must be called after init to begin pumping messages into the async streams.
    public func startReceiving() {
        guard let connection else { return }
        receiveNext(on: connection)
    }

    public var isConnected: Bool {
        connection?.state == .ready
    }

    public func send(_ message: some Codable & Sendable) async throws {
        guard let connection else {
            throw TransportError.notConnected
        }

        let sendData = try encoder.encode(message)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "wsText",
            metadata: [metadata]
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: sendData,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    public func sendBinary(_ data: Data) async throws {
        guard let connection else {
            throw TransportError.notConnected
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(
            identifier: "binary",
            metadata: [metadata]
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    public func disconnect() async {
        connection?.cancel()
        connection = nil
        textContinuation.finish()
        binaryContinuation.finish()
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
                        Task { await self.yieldText(text) }
                    }
                case .binary:
                    if let data = content {
                        Task { await self.yieldBinary(data) }
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

            // Continue receiving
            receiveNext(on: connection)
        }
    }

    private func yieldText(_ text: String) {
        textContinuation.yield(text)
    }

    private func yieldBinary(_ data: Data) {
        binaryContinuation.yield(data)
    }

    /// Called on WebSocket close frame. We note it but do NOT finish the stream
    /// continuations yet — data frames may still be queued behind the close in the
    /// NWConnection buffer. The streams are finished when the receive loop terminates
    /// naturally (error or connection teardown) via `finishStreams()`.
    private func handleClose() {
        closeReceived = true
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
        textContinuation.finish()
        binaryContinuation.finish()
    }
}
