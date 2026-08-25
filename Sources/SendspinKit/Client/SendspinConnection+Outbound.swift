import Foundation

extension SendspinConnection {
    // MARK: - Outbound sends

    func sendWrapped(_ message: some Codable & Sendable) async throws {
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
        guard lifecycle == .running else { throw SendspinClientError.handshakeIncomplete }
        do {
            try await sendWrapped(message)
        } catch {
            throw SendspinClientError.sendFailed(error.localizedDescription)
        }
    }

    func sendClientStateIfChanged() async throws {
        guard lifecycle == .running else { throw SendspinClientError.handshakeIncomplete }
        clientStateDirty = true
        // A caller that arrives while another state send is in flight must wait
        // for that cycle to finish; returning here would report success without
        // sending the caller's changed state.
        while clientStateSendInFlight {
            try await Task.sleep(for: .milliseconds(1))
        }

        clientStateSendInFlight = true
        defer { clientStateSendInFlight = false }

        while clientStateDirty {
            clientStateDirty = false
            let current = currentClientStateSnapshot()
            guard let payload = try Self.clientStateDelta(from: lastSentClientState, to: current) else {
                lastSentClientState = current
                continue
            }

            try await sendWrapped(ClientStateMessage(payload: payload))
            lastSentClientState = current
        }
    }

    func currentClientStateSnapshot() -> SentClientState {
        let player = playerRoleActive
            ? SentPlayerState(
                volume: currentVolume,
                muted: currentMuted,
                outputDelayMs: currentOutputDelayMs,
                supportedCommands: advertisedCommands
                    .intersection(PlayerStateObject.validStateCommands)
                    .sorted(by: { $0.rawValue < $1.rawValue }),
                requiredLeadTimeMs: requiredLeadTimeMs,
                minBufferMs: minBufferMs
            )
            : nil
        return SentClientState(
            state: clientOperationalState,
            available: isClockSynced && clientOperationalState != .externalSource,
            player: player
        )
    }
}
