import Foundation

extension SendspinConnection {
    // MARK: - Outbound sends

    /// Park until the outbound slot is free, then take it. FIFO, no busy spin.
    private func acquireOutboundSlot() async {
        if outboundInFlight {
            await withCheckedContinuation { outboundWaiters.append($0) }
        }
        outboundInFlight = true
    }

    /// Free the slot or hand it to the queued head (inFlight stays true so a
    /// fresh sender cannot steal it between the release and the wake).
    private func releaseOutboundSlot() {
        if outboundWaiters.isEmpty {
            outboundInFlight = false
        } else {
            outboundWaiters.removeFirst().resume()
        }
    }

    /// A send failure burns nonces, so the channel is crypto-dead. Latch the
    /// failure before the async teardown: the deferred slot release then chains
    /// queued senders into the latch, which rejects them without encrypting.
    private func failOutbound() async {
        outboundFailed = true
        if !shuttingDown {
            shuttingDown = true
            if disconnectReason == nil {
                disconnectReason = .connectionLost(nil)
            }
        }
        await transport.disconnect()
    }

    func sendWrapped(
        _ message: some Codable & Sendable,
        bypassRehandshakeGate: Bool = false,
        requireRunningLifecycle: Bool = false,
        expectedPairingAttemptID: PairingAttemptID? = nil,
        allowClearedPairingAbort: Bool = false,
        controllerCommand: ControllerCommandType? = nil
    ) async throws {
        await acquireOutboundSlot()
        defer { releaseOutboundSlot() }
        try await sendWrappedInOutboundSlot(
            message,
            bypassRehandshakeGate: bypassRehandshakeGate,
            requireRunningLifecycle: requireRunningLifecycle,
            expectedPairingAttemptID: expectedPairingAttemptID,
            allowClearedPairingAbort: allowClearedPairingAbort,
            controllerCommand: controllerCommand
        )
    }

    private func sendWrappedInOutboundSlot(
        _ message: some Codable & Sendable,
        bypassRehandshakeGate: Bool = false,
        requireRunningLifecycle: Bool = false,
        expectedPairingAttemptID: PairingAttemptID? = nil,
        allowClearedPairingAbort: Bool = false,
        controllerCommand: ControllerCommandType? = nil
    ) async throws {
        guard !outboundFailed else {
            throw SendspinClientError.sendFailed("outbound channel is dead")
        }
        if let expectedPairingAttemptID {
            let currentAuthorized = pairingAttemptID == expectedPairingAttemptID
            let abortAuthorized = allowClearedPairingAbort && pairingAbortAuthorization == expectedPairingAttemptID
            guard currentAuthorized || abortAuthorized else {
                throw SendspinClientError.stalePairingAttempt(expectedPairingAttemptID)
            }
            if abortAuthorized, !currentAuthorized {
                pairingAbortAuthorization = nil
            }
        }
        // Gate checks come after acquisition: a sender parked during an exchange
        // or shutdown must not proceed under stale keys or a closing session.
        guard bypassRehandshakeGate || !rehandshakeInProgress else {
            throw SendspinClientError.handshakeIncomplete
        }
        let lifecycleAllowsSend = requireRunningLifecycle
            ? lifecycle == .running
            : lifecycle == .running || lifecycle == .shuttingDown
        guard lifecycleAllowsSend else {
            // `.shuttingDown` permits the intentional goodbye; leave opts out so
            // a queued leave cannot follow that goodbye onto a closing transport.
            throw SendspinClientError.notConnected
        }
        if Task.isCancelled {
            // The pairing timeout handler detaches its own task handle before
            // clearing, so a cancelled sender here is always abandoned work:
            // don't burn a nonce for a frame nothing will carry.
            throw CancellationError()
        }

        if let controllerCommand {
            try requireActiveRole(.controllerV1)
            guard let currentControllerState else { throw SendspinClientError.controllerStateUnavailable }
            guard currentControllerState.supportedCommands.contains(controllerCommand) else {
                throw SendspinClientError.controllerCommandUnsupported(controllerCommand)
            }
        }
        let data = try SendspinEncoding.makeEncoder().encode(message)
        var plaintext = Data([NoiseFrameType.json])
        plaintext.append(data)
        do {
            for frame in try channel.encryptMessage(plaintext) {
                try await transport.sendBinary(frame)
            }
        } catch {
            await failOutbound()
            throw error
        }
    }

    func sendPairingWrapped(
        _ first: ClientPairInitMessage,
        followedBy second: ClientPairFinalizeMessage,
        attemptID: PairingAttemptID
    ) async throws {
        // Pairing PSK init and finalize stay adjacent while other senders wait for the slot.
        await acquireOutboundSlot()
        defer { releaseOutboundSlot() }
        try await sendWrappedInOutboundSlot(first, expectedPairingAttemptID: attemptID)
        try await sendWrappedInOutboundSlot(second, expectedPairingAttemptID: attemptID)
    }

    func sendPairingWrapped(
        _ message: some Codable & Sendable,
        attemptID: PairingAttemptID,
        allowClearedAbort: Bool = false
    ) async throws {
        try await sendWrapped(
            message,
            expectedPairingAttemptID: attemptID,
            allowClearedPairingAbort: allowClearedAbort
        )
    }

    // MARK: - Facade-initiated sends

    /// Send a facade-initiated protocol message, wrapping transport errors in
    /// the public typed ``SendspinClientError/sendFailed(_:)``.
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

    func sendControllerCommand(_ command: ControllerCommand) async throws {
        guard lifecycle == .running, !rehandshakeInProgress else {
            throw SendspinClientError.handshakeIncomplete
        }
        let message = ClientCommandMessage(payload: ClientCommandPayload(controller: command))
        do {
            try await sendWrapped(message, requireRunningLifecycle: true, controllerCommand: command.command)
        } catch let error as SendspinClientError {
            throw error
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
            // Forward the rehandshake bypass: handleServerActivate publishes the
            // post-swap full state while rehandshakeInProgress is still true.
            try await sendWrapped(ClientStateMessage(payload: payload), bypassRehandshakeGate: bypassRehandshakeGate)
            publishedAvailability = payload.available
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
