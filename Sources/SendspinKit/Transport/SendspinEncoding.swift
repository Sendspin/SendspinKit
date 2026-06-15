import Foundation

/// Sendspin wire format encoding utilities.
/// Used by transport implementations to avoid duplicating encoder configuration.
enum SendspinEncoding {
    /// Create a JSON encoder configured for the Sendspin wire format (snake_case keys).
    ///
    /// **Call once and store** as a `let` property on the actor. Do not call per-message
    /// — that defeats the purpose of reuse. Do not pass the returned encoder across
    /// isolation boundaries (JSONEncoder is a mutable reference type, not Sendable).
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    /// The `type` tag of a wire frame, read without decoding the payload.
    ///
    /// Every Sendspin frame is `{ "type": "...", "payload": {...} }`. Callers MUST
    /// read this tag and dispatch on it *before* decoding the concrete message: each
    /// message's `type` is a `let` constant the synthesized decoder leaves untouched,
    /// and payloads are all-optional, so any frame decodes "successfully" as the wrong
    /// type. The wire tag is the only reliable discriminator.
    static func messageType(of data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["type"] as? String
    }
}
