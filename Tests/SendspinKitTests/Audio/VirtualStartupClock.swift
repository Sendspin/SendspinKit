// ABOUTME: Drives startup deadlines independently of wall-clock scheduling.
// ABOUTME: Keeps server mapping, release selection, and deadline sleeps on one time base.
import Foundation
import os
@testable import SendspinKit

final class VirtualStartupClock: Sendable {
    let anchor = MonotonicClock.absoluteMicroseconds()
    private let time: OSAllocatedUnfairLock<Int64>
    private let gate = SleepGate()

    init() {
        time = OSAllocatedUnfairLock(initialState: anchor)
    }

    func now() -> Int64 {
        time.withLock { $0 }
    }

    /// Advance runs only after gated sleeps are released so sleepers observe every clock change.
    func advance(to timestamp: Int64) {
        time.withLock { $0 = max($0, anchor + timestamp) }
    }

    func sleep(_ duration: Duration) async throws {
        await gate.wait()
        try Task.checkCancellation()
        let components = duration.components
        let microseconds = components.seconds * 1_000_000 + components.attoseconds / 1_000_000_000_000
        // The final approach advances with the sleep, so the yield loop observes its target
        // without requiring polling to move virtual time.
        time.withLock { $0 += microseconds + AudioEngine.startupSpinThresholdUs }
    }

    func releaseSleeps() async {
        await gate.release()
    }

    private actor SleepGate {
        private var released = false
        private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

        func wait() async {
            guard !released else { return }
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled || released {
                        continuation.resume()
                    } else {
                        waiters[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        private func cancel(_ id: UUID) {
            waiters.removeValue(forKey: id)?.resume()
        }

        func release() {
            released = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending.values {
                waiter.resume()
            }
        }
    }
}
