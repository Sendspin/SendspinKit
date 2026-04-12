// ABOUTME: Main orchestrator for Sendspin protocol client
// ABOUTME: Manages WebSocket connection, message handling, clock sync, and audio playback

import Foundation
import Observation

/// Main Sendspin client
@Observable
@MainActor
public final class SendspinClient {
    // Configuration
    private let clientId: String
    private let name: String
    private let roles: Set<VersionedRole>
    private let playerConfig: PlayerConfiguration?
    private let artworkConfig: ArtworkConfiguration?
    /// Resolved volume capabilities and control implementation
    private let volumeCapabilities: VolumeCapabilities
    private let volumeControl: VolumeControl

    // State
    public private(set) var connectionState: ConnectionState = .disconnected
    /// The audio format currently being streamed by the server, or nil if no stream is active.
    public private(set) var currentStreamFormat: AudioFormatSpec?
    private var clientOperationalState: ClientOperationalState = .synchronized
    private var isAutoStarting = false
    private var isClockSynced = false
    /// Incremented on format changes so the scheduler output loop can detect the boundary.
    private var streamGeneration: UInt64 = 0
    /// Deferred format + codec header for seamless mid-stream format transitions.
    /// Set in handleStreamStart; consumed by runSchedulerOutput when the first
    /// new-generation chunk arrives.
    private var pendingFormat: AudioFormatSpec?
    private var pendingCodecHeader: Data?
    private var currentVolume: Int = 100
    private var currentMuted: Bool = false
    /// Current static delay in milliseconds. Initialized from `PlayerConfiguration.initialStaticDelayMs`,
    /// updated when the server sends a `set_static_delay` command.
    public private(set) var staticDelayMs: Int
    private var artworkStreamActive = false

    // Accumulated state (merged from server deltas per spec)
    /// Current track metadata, accumulated from `server/state` deltas.
    public private(set) var currentMetadata: TrackMetadata?
    /// Current group info, accumulated from `group/update` deltas.
    public private(set) var currentGroup: GroupInfo?
    /// Current controller state from the server.
    public private(set) var currentControllerState: ControllerState?

    // Multi-server state
    private var currentConnectionReason: ConnectionReason?
    private var currentServerId: String?

    /// Key used to persist the last-played server ID (spec requires persistence across reboots)
    private static let lastPlayedServerKey = "SendspinKit.lastPlayedServerId"

    // Dependencies
    private var transport: (any SendspinTransport)?
    private var clockSync: ClockSynchronizer?
    private var audioScheduler: AudioScheduler<ClockSynchronizer>?
    private var bufferManager: BufferManager?
    private var audioPlayer: AudioPlayer?

    // Task management
    private var messageLoopTask: Task<Void, Never>?
    private var clockSyncTask: Task<Void, Never>?
    private var schedulerOutputTask: Task<Void, Never>?
    private var schedulerStatsTask: Task<Void, Never>?

    // Event stream
    private let eventsContinuation: AsyncStream<ClientEvent>.Continuation
    public let events: AsyncStream<ClientEvent>

    public init(
        clientId: String,
        name: String,
        roles: Set<VersionedRole>,
        playerConfig: PlayerConfiguration? = nil,
        artworkConfig: ArtworkConfiguration? = nil
    ) {
        self.clientId = clientId
        self.name = name
        self.roles = roles
        self.playerConfig = playerConfig
        self.artworkConfig = artworkConfig
        self.staticDelayMs = playerConfig?.initialStaticDelayMs ?? 0

        // Resolve volume mode into concrete capabilities and control implementation
        let resolved = VolumeControlFactory.resolve(mode: playerConfig?.volumeMode ?? .software)
        self.volumeCapabilities = resolved.capabilities
        self.volumeControl = resolved.control

        (events, eventsContinuation) = AsyncStream.makeStream()

        if roles.contains(.playerV1) {
            precondition(playerConfig != nil, "Player role requires playerConfig")
        }
        if roles.contains(.artworkV1) {
            precondition(artworkConfig != nil, "Artwork role requires artworkConfig")
        }
    }

    deinit {
        eventsContinuation.finish()
    }

    /// Continuously discover Sendspin servers on the local network.
    ///
    /// Returns a `ServerDiscovery` whose `servers` stream emits an updated list
    /// whenever servers appear or disappear. The caller owns the lifecycle —
    /// call `stopDiscovery()` when done.
    ///
    /// ```swift
    /// let discovery = await SendspinClient.discoverServers()
    /// for await servers in discovery.servers {
    ///     print("Found \(servers.count) server(s)")
    /// }
    /// // Later:
    /// await discovery.stopDiscovery()
    /// ```
    public nonisolated static func discoverServers() async -> ServerDiscovery {
        let discovery = ServerDiscovery()
        await discovery.startDiscovery()
        return discovery
    }

    /// Discover Sendspin servers on the local network (one-shot with timeout).
    ///
    /// Convenience wrapper that browses for `timeout`, then returns whatever was found.
    /// For continuous discovery (live-updating server list), use `discoverServers()`
    /// which returns a `ServerDiscovery` with an async stream.
    ///
    /// - Parameter timeout: How long to search for servers (default: 3 seconds)
    /// - Returns: Array of discovered servers
    public nonisolated static func discoverServers(timeout: Duration = .seconds(3)) async -> [DiscoveredServer] {
        let discovery = await discoverServers()

        return await withTaskGroup(of: [DiscoveredServer].self) { group in
            var latestServers: [DiscoveredServer] = []

            group.addTask {
                var collected: [DiscoveredServer] = []
                for await discoveredServers in discovery.servers {
                    collected = discoveredServers
                }
                return collected
            }

            group.addTask {
                try? await Task.sleep(for: timeout)
                await discovery.stopDiscovery()
                return []
            }

            for await result in group where !result.isEmpty {
                latestServers = result
            }

            return latestServers
        }
    }

    // MARK: - Connection lifecycle

    /// Connect to a Sendspin server at the given URL (client-initiated connection).
    @MainActor
    public func connect(to url: URL) async throws {
        guard connectionState == .disconnected else { return }

        connectionState = .connecting

        let transport = WebSocketTransport(url: url)
        try await transport.connect()

        try await setupConnection(with: transport)
    }

    /// Accept an incoming server connection (server-initiated connection).
    /// Used with `ClientAdvertiser` when servers connect to this client.
    ///
    /// If the client is already connected to a server, the multi-server decision
    /// logic from the spec is applied after the handshake completes.
    @MainActor
    public func acceptConnection(_ transport: any SendspinTransport) async throws {
        if connectionState == .disconnected {
            connectionState = .connecting
            try await setupConnection(with: transport)
        } else {
            // Already connected — run handshake on new connection, then decide
            try await handleCompetingConnection(transport)
        }
    }

    /// Common setup for both client-initiated and server-initiated connections.
    @MainActor
    private func setupConnection(with transport: any SendspinTransport) async throws {
        let clockSync = ClockSynchronizer()
        let audioScheduler = AudioScheduler(clockSync: clockSync)

        self.transport = transport
        self.clockSync = clockSync
        self.audioScheduler = audioScheduler

        if roles.contains(.playerV1), let playerConfig = playerConfig {
            let bufferManager = BufferManager(capacity: playerConfig.bufferCapacity)
            // PCM ring buffer holds decompressed audio for the AudioQueue pipeline.
            // Size it relative to the compressed buffer: compressed audio expands ~10-20x
            // when decoded, but we only need ~2-3s of headroom. Use half the compressed
            // capacity as a reasonable default (512KB for a typical 1MB buffer).
            let pcmBufferCapacity = max(playerConfig.bufferCapacity / 2, 131_072) // min 128KB
            let audioPlayer = AudioPlayer(bufferManager: bufferManager, clockSync: clockSync, pcmBufferCapacity: pcmBufferCapacity, volumeControl: volumeControl)

            self.bufferManager = bufferManager
            self.audioPlayer = audioPlayer

            currentMuted = await audioPlayer.muted
        }

        try await sendClientHello()

        let textStream = transport.textMessages
        let binaryStream = transport.binaryMessages

        messageLoopTask = Task.detached { [weak self] in
            await self?.runMessageLoop(textStream: textStream, binaryStream: binaryStream)
        }

        // Clock sync starts after server/hello is received (in handleServerHello)

        schedulerOutputTask = Task.detached { [weak self] in
            await self?.runSchedulerOutput()
        }

        schedulerStatsTask = Task.detached { [weak self] in
            await self?.runSyncCorrectionAndTelemetry()
        }
    }

    /// Disconnect from server
    @MainActor
    public func disconnect(reason: GoodbyeReason = .shutdown) async {
        // Send client/goodbye before tearing down (best-effort)
        if let transport = transport {
            let goodbye = ClientGoodbyeMessage(
                payload: GoodbyePayload(reason: reason)
            )
            try? await transport.send(goodbye)
        }

        messageLoopTask?.cancel()
        clockSyncTask?.cancel()
        schedulerOutputTask?.cancel()
        schedulerStatsTask?.cancel()
        messageLoopTask = nil
        clockSyncTask = nil
        schedulerOutputTask = nil
        schedulerStatsTask = nil

        if let audioPlayer = audioPlayer {
            await audioPlayer.stop()
        }

        await audioScheduler?.finish()
        await audioScheduler?.clear()
        await transport?.disconnect()

        transport = nil
        clockSync = nil
        audioScheduler = nil
        bufferManager = nil
        audioPlayer = nil

        clientOperationalState = .synchronized
        isClockSynced = false
        currentVolume = 100
        currentMuted = false
        currentStreamFormat = nil
        pendingFormat = nil
        pendingCodecHeader = nil
        artworkStreamActive = false
        currentConnectionReason = nil
        currentServerId = nil
        currentMetadata = nil
        currentControllerState = nil
        // Don't clear currentGroup — spec says group membership persists across reconnections

        connectionState = .disconnected
        eventsContinuation.yield(.disconnected(reason: .explicit(reason)))
    }

    // MARK: - Multi-server logic

    /// Handle a competing server connection per the spec's multi-server rules.
    ///
    /// The spec says to complete the handshake with the new server before deciding.
    /// However, reading server/hello from a separate stream would consume other
    /// messages (like stream/start) that the normal message loop needs. Instead,
    /// we take a simpler approach: switch to the new server unconditionally and
    /// let the normal handleServerHello track the connection reason. If the old
    /// server had playback priority, it will reconnect and reclaim us.
    ///
    /// This matches the real-world behavior: servers reconnect with
    /// connection_reason: playback when they need a client for playback.
    @MainActor
    private func handleCompetingConnection(_ newTransport: any SendspinTransport) async throws {
        // Disconnect old server with 'another_server'
        await disconnect(reason: .anotherServer)

        // Set up normally with new transport — the regular message loop
        // will handle server/hello (tracking connectionReason) and stream/start
        connectionState = .connecting
        try await setupConnection(with: newTransport)
    }

    /// Determine whether to switch to a new server per spec rules.
    private func shouldSwitchToNewServer(
        existingReason: ConnectionReason?,
        newReason: ConnectionReason,
        newServerId: String
    ) -> Bool {
        // If new server's connection_reason is 'playback' → switch
        if newReason == .playback {
            return true
        }

        // If new is 'discovery' and existing was 'playback' → keep existing
        if existingReason == .playback {
            return false
        }

        // Both are 'discovery': prefer last-played server
        let lastPlayed = Self.lastPlayedServerId
        if let lastPlayed = lastPlayed, newServerId == lastPlayed {
            return true
        }

        // Otherwise keep existing
        return false
    }

    /// Persist the server that most recently had playback_state: 'playing'.
    /// Spec: "Clients must persistently store the server_id of the server that
    /// most recently had playback_state: 'playing' (the 'last played server')."
    public static var lastPlayedServerId: String? {
        get { UserDefaults.standard.string(forKey: lastPlayedServerKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastPlayedServerKey) }
    }

    // MARK: - Outbound messages

    /// Build the client/hello payload (used by both connect paths)
    private func buildClientHelloPayload() -> ClientHelloPayload {
        var playerV1Support: PlayerSupport?
        if roles.contains(.playerV1), let playerConfig = playerConfig {
            playerV1Support = PlayerSupport(
                supportedFormats: playerConfig.supportedFormats,
                bufferCapacity: playerConfig.bufferCapacity,
                supportedCommands: volumeCapabilities.playerCommands
            )
        }

        var artworkV1Support: ArtworkSupport?
        if roles.contains(.artworkV1), let artworkConfig = artworkConfig {
            artworkV1Support = ArtworkSupport(channels: artworkConfig.channels)
        }

        return ClientHelloPayload(
            clientId: clientId,
            name: name,
            deviceInfo: DeviceInfo.current,
            version: 1,
            supportedRoles: Array(roles),
            playerV1Support: playerV1Support,
            artworkV1Support: artworkV1Support,
            visualizerV1Support: roles.contains(.visualizerV1) ? VisualizerSupport() : nil
        )
    }

    @MainActor
    private func sendClientHello() async throws {
        guard let transport = transport else {
            throw SendspinClientError.notConnected
        }

        let payload = buildClientHelloPayload()
        try await transport.send(ClientHelloMessage(payload: payload))
    }

    private func sendClientState() async throws {
        guard let transport = transport else {
            throw SendspinClientError.notConnected
        }

        var playerStateObject: PlayerStateObject?
        if roles.contains(.playerV1) {
            playerStateObject = PlayerStateObject(
                volume: currentVolume,
                muted: currentMuted,
                staticDelayMs: staticDelayMs,
                supportedCommands: ["set_static_delay"]
            )
        }

        let payload = ClientStatePayload(
            state: clientOperationalState,
            player: playerStateObject
        )
        try await transport.send(ClientStateMessage(payload: payload))
    }

    // MARK: - Clock synchronization

    /// Perform initial clock synchronization (5 quick rounds)
    @MainActor
    private func performInitialSync() async throws {
        guard let transport = transport, let clockSync = clockSync else {
            throw SendspinClientError.notConnected
        }

        for _ in 0 ..< 5 {
            let now = getCurrentMicroseconds()
            let message = ClientTimeMessage(payload: ClientTimePayload(clientTransmitted: now))
            try await transport.send(message)
            try? await Task.sleep(for: .milliseconds(100))
        }

        try? await Task.sleep(for: .milliseconds(200))

        // Only mark synced if at least one sample was accepted
        if await clockSync.hasSynced {
            isClockSynced = true
            await audioScheduler?.clear()
        }
        // Otherwise the continuous sync loop will eventually succeed
    }

    private nonisolated func runClockSync() async {
        guard let transport = await transport else { return }

        while !Task.isCancelled {
            do {
                let now = getCurrentMicroseconds()
                let message = ClientTimeMessage(payload: ClientTimePayload(clientTransmitted: now))
                try await transport.send(message)
            } catch {
                break // Connection lost
            }

            try? await Task.sleep(for: .seconds(5))
        }
    }

    // MARK: - Message loop

    private nonisolated func runMessageLoop(
        textStream: AsyncStream<String>,
        binaryStream: AsyncStream<Data>
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self = self else { return }
                for await text in textStream {
                    await self.handleTextMessage(text)
                }
            }

            group.addTask { [weak self] in
                guard let self = self else { return }
                for await data in binaryStream {
                    await self.handleBinaryMessage(data)
                }
            }
        }

        // Both streams ended — connection was lost (not an explicit disconnect,
        // which cancels this task before streams end naturally)
        await MainActor.run { [weak self] in
            guard let self = self else { return }
            if self.connectionState != .disconnected {
                self.connectionState = .disconnected
                self.eventsContinuation.yield(.disconnected(reason: .connectionLost))
            }
        }
    }

    // MARK: - Scheduler output

    /// Number of chunks to pre-buffer before rebuilding the AudioQueue during
    /// a format transition. This gives the AudioQueue headroom so the sync
    /// correction doesn't engage aggressively on the first few samples.
    /// 2 chunks ≈ 200ms — enough headroom without overshooting.
    private nonisolated static let formatTransitionPreBuffer = 2

    private nonisolated func runSchedulerOutput() async {
        guard let audioScheduler = await audioScheduler,
              let audioPlayer = await audioPlayer
        else { return }

        var activeGeneration: UInt64 = await streamGeneration

        for await chunk in audioScheduler.scheduledChunks {
            if chunk.generation != activeGeneration {
                if chunk.generation < activeGeneration {
                    // Old-generation chunk after a format change already happened.
                    // This shouldn't occur since old chunks have earlier timestamps,
                    // but discard just in case.
                    continue
                }

                // New generation — first chunk decoded in the new format.
                // Accumulate a few chunks before rebuilding the AudioQueue
                // so we have buffer headroom for clean sync convergence.
                let pending = await MainActor.run { () -> (AudioFormatSpec?, Data?) in
                    let fmt = self.pendingFormat
                    let hdr = self.pendingCodecHeader
                    self.pendingFormat = nil
                    self.pendingCodecHeader = nil
                    return (fmt, hdr)
                }

                activeGeneration = chunk.generation

                guard let format = pending.0 else {
                    try? await audioPlayer.playPCM(chunk.pcmData, serverTimestamp: chunk.originalTimestamp)
                    continue
                }

                // Pre-buffer: collect this chunk + one more before switching
                var preBuffer: [(pcm: Data, timestamp: Int64)] = [
                    (chunk.pcmData, chunk.originalTimestamp)
                ]

                for await nextChunk in audioScheduler.scheduledChunks {
                    preBuffer.append((nextChunk.pcmData, nextChunk.originalTimestamp))
                    if preBuffer.count >= Self.formatTransitionPreBuffer {
                        break
                    }
                }

                // Rebuild AudioQueue and feed pre-buffered chunks
                fputs("[CLIENT] Seamless switch: rebuilding AudioQueue at \(format.sampleRate)Hz (pre-buffered \(preBuffer.count) chunks)\n", stderr)
                try? await audioPlayer.start(format: format, codecHeader: pending.1)

                for buffered in preBuffer {
                    try? await audioPlayer.playPCM(buffered.pcm, serverTimestamp: buffered.timestamp)
                }
                continue
            }
            try? await audioPlayer.playPCM(chunk.pcmData, serverTimestamp: chunk.originalTimestamp)
        }
    }

    /// Polls for reanchor requests from the audio callback and logs telemetry.
    /// Sync correction is now computed inside the AudioQueue callback itself,
    /// so this loop only handles rare reanchor events and periodic logging.
    private nonisolated func runSyncCorrectionAndTelemetry() async {
        var lastTelemetryStats = DetailedSchedulerStats()
        var tickCount = 0

        while !Task.isCancelled {
            // 500ms poll — reanchors are rare events, no need to check faster.
            // Telemetry logs every 4th tick (2s).
            try? await Task.sleep(for: .milliseconds(500))
            tickCount += 1

            guard let audioScheduler = await audioScheduler,
                  let clockSync = await clockSync,
                  let audioPlayer = await audioPlayer else { continue }

            // --- Poll for reanchor requests from the audio callback ---
            if let reanchorTarget = await audioPlayer.pollReanchor() {
                await audioPlayer.reanchorCursor(to: reanchorTarget)
            }

            // --- Telemetry (every 2s = every 4 ticks) ---
            if tickCount % 4 == 0 {
                let currentStats = await audioScheduler.getDetailedStats()
                guard currentStats.received > 0 else { continue }

                let framesScheduled = currentStats.received - lastTelemetryStats.received
                let framesPlayed = currentStats.played - lastTelemetryStats.played
                let framesDroppedLate = currentStats.droppedLate - lastTelemetryStats.droppedLate
                let framesDroppedOther = currentStats.droppedOther - lastTelemetryStats.droppedOther

                let offset = await clockSync.statsOffset
                let rtt = await clockSync.statsRtt
                let clockOffsetMs = Double(offset) / 1000.0
                let rttMs = Double(rtt) / 1000.0

                // Read sync error computed by the audio callback (precise, no actor jitter)
                let tSnap = await audioPlayer.telemetrySnapshot
                let syncErrorUs = tSnap.syncErrorUs
                let dropN = tSnap.correctionSchedule.dropEveryNFrames
                let insertN = tSnap.correctionSchedule.insertEveryNFrames

                fputs("[TELEMETRY] framesScheduled=\(framesScheduled), framesPlayed=\(framesPlayed), framesDroppedLate=\(framesDroppedLate), framesDroppedOther=\(framesDroppedOther), bufferFillMs=\(String(format: "%.1f", currentStats.bufferFillMs)), clockOffsetMs=\(String(format: "%.2f", clockOffsetMs)), rttMs=\(String(format: "%.2f", rttMs)), queueSize=\(currentStats.queueSize), syncErrorUs=\(syncErrorUs), correcting=\(tSnap.correctionSchedule.isCorrecting), dropEvery=\(dropN), insertEvery=\(insertN)\n", stderr)

                lastTelemetryStats = currentStats
            }
        }
    }

    // MARK: - Text message dispatch

    private nonisolated func handleTextMessage(_ text: String) async {
        let decoder = JSONDecoder()
        // NOTE: Do NOT use .convertFromSnakeCase — our models define explicit CodingKeys.

        guard let data = text.data(using: .utf8) else { return }

        var msgType = "unknown"
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = json["type"] as? String {
            msgType = type
            fputs("[RX] \(msgType)\n", stderr)
        }

        // Order matters: messages with required fields before all-optional ones.
        if let message = try? decoder.decode(ServerHelloMessage.self, from: data), message.type == msgType {
            await handleServerHello(message)
        } else if let message = try? decoder.decode(ServerTimeMessage.self, from: data), message.type == msgType {
            await handleServerTime(message)
        } else if let message = try? decoder.decode(ServerStateMessage.self, from: data), message.type == msgType {
            await handleServerState(message)
        } else if let message = try? decoder.decode(StreamStartMessage.self, from: data), message.type == msgType {
            await handleStreamStart(message)
        } else if let message = try? decoder.decode(StreamClearMessage.self, from: data), message.type == msgType {
            await handleStreamClear(message)
        } else if let message = try? decoder.decode(StreamEndMessage.self, from: data), message.type == msgType {
            await handleStreamEnd(message)
        } else if let message = try? decoder.decode(ServerCommandMessage.self, from: data), message.type == msgType {
            await handleServerCommand(message)
        } else if let message = try? decoder.decode(GroupUpdateMessage.self, from: data), message.type == msgType {
            await handleGroupUpdate(message)
        } else {
            let preview = text.prefix(500)
            fputs("[CLIENT] ❌ Failed to decode message type '\(msgType)': \(preview)\n", stderr)
        }
    }

    // MARK: - Binary message dispatch

    private nonisolated func handleBinaryMessage(_ data: Data) async {
        guard let message = BinaryMessage(data: data) else { return }

        switch message.type {
        case .audioChunk:
            await handleAudioChunkNonisolated(message)

        case .artworkChannel0, .artworkChannel1, .artworkChannel2, .artworkChannel3:
            // Per spec: binary messages should be rejected if there is no active stream
            guard await artworkStreamActive else { return }
            let channel = Int(message.type.rawValue - 8)
            // Empty payload (no image data) means clear the artwork per spec
            eventsContinuation.yield(.artworkReceived(channel: channel, data: message.data))

        case .visualizerData:
            eventsContinuation.yield(.visualizerData(message.data))
        }
    }

    // MARK: - Message handlers

    private func handleServerHello(_ message: ServerHelloMessage) async {
        connectionState = .connected

        // Track server identity and connection reason for multi-server logic
        currentServerId = message.payload.serverId
        currentConnectionReason = message.payload.connectionReason

        let info = ServerInfo(
            serverId: message.payload.serverId,
            name: message.payload.name,
            version: message.payload.version,
            connectionReason: message.payload.connectionReason
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

    private func handleServerTime(_ message: ServerTimeMessage) async {
        guard let clockSync = clockSync else { return }

        let now = getCurrentMicroseconds()
        await clockSync.processServerTime(
            clientTransmitted: message.payload.clientTransmitted,
            serverReceived: message.payload.serverReceived,
            serverTransmitted: message.payload.serverTransmitted,
            clientReceived: now
        )

        // Push updated time filter state to the audio callback for sync correction.
        // This is the only cross-boundary needed — the callback does all the math.
        if let audioPlayer = audioPlayer {
            let snapshot = await clockSync.snapshot()
            await audioPlayer.updateTimeSnapshot(snapshot)
        }
    }

    private func handleServerState(_ message: ServerStateMessage) async {
        // Per spec: "Only include fields that have changed. The client will merge
        // these updates into existing state. Fields set to null should be cleared."
        if let metadata = message.payload.metadata {
            let prev = currentMetadata

            // Build progress: Nullable.merge handles absent vs null vs value
            let mergedProgress = metadata.progress.merge(previous: prev?.progress.flatMap { p in
                MetadataProgress(trackProgress: p.trackProgressMs, trackDuration: p.trackDurationMs, playbackSpeed: p.playbackSpeed)
            })
            var progress: PlaybackProgress?
            if let p = mergedProgress {
                progress = PlaybackProgress(
                    trackProgressMs: p.trackProgress ?? 0,
                    trackDurationMs: p.trackDuration ?? 0,
                    playbackSpeed: p.playbackSpeed ?? 1000,
                    timestamp: metadata.timestamp ?? 0
                )
            }

            // Merge using Nullable: .absent keeps previous, .null clears, .value updates
            let mergedRepeatStr = metadata.repeat.merge(previous: prev?.repeatMode?.rawValue)
            let merged = TrackMetadata(
                title: metadata.title.merge(previous: prev?.title),
                artist: metadata.artist.merge(previous: prev?.artist),
                album: metadata.album.merge(previous: prev?.album),
                albumArtist: metadata.albumArtist.merge(previous: prev?.albumArtist),
                track: metadata.track.merge(previous: prev?.track),
                year: metadata.year.merge(previous: prev?.year),
                artworkUrl: metadata.artworkUrl.merge(previous: prev?.artworkUrl),
                progress: progress,
                repeatMode: mergedRepeatStr.flatMap { RepeatMode(rawValue: $0) },
                shuffle: metadata.shuffle.merge(previous: prev?.shuffle)
            )
            currentMetadata = merged
            eventsContinuation.yield(.metadataReceived(merged))
        }

        if let player = message.payload.player {
            if let volume = player.volume {
                await setVolume(volume)
            }
            if let muted = player.muted {
                await setMute(muted)
            }
        }

        if let controller = message.payload.controller {
            let prev = currentControllerState
            let cmds = controller.supportedCommands?.compactMap { ControllerCommandType(rawValue: $0) }
                ?? prev?.supportedCommands ?? []
            let vol = controller.volume ?? prev?.volume ?? 0
            let muted = controller.muted ?? prev?.muted ?? false

            let state = ControllerState(
                supportedCommands: cmds,
                volume: vol,
                muted: muted
            )
            currentControllerState = state
            eventsContinuation.yield(.controllerStateUpdated(state))
        }
    }

    private func handleStreamStart(_ message: StreamStartMessage) async {
        // Handle artwork stream start
        if let artworkInfo = message.payload.artwork {
            artworkStreamActive = true
            eventsContinuation.yield(.artworkStreamStarted(artworkInfo.channels))
        }

        // Handle player stream start
        guard let playerInfo = message.payload.player else {
            fputs("[CLIENT] stream/start: artwork only (no player payload)\n", stderr)
            return
        }
        guard let audioPlayer = audioPlayer else {
            fputs("[CLIENT] stream/start: player payload received but audioPlayer is nil!\n", stderr)
            return
        }
        fputs("[CLIENT] stream/start: \(playerInfo.codec) \(playerInfo.sampleRate)Hz \(playerInfo.channels)ch \(playerInfo.bitDepth)bit\n", stderr)

        guard let codec = AudioCodec(rawValue: playerInfo.codec) else {
            connectionState = .error("Unsupported codec: \(playerInfo.codec)")
            clientOperationalState = .error
            try? await sendClientState()
            return
        }

        let format = AudioFormatSpec(
            codec: codec,
            channels: playerInfo.channels,
            sampleRate: playerInfo.sampleRate,
            bitDepth: playerInfo.bitDepth
        )

        var codecHeader: Data?
        if let headerBase64 = playerInfo.codecHeader {
            codecHeader = Data(base64Encoded: headerBase64)
        }

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
            currentStreamFormat = format

            // Swap decoder for new incoming chunks
            do {
                try await audioPlayer.swapDecoder(format: format, codecHeader: codecHeader)
            } catch {
                fputs("[CLIENT] Decoder swap failed, falling back to full restart: \(error)\n", stderr)
                pendingFormat = nil
                pendingCodecHeader = nil
                try? await audioPlayer.start(format: format, codecHeader: codecHeader)
            }

            fputs("[CLIENT] Format change: seamless transition (\(previousFormat!.sampleRate)Hz → \(format.sampleRate)Hz), old audio continues\n", stderr)
            eventsContinuation.yield(.streamFormatChanged(format))
            try? await sendClientState()
            return
        }

        do {
            try await audioPlayer.start(format: format, codecHeader: codecHeader)
            currentStreamFormat = format
            clientOperationalState = .synchronized
            await audioScheduler?.startScheduling()

            if !wasPlaying {
                eventsContinuation.yield(.streamStarted(format))
            }
            try? await sendClientState()
        } catch {
            connectionState = .error("Failed to start audio: \(error.localizedDescription)")
            clientOperationalState = .error
            try? await sendClientState()
        }
    }

    private func handleStreamClear(_ message: StreamClearMessage) async {
        let roles = message.payload.roles

        if roles == nil || roles?.contains("player") == true {
            await audioScheduler?.clear()
            if let audioPlayer = audioPlayer {
                await audioPlayer.clearBuffer()
            }
            await bufferManager?.clear()
        }
    }

    private func handleServerCommand(_ message: ServerCommandMessage) async {
        guard let playerCmd = message.payload.player else { return }

        switch playerCmd.command {
        case "volume":
            if let volume = playerCmd.volume {
                await setVolume(volume)
            }
        case "mute":
            if let mute = playerCmd.mute {
                await setMute(mute)
            }
        case "set_static_delay":
            if let delayMs = playerCmd.staticDelayMs {
                await setStaticDelay(max(0, min(5000, delayMs)))
            }
        default:
            break // Ignore unsupported commands per spec
        }
    }

    private func handleStreamEnd(_ message: StreamEndMessage) async {
        // stream/end with no roles ends all streams
        let endedRoles = message.payload.roles

        if endedRoles == nil || endedRoles?.contains("player") == true {
            if let audioPlayer = audioPlayer {
                await audioScheduler?.stop()
                await audioScheduler?.clear()
                await audioPlayer.stop()
            }
            currentStreamFormat = nil
        }

        if endedRoles == nil || endedRoles?.contains("artwork") == true {
            artworkStreamActive = false
        }

        clientOperationalState = .synchronized
        eventsContinuation.yield(.streamEnded)
    }

    private func handleGroupUpdate(_ message: GroupUpdateMessage) async {
        // Per spec: persist server_id when playback_state transitions to 'playing'
        if message.payload.playbackState == "playing", let serverId = currentServerId {
            Self.lastPlayedServerId = serverId
        }

        // Per spec: "Contains delta updates with only the changed fields.
        // The client should merge these updates into existing state."
        let prev = currentGroup
        let playbackState = message.payload.playbackState.flatMap { PlaybackState(rawValue: $0) }
            ?? prev?.playbackState

        let info = GroupInfo(
            groupId: message.payload.groupId ?? prev?.groupId ?? "",
            groupName: message.payload.groupName ?? prev?.groupName ?? "",
            playbackState: playbackState
        )
        currentGroup = info
        eventsContinuation.yield(.groupUpdated(info))
    }

    // MARK: - Audio chunk handling

    private nonisolated func handleAudioChunkNonisolated(_ message: BinaryMessage) async {
        await handleAudioChunk(message)
    }

    private func handleAudioChunk(_ message: BinaryMessage) async {
        // Don't process audio until clock sync is complete — timestamps would be wrong
        if !isClockSynced {
            if let clockSync = clockSync, await clockSync.hasSynced {
                isClockSynced = true
                await audioScheduler?.clear()
            } else {
                return
            }
        }

        guard let audioPlayer = audioPlayer,
              let audioScheduler = audioScheduler
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
            let adjustedTimestamp = message.timestamp - Int64(staticDelayMs) * 1000
            await audioScheduler.schedule(pcm: pcmData, serverTimestamp: adjustedTimestamp, generation: streamGeneration)
        } catch {
            // Decode/schedule failure — drop this chunk
        }
    }

    // MARK: - Utilities

    private nonisolated static let processStartTime = Date()

    private nonisolated func getCurrentMicroseconds() -> Int64 {
        let elapsed = Date().timeIntervalSince(SendspinClient.processStartTime)
        return Int64(elapsed * 1_000_000)
    }

    /// Set playback volume (0-100, perceived loudness per spec)
    @MainActor
    public func setVolume(_ volume: Int) async {
        guard let audioPlayer = audioPlayer else { return }

        let clamped = max(0, min(100, volume))
        currentVolume = clamped
        await audioPlayer.setVolume(Float(clamped) / 100.0)

        try? await sendClientState()
    }

    /// Set mute state
    @MainActor
    public func setMute(_ muted: Bool) async {
        guard let audioPlayer = audioPlayer else { return }

        currentMuted = muted
        await audioPlayer.setMute(muted)

        try? await sendClientState()
    }

    /// Set static delay in milliseconds (0-5000).
    /// Per spec: compensates for delay beyond the audio port (external speakers, amplifiers).
    /// Emits `.staticDelayChanged` so the host app can persist the new value.
    @MainActor
    public func setStaticDelay(_ delayMs: Int) async {
        let clamped = max(0, min(5000, delayMs))
        guard clamped != staticDelayMs else { return }
        staticDelayMs = clamped
        eventsContinuation.yield(.staticDelayChanged(clamped))
        try? await sendClientState()
    }

    // MARK: - Player format negotiation

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
    /// - Switch codec: `requestPlayerFormat(codec: .flac)`
    /// - Match source rate: `requestPlayerFormat(sampleRate: 48000)`
    /// - Full format change: `requestPlayerFormat(codec: .flac, sampleRate: 48000, bitDepth: 24)`
    /// - Downgrade under load: `requestPlayerFormat(codec: .opus)`
    @MainActor
    public func requestPlayerFormat(
        codec: AudioCodec? = nil,
        channels: Int? = nil,
        sampleRate: Int? = nil,
        bitDepth: Int? = nil
    ) async {
        guard let transport = transport else { return }

        let request = PlayerFormatRequest(
            codec: codec?.rawValue,
            channels: channels,
            sampleRate: sampleRate,
            bitDepth: bitDepth
        )
        let message = StreamRequestFormatMessage(
            payload: StreamRequestFormatPayload(player: request)
        )
        try? await transport.send(message)
    }

    /// Request a specific format from the `supportedFormats` list by exact match.
    /// This is a convenience that sends all fields, avoiding server-side fill-in ambiguity.
    @MainActor
    public func requestPlayerFormat(_ format: AudioFormatSpec) async {
        await requestPlayerFormat(
            codec: format.codec,
            channels: format.channels,
            sampleRate: format.sampleRate,
            bitDepth: format.bitDepth
        )
    }

    // MARK: - Artwork commands

    /// Request the server to change artwork format for a specific channel.
    /// The server will respond with stream/start containing the updated config.
    @MainActor
    public func requestArtworkFormat(
        channel: Int,
        source: ArtworkSource? = nil,
        format: ImageFormat? = nil,
        mediaWidth: Int? = nil,
        mediaHeight: Int? = nil
    ) async {
        guard let transport = transport else { return }

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
        try? await transport.send(message)
    }

    // MARK: - Controller commands

    /// Send a controller command to the server.
    /// Only valid if the client has the controller role and the command is in
    /// the server's `supported_commands`.
    @MainActor
    public func sendCommand(_ command: String, volume: Int? = nil, mute: Bool? = nil) async {
        guard let transport = transport else { return }

        let controller = ControllerCommand(command: command, volume: volume, mute: mute)
        let message = ClientCommandMessage(payload: ClientCommandPayload(controller: controller))
        try? await transport.send(message)
    }

    /// Convenience: play
    @MainActor public func play() async { await sendCommand("play") }
    /// Convenience: pause
    @MainActor public func pause() async { await sendCommand("pause") }
    /// Convenience: stop playback
    @MainActor public func stopPlayback() async { await sendCommand("stop") }
    /// Convenience: next track
    @MainActor public func next() async { await sendCommand("next") }
    /// Convenience: previous track
    @MainActor public func previous() async { await sendCommand("previous") }
    /// Convenience: set group volume (0-100)
    @MainActor public func setGroupVolume(_ volume: Int) async {
        await sendCommand("volume", volume: max(0, min(100, volume)))
    }
    /// Convenience: set group mute
    @MainActor public func setGroupMute(_ muted: Bool) async {
        await sendCommand("mute", mute: muted)
    }
    /// Convenience: repeat off
    @MainActor public func repeatOff() async { await sendCommand("repeat_off") }
    /// Convenience: repeat one track
    @MainActor public func repeatOne() async { await sendCommand("repeat_one") }
    /// Convenience: repeat all tracks
    @MainActor public func repeatAll() async { await sendCommand("repeat_all") }
    /// Convenience: shuffle playback
    @MainActor public func shuffle() async { await sendCommand("shuffle") }
    /// Convenience: unshuffle playback
    @MainActor public func unshuffle() async { await sendCommand("unshuffle") }
    /// Convenience: switch to next group
    @MainActor public func switchGroup() async { await sendCommand("switch") }
}

// MARK: - Supporting types

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
    /// - Parameter currentTimeMicros: Current time in microseconds (same clock domain as `timestamp`)
    public func currentPositionMs(at currentTimeMicros: Int64) -> Int {
        let elapsed = currentTimeMicros - timestamp
        let calculated = trackProgressMs + Int(elapsed * Int64(playbackSpeed) / 1_000_000)
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
    case unsupportedCodec(String)
    case audioSetupFailed
}
