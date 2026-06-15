import Foundation
import os

/// A `Sendable` token guarding binary event emission from a retired connection.
///
/// When a connection is retired (reconnect/shutdown), the validity token is atomically
/// invalidated. Any binary event from a stale connection that attempts to emit via
/// `yieldIfValid(_:to:)` will be silently dropped.
///
/// The critical operation is `yieldIfValid(_:to:)`: it atomically checks validity and
/// yields the event under a single lock, closing the race window that would otherwise
/// leak a stale event between a separate `isValid` check and a bare `yield`.
final class SessionValidityToken: Sendable {
    private let lock: OSAllocatedUnfairLock<Bool>

    /// Create a new token in the valid state.
    init() {
        lock = OSAllocatedUnfairLock(initialState: true)
    }

    /// Atomically invalidate this token (idempotent).
    func invalidate() {
        lock.withLock { $0 = false }
    }

    /// Query current validity (snapshot; may become invalid between check and use).
    ///
    /// Intended for testing and diagnostics. Do not use for the emit path —
    /// use `yieldIfValid(_:to:)` instead.
    var isValid: Bool {
        lock.withLock { $0 }
    }

    /// Atomically check validity and run a synchronous action in one critical section.
    ///
    /// Use this for non-`AsyncStream` side effects that must obey the same stale-session
    /// contract as binary event emission. The action must be brief, non-suspending, and
    /// must not re-enter this token.
    @MainActor
    func performIfValid(_ action: @MainActor @Sendable () -> Void) {
        lock.withLock { isValidNow in
            guard isValidNow else { return }
            MainActor.assumeIsolated {
                action()
            }
        }
    }

    /// Atomically check validity and yield the event in one critical section.
    ///
    /// This is the only method for emitting binary events. Under the lock, it
    /// checks `isValid` and, only if true, calls `continuation.yield(event)`.
    /// Both operations happen atomically, preventing the facade from invalidating
    /// the token between the check and the yield.
    ///
    /// `yield` is non-blocking and does not re-enter the token, so the lock hold
    /// is brief and safe.
    func yieldIfValid<Element: Sendable>(
        _ element: Element,
        to continuation: AsyncStream<Element>.Continuation
    ) {
        lock.withLock { isValidNow in
            guard isValidNow else { return }
            continuation.yield(element)
        }
    }
}
