// ABOUTME: Represents the connection state of the Sendspin client
// ABOUTME: Used to track connection lifecycle from disconnected to connected

import Foundation

/// Errors that can put the client into an error state during streaming.
public enum ClientError: Error, Sendable, Equatable, LocalizedError {
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
}

/// Connection state of the Sendspin client
public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case error(ClientError)
}
