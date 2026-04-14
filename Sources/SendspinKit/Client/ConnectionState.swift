// ABOUTME: Represents the connection state of the Sendspin client
// ABOUTME: Used to track connection lifecycle from disconnected to connected

import Foundation

/// Errors that occur during an active stream, putting the client into a degraded state.
///
/// These are distinct from ``SendspinClientError``, which covers API-level errors
/// like calling methods while disconnected. ``StreamingError`` represents conditions
/// where the connection is alive but playback cannot proceed.
public enum StreamingError: Error, Sendable, Hashable, LocalizedError, CustomDebugStringConvertible {
    /// Server sent a codec this client doesn't support
    case unsupportedCodec(String)
    /// AudioQueue failed to start (e.g. no audio device available)
    case audioStartFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedCodec(codec):
            "Unsupported codec: \(codec)"
        case let .audioStartFailed(reason):
            "Failed to start audio: \(reason)"
        }
    }

    public var debugDescription: String {
        switch self {
        case let .unsupportedCodec(codec):
            "StreamingError.unsupportedCodec(\(codec))"
        case let .audioStartFailed(reason):
            "StreamingError.audioStartFailed(\(reason))"
        }
    }
}

/// Connection state of the Sendspin client
public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case error(StreamingError)
}
