// ABOUTME: Configuration for player role capabilities
// ABOUTME: Specifies buffer capacity, supported audio formats, and volume control mode

import Foundation

/// How the player handles volume and mute commands from the server.
public enum VolumeMode: Sendable {
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

    public init(
        bufferCapacity: Int,
        supportedFormats: [AudioFormatSpec],
        initialStaticDelayMs: Int = 0,
        volumeMode: VolumeMode = .software
    ) {
        precondition(bufferCapacity > 0, "Buffer capacity must be positive")
        precondition(!supportedFormats.isEmpty, "Must support at least one audio format")
        precondition(initialStaticDelayMs >= 0 && initialStaticDelayMs <= 5000,
                     "initialStaticDelayMs must be 0-5000")

        self.bufferCapacity = bufferCapacity
        self.supportedFormats = supportedFormats
        self.initialStaticDelayMs = initialStaticDelayMs
        self.volumeMode = volumeMode
    }
}
