// ABOUTME: Main orchestrator for Sendspin protocol client
// ABOUTME: Manages WebSocket connection, message handling, clock sync, and audio playback

import Foundation
import Observation
import os

/// Main Sendspin client
@Observable
@MainActor
public final class SendspinClient {
    // Configuration
    let clientId: String
    let name: String
    let roles: Set<VersionedRole>
    let playerConfig: PlayerConfiguration?
    let artworkConfig: ArtworkConfiguration?
    /// Resolved volume capabilities and control implementation
    let volumeCapabilities: VolumeCapabilities
    let volumeControl: VolumeControl

    // Public-readable, privately-settable state. Extension files in the same module
    // mutate these through internal setter methods below (e.g. `updateConnectionState`),
    // keeping the mutation surface controlled and auditable.

    /// Connection lifecycle state. Observe this (via `@Observable`) to update UI
    /// for connecting/connected/error/disconnected transitions.
    ///
    /// If the state enters `.error(_:)`, the transport is still alive but playback
    /// is broken. Call ``disconnect(reason:)`` followed by ``connect(to:)`` to recover.
    public private(set) var connectionState: ConnectionState = .disconnected
    /// The audio format currently being streamed by the server, or nil if no stream is active.
    public private(set) var currentStreamFormat: AudioFormatSpec?
    var clientOperationalState: ClientOperationalState = .synchronized
    var isAutoStarting = false
    var isClockSynced = false
    /// Incremented on format changes so the scheduler output loop can detect the boundary.
    var streamGeneration: UInt64 = 0
    /// Deferred format + codec header for seamless mid-stream format transitions.
    /// Set in handleStreamStart; consumed by runSchedulerOutput when the first
    /// new-generation chunk arrives.
    var pendingFormat: AudioFormatSpec?
    var pendingCodecHeader: Data?
    /// Current player volume (0-100). Observable for UI binding (volume sliders).
    /// Updated by ``setVolume(_:)`` and by the server via `server/command`.
    public private(set) var currentVolume: Int = 100
    /// Current player mute state. Observable for UI binding (mute buttons).
    /// Updated by ``setMute(_:)`` and by the server via `server/command`.
    public private(set) var currentMuted: Bool = false
    /// Current static delay in milliseconds. Initialized from `PlayerConfiguration.initialStaticDelayMs`,
    /// updated when the server sends a `set_static_delay` command.
    public private(set) var staticDelayMs: Int
    var artworkStreamActive = false
    /// Cached from `playerConfig?.emitRawAudioEvents` to avoid optional chaining on every audio chunk.
    var shouldEmitRawAudio = false

    /// Accumulated state (merged from server deltas per spec)
    /// Current track metadata, accumulated from `server/state` deltas.
    public private(set) var currentMetadata: TrackMetadata?
    /// Current group info, accumulated from `group/update` deltas.
    public private(set) var currentGroup: GroupInfo?
    /// Current controller state from the server.
    public private(set) var currentControllerState: ControllerState?
    /// Codec header for the current stream (e.g. FLAC streaminfo), if any.
    /// Set when `stream/start` carries a `codec_header` field; cleared on `stream/end`.
    public private(set) var currentCodecHeader: Data?

    // Multi-server state
    var currentConnectionReason: ConnectionReason?
    var currentServerId: String?

    // Dependencies
    var transport: (any SendspinTransport)?
    var clockSync: ClockSynchronizer?
    var audioScheduler: AudioScheduler?
    var audioPlayer: AudioPlayer?

    // Task management
    var messageLoopTask: Task<Void, Never>?
    var clockSyncTask: Task<Void, Never>?
    var schedulerOutputTask: Task<Void, Never>?
    var syncTelemetryTask: Task<Void, Never>?

    // Event stream
    let eventsContinuation: AsyncStream<ClientEvent>.Continuation
    public let events: AsyncStream<ClientEvent>

    public init(
        clientId: String,
        name: String,
        roles: Set<VersionedRole>,
        playerConfig: PlayerConfiguration? = nil,
        artworkConfig: ArtworkConfiguration? = nil
    ) throws(ConfigurationError) {
        if roles.contains(.playerV1), playerConfig == nil {
            throw .playerRoleRequiresConfiguration
        }
        if roles.contains(.artworkV1), artworkConfig == nil {
            throw .artworkRoleRequiresConfiguration
        }

        self.clientId = clientId
        self.name = name
        self.roles = roles
        self.playerConfig = playerConfig
        self.artworkConfig = artworkConfig
        staticDelayMs = playerConfig?.initialStaticDelayMs ?? 0

        // Resolve volume mode into concrete capabilities and control implementation
        let resolved = VolumeControlFactory.resolve(mode: playerConfig?.volumeMode ?? .software)
        volumeCapabilities = resolved.capabilities
        volumeControl = resolved.control

        (events, eventsContinuation) = AsyncStream.makeStream()
    }

    deinit {
        eventsContinuation.finish()
    }

    // MARK: - Internal state setters

    // Extension files (SendspinClient+MessageHandling.swift, SendspinClient+Commands.swift)
    // use these methods to mutate `public private(set)` properties. This keeps all
    // mutation in named methods rather than scattered direct assignments.

    func updateConnectionState(_ state: ConnectionState) {
        connectionState = state
    }

    func updateStreamFormat(_ format: AudioFormatSpec?) {
        currentStreamFormat = format
    }

    func updateMetadata(_ metadata: TrackMetadata?) {
        currentMetadata = metadata
    }

    func updateGroup(_ group: GroupInfo?) {
        currentGroup = group
    }

    func updateControllerState(_ state: ControllerState?) {
        currentControllerState = state
    }

    func updateCodecHeader(_ header: Data?) {
        currentCodecHeader = header
    }

    /// Continuously discover Sendspin servers on the local network.
    ///
    /// Returns a `ServerDiscovery` whose `servers` stream emits an updated list
    /// whenever servers appear or disappear. The caller owns the lifecycle —
    /// call `stopDiscovery()` when done.
    ///
    /// ```swift
    /// let discovery = try await SendspinClient.discoverServers()
    /// for await servers in discovery.servers {
    ///     print("Found \(servers.count) server(s)")
    /// }
    /// // Later:
    /// await discovery.stopDiscovery()
    /// ```
    public nonisolated static func discoverServers() async throws -> ServerDiscovery {
        let discovery = ServerDiscovery()
        try await discovery.startDiscovery()
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
    public nonisolated static func discoverServers(timeout: Duration = .seconds(3)) async throws -> [DiscoveredServer] {
        let discovery = try await discoverServers()

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
    ///
    /// - Throws: ``SendspinClientError/alreadyConnected`` if not in the
    ///   `.disconnected` state.
    @MainActor
    public func connect(to url: URL) async throws {
        guard connectionState == .disconnected else {
            throw SendspinClientError.alreadyConnected
        }

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

        if roles.contains(.playerV1), let playerConfig {
            // PCM ring buffer holds decompressed audio for the AudioQueue pipeline.
            // Size it relative to the compressed buffer: compressed audio expands ~10-20x
            // when decoded, but we only need ~2-3s of headroom. Use half the compressed
            // capacity as a reasonable default (512KB for a typical 1MB buffer).
            let pcmBufferCapacity = max(playerConfig.bufferCapacity / 2, 131_072) // min 128KB
            let audioPlayer = AudioPlayer(
                pcmBufferCapacity: pcmBufferCapacity,
                volumeControl: volumeControl,
                processCallback: playerConfig.processCallback
            )

            self.audioPlayer = audioPlayer

            currentMuted = await audioPlayer.muted

            // Set eagerly so raw audio events are emitted even for chunks that
            // arrive before stream/start is processed (binary and text messages
            // are consumed by parallel tasks, so binary chunks can race ahead).
            shouldEmitRawAudio = playerConfig.emitRawAudioEvents
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

        syncTelemetryTask = Task.detached { [weak self] in
            await self?.runSyncCorrectionAndTelemetry()
        }
    }

    /// Disconnect from server
    @MainActor
    public func disconnect(reason: GoodbyeReason = .shutdown) async {
        // Send client/goodbye before tearing down (best-effort)
        if let transport {
            let goodbye = ClientGoodbyeMessage(
                payload: GoodbyePayload(reason: reason)
            )
            try? await transport.send(goodbye)
        }

        messageLoopTask?.cancel()
        clockSyncTask?.cancel()
        schedulerOutputTask?.cancel()
        syncTelemetryTask?.cancel()
        messageLoopTask = nil
        clockSyncTask = nil
        schedulerOutputTask = nil
        syncTelemetryTask = nil

        if let audioPlayer {
            await audioPlayer.stop()
        }

        await audioScheduler?.finish()
        await audioScheduler?.clear()
        await transport?.disconnect()

        transport = nil
        clockSync = nil
        audioScheduler = nil
        audioPlayer = nil

        clientOperationalState = .synchronized
        isClockSynced = false
        currentVolume = 100 // Reset to full volume; host app can restore persisted value after reconnect
        currentMuted = false
        updateStreamFormat(nil)
        updateCodecHeader(nil)
        shouldEmitRawAudio = false
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

    // MARK: - Outbound messages

    /// Build the client/hello payload (used by both connect paths)
    private func buildClientHelloPayload() -> ClientHelloPayload {
        var playerV1Support: PlayerSupport?
        if roles.contains(.playerV1), let playerConfig {
            playerV1Support = PlayerSupport(
                supportedFormats: playerConfig.supportedFormats,
                bufferCapacity: playerConfig.bufferCapacity,
                supportedCommands: volumeCapabilities.playerCommands
            )
        }

        var artworkV1Support: ArtworkSupport?
        if roles.contains(.artworkV1), let artworkConfig {
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
        guard let transport else {
            throw SendspinClientError.notConnected
        }

        let payload = buildClientHelloPayload()
        try await transport.send(ClientHelloMessage(payload: payload))
    }

    func sendClientState() async throws {
        guard let transport else {
            throw SendspinClientError.notConnected
        }

        var playerStateObject: PlayerStateObject?
        if roles.contains(.playerV1) {
            // Values are already validated (clamped on set), so this should never throw.
            playerStateObject = try PlayerStateObject(
                volume: currentVolume,
                muted: currentMuted,
                staticDelayMs: staticDelayMs,
                supportedCommands: [.setStaticDelay]
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
    func performInitialSync() async throws {
        guard let transport, let clockSync else {
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

    nonisolated func runClockSync() async {
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
                guard let self else { return }
                for await text in textStream {
                    await handleTextMessage(text)
                }
            }

            group.addTask { [weak self] in
                guard let self else { return }
                for await data in binaryStream {
                    await handleBinaryMessage(data)
                }
            }
        }

        // Both streams ended — connection was lost (not an explicit disconnect,
        // which cancels this task before streams end naturally)
        await MainActor.run { [weak self] in
            guard let self else { return }
            if connectionState != .disconnected {
                connectionState = .disconnected
                eventsContinuation.yield(.disconnected(reason: .connectionLost))
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
                Log.client.info("Seamless switch: rebuilding AudioQueue at \(format.sampleRate)Hz (pre-buffered \(preBuffer.count) chunks)")
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
        var lastTelemetryStats = SchedulerStats()
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
                let currentStats = await audioScheduler.stats
                guard currentStats.received > 0 else { continue }

                let framesScheduled = currentStats.received - lastTelemetryStats.received
                let framesPlayed = currentStats.played - lastTelemetryStats.played
                let framesDroppedLate = currentStats.droppedLate - lastTelemetryStats.droppedLate

                let offset = await clockSync.currentOffset
                let rtt = await clockSync.latestAcceptedRtt
                let clockOffsetMs = Double(offset) / 1_000.0
                let rttMs = Double(rtt) / 1_000.0

                // Read sync error computed by the audio callback (precise, no actor jitter)
                let tSnap = await audioPlayer.telemetrySnapshot
                let syncErrorUs = tSnap.syncErrorUs
                let dropN = tSnap.correctionSchedule.dropEveryNFrames
                let insertN = tSnap.correctionSchedule.insertEveryNFrames

                let correcting = tSnap.correctionSchedule.isCorrecting

                // Telemetry is pre-formatted into a single String because os.Logger's
                // type checker can't handle this many inline interpolation segments.
                // The cost (unconditional formatting) is acceptable at the 2s tick rate.
                let telemetry = "sched=\(framesScheduled) played=\(framesPlayed)"
                    + " late=\(framesDroppedLate)"
                    + " buf=\(String(format: "%.1f", currentStats.bufferFillMs))ms"
                    + " offset=\(String(format: "%.2f", clockOffsetMs))ms"
                    + " rtt=\(String(format: "%.2f", rttMs))ms"
                    + " queue=\(currentStats.queueSize)"
                    + " sync=\(syncErrorUs)us"
                    + " correcting=\(correcting)"
                    + " drop=\(dropN) insert=\(insertN)"
                Log.client.debug("\(telemetry, privacy: .public)")

                lastTelemetryStats = currentStats
            }
        }
    }

    // MARK: - Utilities

    /// Send a message through the transport, wrapping any transport error in
    /// ``SendspinClientError/sendFailed(_:)`` so consumers get a typed public error.
    ///
    /// Internal (not private) so that `SendspinClient+Commands.swift` can call it.
    func sendWrapped(_ message: some Codable & Sendable) async throws {
        guard let transport else { throw SendspinClientError.notConnected }
        do {
            try await transport.send(message)
        } catch {
            throw SendspinClientError.sendFailed(error.localizedDescription)
        }
    }

    nonisolated func getCurrentMicroseconds() -> Int64 {
        MonotonicClock.nowMicroseconds()
    }

    /// Set playback volume (0-100, perceived loudness per spec).
    ///
    /// Updates the local audio gain immediately. The server is notified
    /// best-effort — a failed `client/state` send does not prevent the
    /// local volume change from taking effect.
    ///
    /// - Throws: ``SendspinClientError/notConnected`` if the player role
    ///   is not active (client not connected or player role not configured).
    @MainActor
    public func setVolume(_ volume: Int) async throws {
        guard let audioPlayer else { throw SendspinClientError.notConnected }

        let clamped = max(0, min(100, volume))
        currentVolume = clamped
        await audioPlayer.setVolume(Float(clamped) / 100.0)

        try? await sendClientState()
    }

    /// Set mute state.
    ///
    /// Updates the local mute state immediately. The server is notified
    /// best-effort.
    ///
    /// - Throws: ``SendspinClientError/notConnected`` if the player role
    ///   is not active.
    @MainActor
    public func setMute(_ muted: Bool) async throws {
        guard let audioPlayer else { throw SendspinClientError.notConnected }

        currentMuted = muted
        await audioPlayer.setMute(muted)

        try? await sendClientState()
    }

    /// Set static delay in milliseconds (0-5000).
    ///
    /// Per spec: compensates for delay beyond the audio port (external speakers,
    /// amplifiers). Emits `.staticDelayChanged` so the host app can persist the
    /// new value. The server is notified best-effort — a failed `client/state`
    /// send does not prevent the local delay change from taking effect.
    ///
    /// - Throws: ``SendspinClientError/notConnected`` if not connected.
    @MainActor
    public func setStaticDelay(_ delayMs: Int) async throws {
        guard transport != nil else { throw SendspinClientError.notConnected }
        let clamped = max(0, min(5_000, delayMs))
        guard clamped != staticDelayMs else { return }
        staticDelayMs = clamped
        eventsContinuation.yield(.staticDelayChanged(milliseconds: clamped))
        try? await sendClientState()
    }

    // MARK: - Operational state transitions

    /// Atomically transition `clientOperationalState` to `newState` and notify the server.
    ///
    /// If the server notification fails, rolls back to the previous state and throws.
    /// This prevents split-brain where the client's local state diverges from what
    /// the server believes.
    ///
    /// Internal (not private) so that `SendspinClient+Commands.swift` can call it.
    func transitionOperationalState(to newState: ClientOperationalState) async throws {
        guard transport != nil else { throw SendspinClientError.notConnected }
        let previous = clientOperationalState
        clientOperationalState = newState
        do {
            try await sendClientState()
        } catch let error as SendspinClientError {
            clientOperationalState = previous
            throw error
        } catch {
            clientOperationalState = previous
            throw SendspinClientError.sendFailed(error.localizedDescription)
        }
    }
}
