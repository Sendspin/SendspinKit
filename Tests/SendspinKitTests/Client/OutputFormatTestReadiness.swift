import Foundation
import Testing

func requireOutputCondition(
    _ label: String,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let ready = try await runUnstructuredWithDeadline(.seconds(2), label: label) {
        await waitUntil(timeout: .seconds(1), condition)
    }
    try #require(ready, Comment(rawValue: label))
}
