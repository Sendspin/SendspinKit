// ABOUTME: Public types emitted by SendspinClient via events and properties
// ABOUTME: Includes playback state, metadata, controller state, and event definitions

import Foundation

/// Playback state of a Sendspin group
public enum PlaybackState: String, Sendable {
    case playing
    case stopped
}

/// Controller commands per spec
public enum ControllerCommandType: String, Sendable {
    case play, pause, stop, next, previous
    case volume, mute
    case repeatOff = "repeat_off"
    case repeatOne = "repeat_one"
    case repeatAll = "repeat_all"
    case shuffle, unshuffle
    case `switch`
}

public enum ClientEvent: Sendable {
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
    /// Server changed the static delay via `server/command`. The host app should
    /// persist this value and pass it back as `initialStaticDelayMs` on next launch.
    case staticDelayChanged(Int)
    /// Client disconnected from the server (connection lost or explicit disconnect)
    case disconnected(reason: DisconnectReason)
    case error(String)
}

/// Why the client disconnected
public enum DisconnectReason: Sendable {
    /// Client explicitly disconnected (via `disconnect()`)
    case explicit(GoodbyeReason)
    /// Connection was lost (WebSocket dropped, network error)
    case connectionLost
}

public struct ServerInfo: Sendable {
    public let serverId: String
    public let name: String
    public let version: Int
    public let connectionReason: ConnectionReason
}

public struct GroupInfo: Sendable {
    public let groupId: String
    public let groupName: String
    public let playbackState: PlaybackState?
}

/// Playback progress information.
/// Use `currentPositionMs` to get the real-time interpolated position.
public struct PlaybackProgress: Sendable {
    /// Playback position in milliseconds at the time of the metadata update
    public let trackProgressMs: Int
    /// Total track length in milliseconds (0 = unknown/unlimited, e.g. live radio)
    public let trackDurationMs: Int
    /// Playback speed multiplier x1000 (1000 = normal, 0 = paused)
    public let playbackSpeed: Int
    /// Server timestamp (microseconds) when this progress was valid
    public let timestamp: Int64

    /// Calculate the current playback position in milliseconds.
    /// Interpolates from the last known position using the playback speed.
    /// - Parameter currentTimeMicros: Current time in microseconds
    ///   (same clock domain as `timestamp`)
    public func currentPositionMs(at currentTimeMicros: Int64) -> Int {
        let elapsed = currentTimeMicros - timestamp
        let calculated = trackProgressMs
            + Int(elapsed * Int64(playbackSpeed) / 1_000_000)
        if trackDurationMs != 0 {
            return max(min(calculated, trackDurationMs), 0)
        }
        return max(calculated, 0)
    }
}

public struct TrackMetadata: Sendable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let albumArtist: String?
    public let track: Int?
    public let year: Int?
    public let artworkUrl: String?
    public let progress: PlaybackProgress?
    public let repeatMode: RepeatMode?
    public let shuffle: Bool?
}

/// Repeat mode per spec
public enum RepeatMode: String, Sendable {
    case off
    case one
    case all
}

public struct ControllerState: Sendable {
    public let supportedCommands: [ControllerCommandType]
    public let volume: Int
    public let muted: Bool
}

public enum SendspinClientError: Error {
    case notConnected
}
