// ABOUTME: Server message dispatch and handling for SendspinClient
// ABOUTME: Text/binary message routing, protocol message handlers, audio chunk processing

import Foundation
import os

// MARK: - Text message dispatch

extension SendspinClient {
    nonisolated func handleTextMessage(_ text: String) async {
        guard let data = text.data(using: .utf8) else { return }

        // Extract the type string first, then decode the correct type in one pass.
        // This avoids the O(n) try-all-types chain where every message pays the cost
        // of trying earlier types, and eliminates cross-type ambiguity from messages
        // with all-optional payloads (like ServerStateMessage).
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msgType = json["type"] as? String
        else {
            Log.client.error("Message missing 'type' field: \(text.prefix(200))")
            return
        }

        Log.client.debug("RX \(msgType)")

        let decoder = JSONDecoder()
        // NOTE: Do NOT use .convertFromSnakeCase — our models define explicit CodingKeys.

        do {
            switch msgType {
            case "server/hello":
                try await handleServerHello(decoder.decode(ServerHelloMessage.self, from: data))
            case "server/time":
                try await handleServerTime(decoder.decode(ServerTimeMessage.self, from: data))
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
}

// MARK: - Binary message dispatch

extension SendspinClient {
    nonisolated func handleBinaryMessage(_ data: Data) async {
        guard let message = BinaryMessage(data: data) else { return }

        switch message.type {
        case .audioChunk:
            await handleAudioChunk(message)

        case .artworkChannel0, .artworkChannel1, .artworkChannel2, .artworkChannel3:
            await handleArtworkBinary(message)

        case .visualizerData:
            eventsContinuation.yield(.visualizerData(message.data))
        }
    }
}

// MARK: - Message handlers

extension SendspinClient {
    func handleServerHello(_ message: ServerHelloMessage) async {
        updateConnectionState(.connected)

        // Track server identity and connection reason for multi-server logic
        currentServerId = message.payload.serverId
        currentConnectionReason = message.payload.connectionReason

        let info = ServerInfo(
            serverId: message.payload.serverId,
            name: message.payload.name,
            version: message.payload.version,
            connectionReason: message.payload.connectionReason,
            // Wire format is an array; duplicates (if any) are harmlessly deduplicated.
            activeRoles: Set(message.payload.activeRoles)
        )
        eventsContinuation.yield(.serverConnected(info))

        // Send initial client state (required by spec)
        try? await sendClientState()

        // Perform initial clock sync, then start continuous loop
        try? await performInitialSync()
        clockSyncTask = Task.detached { [weak self] in
            await self?.runClockSync()
        }
    }

    func handleServerTime(_ message: ServerTimeMessage) async {
        guard let clockSync else { return }

        let now = getCurrentMicroseconds()
        await clockSync.processServerTime(
            clientTransmitted: message.payload.clientTransmitted,
            serverReceived: message.payload.serverReceived,
            serverTransmitted: message.payload.serverTransmitted,
            clientReceived: now
        )

        // Push updated time filter state to the audio callback for sync correction.
        // This is the only cross-boundary needed — the callback does all the math.
        // snapshot() returns nil when the filter is uninitialized (before
        // first sync or after a reset). In that case the audio player keeps
        // its existing snapshot and plays unsynchronized.
        if let audioPlayer, let snapshot = await clockSync.snapshot() {
            await audioPlayer.updateTimeSnapshot(snapshot)
        }
    }

    func handleServerState(_ message: ServerStateMessage) async {
        // Per spec: "Only include fields that have changed. The client will merge
        // these updates into existing state. Fields set to null should be cleared."
        if let metadata = message.payload.metadata {
            let prev = currentMetadata

            // Build progress: Nullable.merge handles absent vs null vs value
            let mergedProgress = metadata.progress.merge(previous: prev?.progress.flatMap { p in
                MetadataProgress(trackProgress: p.trackProgressMs, trackDuration: p.trackDurationMs, playbackSpeed: p.playbackSpeedX1000)
            })
            var progress: PlaybackProgress?
            if let p = mergedProgress {
                progress = PlaybackProgress(
                    trackProgressMs: p.trackProgress ?? 0,
                    trackDurationMs: p.trackDuration ?? 0,
                    playbackSpeedX1000: p.playbackSpeed ?? 1_000,
                    timestamp: metadata.timestamp ?? 0
                )
            }

            // Merge using Nullable: .absent keeps previous, .null clears, .value updates
            let merged = TrackMetadata(
                title: metadata.title.merge(previous: prev?.title),
                artist: metadata.artist.merge(previous: prev?.artist),
                album: metadata.album.merge(previous: prev?.album),
                albumArtist: metadata.albumArtist.merge(previous: prev?.albumArtist),
                track: metadata.track.merge(previous: prev?.track),
                year: metadata.year.merge(previous: prev?.year),
                artworkURL: metadata.artworkUrl.merge(previous: prev?.artworkURL),
                progress: progress,
                repeatMode: metadata.repeat.merge(previous: prev?.repeatMode),
                shuffle: metadata.shuffle.merge(previous: prev?.shuffle)
            )
            updateMetadata(merged)
            eventsContinuation.yield(.metadataReceived(merged))
        }

        // try? is deliberate: throws .notConnected if player role not configured
        // (see handleServerCommand for rationale)
        if let player = message.payload.player {
            if let volume = player.volume {
                try? await setVolume(volume)
            }
            if let muted = player.muted {
                try? await setMute(muted)
            }
        }

        if let controller = message.payload.controller {
            let prev = currentControllerState
            let cmds: Set<ControllerCommandType> = controller.supportedCommands
                .map { Set($0) }
                ?? prev?.supportedCommands ?? []
            let vol = min(max(controller.volume ?? prev?.volume ?? 0, 0), 100)
            let muted = controller.muted ?? prev?.muted ?? false

            let state = ControllerState(
                supportedCommands: cmds,
                volume: vol,
                muted: muted
            )
            updateControllerState(state)
            eventsContinuation.yield(.controllerStateUpdated(state))
        }
    }

    func handleStreamStart(_ message: StreamStartMessage) async {
        // Handle artwork stream start
        if let artworkInfo = message.payload.artwork {
            artworkStreamActive = true
            eventsContinuation.yield(.artworkStreamStarted(artworkInfo.channels))
        }

        // Handle player stream start
        guard let playerInfo = message.payload.player else {
            Log.client.info("stream/start: artwork only (no player payload)")
            return
        }
        guard let audioPlayer else {
            Log.client.error("stream/start: player payload received but audioPlayer is nil!")
            return
        }
        Log.client.info("stream/start: \(playerInfo.codec) \(playerInfo.sampleRate)Hz \(playerInfo.channels)ch \(playerInfo.bitDepth)bit")

        guard let codec = AudioCodec(rawValue: playerInfo.codec) else {
            updateConnectionState(.error(.unsupportedCodec(playerInfo.codec)))
            clientOperationalState = .error
            try? await sendClientState()
            return
        }

        let format: AudioFormatSpec
        do {
            format = try AudioFormatSpec(
                codec: codec,
                channels: playerInfo.channels,
                sampleRate: playerInfo.sampleRate,
                bitDepth: playerInfo.bitDepth
            )
        } catch {
            updateConnectionState(.error(.invalidFormat(error.errorDescription ?? "\(error)")))
            clientOperationalState = .error
            try? await sendClientState()
            return
        }

        var codecHeader: Data?
        if let headerBase64 = playerInfo.codecHeader {
            codecHeader = Data(base64Encoded: headerBase64)
        }
        updateCodecHeader(codecHeader)
        shouldEmitRawAudio = playerConfig?.emitRawAudioEvents ?? false

        let wasPlaying = await audioPlayer.isPlaying
        let previousFormat = currentStreamFormat
        let isFormatChange = wasPlaying && previousFormat != nil && previousFormat != format

        if isFormatChange {
            // Seamless mid-stream format transition.
            //
            // 1. Bump generation — chunks are tagged at scheduling time, so
            //    runSchedulerOutput can tell old-format from new-format chunks
            // 2. Swap decoder — new binary chunks get decoded at the new rate
            // 3. Store pending format for deferred AudioQueue rebuild
            // 4. DON'T clear scheduler — old chunks continue playing through
            //    the old AudioQueue, providing seamless audio coverage
            // 5. DON'T stop AudioQueue — it keeps running from its ring buffer
            //
            // When runSchedulerOutput sees the first chunk with the new generation,
            // it rebuilds the AudioQueue at the new sample rate. Old-gen chunks
            // play through the old AudioQueue until that point.
            streamGeneration &+= 1
            pendingFormat = format
            pendingCodecHeader = codecHeader
            updateStreamFormat(format)

            // Swap decoder for new incoming chunks
            do {
                try await audioPlayer.swapDecoder(format: format, codecHeader: codecHeader)
            } catch {
                Log.client.error("Decoder swap failed, full restart: \(error)")
                pendingFormat = nil
                pendingCodecHeader = nil
                try? await audioPlayer.start(format: format, codecHeader: codecHeader)
            }

            // swiftlint:disable:next force_unwrapping
            let oldRate = previousFormat!.sampleRate
            Log.client.info("Format change: \(oldRate)Hz → \(format.sampleRate)Hz")
            eventsContinuation.yield(.streamFormatChanged(format))
            try? await sendClientState()
            return
        }

        do {
            try await audioPlayer.start(format: format, codecHeader: codecHeader)
            updateStreamFormat(format)
            clientOperationalState = .synchronized
            await audioScheduler?.startScheduling()

            if !wasPlaying {
                eventsContinuation.yield(.streamStarted(format))
            }
            try? await sendClientState()
        } catch {
            updateConnectionState(.error(.audioStartFailed(error.localizedDescription)))
            clientOperationalState = .error
            try? await sendClientState()
        }
    }

    func handleStreamClear(_ message: StreamClearMessage) async {
        let roles = message.payload.roles

        if roles == nil || roles?.contains("player") == true {
            await audioScheduler?.clear()
            if let audioPlayer {
                await audioPlayer.clearBuffer()
            }
            eventsContinuation.yield(.streamCleared)
        }
    }

    func handleServerCommand(_ message: ServerCommandMessage) async {
        guard let playerCmd = message.payload.player else { return }

        // try? is deliberate: these throw .notConnected if audioPlayer is nil
        // (player role not configured), but the server may send player commands
        // to any client. Silently ignoring commands for unconfigured roles is
        // correct — the server doesn't know our role configuration until it
        // reads our client/hello.
        switch playerCmd.command {
        case .volume:
            if let volume = playerCmd.volume {
                try? await setVolume(volume)
            }
        case .mute:
            if let mute = playerCmd.mute {
                try? await setMute(mute)
            }
        case .setStaticDelay:
            if let delayMs = playerCmd.staticDelayMs {
                try? await setStaticDelay(delayMs)
            }
        }
    }

    func handleStreamEnd(_ message: StreamEndMessage) async {
        // stream/end with no roles ends all streams
        let endedRoles = message.payload.roles

        if endedRoles == nil || endedRoles?.contains("player") == true {
            if let audioPlayer {
                await audioScheduler?.stop()
                await audioScheduler?.clear()
                await audioPlayer.stop()
            }
            updateStreamFormat(nil)
            updateCodecHeader(nil)
        }

        if endedRoles == nil || endedRoles?.contains("artwork") == true {
            artworkStreamActive = false
        }

        clientOperationalState = .synchronized
        eventsContinuation.yield(.streamEnded)
    }

    func handleGroupUpdate(_ message: GroupUpdateMessage) async {
        // Per spec: persist server_id when playback_state transitions to 'playing'.
        // Emitted as an event so the host app can persist using its own storage.
        if message.payload.playbackState == .playing, let serverId = currentServerId {
            eventsContinuation.yield(.lastPlayedServerChanged(serverId: serverId))
        }

        // Per spec: "Contains delta updates with only the changed fields.
        // The client should merge these updates into existing state."
        let prev = currentGroup
        let playbackState = message.payload.playbackState ?? prev?.playbackState

        let info = GroupInfo(
            groupId: message.payload.groupId ?? prev?.groupId ?? "",
            groupName: message.payload.groupName ?? prev?.groupName ?? "",
            playbackState: playbackState
        )
        updateGroup(info)
        eventsContinuation.yield(.groupUpdated(info))
    }
}

// MARK: - Audio chunk handling

extension SendspinClient {
    /// Handle artwork binary frames on the main actor.
    ///
    /// The spec says binary messages "should be rejected if there is no active stream."
    /// We intentionally don't gate on `artworkStreamActive` here because binary and text
    /// messages arrive on parallel tasks — artwork binary frames can (and do) arrive
    /// before the `stream/start` text message that sets the flag. The binary message
    /// type (8-11) already validates this is artwork data from the server, which is
    /// sufficient validation. Dropping legitimate frames due to a race would be worse
    /// than delivering them slightly early.
    func handleArtworkBinary(_ message: BinaryMessage) {
        guard let channel = message.type.artworkChannel else { return }
        // Empty payload (no image data) means clear the artwork per spec
        eventsContinuation.yield(.artworkReceived(channel: channel, data: message.data))
    }

    func handleAudioChunk(_ message: BinaryMessage) async {
        // Emit raw audio data before any processing for conformance testing / recording.
        // This must be above the clock-sync guard — the conformance adapter needs every
        // chunk regardless of sync state.
        if shouldEmitRawAudio {
            eventsContinuation.yield(.rawAudioChunk(data: message.data, serverTimestamp: message.timestamp))
        }

        // Don't process audio until clock sync is complete — timestamps would be wrong
        if !isClockSynced {
            if let clockSync, await clockSync.hasSynced {
                isClockSynced = true
                await audioScheduler?.clear()
            } else {
                return
            }
        }

        guard let audioPlayer,
              let audioScheduler
        else { return }

        // Auto-start player if not already started (some servers don't send stream/start)
        let isPlaying = await audioPlayer.isPlaying
        if !isPlaying, !isAutoStarting {
            isAutoStarting = true

            guard let defaultFormat = playerConfig?.supportedFormats.first else {
                isAutoStarting = false
                return
            }

            do {
                try await audioPlayer.start(format: defaultFormat, codecHeader: nil)
                clientOperationalState = .synchronized
                await audioScheduler.startScheduling()
                eventsContinuation.yield(.streamStarted(defaultFormat))
                try? await sendClientState()
            } catch {
                isAutoStarting = false
                return
            }
        } else if !isPlaying, isAutoStarting {
            return // Another chunk is already triggering auto-start
        }

        do {
            let pcmData = try await audioPlayer.decode(message.data)
            // Per spec: subtract static_delay_ms from server timestamp before scheduling
            let adjustedTimestamp = message.timestamp - Int64(staticDelayMs) * 1_000
            await audioScheduler.schedule(pcm: pcmData, serverTimestamp: adjustedTimestamp, generation: streamGeneration)
        } catch {
            // Decode/schedule failure — drop this chunk
        }
    }
}
