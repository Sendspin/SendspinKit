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
    /// Optional storage hook for the spec's "last played server" bookkeeping.
    /// Saved on every `group/update` that reports playback started; read by the
    /// multi-server arbitration tiebreak.
    let persistenceProvider: (any SendspinPersistenceProvider)?
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
    /// Gate `stream/request-format`: a format request renegotiates an existing
    /// stream, so it's only valid between a role's `stream/start` and `stream/end`.
    /// Tracks the server's stream *intent*, not local playability — it opens even
    /// when the client couldn't begin playback (e.g. an unsupported codec), which
    /// is precisely the state a client recovers from by requesting a format it
    /// supports. The two roles are independent — `stream/end` can end one without
    /// the other.
    var playerStreamActive = false
    var artworkStreamActive = false
    /// Cached from `playerConfig?.emitRawAudioEvents` to avoid optional chaining on every audio chunk.
    var shouldEmitRawAudio = false

    /// Snapshot of the last `client/state` successfully sent to the current
    /// server session, or `nil` before the initial send. Reset on every
    /// `server/hello` so a (re)connected server receives a full baseline;
    /// subsequent sends transmit only changed fields (spec delta semantics).
    var lastSentClientState: SentClientState?

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
    /// Bumped on every ``setupConnection(with:preReadHello:)``. A message loop
    /// captures the value live at its creation; on exit it tears the connection
    /// down only if the value still matches, so a loop superseded by a fast
    /// reconnect (e.g. a network-path change firing before its `.disconnected`
    /// event drains) cannot clobber the connection that replaced it.
    var connectionGeneration: UInt64 = 0

    /// The reason an in-flight ``disconnect(reason:)`` intends to report, recorded
    /// before it suspends on the goodbye send. If a connection loss races that
    /// suspended disconnect and settles first, it adopts this reason instead of
    /// `.connectionLost`, so the local `.disconnected` event preserves the user's
    /// intent — host apps branch on it (e.g. suppress auto-reconnect on
    /// `.userRequest`/`.anotherServer`, but retry on `.connectionLost`). Consumed
    /// by the settling teardown and cleared on each new connection.
    var explicitDisconnectReason: GoodbyeReason?

    // Event stream
    let eventsContinuation: AsyncStream<ClientEvent>.Continuation
    public let events: AsyncStream<ClientEvent>

    public init(
        clientId: String,
        name: String,
        roles: Set<VersionedRole>,
        playerConfig: PlayerConfiguration? = nil,
        artworkConfig: ArtworkConfiguration? = nil,
        persistenceProvider: (any SendspinPersistenceProvider)? = nil
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
        self.persistenceProvider = persistenceProvider
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
    ///
    /// - Parameter preReadHello: When non-nil, the `client/hello` was already sent
    ///   and the `server/hello` already consumed during competing-connection
    ///   arbitration. In that case we process the hello directly instead of sending
    ///   another `client/hello`, and the message loop resumes the transport's stream
    ///   from the (buffered) frames that follow.
    @MainActor
    func setupConnection(
        with transport: any SendspinTransport,
        preReadHello: ServerHelloMessage? = nil
    ) async throws {
        // A new connection is a new session: drop any server-reported state carried
        // over from a prior connection (notably one lost without an explicit
        // disconnect) before the first server/state can merge a delta onto it.
        // Placed here, not in handleServerHello — that also fires on a same-connection
        // re-hello, where the accumulated state is still valid.
        resetServerSessionState()

        // Establish this connection's identity before any `await` below. A stale
        // handleConnectionLost(generation:) from a prior link that interleaves during
        // those suspensions then sees the bumped generation and skips its teardown,
        // instead of clobbering the connection now being set up.
        connectionGeneration &+= 1
        let generation = connectionGeneration

        // A fresh session never inherits a prior disconnect's reason: drop any intent
        // a disconnect recorded but didn't settle (it bailed on a generation change).
        explicitDisconnectReason = nil

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

        if let preReadHello {
            // Competing-connection path: client/hello already sent and server/hello
            // already read during arbitration. Process it before the loop starts so
            // clock sync is running by the time subsequent frames are dispatched.
            await handleServerHello(preReadHello)
        } else {
            try await sendClientHello()
        }

        let frames = transport.frames

        messageLoopTask = Task.detached { [weak self] in
            await self?.runMessageLoop(frames: frames, generation: generation)
        }

        // Clock sync starts after server/hello is received (in handleServerHello)

        schedulerOutputTask = Task.detached { [weak self] in
            await self?.runSchedulerOutput()
        }

        syncTelemetryTask = Task.detached { [weak self] in
            await self?.runSyncCorrectionAndTelemetry()
        }
    }

    /// Disconnect from the server.
    ///
    /// Sends a `client/goodbye` message with the given reason before tearing down
    /// the connection. The goodbye delivery is best-effort — if the transport fails
    /// to send it (e.g., the connection is already dead), disconnection proceeds
    /// normally without throwing.
    ///
    /// Idempotent: calling `disconnect()` on an already-disconnected client is a
    /// no-op and does not emit an additional `.disconnected` event. This matters
    /// for signal handlers and shutdown paths that may invoke `disconnect()`
    /// more than once (e.g. a user pounding Ctrl-C).
    ///
    /// - Parameter reason: Why the client is disconnecting. Defaults to `.restart`,
    ///   matching the reason a server assumes when a client vanishes without a
    ///   goodbye. Pass `.shutdown` or `.userRequest` to explicitly tell the
    ///   server not to auto-reconnect.
    @MainActor
    public func disconnect(reason: GoodbyeReason = .restart) async {
        // Idempotency guard: a second disconnect() while already disconnected
        // would otherwise re-run teardown on nil state (harmless) and yield a
        // ghost `.disconnected` event (not harmless — it spams event consumers).
        guard connectionState != .disconnected else { return }

        let generation = connectionGeneration

        // Record intent before the goodbye await: if a connection loss races this
        // suspended disconnect and settles first, it reports this reason, not
        // `.connectionLost`.
        explicitDisconnectReason = reason

        // Send client/goodbye before tearing down (best-effort)
        if let transport {
            let goodbye = ClientGoodbyeMessage(
                payload: GoodbyePayload(reason: reason)
            )
            try? await transport.send(goodbye)
        }

        // Shared guarded teardown: bails (emitting nothing) if a connection-loss
        // teardown or a competing connection already settled this one while the
        // goodbye was in flight — collapsing the race to a single `.disconnected`.
        guard await teardownLiveConnection(generation: generation) else { return }

        currentVolume = 100 // Reset to full volume; host app can restore persisted value after reconnect
        currentMuted = false
        resetServerSessionState()
        currentConnectionReason = nil
        currentServerId = nil
        // Don't clear currentGroup — spec says group membership persists across reconnections

        settleDisconnected()
    }

    /// Settle `connectionState` to `.disconnected` and emit a single `.disconnected`
    /// event. Shared by ``disconnect(reason:)`` and ``handleConnectionLost(generation:)``
    /// so the emitted reason is resolved in one place: an explicit disconnect's intent
    /// wins if one is in flight, otherwise it's a `.connectionLost`. Must be called with
    /// no `await` between the teardown's final guard and here, so racing teardowns
    /// cannot double-settle.
    private func settleDisconnected() {
        connectionState = .disconnected
        let reason: DisconnectReason = explicitDisconnectReason.map(DisconnectReason.explicit) ?? .connectionLost
        explicitDisconnectReason = nil
        eventsContinuation.yield(.disconnected(reason: reason))
    }

    /// Clear every marker of the currently-active stream(s). Shared by
    /// ``disconnect(reason:)`` and the connection-lost path so a dropped link
    /// leaves the same coherent "no active stream" state an explicit disconnect
    /// would. Without this on connection loss, the `stream/request-format` gates
    /// stay open against a dead transport, so a request would pass the gate and
    /// then fail with the wrong error (`sendFailed`, not `streamNotActive`).
    func resetStreamState() {
        updateStreamFormat(nil)
        updateCodecHeader(nil)
        shouldEmitRawAudio = false
        pendingFormat = nil
        pendingCodecHeader = nil
        playerStreamActive = false
        artworkStreamActive = false
    }

    /// Clear server-reported state that is scoped to a single connection. A
    /// `server/state` delta merges onto the *previous* value (absent field = keep
    /// previous), so without this a reconnected server's first partial delta would
    /// inherit the dead connection's metadata/controller. `currentServerId` and
    /// `currentConnectionReason` are excluded — ``handleServerHello(_:)`` overwrites
    /// them on every hello — and `currentGroup` is excluded because the spec keeps
    /// group membership across reconnections.
    func resetServerSessionState() {
        updateMetadata(nil)
        updateControllerState(nil)
    }

    /// Cancel and release the four long-lived connection tasks. Shared by
    /// ``disconnect(reason:)`` and the connection-lost path. The latter cannot
    /// rely on a later `disconnect()` to do this: once connection loss sets
    /// `.disconnected`, `disconnect()` hits its idempotency guard and returns
    /// before reaching here, which is how the scheduler-output and telemetry
    /// loops would otherwise leak (and double-run after a reconnect).
    func cancelConnectionTasks() {
        messageLoopTask?.cancel()
        clockSyncTask?.cancel()
        schedulerOutputTask?.cancel()
        syncTelemetryTask?.cancel()
        messageLoopTask = nil
        clockSyncTask = nil
        schedulerOutputTask = nil
        syncTelemetryTask = nil
    }

    // MARK: - Outbound messages

    /// Build the client/hello payload (used by both connect paths)
    func buildClientHelloPayload() -> ClientHelloPayload {
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

    // MARK: - Clock synchronization

    /// Continuous clock sync task. Sends `client/time` messages on a
    /// rapid-then-relaxed cadence: the first two samples go out 10 ms
    /// apart so the Kalman filter establishes both offset (from sample 1)
    /// and drift (from the `count==1 → count==2` finite-difference branch
    /// on sample 2) within ~20 ms of the server/hello handshake. After
    /// that, samples settle into a 1-second cadence for ongoing drift
    /// correction.
    ///
    /// Matches the double-tap approach used in sendspin-rs
    /// (`src/protocol/client.rs`). The tight initial burst shortens
    /// time-to-`isClockSynced` from several hundred milliseconds (the
    /// previous 5×100 ms + 200 ms-tail approach) to roughly one RTT, and
    /// the 1 s steady-state cadence gives a tighter asymptotic
    /// `estimatedError` than the previous 5 s interval did.
    nonisolated func runClockSync() async {
        guard let transport = await transport else { return }

        var sampleCount: UInt32 = 0
        while !Task.isCancelled {
            let now = getCurrentMicroseconds()
            let message = ClientTimeMessage(payload: ClientTimePayload(clientTransmitted: now))
            do {
                try await transport.send(message)
                sampleCount = sampleCount &+ 1
            } catch {
                break // Connection lost
            }

            // First two samples 10 ms apart so the filter's count==1→2
            // branch fires quickly (that branch initializes drift from the
            // finite difference between the first two samples); then relax
            // to a 1-second cadence.
            let delay: Duration = sampleCount < 2
                ? .milliseconds(10)
                : .seconds(1)
            try? await Task.sleep(for: delay)
        }
    }

    // MARK: - Message loop

    /// Dispatch incoming frames in wire order on a single task.
    ///
    /// Text and binary frames share one ordered stream so a control message can
    /// never overtake the audio frames that preceded it (e.g. `stream/end` must
    /// be handled only after the audio chunks the server sent before it). Audio
    /// *output* is decoupled on ``runSchedulerOutput()``, so serial frame
    /// dispatch here does not gate playback.
    private nonisolated func runMessageLoop(frames: AsyncStream<TransportFrame>, generation: UInt64) async {
        for await frame in frames {
            switch frame {
            case let .text(text):
                await handleTextMessage(text)
            case let .binary(data):
                await handleBinaryMessage(data)
            }
        }

        // The frame stream ended — connection was lost (not an explicit disconnect,
        // which cancels this task before streams end naturally).
        await handleConnectionLost(generation: generation)
    }

    /// Tear down a connection that dropped without an explicit ``disconnect(reason:)``.
    ///
    /// Mirrors `disconnect()`'s resource teardown — stop audio, finish the
    /// scheduler, close and release the transport, cancel the connection tasks —
    /// so a dropped link leaves no live AudioQueue, socket, or background loop.
    /// It deliberately preserves the *observable* session state (metadata,
    /// controller, group, volume, server identity) so a UI keeps showing the
    /// last-known state through a transient drop; that state is reset at the next
    /// connection by ``setupConnection(with:preReadHello:)``, not here.
    ///
    /// - Parameter generation: the connection generation this loop was started
    ///   for. If a newer connection has since been established, this teardown is
    ///   stale and must do nothing.
    ///
    /// Internal rather than private so the generation guard can be tested directly
    /// (its failure mode — a stale teardown clobbering a live reconnect — is a race
    /// that can't be reproduced deterministically through the public surface).
    @MainActor
    func handleConnectionLost(generation: UInt64) async {
        guard await teardownLiveConnection(generation: generation) else { return }
        settleDisconnected()
    }

    /// Idempotently tear down the live connection's resources — stop audio, finish
    /// the scheduler, close and release the transport, cancel the background tasks —
    /// guarding against a competing connection that replaced them while suspended.
    ///
    /// Returns `true` if this call performed the teardown; `false` if a newer
    /// connection has taken over (generation bumped) or another teardown path
    /// already settled this one. On `false` the caller must not settle
    /// `connectionState` or emit an event.
    ///
    /// Shared by ``handleConnectionLost(generation:)`` and ``disconnect(reason:)`` so
    /// concurrent teardowns (a user disconnect racing a dropped link) collapse to a
    /// single settle and a single `.disconnected` event. The observable session
    /// state (metadata, controller, group, volume, server identity) is intentionally
    /// left for the caller to handle — connection-loss preserves it; explicit
    /// disconnect resets it.
    @MainActor
    func teardownLiveConnection(generation: UInt64) async -> Bool {
        guard generation == connectionGeneration, connectionState != .disconnected else { return false }

        // Operate on captured locals, not `self.*`: these awaits suspend the
        // MainActor, during which a competing connection can replace the live
        // dependencies. Closing the locals tears down the resources this connection
        // owned, never a replacement's. Teardown is idempotent, so re-running it on
        // already-closed resources (a concurrent disconnect got here first) is safe.
        let closingPlayer = audioPlayer
        let closingScheduler = audioScheduler
        let closingTransport = transport

        await closingPlayer?.stop()
        await closingScheduler?.finish()
        await closingScheduler?.clear()
        await closingTransport?.disconnect()

        // Re-check before mutating shared state. There must be no `await` between
        // here and the caller's `connectionState = .disconnected`, so two racing
        // teardowns cannot both pass this guard and double-settle.
        guard generation == connectionGeneration, connectionState != .disconnected else { return false }

        transport = nil
        clockSync = nil
        audioScheduler = nil
        audioPlayer = nil

        cancelConnectionTasks()

        clientOperationalState = .synchronized
        isClockSynced = false
        resetStreamState()
        return true
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

    /// Estimate the current server time in microseconds.
    ///
    /// Uses the clock synchronization filter to convert the local monotonic clock
    /// to the server's clock domain. Returns `nil` if clock sync has not completed
    /// (no `server/time` responses received yet).
    ///
    /// Use this with ``PlaybackProgress/currentPositionMs(at:)`` to compute
    /// the real-time interpolated playback position:
    /// ```swift
    /// if let serverTime = await client.currentServerTimeMicroseconds(),
    ///    let progress = client.currentMetadata?.progress {
    ///     let positionMs = progress.currentPositionMs(at: serverTime)
    /// }
    /// ```
    @MainActor
    public func currentServerTimeMicroseconds() async -> Int64? {
        guard let clockSync else { return nil }
        let localNow = MonotonicClock.absoluteMicroseconds()
        let offset = await clockSync.currentOffset
        guard offset != 0 else { return nil }
        return localNow + offset
    }

    /// Snapshot of the current clock synchronization state.
    ///
    /// Returns `nil` if the client is not connected or clock sync has not
    /// completed (no `server/time` responses accepted yet).
    ///
    /// Useful for diagnostics, telemetry dashboards, and debugging sync quality.
    /// The returned values are a point-in-time snapshot — they may change on the
    /// next `server/time` exchange.
    @MainActor
    public func currentClockSyncStats() async -> ClockSyncStats? {
        guard let clockSync else { return nil }
        // Single actor hop — all values are from the same point in time.
        // `diagnosticSnapshot()` itself returns nil when the filter hasn't
        // accepted any sample yet, which is our "no data" case.
        guard let snap = await clockSync.diagnosticSnapshot() else { return nil }
        return ClockSyncStats(
            offset: snap.offset,
            rtt: snap.rtt,
            rawRtt: snap.rawRtt,
            rawRttWasRejected: snap.rawRttWasRejected,
            drift: snap.drift,
            estimatedError: snap.estimatedError,
            sampleCount: snap.sampleCount
        )
    }

    /// Set playback volume (0–100, perceived loudness per spec).
    ///
    /// The integer range 0–100 matches the Sendspin wire format. Internally,
    /// the value is converted to a 0.0–1.0 float and passed through a 1.5-power
    /// perceptual gain curve (see ``AudioPlayer/perceptualGain(_:)``) before
    /// being applied to either the AudioQueue (software mode) or the hardware
    /// device (hardware mode). This ensures volume 50 sounds roughly half as
    /// loud as volume 100, regardless of volume mode.
    ///
    /// Updates the local audio gain immediately. The server is notified
    /// best-effort — a failed `client/state` send does not prevent the
    /// local volume change from taking effect.
    ///
    /// - Parameter volume: Volume level (0–100). Values outside this range
    ///   are clamped.
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
    /// best-effort — a failed `client/state` send does not prevent the
    /// local mute change from taking effect. This asymmetry (throw for
    /// missing player, swallow server notification failure) is deliberate:
    /// a missing player is a programmer error, while a transient send
    /// failure is recoverable (the next state update will catch up).
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

    /// Apply an underrun transition from the telemetry loop's ``UnderrunMonitor``.
    ///
    /// Guarded to only move `.synchronized` ↔ `.error`, so it can't clobber
    /// `.externalSource` or a codec/format `.error`. Send failures are ignored;
    /// the next state change re-syncs the server.
    func applyUnderrunTransition(_ transition: UnderrunMonitor.Transition) async {
        switch transition {
        case .none:
            break
        case .toError:
            guard clientOperationalState == .synchronized else { return }
            try? await transitionOperationalState(to: .error)
        case .toSynchronized:
            guard clientOperationalState == .error else { return }
            try? await transitionOperationalState(to: .synchronized)
        }
    }
}
