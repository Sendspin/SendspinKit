import Foundation
import os

/// Core audio and control streaming actor.
///
/// Owns the physical socket lifetime (transport), the ordered message loop
/// (frame classification and routing), the protocol-intent gates (stream active flags),
/// clock synchronization, the audio engine, and a supervisor task.
///
/// **Isolation guarantee:** `SendspinConnection` holds no `SendspinClient` reference
/// and imports nothing `@MainActor`-isolated. The dependency is strictly one-way
/// (facade → connection → engine), proven at compile time.
///
/// Emits control-plane events on a control stream (`ConnectionEvent`) and yields
/// binary data off-main directly to the public continuation, guarded by a session
/// validity token that silently drops stale events after reconnect.
actor SendspinConnection {
    // Dependencies
    let transport: any SendspinTransport
    let clock: any ClockSyncProtocol
    let audioEngine: AudioEngine
    let audioSink: AsyncStream<AudioChunk>.Continuation
    let artworkSink: AsyncStream<ArtworkData>.Continuation
    let visualizerSink: AsyncStream<VisualizerData>.Continuation
    let emitRawAudio: Bool
    let artworkObserver: (@Sendable (ArtworkData) -> Void)?
    let validity: SessionValidityToken

    /// Outbound control-plane sink. Depth-tracked: the facade drain calls
    /// `decrementDepth()` per consumed event (immutable Sendable, cross-actor safe).
    nonisolated let controlSink = ControlEventSink()

    // Lifecycle state
    var lifecycle: ConnectionLifecycle = .idle
    var handshakePhase: HandshakePhase = .awaitingServerHello
    var shuttingDown = false
    var disconnectReason: DisconnectReason?
    var supervisorTask: Task<Void, Never>?
    private(set) var supervisorSpawnCount: Int = 0

    /// Pre-read hello (for multi-server handoff)
    let parsedHello: ServerHelloMessage?

    /// Client/hello payload, sent as the first message on the normal connect path
    /// (spec §103). Skipped when `parsedHello` is set — the facade already sent it
    /// during competing-connection arbitration.
    let clientHelloPayload: ClientHelloPayload

    /// Clock-sync sender task. Started on `server/hello` (spec §104: no client
    /// messages before the handshake completes), cancelled on teardown.
    var clockSyncTask: Task<Void, Never>?

    // Protocol-intent gates. Internal so same-module SendspinConnection extensions
    // can split implementation across files; the message handlers remain the
    // single writer and request-format sends gate on these values.
    var playerStreamActive = false
    var artworkStreamActive = false
    var visualizerStreamActive = false
    var isClockSynced = false
    var announcedPlayerStream: (format: AudioFormatSpec, codecHeader: Data?)?
    var clientOperationalState: ClientOperationalState = .synchronized

    /// Client state tracking for delta computation
    var lastSentClientState: SentClientState?
    var clientStateSendInFlight = false
    var clientStateDirty = false

    /// Server info
    var currentServerId: String?
    var activeRoles: Set<VersionedRole> = []

    /// Last metadata state, retained so partial server/state deltas merge
    /// rather than clobber absent fields (e.g. a title-only delta keeps album/artist).
    var currentMetadata: TrackMetadata?

    /// Last controller state, retained so partial server/state deltas merge
    /// rather than clobber absent fields (e.g. a volume-only delta keeps repeat/shuffle).
    var currentControllerState: ControllerState?

    /// Last group state, retained so partial group/update deltas merge rather
    /// than clobber absent fields (e.g. a playback-only delta keeps group id/name).
    var currentGroup: GroupInfo?

    // Player state for reporting
    var currentVolume: Int = 100
    var currentMuted: Bool = false
    var currentStaticDelayMs: Int = 0
    let requiredLeadTimeMs: Int
    let minBufferMs: Int

    // Config info needed for client state assembly
    let playerRoleActive: Bool
    let roles: Set<VersionedRole>

    // MARK: - Initialization

    /// Advertised player commands (gate in handleServerCommand)
    let advertisedCommands: Set<PlayerCommand>

    /// Create a connection with the given transport and engine.
    ///
    /// - Parameters:
    ///   - transport: The transport to read/write frames
    ///   - parsedHello: Pre-read `server/hello` (for multi-server handoff), or nil
    ///   - clientHelloPayload: Payload sent as the first `client/hello` (normal path only)
    ///   - validity: Token guarding data-plane event emission
    ///   - advertisedCommands: The set of commands to accept from the server (gate in `handleServerCommand`)
    ///   - roles: The client roles for state reporting
    ///   - initialStaticDelayMs: Initial static delay in milliseconds
    ///   - clock: Clock sync instance (injected for testing; default creates a new `ClockSynchronizer`)
    ///   - engine: Audio engine (injected for testing; default creates a production engine)
    init(
        transport: any SendspinTransport,
        parsedHello: ServerHelloMessage?,
        clientHelloPayload: ClientHelloPayload,
        audioSink: AsyncStream<AudioChunk>.Continuation = AsyncStream<AudioChunk>.makeStream().1,
        artworkSink: AsyncStream<ArtworkData>.Continuation = AsyncStream<ArtworkData>.makeStream().1,
        visualizerSink: AsyncStream<VisualizerData>.Continuation = AsyncStream<VisualizerData>.makeStream().1,
        emitRawAudio: Bool = true,
        artworkObserver: (@Sendable (ArtworkData) -> Void)? = nil,
        validity: SessionValidityToken,
        advertisedCommands: Set<PlayerCommand> = [.setStaticDelay],
        roles: Set<VersionedRole> = [],
        initialStaticDelayMs: Int = 0,
        initialVolume: Int = 100,
        initialMuted: Bool = false,
        requiredLeadTimeMs: Int = defaultRequiredLeadTimeMs,
        minBufferMs: Int = defaultMinBufferMs,
        clock: any ClockSyncProtocol = ClockSynchronizer(),
        engine: AudioEngine
    ) {
        self.transport = transport
        self.parsedHello = parsedHello
        self.clientHelloPayload = clientHelloPayload
        self.audioSink = audioSink
        self.artworkSink = artworkSink
        self.visualizerSink = visualizerSink
        self.emitRawAudio = emitRawAudio
        self.artworkObserver = artworkObserver
        self.validity = validity
        self.advertisedCommands = advertisedCommands
        playerRoleActive = roles.contains(.playerV1)
        self.roles = roles
        currentStaticDelayMs = initialStaticDelayMs
        currentVolume = initialVolume
        currentMuted = initialMuted
        self.requiredLeadTimeMs = requiredLeadTimeMs
        self.minBufferMs = minBufferMs
        self.clock = clock
        audioEngine = engine
    }

    // MARK: - Public interface

    /// Control-plane event stream (terminates with `.disconnected`).
    nonisolated var events: AsyncStream<ConnectionEvent> {
        controlSink.elements
    }

    /// Internal test access to the connection-owned engine. Kept off the facade
    /// so production `SendspinClient` cannot observe or command audio internals.
    nonisolated var audioEngineForTesting: AudioEngine {
        audioEngine
    }

    /// Send client state to the server (internal, called by facade).
    func sendClientState() async throws {
        try await sendClientStateIfChanged()
    }

    func requireActiveRole(_ role: VersionedRole) throws {
        guard handshakePhase == .complete else { throw SendspinClientError.handshakeIncomplete }
        guard roles.contains(role), activeRoles.contains(role) else {
            throw SendspinClientError.roleNotActive(role)
        }
    }

    /// Apply an optimistic local volume change to the engine, then report it to the server.
    /// The connection owns both engine access and client/state serialization.
    func setVolume(_ volume: Int) async throws {
        currentVolume = volume
        await audioEngine.setGain(Float(volume) / 100.0)
        try await sendClientStateIfChanged()
    }

    /// Apply an optimistic local mute change to the engine, then report it to the server.
    func setMuted(_ muted: Bool) async throws {
        currentMuted = muted
        await audioEngine.setMuted(muted)
        try await sendClientStateIfChanged()
    }

    /// Enqueue an optimistic static-delay change in engine order, then report it to the server.
    func setStaticDelay(_ delayMs: Int) async throws {
        currentStaticDelayMs = delayMs
        audioEngine.commands.enqueue(.setStaticDelay(delayMs))
        try await sendClientStateIfChanged()
    }

    /// Tell the engine whether playback is suppressed by an external source.
    func setExternalSource(_ active: Bool) async {
        await audioEngine.setExternalSource(active)
    }

    /// Estimate current server time from the connection-owned clock sync state.
    func currentServerTimeMicroseconds(localNow: Int64) async -> Int64? {
        guard await clock.hasSynced else { return nil }
        return await clock.localTimeToServer(localNow)
    }

    /// Snapshot the connection-owned clock sync diagnostics.
    func currentClockSyncStats() async -> ClockSyncStats? {
        guard let snap = await clock.diagnosticSnapshot() else { return nil }
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

    /// Transition the operational state (the connection is the single writer)
    /// and notify the server. Rolls back and rethrows if the `client/state` send fails,
    /// so the facade can keep its optimistic state consistent.
    func setOperationalState(_ newState: ClientOperationalState) async throws {
        let previous = clientOperationalState
        clientOperationalState = newState
        do {
            try await sendClientStateIfChanged()
        } catch {
            clientOperationalState = previous
            throw error
        }
    }

    /// Start the connection and spawn the supervisor task.
    /// Idempotent: calling multiple times is a no-op.
    func start() {
        guard lifecycle == .idle else { return }
        lifecycle = .running
        supervisorSpawnCount += 1

        supervisorTask = Task {
            await runLoop()
            await finishTeardown(disconnectReason ?? .connectionLost)
        }
    }

    /// Graceful disconnect: send goodbye and close.
    /// Idempotent after lifecycle leaves `.running`.
    func disconnect(reason: GoodbyeReason) async {
        // Record the reason BEFORE the first await (wins a race with loss)
        shuttingDown = true
        disconnectReason = .explicit(reason)

        if lifecycle == .idle {
            await teardownFromIdle()
            return
        }

        guard handshakePhase == .complete else {
            await transport.disconnect()
            if let supervisor = supervisorTask {
                await supervisor.value
            }
            return
        }

        guard lifecycle == .running else {
            // Not currently connected; wait for existing shutdown
            if let supervisor = supervisorTask {
                await supervisor.value
            }
            return
        }
        // Close the duplicate-goodbye window before the first suspension. A
        // concurrent disconnect now observes `.shuttingDown` and only waits for
        // the supervisor instead of sending its own `client/goodbye`.
        lifecycle = .shuttingDown

        // Send exactly one goodbye (best-effort; ignore send failures)
        do {
            try await sendWrapped(ClientGoodbyeMessage(payload: GoodbyePayload(reason: reason)))
        } catch {
            Log.client.warning("Failed to send goodbye: \(error)")
        }

        // Close transport to trigger runLoop() return
        await transport.disconnect()

        // Await the supervisor
        if let supervisor = supervisorTask {
            await supervisor.value
        }
    }

    /// Hard shutdown: no goodbye, kill transport, wait for supervisor.
    /// Idempotent.
    func shutdown() async {
        let alreadyShuttingDown = shuttingDown
        shuttingDown = true

        if lifecycle == .idle {
            await teardownFromIdle()
            return
        }

        if !alreadyShuttingDown {
            // First to call shutdown: invalidate and close
            validity.invalidate()
            await transport.disconnect()
        }

        // Wait for supervisor (same or new caller)
        if let supervisor = supervisorTask {
            await supervisor.value
        }
    }
}
