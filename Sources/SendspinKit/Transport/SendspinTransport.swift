// ABOUTME: Protocol abstracting the WebSocket transport layer
// ABOUTME: Enables both client-initiated (Starscream) and server-initiated (NWListener) connections

import Foundation

/// Protocol for WebSocket transports used by SendspinClient.
/// Both outbound (client connects to server) and inbound (server connects to client)
/// connections conform to this protocol.
public protocol SendspinTransport: Actor, Sendable {
    /// Stream of incoming text messages (JSON payloads)
    nonisolated var textMessages: AsyncStream<String> { get }

    /// Stream of incoming binary messages (audio, artwork, visualization)
    nonisolated var binaryMessages: AsyncStream<Data> { get }

    /// Whether the transport is currently connected
    var isConnected: Bool { get }

    /// Send a JSON-encoded Sendspin message
    func send<T: SendspinMessage>(_ message: T) async throws

    /// Send raw binary data
    func sendBinary(_ data: Data) async throws

    /// Disconnect the transport
    func disconnect() async
}
