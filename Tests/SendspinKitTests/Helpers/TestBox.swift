import Foundation

/// A single mutable `Sendable` value isolated behind an actor.
///
/// Tests frequently need a tiny, race-free observation point — "did this happen
/// yet?", "how many chunks have arrived?", "what was the last value seen?" —
/// from code that runs outside the test's own isolation. Hand-rolling one
/// purpose-built `actor` per observation is noise; this generic captures the
/// pattern once.
///
/// Read via `await box.value`. Mutate via `await box.update { $0 = ... }` so
/// callers can compute the new value from the old without a separate get/set
/// round-trip race.
actor TestBox<Value: Sendable> {
    private(set) var value: Value

    init(_ initialValue: Value) {
        value = initialValue
    }

    /// Mutate the value in place. The closure runs synchronously inside the actor.
    func update(_ transform: @Sendable (inout Value) -> Void) {
        transform(&value)
    }

    /// Convenience: set without reading.
    func set(_ newValue: Value) {
        value = newValue
    }
}
