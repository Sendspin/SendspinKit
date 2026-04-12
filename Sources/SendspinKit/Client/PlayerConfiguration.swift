// ABOUTME: Configuration for player role capabilities
// ABOUTME: Specifies buffer capacity and supported audio formats

import Foundation

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

    public init(bufferCapacity: Int, supportedFormats: [AudioFormatSpec], initialStaticDelayMs: Int = 0) {
        precondition(bufferCapacity > 0, "Buffer capacity must be positive")
        precondition(!supportedFormats.isEmpty, "Must support at least one audio format")
        precondition(initialStaticDelayMs >= 0 && initialStaticDelayMs <= 5000,
                     "initialStaticDelayMs must be 0-5000")

        self.bufferCapacity = bufferCapacity
        self.supportedFormats = supportedFormats
        self.initialStaticDelayMs = initialStaticDelayMs
    }
}
