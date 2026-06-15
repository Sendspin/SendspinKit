import Foundation
#if canImport(UIKit)
    import UIKit
#endif

// MARK: - Client Messages

/// Client hello message sent after WebSocket connection
struct ClientHelloMessage: SendspinMessage, Equatable {
    static let typeString = "client/hello"
    let type = Self.typeString
    let payload: ClientHelloPayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ClientHelloPayload: Codable, Equatable {
    let clientId: String
    let name: String
    let deviceInfo: DeviceInfo?
    let version: Int
    let supportedRoles: [VersionedRole]
    let playerV1Support: PlayerSupport?
    let artworkV1Support: ArtworkSupport?
    let visualizerV1Support: VisualizerSupport?

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case name
        case deviceInfo = "device_info"
        case version
        case supportedRoles = "supported_roles"
        case playerV1Support = "player@v1_support"
        case artworkV1Support = "artwork@v1_support"
        case visualizerV1Support = "visualizer@v1_support"
    }
}

public struct DeviceInfo: Codable, Equatable, Sendable {
    public let productName: String?
    public let manufacturer: String?
    public let softwareVersion: String?
    public let macAddress: String?

    enum CodingKeys: String, CodingKey {
        case productName = "product_name"
        case manufacturer
        case softwareVersion = "software_version"
        case macAddress = "mac_address"
    }

    public init(
        productName: String? = nil,
        manufacturer: String? = nil,
        softwareVersion: String? = nil,
        macAddress: String? = nil
    ) {
        self.productName = productName
        self.manufacturer = manufacturer
        self.softwareVersion = softwareVersion
        self.macAddress = macAddress
    }

    public static var current: DeviceInfo {
        #if os(iOS) || os(tvOS)
            return DeviceInfo(
                productName: UIDevice.current.model,
                manufacturer: "Apple",
                softwareVersion: UIDevice.current.systemVersion
            )
        #elseif os(macOS)
            return DeviceInfo(
                productName: "Mac",
                manufacturer: "Apple",
                softwareVersion: ProcessInfo.processInfo.operatingSystemVersionString
            )
        #else
            return DeviceInfo(productName: nil, manufacturer: "Apple", softwareVersion: nil)
        #endif
    }
}

/// Player command identifiers per spec.
///
/// These are commands that target an individual player (volume, mute, static delay).
/// Distinct from ``ControllerCommandType`` which targets the group (play, pause, skip, etc.).
/// The `volume` and `mute` cases overlap because a player's volume/mute can be set
/// directly by the server or indirectly via group-level controller commands.
///
/// Used in `player@v1_support.supported_commands`, `client/state` player object's
/// `supported_commands`, and `server/command` player object's `command` field.
enum PlayerCommand: String, Codable, Hashable {
    /// Set player volume (0-100)
    case volume
    /// Set player mute state
    case mute
    /// Set static delay in milliseconds (0-5000)
    case setStaticDelay = "set_static_delay"
}

struct PlayerSupport: Codable, Equatable {
    let supportedFormats: [AudioFormatSpec]
    let bufferCapacity: Int
    let supportedCommands: [PlayerCommand]

    enum CodingKeys: String, CodingKey {
        case supportedFormats = "supported_formats"
        case bufferCapacity = "buffer_capacity"
        case supportedCommands = "supported_commands"
    }
}

// NOTE: The metadata role has no support object in the spec.
// It's activated by listing "metadata@v1" in supported_roles.

/// Artwork@v1 support object in client/hello per spec.
/// Declares artwork channels the client can display.
struct ArtworkSupport: Codable, Equatable {
    /// Supported artwork channels (1-4), array index is the channel number
    let channels: [ArtworkChannel]
}

struct VisualizerSupport: Codable, Equatable {
    // IMPLEMENTATION_NOTE: Implement when visualizer role is added

    init() {}

    // Explicit Codable implementation for empty struct
    init(from _: Decoder) throws {}
    func encode(to _: Encoder) throws {}
}

// MARK: - Server Messages

/// Server hello response
struct ServerHelloMessage: SendspinMessage, Equatable {
    static let typeString = "server/hello"
    let type = Self.typeString
    let payload: ServerHelloPayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

/// Connection reason for server/hello
public enum ConnectionReason: String, Codable, Sendable, Hashable {
    /// Server connected for general availability/discovery
    case discovery
    /// Server connected for active playback
    case playback
}

struct ServerHelloPayload: Codable, Equatable {
    let serverId: String
    let name: String
    let version: Int
    let activeRoles: [VersionedRole]
    let connectionReason: ConnectionReason

    enum CodingKeys: String, CodingKey {
        case serverId = "server_id"
        case name
        case version
        case activeRoles = "active_roles"
        case connectionReason = "connection_reason"
    }

    init(
        serverId: String,
        name: String,
        version: Int,
        activeRoles: [VersionedRole],
        connectionReason: ConnectionReason
    ) {
        self.serverId = serverId
        self.name = name
        self.version = version
        self.activeRoles = activeRoles
        self.connectionReason = connectionReason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverId = try container.decode(String.self, forKey: .serverId)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(Int.self, forKey: .version)
        activeRoles = try container.decode([VersionedRole].self, forKey: .activeRoles)
        connectionReason = try container.decodeIfPresent(ConnectionReason.self, forKey: .connectionReason) ?? .playback
    }
}
