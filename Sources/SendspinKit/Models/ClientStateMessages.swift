// ABOUTME: Defines client-originated Sendspin state message payloads
// ABOUTME: Validates player state ranges before encoding client/state

import Foundation

// MARK: - State Messages

/// Client operational state per Sendspin protocol spec.
/// This is a top-level field in client/state, independent of any role.
public enum ClientOperationalState: String, Codable, Equatable, Sendable {
    /// Client is operational and synchronized with server timestamps
    case synchronized
    /// Client has a problem preventing normal operation
    case error
    /// Client output is in use by an external system
    case externalSource = "external_source"
}

/// Client state message (sent by clients to report current state)
struct ClientStateMessage: SendspinMessage, Equatable {
    static let typeString = "client/state"
    let type = Self.typeString
    let payload: ClientStatePayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

/// Client state payload containing client-level state and role-specific state objects.
/// Per spec: must be sent after server/hello and whenever any state changes.
struct ClientStatePayload: Codable, Equatable {
    /// Client operational state (required on initial send, optional on deltas)
    let state: ClientOperationalState?
    /// Player role state (only if client has player role)
    let player: PlayerStateObject?

    init(state: ClientOperationalState? = nil, player: PlayerStateObject? = nil) {
        self.state = state
        self.player = player
    }
}

/// Player state object within client/state message.
///
/// Every field is optional so this type can express both the initial full
/// state and subsequent deltas. Per spec, the initial `client/state` after
/// `server/hello` includes `static_delay_ms`, `required_lead_time_ms`, and
/// `min_buffer_ms`; later delta updates omit any field that has not changed
/// (the server merges them into existing state).
struct PlayerStateObject: Codable, Equatable {
    /// Volume level (0-100), only if 'volume' is in supported_commands from player@v1_support
    let volume: Int?
    /// Mute state, only if 'mute' is in supported_commands from player@v1_support
    let muted: Bool?
    /// Static delay in milliseconds (0-5000). Present in the initial full state;
    /// omitted from a delta when unchanged. Compensates for delay beyond the
    /// audio port (external speakers, amplifiers).
    let staticDelayMs: Int?
    /// Supported commands that can change at runtime (e.g. when audio output changes).
    /// Per spec, currently only `set_static_delay` is valid here.
    let supportedCommands: [PlayerCommand]?
    /// Required lead time in milliseconds (spec §485). Present in the initial full state;
    /// omitted from a delta when unchanged. Accounts for AudioQueue setup and codec warmup.
    let requiredLeadTimeMs: Int?
    /// Minimum buffer size in milliseconds (spec §486). Present in the initial full state;
    /// omitted from a delta when unchanged. Accounts for scheduler jitter and prebuffering.
    let minBufferMs: Int?

    enum CodingKeys: String, CodingKey {
        case volume
        case muted
        case staticDelayMs = "static_delay_ms"
        case supportedCommands = "supported_commands"
        case requiredLeadTimeMs = "required_lead_time_ms"
        case minBufferMs = "min_buffer_ms"
    }

    /// Commands valid in the `client/state` player object. Per spec §489 this is a
    /// subset of `{set_static_delay}` only — volume/mute are advertised solely in
    /// `client/hello` (`player@v1_support`), never at the state level. Canonical home
    /// for the invariant; the connection's state builder reads from here.
    static let validStateCommands: Set<PlayerCommand> = [.setStaticDelay]

    /// Validates volume/static-delay ranges and the supported_commands subset when present.
    private static func validate(
        volume: Int?,
        staticDelayMs: Int?,
        supportedCommands: [PlayerCommand]?
    ) throws(ConfigurationError) {
        if let vol = volume {
            guard vol >= 0, vol <= 100 else { throw .volumeOutOfRange(vol) }
        }
        if let delay = staticDelayMs {
            guard delay >= 0, delay <= 5_000 else { throw .staticDelayOutOfRange(delay) }
        }
        if let supportedCommands {
            let invalid = Set(supportedCommands).subtracting(validStateCommands)
            guard invalid.isEmpty else {
                throw .invalidStateCommands(invalid.map(\.rawValue).sorted())
            }
        }
    }

    init(
        volume: Int? = nil,
        muted: Bool? = nil,
        staticDelayMs: Int? = nil,
        supportedCommands: [PlayerCommand]? = nil,
        requiredLeadTimeMs: Int? = nil,
        minBufferMs: Int? = nil
    ) throws(ConfigurationError) {
        try Self.validate(volume: volume, staticDelayMs: staticDelayMs, supportedCommands: supportedCommands)
        self.volume = volume
        self.muted = muted
        self.staticDelayMs = staticDelayMs
        self.supportedCommands = supportedCommands
        self.requiredLeadTimeMs = requiredLeadTimeMs
        self.minBufferMs = minBufferMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let volume = try container.decodeIfPresent(Int.self, forKey: .volume)
        let muted = try container.decodeIfPresent(Bool.self, forKey: .muted)
        let staticDelayMs = try container.decodeIfPresent(Int.self, forKey: .staticDelayMs)
        let supportedCommands = try container.decodeIfPresent([PlayerCommand].self, forKey: .supportedCommands)
        let requiredLeadTimeMs = try container.decodeIfPresent(Int.self, forKey: .requiredLeadTimeMs)
        let minBufferMs = try container.decodeIfPresent(Int.self, forKey: .minBufferMs)

        do {
            try Self.validate(volume: volume, staticDelayMs: staticDelayMs, supportedCommands: supportedCommands)
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: error.errorDescription ?? "\(error)"
                )
            )
        }

        self.volume = volume
        self.muted = muted
        self.staticDelayMs = staticDelayMs
        self.supportedCommands = supportedCommands
        self.requiredLeadTimeMs = requiredLeadTimeMs
        self.minBufferMs = minBufferMs
    }
}
