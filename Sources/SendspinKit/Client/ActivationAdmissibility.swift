import Foundation

/// How the client must respond to a `server/activate`.
enum ActivationVerdict: Equatable, Sendable {
    /// Admissible: apply the activities and roles.
    case admit
    /// Close the connection with `client/goodbye` carrying this reason.
    case close(GoodbyeReason)
    /// Reply `pair/abort` reason `method_not_supported`, leaving the connection open.
    case abortPairing
}

/// The spec's `server/activate` admissibility rules: which activity sets each
/// matched-PSK category allows, the playback-capable constraint on `active_roles`,
/// and the response-selection order for inadmissible activations. Pure functions —
/// the connection supplies live state and applies the verdict.
enum ActivationAdmissibility {
    /// The PSK-category × activity-set table.
    static func isAllowedSet(
        _ activities: Set<Activity>,
        category: PskCategory,
        unpairedAccessEnabled: Bool
    ) -> Bool {
        switch category {
        case .longTerm:
            activities.isEmpty || activities == [.playback]
        case .pairing:
            activities == [.pairing]
        case .sentinel:
            activities.isEmpty
                || activities == [.pairing]
                || (activities == [.playback] && unpairedAccessEnabled)
        }
    }

    /// A connection is playback-capable when its activities extended with
    /// `playback` form an allowed set. Only such a connection may carry a
    /// non-empty `active_roles`.
    static func isPlaybackCapable(
        _ activities: Set<Activity>,
        category: PskCategory,
        unpairedAccessEnabled: Bool
    ) -> Bool {
        isAllowedSet(
            activities.union([.playback]),
            category: category,
            unpairedAccessEnabled: unpairedAccessEnabled
        )
    }

    /// Session-fixed inputs to admissibility: the matched PSK category plus the
    /// live pairing configuration (which may have drifted from `client/hello`).
    struct SessionContext: Sendable {
        let category: PskCategory
        let unpairedAccessEnabled: Bool
        let offeredPairMethods: Set<String>
        let offeredDynamicFormats: Set<String>

        init(
            category: PskCategory,
            unpairedAccessEnabled: Bool,
            offeredPairMethods: Set<String>,
            offeredDynamicFormats: Set<String> = []
        ) {
            self.category = category
            self.unpairedAccessEnabled = unpairedAccessEnabled
            self.offeredPairMethods = offeredPairMethods
            self.offeredDynamicFormats = offeredDynamicFormats
        }
    }

    /// Evaluate one `server/activate` against the session context. `activeRoles`
    /// are the resolved roles — payload roles, or the persisted set when the
    /// payload omits them — already filtered to roles this client listed.
    static func evaluate(
        activities: Set<Activity>,
        activeRoles: Set<VersionedRole>,
        pairing: PairingDirective?,
        session: SessionContext
    ) -> ActivationVerdict {
        let category = session.category
        let unpairedAccessEnabled = session.unpairedAccessEnabled
        let offeredPairMethods = session.offeredPairMethods
        let offeredDynamicFormats = session.offeredDynamicFormats
        func admissible(unpairedAccess: Bool) -> Bool {
            guard isAllowedSet(activities, category: category, unpairedAccessEnabled: unpairedAccess)
            else { return false }
            if !activeRoles.isEmpty,
               !isPlaybackCapable(activities, category: category, unpairedAccessEnabled: unpairedAccess) {
                return false
            }
            // source@v1 is forbidden at trust level 'none'; this client never
            // advertises source, and roles are filtered to advertised ones upstream,
            // so no explicit check is needed here.
            if activities.contains(.pairing) {
                guard let pairing, pairingMethodAcceptable(pairing) else { return false }
            }
            return true
        }

        func pairingMethodAcceptable(_ pairing: PairingDirective) -> Bool {
            // Pairing PSK is restricted to its dedicated PSK; code methods use
            // sentinel or long-term sessions.
            let methodAllowedForCategory: Bool = if pairing.method == PairMethod.pairingPsk {
                category == .pairing
            } else if pairing.method == PairMethod.dynamicPairingCode || pairing.method == PairMethod.staticPairingCode {
                category == .sentinel
            } else {
                false
            }
            guard methodAllowedForCategory,
                  offeredPairMethods.contains(pairing.method)
            else { return false }
            if pairing.method == PairMethod.dynamicPairingCode {
                guard let format = pairing.format, offeredDynamicFormats.contains(format) else { return false }
            } else {
                guard pairing.format == nil else { return false }
            }
            return true
        }

        if admissible(unpairedAccess: unpairedAccessEnabled) {
            return .admit
        }

        // Response selection, first rule that applies:
        // 1. Sentinel session where enabling unpaired access would make this
        //    admissible → the operator's fix is pairing.
        if category == .sentinel, !unpairedAccessEnabled, admissible(unpairedAccess: true) {
            return .close(.pairingRequired)
        }
        // 2. Disallowed activity set, or roles on a non-playback-capable connection.
        if !isAllowedSet(activities, category: category, unpairedAccessEnabled: unpairedAccessEnabled) {
            return .close(.unauthorized)
        }
        if !activeRoles.isEmpty,
           !isPlaybackCapable(activities, category: category, unpairedAccessEnabled: unpairedAccessEnabled) {
            return .close(.unauthorized)
        }
        // 3. Only the pairing directive can be at fault now: disallowed or
        //    unoffered method/format → abort, connection stays open.
        return .abortPairing
    }
}

/// Multi-server admission between an admitted connection and an incoming one,
/// ranked by highest declared activity from each connection's `server/activate`.
enum MultiServerAdmission {
    enum Decision: Equatable, Sendable {
        /// Keep the existing connection; the incoming gets `concurrent_attempt`.
        case keepExisting
        /// Admit the incoming; the existing gets `another_server`.
        case acceptIncoming
    }

    /// One side of an admission decision.
    struct Candidate: Sendable {
        let serverId: String
        let activities: Set<Activity>
        /// An in-progress pairing attempt is never displaced by an incoming
        /// playback or pairing connection.
        var isPairingAttempt = false
    }

    static func arbitrate(
        incoming: Candidate,
        existing: Candidate,
        lastPlaybackServerId: String?
    ) -> Decision {
        let incomingRank = Activity.rank(of: incoming.activities)
        let existingRank = Activity.rank(of: existing.activities)

        if existing.isPairingAttempt, incomingRank <= Activity.playback.rank {
            return .keepExisting
        }
        // Both empty: the last-playback server reclaims its client, and only from a
        // holder that is not itself the last-playback server.
        if incomingRank == 0, existingRank == 0 {
            let incomingIsLastPlayback = incoming.serverId == lastPlaybackServerId
            let existingIsLastPlayback = existing.serverId == lastPlaybackServerId
            return incomingIsLastPlayback && !existingIsLastPlayback ? .acceptIncoming : .keepExisting
        }
        return incomingRank >= existingRank ? .acceptIncoming : .keepExisting
    }
}
