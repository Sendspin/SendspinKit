// ABOUTME: Protocol abstracting the WebSocket transport layer
// ABOUTME: Enables both client-initiated and server-initiated connections

import Foundation

/// A single incoming WebSocket frame, tagged by payload kind.
///
/// Transports surface text and binary frames through one ordered stream so the
/// exact wire order is preserved end-to-end (see ``SendspinTransport/frames``).
public enum TransportFrame: Sendable {
    /// Text frame (a JSON control message).
    case text(String)
    /// Binary frame (audio, artwork, or visualization data).
    case binary(Data)
}

/// Protocol for WebSocket transports used by SendspinClient.
/// Both outbound (client connects to server) and inbound (server connects to client)
/// connections conform to this protocol.
public protocol SendspinTransport: Actor, Sendable {
    /// Ordered stream of incoming frames, in the exact order the server sent
    /// them on the wire.
    ///
    /// - Important: Text and binary frames share one stream on purpose. Stream
    ///   lifecycle control messages (e.g. `stream/end`, which stops output and
    ///   clears buffers on receipt) must be processed *after* the audio frames
    ///   that preceded them. Splitting text and binary into separately-drained
    ///   streams would let a control message overtake still-unprocessed audio.
    nonisolated var frames: AsyncStream<TransportFrame> { get }

    /// Whether the transport is currently connected
    var isConnected: Bool { get }

    /// Send a JSON-encoded message
    func send(_ message: some Codable & Sendable) async throws

    /// Send raw binary data
    func sendBinary(_ data: Data) async throws

    /// Disconnect the transport
    func disconnect() async
}
