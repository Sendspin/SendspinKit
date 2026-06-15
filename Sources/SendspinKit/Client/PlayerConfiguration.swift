/// Default required lead time in milliseconds for audio buffering.
/// Accounts for AudioQueue setup latency and codec warmup (typically 50-100ms).
/// This is sent to the server in client/state per spec §485.
public let defaultRequiredLeadTimeMs: Int = 100

/// Default minimum buffer size in milliseconds for smooth playback.
/// Accounts for scheduler jitter and prebuffering (typically 200-500ms).
/// This is sent to the server in client/state per spec §486.
public let defaultMinBufferMs: Int = 500

/// Maximum static delay in milliseconds. Server-provided and local `setStaticDelay`
/// values are clamped to `0...maxStaticDelayMs` rather than trusted blindly.
public let maxStaticDelayMs: Int = 5_000

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

/// Configuration for player role
public struct PlayerConfiguration: Sendable {
    /// Buffer capacity in bytes
    public let bufferCapacity: Int

    /// Supported audio formats in priority order
    public let supportedFormats: [AudioFormatSpec]

    /// Initial static delay in milliseconds (0-5000).
    /// Per spec: compensates for delay beyond the audio port (external speakers,
    /// amplifiers). The host app is responsible for persisting this value across
    /// reboots — pass the last-known value here on startup. The server may change
    /// it at runtime via `server/command`; listen for `.staticDelayChanged` events.
    ///
    /// **Design note:** The spec says "clients must persist static_delay_ms locally
    /// across reboots." That persistence belongs in the host app, NOT in this library.
    /// Different apps store settings differently (UserDefaults, Core Data, files, etc.)
    /// and may persist per-output-device delays. The library's job is to accept the
    /// initial value, apply it, and notify the app when the server changes it.
    public let initialStaticDelayMs: Int

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

    /// Required lead time in milliseconds (spec §485).
    /// Accounts for AudioQueue setup and codec warmup latency.
    /// Defaults to 100ms. Must be >= 0.
    public let requiredLeadTimeMs: Int

    /// Minimum buffer size in milliseconds (spec §486).
    /// Accounts for scheduler jitter and prebuffering to avoid underruns.
    /// Defaults to 500ms. Must be >= 0.
    public let minBufferMs: Int

    public init(
        bufferCapacity: Int,
        supportedFormats: [AudioFormatSpec],
        initialStaticDelayMs: Int = 0,
        volumeMode: VolumeMode = .software,
        processCallback: AudioProcessCallback? = nil,
        emitRawAudioEvents: Bool = false,
        requiredLeadTimeMs: Int = defaultRequiredLeadTimeMs,
        minBufferMs: Int = defaultMinBufferMs
    ) throws(ConfigurationError) {
        guard bufferCapacity > 0 else { throw .nonPositiveBufferCapacity }
        guard !supportedFormats.isEmpty else { throw .emptySupportedFormats }
        guard initialStaticDelayMs >= 0, initialStaticDelayMs <= maxStaticDelayMs else {
            throw .staticDelayOutOfRange(initialStaticDelayMs)
        }
        guard requiredLeadTimeMs >= 0 else { throw .negativeRequiredLeadTime(requiredLeadTimeMs) }
        guard minBufferMs >= 0 else { throw .negativeMinBuffer(minBufferMs) }

        self.bufferCapacity = bufferCapacity
        self.supportedFormats = supportedFormats
        self.initialStaticDelayMs = initialStaticDelayMs
        self.volumeMode = volumeMode
        self.processCallback = processCallback
        self.emitRawAudioEvents = emitRawAudioEvents
        self.requiredLeadTimeMs = requiredLeadTimeMs
        self.minBufferMs = minBufferMs
    }
}
