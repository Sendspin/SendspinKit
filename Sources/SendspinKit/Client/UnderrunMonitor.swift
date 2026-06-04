// ABOUTME: Pure decision logic for underrun-driven operational-state reporting
// ABOUTME: Maps telemetry underrun counts to synchronized/error transitions with hysteresis

/// Decides when buffer underruns should move the client between `synchronized`
/// and `error` (per spec §Playback Synchronization).
///
/// Pure value type so the policy is testable without timing or audio hardware.
/// Hysteresis is deliberately asymmetric — error on the first underrun, recovery
/// only after `recoveryTicks` clean ticks — to keep `client/state` from flapping.
struct UnderrunMonitor {
    enum Transition: Equatable {
        case none
        case toError
        case toSynchronized
    }

    /// Clean ticks required to recover. At the telemetry loop's 500 ms poll, `2` ≈ 1 s.
    private let recoveryTicks: Int
    private var lastUnderrunCount: Int64 = 0
    private var cleanTicks = 0
    private var inError = false

    init(recoveryTicks: Int = 2) {
        self.recoveryTicks = max(1, recoveryTicks)
    }

    /// Whether the monitor raised the current `error`, so the caller doesn't clear
    /// an error it didn't set (e.g. a codec failure).
    var isTrackingError: Bool {
        inError
    }

    /// The count resets to zero on a new stream, so a decrease counts as clean.
    mutating func observe(underrunCount: Int64) -> Transition {
        defer { lastUnderrunCount = underrunCount }

        if underrunCount > lastUnderrunCount {
            cleanTicks = 0
            guard !inError else { return .none }
            inError = true
            return .toError
        }

        guard inError else { return .none }
        cleanTicks += 1
        guard cleanTicks >= recoveryTicks else { return .none }
        cleanTicks = 0
        inError = false
        return .toSynchronized
    }

    /// Re-baseline and drop any tracked error without emitting a transition, for
    /// when the client isn't participating in playback (external source).
    mutating func resetBaseline(underrunCount: Int64) {
        lastUnderrunCount = underrunCount
        cleanTicks = 0
        inError = false
    }
}
