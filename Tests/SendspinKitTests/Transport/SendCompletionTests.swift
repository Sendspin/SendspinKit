// ABOUTME: Deterministic unit tests for SendCompletion's three-way race semantics
// ABOUTME: Covers NW completion / timeout / cancellation interleavings without needing a live NWConnection

import Foundation
@testable import SendspinKit
import Testing

/// Iterations for the concurrent-producer race test. High enough that a
/// double-resume or lock-resume reentrancy would reliably surface.
private let raceTestIterations = 200

/// `SendCompletion` coordinates the three-way race between Network.framework's
/// `send` completion callback, our timeout task, and task cancellation. The
/// integration tests cover the happy path through a live NWConnection; these
/// tests exercise the race directly so the lock-discipline invariants are
/// validated independently of NW timing.
///
/// Invariants under test:
/// 1. First `complete(...)` wins; later callers are no-ops.
/// 2. A `complete(...)` that lands before `install(...)` is replayed when the
///    continuation arrives.
/// 3. `isCompleted` flips synchronously with the first `complete(...)`.
/// 4. Concurrent producers cannot double-resume the continuation.
struct SendCompletionTests {
    // MARK: - Invariant 1: first-wins

    @Test("complete called twice resumes the continuation exactly once")
    func firstCompleteWins() async {
        let completion = SendCompletion()
        let outcome = await awaitOutcome(completion) {
            // First contender wins; the second would crash a checked continuation
            // if SendCompletion let it through.
            completion.complete(with: .failure(TransportError.sendTimedOut))
            completion.complete(with: .failure(TransportError.notConnected))
            completion.complete(with: .success(()))
        }
        guard case let .failure(error) = outcome, let transport = error as? TransportError else {
            Issue.record("expected sendTimedOut, got \(outcome)")
            return
        }
        #expect(transport == .sendTimedOut, "first complete(...) must be the delivered one")
    }

    // MARK: - Invariant 2: complete-before-install is replayed

    @Test("a result stored before install() is resumed when install arrives")
    func completeBeforeInstallReplays() async {
        let completion = SendCompletion()
        // Cover the complete-before-install replay path: fire the result first,
        // then install. The install must replay it immediately. This is the same
        // shape as the canonical onCancel-before-installation window, exercised
        // deterministically.
        completion.complete(with: .failure(TransportError.sendTimedOut))
        #expect(completion.isCompleted, "complete(...) must flip isCompleted synchronously")

        let outcome = await awaitOutcome(completion) {
            // install() already happened inside awaitOutcome; nothing more to do.
        }
        guard case let .failure(error) = outcome, let transport = error as? TransportError else {
            Issue.record("expected sendTimedOut replay, got \(outcome)")
            return
        }
        #expect(transport == .sendTimedOut, "install() must replay the stored result")
    }

    // MARK: - Invariant 3: isCompleted flips synchronously

    @Test("isCompleted is false before any complete() and true immediately after")
    func isCompletedFlipsSynchronously() {
        let completion = SendCompletion()
        #expect(completion.isCompleted == false, "fresh SendCompletion must report not completed")
        completion.complete(with: .success(()))
        #expect(completion.isCompleted, "complete(...) must flip isCompleted synchronously")
    }

    // MARK: - Invariant 4: cross-isolation producer/consumer race

    /// Models the production shape: a parked continuation in one task, two
    /// independent producers racing in others. Repeats many iterations to
    /// surface any held-lock or ordering bug. The pre-fix shape (resuming the
    /// continuation under the lock) would crash if the lock-resume re-entered;
    /// the current shape (resume after lock release) must come out clean.
    @Test("concurrent producers never double-resume the continuation")
    func concurrentProducersDoNotDoubleResume() async {
        for _ in 0 ..< raceTestIterations {
            let completion = SendCompletion()
            let outcome = await awaitOutcome(completion) {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { completion.complete(with: .success(())) }
                    group.addTask { completion.complete(with: .failure(TransportError.sendTimedOut)) }
                }
            }
            // The awaited result must be one of the two; we don't assert which.
            switch outcome {
            case .success:
                break
            case let .failure(error):
                if let transport = error as? TransportError, transport == .sendTimedOut {
                    break
                }
                Issue.record("unexpected error from race: \(error)")
            }
        }
    }
}

// MARK: - Test helper

/// Install a continuation on `completion`, run `producer` to drive completion,
/// and report the outcome as a `Result`. The producer is invoked SYNCHRONOUSLY
/// inside `withCheckedThrowingContinuation`, before the continuation suspends —
/// matching the `timedSend` shape where the timeout task and NW completion are
/// both armed inside the continuation's body.
private func awaitOutcome(
    _ completion: SendCompletion,
    producer: @escaping @Sendable () async -> Void
) async -> Result<Void, Error> {
    do {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            completion.install(continuation)
            // The producer is non-throwing; we wrap it in a detached Task because
            // withCheckedThrowingContinuation's body is non-async. Production code
            // never has to do this — `timedSend` runs producers via the surrounding
            // task; here we synthesize that surrounding context for the test.
            Task { await producer() }
        }
        return .success(())
    } catch {
        return .failure(error)
    }
}
