import CryptoKit
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
    var channel: NoiseChannel
    let clock: any ClockSyncProtocol
    let audioEngine: AudioEngine
    let audioSink: AsyncStream<AudioChunk>.Continuation
    let artworkSink: AsyncStream<ArtworkData>.Continuation
    let visualizerSink: AsyncStream<VisualizerData>.Continuation
    let emitRawAudio: Bool
    let artworkObserver: (@Sendable (ArtworkData) -> Void)?
    let validity: SessionValidityToken

    /// Reusable decoder for inbound control frames, stored to avoid a per-message
    /// allocation. Safe as actor-isolated state: `route(text:)` is the sole,
    /// serialized user. Plain config — message types map snake_case via explicit
    /// `CodingKeys`, so no key-decoding strategy is needed.
    let inboundDecoder = JSONDecoder()

    /// Outbound control-plane sink. Depth-tracked: the facade drain calls
    /// `decrementDepth()` per consumed event (immutable Sendable, cross-actor safe).
    nonisolated let controlSink = ControlEventSink()

    // Lifecycle state
    var lifecycle: ConnectionLifecycle = .idle
    var shuttingDown = false
    var disconnectReason: DisconnectReason?
    var supervisorTask: Task<Void, Never>?
    private(set) var supervisorSpawnCount: Int = 0

    /// Exact player catalog advertised for this session. `nil` for non-player clients.
    nonisolated let effectivePlayerFormats: [AudioFormatSpec]?
    let outputSampleRatePolicy: OutputSampleRatePolicy?

    /// Session-scoped route negotiation state. Snapshot ownership remains on the facade;
    /// this actor retains only the latest value needed to make protocol decisions.
    var outputSnapshot: AudioOutputSnapshot?
    var latestOutputSnapshotSequence: UInt64
    var settledOutputSampleRate: Int?
    var outputFormatStatus: OutputFormatStatus?
    var pendingOutputFormatRequest: PendingOutputFormatRequest?
    var automaticRequestsSuppressed = false
    var handledAutomaticSampleRate: Int?
    var outputSettleTask: Task<Void, Never>?
    var outputRequestDeadlineTask: Task<Void, Never>?
    var outputNegotiationGeneration: UInt64 = 0
    let outputSettleInterval: Duration
    let outputRequestTimeout: Duration
    let outputNegotiationSleep: @Sendable (Duration) async throws -> Void

    /// Clock-sync sender task. Starts when the message loop begins after handoff
    /// and is cancelled on teardown.
    var clockSyncTask: Task<Void, Never>?

    // Protocol-intent gates for inbound stream data. Internal so same-module
    // SendspinConnection extensions can split implementation across files; the
    // message handlers remain the single writer. Request-format sends are allowed
    // even when these are false, per spec.
    var playerStreamActive = false
    var artworkStreamActive = false
    var visualizerStreamActive = false
    var isClockSynced = false
    var announcedPlayerStream: (format: AudioFormatSpec, codecHeader: Data?)?
    /// Written from several places (this method, the engine report drain, stream-start
    /// validation). `operationalStateEpoch` stamps every one of them so a rollback can
    /// tell "nothing moved" from "something moved to the same value".
    var clientOperationalState: EngineSyncState = .synchronized {
        didSet { operationalStateEpoch += 1 }
    }

    private(set) var operationalStateEpoch = 0

    /// Client state tracking for delta computation
    var lastSentClientState: SentClientState?
    var clientStateSendInFlight = false
    var clientStateDirty = false

    /// Server info
    var currentServerId: String?
    var serverName: String
    var activities: Set<Activity>
    var pskCategory: PskCategory
    var matchedPskId: String
    let pairingStore: (any PairingRecordStore)?
    let pairingConfigurationRuntime: PairingConfigurationRuntime?
    let pairingAttemptTimeout: Duration
    #if DEBUG
        let nonceBOverride: Data?
        let pairingHandshakeHashOverride: Data?
        let pairingScalarBOverride: Data?
    #endif
    var sessionContext: ActivationAdmissibility.SessionContext
    let identityPrivateKey: Curve25519.KeyAgreement.PrivateKey
    let serverStaticPublicKey: Curve25519.KeyAgreement.PublicKey
    let suite: NoiseCipherSuite
    let candidateProvider: @Sendable () async -> [PskCandidate]
    let clientHelloPayload: ClientHelloPayload
    var rehandshakeInProgress = false
    nonisolated var isRehandshakeInProgress: Bool {
        get async { await rehandshakeInProgress }
    }

    var awaitingRehandshakeActivation = false
    var activeRoles: Set<VersionedRole>
    var pendingPairingPsk: Psk?
    var pairingAttemptTask: Task<Void, Never>?

    struct DynamicPairingAttempt {
        let format: PairingCodeFormat
        let pairingIndex: UInt32
        let sid: Data
        let nonceB: Data
        let commitB: Data
        var nonceA: Data?
        var serverShare: Data?
        var cpace: CPace?
        var secrets: CPaceSecrets?
        var clientConfirmationSent: Bool
    }

    struct StaticPairingAttempt {
        let pairingIndex: UInt32
        let sid: Data
        let prs: Data
        var serverShare: Data?
        var cpace: CPace?
        var secrets: CPaceSecrets?
        var clientConfirmationSent: Bool
    }

    var dynamicPairingAttempt: DynamicPairingAttempt?
    var staticPairingAttempt: StaticPairingAttempt?
    var pairingActivateCounter: UInt32 = 0
    var pairingWindowOpen = false
    var pairingWindowTask: Task<Void, Never>?
    let pairingWindowLifetime: Duration

    /// Last metadata state, retained so partial server/state deltas merge
    /// rather than clobber absent fields (e.g. a title-only delta keeps album/artist).
    var currentMetadata: TrackMetadata?

    /// Last controller state, retained so partial server/state deltas merge
    /// rather than clobber absent fields (e.g. a volume-only delta keeps repeat/shuffle).
    var currentControllerState: ControllerState?

    /// Last color state, retained so partial server/state color deltas merge
    /// rather than clobber absent fields.
    var currentColorState: ColorState?

    /// Last group state, retained so partial group/update deltas merge rather
    /// than clobber absent fields (e.g. a playback-only delta keeps group id/name).
    var currentGroup: GroupInfo?

    // Player state for reporting
    var currentVolume: Int = 100
    var currentMuted: Bool = false
    var currentOutputDelayMs: Int = 0
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
    ///   - channel: The Noise channel owned by this connection
    ///   - serverId/serverName: The admitted server identity
    ///   - activities/activeRoles: The admitted session capabilities
    ///   - validity: Token guarding data-plane event emission
    ///   - advertisedCommands: The set of commands to accept from the server (gate in `handleServerCommand`)
    ///   - roles: The client roles for state reporting
    ///   - initialOutputDelayMs: Initial output delay in milliseconds
    ///   - clock: Clock sync instance (injected for testing; default creates a new `ClockSynchronizer`)
    ///   - engine: Audio engine (injected for testing; default creates a production engine)
    init(
        transport: any SendspinTransport,
        channel: consuming NoiseChannel,
        serverId: String,
        serverName: String,
        activities: Set<Activity>,
        activeRoles: Set<VersionedRole>,
        pskCategory: PskCategory,
        matchedPskId: String = "",
        pairingStore: (any PairingRecordStore)? = nil,
        pairingConfigurationRuntime: PairingConfigurationRuntime? = nil,
        pairingAttemptTimeout: Duration = .seconds(120),
        pairingWindowLifetime: Duration = .seconds(300),
        nonceBOverride: Data? = nil,
        pairingHandshakeHashOverride: Data? = nil,
        pairingScalarBOverride: Data? = nil,
        identityPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        serverStaticPublicKey: Curve25519.KeyAgreement.PublicKey,
        suite: NoiseCipherSuite,
        candidateProvider: @escaping @Sendable () async -> [PskCandidate],
        clientHelloPayload: ClientHelloPayload,
        unpairedAccessEnabled: Bool = true,
        effectivePlayerFormats: [AudioFormatSpec]? = nil,
        outputSampleRatePolicy: OutputSampleRatePolicy? = nil,
        initialOutputSnapshot: AudioOutputSnapshot? = nil,
        initialOutputSnapshotSequence: UInt64 = 0,
        outputSettleInterval: Duration = .milliseconds(250),
        outputRequestTimeout: Duration = .seconds(3),
        outputNegotiationSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        audioSink: AsyncStream<AudioChunk>.Continuation = AsyncStream<AudioChunk>.makeStream().1,
        artworkSink: AsyncStream<ArtworkData>.Continuation = AsyncStream<ArtworkData>.makeStream().1,
        visualizerSink: AsyncStream<VisualizerData>.Continuation = AsyncStream<VisualizerData>.makeStream().1,
        emitRawAudio: Bool = true,
        artworkObserver: (@Sendable (ArtworkData) -> Void)? = nil,
        validity: SessionValidityToken,
        advertisedCommands: Set<PlayerCommand> = [.setOutputDelay],
        roles: Set<VersionedRole> = [],
        initialOutputDelayMs: Int = 0,
        initialVolume: Int = 100,
        initialMuted: Bool = false,
        requiredLeadTimeMs: Int = defaultRequiredLeadTimeMs,
        minBufferMs: Int = defaultMinBufferMs,
        clock: any ClockSyncProtocol = ClockSynchronizer(),
        engine: AudioEngine
    ) {
        self.transport = transport
        self.channel = channel
        currentServerId = serverId
        self.serverName = serverName
        self.activities = activities
        self.activeRoles = activeRoles
        pendingPairingPsk = nil
        pairingAttemptTask = nil
        self.pskCategory = pskCategory
        self.matchedPskId = matchedPskId
        self.pairingStore = pairingStore
        self.pairingConfigurationRuntime = pairingConfigurationRuntime
        self.pairingAttemptTimeout = pairingAttemptTimeout
        self.pairingWindowLifetime = pairingWindowLifetime
        #if DEBUG
            self.nonceBOverride = nonceBOverride
            self.pairingHandshakeHashOverride = pairingHandshakeHashOverride
            self.pairingScalarBOverride = pairingScalarBOverride
        #endif
        dynamicPairingAttempt = nil
        staticPairingAttempt = nil
        pairingWindowOpen = false
        pairingWindowTask = nil
        self.identityPrivateKey = identityPrivateKey
        self.serverStaticPublicKey = serverStaticPublicKey
        self.suite = suite
        self.candidateProvider = candidateProvider
        self.clientHelloPayload = clientHelloPayload
        sessionContext = ActivationAdmissibility.SessionContext(
            category: pskCategory,
            unpairedAccessEnabled: unpairedAccessEnabled,
            offeredPairMethods: []
        )
        self.effectivePlayerFormats = effectivePlayerFormats
        self.outputSampleRatePolicy = outputSampleRatePolicy
        outputSnapshot = initialOutputSnapshot
        latestOutputSnapshotSequence = initialOutputSnapshotSequence
        settledOutputSampleRate = initialOutputSnapshot?.sampleRate
        self.outputSettleInterval = outputSettleInterval
        self.outputRequestTimeout = outputRequestTimeout
        self.outputNegotiationSleep = outputNegotiationSleep
        self.audioSink = audioSink
        self.artworkSink = artworkSink
        self.visualizerSink = visualizerSink
        self.emitRawAudio = emitRawAudio
        self.artworkObserver = artworkObserver
        self.validity = validity
        self.advertisedCommands = advertisedCommands
        playerRoleActive = roles.contains(.playerV1)
        self.roles = roles
        currentOutputDelayMs = initialOutputDelayMs
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
        guard lifecycle == .running || lifecycle == .idle else { throw SendspinClientError.handshakeIncomplete }
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
    func setOutputDelay(_ delayMs: Int) async throws {
        currentOutputDelayMs = delayMs
        audioEngine.commands.enqueue(.setOutputDelay(delayMs))
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
    func setOperationalState(_ newState: EngineSyncState) async throws {
        let previous = clientOperationalState
        clientOperationalState = newState
        // No forced resend: only wire-visible changes flow. An engine error has no
        // wire representation; an external-source flip reaches the server because
        // `available` changes in the delta.
        let stamp = operationalStateEpoch
        do {
            try await sendClientStateIfChanged()
        } catch {
            // Roll back only if no other writer touched the state during the send. A value
            // comparison is not enough: the engine drain can independently set the same
            // state we requested, and rolling that back discards an authoritative write.
            if operationalStateEpoch == stamp {
                clientOperationalState = previous
            }
            throw error
        }
    }

    /// Start the connection and spawn the supervisor task.
    /// Idempotent: calling multiple times is a no-op.
    func start() {
        guard lifecycle == .idle else { return }
        lifecycle = .running
        if case .longTerm = pskCategory, let pairingStore {
            let pskId = matchedPskId
            Task { await pairingStore.markUsed(pskId: pskId) }
        }
        if lastSentClientState == nil, !playerRoleActive {
            Task { [weak self] in
                try? await self?.sendClientStateIfChanged()
            }
        }
        supervisorSpawnCount += 1

        supervisorTask = Task {
            await runLoop()
            // An explicit local disconnect still wins; it is recorded before its first
            // suspension precisely so it beats the loss path.
            let observed = await transport.closeReason
            await finishTeardown(disconnectReason ?? .connectionLost(observed))
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
