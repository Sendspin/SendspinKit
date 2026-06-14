// ABOUTME: Protocol abstracting the WebSocket transport layer
// ABOUTME: Enables both client-initiated and server-initiated connections

import Foundation

/// A single incoming WebSocket frame, tagged by payload kind.
///
/// Transports deliver text and binary frames through one ordered pull interface so the
/// exact wire order is preserved end-to-end.
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
    /// Pull the next incoming frame from the transport.
    ///
    /// `nextFrame()` is single-consumer: at most one task may call it in-flight at any time.
    /// Overlapping calls are a contract violation and will trap via precondition.
    ///
    /// When the transport closes, `nextFrame()` returns `nil`. Once `nil` is returned,
    /// subsequent calls return `nil` as well.
    ///
    /// Frames are delivered in the exact order the server sent them on the wire. Text and
    /// binary frames share the pull interface on purpose. Stream lifecycle control messages
    /// (e.g. `stream/end`, which stops output and clears buffers on receipt) must be
    /// processed *after* the audio frames that preceded them. Merging text and binary into
    /// one ordered pull interface preserves this ordering — a control message cannot overtake
    /// still-unprocessed audio frames.
    ///
    /// Frame ownership transfers across handshake → message-loop boundaries: the handshake
    /// stops pulling (returns), then the message loop starts pulling the same transport.
    /// Because both run on the caller's MainActor sequence, there is no overlap.
    /// The pull interface eliminates the need to cancel and restart the stream on promotion.
    func nextFrame() async -> TransportFrame?

    /// Whether the transport is currently connected
    var isConnected: Bool { get }

    /// Send a JSON-encoded message
    func send(_ message: some Codable & Sendable) async throws

    /// Send raw binary data
    func sendBinary(_ data: Data) async throws

    /// Disconnect the transport
    func disconnect() async
}
