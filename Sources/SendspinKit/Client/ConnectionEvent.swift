import Foundation

/// Control-plane lifecycle and state events emitted by `SendspinConnection`.
///
/// These are the control-plane events the facade consumes to apply `@Observable` state
/// before re-emitting the render-applied public `ClientEvent`. Binary role payloads
/// bypass this enum and are emitted on the facade's typed data streams.
///
/// The terminal event is `.disconnected(reason:)`, which completes the control stream.
enum ConnectionEvent: Equatable {
    /// Server handshake completed, roles negotiated
    case serverConnected(ServerInfo)

    /// Track metadata received and accumulated from server deltas
    case metadataReceived(TrackMetadata)

    /// Controller state (volume, mute, supported commands, repeat, shuffle)
    case controllerStateUpdated(ControllerState)

    /// Group membership and playback state
    case groupUpdated(GroupInfo)

    /// Artwork stream started with channel configs
    case artworkStreamStarted([StreamArtworkChannelConfig])

    /// Audio stream started (format was validated and applied)
    case streamStarted(AudioFormatSpec)

    /// Audio format changed mid-stream
    case streamFormatChanged(AudioFormatSpec)

    /// One or more streams ended (no longer active), roles optional per wire format.
    case streamEnded(roles: [String]?)

    /// Audio stream cleared (buffers flushed without ending), roles optional
    case streamCleared(roles: [String]?)

    /// Static delay changed (command from server)
    case staticDelayChanged(milliseconds: Int)

    /// Last server with playback active (multi-server tracking)
    case lastPlayedServerChanged(serverId: String)

    /// Stream-start failure: unsupported codec, invalid format, or AudioQueue failure
    case streamError(StreamingError)

    /// Player volume changed (server command or local `setVolume`)
    case playerVolumeChanged(Int)

    /// Player mute state changed (server command or local `setMute`)
    case playerMutedChanged(Bool)

    /// Client operational state (synchronized, error, etc.)
    case operationalState(ClientOperationalState)

    /// Clock synchronization established (first `server/time` convergence).
    case clockSyncEstablished

    /// Connection lost or explicit disconnect (terminal event)
    case disconnected(reason: DisconnectReason)
}

/// Connection lifecycle state: idleness, running, shutdown sequence, terminal stopped state.
enum ConnectionLifecycle {
    case idle
    case running
    case shuttingDown
    case stopped
}

/// Protocol handshake phase for the connection's message loop and outbound gates.
enum HandshakePhase {
    case awaitingServerHello
    case complete
}
