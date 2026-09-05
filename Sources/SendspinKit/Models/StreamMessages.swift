import Foundation

// MARK: - Stream Messages

/// Stream start message
struct StreamStartMessage: SendspinMessage, Equatable {
    static let typeString = "stream/start"
    let type = Self.typeString
    let payload: StreamStartPayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct StreamStartPayload: Codable, Equatable {
    let player: StreamStartPlayer?
    let artwork: StreamStartArtwork?
    let visualizer: StreamStartVisualizer?
}

/// Player stream configuration within stream/start.
///
/// `codec` is `String` rather than `AudioCodec` because this is a server-provided
/// type — the server may support codecs the client doesn't know about yet. The client
/// validates the codec when building `AudioFormatSpec` and surfaces a structured
/// `.unsupportedCodec` error if it's unrecognized.
struct StreamStartPlayer: Codable, Equatable {
    let codec: String
    let sampleRate: Int
    let channels: Int
    let bitDepth: Int
    let codecHeader: String?

    enum CodingKeys: String, CodingKey {
        case codec
        case sampleRate = "sample_rate"
        case channels
        case bitDepth = "bit_depth"
        case codecHeader = "codec_header"
    }
}

/// Artwork stream configuration in stream/start per spec.
/// Contains per-channel config with resolved dimensions.
struct StreamStartArtwork: Codable, Equatable {
    /// Configuration for each active artwork channel, array index is the channel number
    let channels: [StreamArtworkChannelConfig]
}

/// Empty `stream/start` visualizer block. The visualizer role is not yet
/// implemented; this exists so a server `stream/start` carrying a visualizer
/// block decodes (and re-encodes) without error rather than failing the message.
struct StreamStartVisualizer: Codable, Equatable {
    init() {}

    // Explicit Codable implementation for empty struct
    init(from _: Decoder) throws {}
    func encode(to _: Encoder) throws {}
}

/// Stream end message — ends streams for specified roles (or all if omitted)
struct StreamEndMessage: SendspinMessage, Equatable {
    static let typeString = "stream/end"
    let type = Self.typeString
    let payload: StreamEndPayload

    private enum CodingKeys: String, CodingKey { case type, payload }

    init(payload: StreamEndPayload = StreamEndPayload()) {
        self.payload = payload
    }
}

struct StreamEndPayload: Codable, Equatable {
    /// Roles to end streams for. If nil, ends all active streams.
    /// Typed as `[String]?` because the spec allows application-specific roles
    /// (prefixed with `_`), making this an open set.
    let roles: [String]?

    init(roles: [String]? = nil) {
        self.roles = roles
    }
}

/// Group update message
struct GroupUpdateMessage: SendspinMessage, Equatable {
    static let typeString = "group/update"
    let type = Self.typeString
    let payload: GroupUpdatePayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct GroupUpdatePayload: Codable, Equatable {
    /// Per spec, playback_state is a closed set: `'playing' | 'stopped'`.
    /// Unlike roles, there's no extensibility mechanism for custom states.
    let playbackState: PlaybackState?
    let groupId: String?
    let groupName: String?

    /// Key-presence flags for delta merging. Plain optionals cannot distinguish
    /// an absent key (keep previous value) from an explicit null (clear value).
    let hasPlaybackState: Bool
    let hasGroupId: Bool
    let hasGroupName: Bool

    enum CodingKeys: String, CodingKey {
        case playbackState = "playback_state"
        case groupId = "group_id"
        case groupName = "group_name"
    }

    init(playbackState: PlaybackState? = nil, groupId: String? = nil, groupName: String? = nil) {
        self.playbackState = playbackState
        self.groupId = groupId
        self.groupName = groupName
        hasPlaybackState = playbackState != nil
        hasGroupId = groupId != nil
        hasGroupName = groupName != nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasPlaybackState = container.contains(.playbackState)
        hasGroupId = container.contains(.groupId)
        hasGroupName = container.contains(.groupName)
        playbackState = try container.decodeIfPresent(PlaybackState.self, forKey: .playbackState)
        groupId = try container.decodeIfPresent(String.self, forKey: .groupId)
        groupName = try container.decodeIfPresent(String.self, forKey: .groupName)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if hasPlaybackState {
            try container.encodeIfPresent(playbackState, forKey: .playbackState)
        }
        if hasGroupId {
            try container.encodeIfPresent(groupId, forKey: .groupId)
        }
        if hasGroupName {
            try container.encodeIfPresent(groupName, forKey: .groupName)
        }
    }
}

// MARK: - Clear Messages

/// Stream clear message — instructs client to clear buffers without ending the stream.
/// Used for seek operations.
struct StreamClearMessage: SendspinMessage, Equatable {
    static let typeString = "stream/clear"
    let type = Self.typeString
    let payload: StreamClearPayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct StreamClearPayload: Codable, Equatable {
    /// Which roles to clear. If nil, clears all roles.
    /// Typed as `[String]?` because the spec allows application-specific roles
    /// (prefixed with `_`), making this an open set.
    let roles: [String]?

    init(roles: [String]? = nil) {
        self.roles = roles
    }
}
