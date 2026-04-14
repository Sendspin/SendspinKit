// ABOUTME: Public types emitted by SendspinClient via events and properties
// ABOUTME: Includes playback state, metadata, controller state, and event definitions

import Foundation

/// Playback state of a Sendspin group.
///
/// Per spec, only `playing` and `stopped` exist on the wire. Paused playback
/// is represented as `playing` with `PlaybackProgress.playbackSpeedX1000 == 0`.
public enum PlaybackState: String, Sendable {
    case playing
    case stopped
}

/// Repeat mode for playback queue.
///
/// Values match the wire format: `'off'`, `'one'`, `'all'`.
public enum RepeatMode: String, Sendable {
    case off
    case one
    case all
}

/// Controller command identifiers per spec.
///
/// Raw values match the wire format exactly (e.g. `"repeat_off"`, `"switch"`).
/// Used in `supported_commands` arrays and `client/command` messages.
public enum ControllerCommandType: String, Sendable, Hashable {
    case play, pause, stop, next, previous
    case volume, mute
    case repeatOff = "repeat_off"
    case repeatOne = "repeat_one"
    case repeatAll = "repeat_all"
    case shuffle, unshuffle
    case `switch`
}

/// Why the client disconnected
public enum DisconnectReason: Sendable, Equatable {
    /// Client explicitly disconnected (via `disconnect()`)
    case explicit(GoodbyeReason)
    /// Connection was lost (WebSocket dropped, network error)
    case connectionLost
}

public enum ClientEvent: Sendable, Equatable {
    case serverConnected(ServerInfo)
    case streamStarted(AudioFormatSpec)
    /// Format changed mid-stream (e.g. after a `stream/request-format` request)
    case streamFormatChanged(AudioFormatSpec)
    case streamEnded
    case groupUpdated(GroupInfo)
    case metadataReceived(TrackMetadata)
    case controllerStateUpdated(ControllerState)
    case artworkStreamStarted([StreamArtworkChannelConfig])
    case artworkReceived(channel: Int, data: Data)
    case visualizerData(Data)
    /// Raw audio chunk bytes exactly as received from the server (before decoding).
    /// For PCM streams, this is the raw PCM samples. For FLAC streams, these are
    /// encoded FLAC frames. Only emitted when ``PlayerConfiguration/emitRawAudioEvents``
    /// is `true`.
    ///
    /// `serverTimestamp` is microseconds in the server's clock domain (same as
    /// ``PlaybackProgress/timestamp``).
    case rawAudioChunk(data: Data, serverTimestamp: Int64)
    /// Server changed the static delay via `server/command`. The host app should
    /// persist this value and pass it back as `initialStaticDelayMs` on next launch.
    case staticDelayChanged(milliseconds: Int)
    /// Client disconnected from the server (connection lost or explicit disconnect)
    case disconnected(reason: DisconnectReason)
}

/// Server information received during the handshake.
///
/// Constructed internally by `SendspinClient` — consumers observe these
/// via ``ClientEvent/serverConnected(_:)``.
public struct ServerInfo: Sendable, Hashable {
    public let serverId: String
    public let name: String
    public let version: Int
    public let connectionReason: ConnectionReason
}

/// Group membership and playback state update.
///
/// Constructed internally by `SendspinClient` — consumers observe these
/// via ``ClientEvent/groupUpdated(_:)``.
public struct GroupInfo: Sendable, Hashable {
    public let groupId: String
    public let groupName: String
    public let playbackState: PlaybackState?
}

/// Playback progress information.
/// Use `currentPositionMs(at:)` to get the real-time interpolated position.
///
/// Constructed internally by `SendspinClient` — consumers observe these
/// via ``TrackMetadata/progress``.
public struct PlaybackProgress: Sendable, Hashable {
    /// Playback position in milliseconds at the time of the metadata update
    public let trackProgressMs: Int
    /// Total track length in milliseconds (0 = unknown/unlimited, e.g. live radio)
    public let trackDurationMs: Int
    /// Playback speed multiplier × 1000 (1000 = normal, 1500 = 1.5×, 0 = paused)
    public let playbackSpeedX1000: Int
    /// Server timestamp (microseconds) when this progress was valid
    public let timestamp: Int64

    /// Playback speed as a floating-point multiplier (1.0 = normal speed).
    public var playbackSpeedMultiplier: Double {
        Double(playbackSpeedX1000) / 1_000.0
    }

    /// Calculate the current playback position in milliseconds.
    /// Interpolates from the last known position using the playback speed.
    /// - Parameter currentTimeMicros: Current time in microseconds
    ///   (same clock domain as `timestamp`)
    public func currentPositionMs(at currentTimeMicros: Int64) -> Int64 {
        let elapsed = currentTimeMicros - timestamp
        let calculated = Int64(trackProgressMs)
            + elapsed * Int64(playbackSpeedX1000) / 1_000_000
        if trackDurationMs != 0 {
            return max(min(calculated, Int64(trackDurationMs)), 0)
        }
        return max(calculated, 0)
    }
}

/// Track metadata from the server.
///
/// Constructed internally by `SendspinClient` — consumers observe these
/// via ``ClientEvent/metadataReceived(_:)``.
public struct TrackMetadata: Sendable, Hashable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let albumArtist: String?
    public let track: Int?
    public let year: Int?
    /// URL to artwork image as provided by the server. Useful for forwarding
    /// metadata to external systems or for clients that fetch images themselves.
    public let artworkURL: String?
    public let progress: PlaybackProgress?
    public let repeatMode: RepeatMode?
    public let shuffle: Bool?
}

/// Controller state from the server.
///
/// Constructed internally by `SendspinClient` — consumers observe these
/// via ``ClientEvent/controllerStateUpdated(_:)``.
public struct ControllerState: Sendable, Hashable {
    /// Commands the server currently supports. Check membership with `contains`
    /// to determine which UI controls to enable.
    public let supportedCommands: Set<ControllerCommandType>
    /// Group volume, range 0–100 per spec (average of all player volumes).
    /// Clamped on construction from server messages.
    public let volume: Int
    /// Group mute state (`true` only when all players in the group are muted)
    public let muted: Bool
}

/// Errors thrown by `SendspinClient` methods.
///
/// Currently minimal — additional cases will be added as command methods
/// grow. Runtime errors during streaming surface as
/// ``ConnectionState/error(_:)`` with a typed ``ClientError`` payload.
public enum SendspinClientError: Error, LocalizedError {
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            "Not connected to a Sendspin server"
        }
    }
}
