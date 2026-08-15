import Foundation

/// No-op audio output that does nothing.
/// Used when the client doesn't have the player role but still needs an AudioEngine
/// to own the audio scheduler and command/report streams.
actor NoOpAudioOutput: AudioOutput {
    var isPlaying: Bool {
        false
    }

    var telemetrySnapshot: AudioPlayer.TelemetrySnapshot {
        AudioPlayer.TelemetrySnapshot(
            cursorMicroseconds: 0,
            sampleRate: 0,
            syncErrorUs: 0,
            correctionSchedule: CorrectionSchedule(),
            underrunCount: 0,
            pcmBytesDropped: 0,
            startupOffsetUs: nil,
            spinUpUs: -1,
            startupPadFrames: 0,
            framesConsumed: 0,
            silentBuffers: 0,
            enqueueFailures: 0,
            peakOutputLevel: 0,
            appliedVolume: 0,
            queueGain: -1,
            deviceVolume: -1,
            deviceMuted: false,
            framesInFlight: 0
        )
    }

    func prepare(format _: AudioFormatSpec, codecHeader _: Data?) throws {}

    func startPrepared() throws {}

    func pipelineLatencyMicroseconds() -> Int64 {
        0
    }

    func startupLeadMicroseconds() -> Int64 {
        0
    }

    /// No device to wait for.
    func waitUntilOutputDeviceIsLive() async throws {}

    func start(format _: AudioFormatSpec, codecHeader _: Data?) throws {}

    func stop() {}

    func swapDecoder(format _: AudioFormatSpec, codecHeader _: Data?) throws {}

    func decode(_ data: Data) async throws -> Data {
        data
    }

    func playPCM(_: Data, serverTimestamp _: Int64) async throws {}

    func clearBuffer() {}

    func setVolume(_: Float) {}

    func setMute(_: Bool) {}

    func updateTimeSnapshot(_: TimeFilterSnapshot) {}

    func pollReanchor() -> Int64? {
        nil
    }

    func reanchorCursor(to _: Int64) {}
}
