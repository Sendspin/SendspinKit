// ABOUTME: Protocol abstracting audio output for testability
// ABOUTME: Allows AudioEngine to work with mock or real AudioPlayer

import Foundation

/// Protocol for audio output, abstracting the methods that AudioEngine calls on AudioPlayer.
///
/// This allows the engine to be tested in isolation with a mock `SpyAudioOutput` or `StubAudioOutput`,
/// avoiding the MainActor and real AudioQueue hardware.
protocol AudioOutput: Actor, Sendable {
    /// Whether audio is currently being played.
    var isPlaying: Bool { get }

    /// Current telemetry snapshot (underrun count, sync correction state, etc).
    var telemetrySnapshot: AudioPlayer.TelemetrySnapshot { get }

    /// Start playback with the given format and optional codec header.
    /// Throws if the AudioQueue cannot be initialized or audio playback cannot begin.
    func start(format: AudioFormatSpec, codecHeader: Data?) throws

    /// Stop playback. Safe to call even if not playing.
    func stop()

    /// Swap the decoder for seamless format transitions.
    /// Called before chunks in the new format arrive.
    func swapDecoder(format: AudioFormatSpec, codecHeader: Data?) throws

    /// Decode a chunk of encoded audio into PCM.
    /// Throws if decoding fails.
    func decode(_ data: Data) async throws -> Data

    /// Queue a PCM chunk for playback at the given server timestamp.
    /// Throws if playback cannot continue (e.g., underrun recovery failing).
    func playPCM(_ pcm: Data, serverTimestamp: Int64) throws

    /// Clear buffered PCM without stopping playback (for stream clear or seek).
    func clearBuffer()

    /// Set playback volume (0.0 = silent, 1.0 = full).
    func setVolume(_ gain: Float)

    /// Set mute state.
    func setMute(_ muted: Bool)

    /// Update the time snapshot for sync correction (called per server/time).
    /// This is the per-server/time cross-boundary push that drives sync correction.
    func updateTimeSnapshot(_ snapshot: TimeFilterSnapshot)

    /// Poll for reanchor requests from the audio callback.
    /// Returns the target server time if a reanchor is pending, clears the flag, and returns nil otherwise.
    func pollReanchor() -> Int64?

    /// Reanchor the playback cursor to a specific server time position.
    func reanchorCursor(to: Int64)
}
