import Foundation

/// Default required lead time in milliseconds for audio buffering.
/// Accounts for AudioQueue setup latency and codec warmup (typically 50-100ms).
/// Sent to the server in the `client/state` player object.
public let defaultRequiredLeadTimeMs: Int = 100

/// Default minimum buffer size in milliseconds for smooth playback.
/// Accounts for scheduler jitter and prebuffering (typically 200-500ms).
/// Sent to the server in the `client/state` player object.
public let defaultMinBufferMs: Int = 500

/// Maximum output delay in milliseconds. Server-provided and local `setOutputDelay`
/// values are clamped to `0...maxOutputDelayMs` rather than trusted blindly.
public let maxOutputDelayMs: Int = 5_000

/// Controls how the player's supported sample-rate formats are ordered against the
/// current output route. The policy never invents formats or changes the application's
/// codec, channel, or bit-depth choices.
public enum OutputSampleRatePolicy: String, Sendable, Hashable, Codable, CaseIterable {
    /// Preserve `supportedFormats` exactly as supplied by the application.
    case preserveFormatOrder

    /// Prefer formats whose sample rate matches the current output route while
    /// retaining all other supplied formats as fallback choices.
    case preferCurrentOutput

    /// Advertise only formats whose sample rate matches the current output route.
    /// The session fails before hello if the route is unknown or no supplied format matches.
    case requireCurrentOutput
}

/// Why a policy could not produce an effective supported-format catalog.
public enum OutputFormatError: SendspinError, Hashable, LocalizedError {
    /// The output route did not provide a trustworthy sample rate.
    case routeUnavailable
    /// No application-supplied format matches the current output sample rate.
    case noMatchingFormat

    public var errorDescription: String? {
        switch self {
        case .routeUnavailable:
            "The current audio output sample rate is unavailable"
        case .noMatchingFormat:
            "No supported audio format matches the current output sample rate"
        }
    }
}

/// Resolves an application catalog against an advisory output sample rate.
///
/// The transformation is pure so normal and competing handshakes can share the
/// same result. Relative order is preserved within every resulting group.
func effectiveSupportedFormats(
    _ formats: [AudioFormatSpec],
    policy: OutputSampleRatePolicy,
    outputSampleRate: Int?
) throws(OutputFormatError) -> [AudioFormatSpec] {
    switch policy {
    case .preserveFormatOrder:
        return formats
    case .preferCurrentOutput:
        guard let outputSampleRate else { return formats }
        let matching = formats.filter { $0.sampleRate == outputSampleRate }
        guard !matching.isEmpty else { return formats }
        let fallback = formats.filter { $0.sampleRate != outputSampleRate }
        return matching + fallback
    case .requireCurrentOutput:
        guard let outputSampleRate else { throw .routeUnavailable }
        let matching = formats.filter { $0.sampleRate == outputSampleRate }
        guard !matching.isEmpty else { throw .noMatchingFormat }
        return matching
    }
}

/// An advisory snapshot of the current audio output route.
///
/// A `nil` sample rate means the platform could not provide a trustworthy value.
/// The reported bit depth and description are diagnostic only and do not identify
/// a route or guarantee the physical endpoint's representation.
public struct AudioOutputSnapshot: Sendable, Hashable {
    /// The output route's nominal sample rate in hertz, when trustworthy.
    public let sampleRate: Int?

    /// A diagnostic bit depth reported by the platform, when available.
    public let reportedBitDepth: Int?

    /// Transient, non-localized diagnostic text about the output route.
    public let diagnosticDescription: String?

    public init(
        sampleRate: Int?,
        reportedBitDepth: Int?,
        diagnosticDescription: String?
    ) {
        self.sampleRate = sampleRate
        self.reportedBitDepth = reportedBitDepth
        self.diagnosticDescription = diagnosticDescription
    }
}

/// The output route and the current state of sample-rate format negotiation.
public struct OutputFormatStatus: Sendable, Hashable {
    /// The output snapshot against which ``state`` was determined.
    public let output: AudioOutputSnapshot

    /// The current format-negotiation state.
    public let state: State

    public init(output: AudioOutputSnapshot, state: State) {
        self.output = output
        self.state = state
    }

    /// A structurally valid state in output-format selection or playback.
    public enum State: Sendable, Hashable {
        /// The output sample rate is unavailable.
        case outputUnknown
        /// No application-supplied format matches the output sample rate.
        case noMatchingFormat
        /// The format preferred for the current output route.
        case preferred(AudioFormatSpec)
        /// A format change has been requested from the server.
        case requesting(AudioFormatSpec)
        /// The active stream matches the output's native sample rate.
        case activeNative(AudioFormatSpec)
        /// The active stream uses a non-native fallback sample rate.
        case activeFallback(AudioFormatSpec)
    }
}

/// Host-reported activation state for platforms whose audio session is application-owned.
public enum AudioSessionActivationState: Sendable, Hashable {
    case unknown
    case inactive
    case active
}

/// How the player handles volume and mute commands from the server.
public enum VolumeMode: Sendable, Hashable {
    /// Software volume via AudioQueue gain (works everywhere).
    /// Always advertises `volume` and `mute` in `supported_commands`.
    case software

    /// Hardware volume via CoreAudio device properties (macOS only).
    /// Queries the current output device for volume/mute capability at startup
    /// and only advertises commands the hardware supports.
    /// Falls back to `.software` on platforms without CoreAudio device control.
    case hardware

    /// No volume control — the device is fixed-volume (e.g. line-out to an
    /// external amplifier that handles its own volume). Does not advertise
    /// `volume` or `mute` in `supported_commands`.
    case none
}

/// Bound on `server/hello` arrival after a transport opens.
///
/// The spec sets no bound. This matches the budget multi-server arbitration applies to
/// its own handshake, so both paths give a server the same grace.
let defaultHandshakeTimeout: Duration = .seconds(5)

/// Configuration for player role
public struct PlayerConfiguration: Sendable {
    /// Buffer capacity in bytes
    public let bufferCapacity: Int

    /// Supported audio formats in application priority order.
    ///
    /// ``outputSampleRatePolicy`` may stably reorder or filter this catalog against
    /// the current output route for the session's `client/hello`.
    public let supportedFormats: [AudioFormatSpec]

    /// Controls how ``supportedFormats`` is matched to the current output sample rate.
    public let outputSampleRatePolicy: OutputSampleRatePolicy

    /// Initial output delay in milliseconds (0-5000).
    /// Per spec: compensates for delay beyond the audio port (external speakers,
    /// amplifiers). The host app is responsible for persisting this value across
    /// reboots — pass the last-known value here on startup. The server may change
    /// it at runtime via `server/command`; listen for `.outputDelayChanged` events.
    ///
    /// **Design note:** The spec says "clients must persist output_delay_ms locally
    /// across reboots." That persistence belongs in the host app, NOT in this library.
    /// Different apps store settings differently (UserDefaults, Core Data, files, etc.)
    /// and may persist per-output-device delays. The library's job is to accept the
    /// initial value, apply it, and notify the app when the server changes it.
    public let initialOutputDelayMs: Int

    /// How the player handles volume/mute commands.
    /// Defaults to `.software` which uses AudioQueue gain and always advertises
    /// volume/mute support to the server.
    public let volumeMode: VolumeMode

    /// Optional callback invoked on the audio thread with the final PCM buffer
    /// before each chunk is played. Use this for local visualization (VU meters,
    /// waveform displays) or to apply real-time audio effects.
    ///
    /// See ``AudioProcessCallback`` for threading constraints and parameter details.
    public let processCallback: AudioProcessCallback?

    /// When `true`, the client emits ``AudioChunk`` values on ``SendspinClient/audioChunks``
    /// for every audio binary message received from the server.
    ///
    /// The `data` payload contains the raw bytes exactly as received — PCM samples
    /// for PCM streams, encoded FLAC frames for FLAC streams. Useful for conformance
    /// testing, recording, or analysis.
    ///
    /// Defaults to `false` to avoid unnecessary work in normal playback scenarios.
    public let emitRawAudioEvents: Bool

    /// Required lead time in milliseconds.
    /// Accounts for AudioQueue setup and codec warmup latency.
    /// Defaults to 100ms. Must be >= 0.
    public let requiredLeadTimeMs: Int

    /// Minimum buffer size in milliseconds.
    /// Accounts for scheduler jitter and prebuffering to avoid underruns.
    /// Defaults to 500ms. Must be >= 0.
    public let minBufferMs: Int

    public init(
        bufferCapacity: Int,
        supportedFormats: [AudioFormatSpec],
        initialOutputDelayMs: Int = 0,
        volumeMode: VolumeMode = .software,
        processCallback: AudioProcessCallback? = nil,
        emitRawAudioEvents: Bool = false,
        requiredLeadTimeMs: Int = defaultRequiredLeadTimeMs,
        minBufferMs: Int = defaultMinBufferMs,
        outputSampleRatePolicy: OutputSampleRatePolicy = .preferCurrentOutput
    ) throws(ConfigurationError) {
        guard bufferCapacity > 0 else { throw .nonPositiveBufferCapacity }
        guard !supportedFormats.isEmpty else { throw .emptySupportedFormats }
        guard initialOutputDelayMs >= 0, initialOutputDelayMs <= maxOutputDelayMs else {
            throw .outputDelayOutOfRange(initialOutputDelayMs)
        }
        guard requiredLeadTimeMs >= 0 else { throw .negativeRequiredLeadTime(requiredLeadTimeMs) }
        guard minBufferMs >= 0 else { throw .negativeMinBuffer(minBufferMs) }

        self.bufferCapacity = bufferCapacity
        self.supportedFormats = supportedFormats
        self.initialOutputDelayMs = initialOutputDelayMs
        self.volumeMode = volumeMode
        self.processCallback = processCallback
        self.emitRawAudioEvents = emitRawAudioEvents
        self.requiredLeadTimeMs = requiredLeadTimeMs
        self.minBufferMs = minBufferMs
        self.outputSampleRatePolicy = outputSampleRatePolicy
    }
}
