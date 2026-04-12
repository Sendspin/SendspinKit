// ABOUTME: Core protocol message types for Sendspin client-server communication
// ABOUTME: All messages follow the pattern: { "type": "...", "payload": {...} }

import Foundation
#if canImport(UIKit)
    import UIKit
#endif

/// Base protocol for all Sendspin messages
protocol SendspinMessage: Codable, Sendable {
    var type: String { get }
}

// MARK: - Client Messages

/// Client hello message sent after WebSocket connection
struct ClientHelloMessage: SendspinMessage {
    let type = "client/hello"
    public let payload: ClientHelloPayload

    private enum CodingKeys: String, CodingKey { case type, payload }

    public init(payload: ClientHelloPayload) {
        self.payload = payload
    }
}

struct ClientHelloPayload: Codable, Sendable {
    public let clientId: String
    public let name: String
    public let deviceInfo: DeviceInfo?
    public let version: Int
    public let supportedRoles: [VersionedRole]
    public let playerV1Support: PlayerSupport?
    public let artworkV1Support: ArtworkSupport?
    public let visualizerV1Support: VisualizerSupport?

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

    public init(
        clientId: String,
        name: String,
        deviceInfo: DeviceInfo?,
        version: Int,
        supportedRoles: [VersionedRole],
        playerV1Support: PlayerSupport?,
        artworkV1Support: ArtworkSupport?,
        visualizerV1Support: VisualizerSupport?
    ) {
        self.clientId = clientId
        self.name = name
        self.deviceInfo = deviceInfo
        self.version = version
        self.supportedRoles = supportedRoles
        self.playerV1Support = playerV1Support
        self.artworkV1Support = artworkV1Support
        self.visualizerV1Support = visualizerV1Support
    }
}

struct DeviceInfo: Codable, Sendable {
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

enum PlayerCommand: String, Codable, Sendable {
    case volume
    case mute
}

struct PlayerSupport: Codable, Sendable {
    public let supportedFormats: [AudioFormatSpec]
    public let bufferCapacity: Int
    public let supportedCommands: [PlayerCommand]

    enum CodingKeys: String, CodingKey {
        case supportedFormats = "supported_formats"
        case bufferCapacity = "buffer_capacity"
        case supportedCommands = "supported_commands"
    }

    public init(supportedFormats: [AudioFormatSpec], bufferCapacity: Int, supportedCommands: [PlayerCommand]) {
        self.supportedFormats = supportedFormats
        self.bufferCapacity = bufferCapacity
        self.supportedCommands = supportedCommands
    }
}

// NOTE: The metadata role has no support object in the spec.
// It's activated by listing "metadata@v1" in supported_roles.

/// Artwork@v1 support object in client/hello per spec.
/// Declares artwork channels the client can display.
struct ArtworkSupport: Codable, Sendable {
    /// Supported artwork channels (1-4), array index is the channel number
    public let channels: [ArtworkChannel]

    public init(channels: [ArtworkChannel]) {
        self.channels = channels
    }
}

struct VisualizerSupport: Codable, Sendable {
    // IMPLEMENTATION_NOTE: Implement when visualizer role is added

    public init() {}

    // Explicit Codable implementation for empty struct
    public init(from _: Decoder) throws {}
    public func encode(to _: Encoder) throws {}
}

// MARK: - Server Messages

/// Server hello response
struct ServerHelloMessage: SendspinMessage {
    public let type = "server/hello"
    public let payload: ServerHelloPayload

    private enum CodingKeys: String, CodingKey { case type, payload }

    public init(payload: ServerHelloPayload) {
        self.payload = payload
    }
}

/// Connection reason for server/hello
public enum ConnectionReason: String, Codable, Sendable {
    /// Server connected for general availability/discovery
    case discovery
    /// Server connected for active playback
    case playback
}

struct ServerHelloPayload: Codable, Sendable {
    public let serverId: String
    public let name: String
    public let version: Int
    public let activeRoles: [VersionedRole]
    public let connectionReason: ConnectionReason

    enum CodingKeys: String, CodingKey {
        case serverId = "server_id"
        case name
        case version
        case activeRoles = "active_roles"
        case connectionReason = "connection_reason"
    }

    public init(serverId: String, name: String, version: Int, activeRoles: [VersionedRole], connectionReason: ConnectionReason) {
        self.serverId = serverId
        self.name = name
        self.version = version
        self.activeRoles = activeRoles
        self.connectionReason = connectionReason
    }
}

/// Client time message for clock sync
struct ClientTimeMessage: SendspinMessage {
    public let type = "client/time"
    public let payload: ClientTimePayload

    private enum CodingKeys: String, CodingKey { case type, payload }

    public init(payload: ClientTimePayload) {
        self.payload = payload
    }
}

struct ClientTimePayload: Codable, Sendable {
    public let clientTransmitted: Int64

    enum CodingKeys: String, CodingKey {
        case clientTransmitted = "client_transmitted"
    }

    public init(clientTransmitted: Int64) {
        self.clientTransmitted = clientTransmitted
    }
}

/// Server time response for clock sync
struct ServerTimeMessage: SendspinMessage {
    public let type = "server/time"
    public let payload: ServerTimePayload

    private enum CodingKeys: String, CodingKey { case type, payload }

    public init(payload: ServerTimePayload) {
        self.payload = payload
    }
}

struct ServerTimePayload: Codable, Sendable {
    public let clientTransmitted: Int64
    public let serverReceived: Int64
    public let serverTransmitted: Int64

    enum CodingKeys: String, CodingKey {
        case clientTransmitted = "client_transmitted"
        case serverReceived = "server_received"
        case serverTransmitted = "server_transmitted"
    }

    public init(clientTransmitted: Int64, serverReceived: Int64, serverTransmitted: Int64) {
        self.clientTransmitted = clientTransmitted
        self.serverReceived = serverReceived
        self.serverTransmitted = serverTransmitted
    }
}

// MARK: - State Messages

/// Client operational state per Sendspin protocol spec.
/// This is a top-level field in client/state, independent of any role.
enum ClientOperationalState: String, Codable, Sendable {
    /// Client is operational and synchronized with server timestamps
    case synchronized
    /// Client has a problem preventing normal operation
    case error
    /// Client output is in use by an external system
    case externalSource = "external_source"
}

/// Client state message (sent by clients to report current state)
struct ClientStateMessage: SendspinMessage {
    public let type = "client/state"
    public let payload: ClientStatePayload

    private enum CodingKeys: String, CodingKey { case type, payload }

    public init(payload: ClientStatePayload) {
        self.payload = payload
    }
}

/// Client state payload containing client-level state and role-specific state objects.
/// Per spec: must be sent after server/hello and whenever any state changes.
struct ClientStatePayload: Codable, Sendable {
    /// Client operational state (required on initial send, optional on deltas)
    public let state: ClientOperationalState?
    /// Player role state (only if client has player role)
    public let player: PlayerStateObject?

    public init(state: ClientOperationalState? = nil, player: PlayerStateObject? = nil) {
        self.state = state
        self.player = player
    }
}

/// Player state object within client/state message.
/// Per spec: volume/muted are optional (only if supported), but static_delay_ms is always required.
struct PlayerStateObject: Codable, Sendable {
    /// Volume level (0-100), only if 'volume' is in supported_commands from player@v1_support
    public let volume: Int?
    /// Mute state, only if 'mute' is in supported_commands from player@v1_support
    public let muted: Bool?
    /// Static delay in milliseconds (0-5000), always required for players.
    /// Compensates for delay beyond the audio port (external speakers, amplifiers).
    public let staticDelayMs: Int
    /// Supported commands that can change at runtime (e.g. when audio output changes)
    public let supportedCommands: [String]?

    enum CodingKeys: String, CodingKey {
        case volume
        case muted
        case staticDelayMs = "static_delay_ms"
        case supportedCommands = "supported_commands"
    }

    public init(volume: Int? = nil, muted: Bool? = nil, staticDelayMs: Int = 0, supportedCommands: [String]? = nil) {
        if let vol = volume {
            precondition(vol >= 0 && vol <= 100, "Volume must be between 0 and 100")
        }
        precondition(staticDelayMs >= 0 && staticDelayMs <= 5000, "static_delay_ms must be 0-5000")
        self.volume = volume
        self.muted = muted
        self.staticDelayMs = staticDelayMs
        self.supportedCommands = supportedCommands
    }
}

// MARK: - Server State

/// Server state message (delta state updates from server to client)
struct ServerStateMessage: SendspinMessage {
    public let type = "server/state"
    public let payload: ServerStatePayload

    private enum CodingKeys: String, CodingKey { case type, payload }

    public init(payload: ServerStatePayload) {
        self.payload = payload
    }
}

struct ServerStatePayload: Codable, Sendable {
    /// Player state pushed from server (e.g. volume/mute commands)
    public let player: ServerPlayerState?
    /// Metadata state from server
    public let metadata: ServerMetadataState?
    /// Controller state from server (group volume, mute, supported commands)
    public let controller: ServerControllerState?

    public init(player: ServerPlayerState? = nil, metadata: ServerMetadataState? = nil, controller: ServerControllerState? = nil) {
        self.player = player
        self.metadata = metadata
        self.controller = controller
    }
}

/// Player state within server/state
struct ServerPlayerState: Codable, Sendable {
    public let volume: Int?
    public let muted: Bool?

    public init(volume: Int? = nil, muted: Bool? = nil) {
        self.volume = volume
        self.muted = muted
    }
}

/// Controller state within server/state — tells the client what commands are available
/// and the current group volume/mute state.
struct ServerControllerState: Codable, Sendable {
    /// Which commands the server supports for this group
    public let supportedCommands: [String]?
    /// Group volume (0-100, average of all player volumes)
    public let volume: Int?
    /// Group mute state (true only when all players muted)
    public let muted: Bool?

    enum CodingKeys: String, CodingKey {
        case supportedCommands = "supported_commands"
        case volume
        case muted
    }

    public init(supportedCommands: [String]? = nil, volume: Int? = nil, muted: Bool? = nil) {
        self.supportedCommands = supportedCommands
        self.volume = volume
        self.muted = muted
    }
}

/// Distinguishes "field absent" from "field explicitly null" in JSON delta merges.
/// Per spec: absent means "no change", null means "clear the value".
enum Nullable<T: Codable & Sendable>: Sendable {
    /// Key was not present in JSON — keep previous value
    case absent
    /// Key was present with a JSON null — clear the value
    case null
    /// Key was present with a value
    case value(T)

    /// Whether this field was absent from the JSON (key not present).
    var isAbsent: Bool {
        if case .absent = self { return true }
        return false
    }

    /// Merge this delta field with a previous value.
    /// - `.absent` → keep previous
    /// - `.null` → clear (return nil)
    /// - `.value(v)` → use new value
    func merge(previous: T?) -> T? {
        switch self {
        case .absent: return previous
        case .null: return nil
        case .value(let v): return v
        }
    }
}

extension Nullable: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else {
            self = .value(try container.decode(T.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .absent:
            break // Don't encode anything — omit from output
        case .null:
            try container.encodeNil()
        case .value(let v):
            try container.encode(v)
        }
    }
}

/// Metadata state within server/state.
/// Uses `Nullable` for fields that the spec says can be cleared with explicit null.
struct ServerMetadataState: Sendable {
    public let timestamp: Int64?
    public let title: Nullable<String>
    public let artist: Nullable<String>
    public let albumArtist: Nullable<String>
    public let album: Nullable<String>
    public let artworkUrl: Nullable<String>
    public let year: Nullable<Int>
    public let track: Nullable<Int>
    public let progress: Nullable<MetadataProgress>
    public let `repeat`: Nullable<String>
    public let shuffle: Nullable<Bool>

    enum CodingKeys: String, CodingKey {
        case timestamp
        case title
        case artist
        case albumArtist = "album_artist"
        case album
        case artworkUrl = "artwork_url"
        case year
        case track
        case progress
        case `repeat`
        case shuffle
    }

    public init(
        timestamp: Int64? = nil, title: Nullable<String> = .absent, artist: Nullable<String> = .absent,
        albumArtist: Nullable<String> = .absent, album: Nullable<String> = .absent, artworkUrl: Nullable<String> = .absent,
        year: Nullable<Int> = .absent, track: Nullable<Int> = .absent, progress: Nullable<MetadataProgress> = .absent,
        repeat: Nullable<String> = .absent, shuffle: Nullable<Bool> = .absent
    ) {
        self.timestamp = timestamp
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.artworkUrl = artworkUrl
        self.year = year
        self.track = track
        self.progress = progress
        self.repeat = `repeat`
        self.shuffle = shuffle
    }
}

extension ServerMetadataState: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decodeIfPresent(Int64.self, forKey: .timestamp)
        title = container.contains(.title) ? try container.decode(Nullable<String>.self, forKey: .title) : .absent
        artist = container.contains(.artist) ? try container.decode(Nullable<String>.self, forKey: .artist) : .absent
        albumArtist = container.contains(.albumArtist) ? try container.decode(Nullable<String>.self, forKey: .albumArtist) : .absent
        album = container.contains(.album) ? try container.decode(Nullable<String>.self, forKey: .album) : .absent
        artworkUrl = container.contains(.artworkUrl) ? try container.decode(Nullable<String>.self, forKey: .artworkUrl) : .absent
        year = container.contains(.year) ? try container.decode(Nullable<Int>.self, forKey: .year) : .absent
        track = container.contains(.track) ? try container.decode(Nullable<Int>.self, forKey: .track) : .absent
        progress = container.contains(.progress) ? try container.decode(Nullable<MetadataProgress>.self, forKey: .progress) : .absent
        `repeat` = container.contains(.repeat) ? try container.decode(Nullable<String>.self, forKey: .repeat) : .absent
        shuffle = container.contains(.shuffle) ? try container.decode(Nullable<Bool>.self, forKey: .shuffle) : .absent
    }
}

extension ServerMetadataState: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
        // Only encode non-absent fields (absent = key not in JSON delta)
        if !title.isAbsent { try container.encode(title, forKey: .title) }
        if !artist.isAbsent { try container.encode(artist, forKey: .artist) }
        if !albumArtist.isAbsent { try container.encode(albumArtist, forKey: .albumArtist) }
        if !album.isAbsent { try container.encode(album, forKey: .album) }
        if !artworkUrl.isAbsent { try container.encode(artworkUrl, forKey: .artworkUrl) }
        if !year.isAbsent { try container.encode(year, forKey: .year) }
        if !track.isAbsent { try container.encode(track, forKey: .track) }
        if !progress.isAbsent { try container.encode(progress, forKey: .progress) }
        if !`repeat`.isAbsent { try container.encode(`repeat`, forKey: .repeat) }
        if !shuffle.isAbsent { try container.encode(shuffle, forKey: .shuffle) }
    }
}

/// Progress information within metadata
struct MetadataProgress: Codable, Sendable {
    /// Current playback position in milliseconds since start of track
    public let trackProgress: Int?
    /// Total track length in milliseconds, 0 for unlimited/unknown duration
    public let trackDuration: Int?
    /// Playback speed multiplier × 1000 (e.g. 1000 = normal, 0 = paused)
    public let playbackSpeed: Int?

    enum CodingKeys: String, CodingKey {
        case trackProgress = "track_progress"
        case trackDuration = "track_duration"
        case playbackSpeed = "playback_speed"
    }

    public init(trackProgress: Int? = nil, trackDuration: Int? = nil, playbackSpeed: Int? = nil) {
        self.trackProgress = trackProgress
        self.trackDuration = trackDuration
        self.playbackSpeed = playbackSpeed
    }
}

// MARK: - Stream Messages

/// Stream start message
struct StreamStartMessage: SendspinMessage {
    public let type = "stream/start"
    public let payload: StreamStartPayload

    private enum CodingKeys: String, CodingKey { case type, payload }

    public init(payload: StreamStartPayload) {
        self.payload = payload
    }
}

struct StreamStartPayload: Codable, Sendable {
    public let player: StreamStartPlayer?
    public let artwork: StreamStartArtwork?
    public let visualizer: StreamStartVisualizer?

    public init(player: StreamStartPlayer?, artwork: StreamStartArtwork?, visualizer: StreamStartVisualizer?) {
        self.player = player
        self.artwork = artwork
        self.visualizer = visualizer
    }
}

struct StreamStartPlayer: Codable, Sendable {
    public let codec: String
    public let sampleRate: Int
    public let channels: Int
    public let bitDepth: Int
    public let codecHeader: String?

    enum CodingKeys: String, CodingKey {
        case codec
        case sampleRate = "sample_rate"
        case channels
        case bitDepth = "bit_depth"
        case codecHeader = "codec_header"
    }

    public init(codec: String, sampleRate: Int, channels: Int, bitDepth: Int, codecHeader: String?) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
        self.codecHeader = codecHeader
    }
}

/// Artwork stream configuration in stream/start per spec.
/// Contains per-channel config with resolved dimensions.
struct StreamStartArtwork: Codable, Sendable {
    /// Configuration for each active artwork channel, array index is the channel number
    public let channels: [StreamArtworkChannelConfig]

    public init(channels: [StreamArtworkChannelConfig]) {
        self.channels = channels
    }
}

struct StreamStartVisualizer: Codable, Sendable {
    // IMPLEMENTATION_NOTE: Implement when visualizer role is added

    public init() {}

    // Explicit Codable implementation for empty struct
    public init(from _: Decoder) throws {}
    public func encode(to _: Encoder) throws {}
}

/// Stream end message — ends streams for specified roles (or all if omitted)
struct StreamEndMessage: SendspinMessage {
    public let type = "stream/end"
    public let payload: StreamEndPayload

    private enum CodingKeys: String, CodingKey { case type, payload }

    public init(payload: StreamEndPayload = StreamEndPayload()) {
        self.payload = payload
    }
}

struct StreamEndPayload: Codable, Sendable {
    /// Roles to end streams for. If nil, ends all active streams.
    public let roles: [String]?

    public init(roles: [String]? = nil) {
        self.roles = roles
    }
}

/// Group update message
struct GroupUpdateMessage: SendspinMessage {
    public let type = "group/update"
    public let payload: GroupUpdatePayload

    private enum CodingKeys: String, CodingKey { case type, payload }

    public init(payload: GroupUpdatePayload) {
        self.payload = payload
    }
}

struct GroupUpdatePayload: Codable, Sendable {
    public let playbackState: String?
    public let groupId: String?
    public let groupName: String?

    enum CodingKeys: String, CodingKey {
        case playbackState = "playback_state"
        case groupId = "group_id"
        case groupName = "group_name"
    }

    public init(playbackState: String?, groupId: String?, groupName: String?) {
        self.playbackState = playbackState
        self.groupId = groupId
        self.groupName = groupName
    }
}

// MARK: - Clear Messages

/// Stream clear message — instructs client to clear buffers without ending the stream.
/// Used for seek operations.
struct StreamClearMessage: SendspinMessage {
    public let type = "stream/clear"
    public let payload: StreamClearPayload

    private enum CodingKeys: String, CodingKey { case type, payload }

    public init(payload: StreamClearPayload) {
        self.payload = payload
    }
}

struct StreamClearPayload: Codable, Sendable {
    /// Which roles to clear. If nil, clears all roles.
    public let roles: [String]?

    public init(roles: [String]? = nil) {
        self.roles = roles
    }
}

// MARK: - Stream Format Request

/// Client requests a different stream format (upgrade or downgrade).
/// Available for clients with the player or artwork role.
struct StreamRequestFormatMessage: SendspinMessage {
    public let type = "stream/request-format"
    public let payload: StreamRequestFormatPayload

    private enum CodingKeys: String, CodingKey { case type, payload }

    public init(payload: StreamRequestFormatPayload) {
        self.payload = payload
    }
}

struct StreamRequestFormatPayload: Codable, Sendable {
    /// Player format request (only for clients with player role)
    public let player: PlayerFormatRequest?
    /// Artwork format request (only for clients with artwork role)
    public let artwork: ArtworkFormatRequest?

    public init(player: PlayerFormatRequest? = nil, artwork: ArtworkFormatRequest? = nil) {
        self.player = player
        self.artwork = artwork
    }
}

/// Player format request within stream/request-format per spec
struct PlayerFormatRequest: Codable, Sendable {
    public let codec: String?
    public let channels: Int?
    public let sampleRate: Int?
    public let bitDepth: Int?

    enum CodingKeys: String, CodingKey {
        case codec
        case channels
        case sampleRate = "sample_rate"
        case bitDepth = "bit_depth"
    }

    public init(codec: String? = nil, channels: Int? = nil, sampleRate: Int? = nil, bitDepth: Int? = nil) {
        self.codec = codec
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
    }
}

/// Artwork format request within stream/request-format per spec.
/// Requests the server to change artwork format for a specific channel.
struct ArtworkFormatRequest: Codable, Sendable {
    /// Channel number (0-3)
    public let channel: Int
    /// Artwork source type
    public let source: ArtworkSource?
    /// Requested image format
    public let format: ImageFormat?
    /// Requested max width in pixels
    public let mediaWidth: Int?
    /// Requested max height in pixels
    public let mediaHeight: Int?

    enum CodingKeys: String, CodingKey {
        case channel
        case source
        case format
        case mediaWidth = "media_width"
        case mediaHeight = "media_height"
    }

    public init(channel: Int, source: ArtworkSource? = nil, format: ImageFormat? = nil, mediaWidth: Int? = nil, mediaHeight: Int? = nil) {
        precondition(channel >= 0 && channel <= 3, "channel must be 0-3")
        self.channel = channel
        self.source = source
        self.format = format
        self.mediaWidth = mediaWidth
        self.mediaHeight = mediaHeight
    }
}

// MARK: - Command Messages

/// Command sent from client to server (e.g. play, pause, skip)
struct ClientCommandMessage: SendspinMessage {
    public let type = "client/command"
    public let payload: ClientCommandPayload

    private enum CodingKeys: String, CodingKey { case type, payload }

    public init(payload: ClientCommandPayload) {
        self.payload = payload
    }
}

struct ClientCommandPayload: Codable, Sendable {
    public let controller: ControllerCommand?

    public init(controller: ControllerCommand?) {
        self.controller = controller
    }
}

struct ControllerCommand: Codable, Sendable {
    /// Command type: play, pause, stop, next, previous, volume, mute,
    /// repeat_off, repeat_one, repeat_all, shuffle, unshuffle, switch
    public let command: String
    /// Group volume (0-100), only when command is "volume"
    public let volume: Int?
    /// Group mute state, only when command is "mute"
    public let mute: Bool?

    public init(command: String, volume: Int? = nil, mute: Bool? = nil) {
        self.command = command
        self.volume = volume
        self.mute = mute
    }
}

/// Command sent from server to client (e.g. volume, mute, set_static_delay)
struct ServerCommandMessage: SendspinMessage {
    public let type = "server/command"
    public let payload: ServerCommandPayload

    private enum CodingKeys: String, CodingKey { case type, payload }

    public init(payload: ServerCommandPayload) {
        self.payload = payload
    }
}

struct ServerCommandPayload: Codable, Sendable {
    public let player: PlayerCommandObject?

    public init(player: PlayerCommandObject? = nil) {
        self.player = player
    }
}

/// Player command object within server/command
struct PlayerCommandObject: Codable, Sendable {
    /// Command type: "volume", "mute", or "set_static_delay"
    public let command: String
    /// Volume value (0-100), present when command is "volume"
    public let volume: Int?
    /// Mute state, present when command is "mute"
    public let mute: Bool?
    /// Static delay in ms (0-5000), present when command is "set_static_delay"
    public let staticDelayMs: Int?

    enum CodingKeys: String, CodingKey {
        case command
        case volume
        case mute
        case staticDelayMs = "static_delay_ms"
    }

    public init(command: String, volume: Int? = nil, mute: Bool? = nil, staticDelayMs: Int? = nil) {
        self.command = command
        self.volume = volume
        self.mute = mute
        self.staticDelayMs = staticDelayMs
    }
}

// MARK: - Goodbye Messages

/// Client goodbye message (graceful disconnect)
struct ClientGoodbyeMessage: SendspinMessage {
    public let type = "client/goodbye"
    public let payload: GoodbyePayload?

    private enum CodingKeys: String, CodingKey { case type, payload }

    public init(payload: GoodbyePayload? = nil) {
        self.payload = payload
    }
}

/// Goodbye reason per spec
public enum GoodbyeReason: String, Codable, Sendable {
    /// Switching to a different server
    case anotherServer = "another_server"
    /// Client is shutting down
    case shutdown
    /// Client is restarting and will reconnect
    case restart
    /// User explicitly requested disconnect
    case userRequest = "user_request"
}

/// Goodbye payload with optional reason
struct GoodbyePayload: Codable, Sendable {
    public let reason: GoodbyeReason?

    public init(reason: GoodbyeReason? = nil) {
        self.reason = reason
    }
}
