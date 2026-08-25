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
    func handleCompetingConnection(_ transport: any SendspinTransport) async throws {
        guard !arbitrationInProgress else {
            await transport.disconnect()
            return
        }
        arbitrationInProgress = true
        defer { arbitrationInProgress = false }
        let arbitrationEpoch = sessionEpoch

        do {
            let negotiation = try await makeSessionFormatNegotiation()
            let outcome = try await HandshakeDriver.establish(
                on: transport,
                configuration: HandshakeDriver.Configuration(
                    identity: identity,
                    candidates: [PskCandidate(psk: .sentinel, category: .sentinel)],
                    clientHello: buildClientHelloPayload(effectivePlayerFormats: negotiation.effectivePlayerFormats),
                    supportedRoles: roleSet,
                    unpairedAccessEnabled: unpairedAccessEnabled
                ),
                phaseTimeout: handshakeTimeout
            )
            guard sessionEpoch == arbitrationEpoch else {
                await HandshakeDriver.reject(outcome, reason: .concurrentAttempt, on: transport)
                return
            }
            let existingCandidate = MultiServerAdmission.Candidate(
                serverId: currentServerId ?? "",
                activities: currentActivities
            )
            let incomingCandidate = MultiServerAdmission.Candidate(
                serverId: outcome.serverId,
                activities: outcome.activities
            )
            let lastPlayback = await persistenceProvider?.loadLastPlayedServerId()
            switch MultiServerAdmission.arbitrate(
                incoming: incomingCandidate,
                existing: existingCandidate,
                lastPlaybackServerId: lastPlayback
            ) {
            case .keepExisting:
                await HandshakeDriver.reject(outcome, reason: .concurrentAttempt, on: transport)
            case .acceptIncoming:
                if let incumbent = retireSession() {
                    await incumbent.disconnect(reason: .anotherServer)
                }
                updateConnectionState(.connecting)
                await setupConnection(with: transport, outcome: outcome, negotiation: negotiation)
            }
        } catch {
            await transport.disconnect()
            throw error
        }
    }
}
