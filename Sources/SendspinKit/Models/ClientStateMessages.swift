import Foundation

// MARK: - State Messages

/// Client operational state per Sendspin protocol spec.
/// This is a top-level field in client/state, independent of any role.
enum EngineSyncState: String, Codable, Equatable, Sendable {
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
    /// Whether the client is available. This is required on every snapshot.
    let available: Bool
    /// Role objects are omitted only when that role's state is unchanged or inactive.
    let player: PlayerStateObject?
    let artwork: ArtworkStateObject?
    let visualizer: VisualizerStateObject?

    init(
        available: Bool,
        player: PlayerStateObject? = nil,
        artwork: ArtworkStateObject? = nil,
        visualizer: VisualizerStateObject? = nil
    ) {
        self.available = available
        self.player = player
        self.artwork = artwork
        self.visualizer = visualizer
    }

    enum CodingKeys: String, CodingKey {
        case available
        case player
        case artwork
        case visualizer
    }
}

/// Full player state object within client/state. Omission is only valid at the
/// enclosing payload level when the player role is unchanged or inactive.
struct PlayerStateObject: Codable, Equatable {
    /// Volume level (0-100), only if 'volume' is in supported_commands from player@v1_support
    let volume: Int?
    /// Mute state, only if 'mute' is in supported_commands from player@v1_support
    let muted: Bool?
    /// Output delay in milliseconds (0-5000), always present in a full object.
    let outputDelayMs: Int
    /// Commands the server may send to this player.
    let supportedCommands: [PlayerCommand]
    let requiredLeadTimeMs: Int
    let minBufferMs: Int
    /// Preferred format, if the host has selected one.
    let format: AudioFormatSpec?

    enum CodingKeys: String, CodingKey {
        case volume
        case muted
        case outputDelayMs = "output_delay_ms"
        case supportedCommands = "supported_commands"
        case requiredLeadTimeMs = "required_lead_time_ms"
        case minBufferMs = "min_buffer_ms"
        case format
    }

    /// Commands valid in the `client/state` player object.
    static let validStateCommands: Set<PlayerCommand> = [.volume, .mute, .setOutputDelay]

    init(
        volume: Int? = nil,
        muted: Bool? = nil,
        outputDelayMs: Int = 0,
        supportedCommands: [PlayerCommand] = [],
        requiredLeadTimeMs: Int = defaultRequiredLeadTimeMs,
        minBufferMs: Int = defaultMinBufferMs,
        format: AudioFormatSpec? = nil
    ) throws(ConfigurationError) {
        guard outputDelayMs >= 0, outputDelayMs <= maxOutputDelayMs else {
            throw .outputDelayOutOfRange(outputDelayMs)
        }
        if let volume {
            guard volume >= 0, volume <= 100 else { throw .volumeOutOfRange(volume) }
        }
        if supportedCommands.contains(.volume), volume == nil {
            throw .missingRequiredStateField("volume")
        }
        if supportedCommands.contains(.mute), muted == nil {
            throw .missingRequiredStateField("muted")
        }
        self.volume = volume
        self.muted = muted
        self.outputDelayMs = outputDelayMs
        self.supportedCommands = supportedCommands
        self.requiredLeadTimeMs = requiredLeadTimeMs
        self.minBufferMs = minBufferMs
        self.format = format
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        volume = try container.decodeIfPresent(Int.self, forKey: .volume)
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted)
        outputDelayMs = try container.decode(Int.self, forKey: .outputDelayMs)
        supportedCommands = try container.decode([PlayerCommand].self, forKey: .supportedCommands)
        requiredLeadTimeMs = try container.decode(Int.self, forKey: .requiredLeadTimeMs)
        minBufferMs = try container.decode(Int.self, forKey: .minBufferMs)
        format = try container.decodeIfPresent(AudioFormatSpec.self, forKey: .format)
        do {
            guard outputDelayMs >= 0, outputDelayMs <= maxOutputDelayMs else { throw ConfigurationError.outputDelayOutOfRange(outputDelayMs) }
            if supportedCommands.contains(.volume), volume == nil {
                throw ConfigurationError.missingRequiredStateField("volume")
            }
            if supportedCommands.contains(.mute), muted == nil {
                throw ConfigurationError.missingRequiredStateField("muted")
            }
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: String(describing: error)))
        }
    }
}

/// Dynamic artwork preferences in client/state.
public struct ArtworkStateObject: Codable, Equatable, Sendable {
    public let channels: [ArtworkStateChannel]
    public init(channels: [ArtworkStateChannel]) throws(ConfigurationError) {
        guard !channels.isEmpty else { throw .emptyArtworkChannels }
        guard channels.count <= 4 else { throw .tooManyArtworkChannels(channels.count) }
        self.channels = channels
    }
}

public struct ArtworkStateChannel: Codable, Equatable, Sendable {
    public let source: ArtworkSource
    public let format: ImageFormat?
    public let width: Int?
    public let height: Int?

    enum CodingKeys: String, CodingKey { case source, format, width, height }

    public init(source: ArtworkSource, format: ImageFormat? = nil, width: Int? = nil, height: Int? = nil) throws(ConfigurationError) {
        if source == .none {
            guard format == nil, width == nil, height == nil else { throw .invalidArtworkStateChannel }
        } else {
            guard format != nil, let width, width > 0, let height, height > 0 else { throw .invalidArtworkStateChannel }
        }
        self.source = source
        self.format = format
        self.width = width
        self.height = height
    }
}

/// Configuration for the visualizer role, including its hello buffer capacity.
public struct VisualizerConfiguration: Sendable {
    /// Requested visualization data types.
    public let types: [VisualizerType]
    /// Maximum periodic visualization frames per second.
    public let rateMax: Int
    /// Spectrum parameters, required when `types` includes `.spectrum`.
    public let spectrum: SpectrumConfiguration?
    /// Maximum total size in bytes of buffered visualizer messages.
    public let bufferCapacity: Int

    public init(
        types: [VisualizerType],
        rateMax: Int,
        spectrum: SpectrumConfiguration? = nil,
        bufferCapacity: Int = 65_536
    ) throws(ConfigurationError) {
        guard bufferCapacity > 0 else { throw .nonPositiveBufferCapacity }
        guard !types.contains(.spectrum) || spectrum != nil else { throw .missingSpectrumConfiguration }
        self.types = types
        self.rateMax = rateMax
        self.spectrum = spectrum
        self.bufferCapacity = bufferCapacity
    }

    var stateObject: VisualizerStateObject {
        VisualizerStateObject(uncheckedTypes: types, rateMax: rateMax, spectrum: spectrum)
    }
}

/// Dynamic visualizer preferences in client/state.
public struct VisualizerStateObject: Codable, Equatable, Sendable {
    public let types: [VisualizerType]
    public let rateMax: Int
    public let spectrum: SpectrumConfiguration?
    enum CodingKeys: String, CodingKey { case types; case rateMax = "rate_max"; case spectrum }
    public init(types: [VisualizerType], rateMax: Int, spectrum: SpectrumConfiguration? = nil) throws(ConfigurationError) {
        guard !types.contains(.spectrum) || spectrum != nil else { throw .missingSpectrumConfiguration }
        self.init(uncheckedTypes: types, rateMax: rateMax, spectrum: spectrum)
    }

    init(uncheckedTypes types: [VisualizerType], rateMax: Int, spectrum: SpectrumConfiguration?) {
        self.types = types
        self.rateMax = rateMax
        self.spectrum = spectrum
    }
}

public enum VisualizerType: String, Codable, Equatable, Sendable { case beat, loudness, fPeak = "f_peak", peak, spectrum }
public struct SpectrumConfiguration: Codable, Equatable, Sendable {
    public let nDispBins: Int
    public let scale: SpectrumScale
    public let fMin: Int
    public let fMax: Int
    enum CodingKeys: String, CodingKey { case nDispBins = "n_disp_bins"; case scale; case fMin = "f_min"; case fMax = "f_max" }
    public init(nDispBins: Int, scale: SpectrumScale, fMin: Int, fMax: Int) {
        self.nDispBins = nDispBins; self.scale = scale; self.fMin = fMin; self.fMax = fMax
    }
}

public enum SpectrumScale: String, Codable, Equatable, Sendable { case mel, log, lin }
