// ABOUTME: Outbound protocol sends and client/state snapshot assembly for SendspinConnection
// ABOUTME: Centralizes transport writes so the connection remains the single writer

import Foundation

extension SendspinConnection {
    // MARK: - Outbound sends

    func sendWrapped(_ message: some Codable & Sendable) async throws {
        try await transport.send(message)
    }

    // MARK: - Facade-initiated sends

    /// Send a facade-initiated protocol message, wrapping transport errors in
    /// the public typed ``SendspinClientError/sendFailed(_:)``.
    ///
    /// All outbound protocol I/O flows through this actor — the facade holds
    /// no send path of its own — so public API sends serialize with the
    /// handshake/time/state/goodbye sequencing this actor owns.
    func send(clientMessage message: some Codable & Sendable) async throws {
        guard handshakePhase == .complete else { throw SendspinClientError.handshakeIncomplete }
        do {
            try await transport.send(message)
        } catch {
            throw SendspinClientError.sendFailed(error.localizedDescription)
        }
    }

    func sendClientStateIfChanged() async throws {
        guard handshakePhase == .complete else { throw SendspinClientError.handshakeIncomplete }
        clientStateDirty = true
        guard !clientStateSendInFlight else { return }

        clientStateSendInFlight = true
        defer { clientStateSendInFlight = false }

        while clientStateDirty {
            clientStateDirty = false
            let current = currentClientStateSnapshot()
            guard let payload = try Self.clientStateDelta(from: lastSentClientState, to: current) else {
                lastSentClientState = current
                continue
            }

            try await transport.send(ClientStateMessage(payload: payload))
            lastSentClientState = current
        }
    }

    func currentClientStateSnapshot() -> SentClientState {
        let player = playerRoleActive
            ? SentPlayerState(
                volume: currentVolume,
                muted: currentMuted,
                staticDelayMs: currentStaticDelayMs,
                supportedCommands: advertisedCommands
                    .intersection(PlayerStateObject.validStateCommands)
                    .sorted(by: { $0.rawValue < $1.rawValue }),
                requiredLeadTimeMs: requiredLeadTimeMs,
                minBufferMs: minBufferMs
            )
            : nil
        return SentClientState(state: clientOperationalState, player: player)
    }
}
