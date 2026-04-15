// ABOUTME: Defines versioned roles for Sendspin protocol negotiation
// ABOUTME: Roles use format "role@version" (e.g., "player@v1") for capability negotiation

/// Versioned role identifier for Sendspin protocol.
///
/// Format: `"role@version"` (e.g., `"player@v1"`, `"metadata@v1"`).
/// Per spec, role names and versions not starting with `_` are reserved for the
/// specification. Custom roles use the `_` prefix (e.g., `"_myapp_display@v1"`).
public struct VersionedRole: Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    /// Role name (e.g., "player", "metadata", "artwork").
    public let role: String
    /// Version string (e.g., "v1", "v2").
    public let version: String

    /// Full role identifier (e.g., "player@v1").
    public var identifier: String {
        "\(role)@\(version)"
    }

    /// Splits a `"role@version"` string on the first `@`.
    /// Returns `nil` if there is no `@` or if either component is empty.
    private static func parse(_ value: String) -> (role: String, version: String)? {
        guard let atIndex = value.firstIndex(of: "@") else { return nil }
        let role = String(value[value.startIndex ..< atIndex])
        let version = String(value[value.index(after: atIndex)...])
        guard !role.isEmpty, !version.isEmpty else { return nil }
        return (role, version)
    }

    public init(role: String, version: String) {
        precondition(!role.isEmpty, "Role name must not be empty")
        precondition(!version.isEmpty, "Version must not be empty")
        precondition(!role.contains("@"), "Role name must not contain '@'")
        self.role = role
        self.version = version
    }

    /// Creates a versioned role from a string literal.
    ///
    /// If the string contains a valid `"role@version"` format, it's split
    /// into role and version. If no `@` is present, the version defaults
    /// to `"v1"` for convenience in Swift code. Malformed strings (empty,
    /// leading/trailing `@`) are programmer errors and trap.
    ///
    /// Wire-format parsing uses `init(from:)` which throws instead of trapping.
    public init(stringLiteral value: String) {
        if let parsed = Self.parse(value) {
            role = parsed.role
            version = parsed.version
        } else {
            precondition(!value.isEmpty, "Role string literal must not be empty")
            precondition(!value.contains("@"), "Malformed role literal '\(value)' — use 'role@version' format")
            role = value
            version = "v1"
        }
    }

    /// Decodes a versioned role from a JSON string.
    ///
    /// Requires the `"role@version"` format per spec. Unlike `init(stringLiteral:)`,
    /// this does not default missing versions — a malformed string is non-compliant.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let parsed = Self.parse(value) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Role must be in 'role@version' format with non-empty components, got '\(value)'"
                )
            )
        }
        role = parsed.role
        version = parsed.version
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(identifier)
    }

    // MARK: - Spec-defined roles

    /// Player role — outputs audio.
    public static let playerV1 = VersionedRole(role: "player", version: "v1")
    /// Controller role — controls the current Sendspin group.
    public static let controllerV1 = VersionedRole(role: "controller", version: "v1")
    /// Metadata role — displays text metadata describing the currently playing audio.
    public static let metadataV1 = VersionedRole(role: "metadata", version: "v1")
    /// Artwork role — displays artwork images.
    public static let artworkV1 = VersionedRole(role: "artwork", version: "v1")
    /// Visualizer role — visualizes audio.
    public static let visualizerV1 = VersionedRole(role: "visualizer", version: "v1")
}
