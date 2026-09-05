import Foundation

/// Playback state of a Sendspin group.
///
/// Per spec, only `playing` and `stopped` exist on the wire. Paused playback
/// is represented as `playing` with `PlaybackProgress.playbackSpeedX1000 == 0`.
public enum PlaybackState: String, Codable, Sendable, Hashable {
    case playing
    case stopped
}

/// App-facing playback status derived from Sendspin protocol state.
///
/// Sendspin's wire-level ``PlaybackState`` only distinguishes `playing` from
/// `stopped`; pause is represented by `playback_state == playing` plus
/// ``PlaybackProgress/playbackSpeedX1000`` equal to zero. Use this type when
/// building UI instead of re-implementing that protocol detail in each app.
public enum PlaybackStatus: Sendable, Hashable {
    case playing
    case paused
    case stopped

    public init?(group: GroupInfo?, metadata: TrackMetadata?, isPlayerStreamActive: Bool = false) {
        if group?.playbackState == .stopped {
            self = .stopped
        } else if isPlayerStreamActive {
            self = .playing
        } else if metadata?.progress?.playbackSpeedX1000 == 0 {
            self = .paused
        } else if group?.playbackState == .playing {
            self = .playing
        } else {
            return nil
        }
    }
}

/// Repeat mode for playback queue.
///
/// Values match the wire format: `'off'`, `'one'`, `'all'`.
public enum RepeatMode: String, Codable, Sendable, Hashable {
    case off
    case one
    case all
}

/// Controller command identifiers per spec.
///
/// These are group-level commands sent by a client with the `controller` role
/// (play, pause, skip, group volume/mute, etc.). Distinct from ``PlayerCommand``
/// which targets an individual player. The `volume` and `mute` cases overlap
/// because group volume/mute cascades to individual player volumes/mutes.
///
/// Raw values match the wire format exactly (e.g. `"repeat_off"`, `"switch"`).
/// Used in `supported_commands` arrays and `client/command` messages.
public enum ControllerCommandType: String, Codable, Sendable, Hashable {
    case play, pause, stop, next, previous
    case volume, mute
    case repeatOff = "repeat_off"
    case repeatOne = "repeat_one"
    case repeatAll = "repeat_all"
    case shuffle, unshuffle
    case seek
    case seekRelative = "seek_relative"
    case `switch`
}

/// Why the client disconnected
public enum DisconnectReason: Sendable, Equatable {
    /// Client explicitly disconnected (via `disconnect()`)
    case explicit(GoodbyeReason)
    /// Connection ended without a local `disconnect()` — peer closed, or the network failed.
    ///
    /// The reason is a best-effort socket observation, useful for backoff and diagnostics
    /// but not protocol state (see ``TransportCloseReason``). Treat `nil` as "lost".
    case connectionLost(TransportCloseReason?)
    /// Server was rejected (e.g. unsupported core protocol version in `server/hello`)
    case incompatibleServer
    /// The transport opened but `server/hello` never arrived within the handshake budget.
    ///
    /// Distinct from ``incompatibleServer``: nothing was learned about the server's
    /// protocol support, so this is usually transient (a slow or overloaded server) and
    /// is a reasonable candidate for reconnect, whereas an incompatible server is not.
    case handshakeTimeout
    /// The server selected a player format rejected by the session's output policy.
    case outputFormatRejected(OutputFormatError)
}

/// Raw player audio bytes exactly as received from the server.
public struct AudioChunk: Sendable, Equatable {
    /// Raw payload bytes after the Sendspin binary header.
    public let data: Data
    /// Raw server timestamp in microseconds in the server's clock domain.
    ///
    /// This is the timestamp exactly as sent on the wire. SendspinKit's internal
    /// playback engine subtracts `output_delay_ms` and translates server time to
    /// local time before scheduling. Consumers that use raw audio chunks for their
    /// own playback scheduling must apply the same output-delay adjustment and
    /// clock-domain conversion themselves.
    public let serverTimestamp: Int64
    /// Server-reported lead time in microseconds, used for arrival-delay measurement only.
    public let sendAhead: UInt32

    public init(data: Data, serverTimestamp: Int64, sendAhead: UInt32 = 0) {
        self.data = data
        self.serverTimestamp = serverTimestamp
        self.sendAhead = sendAhead
    }
}

/// Artwork bytes received for one artwork stream channel.
public struct ArtworkData: Sendable, Equatable {
    /// Artwork channel index from the binary message type.
    public let channel: Int
    /// Raw artwork payload bytes after the Sendspin binary header.
    ///
    /// Per the Sendspin spec, an empty payload is an explicit clear signal for
    /// ``channel``: the binary frame contains only the message type byte and
    /// timestamp, with no image data.
    public let data: Data
    /// Whether this payload clears the currently displayed artwork for ``channel``.
    public var clearsArtwork: Bool {
        data.isEmpty
    }

    /// Local absolute display time in microseconds, or `nil` when clock sync is not ready.
    public let localDisplayTime: Int64?
}

/// Visualizer bytes received from the visualizer stream.
public struct VisualizerData: Sendable, Equatable {
    /// Raw visualizer payload bytes after the Sendspin binary header.
    public let data: Data
    /// Local absolute display time in microseconds.
    public let localDisplayTime: Int64
}

public enum PairingCodeFormat: String, Codable, Sendable, Equatable {
    case digits
    case qrCode = "qr_code"
}

public struct PairingCodeEmission: Sendable, Equatable {
    public let format: PairingCodeFormat
    public let payload: String
    public let digitAudioPack: DigitAudioPack?

    public init(format: PairingCodeFormat, payload: String, digitAudioPack: DigitAudioPack? = nil) {
        self.format = format
        self.payload = payload
        self.digitAudioPack = digitAudioPack
    }
}

public enum ClientEvent: Sendable, Equatable {
    case serverConnected(ServerInfo)
    case pairingCodeChanged(PairingCodeEmission?)
    case pairingAttemptEnded(PairAbortReason)
    case paired(serverId: String)
    /// The client observed a new advisory audio-output capability snapshot.
    case audioOutputChanged(AudioOutputSnapshot)
    /// The current session's output-format negotiation status changed.
    case outputFormatStatusChanged(OutputFormatStatus)
    /// Streaming could not continue with the server-selected format or audio output.
    case streamingFailed(StreamingError)
    case streamStarted(AudioFormatSpec)
    /// Format changed mid-stream after the server applies a client format preference.
    case streamFormatChanged(AudioFormatSpec)
    /// Server sent `stream/end` — one or more streams have ended and buffers
    /// should be cleared for those roles. `roles` contains the ended roles, or
    /// `nil` if all active streams ended (matching the wire format's semantics).
    case streamEnded(roles: [String]?)
    /// Server sent `stream/clear` — buffers have been flushed without ending
    /// the stream. Typically sent during a seek operation. Consumers should
    /// reset any time-based UI (progress bars, waveform displays, etc.)
    /// and wait for fresh metadata with the new position.
    ///
    /// `roles` contains the roles that were cleared, or `nil` if all roles
    /// were cleared (matching the wire format's semantics).
    case streamCleared(roles: [String]?)
    case groupUpdated(GroupInfo)
    case metadataReceived(TrackMetadata)
    case controllerStateUpdated(ControllerState)
    /// The server cleared the complete controller role state.
    case controllerStateCleared
    case colorStateUpdated(ColorState)
    /// The server cleared the complete color role state.
    case colorStateCleared
    case artworkStreamStarted([StreamArtworkChannelConfig])
    /// Server changed the output delay via `server/command`. The host app should
    /// persist this value and pass it back as `initialOutputDelayMs` on next launch.
    case outputDelayChanged(milliseconds: Int)
    /// The server that most recently had `playback_state: 'playing'` changed.
    /// Per spec, clients must persist this across reboots for multi-server
    /// priority logic. The host app is responsible for persistence — store
    /// this value and pass it to reconnection/discovery logic as needed.
    case lastPlayedServerChanged(serverId: String)
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
    public let trustLevel: TrustLevel
    /// Roles the server actually activated for this client.
    /// Use ``hasRole(_:)`` to check whether a specific capability is available.
    public let activeRoles: Set<VersionedRole>
    /// Activities currently admitted for this connection.
    public let activities: Set<Activity>

    /// Whether the server activated the given role for this client.
    ///
    /// Convenience for `activeRoles.contains(role)`. Useful in SwiftUI:
    /// ```swift
    /// Button("Play") { ... }
    ///     .disabled(!info.hasRole(.controllerV1))
    /// ```
    public func hasRole(_ role: VersionedRole) -> Bool {
        activeRoles.contains(role)
    }
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
/// ``trackProgressMs`` is track-relative milliseconds; ``timestamp`` is a server-clock instant.
/// Playback speed is the only bridge: position advances by `elapsed × speed` only while playing.
/// Sendspin has no pause state; a paused position is a retained track-relative offset.
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
        // Every input is an unvalidated server value. Overflow at any step means the
        // interpolation is meaningless, so report the last known position rather than a
        // wrapped one — with `trackDurationMs == 0` (live radio) there is no upper clamp
        // below to disguise a wrapped result.
        let elapsed = currentTimeMicros.subtractingReportingOverflow(timestamp)
        guard !elapsed.overflow else { return max(Int64(trackProgressMs), 0) }
        let scaled = elapsed.partialValue.multipliedReportingOverflow(by: Int64(playbackSpeedX1000))
        guard !scaled.overflow else { return max(Int64(trackProgressMs), 0) }
        let sum = Int64(trackProgressMs).addingReportingOverflow(scaled.partialValue / 1_000_000)
        guard !sum.overflow else { return max(Int64(trackProgressMs), 0) }
        if trackDurationMs != 0 {
            return max(min(sum.partialValue, Int64(trackDurationMs)), 0)
        }
        return max(sum.partialValue, 0)
    }
}

/// Track metadata from the server.
///
/// Constructed internally by `SendspinClient` — consumers observe these
/// via ``ClientEvent/metadataReceived(_:)``.
public struct TrackMetadata: Sendable, Hashable {
    static let empty = TrackMetadata(
        title: nil, artist: nil, album: nil, albumArtist: nil, track: nil, year: nil, artworkURL: nil, progress: nil
    )

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
}

/// An RGB color from a Sendspin color role update. Components are in the
/// protocol's 0...255 range.
public struct SendspinColor: Codable, Sendable, Hashable {
    public let red: Int
    public let green: Int
    public let blue: Int

    public init(red: Int, green: Int, blue: Int) {
        precondition(
            [red, green, blue].allSatisfy { 0 ... 255 ~= $0 },
            "RGB color components must be in the range 0...255"
        )
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let components = try [container.decode(Int.self), container.decode(Int.self), container.decode(Int.self)]
        guard components.allSatisfy({ 0 ... 255 ~= $0 }), container.isAtEnd else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "RGB colors must contain exactly three components in the range 0...255"
            )
        }
        self.init(red: components[0], green: components[1], blue: components[2])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(red)
        try container.encode(green)
        try container.encode(blue)
    }
}

/// Color state derived from the current audio.
///
/// Constructed internally by `SendspinClient` — consumers observe these
/// via ``ClientEvent/colorStateUpdated(_:)``.
public struct ColorState: Sendable, Hashable {
    /// Raw server clock time in microseconds for when these colors are valid.
    public let serverTimestamp: Int64
    /// Local absolute display time in microseconds, or `nil` when clock sync was not ready.
    public let localDisplayTime: Int64?
    public let backgroundDark: SendspinColor?
    public let backgroundLight: SendspinColor?
    public let primary: SendspinColor?
    public let accent: SendspinColor?
    public let onDark: SendspinColor?
    public let onLight: SendspinColor?

    public init(
        serverTimestamp: Int64,
        localDisplayTime: Int64?,
        backgroundDark: SendspinColor?,
        backgroundLight: SendspinColor?,
        primary: SendspinColor?,
        accent: SendspinColor?,
        onDark: SendspinColor?,
        onLight: SendspinColor?
    ) {
        self.serverTimestamp = serverTimestamp
        self.localDisplayTime = localDisplayTime
        self.backgroundDark = backgroundDark
        self.backgroundLight = backgroundLight
        self.primary = primary
        self.accent = accent
        self.onDark = onDark
        self.onLight = onLight
    }
}

/// Controller state from the server.
///
/// Constructed internally by `SendspinClient` — consumers observe these
/// via ``ClientEvent/controllerStateUpdated(_:)``.
public struct ControllerState: Sendable, Hashable {
    /// Commands the server currently supports. Check membership with `contains`
    /// to determine which UI controls to enable.
    public let supportedCommands: Set<ControllerCommandType>
    /// Group volume, range 0-100 per spec (average of all player volumes).
    /// Clamped on construction from server messages.
    public let volume: Int
    /// Group mute state (`true` only when all players in the group are muted)
    public let muted: Bool
    /// Group repeat mode, `nil` if the server has not reported one.
    public let repeatMode: RepeatMode?
    /// Group shuffle state, `nil` if the server has not reported one.
    public let shuffle: Bool?
    /// Maximum absolute seek target in milliseconds for the current media.
    /// `nil` if the server has not reported a bounded seek range.
    public let seekMaxMs: Int?

    public init(
        supportedCommands: Set<ControllerCommandType>,
        volume: Int,
        muted: Bool,
        repeatMode: RepeatMode?,
        shuffle: Bool?,
        seekMaxMs: Int? = nil
    ) {
        self.supportedCommands = supportedCommands
        self.volume = volume
        self.muted = muted
        self.repeatMode = repeatMode
        self.shuffle = shuffle
        self.seekMaxMs = seekMaxMs
    }
}

/// A role that carries its own independently-negotiated stream.
public enum StreamRole: String, Sendable, Hashable {
    case player
    case artwork
}

/// Errors thrown by `SendspinClient` methods.
///
/// Runtime errors during streaming surface as
/// ``ConnectionState/error(_:)`` with a typed ``StreamingError`` payload.
public enum SendspinClientError: SendspinError, Equatable, LocalizedError {
    /// A method that requires an active connection was called while disconnected.
    case notConnected
    /// ``SendspinClient/connect(to:)`` or ``SendspinClient/acceptConnection(_:)``
    /// was called while a connection is already in progress or established.
    case alreadyConnected
    /// A command or message could not be sent over the transport.
    /// The associated string describes the underlying transport error.
    case sendFailed(String)
    /// A role-specific API was called before that protocol role was active.
    case roleNotActive(VersionedRole)
    /// A facade-initiated send was attempted before `server/hello` completed the handshake.
    case handshakeIncomplete
    /// A stream-specific operation was attempted for a role whose stream is not
    /// currently active.
    case streamNotActive(StreamRole)
    /// A URL string supplied to a connect/discovery convenience could not be parsed as an absolute URL.
    case invalidServerURL(String)
    /// Discovery was requested but no Sendspin server was found before the timeout.
    case noDiscoveredServers
    /// Neither an explicit server URL nor discovery was requested.
    case serverURLRequired

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            "Not connected to a Sendspin server"
        case .alreadyConnected:
            "Already connected or connecting to a Sendspin server"
        case let .sendFailed(reason):
            "Failed to send message: \(reason)"
        case let .roleNotActive(role):
            "The \(role.identifier) role is not active for this connection"
        case .handshakeIncomplete:
            "Handshake is not complete; wait for server/hello before sending commands"
        case let .streamNotActive(role):
            "No active \(role.rawValue) stream"
        case let .invalidServerURL(server):
            "Invalid Sendspin server URL: \(server)"
        case .noDiscoveredServers:
            "No Sendspin servers found via mDNS discovery"
        case .serverURLRequired:
            "Provide a Sendspin server URL or enable discovery"
        }
    }
}
