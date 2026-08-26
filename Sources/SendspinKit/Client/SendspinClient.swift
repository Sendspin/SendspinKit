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
    let unpairedAccessEnabled: Bool
    let roles: [VersionedRole]
    let roleSet: Set<VersionedRole>
    let deviceInfo: DeviceInfo?
    let playerConfig: PlayerConfiguration?
    let artworkConfig: ArtworkConfiguration?
    /// Optional storage hook for the spec's "last played server" bookkeeping.
    /// Saved on every `group/update` that reports playback started; read by the
    /// multi-server arbitration tiebreak. `nil` means no implicit storage: discovery
    /// ties are resolved as if no last-played server has been remembered.
    let persistenceProvider: (any SendspinPersistenceProvider)?
    /// Pairing PSK and long-term record persistence for Noise sessions.
    public let pairingConfiguration: PairingConfiguration?
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
    /// Observability mirrors of server-declared stream activity. These do NOT
    /// gate `stream/request-format`: per spec, those requests are allowed before
    /// a stream starts and after it ends. The mirrors are render-applied (player:
    /// from the engine's `.started` report; artwork:
    /// from `.artworkStreamStarted`), so they can lag the connection's gates.
    /// `stream/clear` leaves both untouched — the stream continues (per spec).
    var playerStreamActive = false
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
    /// Current colors derived from the audio, accumulated from `server/state` deltas.
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

    /// Client-lifetime audio-output capability service. The facade owns exactly
    /// one provider; connections consume later session snapshots but never own it.
    let audioOutputCapabilityProvider: any AudioOutputCapabilityProviding
    let outputSettleInterval: Duration
    let outputRequestTimeout: Duration
    let handshakeTimeout: Duration
    let pairingAttemptTimeout: Duration
    let outputNegotiationSleep: @Sendable (Duration) async throws -> Void
    let outboundTransportFactory: @Sendable (URL) -> any ClientDialingTransport
    let sessionNegotiationHook: @Sendable () async -> Void
    private var audioOutputCapabilityTask: Task<Void, Never>?
    var audioOutputSnapshotSequence: UInt64 = 0

    /// Validity token gating the current session's binary events. Stored here so
    /// `retireSession()` can invalidate it synchronously — before old-connection
    /// teardown is awaited — per the design's retire contract (both guards must
    /// reject a dying connection's late events *during* teardown, not after).
    private(set) var sessionValidity: SessionValidityToken?

    /// Exact player catalog advertised by the active session. Cleared on reusable disconnect.
    private(set) var effectivePlayerFormats: [AudioFormatSpec]?

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
    private var pendingTransports: [UUID: any SendspinTransport] = [:]
    var pairingSetupComplete = false

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

    let visualizerDataContinuation: AsyncStream<VisualizerData>.Continuation
    /// Visualizer bytes from the visualizer data stream.
    public let visualizerData: AsyncStream<VisualizerData>

    public convenience init(
        identity: SendspinIdentity,
        name: String,
        roles: some Sequence<VersionedRole>,
        deviceInfo: DeviceInfo? = .current,
        playerConfig: PlayerConfiguration? = nil,
        artworkConfig: ArtworkConfiguration? = nil,
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
        unpairedAccessEnabled: Bool = true,
        persistenceProvider: (any SendspinPersistenceProvider)? = nil,
        pairing: PairingConfiguration? = nil,
        audioOutputCapabilityProvider: any AudioOutputCapabilityProviding,
        outputSettleInterval: Duration = .milliseconds(250),
        outputRequestTimeout: Duration = .seconds(3),
        handshakeTimeout: Duration = defaultHandshakeTimeout,
        pairingAttemptTimeout: Duration = .seconds(120),
        outputNegotiationSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
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

        self.identity = identity
        self.name = name
        self.unpairedAccessEnabled = unpairedAccessEnabled
        self.roles = orderedRoles
        self.roleSet = roleSet
        self.deviceInfo = deviceInfo
        self.playerConfig = playerConfig
        self.artworkConfig = artworkConfig
        self.persistenceProvider = persistenceProvider
        pairingConfiguration = pairing
        self.audioOutputCapabilityProvider = audioOutputCapabilityProvider
        self.outputSettleInterval = outputSettleInterval
        self.outputRequestTimeout = outputRequestTimeout
        self.handshakeTimeout = handshakeTimeout
        self.pairingAttemptTimeout = pairingAttemptTimeout
        self.outputNegotiationSleep = outputNegotiationSleep
        self.outboundTransportFactory = outboundTransportFactory
        self.sessionNegotiationHook = sessionNegotiationHook
        outputDelayMs = playerConfig?.initialOutputDelayMs ?? 0

        // Resolve volume mode into concrete capabilities (the control is built by AudioEngine)
        volumeCapabilities = VolumeControlFactory.resolve(mode: playerConfig?.volumeMode ?? .software).capabilities

        (audioChunks, audioChunksContinuation) = AsyncStream.makeStream()
        (artwork, artworkContinuation) = AsyncStream.makeStream()
        (visualizerData, visualizerDataContinuation) = AsyncStream.makeStream()

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
        visualizerDataContinuation.finish()
        // Safety net: dropping a connected client must not leak a live, playing
        // connection graph. Capture the connection into a local — do NOT capture
        // self. (`isolated deinit` runs on the MainActor, so reading the isolated
        // stored property is legal.)
        let conn = connection
        Task { await conn?.shutdown() }
    }

    /// Create a fresh control-event stream for one caller.
    ///
    /// Each call returns an independent stream that receives future control events.
    /// Binary role payloads are not emitted here; use ``audioChunks``, ``artwork``,
    /// and ``visualizerData`` for data-plane bytes.
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

    private func emitEvent(_ event: ClientEvent) {
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

    private func updateMetadata(_ metadata: TrackMetadata?) {
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

    private func updateCodecHeader(_ header: Data?) {
        currentCodecHeader = header
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

        connectionState = .connecting
        sessionEpoch += 1
        let dialEpoch = sessionEpoch
        await preparePairingConfiguration()

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

        // Re-validate: the guard above ran before a network-length suspension, during
        // which an inbound server can win arbitration and be promoted, or the caller can
        // call `disconnect()`. Either bumps the epoch, and neither is visible in
        // `connection` — a cancelled dial leaves it nil, exactly as an untouched one does.
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
                unpairedAccessEnabled: runtimeConfiguration.unpairedAccessEnabled
            )
            let outcome = try await HandshakeDriver.establish(
                on: transport,
                configuration: HandshakeDriver.Configuration(
                    identity: identity,
                    candidates: pairingCandidates(),
                    clientHello: hello,
                    supportedRoles: roleSet,
                    unpairedAccessEnabled: runtimeConfiguration.unpairedAccessEnabled
                ),
                phaseTimeout: handshakeTimeout
            )
            try requireOpen()
            guard sessionEpoch == dialEpoch else {
                await transport.disconnect()
                throw SendspinClientError.alreadyConnected
            }
            await setupConnection(with: transport, outcome: outcome, negotiation: negotiation)
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
        try requireOpen()
        let pendingID = registerPendingTransport(transport)
        defer { pendingTransports.removeValue(forKey: pendingID) }
        if connectionState == .disconnected {
            connectionState = .connecting
            await preparePairingConfiguration()
            do {
                let negotiation = try await makeSessionFormatNegotiation()
                let runtimeConfiguration = await pairingRuntimeConfiguration()
                let hello = buildClientHelloPayload(
                    effectivePlayerFormats: negotiation.effectivePlayerFormats,
                    unpairedAccessEnabled: runtimeConfiguration.unpairedAccessEnabled
                )
                let outcome = try await HandshakeDriver.establish(
                    on: transport,
                    configuration: HandshakeDriver.Configuration(
                        identity: identity,
                        candidates: pairingCandidates(),
                        clientHello: hello,
                        supportedRoles: roleSet,
                        unpairedAccessEnabled: runtimeConfiguration.unpairedAccessEnabled
                    ),
                    phaseTimeout: handshakeTimeout
                )
                try requireOpen()
                await setupConnection(with: transport, outcome: outcome, negotiation: negotiation)
            } catch {
                await transport.disconnect()
                updateConnectionState(.disconnected)
                throw error
            }
        } else {
            try await handleCompetingConnection(transport)
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
        let retired = connection
        connection = nil
        return retired
    }

    /// - Parameter preReadHello: When non-nil, the `client/hello` was already sent
    ///   and the `server/hello` already consumed during competing-connection
    ///   arbitration. In that case we process the hello directly instead of sending
    ///   another `client/hello`, and the message loop resumes the transport's stream
    ///   from the (buffered) frames that follow.
    ///
    /// This setup path is intentionally non-throwing: all genuine dial/handshake
    /// failures are handled before a transport reaches this point, so callers do not
    /// need duplicate rollback logic after they set `.connecting`.
    @MainActor
    // swiftlint:disable:next function_body_length
    func setupConnection(
        with transport: any SendspinTransport,
        outcome: consuming HandshakeDriver.Result,
        negotiation: SessionFormatNegotiation
    ) async {
        guard !isTerminated else {
            await transport.disconnect()
            return
        }
        // A new connection is a new session: drop any server-reported state carried
        // over from a prior connection (notably one lost without an explicit
        // disconnect) before the first server/state can merge a delta onto it.
        // Placed here, not in handleServerHello — that also fires on a same-connection
        // re-hello, where the accumulated state is still valid.
        resetServerSessionState()
        isClockSynced = false
        effectivePlayerFormats = negotiation.effectivePlayerFormats

        // Retire the old session synchronously (token + identity guards both
        // reject its late events from this point), then await its teardown.
        //
        // `oldConnection` is nil for every current caller, so this await does not run. If
        // that changes, the nil-`connection` window makes `disconnect()` a silent no-op and
        // can orphan a live connection. Keep the rest of this suspension-free.
        let oldConnection = retireSession()
        if let oldConnection {
            await oldConnection.shutdown()
        }

        // Build the SendspinConnection with configuration from this facade
        let validity = SessionValidityToken()
        sessionValidity = validity
        let clockSync = ClockSynchronizer()

        let audioEngine = makeAudioEngine(clock: clockSync, validity: validity)

        // A player always advertises set_output_delay; volume/mute depend on
        // the resolved VolumeMode capabilities. Non-player roles advertise nothing.
        let advertisedCommands: Set<PlayerCommand> = roleSet.contains(.playerV1)
            ? Set(volumeCapabilities.playerCommands).union([.setOutputDelay])
            : []

        let outcomeServerId = outcome.serverId
        let outcomeActivities = outcome.activities
        let outcomeServerName = outcome.serverName
        let outcomeActiveRoles = outcome.activeRoles
        let outcomeCategory = outcome.matchedCandidate.category
        let outcomePskId = outcome.matchedCandidate.psk.pskId
        let outcomeIdentityPrivateKey = outcome.identityPrivateKey
        let outcomeServerStaticPublicKey = outcome.serverStaticPublicKey
        let outcomeSuite = outcome.suite
        let sessionChannel = outcome.takeChannel()
        let runtimeConfiguration = await pairingRuntimeConfiguration()
        let newConnection = SendspinConnection(
            transport: transport,
            channel: sessionChannel,
            serverId: outcomeServerId,
            serverName: outcomeServerName,
            activities: outcomeActivities,
            activeRoles: outcomeActiveRoles,
            pskCategory: outcomeCategory,
            matchedPskId: outcomePskId,
            pairingStore: pairingConfiguration?.store,
            pairingConfigurationRuntime: pairingConfiguration?.runtime,
            pairingAttemptTimeout: pairingAttemptTimeout,
            identityPrivateKey: outcomeIdentityPrivateKey,
            serverStaticPublicKey: outcomeServerStaticPublicKey,
            suite: outcomeSuite,
            candidateProvider: { [pairingConfiguration] in
                await PairingCandidateBuilder.candidates(configuration: pairingConfiguration)
            },
            clientHelloPayload: buildClientHelloPayload(
                effectivePlayerFormats: negotiation.effectivePlayerFormats,
                unpairedAccessEnabled: runtimeConfiguration.unpairedAccessEnabled
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
            visualizerSink: visualizerDataContinuation,
            emitRawAudio: playerConfig?.emitRawAudioEvents ?? false,
            artworkObserver: { [weak self] artwork in
                Task { @MainActor [weak self] in
                    // Same session-validity contract as the public artwork
                    // stream's yieldIfValid: a retired connection's in-flight
                    // artwork must not mutate facade state. The token check and
                    // write happen under the token lock, closing the snapshot/use
                    // window that a separate `isValid` read would leave open.
                    validity.performIfValid {
                        self?.currentArtwork = artwork.clearsArtwork ? nil : artwork
                    }
                }
            },
            validity: validity,
            advertisedCommands: advertisedCommands,
            roles: roleSet,
            // Live facade state, not playerConfig defaults: a multi-server switch
            // (and any runtime setOutputDelay) must carry into the new session.
            initialOutputDelayMs: outputDelayMs,
            initialVolume: currentVolume,
            initialMuted: currentMuted,
            requiredLeadTimeMs: playerConfig?.requiredLeadTimeMs ?? defaultRequiredLeadTimeMs,
            minBufferMs: playerConfig?.minBufferMs ?? defaultMinBufferMs,
            clock: clockSync,
            engine: audioEngine
        )

        connection = newConnection
        currentOutputFormatStatus = nil

        // Spawn a task to start the connection and drain its control events.
        // `self` is held weakly and upgraded per event: a parked drain must not
        // be a self-retain cycle (client → task → closure → client), or dropping
        // the last user reference can never reach deinit and its safety net.
        drainConnectionEventsTask = Task { [weak self] in
            await newConnection.start()
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
                applyConnectionEvent(event)
            }
        }

        // Set should-emit-raw-audio flag
        shouldEmitRawAudio = playerConfig?.emitRawAudioEvents ?? false

        currentServerId = outcomeServerId
        currentActivities = outcomeActivities
        if outcomeActivities.contains(.playback) {
            Task { await persistenceProvider?.saveLastPlayedServerId(outcomeServerId) }
        }
        updateConnectionState(.connected)
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
            }
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
        drainConnectionEventsTask?.cancel()
        drainConnectionEventsTask = nil
        sessionValidity?.invalidate()
        sessionValidity = nil
        let retiredConnection = connection
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
            await capabilityTask?.value
            await capabilityProvider.stopMonitoring()
            self?.finishClose()
        }
        closeTask = task
        await task.value
    }

    private func finishClose() {
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
        visualizerDataContinuation.finish()
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
            // Mid-dial: there is no connection to say goodbye to, but the caller's
            // intent must still land, or `connectionState` stays `.connecting` forever.
            if connectionState != .disconnected {
                applyDisconnected(reason: .explicit(reason))
            }
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
    private func applyConnectionEvent(_ event: ConnectionEvent) { // swiftlint:disable:this function_body_length
        guard !isTerminated else { return }
        switch event {
        case let .paired(serverId):
            emitEvent(.paired(serverId: serverId))

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

        case let .controllerStateUpdated(state):
            updateControllerState(state)
            emitEvent(.controllerStateUpdated(state))

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
            // requesting a supported format, so requestPlayerFormat must be allowed.
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
        // Volume/mute/outputDelay deliberately survive (device-user state,
        // like the spec's static-delay persistence): the next session is
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
    }

    /// Clear server-reported state that is scoped to a single connection. A
    /// `server/state` delta merges onto the *previous* value (absent field = keep
    /// previous), so without this a reconnected server's first partial delta would
    /// inherit the dead connection's metadata/controller. `currentServerId` and
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
