import Foundation

final class HeldOutputRequestDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var waits: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelled: Set<UUID> = []

    func sleep(_ duration: Duration) async throws {
        guard duration > .zero else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if cancelled.remove(id) != nil || Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waits[id] = continuation
                    }
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Error>? = self.lock.withLock {
                if let continuation = self.waits.removeValue(forKey: id) {
                    return continuation
                }
                self.cancelled.insert(id)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}
