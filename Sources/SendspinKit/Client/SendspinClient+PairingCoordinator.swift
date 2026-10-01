import Foundation

extension SendspinClient {
    @MainActor
    func applyPairingConnectionEvent(_ event: ConnectionEvent) {
        guard pairingConnection != nil else { return }
        switch event {
        case let .paired(snapshot):
            updateCurrentPairing(snapshot)
            // A late success from an older attempt must not close a newer window.
            if pairingWindow?.attemptID == snapshot.id {
                clearPairingWindow()
            }
            emitEvent(.paired(snapshot))
        case let .pairingCodeChanged(snapshot):
            // The terminal event is followed by a nil-code projection so observers
            // can see code removal without losing the terminal lifecycle state.
            if case .ended = snapshot.phase {
                emitEvent(.pairingCodeChanged(snapshot))
            } else {
                updateCurrentPairing(snapshot)
                emitEvent(.pairingCodeChanged(snapshot))
            }
        case let .pairingAttemptEnded(snapshot):
            updateCurrentPairing(snapshot)
            emitEvent(.pairingAttemptEnded(snapshot))
        case let .pairingAttemptSuperseded(attemptID):
            if currentPairing?.id == attemptID {
                updateCurrentPairing(nil)
            }
            emitEvent(.pairingAttemptSuperseded(attemptID))
        case let .pairingWindowChanged(window):
            pairingSideWindowID = window?.attemptID
            updatePairingWindow(window)
            emitEvent(.pairingWindowChanged(window))
        case .disconnected:
            if let side = pairingConnection {
                dropPairingConnection(side)
            }
        case .serverConnected, .audioOutputChanged, .outputFormatStatusChanged,
             .metadataReceived, .metadataCleared, .controllerStateUpdated,
             .controllerStateCleared, .colorStateUpdated, .colorStateCleared,
             .groupUpdated, .artworkStreamStarted, .visualizerStreamStarted,
             .streamAccepted, .streamStarted, .streamFormatChanged, .streamEnded,
             .streamCleared, .outputDelayChanged, .lastPlayedServerChanged,
             .streamError, .playerVolumeChanged, .playerMutedChanged,
             .serverActivated, .operationalState, .clockSyncEstablished:
            break
        }
    }

    @MainActor
    func observePairingActivations(
        from gate: ConnectionActivationGate,
        connection side: SendspinConnection
    ) {
        Task { @MainActor [weak self] in
            for await proposal in gate.requests {
                guard let self, pairingConnection === side else {
                    gate.resolve(proposal.token, verdict: .reject(.concurrentAttempt))
                    continue
                }
                let verdict = await resolvePairingActivation(proposal, side: side, gate: gate)
                if case .admit = verdict {
                    gate.cancel()
                } else {
                    // The connection actor owns the rejection response and must
                    // send its goodbye before the facade retires the side. Its
                    // terminal disconnected event performs the eventual detach.
                    gate.resolve(proposal.token, verdict: verdict)
                }
            }
        }
    }

    @MainActor
    private func resolvePairingActivation(
        _ proposal: ConnectionActivationProposal,
        side: SendspinConnection,
        gate: ConnectionActivationGate
    ) async -> ConnectionActivationVerdict {
        guard pairingConnection === side, let primary = connection else {
            return .reject(.concurrentAttempt)
        }
        let primarySnapshot = await primary.admissionSnapshot()
        let incoming = await MultiServerAdmission.Candidate(
            serverId: side.admissionSnapshot().serverId,
            activities: proposal.activities,
            isPairingAttempt: false
        )
        let existing = MultiServerAdmission.Candidate(
            serverId: primarySnapshot.serverId,
            activities: primarySnapshot.activities,
            isPairingAttempt: primarySnapshot.isPairingAttempt
        )
        let lastPlayback = await persistenceProvider?.loadLastPlayedServerId()
        switch MultiServerAdmission.arbitrate(
            incoming: incoming,
            existing: existing,
            lastPlaybackServerId: lastPlayback
        ) {
        case .keepExisting:
            return .reject(.concurrentAttempt)
        case .acceptIncoming:
            guard await promotePairingConnection(side, primary: primary, gate: gate, token: proposal.token) else {
                return .reject(.concurrentAttempt)
            }
            return .admit
        }
    }

    @MainActor
    private func promotePairingConnection(
        _ side: SendspinConnection,
        primary: SendspinConnection,
        gate: ConnectionActivationGate,
        token: UUID
    ) async -> Bool {
        guard !isTerminated, pairingConnection === side, connection === primary else { return false }
        // Capture the parked connection's complete projection before retiring the
        // primary. The side remains in its pairing activation while the gate is
        // unresolved, so this is the stable state that promotion must inherit.
        let snapshot = await side.projectionSnapshot()
        guard !isTerminated, pairingConnection === side, connection === primary else { return false }
        sessionEpoch += 1
        let promotionEpoch = sessionEpoch
        let sideDelivery = pairingDataDelivery
        let sideValidity = pairingSessionValidity
        pairingPromotionInProgress = true
        deferredPairingEvents.removeAll(keepingCapacity: true)

        // Keep ownership pointers unchanged until the incumbent goodbye completes
        // and the promoted projection is installed; its terminal event must not
        // retire the new owner.
        await primary.disconnect(reason: .anotherServer)
        guard !isTerminated, sessionEpoch == promotionEpoch, connection === primary,
              pairingConnection === side else {
            pairingPromotionInProgress = false
            deferredPairingEvents.removeAll()
            return false
        }

        sessionValidity?.invalidate()
        sessionValidity = sideValidity
        pairingSessionValidity = nil
        connection = side
        pairingConnection = nil
        pairingActivationGate = nil
        pairingDataDelivery = nil
        drainConnectionEventsTask?.cancel()
        drainConnectionEventsTask = pairingConnectionDrainTask
        pairingConnectionDrainTask = nil

        applyPromotedProjection(snapshot)
        updateConnectionState(.connected)
        gate.resolve(token, verdict: .admit)
        sideDelivery?.promoteToPrimary()
        pairingPromotionInProgress = false
        let deferredEvents = deferredPairingEvents
        deferredPairingEvents.removeAll(keepingCapacity: true)
        for event in deferredEvents {
            guard !isTerminated, connection === side else { return false }
            applyConnectionEvent(event)
        }
        return true
    }

    @MainActor
    func detachPairingConnection() -> SendspinConnection? {
        pairingConnectionDrainTask?.cancel()
        pairingConnectionDrainTask = nil
        pairingActivationGate?.cancel()
        pairingActivationGate = nil
        pairingPromotionInProgress = false
        deferredPairingEvents.removeAll()
        pairingSessionValidity?.invalidate()
        pairingSessionValidity = nil
        pairingDataDelivery = nil
        let side = pairingConnection
        pairingConnection = nil
        return side
    }

    @MainActor
    func dropPairingConnection(_ side: SendspinConnection) {
        guard pairingConnection === side else { return }
        if let pairingSideWindowID, pairingWindow?.attemptID == pairingSideWindowID {
            clearPairingWindow()
            emitEvent(.pairingWindowChanged(nil))
        }
        pairingSideWindowID = nil
        _ = detachPairingConnection()
        Task { await side.shutdown() }
    }
}
