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

    // State
    public private(set) var connectionState: ConnectionState = .disconnected
    private var playerState: PlayerStateValue = .synchronized
    private var isAutoStarting = false
    private var isClockSynced = false
    private var currentVolume: Float = 1.0
    private var currentMuted: Bool = false

    // Dependencies
    private var transport: WebSocketTransport?
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
        playerConfig: PlayerConfiguration? = nil
    ) {
        self.clientId = clientId
        self.name = name
        self.roles = roles
        self.playerConfig = playerConfig

        (events, eventsContinuation) = AsyncStream.makeStream()

        if roles.contains(.playerV1) {
            precondition(playerConfig != nil, "Player role requires playerConfig")
        }
    }

    deinit {
        eventsContinuation.finish()
    }

    /// Discover Sendspin servers on the local network
    /// - Parameter timeout: How long to search for servers (default: 3 seconds)
    /// - Returns: Array of discovered servers
    public nonisolated static func discoverServers(timeout: Duration = .seconds(3)) async -> [DiscoveredServer] {
        let discovery = ServerDiscovery()
        await discovery.startDiscovery()

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

    /// Connect to Sendspin server
    @MainActor
    public func connect(to url: URL) async throws {
        guard connectionState == .disconnected else { return }

        connectionState = .connecting

        let transport = WebSocketTransport(url: url)
        let clockSync = ClockSynchronizer()
        let audioScheduler = AudioScheduler(clockSync: clockSync)

        self.transport = transport
        self.clockSync = clockSync
        self.audioScheduler = audioScheduler

        if roles.contains(.playerV1), let playerConfig = playerConfig {
            let bufferManager = BufferManager(capacity: playerConfig.bufferCapacity)
            let audioPlayer = AudioPlayer(bufferManager: bufferManager, clockSync: clockSync)

            self.bufferManager = bufferManager
            self.audioPlayer = audioPlayer

            currentVolume = await audioPlayer.volume
            currentMuted = await audioPlayer.muted
        }

        try await transport.connect()
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

        playerState = .synchronized
        isClockSynced = false
        currentVolume = 1.0
        currentMuted = false

        connectionState = .disconnected
    }

    // MARK: - Outbound messages

    @MainActor
    private func sendClientHello() async throws {
        guard let transport = transport else {
            throw SendspinClientError.notConnected
        }

        var playerV1Support: PlayerSupport?
        if roles.contains(.playerV1), let playerConfig = playerConfig {
            playerV1Support = PlayerSupport(
                supportedFormats: playerConfig.supportedFormats,
                bufferCapacity: playerConfig.bufferCapacity,
                supportedCommands: [.volume, .mute]
            )
        }

        let payload = ClientHelloPayload(
            clientId: clientId,
            name: name,
            deviceInfo: DeviceInfo.current,
            version: 1,
            supportedRoles: Array(roles),
            playerV1Support: playerV1Support,
            metadataV1Support: roles.contains(.metadataV1) ? MetadataSupport() : nil,
            artworkV1Support: roles.contains(.artworkV1) ? ArtworkSupport() : nil,
            visualizerV1Support: roles.contains(.visualizerV1) ? VisualizerSupport() : nil
        )

        try await transport.send(ClientHelloMessage(payload: payload))
    }

    private func sendClientState() async throws {
        guard let transport = transport else {
            throw SendspinClientError.notConnected
        }

        guard roles.contains(.playerV1) else { return }

        let volumeInt = Int((currentVolume * 100).rounded())
        let playerStateObject = PlayerStateObject(
            state: playerState,
            volume: volumeInt,
            muted: currentMuted
        )

        try await transport.send(ClientStateMessage(payload: ClientStatePayload(player: playerStateObject)))
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
    }

    // MARK: - Scheduler output

    private nonisolated func runSchedulerOutput() async {
        guard let audioScheduler = await audioScheduler,
              let audioPlayer = await audioPlayer
        else { return }

        for await chunk in audioScheduler.scheduledChunks {
            try? await audioPlayer.playPCM(chunk.pcmData, serverTimestamp: chunk.originalTimestamp)
        }
    }

    /// Runs sync correction at 100ms intervals and telemetry at 1s intervals.
    private nonisolated func runSyncCorrectionAndTelemetry() async {
        var lastTelemetryStats = DetailedSchedulerStats()
        // Wider thresholds than the Rust defaults (3ms/1.5ms) because we update at
        // 100ms intervals vs Rust's ~5ms. Measurement jitter is ±5ms at this rate,
        // so we need thresholds above the noise floor.
        let planner = CorrectionPlanner(
            deadbandMicroseconds: 5_000,    // 5ms (was 1.5ms)
            engageMicroseconds: 10_000,     // 10ms (was 3ms)
            reanchorThresholdMicroseconds: 500_000
        )
        var tickCount = 0
        // Cache AudioQueue latency (constant for a given format)
        var cachedAqLatencyUs: Int64 = 0

        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            tickCount += 1

            guard let audioScheduler = await audioScheduler,
                  let clockSync = await clockSync,
                  let audioPlayer = await audioPlayer else { continue }

            // --- Sync correction (every 100ms) ---
            let cursorUs = await audioPlayer.playbackCursorMicroseconds
            if cursorUs > 0, await clockSync.hasSynced {
                let nowAbsolute = Int64(Date().timeIntervalSince1970 * 1_000_000)
                let expectedServerTime = await clockSync.localTimeToServer(nowAbsolute)

                // Compute AQ latency once
                if cachedAqLatencyUs == 0 {
                    let sr = await audioPlayer.currentSampleRate
                    let fs = await audioPlayer.currentFrameSize
                    if fs > 0, sr > 0 {
                        // ~2 buffers active at a time (1 playing + 1 queued)
                        cachedAqLatencyUs = Int64(2 * 16384) * 1_000_000 / Int64(sr * fs)
                    }
                }

                let syncErrorUs = (cursorUs - expectedServerTime) - cachedAqLatencyUs

                let currentSchedule = await audioPlayer.currentCorrectionSchedule
                let schedule = planner.plan(
                    errorMicroseconds: syncErrorUs,
                    sampleRate: UInt32(await audioPlayer.currentSampleRate),
                    currentlyCorrecting: currentSchedule.isCorrecting
                )

                // Correction infrastructure is in place but disabled until the error
                // computation moves into the audio callback for tight-loop stability.
                // At 100ms update intervals, the drop/insert feedback loop diverges.
                // See: Rust synced_player.rs which computes error at ~5ms in the cpal callback.
                _ = schedule
            }

            // --- Telemetry (every 1s = every 10 ticks) ---
            if tickCount % 10 == 0 {
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

                let syncErrorUs = cursorUs > 0
                    ? (cursorUs - (await clockSync.localTimeToServer(
                        Int64(Date().timeIntervalSince1970 * 1_000_000)
                    ))) - cachedAqLatencyUs
                    : Int64(0)

                let currentSchedule = await audioPlayer.currentCorrectionSchedule

                fputs("[TELEMETRY] framesScheduled=\(framesScheduled), framesPlayed=\(framesPlayed), framesDroppedLate=\(framesDroppedLate), framesDroppedOther=\(framesDroppedOther), bufferFillMs=\(String(format: "%.1f", currentStats.bufferFillMs)), clockOffsetMs=\(String(format: "%.2f", clockOffsetMs)), rttMs=\(String(format: "%.2f", rttMs)), queueSize=\(currentStats.queueSize), syncErrorUs=\(syncErrorUs), correcting=\(currentSchedule.isCorrecting)\n", stderr)

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
        } else if let message = try? decoder.decode(StreamMetadataMessage.self, from: data), message.type == msgType {
            await handleStreamMetadata(message)
        } else if let message = try? decoder.decode(GroupUpdateMessage.self, from: data), message.type == msgType {
            await handleGroupUpdate(message)
        } else if let message = try? decoder.decode(SessionUpdateMessage.self, from: data), message.type == msgType {
            await handleSessionUpdate(message)
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
            let channel = Int(message.type.rawValue - 8)
            eventsContinuation.yield(.artworkReceived(channel: channel, data: message.data))

        case .visualizerData:
            eventsContinuation.yield(.visualizerData(message.data))
        }
    }

    // MARK: - Message handlers

    private func handleServerHello(_ message: ServerHelloMessage) async {
        connectionState = .connected

        let info = ServerInfo(
            serverId: message.payload.serverId,
            name: message.payload.name,
            version: message.payload.version
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
    }

    private func handleServerState(_ message: ServerStateMessage) async {
        if let metadata = message.payload.metadata {
            let trackMetadata = TrackMetadata(
                title: metadata.title,
                artist: metadata.artist,
                album: metadata.album,
                albumArtist: metadata.albumArtist,
                track: metadata.track,
                duration: nil,
                year: metadata.year,
                artworkUrl: metadata.artworkUrl
            )
            eventsContinuation.yield(.metadataReceived(trackMetadata))
        }

        if let player = message.payload.player {
            if let volume = player.volume {
                await setVolume(Float(volume) / 100.0)
            }
            if let muted = player.muted {
                await setMute(muted)
            }
        }
    }

    private func handleStreamStart(_ message: StreamStartMessage) async {
        guard let playerInfo = message.payload.player else { return }
        guard let audioPlayer = audioPlayer else { return }

        guard let codec = AudioCodec(rawValue: playerInfo.codec) else {
            connectionState = .error("Unsupported codec: \(playerInfo.codec)")
            playerState = .error
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

        do {
            try await audioPlayer.start(format: format, codecHeader: codecHeader)
            playerState = .synchronized
            await audioScheduler?.startScheduling()

            if !wasPlaying {
                eventsContinuation.yield(.streamStarted(format))
            }
            try? await sendClientState()
        } catch {
            connectionState = .error("Failed to start audio: \(error.localizedDescription)")
            playerState = .error
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
                let clamped = max(0, min(100, volume))
                await setVolume(Float(clamped) / 100.0)
            }
        case "mute":
            if let mute = playerCmd.mute {
                await setMute(mute)
            }
        default:
            break // Ignore unsupported commands per spec
        }
    }

    private func handleStreamEnd(_: StreamEndMessage) async {
        guard let audioPlayer = audioPlayer else { return }

        await audioScheduler?.stop()
        await audioScheduler?.clear()
        await audioPlayer.stop()
        playerState = .synchronized
        eventsContinuation.yield(.streamEnded)
    }

    private func handleGroupUpdate(_ message: GroupUpdateMessage) async {
        if let groupId = message.payload.groupId,
           let groupName = message.payload.groupName {
            let info = GroupInfo(
                groupId: groupId,
                groupName: groupName,
                playbackState: message.payload.playbackState
            )
            eventsContinuation.yield(.groupUpdated(info))
        }
    }

    private func handleStreamMetadata(_ message: StreamMetadataMessage) async {
        let metadata = TrackMetadata(
            title: message.payload.title,
            artist: message.payload.artist,
            album: message.payload.album,
            albumArtist: nil,
            track: nil,
            duration: nil,
            year: nil,
            artworkUrl: message.payload.artworkUrl
        )
        eventsContinuation.yield(.metadataReceived(metadata))
    }

    private func handleSessionUpdate(_ message: SessionUpdateMessage) async {
        if let sessionMetadata = message.payload.metadata {
            let metadata = TrackMetadata(
                title: sessionMetadata.title,
                artist: sessionMetadata.artist,
                album: sessionMetadata.album,
                albumArtist: sessionMetadata.albumArtist,
                track: sessionMetadata.track,
                duration: sessionMetadata.trackDuration,
                year: sessionMetadata.year,
                artworkUrl: sessionMetadata.artworkUrl
            )
            eventsContinuation.yield(.metadataReceived(metadata))
        }
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
                playerState = .synchronized
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
            await audioScheduler.schedule(pcm: pcmData, serverTimestamp: message.timestamp)
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

    /// Set playback volume (0.0 to 1.0)
    @MainActor
    public func setVolume(_ volume: Float) async {
        guard let audioPlayer = audioPlayer else { return }

        let clampedVolume = max(0.0, min(1.0, volume))
        await audioPlayer.setVolume(clampedVolume)
        currentVolume = await audioPlayer.volume

        try? await sendClientState()
    }

    /// Set mute state
    @MainActor
    public func setMute(_ muted: Bool) async {
        guard let audioPlayer = audioPlayer else { return }

        await audioPlayer.setMute(muted)
        currentMuted = await audioPlayer.muted

        try? await sendClientState()
    }
}

// MARK: - Supporting types

public enum ClientEvent: Sendable {
    case serverConnected(ServerInfo)
    case streamStarted(AudioFormatSpec)
    case streamEnded
    case groupUpdated(GroupInfo)
    case metadataReceived(TrackMetadata)
    case artworkReceived(channel: Int, data: Data)
    case visualizerData(Data)
    case error(String)
}

public struct ServerInfo: Sendable {
    public let serverId: String
    public let name: String
    public let version: Int
}

public struct GroupInfo: Sendable {
    public let groupId: String
    public let groupName: String
    public let playbackState: String?
}

public struct TrackMetadata: Sendable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let albumArtist: String?
    public let track: Int?
    public let duration: Int?
    public let year: Int?
    public let artworkUrl: String?
}

public enum SendspinClientError: Error {
    case notConnected
    case unsupportedCodec(String)
    case audioSetupFailed
}
