// ABOUTME: JSON encoding utilities for the Sendspin wire format
// ABOUTME: Provides a configured encoder factory for transport implementations

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
}
