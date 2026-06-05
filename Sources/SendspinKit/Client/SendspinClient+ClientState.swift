// ABOUTME: client/state reporting for SendspinClient, including delta computation
// ABOUTME: Tracks the last-sent state and emits only changed fields per spec

import Foundation

// MARK: - client/state snapshots

extension SendspinClient {
    /// Immutable snapshot of the client state reported to the server, used to
    /// compute deltas. `player` is `nil` when the player role is inactive.
    struct SentClientState: Equatable {
        var state: ClientOperationalState
        var player: SentPlayerState?
    }

    /// Player-role portion of a ``SentClientState`` snapshot. Every field is
    /// always present here; which fields actually go on the wire is decided by
    /// the delta computation in ``clientStateDelta(from:to:)``.
    struct SentPlayerState: Equatable {
        var volume: Int
        var muted: Bool
        var staticDelayMs: Int
        var supportedCommands: [PlayerCommand]
    }
}

// MARK: - Sending client/state

extension SendspinClient {
    /// Player commands whose availability can change at runtime. Per spec this
    /// is currently only `set_static_delay`.
    private static let playerSupportedCommands: [PlayerCommand] = [.setStaticDelay]

    /// Send the current client state to the server.
    ///
    /// The first send after `server/hello` is the full payload; subsequent
    /// sends include only fields that changed since the last successful send,
    /// which the server merges into its existing state. A send that would carry
    /// no changes is suppressed. The last-sent snapshot is updated only after a
    /// successful transport send, so a failed send (e.g. the rollback path in
    /// ``transitionOperationalState(to:)``) leaves delta tracking consistent.
    func sendClientState() async throws {
        guard let transport else {
            throw SendspinClientError.notConnected
        }

        let current = currentClientStateSnapshot()
        guard let payload = try Self.clientStateDelta(from: lastSentClientState, to: current) else {
            return
        }

        try await transport.send(ClientStateMessage(payload: payload))
        lastSentClientState = current
    }

    private func currentClientStateSnapshot() -> SentClientState {
        let player = roles.contains(.playerV1)
            ? SentPlayerState(
                volume: currentVolume,
                muted: currentMuted,
                staticDelayMs: staticDelayMs,
                supportedCommands: Self.playerSupportedCommands
            )
            : nil
        return SentClientState(state: clientOperationalState, player: player)
    }

    /// Build the `client/state` payload to send, or `nil` if nothing changed.
    ///
    /// A `nil` `previous` represents "server has no prior state", so every field
    /// differs and the result is the full initial payload. Otherwise only changed
    /// fields are included. The non-optional snapshot values are compared against
    /// optional previous values, so a `nil` previous naturally reads as "changed".
    private static func clientStateDelta(
        from previous: SentClientState?,
        to current: SentClientState
    ) throws -> ClientStatePayload? {
        let previousPlayer = previous?.player
        let state = current.state != previous?.state ? current.state : nil

        var player: PlayerStateObject?
        if let p = current.player {
            let volume = p.volume != previousPlayer?.volume ? p.volume : nil
            let muted = p.muted != previousPlayer?.muted ? p.muted : nil
            let delay = p.staticDelayMs != previousPlayer?.staticDelayMs ? p.staticDelayMs : nil
            let commands = p.supportedCommands != previousPlayer?.supportedCommands ? p.supportedCommands : nil
            if volume != nil || muted != nil || delay != nil || commands != nil {
                // Values are pre-clamped on set, so validation never throws here.
                player = try PlayerStateObject(volume: volume, muted: muted, staticDelayMs: delay, supportedCommands: commands)
            }
        }

        guard state != nil || player != nil else { return nil }
        return ClientStatePayload(state: state, player: player)
    }
}
