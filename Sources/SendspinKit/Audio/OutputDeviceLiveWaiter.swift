import os

final class OutputDeviceLiveWaiter: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Never>?
        var completed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        let completed = state.withLock { state in
            if state.completed {
                return true
            }
            state.continuation = continuation
            return false
        }
        if completed {
            continuation.resume()
        }
    }

    func resume() {
        let continuation = state.withLock { state in
            state.completed = true
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}
