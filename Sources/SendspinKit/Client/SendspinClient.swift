import Foundation
import Observation
import os

/// Main Sendspin client
@Observable
@MainActor
public final class SendspinClient {
    // Configuration
    let identity: SendspinIdentity
    let name: String
    var unpairedAccessEnabled: Bool
    @ObservationIgnored var ownedDevice: SendspinDevice?
    @ObservationIgnored var deviceLease: UUID?
    @ObservationIgnored var accessPolicyUpdateTask: Task<Void, Error>?

    /// The explicitly selected policy for normal unpaired role access.
    public var accessPolicy: AccessPolicy {
        unpairedAccessEnabled ? .allowUnpaired : .pairedOnly
    }

    let roles: [VersionedRole]
    let roleSet: Set<VersionedRole>
    let deviceInfo: DeviceInfo?
    let playerConfig: PlayerConfiguration?
    let artworkConfig: ArtworkConfiguration?
    /// Visualizer configuration published in client/state and client/hello.
    let visualizerConfig: VisualizerConfiguration?
    /// Optional storage hook for the spec's "last played server" bookkeeping.
    /// Saved on every `group/update` that reports playback started; read by the
    /// multi-server arbitration tiebreak. `nil` means no implicit storage: discovery
    /// ties are resolved as if no last-played server has been remembered.
    let persistenceProvider: (any SendspinPersistenceProvider)?
    /// Pairing PSK and long-term record persistence for Noise sessions.
    let pairingConfiguration: PairingConfiguration?
    /// Resolved volume capabilities (the concrete `VolumeControl` lives in `AudioEngine`).
    let volumeCapabilities: VolumeCapabilities

    // Public-readable, privately-settable state, mutated only through named setters.
    // Keeping the mutation surface narrow makes the facade's event-drain path the
    // auditable source of observable state changes. `updateConnectionState` stays
    // internal for the multi-server arbitration path.

    /// Connection lifecycle state. Observe this (via `@Observable`) to update UI
    /// for connecting/connected/error/disconnected transitions.
    ///
    /// If the state enters `.error(_:)`, the transport is still alive but playback
    /// is broken. Call ``disconnect(reason:)`` followed by ``connect(to:)`` to recover.
    public private(set) var connectionState: ConnectionState = .disconnected
    /// Trust level established by the currently admitted Noise PSK.
    public private(set) var trustLevel: TrustLevel = .none
    /// Latest immutable pairing projection; genuine ends retain their terminal snapshot until a new
    /// attempt starts. Server activation supersession clears it and emits `pairingAttemptSuperseded`.
    public private(set) var currentPairing: PairingAttemptSnapshot?
    /// Connection-scoped operator authorization, or nil when no window is open. It survives
    /// timed-out, cancelled, and superseded attempts; its identity can cancel the surviving window.
    /// A window does not change the peer's ``TrustLevel``; that is established only after pairing.
    public private(set) var pairingWindow: PairingWindowSnapshot?
    var pairingSideWindowID: PairingAttemptID?
    /// The audio format currently being streamed by the server, or nil if no stream is active.
    public private(set) var currentStreamFormat: AudioFormatSpec?
    /// Written both here and by the control drain's `.operationalState` case, so
    /// `operationalStateEpoch` stamps every write for the rollback in
    /// `transitionOperationalState(to:)`.
    var clientOperationalState: EngineSyncState = .synchronized {
        didSet { operationalStateEpoch += 1 }
    }

    private(set) var operationalStateEpoch = 0
    var isClockSynced = false
    /// Format announced by the most recent player `stream/start`, tracked
    /// synchronously for seamless-change classification. Distinct from the public
    /// ``currentStreamFormat``, which the engine's report drain applies
    /// asynchronously once audio actually renders.
    var announcedPlayerFormat: AudioFormatSpec?
    /// Current player volume (0-100). Observable for UI binding (volume sliders).
    /// Updated by ``setVolume(_:)`` and by the server via `server/command`.
    public private(set) var currentVolume: Int = 100
    /// Current player mute state. Observable for UI binding (mute buttons).
    /// Updated by ``setMute(_:)`` and by the server via `server/command`.
    public private(set) var currentMuted: Bool = false
    /// Current output delay in milliseconds. Initialized from `PlayerConfiguration.initialOutputDelayMs`,
    /// updated when the server sends a `set_output_delay` command.
    public private(set) var outputDelayMs: Int
    /// Observability mirrors of server-declared stream activity. These do not
    /// gate client state preferences. The mirrors are render-applied (player:
    /// from the engine's `.started` report; artwork:
    /// from `.artworkStreamStarted`), so they can lag the connection's gates.
    /// `stream/clear` leaves both untouched — the stream continues (per spec).
    var playerStreamActive = false
    var artworkStreamActive = false
    /// The server-negotiated visualizer stream configuration, or nil when inactive.
    public private(set) var currentVisualizerStreamConfiguration: VisualizerStreamConfiguration?
    /// Cached from `playerConfig?.emitRawAudioEvents` to avoid optional chaining on every audio chunk.
    var shouldEmitRawAudio = false

    /// Current track metadata, accumulated from server state updates.
    public private(set) var currentMetadata: TrackMetadata?
    /// Current group info, accumulated from group updates.
    public private(set) var currentGroup: GroupInfo?
    /// Current controller state from the server.
    public private(set) var currentControllerState: ControllerState?
    /// Current colors derived from the audio, accumulated from server state updates.
    public private(set) var currentColorState: ColorState?
    /// App-facing playback status derived from the current stream, group, and metadata state.
    ///
    /// Eventually consistent: `playerStreamActive` is a render-applied mirror that
    /// can lag the connection's authoritative stream gates, so this is an
    /// observability projection — not a wire-ordered signal. Prefer the typed
    /// `ClientEvent` stream for transitions that must be wire-ordered.
    public var currentPlaybackStatus: PlaybackStatus? {
        PlaybackStatus(group: currentGroup, metadata: currentMetadata, isPlayerStreamActive: playerStreamActive)
    }

    /// Codec header for the current stream (e.g. FLAC streaminfo), if any.
    /// Set when `stream/start` carries a `codec_header` field; cleared on `stream/end`.
    public private(set) var currentCodecHeader: Data?

    /// Most recently observed audio-output capability.
    ///
    /// This client-lifetime value survives reusable ``disconnect(reason:)`` calls.
    /// Permanent ``close()`` clears it before returning.
    public private(set) var currentAudioOutput: AudioOutputSnapshot?

    /// Output-format negotiation status for the current server session.
    ///
    /// This session-lifetime value resets on reusable ``disconnect(reason:)`` and
    /// permanent ``close()``.
    public private(set) var currentOutputFormatStatus: OutputFormatStatus?

    // Multi-server state
    var currentServerId: String?
    var currentActivities: Set<Activity> = []

    /// Dependencies.
    /// Note: the facade deliberately holds NO transport reference. The connection
    /// is the transport's sole owner and single writer; all outbound protocol I/O
    /// goes through `SendspinConnection` methods.
    /// The active connection, or nil if disconnected.
    /// When a new connection replaces the old one, the old is shutdown.
    var connection: SendspinConnection?
    /// At most one pairing connection may be parked beside a playback holder.
    var pairingConnection: SendspinConnection?
    var pairingConnectionDrainTask: Task<Void, Never>?
    var pairingActivationGate: ConnectionActivationGate?
    var pairingDataDelivery: ConnectionDataDelivery?
    var pairingSessionValidity: SessionValidityToken?
    var pairingPromotionInProgress = false
    var deferredPairingEvents: [ConnectionEvent] = []

    /// Client-lifetime audio-output capability service. The facade owns exactly
    /// one provider; connections consume later session snapshots but never own it.
    let audioOutputCapabilityProvider: any AudioOutputCapabilityProviding
    let outputSettleInterval: Duration
    let outputRequestTimeout: Duration
    let handshakeTimeout: Duration
    let pairingAttemptTimeout: Duration
    let pairingWindowLifetime: Duration
    #if DEBUG
        let nonceBOverride: Data?
        let pairingHandshakeHashOverride: Data?
        let pairingScalarBOverride: Data?
    #endif
    let outputNegotiationSleep: @Sendable (Duration) async throws -> Void
    var outboundTransportFactory: @Sendable (URL) -> any ClientDialingTransport
    var audioOutputFactory: @Sendable (PlayerConfiguration, (@Sendable (AudioOutputTransition) -> Void)?) -> any AudioOutput = AudioEngine
        .makeProductionOutput
    let sessionNegotiationHook: @Sendable () async -> Void
    private var audioOutputCapabilityTask: Task<Void, Never>?
    var audioOutputSnapshotSequence: UInt64 = 0

    /// Validity token gating the current session's binary events. Stored here so
    /// `retireSession()` can invalidate it synchronously — before old-connection
    /// teardown is awaited — per the design's retire contract (both guards must
    /// reject a dying connection's late events *during* teardown, not after).
    var sessionValidity: SessionValidityToken?

    /// Exact player catalog advertised by the active session. Cleared on reusable disconnect.
    private(set) var effectivePlayerFormats: [AudioFormatSpec]?
    /// Host-selected player preference retained across reusable reconnects.
    var preferredPlayerFormat: AudioFormatSpec?

    /// Task draining control events from the connection and re-emitting them to the public events stream.
    var drainConnectionEventsTask: Task<Void, Never>?

    /// Serializes `handleCompetingConnection`; see the guard there for why.
    /// Not `private` — that method lives in the +MultiServer extension.
    var arbitrationInProgress = false

    /// Incremented by every session-transition intent (`connect`, `disconnect`, and
    /// arbitration promotion).
    ///
    /// `connection` is nil for the whole dial/handshake window, so a nil check cannot
    /// tell "no session yet" from "the caller abandoned this one". Capturing the epoch
    /// before a suspension and re-reading it after distinguishes them, which is what
    /// stops a completed dial from promoting a session the caller already cancelled.
    /// Not `private` — arbitration lives in the +MultiServer extension.
    var sessionEpoch = 0

    /// Permanent client-lifetime termination. Set before `close()` first suspends so
    /// every concurrent API call observes terminal intent immediately.
    private(set) var isTerminated = false
    private var closeTask: Task<Void, Never>?
    var pendingTransports: [UUID: any SendspinTransport] = [:]
    var advertisingPendingIDs: Set<UUID> = []
    var advertisingAccepting = false
    var pairingSetupComplete = false

    // Client-owned advertising. These defaults intentionally avoid initializer plumbing so
    // device-backed initializers can evolve independently.
    var advertisingState: AdvertisingState = .stopped
    var advertiser: (any ClientAdvertising)?
    var advertisingStartTask: Task<Void, Never>?
    var advertisingStartWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    var advertisingStartError: Error?
    var advertisingIncomingTask: Task<Void, Never>?
    var outgoingAttemptInProgress = false
    var advertisingFactoryStorage: @Sendable (String, UInt16, String) -> any ClientAdvertising = { name, port, path in
        ClientAdvertiser(name: name, port: port, path: path)
    }

    /// Event streams
    private var eventSubscribers: [UUID: AsyncStream<ClientEvent>.Continuation] = [:]

    let audioChunksContinuation: AsyncStream<AudioChunk>.Continuation
    /// Raw player audio chunks, emitted only when ``PlayerConfiguration/emitRawAudioEvents`` is true.
    public let audioChunks: AsyncStream<AudioChunk>

    let artworkContinuation: AsyncStream<ArtworkData>.Continuation
    /// Artwork bytes from the artwork data stream.
    public let artwork: AsyncStream<ArtworkData>
    /// Most recent artwork payload received from the artwork data stream.
    public private(set) var currentArtwork: ArtworkData?

    let visualizerFrameMailbox: VisualizerFrameMailbox
    /// Acquire the single app-facing visualizer frame subscription.
    ///
    /// A subscription owns the bounded mailbox consumer until it is cancelled,
    /// its pending read is cancelled, or it is deallocated. A second live
    /// subscription fails instead of silently returning an empty iterator.
    public func acquireVisualizerFrames() throws(VisualizerFrameAcquisitionError) -> VisualizerFrameSubscription {
        try VisualizerFrameSubscription(acquiring: visualizerFrameMailbox)
    }

    convenience init(
        identity: SendspinIdentity,
        name: String,
        roles: some Sequence<VersionedRole>,
        deviceInfo: DeviceInfo? = .current,
        playerConfig: PlayerConfiguration? = nil,
        artworkConfig: ArtworkConfiguration? = nil,
        visualizerConfig: VisualizerConfiguration? = nil,
        unpairedAccessEnabled: Bool = true,
        persistenceProvider: (any SendspinPersistenceProvider)? = nil,
        pairing: PairingConfiguration? = nil
    ) throws(ConfigurationError) {
        try self.init(
            identity: identity,
            name: name,
            roles: roles,
            deviceInfo: deviceInfo,
            playerConfig: playerConfig,
            artworkConfig: artworkConfig,
            visualizerConfig: visualizerConfig,
            unpairedAccessEnabled: unpairedAccessEnabled,
            persistenceProvider: persistenceProvider,
            pairing: pairing,
            audioOutputCapabilityProvider: AudioOutputCapabilityService()
        )
    }

    init(
        identity: SendspinIdentity,
        name: String,
        roles: some Sequence<VersionedRole>,
        deviceInfo: DeviceInfo? = .current,
        playerConfig: PlayerConfiguration? = nil,
        artworkConfig: ArtworkConfiguration? = nil,
        visualizerConfig: VisualizerConfiguration? = nil,
        unpairedAccessEnabled: Bool = true,
        persistenceProvider: (any SendspinPersistenceProvider)? = nil,
        pairing: PairingConfiguration? = nil,
        audioOutputCapabilityProvider: any AudioOutputCapabilityProviding,
        outputSettleInterval: Duration = .milliseconds(250),
        outputRequestTimeout: Duration = .seconds(3),
        handshakeTimeout: Duration = defaultHandshakeTimeout,
        pairingAttemptTimeout: Duration = .seconds(120),
        pairingWindowLifetime: Duration = .seconds(300),
        nonceBOverride: Data? = nil,
        pairingHandshakeHashOverride: Data? = nil,
        pairingScalarBOverride: Data? = nil,
        outputNegotiationSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        audioOutputFactory: @escaping @Sendable (PlayerConfiguration, (@Sendable (AudioOutputTransition) -> Void)?) -> any AudioOutput = AudioEngine
            .makeProductionOutput,
        outboundTransportFactory: @escaping @Sendable (URL) -> any ClientDialingTransport = {
            NWWebSocketTransport(url: $0)
        },
        sessionNegotiationHook: @escaping @Sendable () async -> Void = {}
    ) throws(ConfigurationError) {
        let orderedRoles = Self.deduplicatingRoles(roles)
        let roleSet = Set(orderedRoles)

        if roleSet.contains(.playerV1), playerConfig == nil {
            throw .playerRoleRequiresConfiguration
        }
        if roleSet.contains(.artworkV1), artworkConfig == nil {
            throw .artworkRoleRequiresConfiguration
        }
        if roleSet.contains(.visualizerV1), visualizerConfig == nil {
            throw .visualizerRoleRequiresConfiguration
        }

        self.identity = identity
        self.name = name
        self.unpairedAccessEnabled = pairing?.unpairedAccessEnabled ?? unpairedAccessEnabled
        self.roles = orderedRoles
        self.roleSet = roleSet
        self.deviceInfo = deviceInfo
        self.playerConfig = playerConfig
        self.artworkConfig = artworkConfig
        self.visualizerConfig = visualizerConfig
        self.persistenceProvider = persistenceProvider
        pairingConfiguration = pairing
        self.audioOutputCapabilityProvider = audioOutputCapabilityProvider
        self.outputSettleInterval = outputSettleInterval
        self.outputRequestTimeout = outputRequestTimeout
        self.handshakeTimeout = handshakeTimeout
        self.pairingAttemptTimeout = pairingAttemptTimeout
        self.pairingWindowLifetime = pairingWindowLifetime
        #if DEBUG
            self.nonceBOverride = nonceBOverride
            self.pairingHandshakeHashOverride = pairingHandshakeHashOverride
            self.pairingScalarBOverride = pairingScalarBOverride
        #endif
        self.outputNegotiationSleep = outputNegotiationSleep
        self.audioOutputFactory = audioOutputFactory
        self.outboundTransportFactory = outboundTransportFactory
        self.sessionNegotiationHook = sessionNegotiationHook
        outputDelayMs = playerConfig?.initialOutputDelayMs ?? 0

        // Resolve volume mode into concrete capabilities (the control is built by AudioEngine)
        volumeCapabilities = VolumeControlFactory.resolve(mode: playerConfig?.volumeMode ?? .software).capabilities

        (audioChunks, audioChunksContinuation) = AsyncStream.makeStream()
        (artwork, artworkContinuation) = AsyncStream.makeStream()
        visualizerFrameMailbox = VisualizerFrameMailbox(capacityBytes: visualizerConfig?.bufferCapacity ?? 1)

        if roleSet.contains(.playerV1) {
            startAudioOutputCapabilityMonitoring()
        }
    }

    private static func deduplicatingRoles(_ roles: some Sequence<VersionedRole>) -> [VersionedRole] {
        var seen: Set<VersionedRole> = []
        var ordered: [VersionedRole] = []
        for role in roles where seen.insert(role).inserted {
            ordered.append(role)
        }
        return ordered
    }

    isolated deinit {
        audioOutputCapabilityTask?.cancel()
        let capabilityProvider = audioOutputCapabilityProvider
        Task { await capabilityProvider.stopMonitoring() }

        for continuation in eventSubscribers.values {
            continuation.finish()
        }
        eventSubscribers.removeAll()
        audioChunksContinuation.finish()
        artworkContinuation.finish()
        visualizerFrameMailbox.finish()
        // Safety net: dropping a connected client must not leak a live, playing
        // connection graph. Capture the connection into a local — do NOT capture
        // self. (`isolated deinit` runs on the MainActor, so reading the isolated
        // stored property is legal.)
        let conn = connection
        let side = pairingConnection
        let advertiser = advertiser
        let device = ownedDevice
        let lease = deviceLease
        Task {
            await advertiser?.stop()
            await conn?.shutdown()
            if side !== conn {
                await side?.shutdown()
            }
            if let device, let lease {
                try? device.release(lease)
            }
        }
    }

    /// Create a fresh control-event stream for one caller.
    ///
    /// Each call returns an independent stream that receives future control events.
    /// Binary role payloads are not emitted here; use ``audioChunks``, ``artwork``,
    /// and ``acquireVisualizerFrames()`` for data-plane bytes.
    public func events() -> AsyncStream<ClientEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ClientEvent>.makeStream()
        guard !isTerminated else {
            continuation.finish()
            return stream
        }
        eventSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.eventSubscribers.removeValue(forKey: id)
            }
        }
        return stream
    }

    func emitEvent(_ event: ClientEvent) {
        for continuation in eventSubscribers.values {
            continuation.yield(event)
        }
    }

    private func startAudioOutputCapabilityMonitoring() {
        let provider = audioOutputCapabilityProvider
        audioOutputCapabilityTask = Task { @MainActor [weak self] in
            let updates = await provider.startMonitoring()
            let initialSnapshot = await provider.snapshot()
            self?.applyConnectionEvent(.audioOutputChanged(initialSnapshot))

            for await snapshot in updates {
                guard let self else { return }
                applyConnectionEvent(.audioOutputChanged(snapshot))
            }
        }
    }

    /// Permanent capability-service cleanup hook used by tests and ``close()``.
    /// Reusable ``disconnect(reason:)`` deliberately does not call this.
    func finishAudioOutputCapabilityMonitoring() async {
        audioOutputCapabilityTask?.cancel()
        audioOutputCapabilityTask = nil
        await audioOutputCapabilityProvider.stopMonitoring()
        currentAudioOutput = nil
        currentOutputFormatStatus = nil
    }

    // MARK: - State setters

    // Named mutators for `public private(set)` observable properties. Most are
    // private so observable state changes flow through the facade's event-drain;
    // `updateConnectionState` remains internal because multi-server arbitration
    // also projects connection state.

    func updateConnectionState(_ state: ConnectionState) {
        connectionState = state
    }

    private func updateStreamFormat(_ format: AudioFormatSpec?) {
        currentStreamFormat = format
    }

    func updateMetadata(_ metadata: TrackMetadata?) {
        currentMetadata = metadata
    }

    private func updateColorState(_ state: ColorState?) {
        currentColorState = state
    }

    private func updateGroup(_ group: GroupInfo?) {
        currentGroup = group
    }

    func updateControllerState(_ state: ControllerState?) {
        currentControllerState = state
    }

    func updateCurrentPairing(_ snapshot: PairingAttemptSnapshot?) {
        currentPairing = snapshot
    }

    func updatePairingWindow(_ window: PairingWindowSnapshot?) {
        pairingWindow = window
    }

    func clearPairingWindow() {
        pairingWindow = nil
    }

    private func updateCodecHeader(_ header: Data?) {
        currentCodecHeader = header
    }

    func applyPromotedProjection(_ snapshot: SendspinConnection.ProjectionSnapshot) {
        resetServerSessionState()
        playerStreamActive = snapshot.playerStreamActive
        artworkStreamActive = snapshot.artworkStreamActive
        currentVisualizerStreamConfiguration = snapshot.visualizerConfiguration
        updateStreamFormat(snapshot.streamFormat)
        updateCodecHeader(snapshot.codecHeader)
        currentArtwork = nil
        updateMetadata(snapshot.metadata)
        updateGroup(snapshot.group)
        updateControllerState(snapshot.controller)
        updateColorState(snapshot.color)
        clientOperationalState = snapshot.operationalState
        isClockSynced = snapshot.clockSynced
        currentOutputFormatStatus = snapshot.outputFormatStatus
        currentServerId = snapshot.serverId
        currentActivities = snapshot.activities
        trustLevel = snapshot.trustLevel
        currentVolume = snapshot.volume
        currentMuted = snapshot.muted
        outputDelayMs = snapshot.outputDelayMs
        shouldEmitRawAudio = playerConfig?.emitRawAudioEvents ?? false
    }

    // MARK: - Connection lifecycle

    /// Connect to a Sendspin server at the given URL (client-initiated connection).
    ///
    /// - Throws: ``SendspinClientError/alreadyConnected`` if not in the
    ///   `.disconnected` state.
    @MainActor
    public func connect(to url: URL) async throws {
        try requireOpen()
        guard connectionState == .disconnected else {
            throw SendspinClientError.alreadyConnected
        }
        guard advertiser == nil, advertisingState == .stopped, !advertisingAccepting else {
            throw SendspinClientError.modeConflict
        }

        connectionState = .connecting
        sessionEpoch += 1
        let dialEpoch = sessionEpoch
        await preparePairingConfiguration()

        outgoingAttemptInProgress = true
        defer { outgoingAttemptInProgress = false }
        let transport = outboundTransportFactory(url)
        let pendingID = registerPendingTransport(transport)
        defer { pendingTransports.removeValue(forKey: pendingID) }
        do {
            try await transport.connect()
        } catch {
            await transport.disconnect()
            // Only surrender the state if this dial still owns it.
            if sessionEpoch == dialEpoch, connectionState == .connecting {
                updateConnectionState(.disconnected)
            }
            try requireOpen()
            throw error
        }

        // Re-validate after the network suspension: a promotion or a disconnect bumps
        // the epoch, and neither is visible in `connection` (nil either way).
        guard sessionEpoch == dialEpoch else {
            Log.client.warning("The session changed while dialing \(url); abandoning this dial")
            await transport.disconnect()
            try requireOpen()
            throw SendspinClientError.alreadyConnected
        }

        do {
            let negotiation = try await makeSessionFormatNegotiation()
            let runtimeConfiguration = await pairingRuntimeConfiguration()
            let hello = buildClientHelloPayload(
                effectivePlayerFormats: negotiation.effectivePlayerFormats,
                configuration: runtimeConfiguration
            )
            let outcome = try await HandshakeDriver.establish(
                on: transport,
                configuration: HandshakeDriver.Configuration(
                    identity: identity,
                    candidates: pairingCandidates(),
                    clientHello: hello,
                    supportedRoles: roleSet,
                    unpairedAccessEnabled: runtimeConfiguration.unpairedAccessEnabled,
                    pairingStore: pairingConfiguration?.store
                ),
                phaseTimeout: handshakeTimeout
            )
            guard !isTerminated, sessionEpoch == dialEpoch else {
                if let lease = outcome.protectionLease, let store = outcome.pairingStore {
                    try? await store.releaseProtection(lease)
                }
                await transport.disconnect()
                try requireOpen()
                throw SendspinClientError.alreadyConnected
            }
            await setupConnection(
                with: transport,
                outcome: outcome,
                negotiation: negotiation,
                runtimeConfiguration: runtimeConfiguration,
                setupEpoch: dialEpoch
            )
            try requireOpen()
        } catch {
            await transport.disconnect()
            if sessionEpoch == dialEpoch, connectionState == .connecting {
                updateConnectionState(.disconnected)
            }
            if isTerminated {
                throw TerminatedError()
            }
            throw error
        }
    }

    /// Accept an incoming server connection (server-initiated connection).
    /// Used with `ClientAdvertiser` when servers connect to this client.
    ///
    /// If the client is already connected to a server, the multi-server decision
    /// logic from the spec is applied after the handshake completes.
    @MainActor
    public func acceptConnection(_ transport: any SendspinTransport) async throws {
        try await acceptConnection(transport, ownership: nil)
    }

    func acceptConnection(
        _ originalTransport: any SendspinTransport,
        ownership: AdvertisingTransportOwnership?,
        afterAcceptance: (@Sendable () async -> Void)? = nil
    ) async throws {
        let transport: any SendspinTransport = if let ownership {
            AdvertisingCandidateTransport(originalTransport, ownership: ownership)
        } else {
            originalTransport
        }
        try requireOpen()
        guard !outgoingAttemptInProgress || connection != nil else {
            await transport.disconnect()
            throw SendspinClientError.modeConflict
        }
        let pendingID = registerPendingTransport(transport)
        if advertisingAccepting {
            advertisingPendingIDs.insert(pendingID)
        }
        defer {
            pendingTransports.removeValue(forKey: pendingID)
            advertisingPendingIDs.remove(pendingID)
        }
        if connection == nil {
            if connectionState == .disconnected {
                connectionState = .connecting
            }
            // Claim the epoch before the first suspension: the dial window holds no
            // `connection`, so only the epoch tracks caller intent.
            sessionEpoch += 1
            let acceptEpoch = sessionEpoch
            await preparePairingConfiguration()
            do {
                let negotiation = try await makeSessionFormatNegotiation()
                let runtimeConfiguration = await pairingRuntimeConfiguration()
                let hello = buildClientHelloPayload(
                    effectivePlayerFormats: negotiation.effectivePlayerFormats,
                    configuration: runtimeConfiguration
                )
                let outcome = try await HandshakeDriver.establish(
                    on: transport,
                    configuration: HandshakeDriver.Configuration(
                        identity: identity,
                        candidates: pairingCandidates(),
                        clientHello: hello,
                        supportedRoles: roleSet,
                        unpairedAccessEnabled: runtimeConfiguration.unpairedAccessEnabled,
                        pairingStore: pairingConfiguration?.store
                    ),
                    phaseTimeout: handshakeTimeout
                )
                guard !isTerminated, sessionEpoch == acceptEpoch else {
                    if let lease = outcome.protectionLease, let store = outcome.pairingStore {
                        try? await store.releaseProtection(lease)
                    }
                    await transport.disconnect()
                    try requireOpen()
                    throw SendspinClientError.alreadyConnected
                }
                await setupConnection(
                    with: transport,
                    outcome: outcome,
                    negotiation: negotiation,
                    runtimeConfiguration: runtimeConfiguration,
                    setupEpoch: acceptEpoch,
                    ownership: ownership,
                    afterAcceptance: afterAcceptance
                )
                try requireOpen()
            } catch {
                await transport.disconnect()
                // Only a candidate still owning this epoch may reset the visible
                // state; a stale failure must not clobber a replacement session.
                if sessionEpoch == acceptEpoch, connectionState == .connecting {
                    updateConnectionState(.disconnected)
                }
                if isTerminated {
                    throw TerminatedError()
                }
                throw error
            }
        } else {
            try await handleCompetingConnection(transport, ownership: ownership, afterAcceptance: afterAcceptance)
        }
        try requireOpen()
    }

    /// Common setup for both client-initiated and server-initiated connections.
    ///
    /// Synchronously retire the current session: invalidate the binary-event
    /// validity token, detach the connection (arming the identity guard), and
    /// stop the control drain. Returns the retired connection so the caller can
    /// await its teardown.
    ///
    /// Contains no suspension points — that is the contract. Late events from
    /// the dying connection are already gated when this returns, regardless of
    /// how long its teardown takes or when it lands on the connection actor.
    /// Do not reorder a caller to install a replacement before calling this.
    @MainActor
    @discardableResult
    func retireSession() -> SendspinConnection? {
        drainConnectionEventsTask?.cancel()
        drainConnectionEventsTask = nil
        sessionValidity?.invalidate()
        visualizerFrameMailbox.clear()
        let retired = connection
        connection = nil
        return retired
    }

    /// Install an admitted session on `transport` and start it.
    ///
    /// Caller already resolved the pairing runtime snapshot and claimed its
    /// epoch: never install for an epoch that lost its claim. Non-throwing.
    @MainActor
    // swiftlint:disable:next function_body_length
    func setupConnection(
        with transport: any SendspinTransport,
        outcome: consuming HandshakeDriver.Result,
        negotiation: SessionFormatNegotiation,
        runtimeConfiguration: PairingManagementConfiguration,
        setupEpoch: Int,
        installAsPairingSide: Bool = false,
        ownership: AdvertisingTransportOwnership? = nil,
        afterAcceptance: (@Sendable () async -> Void)? = nil
    ) async {
        guard !isTerminated, sessionEpoch == setupEpoch else {
            if let lease = outcome.protectionLease, let store = outcome.pairingStore {
                try? await store.releaseProtection(lease)
            }
            await transport.disconnect()
            return
        }
        if !installAsPairingSide {
            // A new primary session drops server-reported state carried over from
            // a prior connection before the first server/state update is applied.
            resetServerSessionState()
            isClockSynced = false
            effectivePlayerFormats = negotiation.effectivePlayerFormats

            // Retire the old primary and any parked pairing side synchronously,
            // then await both teardowns before installing the replacement.
            let oldConnection = retireSession()
            let oldPairingConnection = detachPairingConnection()
            if let oldConnection {
                await oldConnection.shutdown()
            }
            if let oldPairingConnection {
                await oldPairingConnection.shutdown()
            }
            guard !isTerminated, sessionEpoch == setupEpoch else {
                if let lease = outcome.protectionLease, let store = outcome.pairingStore {
                    try? await store.releaseProtection(lease)
                }
                await transport.disconnect()
                return
            }
        }

        let initialArtworkState = makeInitialArtworkState()
        await afterAcceptance?()
        guard !isTerminated, sessionEpoch == setupEpoch,
              adoptAdvertisingTransport(transport, ownership: ownership) else {
            await transport.disconnect()
            if let lease = outcome.protectionLease, let store = outcome.pairingStore {
                try? await store.releaseProtection(lease)
            }
            if sessionEpoch == setupEpoch, connection == nil {
                updateConnectionState(.disconnected)
                emitEvent(.disconnected(reason: .connectionLost(nil)))
            }
            return
        }
        let sessionTransport = (transport as? AdvertisingCandidateTransport)?.underlying ?? transport
        // Adoption and connection construction have no intervening suspension.
        let validity = SessionValidityToken()
        if !installAsPairingSide {
            sessionValidity = validity
        }
        let clockSync = ClockSynchronizer()
        let deliveryArtworkObserver: (@Sendable (ArtworkData, SessionValidityToken) -> Void) = { [weak self] artwork, deliveryValidity in
            Task { @MainActor [weak self] in
                deliveryValidity.performIfValid {
                    validity.performIfValid {
                        self?.currentArtwork = artwork.clearsArtwork ? nil : artwork
                    }
                }
            }
        }
        let dataDelivery = ConnectionDataDelivery(
            audio: audioChunksContinuation,
            artwork: artworkContinuation,
            visualizer: visualizerFrameMailbox,
            artworkObserver: deliveryArtworkObserver
        )
        if !installAsPairingSide {
            dataDelivery.promoteToPrimary()
        }
        let activationGate = installAsPairingSide ? ConnectionActivationGate() : nil

        let audioEngine = makeAudioEngine(clock: clockSync, validity: validity)

        // A player always advertises set_output_delay; volume/mute depend on
        // the resolved VolumeMode capabilities. Non-player roles advertise nothing.
        let advertisedCommands: Set<PlayerCommand> = roleSet.contains(.playerV1)
            ? Set(volumeCapabilities.playerCommands).union([.setOutputDelay])
            : []

        let outcomeServerId = outcome.serverId
        let outcomeActivities = outcome.activities
        let outcomePairing = outcome.pairing
        let outcomeServerName = outcome.serverName
        let outcomeServerLanguages = outcome.serverLanguages
        let outcomeActiveRoles = outcome.activeRoles
        let outcomeCategory = outcome.matchedCandidate.category
        let outcomePskId = outcome.matchedCandidate.psk.pskId
        let outcomeIdentityPrivateKey = outcome.identityPrivateKey
        let outcomeServerStaticPublicKey = outcome.serverStaticPublicKey
        let outcomeSuite = outcome.suite
        let outcomeProtectionLease = outcome.protectionLease
        let sessionChannel = outcome.takeChannel()
        #if DEBUG
            let nonceBOverride = nonceBOverride
            let pairingHandshakeHashOverride = pairingHandshakeHashOverride
            let pairingScalarBOverride = pairingScalarBOverride
        #else
            let nonceBOverride: Data? = nil
            let pairingHandshakeHashOverride: Data? = nil
            let pairingScalarBOverride: Data? = nil
        #endif
        let newConnection = SendspinConnection(
            transport: sessionTransport,
            channel: sessionChannel,
            serverId: outcomeServerId,
            serverName: outcomeServerName,
            serverLanguages: outcomeServerLanguages,
            activities: outcomeActivities,
            activeRoles: outcomeActiveRoles,
            pskCategory: outcomeCategory,
            matchedPskId: outcomePskId,
            pairingStore: pairingConfiguration?.store,
            pairingProtectionLease: outcomeProtectionLease,
            pairingConfigurationRuntime: pairingConfiguration?.runtime,
            pairingAttemptTimeout: pairingAttemptTimeout,
            pairingWindowLifetime: pairingWindowLifetime,
            nonceBOverride: nonceBOverride,
            pairingHandshakeHashOverride: pairingHandshakeHashOverride,
            pairingScalarBOverride: pairingScalarBOverride,
            identityPrivateKey: outcomeIdentityPrivateKey,
            serverStaticPublicKey: outcomeServerStaticPublicKey,
            suite: outcomeSuite,
            candidateProvider: { [pairingConfiguration] in
                try await PairingCandidateBuilder.candidates(configuration: pairingConfiguration)
            },
            clientHelloPayload: buildClientHelloPayload(
                effectivePlayerFormats: negotiation.effectivePlayerFormats,
                configuration: runtimeConfiguration
            ),
            unpairedAccessEnabled: runtimeConfiguration.unpairedAccessEnabled,
            effectivePlayerFormats: negotiation.effectivePlayerFormats,
            outputSampleRatePolicy: playerConfig?.outputSampleRatePolicy,
            initialOutputSnapshot: negotiation.outputSnapshot,
            initialOutputSnapshotSequence: negotiation.outputSnapshotSequence,
            outputSettleInterval: outputSettleInterval,
            outputRequestTimeout: outputRequestTimeout,
            outputNegotiationSleep: outputNegotiationSleep,
            audioSink: audioChunksContinuation,
            artworkSink: artworkContinuation,
            visualizerDelivery: nil,
            dataDelivery: dataDelivery,
            activationGate: activationGate,
            emitRawAudio: playerConfig?.emitRawAudioEvents ?? false,
            artworkObserver: nil,
            validity: validity,
            advertisedCommands: advertisedCommands,
            roles: roleSet,
            // Live facade state, not playerConfig defaults: a multi-server switch
            // (and any runtime setOutputDelay) must carry into the new session.
            initialOutputDelayMs: outputDelayMs,
            initialPreferredPlayerFormat: preferredPlayerFormat,
            initialVolume: currentVolume,
            initialMuted: currentMuted,
            initialArtworkState: initialArtworkState,
            initialVisualizerState: visualizerConfig?.stateObject,
            requiredLeadTimeMs: playerConfig?.requiredLeadTimeMs ?? defaultRequiredLeadTimeMs,
            minBufferMs: playerConfig?.minBufferMs ?? defaultMinBufferMs,
            clock: clockSync,
            engine: audioEngine
        )
        // No suspension occurs between the re-check above and this install.

        if installAsPairingSide {
            pairingConnection = newConnection
            pairingActivationGate = activationGate
            pairingDataDelivery = dataDelivery
            pairingSessionValidity = validity
            pairingConnectionDrainTask?.cancel()
            pairingConnectionDrainTask = Task { @MainActor [weak self] in
                if let activationGate {
                    self?.observePairingActivations(from: activationGate, connection: newConnection)
                }
                for await event in newConnection.events {
                    newConnection.controlSink.decrementDepth()
                    guard let self else { return }
                    guard !isTerminated,
                          pairingConnection === newConnection || connection === newConnection else { return }
                    if pairingConnection === newConnection || pairingPromotionInProgress {
                        if pairingPromotionInProgress {
                            deferredPairingEvents.append(event)
                        } else {
                            applyPairingConnectionEvent(event)
                        }
                    } else {
                        applyConnectionEvent(event)
                    }
                }
            }
        } else {
            connection = newConnection
            currentOutputFormatStatus = nil
        }

        // Pairing setup sends its first protocol message. Mark the connection
        // running for that handoff send, but defer the supervisor until setup is
        // complete so the live reader cannot race the initial activation replay.
        if let outcomePairing {
            await newConnection.prepareInitialPairingActivation(outcomePairing)
        }
        await newConnection.start()
        if !installAsPairingSide, let snapshot = await newConnection.pairingAttemptSnapshot() {
            updateCurrentPairing(snapshot)
        }

        // Drain control events without retaining the client: upgrade weak `self` per event.
        // Otherwise a parked task prevents deinit and its cleanup safety net.
        guard !installAsPairingSide else { return }
        drainConnectionEventsTask = Task { [weak self] in
            guard newConnection === self?.connection else { return }
            if let sequence = self?.audioOutputSnapshotSequence,
               sequence > negotiation.outputSnapshotSequence,
               let currentAudioOutput = self?.currentAudioOutput {
                await newConnection.receiveAudioOutputSnapshot(
                    currentAudioOutput,
                    sequence: sequence
                )
            }
            for await event in newConnection.events {
                // The event left the control buffer regardless of what we do with it.
                newConnection.controlSink.decrementDepth()

                guard let self else { return }
                // Identity guard: if connection was replaced, ignore this stale event.
                guard newConnection === connection else { return }
                // Promotion deliberately awaits the incumbent's graceful teardown
                // before swapping facade ownership. Its terminal event is not a
                // session loss; applying it here would retire the parked winner.
                guard !pairingPromotionInProgress else { continue }
                applyConnectionEvent(event)
            }
        }

        guard !installAsPairingSide else { return }

        // Set should-emit-raw-audio flag
        shouldEmitRawAudio = playerConfig?.emitRawAudioEvents ?? false

        currentServerId = outcomeServerId
        currentActivities = outcomeActivities
        if outcomeActivities.contains(.playback) {
            Task { await persistenceProvider?.saveLastPlayedServerId(outcomeServerId) }
        }
        updateConnectionState(.connected)
    }

    private func makeInitialArtworkState() -> ArtworkStateObject? {
        artworkConfig.map { config in
            do {
                return try ArtworkStateObject(channels: config.channels.map { channel in
                    try ArtworkStateChannel(
                        source: channel.source,
                        format: channel.source == .none ? nil : channel.format,
                        width: channel.source == .none ? nil : channel.width,
                        height: channel.source == .none ? nil : channel.height
                    )
                })
            } catch {
                preconditionFailure("Validated artwork configuration cannot produce state: \(error)")
            }
        }
    }

    private func makeAudioEngine(
        clock: any ClockSyncProtocol,
        validity: SessionValidityToken
    ) -> AudioEngine {
        guard roleSet.contains(.playerV1), let playerConfig else {
            let output = NoOpAudioOutput()
            let scheduler = AudioScheduler(clockSync: clock)
            return AudioEngine(output: output, scheduler: scheduler, clock: clock)
        }

        let capabilityProvider = audioOutputCapabilityProvider
        return AudioEngine(
            clock: clock,
            config: playerConfig,
            outputTransitionCallback: { transition in
                validity.performSendableIfValid {
                    Task {
                        switch transition {
                        case let .willBegin(sampleRate):
                            await capabilityProvider.audioQueueTransitionWillBegin(sampleRate: sampleRate)
                        case .didStart:
                            await capabilityProvider.audioQueueTransitionDidStart()
                        }
                    }
                }
            },
            audioOutputFactory: audioOutputFactory
        )
    }

    func requireOpen() throws {
        guard !isTerminated else { throw TerminatedError() }
    }

    private func registerPendingTransport(_ transport: any SendspinTransport) -> UUID {
        let id = UUID()
        pendingTransports[id] = transport
        return id
    }

    /// Permanently close this client and finish all client-lifetime streams.
    ///
    /// If a live connection exists, the client first sends `client/goodbye` with the
    /// `shutdown` reason, then tears down the connection. Unlike ``disconnect(reason:)``,
    /// this operation does not emit a terminal ``ClientEvent/disconnected(reason:)`` event;
    /// it finishes all client-lifetime streams instead.
    ///
    /// This operation is terminal: the client cannot reconnect or accept commands afterwards.
    /// Concurrent and repeated callers await the same teardown. Create a new client instance
    /// to start another lifecycle.
    public func close() async {
        if let closeTask {
            await closeTask.value
            return
        }

        isTerminated = true
        sessionEpoch += 1
        arbitrationInProgress = false
        await shutdownAdvertising()
        drainConnectionEventsTask?.cancel()
        drainConnectionEventsTask = nil
        sessionValidity?.invalidate()
        sessionValidity = nil
        let retiredConnection = connection
        let retiredPairingConnection = pairingConnection
        pairingConnectionDrainTask?.cancel()
        pairingConnectionDrainTask = nil
        pairingActivationGate?.cancel()
        pairingActivationGate = nil
        pairingPromotionInProgress = false
        deferredPairingEvents.removeAll()
        pairingDataDelivery = nil
        pairingSessionValidity?.invalidate()
        pairingSessionValidity = nil
        pairingConnection = nil
        connection = nil
        let candidates = Array(pendingTransports.values)
        pendingTransports.removeAll()
        let capabilityTask = audioOutputCapabilityTask
        audioOutputCapabilityTask = nil
        capabilityTask?.cancel()
        let capabilityProvider = audioOutputCapabilityProvider

        let task = Task { @MainActor [weak self] in
            for transport in candidates {
                await transport.disconnect()
            }
            if let retiredConnection {
                await retiredConnection.disconnect(reason: .shutdown)
            }
            if let retiredPairingConnection {
                await retiredPairingConnection.disconnect(reason: .shutdown)
            }
            await capabilityTask?.value
            await capabilityProvider.stopMonitoring()
            self?.finishClose()
        }
        closeTask = task
        await task.value
    }

    private func finishClose() {
        if let ownedDevice, let deviceLease {
            try? ownedDevice.release(deviceLease)
        }
        deviceLease = nil
        ownedDevice = nil
        updateConnectionState(.disconnected)
        resetStreamState()
        resetServerSessionState()
        currentAudioOutput = nil
        currentOutputFormatStatus = nil
        currentArtwork = nil
        effectivePlayerFormats = nil
        currentServerId = nil
        currentActivities = []
        isClockSynced = false
        for continuation in eventSubscribers.values {
            continuation.finish()
        }
        eventSubscribers.removeAll()
        audioChunksContinuation.finish()
        artworkContinuation.finish()
        visualizerFrameMailbox.finish()
    }

    /// Record the host application's audio-session activation state.
    ///
    /// SendspinKit never changes the host's audio-session category, mode, or active
    /// state. On iOS, tvOS, and watchOS, later capability snapshots use this signal
    /// to decide whether session-backed route values are trustworthy. On macOS,
    /// where AVAudioSession does not apply, the service records the value but performs
    /// no session work. Returning guarantees later snapshots observe this update.
    /// - Throws: ``TerminatedError`` after ``close()`` begins.
    public func setAudioSessionActivationState(_ state: AudioSessionActivationState) async throws {
        try requireOpen()
        await audioOutputCapabilityProvider.setAudioSessionActivationState(state)
        try requireOpen()
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
        guard !isTerminated else {
            await closeTask?.value
            return
        }
        // Invalidate any in-flight dial or arbitration before the first suspension, so
        // whichever one resumes sees a changed epoch and abandons its transport.
        sessionEpoch += 1

        guard let conn = connection else {
            if let side = pairingConnection {
                dropPairingConnection(side)
            }
            // Mid-dial: there is no connection to say goodbye to, but the caller's
            // intent must still land, or `connectionState` stays `.connecting` forever.
            if connectionState != .disconnected {
                applyDisconnected(reason: .explicit(reason))
            }
            return
        }
        // Promotion owns the incumbent goodbye. Retire facade state immediately if
        // a concurrent disconnect invalidates that promotion; finish teardown in the
        // background rather than waiting on the gated send.
        let promotionWasInProgress = pairingPromotionInProgress
        if let side = pairingConnection {
            dropPairingConnection(side)
        }
        if promotionWasInProgress {
            applyConnectionEvent(.disconnected(reason: .explicit(reason)))
            Task { await conn.disconnect(reason: reason) }
            return
        }
        await conn.disconnect(reason: reason)
        if connection === conn {
            applyDisconnected(reason: .explicit(reason))
        }
    }

    // swiftlint:disable cyclomatic_complexity
    /// Apply one control event to facade state, then re-emit the render-applied
    /// event to the public stream. Called per event by the drain
    /// task, which holds `self` only for the duration of the call.
    @MainActor
    func applyConnectionEvent(_ event: ConnectionEvent) { // swiftlint:disable:this function_body_length
        guard !isTerminated else { return }
        switch event {
        case let .paired(snapshot):
            currentPairing = snapshot
            // A late success from an older attempt must not close a newer window.
            if pairingWindow?.attemptID == snapshot.id {
                pairingWindow = nil
            }
            emitEvent(.paired(snapshot))

        case let .pairingCodeChanged(snapshot):
            // A terminal nil-code projection follows the ended event so a
            // consumer can observe both lifecycle and code removal in order.
            if case .ended = snapshot.phase {
                emitEvent(.pairingCodeChanged(snapshot))
            } else {
                currentPairing = snapshot
                emitEvent(.pairingCodeChanged(snapshot))
            }

        case let .pairingAttemptEnded(snapshot):
            currentPairing = snapshot
            emitEvent(.pairingAttemptEnded(snapshot))

        case let .pairingAttemptSuperseded(attemptID):
            if currentPairing?.id == attemptID {
                currentPairing = nil
            }
            emitEvent(.pairingAttemptSuperseded(attemptID))

        case let .pairingWindowChanged(window):
            pairingWindow = window
            emitEvent(.pairingWindowChanged(window))

        case let .serverConnected(info):
            currentServerId = info.serverId
            trustLevel = info.trustLevel
            currentActivities = info.activities
            updateConnectionState(.connected)
            emitEvent(.serverConnected(info))

        case let .audioOutputChanged(output):
            let changed = currentAudioOutput != output
            if changed {
                currentAudioOutput = output
                emitEvent(.audioOutputChanged(output))
            }
            audioOutputSnapshotSequence += 1
            let sequence = audioOutputSnapshotSequence
            if let connection {
                Task { [weak self] in
                    guard self?.connection === connection else { return }
                    await connection.receiveAudioOutputSnapshot(output, sequence: sequence)
                }
            }

        case let .outputFormatStatusChanged(status):
            guard currentOutputFormatStatus != status else { return }
            currentOutputFormatStatus = status
            emitEvent(.outputFormatStatusChanged(status))

        case let .metadataReceived(metadata):
            updateMetadata(metadata)
            emitEvent(.metadataReceived(metadata))

        case .metadataCleared:
            updateMetadata(nil)
            emitEvent(.metadataReceived(.empty))

        case let .controllerStateUpdated(state):
            updateControllerState(state)
            emitEvent(.controllerStateUpdated(state))

        case .controllerStateCleared:
            updateControllerState(nil)
            emitEvent(.controllerStateCleared)

        case let .colorStateUpdated(state):
            updateColorState(state)
            emitEvent(.colorStateUpdated(state))

        case .colorStateCleared:
            updateColorState(nil)
            emitEvent(.colorStateCleared)

        case let .groupUpdated(group):
            updateGroup(group)
            emitEvent(.groupUpdated(group))

        case let .artworkStreamStarted(channels):
            artworkStreamActive = true
            emitEvent(.artworkStreamStarted(channels))

        case let .visualizerStreamStarted(configuration):
            currentVisualizerStreamConfiguration = configuration
            emitEvent(.visualizerStreamStarted(configuration))

        case let .streamAccepted(format):
            playerStreamActive = true
            updateStreamFormat(format)

        case let .streamStarted(format):
            playerStreamActive = true
            updateStreamFormat(format)
            emitEvent(.streamStarted(format))

        case let .streamFormatChanged(format):
            updateStreamFormat(format)
            emitEvent(.streamFormatChanged(format))

        case let .streamEnded(roles):
            if roles == nil || roles?.contains(StreamRole.player.rawValue) == true {
                playerStreamActive = false
                updateStreamFormat(nil)
                updateCodecHeader(nil)
                announcedPlayerFormat = nil
            }
            if roles == nil || roles?.contains(StreamRole.artwork.rawValue) == true {
                artworkStreamActive = false
                currentArtwork = nil
            }
            if roles == nil || roles?.contains(StreamRole.visualizer.rawValue) == true {
                currentVisualizerStreamConfiguration = nil
            }
            emitEvent(.streamEnded(roles: roles))

        case let .streamCleared(roles):
            // stream/clear clears buffers WITHOUT ending the stream (per spec):
            // no format reset and no gate change — the stream stays active and
            // chunks received after this message continue to play.
            emitEvent(.streamCleared(roles: roles))

        case let .outputDelayChanged(milliseconds):
            outputDelayMs = milliseconds
            emitEvent(.outputDelayChanged(milliseconds: milliseconds))

        case let .serverActivated(activities, activeRoles):
            if !activeRoles.contains(.artworkV1) {
                currentArtwork = nil
            }
            currentActivities = activities
            if activities.contains(.playback), let currentServerId {
                Task { await persistenceProvider?.saveLastPlayedServerId(currentServerId) }
            }
            emitEvent(.serverConnected(ServerInfo(
                serverId: currentServerId ?? "",
                name: "",
                trustLevel: trustLevel,
                activeRoles: activeRoles,
                activities: activities
            )))

        case let .operationalState(state):
            clientOperationalState = state
                // Operational state is applied but not re-emitted as a public event
                // (it's an internal state projection)

        case .clockSyncEstablished:
            isClockSynced = true
                // Internal state projection; not a public event.

        case let .streamError(error):
            // A stream-start error (unsupported codec / invalid format / audio-start
            // failure) still opened the player stream gate: the client recovers by
            // publishing a supported format preference.
            playerStreamActive = true
            // Project connection stream errors to observable connectionState errors.
            updateConnectionState(.error(error))
            emitEvent(.streamingFailed(error))

        case let .playerVolumeChanged(volume):
            currentVolume = volume
                // Volume changes are internal state; don't emit (servers send via server/command, we apply locally)

        case let .playerMutedChanged(muted):
            currentMuted = muted
                // Mute changes are internal state; don't emit

        case let .lastPlayedServerChanged(serverId):
            // Activation persists the last-played server; group/update only emits
            // the compatibility event and must not write a second time.
            emitEvent(.lastPlayedServerChanged(serverId: serverId))

        case let .disconnected(reason):
            applyDisconnected(reason: reason)
        }
    }

    // swiftlint:enable cyclomatic_complexity

    /// Apply terminal disconnection state exactly once from either the drain task
    /// or the awaited public `disconnect()` postcondition path.
    private func applyDisconnected(reason: DisconnectReason) {
        guard connection != nil || connectionState != .disconnected else { return }
        // Terminal event: retire the connection and apply reconnect logic.
        // A parked pairing side belongs to the same session and must not outlive
        // a lost primary transport.
        let retiredPairingConnection = detachPairingConnection()
        if let retiredPairingConnection {
            Task { await retiredPairingConnection.shutdown() }
        }
        // Volume/mute/outputDelay deliberately survive (device-user state,
        // like the spec's output-delay persistence): the next session is
        // seeded from facade state and re-applies them to its fresh engine.
        updateConnectionState(.disconnected)
        resetStreamState()
        currentOutputFormatStatus = nil
        effectivePlayerFormats = nil
        currentServerId = nil
        currentActivities = []
        // Don't clear currentGroup — spec preserves group membership across reconnects

        // Synchronously invalidate and release the connection so any late
        // events from the dead connection are dropped by both guards.
        // (The token is already invalid via finishTeardown; this keeps the
        // "retired implies invalid" invariant local and unconditional.)
        // Not retireSession(): that would cancel the drain task this very
        // loop may be running on — the stream is finishing on its own.
        sessionValidity?.invalidate()
        connection = nil

        // Release the drain task; the connection released its own resources
        // (transport, engine) during teardown.
        drainConnectionEventsTask = nil

        emitEvent(.disconnected(reason: reason))
    }

    /// Clear every marker of the currently-active stream(s). Shared by
    /// ``disconnect(reason:)`` and the connection-lost path so a dropped link
    /// leaves the same coherent "no active stream" state an explicit disconnect
    /// would. Request-format APIs fail with `notConnected` once `connection` is
    /// nil; these mirrors are observability state.
    func resetStreamState() {
        updateStreamFormat(nil)
        updateCodecHeader(nil)
        announcedPlayerFormat = nil
        shouldEmitRawAudio = false
        playerStreamActive = false
        artworkStreamActive = false
        currentVisualizerStreamConfiguration = nil
        visualizerFrameMailbox.clear()
    }

    /// Clear server-reported state that is scoped to a single connection. A
    /// reconnected server must not inherit metadata or controller state from the
    /// dead connection. `currentServerId` and
    /// Server identity and activities are excluded because they are replaced with each
    /// admitted session. Group id/name survive per spec, but playback state is
    /// session-scoped and is cleared to avoid reporting stale playback status.
    func resetServerSessionState() {
        updateMetadata(nil)
        if let group = currentGroup {
            updateGroup(GroupInfo(groupId: group.groupId, groupName: group.groupName, playbackState: nil))
        }
        updateControllerState(nil)
        updateColorState(nil)
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
    /// - Throws: ``SendspinClientError/notConnected`` if disconnected, or
    ///   ``SendspinClientError/roleNotActive(_:)`` if not configured as a player.
    @MainActor
    public func setVolume(_ volume: Int) async throws {
        try requireOpen()
        guard roleSet.contains(.playerV1) else { throw SendspinClientError.roleNotActive(.playerV1) }
        guard let conn = connection else { throw SendspinClientError.notConnected }
        try await conn.requireActiveRole(.playerV1)

        let clamped = max(0, min(100, volume))
        guard clamped != currentVolume else { return }
        currentVolume = clamped

        // Forward to the connection (the client/state and engine authority) best-effort;
        // a failed send does not revert the optimistic local state.
        try? await conn.setVolume(clamped)
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
    /// - Throws: ``SendspinClientError/notConnected`` if disconnected, or
    ///   ``SendspinClientError/roleNotActive(_:)`` if not configured as a player.
    @MainActor
    public func setMute(_ muted: Bool) async throws {
        try requireOpen()
        guard roleSet.contains(.playerV1) else { throw SendspinClientError.roleNotActive(.playerV1) }
        guard let conn = connection else { throw SendspinClientError.notConnected }
        try await conn.requireActiveRole(.playerV1)

        guard muted != currentMuted else { return }
        currentMuted = muted

        // Forward to the connection (the client/state and engine authority) best-effort;
        // a failed send does not revert the optimistic local state.
        try? await conn.setMuted(muted)
    }

    /// Set output delay in milliseconds (0-5000).
    ///
    /// Per spec: compensates for delay beyond the audio port (external speakers,
    /// amplifiers). Emits `.outputDelayChanged` so the host app can persist the
    /// new value. The server is notified best-effort — a failed `client/state`
    /// send does not prevent the local delay change from taking effect.
    ///
    /// - Throws: ``SendspinClientError/notConnected`` if disconnected, or
    ///   ``SendspinClientError/roleNotActive(_:)`` if not configured as a player.
    @MainActor
    public func setOutputDelay(_ delayMs: Int) async throws {
        try requireOpen()
        guard roleSet.contains(.playerV1) else { throw SendspinClientError.roleNotActive(.playerV1) }
        guard let conn = connection else { throw SendspinClientError.notConnected }
        try await conn.requireActiveRole(.playerV1)
        let clamped = max(0, min(maxOutputDelayMs, delayMs))
        guard clamped != outputDelayMs else { return }
        outputDelayMs = clamped

        // Forward to the connection (the client/state and engine authority) best-effort;
        // a failed send does not revert the optimistic local state.
        try? await conn.setOutputDelay(clamped)
    }

    // MARK: - Operational state transitions

    /// Atomically transition `clientOperationalState` to `newState` and notify the server.
    ///
    /// If the server notification fails, rolls back to the previous state and throws.
    /// This prevents split-brain where the client's local state diverges from what
    /// the server believes.
    ///
    /// Internal (not private) so that `SendspinClient+Commands.swift` can call it.
    func transitionOperationalState(to newState: EngineSyncState) async throws {
        guard let conn = connection else { throw SendspinClientError.notConnected }
        // Apply optimistically for the synchronous observable, then forward to the
        // connection (the single writer of client/state). Roll back on send failure.
        let previous = clientOperationalState
        clientOperationalState = newState
        let stamp = operationalStateEpoch
        func rollBackIfUntouched() {
            // Skip the rollback if the drain applied an authoritative state during the
            // await; clobbering it is the split-brain the rollback exists to prevent.
            if operationalStateEpoch == stamp {
                clientOperationalState = previous
            }
        }
        do {
            try await conn.setOperationalState(newState)
        } catch let error as SendspinClientError {
            rollBackIfUntouched()
            throw error
        } catch {
            rollBackIfUntouched()
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
