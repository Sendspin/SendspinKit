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
    /// The audio format currently being streamed by the server, or nil if no stream is active.
    public private(set) var currentStreamFormat: AudioFormatSpec?
    var clientOperationalState: ClientOperationalState = .synchronized
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
    /// Current static delay in milliseconds. Initialized from `PlayerConfiguration.initialStaticDelayMs`,
    /// updated when the server sends a `set_static_delay` command.
    public private(set) var staticDelayMs: Int
    /// Observability mirrors of the connection's protocol-intent gates. These do
    /// NOT gate anything: the authoritative gates live in `SendspinConnection`,
    /// where `stream/request-format` sends are validated. The mirrors are
    /// render-applied (player: from the engine's `.started` report; artwork:
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
    /// Codec header for the current stream (e.g. FLAC streaminfo), if any.
    /// Set when `stream/start` carries a `codec_header` field; cleared on `stream/end`.
    public private(set) var currentCodecHeader: Data?

    // Multi-server state
    var currentConnectionReason: ConnectionReason?
    var currentServerId: String?

    /// Dependencies.
    /// Note: the facade deliberately holds NO transport reference. The connection
    /// is the transport's sole owner and single writer; all outbound protocol I/O
    /// goes through `SendspinConnection` methods. (The only facade-level send is
    /// `performHandshake`, which writes to a candidate transport during
    /// multi-server arbitration, before a connection exists for it.)
    /// The active connection, or nil if disconnected.
    /// When a new connection replaces the old one, the old is shutdown.
    var connection: SendspinConnection?

    /// Validity token gating the current session's binary events. Stored here so
    /// `retireSession()` can invalidate it synchronously — before old-connection
    /// teardown is awaited — per the design's retire contract (both guards must
    /// reject a dying connection's late events *during* teardown, not after).
    private(set) var sessionValidity: SessionValidityToken?

    /// Task draining control events from the connection and re-emitting them to the public events stream.
    var drainConnectionEventsTask: Task<Void, Never>?

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

    public init(
        clientId: String,
        name: String,
        roles: some Sequence<VersionedRole>,
        deviceInfo: DeviceInfo? = .current,
        playerConfig: PlayerConfiguration? = nil,
        artworkConfig: ArtworkConfiguration? = nil,
        persistenceProvider: (any SendspinPersistenceProvider)? = nil
    ) throws(ConfigurationError) {
        let orderedRoles = Self.deduplicatingRoles(roles)
        let roleSet = Set(orderedRoles)

        if roleSet.contains(.playerV1), playerConfig == nil {
            throw .playerRoleRequiresConfiguration
        }
        if roleSet.contains(.artworkV1), artworkConfig == nil {
            throw .artworkRoleRequiresConfiguration
        }

        self.clientId = clientId
        self.name = name
        self.roles = orderedRoles
        self.roleSet = roleSet
        self.deviceInfo = deviceInfo
        self.playerConfig = playerConfig
        self.artworkConfig = artworkConfig
        self.persistenceProvider = persistenceProvider
        staticDelayMs = playerConfig?.initialStaticDelayMs ?? 0

        // Resolve volume mode into concrete capabilities (the control is built by AudioEngine)
        volumeCapabilities = VolumeControlFactory.resolve(mode: playerConfig?.volumeMode ?? .software).capabilities

        (audioChunks, audioChunksContinuation) = AsyncStream.makeStream()
        (artwork, artworkContinuation) = AsyncStream.makeStream()
        (visualizerData, visualizerDataContinuation) = AsyncStream.makeStream()
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
        guard connectionState == .disconnected else {
            throw SendspinClientError.alreadyConnected
        }

        connectionState = .connecting

        let transport = NWWebSocketTransport(url: url)
        do {
            try await transport.connect()
        } catch {
            await transport.disconnect()
            if connectionState == .connecting {
                updateConnectionState(.disconnected)
            }
            throw error
        }

        await setupConnection(with: transport)
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
            await setupConnection(with: transport)
        } else {
            // Already connected — run handshake on new connection, then decide
            try await handleCompetingConnection(transport)
        }
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
    func setupConnection(
        with transport: any SendspinTransport,
        preReadHello: ServerHelloMessage? = nil
    ) async {
        // A new connection is a new session: drop any server-reported state carried
        // over from a prior connection (notably one lost without an explicit
        // disconnect) before the first server/state can merge a delta onto it.
        // Placed here, not in handleServerHello — that also fires on a same-connection
        // re-hello, where the accumulated state is still valid.
        resetServerSessionState()
        isClockSynced = false

        // Retire the old session synchronously (token + identity guards both
        // reject its late events from this point), then await its teardown.
        let oldConnection = retireSession()
        if let oldConnection {
            await oldConnection.shutdown()
        }

        // Build the SendspinConnection with configuration from this facade
        let validity = SessionValidityToken()
        sessionValidity = validity
        let clockSync = ClockSynchronizer()

        // Create AudioEngine for player role, or a no-op engine for non-player roles
        let audioEngine: AudioEngine
        if roleSet.contains(.playerV1), let playerConfig {
            audioEngine = AudioEngine(clock: clockSync, config: playerConfig)
        } else {
            // Non-player roles still need an engine (owns the audio streams and scheduler)
            // Create with a no-op audio output
            let noOpOutput = NoOpAudioOutput()
            let audioScheduler = AudioScheduler(clockSync: clockSync)
            audioEngine = AudioEngine(output: noOpOutput, scheduler: audioScheduler, clock: clockSync)
        }

        // A player always advertises set_static_delay; volume/mute depend on
        // the resolved VolumeMode capabilities. Non-player roles advertise nothing.
        let advertisedCommands: Set<PlayerCommand> = roleSet.contains(.playerV1)
            ? Set(volumeCapabilities.playerCommands).union([.setStaticDelay])
            : []

        let newConnection = SendspinConnection(
            transport: transport,
            parsedHello: preReadHello,
            clientHelloPayload: buildClientHelloPayload(),
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
            // (and any runtime setStaticDelay) must carry into the new session.
            initialStaticDelayMs: staticDelayMs,
            initialVolume: currentVolume,
            initialMuted: currentMuted,
            requiredLeadTimeMs: playerConfig?.requiredLeadTimeMs ?? defaultRequiredLeadTimeMs,
            minBufferMs: playerConfig?.minBufferMs ?? defaultMinBufferMs,
            clock: clockSync,
            engine: audioEngine
        )

        connection = newConnection

        // Spawn a task to start the connection and drain its control events.
        // `self` is held weakly and upgraded per event: a parked drain must not
        // be a self-retain cycle (client → task → closure → client), or dropping
        // the last user reference can never reach deinit and its safety net.
        drainConnectionEventsTask = Task { [weak self] in
            await newConnection.start()
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

        // Promotion path: the `server/hello` was already consumed during competing-
        // connection arbitration, so apply the connected-state projection synchronously
        // here. Otherwise the caller would observe `.connecting` until the connection's
        // async drain delivers `.serverConnected`. The connection still emits the public
        // `.serverConnected` event via its message loop (single public emission).
        if let preReadHello {
            currentServerId = preReadHello.payload.serverId
            currentConnectionReason = preReadHello.payload.connectionReason
            updateConnectionState(.connected)
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
        guard let conn = connection else { return }
        await conn.disconnect(reason: reason)
        if connection === conn {
            applyDisconnected(reason: .explicit(reason))
        }
    }

    /// Apply one control event to facade state, then re-emit the render-applied
    /// event to the public stream. Called per event by the drain
    /// task, which holds `self` only for the duration of the call.
    @MainActor
    private func applyConnectionEvent(_ event: ConnectionEvent) {
        switch event {
        case let .serverConnected(info):
            currentServerId = info.serverId
            currentConnectionReason = info.connectionReason
            updateConnectionState(.connected)
            emitEvent(.serverConnected(info))

        case let .metadataReceived(metadata):
            updateMetadata(metadata)
            emitEvent(.metadataReceived(metadata))

        case let .controllerStateUpdated(state):
            updateControllerState(state)
            emitEvent(.controllerStateUpdated(state))

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

        case let .staticDelayChanged(milliseconds):
            staticDelayMs = milliseconds
            emitEvent(.staticDelayChanged(milliseconds: milliseconds))

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
                // streamError is internal; don't emit to public stream

        case let .playerVolumeChanged(volume):
            currentVolume = volume
                // Volume changes are internal state; don't emit (servers send via server/command, we apply locally)

        case let .playerMutedChanged(muted):
            currentMuted = muted
                // Mute changes are internal state; don't emit

        case let .lastPlayedServerChanged(serverId):
            // Persist the spec's "last played server" bookkeeping (used by the
            // multi-server arbitration tiebreak).
            if let persistenceProvider {
                Task { await persistenceProvider.saveLastPlayedServerId(serverId) }
            }
            emitEvent(.lastPlayedServerChanged(serverId: serverId))

        case let .disconnected(reason):
            applyDisconnected(reason: reason)
        }
    }

    /// Apply terminal disconnection state exactly once from either the drain task
    /// or the awaited public `disconnect()` postcondition path.
    private func applyDisconnected(reason: DisconnectReason) {
        guard connection != nil || connectionState != .disconnected else { return }
        // Terminal event: retire the connection and apply reconnect logic.
        // Volume/mute/staticDelay deliberately survive (device-user state,
        // like the spec's static-delay persistence): the next session is
        // seeded from facade state and re-applies them to its fresh engine.
        updateConnectionState(.disconnected)
        resetStreamState()
        currentServerId = nil
        currentConnectionReason = nil
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
    /// would. (Requests themselves fail with `streamNotActive` via the
    /// `connection == nil` guard — these mirrors are observability state.)
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
    /// `currentConnectionReason` are excluded — ``handleServerHello(_:)`` overwrites
    /// them on every hello — and `currentGroup` is excluded because the spec keeps
    /// group membership across reconnections.
    func resetServerSessionState() {
        updateMetadata(nil)
        updateControllerState(nil)
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
        guard roleSet.contains(.playerV1) else { throw SendspinClientError.roleNotActive(.playerV1) }
        guard let conn = connection else { throw SendspinClientError.notConnected }
        try await conn.requireActiveRole(.playerV1)

        guard muted != currentMuted else { return }
        currentMuted = muted

        // Forward to the connection (the client/state and engine authority) best-effort;
        // a failed send does not revert the optimistic local state.
        try? await conn.setMuted(muted)
    }

    /// Set static delay in milliseconds (0-5000).
    ///
    /// Per spec: compensates for delay beyond the audio port (external speakers,
    /// amplifiers). Emits `.staticDelayChanged` so the host app can persist the
    /// new value. The server is notified best-effort — a failed `client/state`
    /// send does not prevent the local delay change from taking effect.
    ///
    /// - Throws: ``SendspinClientError/notConnected`` if disconnected, or
    ///   ``SendspinClientError/roleNotActive(_:)`` if not configured as a player.
    @MainActor
    public func setStaticDelay(_ delayMs: Int) async throws {
        guard roleSet.contains(.playerV1) else { throw SendspinClientError.roleNotActive(.playerV1) }
        guard let conn = connection else { throw SendspinClientError.notConnected }
        try await conn.requireActiveRole(.playerV1)
        let clamped = max(0, min(maxStaticDelayMs, delayMs))
        guard clamped != staticDelayMs else { return }
        staticDelayMs = clamped

        // Forward to the connection (the client/state and engine authority) best-effort;
        // a failed send does not revert the optimistic local state.
        try? await conn.setStaticDelay(clamped)
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
        guard let conn = connection else { throw SendspinClientError.notConnected }
        // Apply optimistically for the synchronous observable, then forward to the
        // connection (the single writer of client/state). Roll back on send failure.
        let previous = clientOperationalState
        clientOperationalState = newState
        do {
            try await conn.setOperationalState(newState)
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
