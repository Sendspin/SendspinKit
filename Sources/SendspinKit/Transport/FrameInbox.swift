import Foundation
import os

/// Ordered, unbounded, single-consumer inbox of `TransportFrame`s.
///
/// The producer side (`yield`/`finish`) is synchronous, nonisolated, and thread-safe:
/// frames enqueue in call order with no task hop, so wire order is preserved exactly —
/// which is why a transport's receive callback can feed it directly. The consumer side
/// (`next()`) is single-consumer: callers must never overlap pulls. A second `next()`
/// that finds a parked predecessor traps; a caller that nonetheless overlaps pulls where
/// none parks (a buffered frame or `finish()` is already pending) is undefined use, not a
/// supported mode. Once `finish()` is observed, `next()` returns `nil` forever.
///
/// This replaces an `AsyncStream` plus a stored `AsyncIterator`. A `mutating` iterator's
/// `next()` cannot be driven across an actor suspension under Swift 6 exclusivity — the
/// sole reason transports otherwise reach for `nonisolated(unsafe)`. A parked continuation
/// has no such constraint, so conformers forward to this and stay free of unsafe opt-outs.
final class FrameInbox: Sendable {
    private struct State {
        var buffer: [TransportFrame] = []
        /// Read cursor into `buffer`; advanced by `next()`, compacted when it catches up.
        var head = 0
        var finished = false
        /// A consumer parked waiting for a frame. Non-nil only when `buffer` is drained.
        /// Its presence is also the single-consumer guard: a second `next()` that observes
        /// a parked waiter is an overlapping call and traps.
        var waiter: CheckedContinuation<TransportFrame?, Never>?
    }

    /// `uncheckedState` because `State` holds a non-`Sendable` `CheckedContinuation`. The
    /// lock is the synchronization: the continuation is stored and extracted only under it,
    /// and resumed only after the lock is released, so it never escapes unsynchronized.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    private enum Pull {
        case resume(TransportFrame?)
        case parked
    }

    /// Enqueue a frame. Synchronous, nonisolated, thread-safe, FIFO. No-op after `finish()`.
    func yield(_ frame: TransportFrame) {
        let waiter: CheckedContinuation<TransportFrame?, Never>? = state.withLock { state in
            guard !state.finished else { return nil }
            if let waiter = state.waiter {
                // A parked consumer hands off directly; the buffer is empty here.
                state.waiter = nil
                return waiter
            }
            state.buffer.append(frame)
            return nil
        }
        waiter?.resume(returning: frame) // resume outside the lock
    }

    /// Terminate the inbox. Idempotent. Unblocks a parked consumer with `nil`.
    func finish() {
        let waiter: CheckedContinuation<TransportFrame?, Never>? = state.withLock { state in
            guard !state.finished else { return nil }
            state.finished = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil) // resume outside the lock
    }

    /// Pull the next frame, or `nil` once finished. Single-consumer: callers must never
    /// overlap pulls; a second call that finds a parked predecessor traps.
    ///
    /// Cancellation is deliberately not this primitive's release mechanism. The owner
    /// of the transport/session must call `finish()` (usually via `disconnect()`) to
    /// unblock a parked pull. Keeping that policy out of this mailbox avoids coupling
    /// task-cancellation races to queue correctness.
    func next() async -> TransportFrame? {
        await withCheckedContinuation { (continuation: CheckedContinuation<TransportFrame?, Never>) in
            let action: Pull = state.withLock { state in
                precondition(
                    state.waiter == nil,
                    "FrameInbox.next() is single-consumer; a second pull while one is parked is a contract violation"
                )
                if state.head < state.buffer.count {
                    let frame = state.buffer[state.head]
                    state.head += 1
                    if state.head == state.buffer.count {
                        // keepingCapacity pins only array slots (~tens of bytes per
                        // frame) — each Data payload releases on removal, so bursts
                        // pin KBs, not MBs. Deliberate: avoids realloc churn.
                        state.buffer.removeAll(keepingCapacity: true)
                        state.head = 0
                    }
                    return .resume(frame)
                }
                if state.finished { return .resume(nil) }
                state.waiter = continuation
                return .parked
            }
            if case let .resume(frame) = action { continuation.resume(returning: frame) }
        }
    }
}
