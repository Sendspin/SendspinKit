// ABOUTME: Public command methods for SendspinClient
// ABOUTME: External source, format negotiation, artwork, and controller commands

import Foundation

// MARK: - External source

public extension SendspinClient {
    /// Signal that this client's output is in use by an external source.
    ///
    /// Per spec, setting `state: 'external_source'` tells the server that
    /// the client is playing audio from a different source (HDMI input,
    /// local playback, etc.). The server will move this client to a new
    /// solo group and stop sending audio.
    ///
    /// Unlike ``setVolume(_:)`` where a failed server notification is benign
    /// (the next state update catches up), a failed external-source notification
    /// creates split-brain: the client thinks it's external while the server
    /// keeps streaming audio. To prevent this, the local state is rolled back
    /// if the server cannot be notified.
    ///
    /// Call ``exitExternalSource()`` to return to normal operation.
    ///
    /// - Throws: ``SendspinClientError/notConnected`` if not connected,
    ///   or ``SendspinClientError/sendFailed(_:)`` if the server notification fails.
    @MainActor
    func enterExternalSource() async throws {
        try await transitionOperationalState(to: .externalSource)
    }

    /// Return to normal synchronized operation after ``enterExternalSource()``.
    ///
    /// Tells the server this client is ready to receive audio again.
    /// The server will typically move the client back into its previous group
    /// via `group/update`.
    ///
    /// The local state is rolled back if the server notification fails
    /// (see ``enterExternalSource()`` for rationale).
    ///
    /// - Throws: ``SendspinClientError/notConnected`` if not connected,
    ///   or ``SendspinClientError/sendFailed(_:)`` if the server notification fails.
    @MainActor
    func exitExternalSource() async throws {
        try await transitionOperationalState(to: .synchronized)
    }
}

// MARK: - Player format negotiation

public extension SendspinClient {
    /// Request the server to change the audio stream format.
    ///
    /// Per spec, the server responds with `stream/start` containing the new format.
    /// All parameters are optional — omitted fields are filled in by the server
    /// (typically from the current format or the client's first supported format).
    ///
    /// **Important:** The requested combination must exist in the client's
    /// `supported_formats` list from `client/hello`, otherwise the server
    /// falls back to the current format.
    ///
    /// Use cases:
    /// - Switch codec: `try await requestPlayerFormat(codec: .flac)`
    /// - Match source rate: `try await requestPlayerFormat(sampleRate: 48000)`
    /// - Full format change: `try await requestPlayerFormat(codec: .flac, sampleRate: 48000, bitDepth: 24)`
    /// - Downgrade under load: `try await requestPlayerFormat(codec: .opus)`
    ///
    /// - Throws: ``SendspinClientError/notConnected`` if not connected.
    @MainActor
    func requestPlayerFormat(
        codec: AudioCodec? = nil,
        channels: Int? = nil,
        sampleRate: Int? = nil,
        bitDepth: Int? = nil
    ) async throws {
        let request = PlayerFormatRequest(
            codec: codec,
            channels: channels,
            sampleRate: sampleRate,
            bitDepth: bitDepth
        )
        let message = StreamRequestFormatMessage(
            payload: StreamRequestFormatPayload(player: request)
        )
        try await sendWrapped(message)
    }

    /// Request a specific format from the `supportedFormats` list by exact match.
    /// This is a convenience that sends all fields, avoiding server-side fill-in ambiguity.
    ///
    /// - Throws: ``SendspinClientError/notConnected`` if not connected.
    @MainActor
    func requestPlayerFormat(_ format: AudioFormatSpec) async throws {
        try await requestPlayerFormat(
            codec: format.codec,
            channels: format.channels,
            sampleRate: format.sampleRate,
            bitDepth: format.bitDepth
        )
    }
}

// MARK: - Artwork commands

public extension SendspinClient {
    /// Request the server to change artwork format for a specific channel.
    /// The server will respond with `stream/start` containing the updated config.
    ///
    /// - Throws: ``SendspinClientError/notConnected`` if not connected.
    @MainActor
    func requestArtworkFormat(
        channel: Int,
        source: ArtworkSource? = nil,
        format: ImageFormat? = nil,
        mediaWidth: Int? = nil,
        mediaHeight: Int? = nil
    ) async throws {
        let request = ArtworkFormatRequest(
            channel: channel,
            source: source,
            format: format,
            mediaWidth: mediaWidth,
            mediaHeight: mediaHeight
        )
        let message = StreamRequestFormatMessage(
            payload: StreamRequestFormatPayload(artwork: request)
        )
        try await sendWrapped(message)
    }
}

// MARK: - Controller commands

public extension SendspinClient {
    /// Send a controller command to the server.
    ///
    /// Only valid if the client has the controller role and the command is in
    /// the server's `supported_commands`.
    ///
    /// - Throws: ``SendspinClientError/notConnected`` if not connected.
    @MainActor
    func sendCommand(_ command: ControllerCommandType, volume: Int? = nil, mute: Bool? = nil) async throws {
        let controller = ControllerCommand(command: command, volume: volume, mute: mute)
        let message = ClientCommandMessage(payload: ClientCommandPayload(controller: controller))
        try await sendWrapped(message)
    }

    /// Convenience: play
    @MainActor func play() async throws {
        try await sendCommand(.play)
    }

    /// Convenience: pause
    @MainActor func pause() async throws {
        try await sendCommand(.pause)
    }

    /// Convenience: stop playback
    @MainActor func stopPlayback() async throws {
        try await sendCommand(.stop)
    }

    /// Convenience: next track
    @MainActor func next() async throws {
        try await sendCommand(.next)
    }

    /// Convenience: previous track
    @MainActor func previous() async throws {
        try await sendCommand(.previous)
    }

    /// Convenience: set group volume (0-100)
    @MainActor func setGroupVolume(_ volume: Int) async throws {
        try await sendCommand(.volume, volume: max(0, min(100, volume)))
    }

    /// Convenience: set group mute
    @MainActor func setGroupMute(_ muted: Bool) async throws {
        try await sendCommand(.mute, mute: muted)
    }

    /// Set repeat mode.
    ///
    /// Maps directly to the individual repeat commands on the wire.
    /// Useful when binding a `Picker<RepeatMode>` in SwiftUI.
    @MainActor func setRepeatMode(_ mode: RepeatMode) async throws {
        switch mode {
        case .off: try await sendCommand(.repeatOff)
        case .one: try await sendCommand(.repeatOne)
        case .all: try await sendCommand(.repeatAll)
        }
    }

    /// Set shuffle state.
    ///
    /// Useful when binding a toggle in SwiftUI.
    @MainActor func setShuffle(_ enabled: Bool) async throws {
        try await sendCommand(enabled ? .shuffle : .unshuffle)
    }

    /// Convenience: repeat off
    @MainActor func repeatOff() async throws {
        try await sendCommand(.repeatOff)
    }

    /// Convenience: repeat one track
    @MainActor func repeatOne() async throws {
        try await sendCommand(.repeatOne)
    }

    /// Convenience: repeat all tracks
    @MainActor func repeatAll() async throws {
        try await sendCommand(.repeatAll)
    }

    /// Convenience: shuffle playback
    @MainActor func shuffle() async throws {
        try await sendCommand(.shuffle)
    }

    /// Convenience: unshuffle playback
    @MainActor func unshuffle() async throws {
        try await sendCommand(.unshuffle)
    }

    /// Convenience: switch to next group
    @MainActor func switchGroup() async throws {
        try await sendCommand(.switch)
    }
}
