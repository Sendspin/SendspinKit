import Foundation

/// A server purpose declared on a connection via `server/activate`. Multi-server
/// admission ranks connections by their highest-ranked declared activity.
public enum Activity: String, Codable, Sendable, Hashable, CaseIterable {
    case playback
    case pairing
    case management

    /// Rank for multi-server admission: management > playback > pairing; a
    /// connection with empty activities ranks below all three.
    var rank: Int {
        switch self {
        case .management: 3
        case .playback: 2
        case .pairing: 1
        }
    }

    static func rank(of activities: Set<Activity>) -> Int {
        activities.map(\.rank).max() ?? 0
    }
}

/// `server/activate` — declares the server's current purpose on this connection.
/// The first one gates all other client messages; later ones may change the
/// activity set or roles at any time.
struct ServerActivateMessage: SendspinMessage, Equatable {
    static let typeString = "server/activate"
    let type = Self.typeString
    let payload: ServerActivatePayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ServerActivatePayload: Codable, Equatable, Sendable {
    let activities: [Activity]
    /// Versioned roles active for this client. Required on the first activate;
    /// persists across later activates that omit it. `nil` means "keep persisted".
    let activeRoles: [VersionedRole]?
    /// Parameters of the pairing attempt this activation admits. Ignored when
    /// `activities` does not include `pairing`.
    let pairing: PairingDirective?

    enum CodingKeys: String, CodingKey {
        case activities
        case activeRoles = "active_roles"
        case pairing
    }

    init(activities: [Activity], activeRoles: [VersionedRole]?, pairing: PairingDirective? = nil) {
        self.activities = activities
        self.activeRoles = activeRoles
        self.pairing = pairing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activities = try container.decode([Activity].self, forKey: .activities)
        // Skip unparseable role entries rather than failing the whole activate —
        // same forward-compat rationale as server/hello's old role handling: one
        // future-shaped role string must not cost every role we do understand.
        if let rawRoles = try container.decodeIfPresent([String].self, forKey: .activeRoles) {
            activeRoles = rawRoles.compactMap(VersionedRole.init(identifier:))
        } else {
            activeRoles = nil
        }
        pairing = try container.decodeIfPresent(PairingDirective.self, forKey: .pairing)
    }
}

/// The `pairing` object inside `server/activate`. `method` and `format` stay
/// strings: an unknown method must be *rejectable* (`pair/abort
/// method_not_supported`), not a decode failure.
struct PairingDirective: Codable, Equatable, Sendable {
    let method: String
    let format: String?
    let languages: [String]?

    init(method: String, format: String? = nil, languages: [String]? = nil) {
        self.method = method
        self.format = format
        self.languages = languages
    }
}

/// Pairing method identifiers as they appear on the wire.
enum PairMethod {
    static let pairingPsk = "pairing_psk"
    static let dynamicPairingCode = "dynamic_pairing_code"
    static let staticPairingCode = "static_pairing_code"
}
