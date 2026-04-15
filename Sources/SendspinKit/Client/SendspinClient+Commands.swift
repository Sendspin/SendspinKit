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
        let request = try ArtworkFormatRequest(
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

extension SendspinClient {
    /// Send a raw controller command to the server.
    ///
    /// Internal because the typed convenience methods (`play()`, `pause()`, etc.) are the
    /// correct public API — they prevent invalid parameter combinations like
    /// `sendCommand(.play, volume: 50)` which compiles but is nonsensical.
    @MainActor
    func sendCommand(_ command: ControllerCommandType, volume: Int? = nil, mute: Bool? = nil) async throws {
        let controller = ControllerCommand(command: command, volume: volume, mute: mute)
        let message = ClientCommandMessage(payload: ClientCommandPayload(controller: controller))
        try await sendWrapped(message)
    }
}

public extension SendspinClient {
    /// Start playback.
    ///
    /// Requires the controller role. Check ``currentControllerState`` to verify
    /// the server supports this command before calling — if the server doesn't
    /// support it, the command is silently ignored per spec.
    ///
    /// - Throws: ``SendspinClientError/notConnected`` if not connected.
    @MainActor func play() async throws {
        try await sendCommand(.play)
    }

    /// Pause playback.
    ///
    /// Requires the controller role. See ``play()`` for server support notes.
    @MainActor func pause() async throws {
        try await sendCommand(.pause)
    }

    /// Stop playback.
    ///
    /// Requires the controller role. See ``play()`` for server support notes.
    @MainActor func stopPlayback() async throws {
        try await sendCommand(.stop)
    }

    /// Skip to the next track.
    ///
    /// Requires the controller role. See ``play()`` for server support notes.
    @MainActor func next() async throws {
        try await sendCommand(.next)
    }

    /// Skip to the previous track.
    ///
    /// Requires the controller role. See ``play()`` for server support notes.
    @MainActor func previous() async throws {
        try await sendCommand(.previous)
    }

    /// Set the group volume (0–100, perceived loudness).
    ///
    /// This controls the volume for the entire group (all players), unlike
    /// ``setVolume(_:)`` which controls this individual player's volume.
    /// Requires the controller role. See ``play()`` for server support notes.
    @MainActor func setGroupVolume(_ volume: Int) async throws {
        try await sendCommand(.volume, volume: max(0, min(100, volume)))
    }

    /// Set the group mute state.
    ///
    /// This controls mute for the entire group (all players), unlike
    /// ``setMute(_:)`` which controls this individual player's mute.
    /// Requires the controller role. See ``play()`` for server support notes.
    @MainActor func setGroupMute(_ muted: Bool) async throws {
        try await sendCommand(.mute, mute: muted)
    }

    /// Set repeat mode.
    ///
    /// Maps directly to the individual repeat commands on the wire.
    /// Useful when binding a `Picker<RepeatMode>` in SwiftUI.
    /// Requires the controller role. See ``play()`` for server support notes.
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
    /// Requires the controller role. See ``play()`` for server support notes.
    @MainActor func setShuffle(_ enabled: Bool) async throws {
        try await sendCommand(enabled ? .shuffle : .unshuffle)
    }

    /// Repeat off.
    /// Requires the controller role. See ``play()`` for server support notes.
    @MainActor func repeatOff() async throws {
        try await sendCommand(.repeatOff)
    }

    /// Repeat the current track.
    /// Requires the controller role. See ``play()`` for server support notes.
    @MainActor func repeatOne() async throws {
        try await sendCommand(.repeatOne)
    }

    /// Repeat all tracks in the queue.
    /// Requires the controller role. See ``play()`` for server support notes.
    @MainActor func repeatAll() async throws {
        try await sendCommand(.repeatAll)
    }

    /// Enable shuffle mode.
    /// Requires the controller role. See ``play()`` for server support notes.
    @MainActor func shuffle() async throws {
        try await sendCommand(.shuffle)
    }

    /// Disable shuffle mode.
    /// Requires the controller role. See ``play()`` for server support notes.
    @MainActor func unshuffle() async throws {
        try await sendCommand(.unshuffle)
    }

    /// Switch to the next group.
    /// Requires the controller role. See ``play()`` for server support notes.
    @MainActor func switchGroup() async throws {
        try await sendCommand(.switch)
    }
}
