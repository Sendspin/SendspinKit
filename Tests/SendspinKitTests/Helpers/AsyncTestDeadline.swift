import Foundation

/// Error thrown when a deadline helper times out before observing an operation's result.
struct AsyncTestDeadlineError: Error, CustomStringConvertible {
    let label: String
    let deadline: Duration

    var description: String {
        "\(label) did not complete within \(deadline)"
    }
}

/// The observed state of an unstructured task or operation.
enum DeadlineObservation<Value: Sendable> {
    case completed(Value)
    case timedOut
}

/// Poll `condition` until it returns `true` or the deadline passes.
/// Returns the final evaluation so callers can assert positively or negatively.
func waitUntil(
    timeout: Duration = .seconds(2),
    pollInterval: Duration = .milliseconds(10),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: pollInterval)
    }
    return await condition()
}

/// Run an async operation with a deadline without relying on child-task cancellation.
///
/// Use this when `operation` may park in a non-cancellable continuation (`NWConnection`,
/// `FrameInbox.next()`, checked continuations, etc.). This deliberately uses an
/// unstructured `Task` plus actor-backed outcome polling, not `withTaskGroup`, because
/// task groups wait for children before returning. If the operation ignores cancellation,
/// a task-group timeout can still wedge the test process.
///
/// On timeout, the helper cancels the task as best effort, runs `onTimeout` so the caller
/// can close the resource that unblocks it, and throws ``AsyncTestDeadlineError`` without
/// awaiting the parked task.
func runUnstructuredWithDeadline<Value: Sendable>(
    _ deadline: Duration,
    label: String,
    pollInterval: Duration = .milliseconds(10),
    onTimeout: @escaping @Sendable () async -> Void = {},
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let result = await outcomeOfUnstructuredOperation(
        timeout: deadline,
        pollInterval: pollInterval,
        onTimeout: onTimeout,
        operation: operation
    )

    guard let result else {
        throw AsyncTestDeadlineError(label: label, deadline: deadline)
    }

    return try result.get()
}

/// Run an async operation with a deadline and return its terminal result, or `nil` on timeout.
///
/// This is the non-throwing/probe variant of ``runUnstructuredWithDeadline``. Use it when
/// the test wants to assert on success vs. failure vs. timeout explicitly.
func outcomeOfUnstructuredOperation<Value: Sendable>(
    timeout: Duration,
    pollInterval: Duration = .milliseconds(10),
    onTimeout: @escaping @Sendable () async -> Void = {},
    operation: @escaping @Sendable () async throws -> Value
) async -> Result<Value, Error>? {
    let outcome = TestBox<Result<Value, Error>?>(nil)

    let task = Task {
        do {
            let value = try await operation()
            await outcome.set(.success(value))
        } catch {
            await outcome.set(.failure(error))
        }
    }

    let completed = await waitUntil(timeout: timeout, pollInterval: pollInterval) {
        await outcome.value != nil
    }

    guard completed else {
        task.cancel()
        await onTimeout()
        return nil
    }

    return await outcome.value
}

/// Observe an existing task's value with a deadline, without awaiting it on timeout.
///
/// The returned enum distinguishes a task that completed with an optional `nil` value from a
/// task that never completed. This matters for calls like `Task { await inbox.next() }`, where
/// `nil` is the successful terminal value after stream finish.
func observeTask<Value: Sendable>(
    _ task: Task<Value, Never>,
    timeout: Duration,
    pollInterval: Duration = .milliseconds(10),
    onTimeout: @escaping @Sendable () async -> Void = {}
) async -> DeadlineObservation<Value> {
    let observation = TestBox<DeadlineObservation<Value>?>(nil)

    Task {
        let value = await task.value
        await observation.set(.completed(value))
    }

    let completed = await waitUntil(timeout: timeout, pollInterval: pollInterval) {
        await observation.value != nil
    }

    guard completed, let observed = await observation.value else {
        task.cancel()
        await onTimeout()
        return .timedOut
    }

    return observed
}
