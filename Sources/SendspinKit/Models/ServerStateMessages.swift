import Foundation

// MARK: - Server State

/// Server state message (delta state updates from server to client)
struct ServerStateMessage: SendspinMessage, Equatable {
    static let typeString = "server/state"
    let type = Self.typeString
    let payload: ServerStatePayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ServerStatePayload: Codable, Equatable {
    /// Metadata state from server
    let metadata: ServerMetadataState?
    /// Controller state from server (group volume, mute, supported commands)
    let controller: ServerControllerState?

    init(metadata: ServerMetadataState? = nil, controller: ServerControllerState? = nil) {
        self.metadata = metadata
        self.controller = controller
    }
}

/// Controller state within server/state — tells the client what commands are available
/// and the current group volume/mute state.
struct ServerControllerState: Equatable {
    /// Which commands the server supports for this group
    let supportedCommands: [ControllerCommandType]?
    /// Group volume (0-100, average of all player volumes)
    let volume: Int?
    /// Group mute state (true only when all players muted)
    let muted: Bool?
    /// Group repeat mode
    let `repeat`: RepeatMode?
    /// Group shuffle state
    let shuffle: Bool?
    /// Delta value for the maximum absolute seek target in milliseconds.
    /// Absent means preserve prior controller state; null means clear a prior bounded range.
    let seekMaxMsDelta: Nullable<Int>
    /// Maximum absolute seek target in milliseconds when this delta carries a concrete value.
    var seekMaxMs: Int? {
        if case let .value(value) = seekMaxMsDelta { value } else { nil }
    }

    enum CodingKeys: String, CodingKey {
        case supportedCommands = "supported_commands"
        case volume
        case muted
        case `repeat`
        case shuffle
        case seekMaxMs = "seek_max_ms"
    }

    init(
        supportedCommands: [ControllerCommandType]? = nil,
        volume: Int? = nil,
        muted: Bool? = nil,
        repeat: RepeatMode? = nil,
        shuffle: Bool? = nil,
        seekMaxMs: Int? = nil,
        seekMaxMsDelta: Nullable<Int>? = nil
    ) {
        self.supportedCommands = supportedCommands
        self.volume = volume
        self.muted = muted
        self.repeat = `repeat`
        self.shuffle = shuffle
        self.seekMaxMsDelta = seekMaxMsDelta ?? seekMaxMs.map(Nullable.value) ?? .absent
    }
}

extension ServerControllerState: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        supportedCommands = try container.decodeIfPresent([ControllerCommandType].self, forKey: .supportedCommands)
        volume = try container.decodeIfPresent(Int.self, forKey: .volume)
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted)
        `repeat` = try container.decodeIfPresent(RepeatMode.self, forKey: .repeat)
        shuffle = try container.decodeIfPresent(Bool.self, forKey: .shuffle)
        seekMaxMsDelta = container.contains(.seekMaxMs)
            ? try container.decode(Nullable<Int>.self, forKey: .seekMaxMs)
            : .absent
    }
}

extension ServerControllerState: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(supportedCommands, forKey: .supportedCommands)
        try container.encodeIfPresent(volume, forKey: .volume)
        try container.encodeIfPresent(muted, forKey: .muted)
        try container.encodeIfPresent(`repeat`, forKey: .repeat)
        try container.encodeIfPresent(shuffle, forKey: .shuffle)
        if !seekMaxMsDelta.isAbsent { try container.encode(seekMaxMsDelta, forKey: .seekMaxMs) }
    }
}

/// Distinguishes "field absent" from "field explicitly null" in JSON delta merges.
///
/// Per spec: absent means "no change", null means "clear the value".
///
/// - Important: `Nullable` values should not be encoded directly via a keyed container's
///   `encode(_:forKey:)` when the value is `.absent`. The `Codable` conformance encodes
///   `.absent` as an empty single-value container, which most encoders emit as `null` —
///   indistinguishable from `.null`. Instead, check `isAbsent` and skip encoding entirely.
///   See `ServerMetadataState.encode(to:)` for the correct pattern.
enum Nullable<T: Codable & Sendable> {
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
        case .absent: previous
        case .null: nil
        case let .value(v): v
        }
    }
}

extension Nullable: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else {
            self = try .value(container.decode(T.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .absent:
            // Encoding .absent directly is a programming error. JSONEncoder would emit null,
            // making .absent indistinguishable from .null on the wire. Container types must
            // check isAbsent and skip the key entirely — see ServerMetadataState.encode(to:).
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Nullable.absent must not be encoded directly — check isAbsent before encoding"
                )
            )
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let .value(v):
            var container = encoder.singleValueContainer()
            try container.encode(v)
        }
    }
}

extension Nullable: Equatable where T: Equatable {}
extension Nullable: Hashable where T: Hashable {}

/// Metadata state within server/state.
///
/// Conforms to `Decodable` and `Encodable` via separate extensions rather than
/// declaring `Codable` on the struct, because the custom `init(from:)` needs to
/// distinguish absent keys from explicit nulls using `container.contains(_:)`.
struct ServerMetadataState: Equatable {
    let timestamp: Int64?
    let title: Nullable<String>
    let artist: Nullable<String>
    let albumArtist: Nullable<String>
    let album: Nullable<String>
    let artworkUrl: Nullable<String>
    let year: Nullable<Int>
    let track: Nullable<Int>
    let progress: Nullable<MetadataProgress>

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
    }

    init(
        timestamp: Int64? = nil, title: Nullable<String> = .absent, artist: Nullable<String> = .absent,
        albumArtist: Nullable<String> = .absent, album: Nullable<String> = .absent, artworkUrl: Nullable<String> = .absent,
        year: Nullable<Int> = .absent, track: Nullable<Int> = .absent, progress: Nullable<MetadataProgress> = .absent
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
    }
}

extension ServerMetadataState: Decodable {
    init(from decoder: Decoder) throws {
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
    }
}

extension ServerMetadataState: Encodable {
    func encode(to encoder: Encoder) throws {
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
    }
}

/// Progress information within metadata
struct MetadataProgress: Codable, Equatable {
    /// Current playback position in milliseconds since start of track
    let trackProgress: Int
    /// Total track length in milliseconds, 0 for unlimited/unknown duration
    let trackDuration: Int
    /// Playback speed multiplier × 1000 (e.g. 1000 = normal, 0 = paused)
    let playbackSpeed: Int

    enum CodingKeys: String, CodingKey {
        case trackProgress = "track_progress"
        case trackDuration = "track_duration"
        case playbackSpeed = "playback_speed"
    }
}
