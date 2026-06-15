import Foundation

// MARK: - Command Messages

/// Command sent from client to server (e.g. play, pause, skip)
struct ClientCommandMessage: SendspinMessage, Equatable {
    static let typeString = "client/command"
    let type = Self.typeString
    let payload: ClientCommandPayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ClientCommandPayload: Codable, Equatable {
    let controller: ControllerCommand?
}

struct ControllerCommand: Codable, Equatable {
    /// Command type per spec
    let command: ControllerCommandType
    /// Group volume (0-100), only when command is `.volume`
    let volume: Int?
    /// Group mute state, only when command is `.mute`
    let mute: Bool?

    init(command: ControllerCommandType, volume: Int? = nil, mute: Bool? = nil) {
        self.command = command
        self.volume = volume
        self.mute = mute
    }
}

/// Command sent from server to client (e.g. volume, mute, set_static_delay)
struct ServerCommandMessage: SendspinMessage, Equatable {
    static let typeString = "server/command"
    let type = Self.typeString
    let payload: ServerCommandPayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ServerCommandPayload: Codable, Equatable {
    let player: PlayerCommandObject?

    init(player: PlayerCommandObject? = nil) {
        self.player = player
    }
}

/// Player command object within server/command
struct PlayerCommandObject: Codable, Equatable {
    /// Command type per spec
    let command: PlayerCommand
    /// Volume value (0-100), present when command is `.volume`
    let volume: Int?
    /// Mute state, present when command is `.mute`
    let mute: Bool?
    /// Static delay in ms (0-5000), present when command is `.setStaticDelay`
    let staticDelayMs: Int?

    enum CodingKeys: String, CodingKey {
        case command
        case volume
        case mute
        case staticDelayMs = "static_delay_ms"
    }

    init(command: PlayerCommand, volume: Int? = nil, mute: Bool? = nil, staticDelayMs: Int? = nil) {
        self.command = command
        self.volume = volume
        self.mute = mute
        self.staticDelayMs = staticDelayMs
    }
}
