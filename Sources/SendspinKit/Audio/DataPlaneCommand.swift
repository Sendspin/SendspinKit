import Foundation

/// Commands that flow from the message loop (MainActor) to the AudioEngine.
///
/// Each command represents a unit of work the engine processes: starting/stopping
/// a stream, scheduling a chunk of audio, changing format, or adjusting settings.
/// The `DataPlaneSink` enforces FIFO ordering and depth accounting via an `AsyncStream.Continuation`.
enum DataPlaneCommand {
    /// Start a new audio stream with the given format and optional codec header.
    case streamStart(AudioFormatSpec, codecHeader: Data?)

    /// Schedule a chunk of PCM audio for playback at the given server timestamp (microseconds).
    case chunk(Data, ts: Int64)

    /// Clear buffered audio for the given roles (nil = all roles).
    case streamClear(roles: [String]?)

    /// End the audio stream, truncating unplayed audio for the given roles (nil = all roles).
    case streamEnd(roles: [String]?)

    /// Change format mid-stream (seamless format swap).
    case formatChange(AudioFormatSpec, codecHeader: Data?)

    /// Set static delay in milliseconds (subtracted from scheduled timestamps).
    case setStaticDelay(Int)
}

/// Payload-free tag for a DataPlaneCommand, used to record apply order without retaining audio Data.
enum DataPlaneCommandKind {
    case streamStart
    case chunk
    case streamClear
    case streamEnd
    case formatChange
    case setStaticDelay
}

extension DataPlaneCommand {
    /// Returns the payload-free kind/tag of this command.
    ///
    /// Used by tests to assert processing order without retaining audio data.
    nonisolated var kind: DataPlaneCommandKind {
        switch self {
        case .streamStart:
            .streamStart
        case .chunk:
            .chunk
        case .streamClear:
            .streamClear
        case .streamEnd:
            .streamEnd
        case .formatChange:
            .formatChange
        case .setStaticDelay:
            .setStaticDelay
        }
    }
}

/// Report emitted by the AudioEngine upward to the client for lifecycle and state transitions.
enum EngineReport {
    /// Audio stream started successfully with the applied format.
    case started(AudioFormatSpec)

    /// Format change applied mid-stream.
    case formatApplied(AudioFormatSpec)

    /// Operational state transition (includes full bidirectional state: synchronized, error, externalSource).
    case operationalState(ClientOperationalState)

    /// Audio start failed; the stream could not begin.
    case startFailed(reason: String)
}
