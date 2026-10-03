import Foundation

/// Synchronous ingress barrier for route-invalidated compressed chunks.
///
/// Invalidation drops ingress; it never owns a second queue. The route command opens a new
/// epoch atomically with its FIFO enqueue, so chunks already in flight cannot cross the format
/// boundary while chunks after the command retain normal sink ordering.
final class AudioRouteInvalidationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var invalidated = false

    func invalidate() {
        lock.lock()
        epoch &+= 1
        invalidated = true
        lock.unlock()
    }

    func enqueueChunk(data: Data, timestamp: Int64, to sink: DataPlaneSink) {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated else { return }
        sink.enqueue(.chunkAtRouteEpoch(data, ts: timestamp, epoch: epoch))
    }

    func enqueueStreamStart(
        format: AudioFormatSpec,
        codecHeader: Data?,
        startGeneration: UInt64,
        to sink: DataPlaneSink
    ) {
        lock.lock()
        epoch &+= 1
        invalidated = false
        sink.enqueue(.streamStart(format, codecHeader: codecHeader, startGeneration: startGeneration))
        lock.unlock()
    }

    func enqueueStreamEnd(roles: [String]?, to sink: DataPlaneSink) {
        lock.lock()
        epoch &+= 1
        invalidated = true
        sink.enqueue(.streamEnd(roles: roles))
        lock.unlock()
    }

    func clear() {
        lock.lock()
        epoch &+= 1
        invalidated = false
        lock.unlock()
    }

    func enqueueRouteInvalidatedFormatChange(
        format: AudioFormatSpec,
        codecHeader: Data?,
        startGeneration: UInt64,
        to sink: DataPlaneSink
    ) {
        lock.lock()
        epoch &+= 1
        invalidated = false
        let routeEpoch = epoch
        sink.enqueue(.withStartGeneration(startGeneration, .formatChangeRouteInvalidated(format, codecHeader: codecHeader, epoch: routeEpoch)))
        lock.unlock()
    }

    func isCurrent(epoch candidate: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return candidate == epoch
    }

    func isInvalidated() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidated
    }
}

/// The engine policy for a mid-stream format transition.
enum AudioFormatTransitionPolicy: Sendable {
    /// Keep wire-ordered PCM and switch hardware at the render boundary.
    case ordered

    /// The route invalidated the old PCM; drop it and rebuild the output now.
    case routeInvalidated
}

/// Commands that flow from the message loop (MainActor) to the AudioEngine.
///
/// Each command represents a unit of work the engine processes: starting/stopping
/// a stream, scheduling a chunk of audio, changing format, or adjusting settings.
/// The `DataPlaneSink` enforces FIFO ordering and depth accounting via an `AsyncStream.Continuation`.
enum DataPlaneCommand: Sendable {
    /// Start a new audio stream with the given format and optional codec header.
    case streamStart(AudioFormatSpec, codecHeader: Data?, startGeneration: UInt64 = 0)
    indirect case withStartGeneration(UInt64, DataPlaneCommand)

    /// Schedule a chunk of PCM audio for playback at the given server timestamp (microseconds).
    case chunk(Data, ts: Int64)

    /// Route-epoch-tagged compressed chunk. The epoch is checked before and after decoding.
    case chunkAtRouteEpoch(Data, ts: Int64, epoch: UInt64)

    /// Generation-tagged audio chunk with measurement-only send-ahead.
    case chunkAtGenerationWithSendAhead(Data, ts: Int64, sendAhead: UInt32, generation: UInt64)

    /// Clear buffered audio for the given roles (nil = all roles).
    case streamClear(roles: [String]?)

    /// End the audio stream, truncating unplayed audio for the given roles (nil = all roles).
    case streamEnd(roles: [String]?)

    /// Change format mid-stream; bare use is test-only, production uses withStartGeneration.
    case formatChange(AudioFormatSpec, codecHeader: Data?)

    /// Change format after the current output route invalidated queued PCM.
    case formatChangeRouteInvalidated(AudioFormatSpec, codecHeader: Data?, epoch: UInt64)

    /// Change format at an explicitly announced input generation.
    case formatChangeAtGeneration(AudioFormatSpec, codecHeader: Data?, generation: UInt64)

    /// Set output delay in milliseconds (subtracted from local scheduled play times).
    case setOutputDelay(Int)
}

/// Payload-free tag for a DataPlaneCommand, used to record apply order without retaining audio Data.
enum DataPlaneCommandKind {
    case streamStart
    case chunk
    case streamClear
    case streamEnd
    case formatChange
    case routeInvalidatedFormatChange
    case setOutputDelay
}

extension DataPlaneCommand {
    /// Returns the payload-free kind/tag of this command.
    ///
    /// Used by tests to assert processing order without retaining audio data.
    nonisolated var kind: DataPlaneCommandKind {
        switch self {
        case let .withStartGeneration(_, command):
            command.kind
        case .streamStart:
            .streamStart
        case .chunk, .chunkAtRouteEpoch, .chunkAtGenerationWithSendAhead:
            .chunk
        case .streamClear:
            .streamClear
        case .streamEnd:
            .streamEnd
        case .formatChange, .formatChangeAtGeneration:
            .formatChange
        case .formatChangeRouteInvalidated:
            .routeInvalidatedFormatChange
        case .setOutputDelay:
            .setOutputDelay
        }
    }
}

/// Report emitted by the AudioEngine upward to the client for lifecycle and state transitions.
enum EngineReport {
    /// Audio stream started successfully with the applied format.
    case started(AudioFormatSpec, startGeneration: UInt64 = 0)

    /// Format change applied mid-stream.
    case formatApplied(AudioFormatSpec, startGeneration: UInt64 = 0)

    /// Operational state transition (includes full bidirectional state: synchronized, error, externalSource).
    case operationalState(EngineSyncState)

    /// Audio start failed; the stream could not begin.
    case startFailed(reason: String, startGeneration: UInt64 = 0)
}
