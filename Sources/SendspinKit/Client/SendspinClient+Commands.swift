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
    /// This is the non-interruptible external-source path: the client remains
    /// unavailable while the external activity owns its output.
    ///
    /// - Throws: ``SendspinClientError/notConnected`` if not connected,
    ///   or ``SendspinClientError/sendFailed(_:)`` if the server notification fails.
    @MainActor
    func enterExternalSource() async throws {
        try await transitionOperationalState(to: .externalSource)
        // Signal engine to suppress underrun telemetry only after the server
        // accepted the state transition; failed sends leave engine/facade aligned.
        await connection?.setExternalSource(true)
    }

    /// Return to normal synchronized operation after ``enterExternalSource()``.
    ///
    /// Tells the server this client is ready to receive audio again. The server
    /// does not automatically rejoin the previous group; rejoining requires an
    /// explicit group switch or another server-directed group change.
    ///
    /// The local state is rolled back if the server notification fails
    /// (see ``enterExternalSource()`` for rationale).
    ///
    /// - Throws: ``SendspinClientError/notConnected`` if not connected,
    ///   or ``SendspinClientError/sendFailed(_:)`` if the server notification fails.
    @MainActor
    func exitExternalSource() async throws {
        try await transitionOperationalState(to: .synchronized)
        // Signal engine to resume underrun monitoring only after the server
        // accepted the state transition; failed sends leave engine/facade aligned.
        await connection?.setExternalSource(false)
    }
}

// MARK: - Group membership

public extension SendspinClient {
    /// Leave the current server group without changing local group state.
    ///
    /// This operation is available to every client role. The server moves the
    /// client to a stopped solo group; returning to the previous group requires
    /// an explicit server-directed switch or group update.
    ///
    /// - Throws: ``SendspinClientError/notConnected`` when disconnected,
    ///   ``SendspinClientError/handshakeIncomplete`` during re-handshake, or
    ///   ``SendspinClientError/sendFailed(_:)`` when the encrypted send fails.
    @MainActor
    func leaveGroup() async throws {
        try requireOpen()
        guard let connection else { throw SendspinClientError.notConnected }
        try await connection.leaveGroup()
    }
}

// MARK: - Dynamic player capabilities and format preference

public extension SendspinClient {
    /// Update the commands the player currently accepts from the server.
    @MainActor
    func updatePlayerSupportedCommands(_ commands: Set<PlayerCommand>) async throws {
        try requireOpen()
        guard let connection else { throw SendspinClientError.notConnected }
        try await connection.updateAdvertisedCommands(commands)
    }

    /// Publish a preferred format in the player client/state object.
    @MainActor
    func setPlayerFormatPreference(_ format: AudioFormatSpec?) async throws {
        try requireOpen()
        guard roleSet.contains(.playerV1) else { throw SendspinClientError.roleNotActive(.playerV1) }
        guard let connection else { throw SendspinClientError.notConnected }
        guard await connection.isRehandshakeInProgress == false else { throw SendspinClientError.handshakeIncomplete }
        try await connection.requireActiveRole(.playerV1)
        let previousPreference = preferredPlayerFormat
        do {
            try await connection.setPreferredPlayerFormat(format)
            preferredPlayerFormat = await connection.preferredPlayerFormat
        } catch {
            preferredPlayerFormat = previousPreference
            throw error
        }
    }

    /// Select a preferred supported format by matching the supplied fields.
    @MainActor
    func setPlayerFormatPreference(
        codec: AudioCodec? = nil,
        channels: Int? = nil,
        sampleRate: Int? = nil,
        bitDepth: Int? = nil
    ) async throws {
        try requireOpen()
        guard roleSet.contains(.playerV1) else { throw SendspinClientError.roleNotActive(.playerV1) }
        guard let connection else { throw SendspinClientError.notConnected }
        guard await connection.isRehandshakeInProgress == false else { throw SendspinClientError.handshakeIncomplete }
        try await connection.requireActiveRole(.playerV1)
        try await connection.setPlayerFormatPreference(codec: codec, channels: channels, sampleRate: sampleRate, bitDepth: bitDepth)
        preferredPlayerFormat = await connection.preferredPlayerFormat
    }
}

// MARK: - Artwork state preference

public extension SendspinClient {
    /// Publish one artwork channel's current preference in client/state.
    @MainActor
    func setArtworkChannelPreference(
        channel: Int,
        preference: ArtworkChannelPreference
    ) async throws {
        try requireOpen()
        guard roleSet.contains(.artworkV1) else { throw SendspinClientError.roleNotActive(.artworkV1) }
        guard let connection else { throw SendspinClientError.notConnected }
        guard await connection.isRehandshakeInProgress == false else { throw SendspinClientError.handshakeIncomplete }
        try await connection.requireActiveRole(.artworkV1)
        try await connection.setArtworkChannelPreference(channel: channel, preference: preference)
    }
}

public extension SendspinClient {
    /// Publish the complete visualizer preference, including an empty types request to disable data.
    @MainActor
    func setVisualizerPreference(_ preference: VisualizerStateObject) async throws {
        try requireOpen()
        guard roleSet.contains(.visualizerV1) else { throw SendspinClientError.roleNotActive(.visualizerV1) }
        guard let connection else { throw SendspinClientError.notConnected }
        guard await connection.isRehandshakeInProgress == false else { throw SendspinClientError.handshakeIncomplete }
        try await connection.setVisualizerPreference(preference)
    }
}

// MARK: - Controller commands

extension SendspinClient {
    /// Send a raw controller command to the server.
    ///
    /// Internal because the typed convenience methods (`play()`, `pause()`, etc.) are the
    /// correct public API — they prevent invalid parameter combinations like
    /// `sendCommand(.play, volume: 50)` which compiles but is nonsensical.
    /// Every typed command wrapper throws these controller snapshot errors.
    /// - Throws: ``SendspinClientError/controllerStateUnavailable`` before the first snapshot,
    ///   or ``SendspinClientError/controllerCommandUnsupported(_:)`` when the command is not listed.
    @MainActor
    func sendCommand(
        _ command: ControllerCommandType,
        volume: Int? = nil,
        mute: Bool? = nil,
        positionMs: Int? = nil,
        offsetMs: Int? = nil
    ) async throws {
        try requireOpen()
        guard roleSet.contains(.controllerV1) else { throw SendspinClientError.roleNotActive(.controllerV1) }
        guard let connection else { throw SendspinClientError.notConnected }
        let controller = ControllerCommand(
            command: command,
            volume: volume,
            mute: mute,
            positionMs: positionMs,
            offsetMs: offsetMs
        )
        try await connection.sendControllerCommand(controller)
    }
}

public extension SendspinClient {
    /// Only an operator gesture opens connection-scoped eligibility, not peer trust; attempts do not close it.
    /// Opening resets the device-wide 20-round budget, except when re-opening an open window after dynamic pair-init.
    /// Never invoke automatically or per attempt.
    @MainActor
    func openPairingWindow(for attemptID: PairingAttemptID) async throws {
        try requireOpen()
        let candidates = [connection, pairingConnection].compactMap(\.self)
        guard !candidates.isEmpty else { throw SendspinClientError.notConnected }
        for candidate in candidates {
            guard let snapshot = await candidate.pairingAttemptSnapshot(), snapshot.id == attemptID else { continue }
            try await candidate.openPairingWindow(attemptID: attemptID)
            return
        }
        throw SendspinClientError.stalePairingAttempt(attemptID)
    }

    /// Cancel the attempt, or close the window identified by `pairingWindow.attemptID`.
    /// A window identity remains valid after its original attempt ends. Closing its window also
    /// ends any current attempt on the owning connection; it never targets another connection.
    @MainActor
    func cancelPairing(attemptID: PairingAttemptID) async throws {
        try requireOpen()
        let candidates = [connection, pairingConnection].compactMap(\.self)
        guard !candidates.isEmpty else { throw SendspinClientError.notConnected }
        for candidate in candidates {
            let snapshot = await candidate.pairingAttemptSnapshot()
            let windowID = await candidate.pairingWindowAttemptID
            guard snapshot?.id == attemptID || windowID == attemptID else { continue }
            try await candidate.cancelPairing(attemptID: attemptID)
            return
        }
        throw SendspinClientError.stalePairingAttempt(attemptID)
    }

    /// Start playback.
    ///
    /// Requires the controller role and a received snapshot listing this command.
    /// Throws ``SendspinClientError/controllerStateUnavailable`` before the first snapshot,
    /// or ``SendspinClientError/controllerCommandUnsupported(_:)`` when it is not listed.
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
    /// ``setVolume(_:)`` which controls this individual player's volume. The
    /// observable ``currentControllerState`` is updated optimistically before the
    /// command is sent so SwiftUI bindings feel immediate; if the send fails, the
    /// previous controller state is restored and the error is rethrown.
    /// Requires the controller role. See ``play()`` for server support notes.
    @MainActor func setGroupVolume(_ volume: Int) async throws {
        let clamped = max(0, min(100, volume))
        let previous = currentControllerState
        if let previous {
            updateControllerState(ControllerState(
                supportedCommands: previous.supportedCommands,
                volume: clamped,
                muted: previous.muted,
                repeatMode: previous.repeatMode,
                shuffle: previous.shuffle,
                seekMaxMs: previous.seekMaxMs
            ))
        }
        do {
            try await sendCommand(.volume, volume: clamped)
        } catch {
            updateControllerState(previous)
            throw error
        }
    }

    /// Set the group mute state.
    ///
    /// This controls mute for the entire group (all players), unlike
    /// ``setMute(_:)`` which controls this individual player's mute. The observable
    /// ``currentControllerState`` is updated optimistically before the command is sent;
    /// if the send fails, the previous controller state is restored and the error is rethrown.
    /// Requires the controller role. See ``play()`` for server support notes.
    @MainActor func setGroupMute(_ muted: Bool) async throws {
        let previous = currentControllerState
        if let previous {
            updateControllerState(ControllerState(
                supportedCommands: previous.supportedCommands,
                volume: previous.volume,
                muted: muted,
                repeatMode: previous.repeatMode,
                shuffle: previous.shuffle,
                seekMaxMs: previous.seekMaxMs
            ))
        }
        do {
            try await sendCommand(.mute, mute: muted)
        } catch {
            updateControllerState(previous)
            throw error
        }
    }

    /// Seek to an absolute playback position.
    ///
    /// - Parameter positionMs: Target playback position in milliseconds. Values below zero are clamped
    ///   to zero; if the server reported ``ControllerState/seekMaxMs``, values above it are clamped
    ///   before sending. Servers still validate the command and may ignore unsupported targets per spec.
    /// Requires the controller role. See ``play()`` for server support notes.
    @MainActor func seek(to positionMs: Int) async throws {
        let clamped = min(max(positionMs, 0), currentControllerState?.seekMaxMs ?? Int.max)
        try await sendCommand(.seek, positionMs: clamped)
    }

    /// Seek relative to the current playback position.
    ///
    /// - Parameter offsetMs: Signed offset in milliseconds. Positive values seek forward;
    ///   negative values seek backward. The server clamps/applies the resulting position on a
    ///   best-effort basis per spec.
    /// Requires the controller role. See ``play()`` for server support notes.
    @MainActor func seekRelative(by offsetMs: Int) async throws {
        try await sendCommand(.seekRelative, offsetMs: offsetMs)
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
