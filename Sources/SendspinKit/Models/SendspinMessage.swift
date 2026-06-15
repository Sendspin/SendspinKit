import Foundation

/// Base protocol for all Sendspin messages.
///
/// Every message has a `type` field identifying it and a `payload` with
/// message-specific data. Concrete types declare a `static let typeString = "..."`
/// constant (the wire-level discriminator) and derive `let type = Self.typeString`
/// so callers and tests can refer to the wire string without instantiating a
/// message. A private `CodingKeys` enum keeps the field round-tripping through JSON.
///
/// Concrete message types also conform to `Equatable` for testing and
/// deduplication, but `Equatable` is deliberately not required here to
/// avoid constraining future message types that may carry non-equatable payloads.
///
/// Note: a protocol extension default (`var type: String { Self.typeString }`) would
/// look like it removes the per-type `let type = Self.typeString` line, but `type`
/// must stay a stored property — Swift's synthesized `Codable` keys off stored
/// properties, so making `type` computed would force a hand-written
/// `encode(to:)`/`init(from:)` on every concrete type. The one-line derivation is
/// the minimal cost of keeping synthesized Codable; don't "simplify" it away.
protocol SendspinMessage: Codable, Sendable {
    /// The wire `type` field for this message kind. Static so test and
    /// production code can compare against it (`SendspinEncoding.messageType(of:)
    /// == ClientStateMessage.typeString`) without constructing a sample message.
    static var typeString: String { get }
    var type: String { get }
}
