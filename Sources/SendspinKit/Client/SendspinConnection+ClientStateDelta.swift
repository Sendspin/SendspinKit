import Foundation

extension SendspinConnection {
    /// Last-sent / current `client/state` snapshot (kept separate from the wire
    /// types so delta comparison is field-by-field and exhaustive).
    struct SentClientState: Equatable {
        var state: EngineSyncState
        var available: Bool
        var player: SentPlayerState?
    }

    struct SentPlayerState: Equatable {
        var volume: Int
        var muted: Bool
        var outputDelayMs: Int
        var supportedCommands: [PlayerCommand]
        var requiredLeadTimeMs: Int
        var minBufferMs: Int
    }

    /// Build the `client/state` payload to send, or `nil` if nothing changed.
    static func clientStateDelta(
        from previous: SentClientState?,
        to current: SentClientState
    ) throws -> ClientStatePayload? {
        let previousPlayer = previous?.player
        let currentAvailable = current.available
        let available = previous == nil || currentAvailable != previous?.available ? currentAvailable : nil

        var player: PlayerStateObject?
        if let p = current.player {
            let volume = p.volume != previousPlayer?.volume ? p.volume : nil
            let muted = p.muted != previousPlayer?.muted ? p.muted : nil
            let delay = p.outputDelayMs != previousPlayer?.outputDelayMs ? p.outputDelayMs : nil
            let commands = p.supportedCommands != previousPlayer?.supportedCommands ? p.supportedCommands : nil
            let leadTime = p.requiredLeadTimeMs != previousPlayer?.requiredLeadTimeMs ? p.requiredLeadTimeMs : nil
            let buffer = p.minBufferMs != previousPlayer?.minBufferMs ? p.minBufferMs : nil
            if volume != nil || muted != nil || delay != nil || commands != nil || leadTime != nil || buffer != nil {
                player = try PlayerStateObject(
                    volume: volume,
                    muted: muted,
                    outputDelayMs: delay,
                    supportedCommands: commands,
                    requiredLeadTimeMs: leadTime,
                    minBufferMs: buffer
                )
            }
        }

        guard available != nil || player != nil else { return nil }
        return ClientStatePayload(available: available, player: player)
    }
}
