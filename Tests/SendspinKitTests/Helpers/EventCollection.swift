// ABOUTME: Bounded async event collection helpers for tests
// ABOUTME: Prevents test hangs when expected connection events are not emitted

import Foundation
@testable import SendspinKit

func collectConnectionEvent(
    from connection: SendspinConnection,
    timeout: Duration = .seconds(2),
    where predicate: @escaping @Sendable (ConnectionEvent) -> Bool
) async -> ConnectionEvent? {
    let result: Result<ConnectionEvent?, Error>? = await outcomeOfUnstructuredOperation(timeout: timeout) {
        for await event in connection.events where predicate(event) {
            return event
        }
        return nil
    }
    return try? result?.get()
}

/// Bounded await for a matching public `ClientEvent`. Mirrors
/// `collectConnectionEvent` so facade-level tests never park forever on an event
/// that is never emitted. Returns `nil` on timeout.
func collectClientEvent(
    from stream: AsyncStream<ClientEvent>,
    timeout: Duration = .seconds(3),
    where predicate: @escaping @Sendable (ClientEvent) -> Bool
) async -> ClientEvent? {
    let result: Result<ClientEvent?, Error>? = await outcomeOfUnstructuredOperation(timeout: timeout) {
        for await event in stream where predicate(event) {
            return event
        }
        return nil
    }
    return try? result?.get()
}

func collectConnectionEvents(
    from connection: SendspinConnection,
    until shouldStop: @escaping @Sendable ([ConnectionEvent]) -> Bool,
    timeout: Duration = .seconds(2)
) async -> [ConnectionEvent] {
    let result = await outcomeOfUnstructuredOperation(timeout: timeout) {
        var events: [ConnectionEvent] = []
        for await event in connection.events {
            events.append(event)
            if shouldStop(events) {
                return events
            }
        }
        return events
    }
    return (try? result?.get()) ?? []
}
