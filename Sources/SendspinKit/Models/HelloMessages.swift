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
    let name: String
    let deviceInfo: DeviceInfo?
    let supportedPairMethods: [String: PairMethodDescriptor]
    let unpairedAccess: UnpairedAccessAdvertisement
    let supportedRoles: [VersionedRole]
    let playerV1Support: PlayerSupport?
    let visualizerV1Support: VisualizerSupport?

    enum CodingKeys: String, CodingKey {
        case name
        case deviceInfo = "device_info"
        case supportedPairMethods = "supported_pair_methods"
        case unpairedAccess = "unpaired_access"
        case supportedRoles = "supported_roles"
        case playerV1Support = "player@v1_support"
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
/// These are commands that target an individual player (volume, mute, output delay).
/// Distinct from ``ControllerCommandType`` which targets the group (play, pause, skip, etc.).
/// The `volume` and `mute` cases overlap because a player's volume/mute can be set
/// directly by the server or indirectly via group-level controller commands.
///
/// Used in `player@v1_support.supported_commands`, `client/state` player object's
/// `supported_commands`, and `server/command` player object's `command` field.
public enum PlayerCommand: String, Codable, Hashable, Sendable {
    /// Set player volume (0-100)
    case volume
    /// Set player mute state
    case mute
    /// Set output delay in milliseconds (0-5000)
    case setOutputDelay = "set_output_delay"
}

struct PlayerSupport: Codable, Equatable {
    let supportedFormats: [AudioFormatSpec]
    let bufferCapacity: Int

    enum CodingKeys: String, CodingKey {
        case supportedFormats = "supported_formats"
        case bufferCapacity = "buffer_capacity"
    }
}

// NOTE: The metadata role has no support object in the spec.
// It's activated by listing "metadata@v1" in supported_roles.

/// Visualizer role support advertised by client/hello.
struct VisualizerSupport: Codable, Equatable {
    let bufferCapacity: Int
    enum CodingKeys: String, CodingKey { case bufferCapacity = "buffer_capacity" }
}

// MARK: - Server Messages

/// Server hello response
struct ServerHelloMessage: SendspinMessage, Equatable {
    static let typeString = "server/hello"
    let type = Self.typeString
    let payload: ServerHelloPayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ServerHelloPayload: Codable, Equatable {
    let name: String
}
