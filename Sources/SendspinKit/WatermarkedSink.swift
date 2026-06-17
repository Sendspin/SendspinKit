import Foundation
import os

/// Ordered, unbounded sink for elements sent from a producer to a single draining consumer.
///
/// Thread-safe via `OSAllocatedUnfairLock`; each method (`enqueue`, `decrementDepth`, `finish`)
/// is a single critical section. The sink tracks element depth for diagnostic high-watermark
/// warnings and enforces FIFO ordering via the paired `AsyncStream<Element>`.
///
/// Names are deliberately spec-neutral: "stream" and "command" carry specific meanings in the
/// Sendspin protocol, so specializations re-introduce domain vocabulary via constrained
/// extensions (see `DataPlaneSink` and `ControlEventSink`).
///
/// **Atomicity guarantee:** The finished-check, yield, yield-result inspection,
/// and depth increment are one atomic operation under the lock — a racing `finish()` will either
/// prevent the enqueue entirely (no increment, no yield) or let it succeed before the finish takes effect.
final class WatermarkedSink<Element: Sendable>: Sendable {
    /// High-watermark threshold for depth-based warnings (in elements, not bytes).
    let highWatermark: Int

    /// Hook for rate-limited high-watermark warnings.
    private let onWarning: @Sendable (String) -> Void

    /// Guarded state: depth counter, finished flag, and armed flag for rate-limiting
    private struct State {
        var depth: Int = 0
        var finished: Bool = false
        var armed: Bool = true
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let (stream, continuation) = AsyncStream<Element>.makeStream()

    /// Initializes the sink with a watermark threshold and a warning hook.
    /// - Parameters:
    ///   - highWatermark: Depth above which (strictly) a rate-limited warning fires.
    ///   - onWarning: Closure called when depth crosses the high watermark.
    init(highWatermark: Int, onWarning: @escaping @Sendable (String) -> Void) {
        self.highWatermark = highWatermark
        self.onWarning = onWarning
    }

    /// The `AsyncStream` the single consumer drains.
    nonisolated var elements: AsyncStream<Element> {
        stream
    }

    /// Enqueues an element if the sink is not finished.
    ///
    /// Under the lock: if finished, returns immediately (no-op). Otherwise, yields the element
    /// and inspects the `YieldResult` — only increments depth on `.enqueued`, sets finished on `.terminated`,
    /// and never increments on `.dropped`. If post-increment depth crosses the watermark and armed,
    /// captures a rate-limited warning and clears armed. Invokes the warning hook after releasing the lock.
    func enqueue(_ element: Element) {
        // Captured under the lock, invoked after release: a custom `onWarning` hook
        // that re-enters this sink (e.g. enqueues again) must not deadlock on the
        // non-reentrant unfair lock. Mirrors `FrameInbox`, which resumes its
        // continuation outside the critical section.
        let warning: String? = lock.withLock { state in
            guard !state.finished else { return nil }

            // Yield the element and inspect the result while holding the lock.
            // Only `.enqueued` mutates depth and can trip the watermark; the
            // other cases are pure state updates with no warning path.
            switch continuation.yield(element) {
            case .enqueued:
                state.depth += 1
                // Warn strictly above, re-arm strictly below (decrementDepth): the
                // width-1 dead band at == watermark makes hovering there one
                // excursion — one warning, no flapping. Deliberate hysteresis.
                guard state.depth > highWatermark, state.armed else { return nil }
                state.armed = false
                return "depth \(state.depth) exceeds high watermark \(highWatermark)"

            case .terminated:
                // Stream is terminated; mark as finished but don't increment.
                state.finished = true
                return nil

            case .dropped:
                // Should not happen for an unbounded AsyncStream, but handle it.
                return nil

            @unknown default:
                return nil
            }
        }

        if let warning {
            onWarning(warning) // invoked outside the lock to stay reentrancy-safe
        }
    }

    /// Decrements the depth counter by one, re-arming for the next watermark crossing.
    ///
    /// Under the lock: decrements depth (protected by `max(0, …)`), and re-arms if depth
    /// drops below the watermark. Continues to apply even after `finish()` — buffered elements
    /// still drain `depth` to zero during shutdown.
    func decrementDepth() {
        lock.withLock { state in
            state.depth = max(0, state.depth - 1)

            // Re-arm once we drop back below the watermark
            if state.depth < highWatermark {
                state.armed = true
            }
        }
    }

    /// Terminates the sink: prevents further enqueues and finishes the continuation.
    ///
    /// Under the lock: sets finished and calls `continuation.finish()`. Subsequent enqueues become no-ops.
    /// Does not stop decrement accounting — the consumer drains buffered elements, each calling `decrementDepth`.
    func finish() {
        lock.withLock { state in
            state.finished = true
            continuation.finish()
        }
    }

    /// The current element depth (buffered elements awaiting decrement).
    nonisolated var depth: Int {
        lock.withLock { $0.depth }
    }
}
