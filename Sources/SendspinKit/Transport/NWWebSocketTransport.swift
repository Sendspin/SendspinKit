// ABOUTME: WebSocket transport backed by Network.framework NWConnection
// ABOUTME: Used for server-initiated connections where the server connects to the client

import Foundation
import Network

/// WebSocket transport wrapping an NWConnection (inbound, server-initiated connections).
/// Created by `ClientAdvertiser` when a server connects to the client's WebSocket endpoint.
public actor NWWebSocketTransport: SendspinTransport {
    private var connection: NWConnection?
    private let textContinuation: AsyncStream<String>.Continuation
    private let binaryContinuation: AsyncStream<Data>.Continuation

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

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TransportError.encodingFailed
        }

        let sendData = text.data(using: .utf8)
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
    private nonisolated func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }

            if let error {
                fputs("[NWTransport] receive error: \(error)\n", stderr)
                Task { await self.handleDisconnect() }
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
                    Task { await self.handleDisconnect() }
                    return
                case .ping:
                    // NWProtocolWebSocket handles pong automatically
                    break
                case .pong:
                    break
                case .cont:
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

    private func handleDisconnect() {
        connection?.cancel()
        connection = nil
        textContinuation.finish()
        binaryContinuation.finish()
    }
}
