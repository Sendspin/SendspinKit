import Foundation
@testable import SendspinKit
import Testing

@Suite("Activation admissibility")
struct ActivationAdmissibilityTests {
    /// Shorthand: evaluate with no roles, no pairing directive, nothing offered.
    private func verdict(
        _ activities: Set<Activity>,
        roles: Set<VersionedRole> = [],
        pairing: PairingDirective? = nil,
        category: PskCategory,
        unpairedAccess: Bool = true,
        offered: Set<String> = []
    ) -> ActivationVerdict {
        ActivationAdmissibility.evaluate(
            activities: activities,
            activeRoles: roles,
            pairing: pairing,
            session: ActivationAdmissibility.SessionContext(
                category: category,
                unpairedAccessEnabled: unpairedAccess,
                offeredPairMethods: offered,
                offeredDynamicFormats: offered.contains(PairMethod.dynamicPairingCode) ? [PairingCodeFormat.digits.rawValue] : []
            )
        )
    }

    @Test("Long-term PSK allows exactly empty or playback activity")
    func longTermAllowedSets() {
        #expect(verdict([], category: .longTerm) == .admit)
        #expect(verdict([.playback], category: .longTerm) == .admit)
        #expect(verdict([.pairing], category: .longTerm) == .close(.unauthorized))
        #expect(verdict([.playback, .pairing], category: .longTerm) == .close(.unauthorized))
    }

    @Test("Pairing PSK allows exactly ['pairing']")
    func pairingPskAllowedSets() {
        let directive = PairingDirective(method: PairMethod.pairingPsk)
        #expect(
            verdict([.pairing], pairing: directive, category: .pairing, offered: [PairMethod.pairingPsk])
                == .admit
        )
        #expect(verdict([], category: .pairing) == .close(.unauthorized))
        #expect(verdict([.playback], category: .pairing) == .close(.unauthorized))
        #expect(verdict([.pairing, .playback], pairing: directive, category: .pairing) == .close(.unauthorized))
    }

    @Test("Sentinel allows empty, pairing, and — only with unpaired access — playback")
    func sentinelAllowedSets() {
        #expect(verdict([], category: .sentinel, unpairedAccess: false) == .admit)
        #expect(verdict([.playback], category: .sentinel, unpairedAccess: true) == .admit)
        #expect(verdict([.playback, .pairing], category: .sentinel) == .close(.unauthorized))
    }

    @Test("Sentinel admits an offered dynamic digits activation")
    func sentinelAdmitsOfferedDigits() {
        // Mutating the sentinel branch to reject all pairing directives makes this fail.
        #expect(
            verdict(
                [.pairing],
                pairing: PairingDirective(method: PairMethod.dynamicPairingCode, format: PairingCodeFormat.digits.rawValue),
                category: .sentinel,
                offered: [PairMethod.dynamicPairingCode]
            ) == .admit
        )
    }

    @Test("Pairing PSK category rejects a code method")
    func pairingPskRejectsCodeMethod() {
        // Mutating the category guard from `== .sentinel` to `!= .pairing` admits this invalid method.
        #expect(
            verdict(
                [.pairing],
                pairing: PairingDirective(method: PairMethod.dynamicPairingCode, format: PairingCodeFormat.digits.rawValue),
                category: .pairing,
                offered: [PairMethod.dynamicPairingCode]
            ) == .abortPairing
        )
    }

    @Test("pairing_required is chosen exactly when enabling unpaired access would admit")
    func pairingRequiredSelection() {
        // The spec's worked example: sentinel, unpaired access disabled.
        #expect(
            verdict(
                [.playback],
                roles: [.playerV1],
                category: .sentinel,
                unpairedAccess: false
            ) == .close(.pairingRequired)
        )
        // No unpaired-access setting admits a mixed activity set on sentinel.
        #expect(
            verdict(
                [.playback, .pairing],
                category: .sentinel,
                unpairedAccess: false
            ) == .close(.unauthorized)
        )
    }

    @Test("Non-empty active_roles require a playback-capable connection")
    func rolesRequirePlaybackCapability() {
        // Empty activities on a long-term PSK are playback-capable → roles fine.
        #expect(verdict([], roles: [.playerV1], category: .longTerm) == .admit)
        // A pairing activation is never playback-capable → roles are unauthorized.
        let directive = PairingDirective(method: PairMethod.pairingPsk)
        #expect(
            verdict(
                [.pairing],
                roles: [.playerV1],
                pairing: directive,
                category: .pairing,
                offered: [PairMethod.pairingPsk]
            ) == .close(.unauthorized)
        )
    }

    @Test("Unoffered or category-mismatched pairing methods abort, connection open")
    func pairingMethodSelection() {
        // Offered but wrong category: pairing_psk on a sentinel session.
        #expect(
            verdict(
                [.pairing],
                pairing: PairingDirective(method: PairMethod.pairingPsk),
                category: .sentinel,
                offered: [PairMethod.pairingPsk]
            ) == .abortPairing
        )
        // Right category, method not offered (live config drift).
        #expect(
            verdict(
                [.pairing],
                pairing: PairingDirective(method: PairMethod.pairingPsk),
                category: .pairing,
                offered: []
            ) == .abortPairing
        )
        // Code method on a pairing-PSK session is a category mismatch.
        #expect(
            verdict(
                [.pairing],
                pairing: PairingDirective(method: PairMethod.dynamicPairingCode, format: "digits"),
                category: .pairing,
                offered: [PairMethod.dynamicPairingCode]
            ) == .abortPairing
        )
        // Code methods are Sentinel-only; a long-term session cannot enter pairing.
        #expect(
            verdict(
                [.pairing],
                pairing: PairingDirective(method: PairMethod.staticPairingCode),
                category: .longTerm,
                offered: [PairMethod.staticPairingCode]
            ) == .close(.unauthorized)
        )
        // Missing directive on a pairing activation cannot name an offered method.
        #expect(verdict([.pairing], category: .sentinel) == .abortPairing)
        #expect(
            verdict(
                [.pairing],
                pairing: PairingDirective(method: PairMethod.dynamicPairingCode, format: PairingCodeFormat.qrCode.rawValue),
                category: .sentinel,
                offered: [PairMethod.dynamicPairingCode]
            ) == .abortPairing
        )
        #expect(
            ActivationAdmissibility.evaluate(
                activities: [.pairing],
                activeRoles: [],
                pairing: PairingDirective(method: PairMethod.dynamicPairingCode, format: "digits"),
                session: ActivationAdmissibility.SessionContext(
                    category: .sentinel,
                    unpairedAccessEnabled: true,
                    offeredPairMethods: [PairMethod.dynamicPairingCode],
                    offeredDynamicFormats: ["qr_code"]
                )
            ) == .abortPairing
        )
    }

    @Test("A pairing directive is ignored when 'pairing' is not in activities")
    func pairingDirectiveIgnoredOutsidePairing() {
        #expect(
            verdict(
                [.playback],
                pairing: PairingDirective(method: "bogus"),
                category: .longTerm
            ) == .admit
        )
    }
}

@Suite("Multi-server admission ranking")
struct MultiServerAdmissionTests {
    private func arbitrate(
        incoming: Set<Activity>,
        existing: Set<Activity>,
        incomingId: String = "incoming",
        existingId: String = "existing",
        lastPlayback: String? = nil,
        existingIsPairingAttempt: Bool = false
    ) -> MultiServerAdmission.Decision {
        MultiServerAdmission.arbitrate(
            incoming: MultiServerAdmission.Candidate(serverId: incomingId, activities: incoming),
            existing: MultiServerAdmission.Candidate(
                serverId: existingId,
                activities: existing,
                isPairingAttempt: existingIsPairingAttempt
            ),
            lastPlaybackServerId: lastPlayback
        )
    }

    @Test("Higher or equal rank is accepted; lower is rejected")
    func rankOrdering() {
        #expect(arbitrate(incoming: [.playback], existing: [.playback]) == .acceptIncoming)
        #expect(arbitrate(incoming: [.pairing], existing: [.playback]) == .keepExisting)
        #expect(arbitrate(incoming: [], existing: [.pairing]) == .keepExisting)
        #expect(arbitrate(incoming: [.playback], existing: []) == .acceptIncoming)
        // Highest activity decides, not the set size.
        #expect(arbitrate(incoming: [.playback], existing: [.playback, .pairing]) == .acceptIncoming)
    }

    @Test("Empty vs empty: only the last-playback server displaces a non-last holder")
    func emptyTiebreak() {
        #expect(arbitrate(incoming: [], existing: [], lastPlayback: "incoming") == .acceptIncoming)
        #expect(arbitrate(incoming: [], existing: [], lastPlayback: "existing") == .keepExisting)
        #expect(arbitrate(incoming: [], existing: [], lastPlayback: nil) == .keepExisting)
        #expect(arbitrate(incoming: [], existing: [], lastPlayback: "other") == .keepExisting)
    }

    @Test("A pairing attempt is not displaced by playback or pairing")
    func pairingAttemptShield() {
        #expect(
            arbitrate(incoming: [.playback], existing: [.pairing], existingIsPairingAttempt: true)
                == .keepExisting
        )
        #expect(
            arbitrate(incoming: [.pairing], existing: [.pairing], existingIsPairingAttempt: true)
                == .keepExisting
        )
    }
}
