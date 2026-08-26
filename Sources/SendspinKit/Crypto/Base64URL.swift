import Foundation

/// Base64url (RFC 4648 §5) without padding — the encoding the Sendspin spec uses for
/// identities (`client_id`/`server_id`), `psk_id` values, PSKs, and Noise handshake
/// payloads.
enum Base64URL {
    /// Encode bytes as base64url with no `=` padding.
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode a base64url string. Strict: only the URL-safe alphabet is accepted —
    /// no padding, no standard-alphabet `+`/`/`, no whitespace. The wire form is
    /// always unpadded, so anything else is malformed input, not a variant spelling.
    static func decode(_ string: String) -> Data? {
        guard string.utf8.allSatisfy(isBase64URLCharacter) else { return nil }
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        // A single leftover character can never form a valid base64 quantum.
        if remainder == 1 {
            return nil
        }
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }

    /// Decode a base64url string that must yield exactly `count` bytes.
    static func decode(_ string: String, count: Int) -> Data? {
        guard let data = decode(string), data.count == count else { return nil }
        return data
    }

    private static func isBase64URLCharacter(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"),
             UInt8(ascii: "a") ... UInt8(ascii: "z"),
             UInt8(ascii: "0") ... UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "_"):
            true
        default:
            false
        }
    }
}
