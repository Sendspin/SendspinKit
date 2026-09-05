import Foundation

extension SendspinConnection {
    // MARK: - Outbound sends

    func sendWrapped(_ message: some Codable & Sendable, bypassRehandshakeGate: Bool = false) async throws {
        // Check the gate before encryption; a post-encryption re-check would consume a nonce before throwing.
        guard bypassRehandshakeGate || !rehandshakeInProgress else {
            throw SendspinClientError.handshakeIncomplete
        }
        let data = try SendspinEncoding.makeEncoder().encode(message)
        var plaintext = Data([NoiseFrameType.json])
        plaintext.append(data)
        do {
            for frame in try channel.encryptMessage(plaintext) {
                try await transport.sendBinary(frame)
            }
        } catch {
            // A failed send is terminal: encryption already consumed AEAD nonces,
            // so the peer can never decrypt a later frame — the session is
            // cryptographically dead, not merely degraded. Tear down (unless a
            // teardown is already driving this send) and surface the error.
            if !shuttingDown {
                shuttingDown = true
                if disconnectReason == nil {
                    disconnectReason = .connectionLost(nil)
                }
                await transport.disconnect()
            }
            throw error
        }
    }

    // MARK: - Facade-initiated sends

    /// Send a facade-initiated protocol message, wrapping transport errors in
    /// the public typed ``SendspinClientError/sendFailed(_:)``.
    ///
    /// All outbound protocol I/O flows through this actor — the facade holds
    /// no send path of its own — so public API sends serialize with the
    /// handshake/time/state/goodbye sequencing this actor owns.
    func send(clientMessage message: some Codable & Sendable) async throws {
        guard lifecycle == .running, !rehandshakeInProgress else {
            throw SendspinClientError.handshakeIncomplete
        }
        do {
            try await sendWrapped(message)
        } catch {
            throw SendspinClientError.sendFailed(error.localizedDescription)
        }
    }

    func publishClientState(bypassRehandshakeGate: Bool = false) async throws {
        guard lifecycle == .running, bypassRehandshakeGate || !rehandshakeInProgress else {
            throw SendspinClientError.handshakeIncomplete
        }
        clientStateDirty = true
        while clientStateSendInFlight {
            try await Task.sleep(for: .milliseconds(1))
        }
        clientStateSendInFlight = true
        defer { clientStateSendInFlight = false }
        while clientStateDirty {
            clientStateDirty = false
            let payload = currentClientStatePayload()
            try await sendWrapped(ClientStateMessage(payload: payload))
            if payload.player != nil {
                playerStateSent = true
            }
            if payload.visualizer != nil {
                visualizerStateSent = true
            }
            if payload.artwork != nil {
                artworkStateSent = true
            }
        }
    }

    func currentClientStatePayload() -> ClientStatePayload {
        let commands = advertisedCommands
            .intersection(PlayerStateObject.validStateCommands)
            .sorted { $0.rawValue < $1.rawValue }
        var player: PlayerStateObject?
        if activeRoles.contains(.playerV1) {
            do {
                player = try PlayerStateObject(
                    volume: currentVolume,
                    muted: currentMuted,
                    outputDelayMs: currentOutputDelayMs,
                    supportedCommands: commands,
                    requiredLeadTimeMs: requiredLeadTimeMs,
                    minBufferMs: max(minBufferMs, derivedMinBufferMs),
                    format: preferredPlayerFormat
                )
            } catch {
                preconditionFailure("Validated player state cannot be published: \(error)")
            }
        }
        var artwork: ArtworkStateObject?
        if activeRoles.contains(.artworkV1) {
            guard let artworkState else {
                preconditionFailure("An active artwork role must have configured state")
            }
            artwork = artworkState
        }
        var visualizer: VisualizerStateObject?
        if activeRoles.contains(.visualizerV1) {
            guard let visualizerState else {
                preconditionFailure("An active visualizer role must have configured state")
            }
            visualizer = visualizerState
        }
        return ClientStatePayload(
            available: isClockSynced && clientOperationalState != .externalSource,
            player: player,
            artwork: artwork,
            visualizer: visualizer
        )
    }
}
