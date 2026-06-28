import Foundation
import os

extension SendspinConnection {
    // MARK: - Frame routing

    /// Route a text frame: classify and dispatch.
    func route(text: String, clientReceived: Int64) async {
        guard let data = text.data(using: .utf8) else { return }

        guard let msgType = SendspinEncoding.messageType(of: data) else {
            Log.client.error("Message missing 'type' field: \(text.prefix(200))")
            return
        }

        Log.client.debug("RX \(msgType)")

        let decoder = inboundDecoder
        do {
            switch msgType {
            case "server/hello":
                try await handleServerHello(decoder.decode(ServerHelloMessage.self, from: data))

            case "server/time":
                try await handleServerTime(
                    decoder.decode(ServerTimeMessage.self, from: data),
                    clientReceived: clientReceived
                )

            case "server/state":
                try await handleServerState(decoder.decode(ServerStateMessage.self, from: data))

            case "stream/start":
                try await handleStreamStart(decoder.decode(StreamStartMessage.self, from: data))

            case "stream/clear":
                try await handleStreamClear(decoder.decode(StreamClearMessage.self, from: data))

            case "stream/end":
                try await handleStreamEnd(decoder.decode(StreamEndMessage.self, from: data))

            case "server/command":
                try await handleServerCommand(decoder.decode(ServerCommandMessage.self, from: data))

            case "group/update":
                try await handleGroupUpdate(decoder.decode(GroupUpdateMessage.self, from: data))

            default:
                Log.client.warning("Unknown message type: \(msgType)")
            }
        } catch {
            Log.client.error("Failed to decode '\(msgType)': \(error.localizedDescription)")
        }
    }

    /// Route a binary frame to the matching role data stream if its stream gate is open.
    func route(binary data: Data) async {
        guard let message = BinaryMessage(data: data) else { return }

        switch message.type {
        case .audioChunk:
            await handleAudioChunk(message)

        case .artworkChannel0, .artworkChannel1, .artworkChannel2, .artworkChannel3:
            await handleArtworkBinary(message)

        case .visualizerData:
            await handleVisualizerBinary(message)
        }
    }

    // MARK: - Text message handlers

    func handleServerHello(_ message: ServerHelloMessage) async {
        guard handshakePhase == .awaitingServerHello else {
            Log.client.warning("Ignoring duplicate server/hello on an established connection")
            return
        }

        guard message.payload.version == 1 else {
            Log.client.warning("Rejecting server/hello with unsupported core version: \(message.payload.version)")
            disconnectReason = .incompatibleServer
            await transport.disconnect()
            return
        }

        currentServerId = message.payload.serverId
        activeRoles = Set(message.payload.activeRoles)
        handshakePhase = .complete
        let info = ServerInfo(
            serverId: message.payload.serverId,
            name: message.payload.name,
            version: message.payload.version,
            connectionReason: message.payload.connectionReason,
            activeRoles: activeRoles
        )
        controlSink.enqueue(.serverConnected(info))

        // A fresh handshake means the server holds no prior state: clear the delta baseline
        // so the next send is a full client/state, not an empty delta.
        lastSentClientState = nil
        try? await sendClientStateIfChanged()

        // Handshake is complete: now start client/time sampling (spec §104). Start-once.
        if clockSyncTask == nil {
            clockSyncTask = Task { [weak self] in
                await self?.clockSyncLoop()
            }
        }
    }

    func handleServerTime(
        _ message: ServerTimeMessage,
        clientReceived: Int64
    ) async {
        await clock.processServerTime(
            clientTransmitted: message.payload.clientTransmitted,
            serverReceived: message.payload.serverReceived,
            serverTransmitted: message.payload.serverTransmitted,
            clientReceived: clientReceived
        )
        // First-sync flip: once the filter converges, allow chunks through the gate.
        if !isClockSynced, await clock.hasSynced {
            isClockSynced = true
            controlSink.enqueue(.clockSyncEstablished)
        }

        // Push updated snapshot for sync correction (per-frame cross-boundary).
        if let snapshot = await clock.snapshot() {
            await audioEngine.updateClockSnapshot(snapshot)
        }
    }

    func handleServerState(_ message: ServerStateMessage) async {
        // Emit metadata if present. Merge with the prior state so a partial
        // delta (e.g. title only) preserves absent fields like album/artist,
        // while explicit null clears the field per spec.
        if let metadata = message.payload.metadata {
            let prev = currentMetadata
            let progress: PlaybackProgress? = switch metadata.progress {
            case let .value(prog):
                PlaybackProgress(
                    trackProgressMs: prog.trackProgress,
                    trackDurationMs: prog.trackDuration,
                    playbackSpeedX1000: prog.playbackSpeed,
                    timestamp: metadata.timestamp ?? MonotonicClock.nowMicroseconds()
                )
            case .null:
                nil
            case .absent:
                prev?.progress
            }

            let trackMetadata = TrackMetadata(
                title: metadata.title.merge(previous: prev?.title),
                artist: metadata.artist.merge(previous: prev?.artist),
                album: metadata.album.merge(previous: prev?.album),
                albumArtist: metadata.albumArtist.merge(previous: prev?.albumArtist),
                track: metadata.track.merge(previous: prev?.track),
                year: metadata.year.merge(previous: prev?.year),
                artworkURL: metadata.artworkUrl.merge(previous: prev?.artworkURL),
                progress: progress
            )
            currentMetadata = trackMetadata
            controlSink.enqueue(.metadataReceived(trackMetadata))
        }

        // Emit controller state if present. Merge with the prior state so a partial
        // delta (e.g. volume only) preserves absent fields like repeat/shuffle.
        if let controller = message.payload.controller {
            let prev = currentControllerState
            let controllerState = ControllerState(
                supportedCommands: controller.supportedCommands.map(Set.init) ?? prev?.supportedCommands ?? [],
                volume: controller.volume ?? prev?.volume ?? 0,
                muted: controller.muted ?? prev?.muted ?? false,
                repeatMode: controller.repeat ?? prev?.repeatMode,
                shuffle: controller.shuffle ?? prev?.shuffle
            )
            currentControllerState = controllerState
            controlSink.enqueue(.controllerStateUpdated(controllerState))
        }
    }

    func handleStreamStart(_ message: StreamStartMessage) async {
        // Handle artwork stream
        if let artworkInfo = message.payload.artwork {
            artworkStreamActive = true
            controlSink.enqueue(.artworkStreamStarted(artworkInfo.channels))
        }

        // Handle visualizer stream
        if message.payload.visualizer != nil {
            visualizerStreamActive = true
        }

        // Handle player stream
        guard let playerInfo = message.payload.player else {
            Log.client.info("stream/start: artwork only (no player payload)")
            return
        }

        // Open gate BEFORE validation (must stay open on failure for recovery)
        playerStreamActive = true

        Log.client.info("stream/start: \(playerInfo.codec) \(playerInfo.sampleRate)Hz \(playerInfo.channels)ch \(playerInfo.bitDepth)bit")

        // Validate codec
        guard let codec = AudioCodec(rawValue: playerInfo.codec) else {
            clientOperationalState = .error
            controlSink.enqueue(.streamError(.unsupportedCodec(playerInfo.codec)))
            controlSink.enqueue(.operationalState(.error))
            try? await sendClientStateIfChanged()
            return
        }

        // Validate format
        let format: AudioFormatSpec
        do {
            format = try AudioFormatSpec(
                codec: codec,
                channels: playerInfo.channels,
                sampleRate: playerInfo.sampleRate,
                bitDepth: playerInfo.bitDepth
            )
        } catch {
            clientOperationalState = .error
            controlSink.enqueue(.streamError(.invalidFormat(error.errorDescription ?? "\(error)")))
            controlSink.enqueue(.operationalState(.error))
            try? await sendClientStateIfChanged()
            return
        }

        // Parse codec header. A present-but-malformed (non-base64) header is a
        // corrupt stream/start, not an absent header: surface it as a format error
        // rather than starting headerless (which, for FLAC, fails every decode
        // silently and produces permanent silence with no error reported).
        var codecHeader: Data?
        if let headerBase64 = playerInfo.codecHeader {
            guard let decoded = Data(base64Encoded: headerBase64) else {
                clientOperationalState = .error
                controlSink.enqueue(.streamError(.invalidFormat("codec_header is not valid base64")))
                controlSink.enqueue(.operationalState(.error))
                try? await sendClientStateIfChanged()
                return
            }
            codecHeader = decoded
        }

        // Seamless change detection on format OR codec header: a gapless track
        // change re-announces the same format with fresh codec_header (FLAC
        // streaminfo); routed as .streamStart the player would early-return
        // and silently discard the new header.
        let previous = announcedPlayerStream
        let isFormatChange = previous.map { $0.format != format || $0.codecHeader != codecHeader } ?? false
        announcedPlayerStream = (format: format, codecHeader: codecHeader)

        if isFormatChange {
            audioEngine.commands.enqueue(.formatChange(format, codecHeader: codecHeader))
        } else {
            if clientOperationalState == .error {
                clientOperationalState = .synchronized
                controlSink.enqueue(.operationalState(.synchronized))
                try? await sendClientStateIfChanged()
            }
            controlSink.enqueue(.streamAccepted(format))
            audioEngine.commands.enqueue(.streamStart(format, codecHeader: codecHeader))
        }
    }

    func handleStreamClear(_ message: StreamClearMessage) async {
        let roles = message.payload.roles

        if roles == nil || roles?.contains("player") == true {
            audioEngine.commands.enqueue(.streamClear(roles: roles))
        }

        controlSink.enqueue(.streamCleared(roles: roles))
    }

    func handleStreamEnd(_ message: StreamEndMessage) async {
        let endedRoles = message.payload.roles

        if endedRoles == nil || endedRoles?.contains("player") == true {
            playerStreamActive = false
            audioEngine.commands.enqueue(.streamEnd(roles: endedRoles))
            announcedPlayerStream = nil
        }

        if endedRoles == nil || endedRoles?.contains("artwork") == true {
            artworkStreamActive = false
        }

        if endedRoles == nil || endedRoles?.contains("visualizer") == true {
            visualizerStreamActive = false
        }

        // Per spec, entering external_source causes the server to end active streams.
        // That cleanup must not be interpreted as leaving external_source; only the
        // explicit exitExternalSource() path restores synchronized participation.
        if clientOperationalState != .externalSource {
            clientOperationalState = .synchronized
        }

        controlSink.enqueue(.streamEnded(roles: endedRoles))
    }

    func handleServerCommand(_ message: ServerCommandMessage) async {
        guard let playerCmd = message.payload.player else { return }

        // Gate: only apply commands in the advertised supported set.
        guard advertisedCommands.contains(playerCmd.command) else {
            Log.client.debug("Ignoring server/command: not in advertised supported_commands")
            return
        }

        switch playerCmd.command {
        case .volume:
            if let volume = playerCmd.volume {
                // Clamp to the spec's 0–100 range rather than trusting the server,
                // matching set_static_delay below and the local setVolume API.
                let clamped = max(0, min(100, volume))
                currentVolume = clamped
                await audioEngine.setGain(Float(clamped) / 100.0)
                controlSink.enqueue(.playerVolumeChanged(clamped))
                try? await sendClientStateIfChanged()
            }

        case .mute:
            if let mute = playerCmd.mute {
                currentMuted = mute
                await audioEngine.setMuted(mute)
                controlSink.enqueue(.playerMutedChanged(mute))
                try? await sendClientStateIfChanged()
            }

        case .setStaticDelay:
            if let delayMs = playerCmd.staticDelayMs {
                // Clamp to the spec range rather than trusting the server.
                let clamped = max(0, min(maxStaticDelayMs, delayMs))
                currentStaticDelayMs = clamped
                audioEngine.commands.enqueue(.setStaticDelay(clamped))
                controlSink.enqueue(.staticDelayChanged(milliseconds: clamped))
                try? await sendClientStateIfChanged()
            }
        }
    }

    func handleGroupUpdate(_ message: GroupUpdateMessage) async {
        let prev = currentGroup
        let info = GroupInfo(
            groupId: message.payload.hasGroupId ? message.payload.groupId ?? "" : prev?.groupId ?? "",
            groupName: message.payload.hasGroupName ? message.payload.groupName ?? "" : prev?.groupName ?? "",
            playbackState: message.payload.hasPlaybackState ? message.payload.playbackState : prev?.playbackState
        )
        currentGroup = info
        controlSink.enqueue(.groupUpdated(info))

        // If group update indicates playback is playing and we have a server ID, emit lastPlayedServerChanged
        if message.payload.playbackState == .playing, let serverId = currentServerId {
            controlSink.enqueue(.lastPlayedServerChanged(serverId: serverId))
        }
    }

    // MARK: - Binary message handlers

    func handleAudioChunk(_ message: BinaryMessage) async {
        guard playerStreamActive else {
            Log.client.warning("Discarding audio chunk: no active player stream")
            return
        }

        if emitRawAudio {
            let chunk = AudioChunk(data: message.data, serverTimestamp: message.timestamp)
            validity.yieldIfValid(chunk, to: audioSink)
        }

        // Only enqueue to engine if clock is synced
        if isClockSynced {
            audioEngine.commands.enqueue(.chunk(message.data, ts: message.timestamp))
        }
    }

    func handleArtworkBinary(_ message: BinaryMessage) async {
        guard artworkStreamActive else {
            Log.client.warning("Discarding artwork binary: no active artwork stream")
            return
        }

        guard let channel = message.type.artworkChannel else { return }

        let localDisplayTime = isClockSynced ? await clock.serverTimeToLocal(message.timestamp) : nil
        let artwork = ArtworkData(channel: channel, data: message.data, localDisplayTime: localDisplayTime)
        artworkObserver?(artwork)
        validity.yieldIfValid(artwork, to: artworkSink)
    }

    func handleVisualizerBinary(_ message: BinaryMessage) async {
        guard visualizerStreamActive else {
            Log.client.warning("Discarding visualizer binary: no active visualizer stream")
            return
        }

        guard isClockSynced else {
            Log.client.warning("Discarding visualizer binary: clock is not synced")
            return
        }

        let localDisplayTime = await clock.serverTimeToLocal(message.timestamp)
        let visualizerData = VisualizerData(data: message.data, localDisplayTime: localDisplayTime)
        validity.yieldIfValid(visualizerData, to: visualizerSink)
    }
}
