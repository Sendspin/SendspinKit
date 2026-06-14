// ABOUTME: Errors that can occur during WebSocket transport

import Foundation

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

    /// An outbound send did not complete within the send deadline. NWConnection's
    /// `send` completion may never fire on a connection that dies after the
    /// `.ready` guard, so the send is time-boxed to avoid an unbounded hang.
    case sendTimedOut

    var description: String {
        switch self {
        case .notConnected: "WebSocket is not connected"
        case .alreadyConnected: "WebSocket is already connected"
        case .connectionFailed: "WebSocket connection failed"
        case .sendTimedOut: "WebSocket send timed out"
        }
    }

    var errorDescription: String? {
        description
    }
}
