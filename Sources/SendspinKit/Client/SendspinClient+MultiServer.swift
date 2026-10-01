import Foundation

extension SendspinClient {
    enum ArbitrationDecision: Equatable {
        case switchToNew
        case keepExisting
    }

    nonisolated static func arbitrate(
        incoming: MultiServerAdmission.Candidate,
        existing: MultiServerAdmission.Candidate,
        lastPlaybackServerId: String?
    ) -> ArbitrationDecision {
        switch MultiServerAdmission.arbitrate(
            incoming: incoming,
            existing: existing,
            lastPlaybackServerId: lastPlaybackServerId
        ) {
        case .acceptIncoming: .switchToNew
        case .keepExisting: .keepExisting
        }
    }

    @MainActor
    // swiftlint:disable:next function_body_length
    func handleCompetingConnection(_ transport: any SendspinTransport) async throws {
        guard !arbitrationInProgress else {
            await transport.disconnect()
            return
        }
        arbitrationInProgress = true
        defer { arbitrationInProgress = false }
        let arbitrationEpoch = sessionEpoch
        let incumbent = connection
        guard let incumbent else {
            await transport.disconnect()
            return
        }

        do {
            await preparePairingConfiguration()
            guard sessionEpoch == arbitrationEpoch, connection == nil || connection === incumbent else {
                await transport.disconnect()
                return
            }
            let negotiation = try await makeSessionFormatNegotiation()
            guard sessionEpoch == arbitrationEpoch, connection == nil || connection === incumbent else {
                await transport.disconnect()
                return
            }
            let runtimeConfiguration = await pairingRuntimeConfiguration()
            guard sessionEpoch == arbitrationEpoch, connection == nil || connection === incumbent else {
                await transport.disconnect()
                return
            }
            let outcome = try await HandshakeDriver.establish(
                on: transport,
                configuration: HandshakeDriver.Configuration(
                    identity: identity,
                    candidates: pairingCandidates(),
                    clientHello: buildClientHelloPayload(
                        effectivePlayerFormats: negotiation.effectivePlayerFormats,
                        configuration: runtimeConfiguration
                    ),
                    supportedRoles: roleSet,
                    unpairedAccessEnabled: runtimeConfiguration.unpairedAccessEnabled,
                    pairingStore: pairingConfiguration?.store
                ),
                phaseTimeout: handshakeTimeout
            )
            guard sessionEpoch == arbitrationEpoch, connection == nil || connection === incumbent else {
                await HandshakeDriver.reject(outcome, reason: .concurrentAttempt, on: transport)
                return
            }

            let incomingCandidate = MultiServerAdmission.Candidate(
                serverId: outcome.serverId,
                activities: outcome.activities
            )
            let lastPlayback = await persistenceProvider?.loadLastPlayedServerId()
            guard sessionEpoch == arbitrationEpoch, connection == nil || connection === incumbent else {
                await HandshakeDriver.reject(outcome, reason: .concurrentAttempt, on: transport)
                return
            }
            // Event-drain state can lag while the incumbent processes its ordered
            // message loop. Arbitration therefore uses the actor-owned snapshot.
            let snapshot = await incumbent.admissionSnapshot()
            let existingSnapshot: SendspinConnection.AdmissionSnapshot = if connection === incumbent {
                snapshot
            } else {
                SendspinConnection.AdmissionSnapshot(
                    serverId: "",
                    activities: [],
                    isPairingAttempt: false
                )
            }
            guard sessionEpoch == arbitrationEpoch, connection == nil || connection === incumbent else {
                await HandshakeDriver.reject(outcome, reason: .concurrentAttempt, on: transport)
                return
            }
            let existingCandidate = MultiServerAdmission.Candidate(
                serverId: existingSnapshot.serverId,
                activities: existingSnapshot.activities,
                isPairingAttempt: existingSnapshot.isPairingAttempt
            )
            // The one coexistence exception is a first incoming pairing session
            // beside an admitted playback holder. Keep it parked until a later
            // activation proves that it has become playback-capable.
            if incomingCandidate.activities.contains(.pairing),
               Activity.rank(of: incomingCandidate.activities) == Activity.pairing.rank {
                if pairingConnection != nil {
                    await HandshakeDriver.reject(outcome, reason: .concurrentAttempt, on: transport)
                    return
                }
                if existingCandidate.activities == [.playback], !existingCandidate.isPairingAttempt {
                    await setupConnection(
                        with: transport,
                        outcome: outcome,
                        negotiation: negotiation,
                        runtimeConfiguration: runtimeConfiguration,
                        setupEpoch: arbitrationEpoch,
                        installAsPairingSide: true
                    )
                    return
                }
            }

            switch MultiServerAdmission.arbitrate(
                incoming: incomingCandidate,
                existing: existingCandidate,
                lastPlaybackServerId: lastPlayback
            ) {
            case .keepExisting:
                await HandshakeDriver.reject(outcome, reason: .concurrentAttempt, on: transport)
            case .acceptIncoming:
                // Promotion is a session transition: claim a fresh epoch so a parked
                // connect/accept at the older epoch cannot install over this winner.
                guard sessionEpoch == arbitrationEpoch, connection == nil || connection === incumbent else {
                    await transport.disconnect()
                    return
                }
                sessionEpoch += 1
                let promotionEpoch = sessionEpoch
                if let retired = retireSession() {
                    await retired.disconnect(reason: .anotherServer)
                }
                // The incumbent teardown suspends; a disconnect may have landed.
                guard sessionEpoch == promotionEpoch else {
                    await transport.disconnect()
                    return
                }
                updateConnectionState(.connecting)
                await setupConnection(
                    with: transport,
                    outcome: outcome,
                    negotiation: negotiation,
                    runtimeConfiguration: runtimeConfiguration,
                    setupEpoch: promotionEpoch
                )
            }
        } catch {
            await transport.disconnect()
            throw error
        }
    }
}
