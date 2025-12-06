// ABOUTME: Core protocol message types for Sendspin client-server communication
// ABOUTME: All messages follow the pattern: { "type": "...", "payload": {...} }

import Foundation
#if canImport(UIKit)
    import UIKit
#endif

/// Base protocol for all Sendspin messages
public protocol SendspinMessage: Codable, Sendable {
    var type: String { get }
}

// MARK: - Client Messages

/// Client hello message sent after WebSocket connection
public struct ClientHelloMessage: SendspinMessage {
    public let type = "client/hello"
    public let payload: ClientHelloPayload

    public init(payload: ClientHelloPayload) {
        self.payload = payload
    }
}

public struct ClientHelloPayload: Codable, Sendable {
    public let clientId: String
    public let name: String
    public let deviceInfo: DeviceInfo?
    public let version: Int
    public let supportedRoles: [ClientRole]
    public let playerSupport: PlayerSupport?
    public let metadataSupport: MetadataSupport?
    public let artworkSupport: ArtworkSupport?
    public let visualizerSupport: VisualizerSupport?

    public init(
        clientId: String,
        name: String,
        deviceInfo: DeviceInfo?,
        version: Int,
        supportedRoles: [ClientRole],
        playerSupport: PlayerSupport?,
        metadataSupport: MetadataSupport?,
        artworkSupport: ArtworkSupport?,
        visualizerSupport: VisualizerSupport?
    ) {
        self.clientId = clientId
        self.name = name
        self.deviceInfo = deviceInfo
        self.version = version
        self.supportedRoles = supportedRoles
        self.playerSupport = playerSupport
        self.metadataSupport = metadataSupport
        self.artworkSupport = artworkSupport
        self.visualizerSupport = visualizerSupport
    }
}

public struct DeviceInfo: Codable, Sendable {
    public let productName: String?
    public let manufacturer: String?
    public let softwareVersion: String?

    public init(productName: String?, manufacturer: String?, softwareVersion: String?) {
        self.productName = productName
        self.manufacturer = manufacturer
        self.softwareVersion = softwareVersion
    }

    public static var current: DeviceInfo {
        #if os(iOS)
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

public enum PlayerCommand: String, Codable, Sendable {
    case volume
    case mute
}

public struct PlayerSupport: Codable, Sendable {
    public let supportFormats: [AudioFormatSpec]
    public let supportCodecs: [String]
    public let supportChannels: [Int]
    public let supportSampleRates: [Int]
    public let supportBitDepth: [Int]
    public let bufferCapacity: Int
    public let supportedCommands: [PlayerCommand]

    public init(supportFormats: [AudioFormatSpec], bufferCapacity: Int, supportedCommands: [PlayerCommand]) {
        self.supportFormats = supportFormats
        // Extract unique values from formats for Music Assistant compatibility
        supportCodecs = Array(Set(supportFormats.map { $0.codec.rawValue })).sorted()
        supportChannels = Array(Set(supportFormats.map { $0.channels })).sorted()
        supportSampleRates = Array(Set(supportFormats.map { $0.sampleRate })).sorted()
        supportBitDepth = Array(Set(supportFormats.map { $0.bitDepth })).sorted()
        self.bufferCapacity = bufferCapacity
        self.supportedCommands = supportedCommands
    }
}

public struct MetadataSupport: Codable, Sendable {
    public let supportPictureFormats: [String]

    public init(supportPictureFormats: [String] = []) {
        self.supportPictureFormats = supportPictureFormats
    }
}

public struct ArtworkSupport: Codable, Sendable {
    // IMPLEMENTATION_NOTE: Implement when artwork role is added

    public init() {}

    // Explicit Codable implementation for empty struct
    public init(from _: Decoder) throws {}
    public func encode(to _: Encoder) throws {}
}

public struct VisualizerSupport: Codable, Sendable {
    // IMPLEMENTATION_NOTE: Implement when visualizer role is added

    public init() {}

    // Explicit Codable implementation for empty struct
    public init(from _: Decoder) throws {}
    public func encode(to _: Encoder) throws {}
}

// MARK: - Server Messages

/// Server hello response
public struct ServerHelloMessage: SendspinMessage {
    public let type = "server/hello"
    public let payload: ServerHelloPayload

    public init(payload: ServerHelloPayload) {
        self.payload = payload
    }
}

public struct ServerHelloPayload: Codable, Sendable {
    public let serverId: String
    public let name: String
    public let version: Int

    public init(serverId: String, name: String, version: Int) {
        self.serverId = serverId
        self.name = name
        self.version = version
    }
}

/// Client time message for clock sync
public struct ClientTimeMessage: SendspinMessage {
    public let type = "client/time"
    public let payload: ClientTimePayload

    public init(payload: ClientTimePayload) {
        self.payload = payload
    }
}

public struct ClientTimePayload: Codable, Sendable {
    public let clientTransmitted: Int64

    public init(clientTransmitted: Int64) {
        self.clientTransmitted = clientTransmitted
    }
}

/// Server time response for clock sync
public struct ServerTimeMessage: SendspinMessage {
    public let type = "server/time"
    public let payload: ServerTimePayload

    public init(payload: ServerTimePayload) {
        self.payload = payload
    }
}

public struct ServerTimePayload: Codable, Sendable {
    public let clientTransmitted: Int64
    public let serverReceived: Int64
    public let serverTransmitted: Int64

    public init(clientTransmitted: Int64, serverReceived: Int64, serverTransmitted: Int64) {
        self.clientTransmitted = clientTransmitted
        self.serverReceived = serverReceived
        self.serverTransmitted = serverTransmitted
    }
}

// MARK: - State Messages

/// Player state update message (sent by clients to report current state)
/// Matches Go implementation which uses "player/update" message type
public struct PlayerUpdateMessage: SendspinMessage {
    public let type = "player/update"
    public let payload: PlayerUpdatePayload

    public init(payload: PlayerUpdatePayload) {
        self.payload = payload
    }
}

public struct PlayerUpdatePayload: Codable, Sendable {
    /// Player state: "idle", "playing", "paused", "buffering", or "error"
    public let state: String
    /// Volume level (0-100)
    public let volume: Int
    /// Mute state
    public let muted: Bool

    public init(state: String, volume: Int, muted: Bool) {
        // Valid player states per Sendspin protocol
        let validStates = ["idle", "playing", "paused", "buffering", "error"]
        precondition(validStates.contains(state), "State must be one of: \(validStates.joined(separator: ", "))")
        precondition(volume >= 0 && volume <= 100, "Volume must be between 0 and 100")

        self.state = state
        self.volume = volume
        self.muted = muted
    }
}

// Legacy type aliases for backward compatibility
@available(
    *,
    deprecated,
    renamed: "PlayerUpdateMessage",
    message: "Use PlayerUpdateMessage instead to match protocol spec"
)
public typealias ClientStateMessage = PlayerUpdateMessage
@available(
    *,
    deprecated,
    renamed: "PlayerUpdatePayload",
    message: "Use PlayerUpdatePayload instead to match protocol spec"
)
public typealias ClientStatePayload = PlayerUpdatePayload
@available(
    *,
    deprecated,
    renamed: "PlayerUpdatePayload",
    message: "Use PlayerUpdatePayload instead to match protocol spec"
)
public typealias PlayerState = PlayerUpdatePayload

// MARK: - Stream Messages

/// Stream start message
public struct StreamStartMessage: SendspinMessage {
    public let type = "stream/start"
    public let payload: StreamStartPayload

    public init(payload: StreamStartPayload) {
        self.payload = payload
    }
}

public struct StreamStartPayload: Codable, Sendable {
    public let player: StreamStartPlayer?
    public let artwork: StreamStartArtwork?
    public let visualizer: StreamStartVisualizer?

    public init(player: StreamStartPlayer?, artwork: StreamStartArtwork?, visualizer: StreamStartVisualizer?) {
        self.player = player
        self.artwork = artwork
        self.visualizer = visualizer
    }
}

public struct StreamStartPlayer: Codable, Sendable {
    public let codec: String
    public let sampleRate: Int
    public let channels: Int
    public let bitDepth: Int
    public let codecHeader: String?

    public init(codec: String, sampleRate: Int, channels: Int, bitDepth: Int, codecHeader: String?) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
        self.codecHeader = codecHeader
    }
}

public struct StreamStartArtwork: Codable, Sendable {
    // IMPLEMENTATION_NOTE: Implement when artwork role is added

    public init() {}

    // Explicit Codable implementation for empty struct
    public init(from _: Decoder) throws {}
    public func encode(to _: Encoder) throws {}
}

public struct StreamStartVisualizer: Codable, Sendable {
    // IMPLEMENTATION_NOTE: Implement when visualizer role is added

    public init() {}

    // Explicit Codable implementation for empty struct
    public init(from _: Decoder) throws {}
    public func encode(to _: Encoder) throws {}
}

/// Stream end message
public struct StreamEndMessage: SendspinMessage {
    public let type = "stream/end"

    public init() {}
}

/// Group update message
public struct GroupUpdateMessage: SendspinMessage {
    public let type = "group/update"
    public let payload: GroupUpdatePayload

    public init(payload: GroupUpdatePayload) {
        self.payload = payload
    }
}

public struct GroupUpdatePayload: Codable, Sendable {
    public let playbackState: String?
    public let groupId: String?
    public let groupName: String?

    public init(playbackState: String?, groupId: String?, groupName: String?) {
        self.playbackState = playbackState
        self.groupId = groupId
        self.groupName = groupName
    }
}

// MARK: - Metadata Messages

/// Stream metadata message (basic track info)
public struct StreamMetadataMessage: SendspinMessage {
    public let type = "stream/metadata"
    public let payload: StreamMetadataPayload

    public init(payload: StreamMetadataPayload) {
        self.payload = payload
    }
}

public struct StreamMetadataPayload: Codable, Sendable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let artworkUrl: String?

    public init(title: String?, artist: String?, album: String?, artworkUrl: String?) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkUrl = artworkUrl
    }
}

/// Session update message (comprehensive session state including metadata)
public struct SessionUpdateMessage: SendspinMessage {
    public let type = "session/update"
    public let payload: SessionUpdatePayload

    public init(payload: SessionUpdatePayload) {
        self.payload = payload
    }
}

public struct SessionUpdatePayload: Codable, Sendable {
    public let groupId: String?
    public let playbackState: String?
    public let metadata: SessionMetadata?

    public init(groupId: String?, playbackState: String?, metadata: SessionMetadata?) {
        self.groupId = groupId
        self.playbackState = playbackState
        self.metadata = metadata
    }
}

public struct SessionMetadata: Codable, Sendable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let albumArtist: String?
    public let track: Int?
    public let trackDuration: Int? // Duration in seconds (Go sends int, not float64)
    public let year: Int?
    public let playbackSpeed: Double?
    public let `repeat`: String? // "off", "track", "all" (Go sends string, not bool)
    public let shuffle: Bool?
    public let artworkUrl: String?
    public let timestamp: Int64?

    public init(
        title: String?,
        artist: String?,
        album: String?,
        albumArtist: String?,
        track: Int?,
        trackDuration: Int?,
        year: Int?,
        playbackSpeed: Double?,
        repeat: String?,
        shuffle: Bool?,
        artworkUrl: String?,
        timestamp: Int64?
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.track = track
        self.trackDuration = trackDuration
        self.year = year
        self.playbackSpeed = playbackSpeed
        self.repeat = `repeat`
        self.shuffle = shuffle
        self.artworkUrl = artworkUrl
        self.timestamp = timestamp
    }
}
