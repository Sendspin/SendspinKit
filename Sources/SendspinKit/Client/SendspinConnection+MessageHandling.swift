import CryptoKit
import Foundation
import os

enum PairingProtocolError: Error {
    case invalidSequence
}

private let pairingMessageTypes: Set<String> = [
    ServerPairInitMessage.typeString, ServerPairAuthMessage.typeString,
    ServerPairConfirmMessage.typeString, ServerPairFinalizeMessage.typeString,
    ClientPairPendingMessage.typeString, ClientPairInitMessage.typeString,
    ClientPairAuthMessage.typeString, ClientPairRetryMessage.typeString,
    ClientPairConfirmMessage.typeString, ClientPairFinalizeMessage.typeString,
    PairAbortMessage.typeString
]

extension SendspinConnection {
    // MARK: - Frame routing

    /// Route a text frame: classify and dispatch.
    func route(text: String, clientReceived: Int64) async {
        guard let data = text.data(using: .utf8) else { return }

        guard let msgType = SendspinEncoding.messageType(of: data) else {
            Log.client.error("Message missing 'type' field: \(text.prefix(200))")
            return
        }

        if discardingPairingMessages, pairingMessageTypes.contains(msgType) {
            return
        }

        Log.client.debug("RX \(msgType)")

        let decoder = inboundDecoder
        do {
            switch msgType {
            case "server/activate":
                try await handleServerActivate(decoder.decode(ServerActivateMessage.self, from: data))

            case "noise/handshake":
                try await handleRehandshake(decoder.decode(NoiseHandshakeMessage.self, from: data))

            case "server/hello":
                try await handleServerHello(decoder.decode(ServerHelloMessage.self, from: data))

            case "server/unpair":
                try await handleServerUnpair(decoder.decode(ServerUnpairMessage.self, from: data))

            case "server/pair-init":
                try await handleServerPairInit(decoder.decode(ServerPairInitMessage.self, from: data))

            case "server/pair-auth":
                try await handleServerPairAuth(decoder.decode(ServerPairAuthMessage.self, from: data))

            case "server/pair-confirm":
                try await handleServerPairConfirm(decoder.decode(ServerPairConfirmMessage.self, from: data))

            case "server/pair-finalize":
                try await handleServerPairFinalize(decoder.decode(ServerPairFinalizeMessage.self, from: data))

            case "pair/abort":
                let abort = try JSONDecoder().decode(PairAbortMessage.self, from: data)
                if pairingAttemptID != nil {
                    clearPairingAttempt(reason: abort.payload.reason)
                }

            case "client/pair-pending", "client/pair-init", "client/pair-auth", "client/pair-retry", "client/pair-confirm":
                throw PairingProtocolError.invalidSequence

            case "server/time":
                try await handleServerTime(
                    decoder.decode(ServerTimeMessage.self, from: data),
                    clientReceived: clientReceived
                )

            case "server/state":
                try await handleServerState(decoder.decode(ServerStateMessage.self, from: data))

            case "stream/start":
                try await handleStreamStart(decoder.decode(StreamStartMessage.self, from: data))

            case "stream/clear":
                try await handleStreamClear(decoder.decode(StreamClearMessage.self, from: data))

            case "stream/end":
                try await handleStreamEnd(decoder.decode(StreamEndMessage.self, from: data))

            case "server/command":
                try await handleServerCommand(decoder.decode(ServerCommandMessage.self, from: data))

            case "group/update":
                try await handleGroupUpdate(decoder.decode(GroupUpdateMessage.self, from: data))

            default:
                Log.client.warning("Unknown message type: \(msgType)")
            }
        } catch {
            Log.client.error("Failed to decode '\(msgType)': \(error.localizedDescription)")

            if msgType == ServerActivateMessage.typeString
                || msgType == NoiseHandshakeMessage.typeString
                || pairingMessageTypes.contains(msgType)
                || (msgType == ServerHelloMessage.typeString && awaitingRehandshakeActivation) {
                disconnectReason = .incompatibleServer
                await transport.disconnect()
            }
        }
    }

    /// Route a binary frame to the matching role data stream if its stream gate is open.
    func route(binary data: Data, arrival: Int64 = MonotonicClock.absoluteMicroseconds()) async {
        if let type = data.first,
           type >= BinaryMessageType.artworkChannel0.rawValue,
           type <= BinaryMessageType.artworkChannel3.rawValue {
            do {
                try await handleArtworkBinary(data)
            } catch {
                disconnectReason = .incompatibleServer
                await transport.disconnect()
            }
            return
        }
        guard let message = BinaryMessage(data: data) else { return }

        switch message.type {
        case .audioChunk:
            // Direct callers use the same application-arrival measurement as the message loop.
            await handleAudioChunk(message, arrival: arrival)

        case .visualizerLoudness, .visualizerBeat, .visualizerFPeak, .visualizerSpectrum, .visualizerPeak:
            await handleVisualizerBinary(message, arrival: arrival)

        case .artworkChannel0, .artworkChannel1, .artworkChannel2, .artworkChannel3:
            preconditionFailure("Artwork messages are routed by the range pre-check")
        }
    }

    // MARK: - Text message handlers

    func handleRehandshake(_ message: NoiseHandshakeMessage) async {
        guard !rehandshakeInProgress else { return }
        rehandshakeInProgress = true
        var candidateLease: PairingRecordProtectionLease?
        do {
            let candidates = try await candidateProvider()
            guard let message1 = Base64URL.decode(message.payload.data) else { throw NoiseError.malformedMessage }
            var handshake = NoiseHandshake(
                suite: suite,
                role: .responder,
                localStaticKey: identityPrivateKey,
                remoteStaticPublicKey: serverStaticPublicKey,
                prologue: channel.handshakeHash
            )
            let payload = try handshake.readMessage1(message1)
            let inner = try JSONDecoder().decode(NoiseMessage1Payload.self, from: payload)
            guard let candidate = PskCandidate.select(
                from: candidates,
                pskId: inner.pskId,
                pskCategory: inner.pskCategory,
                serverId: currentServerId ?? ""
            ) else { throw HandshakeError.pskLookupMiss }
            let retainsExistingLease = candidate.category == .longTerm
                && (candidate.psk.pskId == matchedPskId
                    || pairingProtectionLease?.pskIds.contains(candidate.psk.pskId) == true)
            if candidate.category == .longTerm, !retainsExistingLease, let pairingStore {
                candidateLease = try await pairingStore.acquireProtection(
                    pskId: candidate.psk.pskId,
                    serverId: candidate.requiredServerId
                )
            }
            let message2: Data
            do {
                message2 = try handshake.writeMessage2(psk: candidate.psk, payload: noiseMessage2Payload)
            } catch {
                throw error
            }
            let newTransport: NoiseTransport
            do {
                newTransport = try handshake.makeTransport()
            } catch {
                throw error
            }
            let reply = NoiseHandshakeMessage(
                payload: NoiseHandshakePayload(data: Base64URL.encode(message2))
            )
            // The gate covers the old-key reply and the synchronous key swap.
            try await sendWrapped(reply, bypassRehandshakeGate: true)
            channel.rekey(to: newTransport)
            if !retainsExistingLease, let oldLease = pairingProtectionLease, let pairingStore {
                try? await pairingStore.releaseProtection(oldLease)
                pairingProtectionLease = nil
            }
            pairingProtectionLease = candidateLease
            candidateLease = nil
            pskCategory = candidate.category
            matchedPskId = candidate.psk.pskId
            if candidate.category == .longTerm, let pairingStore {
                do {
                    try await pairingStore.markUsed(pskId: candidate.psk.pskId)
                } catch {
                    disconnectReason = .connectionLost(nil)
                    await transport.disconnect()
                    return
                }
            }
            let advertisement = await livePairingAdvertisement()
            sessionContext = ActivationAdmissibility.SessionContext(
                category: candidate.category,
                unpairedAccessEnabled: advertisement.unpairedAccessEnabled,
                offeredPairMethods: advertisement.offeredPairMethods
            )
            clearPairingAttempt()
            pairingActivateCounter = 0
            awaitingRehandshakeActivation = true
            controlSink.enqueue(.serverConnected(ServerInfo(
                serverId: currentServerId ?? "",
                name: serverName,
                trustLevel: candidate.category == .longTerm ? .user : .none,
                activeRoles: activeRoles,
                activities: activities
            )))
        } catch {
            if let candidateLease, let pairingStore {
                try? await pairingStore.releaseProtection(candidateLease)
            }
            rehandshakeInProgress = false
            disconnectReason = .incompatibleServer
            await transport.disconnect()
        }
    }

    func livePairingAdvertisement() async -> (
        supportedPairMethods: [String: PairMethodDescriptor],
        unpairedAccessEnabled: Bool,
        offeredPairMethods: Set<String>
    ) {
        guard let runtime = pairingConfigurationRuntime else {
            return (
                clientHelloPayload.supportedPairMethods,
                clientHelloPayload.unpairedAccess.enabled,
                Set(clientHelloPayload.supportedPairMethods.keys)
            )
        }
        let configuration = await runtime.snapshot()
        var methods: [String: PairMethodDescriptor] = [:]
        if configuration.pairingPskEnabled {
            methods[PairMethod.pairingPsk] = PairMethodDescriptor(locations: ["operator"])
        }
        if configuration.dynamicPairingCodeEnabled {
            methods[PairMethod.dynamicPairingCode] = PairMethodDescriptor(
                outChannels: configuration.outChannels,
                formats: configuration.formats
            )
        }
        if configuration.staticPairingCodeIsAdvertised {
            methods[PairMethod.staticPairingCode] = PairMethodDescriptor(locations: ["operator"])
        }
        return (methods, configuration.unpairedAccessEnabled, Set(methods.keys))
    }

    func handleServerHello(_: ServerHelloMessage) async {
        guard awaitingRehandshakeActivation else { return }
        disconnectReason = .incompatibleServer
        await transport.disconnect()
    }

    /// Apply the activation already consumed by `HandshakeDriver` during handoff.
    /// The live message loop starts after setup, so pairing must be initialized here
    /// rather than waiting for another server/activate frame.
    func applyInitialPairingActivation(_ pairing: PairingDirective) async {
        guard activities.contains(.pairing) else { return }
        if pairingAttemptID == nil {
            admitPairingAttempt()
        } else {
            enqueuePairingSnapshot(phase: .pending)
        }
        pairingAttemptActive = true
        pairingActivateCounter = pairingActivateCounter == .max ? 0 : pairingActivateCounter + 1
        switch pairing.method {
        case PairMethod.pairingPsk:
            await beginPairingAttempt()
        case PairMethod.dynamicPairingCode:
            await beginDynamicPairingAttempt(format: pairing.format)
        case PairMethod.staticPairingCode:
            await beginStaticPairingAttempt(format: pairing.format)
        default:
            clearPairingAttempt(reason: .methodNotSupported)
        }
    }

    private func clearRemovedRoles(_ removedRoles: Set<VersionedRole>) {
        let names = Set(removedRoles.map(\.role))
        if names.contains(VersionedRole.metadataV1.role) {
            currentMetadata = nil
            // Clearing pending state makes a resumed sleeper a no-op even when it swallows cancellation.
            metadataPending = nil
            metadataScheduleTask?.cancel()
            metadataScheduleTask = nil
            controlSink.enqueue(.metadataCleared)
        }
        if names.contains(VersionedRole.colorV1.role) {
            currentColorState = nil
            // Clearing pending state makes a resumed sleeper a no-op even when it swallows cancellation.
            colorPending = nil
            colorScheduleTask?.cancel()
            colorScheduleTask = nil
            controlSink.enqueue(.colorStateCleared)
        }
        if names.contains(VersionedRole.controllerV1.role) {
            currentControllerState = nil
            controlSink.enqueue(.controllerStateCleared)
        }
        if names.contains(VersionedRole.playerV1.role) {
            if playerStreamActive {
                controlSink.enqueue(.streamEnded(roles: [StreamRole.player.rawValue]))
            }
            playerStreamActive = false
            announcedPlayerStream = nil
            playerStartState = .none
            resetOutputFormatNegotiationForStreamBoundary()
            // Stream end stops scheduler/output; stream clear also discards the output buffer.
            audioEngine.enqueueStreamEnd(roles: [StreamRole.player.rawValue])
            audioEngine.commands.enqueue(.streamClear(roles: [StreamRole.player.rawValue]))
        }
        if names.contains(VersionedRole.artworkV1.role) {
            if artworkStreamActive {
                controlSink.enqueue(.streamEnded(roles: [StreamRole.artwork.rawValue]))
            }
            invalidateArtworkDelivery()
            artworkStreamActive = false
            artworkStreamChannels = []
            artworkTransfer = nil
            clearPendingArtwork()
        }
        if names.contains(VersionedRole.visualizerV1.role) {
            if visualizerStreamActive {
                controlSink.enqueue(.streamEnded(roles: [StreamRole.visualizer.rawValue]))
            }
            visualizerStreamActive = false
            visualizerStreamConfiguration = nil
            resetVisualizerDelivery(resetTimestampFloor: true)
        }
    }

    private func resetPairingForActivation() {
        discardingPairingMessages = false
        // Each activation supersedes attempt state, not connection-scoped authorization.
        if dynamicPairingAttempt != nil || staticPairingAttempt != nil || pendingPairingPsk != nil || pairingAttemptActive {
            if let attemptID = pairingAttemptID {
                // Server activation abandons the attempt without implying an operator abort.
                controlSink.enqueue(.pairingAttemptSuperseded(attemptID))
            }
            clearPairingAttempt(emitCodeRemoval: false)
        }
    }

    func handleServerActivate(_ message: ServerActivateMessage) async {
        resetPairingForActivation()
        if message.payload.activities.contains(.pairing), pairingAttemptID == nil {
            admitPairingAttempt()
        }
        let advertisement = await livePairingAdvertisement()
        sessionContext = ActivationAdmissibility.SessionContext(
            category: sessionContext.category,
            unpairedAccessEnabled: advertisement.unpairedAccessEnabled,
            offeredPairMethods: advertisement.offeredPairMethods,
            offeredDynamicFormats: Set(advertisement.supportedPairMethods[PairMethod.dynamicPairingCode]?.formats ?? [])
        )
        let nextActivities = Set(message.payload.activities)
        if nextActivities.contains(.pairing) {
            pairingActivateCounter = pairingActivateCounter == .max ? 0 : pairingActivateCounter + 1
        }
        let nextRoles: Set<VersionedRole> = if let announcedRoles = message.payload.activeRoles {
            Set(announcedRoles).intersection(roles)
        } else if ActivationAdmissibility.isPlaybackCapable(
            nextActivities,
            category: sessionContext.category,
            unpairedAccessEnabled: sessionContext.unpairedAccessEnabled
        ) {
            activeRoles
        } else {
            []
        }
        switch ActivationAdmissibility.evaluate(
            activities: nextActivities,
            activeRoles: nextRoles,
            pairing: message.payload.pairing,
            session: sessionContext
        ) {
        case .admit:
            if activities.contains(.pairing), !nextActivities.contains(.pairing), let activationGate {
                let verdict = await activationGate.request(
                    activities: nextActivities,
                    activeRoles: nextRoles
                )
                guard case .admit = verdict else {
                    if case let .reject(reason) = verdict {
                        let goodbye = ClientGoodbyeMessage(payload: GoodbyePayload(reason: reason))
                        try? await sendWrapped(goodbye, bypassRehandshakeGate: awaitingRehandshakeActivation)
                    }
                    disconnectReason = .explicit(.concurrentAttempt)
                    await transport.disconnect()
                    return
                }
            }
            activities = nextActivities
            pairingAttemptActive = nextActivities.contains(.pairing)
            let completedRehandshake = awaitingRehandshakeActivation
            if completedRehandshake {
                awaitingRehandshakeActivation = false
            }
            // Re-handshake preserves state for unchanged roles; newly active roles
            // require their full client/state objects under the new keys.
            let removedRoles = activeRoles.subtracting(nextRoles)
            let rolesChanged = nextRoles != activeRoles
            activeRoles = nextRoles
            clearRemovedRoles(removedRoles)
            if rolesChanged {
                playerStateSent = false
                visualizerStateSent = false
                artworkStateSent = false
            }
            if rolesChanged || !completedRehandshake {
                try? await publishClientState(bypassRehandshakeGate: completedRehandshake)
            }
            if completedRehandshake {
                rehandshakeInProgress = false
            }
            controlSink.enqueue(.serverActivated(activities: activities, activeRoles: activeRoles))
            if nextActivities.contains(.pairing), message.payload.pairing?.method == PairMethod.pairingPsk {
                await beginPairingAttempt()
            } else if nextActivities.contains(.pairing), message.payload.pairing?.method == PairMethod.dynamicPairingCode {
                await beginDynamicPairingAttempt(format: message.payload.pairing?.format)
            } else if nextActivities.contains(.pairing), message.payload.pairing?.method == PairMethod.staticPairingCode {
                await beginStaticPairingAttempt(format: message.payload.pairing?.format)
            } else if pairingAttemptActive || pendingPairingPsk != nil || dynamicPairingAttempt != nil || staticPairingAttempt != nil {
                if dynamicPairingAttempt != nil {
                    enqueuePairingCode(nil)
                }
                clearPairingAttempt()
            }
        case let .close(reason):
            let goodbye = ClientGoodbyeMessage(payload: GoodbyePayload(reason: reason))
            try? await sendWrapped(goodbye, bypassRehandshakeGate: awaitingRehandshakeActivation)
            disconnectReason = .explicit(reason)
            await transport.disconnect()
        case .abortPairing:
            discardingPairingMessages = true
            clearPairingAttempt(reason: .methodNotSupported)
            try? await sendWrapped(
                PairAbortMessage(payload: PairAbortPayload(reason: .methodNotSupported)),
                bypassRehandshakeGate: awaitingRehandshakeActivation
            )
            if awaitingRehandshakeActivation {
                awaitingRehandshakeActivation = false
                rehandshakeInProgress = false
            }
        }
    }

    func admitPairingAttempt() {
        guard pairingAttemptID == nil else { return }
        pairingAbortAuthorization = nil
        pairingAttemptID = PairingAttemptID()
        pairingAttemptPeer = PairingPeer(id: currentServerId ?? "", name: serverName)
        enqueuePairingSnapshot(phase: .pending)
    }

    func enqueuePairingSnapshot(phase: PairingAttemptPhase, code: PairingCodeEmission? = nil) {
        guard let id = pairingAttemptID, let peer = pairingAttemptPeer else { return }
        let snapshot = PairingAttemptSnapshot(id: id, peer: peer, phase: phase, code: code)
        switch phase {
        case .ended:
            controlSink.enqueue(.pairingAttemptEnded(snapshot))
        case .succeeded:
            controlSink.enqueue(.paired(snapshot))
        default:
            controlSink.enqueue(.pairingCodeChanged(snapshot))
        }
    }

    func enqueuePairingCode(_ emission: PairingCodeEmission?) {
        enqueuePairingSnapshot(phase: emission == nil ? .authenticating : .codeReady, code: emission)
    }

    func beginPairingAttempt() async {
        guard pairingAttemptID != nil else { return }
        guard pskCategory == .pairing,
              pendingPairingPsk == nil,
              dynamicPairingAttempt == nil,
              staticPairingAttempt == nil
        else {
            if pskCategory != .pairing, let attemptID = pairingAttemptID {
                discardingPairingMessages = true
                try? await sendPairingWrapped(
                    PairAbortMessage(payload: PairAbortPayload(reason: .methodNotSupported)),
                    attemptID: attemptID
                )
            }
            return
        }
        guard let authorizedAttemptID = pairingAttemptID else { return }
        let generated = await selectPairingLongTermPsk()
        guard pairingAttemptID == authorizedAttemptID, pairingAttemptActive else { return }
        pendingPairingPsk = generated
        pairingAttemptTask?.cancel()
        let attemptID = pairingAttemptID
        pairingAttemptTask = Task { [weak self] in
            try? await Task.sleep(for: self?.pairingAttemptTimeout ?? .seconds(120))
            guard !Task.isCancelled else { return }
            await self?.pairingAttemptTimedOut(attemptID: attemptID)
        }
        do {
            try await sendPairingWrapped(
                ClientPairInitMessage(payload: ClientPairInitPayload(pairingIndex: pairingActivateCounter, commitB: nil)),
                attemptID: authorizedAttemptID
            )
            try await sendPairingWrapped(
                ClientPairFinalizeMessage(payload: ClientPairFinalizePayload(longTermPsk: generated.base64URL)),
                attemptID: authorizedAttemptID
            )
        } catch {
            guard pairingAttemptID == authorizedAttemptID else { return }
            clearPairingAttempt()
        }
    }

    /// Generate the PSK committed by `client/pair-finalize`.
    private func selectPairingLongTermPsk() async -> Psk {
        Psk.generate()
    }

    func beginDynamicPairingAttempt(format: String?) async {
        guard pairingAttemptID != nil else { return }
        guard pskCategory == .sentinel,
              let rawFormat = format,
              let selectedFormat = PairingCodeFormat(rawValue: rawFormat)
        else {
            guard let attemptID = pairingAttemptID else { return }
            await abortPairingAttempt(reason: .methodNotSupported, attemptID: attemptID)
            return
        }
        guard let authorizedAttemptID = pairingAttemptID else { return }
        guard await dynamicPairingCodeIsOffered(format: selectedFormat), pairingAttemptID == authorizedAttemptID else { return }
        #if DEBUG
            let nonceB = nonceBOverride ?? Psk.generate().bytes
        #else
            let nonceB = Psk.generate().bytes
        #endif
        var commitInput = Data("sendspin-pair-commit-v1".utf8)
        commitInput.append(nonceB)
        let commitB = Data(SHA256.hash(data: commitInput))
        #if DEBUG
            let pairingHandshakeHash = pairingHandshakeHashOverride ?? channel.handshakeHash
        #else
            let pairingHandshakeHash = channel.handshakeHash
        #endif
        guard pairingAttemptID == authorizedAttemptID else { return }
        dynamicPairingAttempt = DynamicPairingAttempt(
            format: selectedFormat,
            pairingIndex: pairingActivateCounter,
            nonceB: nonceB,
            commitB: commitB,
            nonceA: nil,
            prs: nil,
            round: 0,
            sid: nil,
            pairInitSent: false,
            serverShare: nil,
            cpace: nil,
            secrets: nil,
            clientConfirmationSent: false
        )
        guard let pairingStore else {
            Log.client.error("Dynamic pairing requires a durable pairing store")
            clearPairingAttempt()
            disconnectReason = .connectionLost(nil)
            await transport.disconnect()
            return
        }
        do {
            let count = try await pairingStore.dynamicPairingRoundCount()
            guard pairingAttemptID == authorizedAttemptID, pairingAttemptActive else { return }
            if count < dynamicPairingRoundLimit {
                await sendDynamicPairInit(attemptID: authorizedAttemptID)
            } else {
                try? await sendPairingWrapped(
                    ClientPairPendingMessage(payload: ClientPairPendingPayload(pairingIndex: pairingActivateCounter)),
                    attemptID: authorizedAttemptID
                )
            }
        } catch {
            Log.client.error("Dynamic pairing budget read failed: \(error.localizedDescription)")
            await failPairingStorage(for: authorizedAttemptID)
        }
    }

    func dynamicPairingCodeIsOffered(format: PairingCodeFormat) async -> Bool {
        let advertisement = await livePairingAdvertisement()
        return advertisement.supportedPairMethods[PairMethod.dynamicPairingCode]?.formats?.contains(format.rawValue) == true
    }

    func beginStaticPairingAttempt(format: String?) async {
        guard pairingAttemptID != nil else { return }
        guard pskCategory == .sentinel, format == nil,
              let runtime = pairingConfigurationRuntime
        else {
            guard let attemptID = pairingAttemptID else { return }
            await abortPairingAttempt(reason: .methodNotSupported, attemptID: attemptID)
            return
        }
        guard let authorizedAttemptID = pairingAttemptID else { return }
        let configuration = await runtime.snapshot()
        guard pairingAttemptID == authorizedAttemptID else { return }
        guard configuration.staticPairingCodeIsAdvertised,
              let code = configuration.staticPairingCode,
              PairingManagementConfiguration.isValidStaticPairingCode(code)
        else {
            guard let attemptID = pairingAttemptID else { return }
            await abortPairingAttempt(reason: .methodNotSupported, attemptID: attemptID)
            return
        }
        #if DEBUG
            let pairingHandshakeHash = pairingHandshakeHashOverride ?? channel.handshakeHash
        #else
            let pairingHandshakeHash = channel.handshakeHash
        #endif
        let sid = CPaceSessionIdentifier.make(handshakeHash: pairingHandshakeHash, counter: pairingActivateCounter, round: 1)
        staticPairingAttempt = StaticPairingAttempt(
            pairingIndex: pairingActivateCounter,
            sid: sid,
            prs: Data(code.utf8),
            serverShare: nil,
            cpace: nil,
            secrets: nil,
            clientConfirmationSent: false
        )
        if pairingWindowOpen {
            await sendStaticPairInit()
        } else {
            guard let attemptID = pairingAttemptID else { return }
            try? await sendPairingWrapped(
                ClientPairPendingMessage(payload: ClientPairPendingPayload(pairingIndex: pairingActivateCounter)),
                attemptID: attemptID
            )
        }
    }

    func sendDynamicPairInit(attemptID: PairingAttemptID? = nil) async {
        guard let authorizedAttemptID = attemptID ?? pairingAttemptID,
              pairingAttemptID == authorizedAttemptID,
              var attempt = dynamicPairingAttempt,
              !attempt.pairInitSent
        else { return }
        if pairingAttemptTask == nil {
            pairingAttemptTask = Task { [weak self] in
                try? await Task.sleep(for: self?.pairingAttemptTimeout ?? .seconds(120))
                guard !Task.isCancelled else { return }
                await self?.pairingAttemptTimedOut(attemptID: authorizedAttemptID)
            }
        }
        attempt.serverShare = nil
        attempt.cpace = nil
        attempt.secrets = nil
        attempt.clientConfirmationSent = false
        dynamicPairingAttempt = attempt
        do {
            try await sendPairingWrapped(ClientPairInitMessage(payload: ClientPairInitPayload(
                pairingIndex: attempt.pairingIndex,
                commitB: Base64URL.encode(attempt.commitB)
            )), attemptID: authorizedAttemptID)
            guard pairingAttemptID == authorizedAttemptID else { return }
            attempt.pairInitSent = true
            dynamicPairingAttempt = attempt
        } catch {
            guard pairingAttemptID == authorizedAttemptID else { return }
            clearPairingAttempt()
        }
    }

    func openPairingWindow(attemptID: PairingAttemptID) async throws {
        // The identity is reserved at admission, before the server chooses a
        // pairing method. The operator can open connection-scoped authorization
        // before the activation arrives.
        guard pairingAttemptID == attemptID else {
            throw SendspinClientError.stalePairingAttempt(attemptID)
        }
        pairingAttemptActive = true
        let authorizedAttemptID = attemptID
        guard pairingAttemptID == authorizedAttemptID, pairingAttemptActive else {
            throw SendspinClientError.stalePairingAttempt(authorizedAttemptID)
        }
        // The deliberate gesture resets the device-wide budget even before method selection.
        if !(pairingWindowOpen && dynamicPairingAttempt?.pairInitSent == true), let pairingStore {
            do {
                try await pairingStore.resetDynamicPairingBudget()
                guard pairingAttemptID == authorizedAttemptID, pairingAttemptActive else {
                    throw SendspinClientError.stalePairingAttempt(authorizedAttemptID)
                }
            } catch let error as SendspinClientError {
                throw error
            } catch {
                Log.client.error("Dynamic pairing budget reset failed: \(error.localizedDescription)")
                await failPairingStorage(for: authorizedAttemptID)
                throw error
            }
        }
        guard pairingAttemptID == authorizedAttemptID, pairingAttemptActive else {
            throw SendspinClientError.stalePairingAttempt(authorizedAttemptID)
        }
        if pairingWindowOpen {
            if dynamicPairingAttempt != nil {
                await sendDynamicPairInit(attemptID: authorizedAttemptID)
            }
            return
        }
        pairingWindowFailedConfirmations = 0
        pairingWindowOpen = true
        pairingWindowAttemptID = authorizedAttemptID
        let expiresAt = PresentationInstant.now.adding(pairingWindowLifetime)
        pairingWindowExpiresAt = expiresAt
        controlSink.enqueue(.pairingWindowChanged(PairingWindowSnapshot(
            attemptID: authorizedAttemptID,
            expiresAt: expiresAt
        )))
        pairingWindowTask?.cancel()
        pairingWindowTask = Task { [weak self] in
            try? await Task.sleep(for: self?.pairingWindowLifetime ?? .seconds(300))
            guard !Task.isCancelled else { return }
            await self?.expirePairingWindow(for: authorizedAttemptID)
        }
        if dynamicPairingAttempt != nil {
            await sendDynamicPairInit(attemptID: authorizedAttemptID)
        } else if staticPairingAttempt != nil {
            await sendStaticPairInit(attemptID: authorizedAttemptID)
        }
    }

    func sendStaticPairInit(attemptID: PairingAttemptID? = nil) async {
        guard attemptID == nil || pairingAttemptID == attemptID,
              var attempt = staticPairingAttempt, attempt.cpace == nil else { return }
        pairingAttemptTask?.cancel()
        let attemptID = pairingAttemptID
        pairingAttemptTask = Task { [weak self] in
            try? await Task.sleep(for: self?.pairingAttemptTimeout ?? .seconds(120))
            guard !Task.isCancelled else { return }
            await self?.pairingAttemptTimedOut(attemptID: attemptID)
        }
        attempt.cpace = try? CPace(
            role: .responder,
            prs: attempt.prs,
            sid: attempt.sid,
            scalarOverride: pairingScalarBOverride
        )
        guard attempt.cpace != nil else {
            clearPairingAttempt()
            return
        }
        staticPairingAttempt = attempt
        guard let attemptID = pairingAttemptID else { return }
        try? await sendPairingWrapped(
            ClientPairInitMessage(payload: ClientPairInitPayload(pairingIndex: attempt.pairingIndex, commitB: nil)),
            attemptID: attemptID
        )
    }

    /// Close the connection-scoped authorization window. The snapshot's
    /// lifetime is the public authorization state, so clearing it emits exactly
    /// one nil event even if a close races expiry or finalization.
    func closePairingWindow(for attemptID: PairingAttemptID? = nil, cancelTask: Bool = true) {
        guard attemptID == nil || pairingWindowAttemptID == attemptID else { return }
        let hadPublicWindow = pairingWindowExpiresAt != nil
        pairingWindowOpen = false
        pairingWindowFailedConfirmations = 0
        pairingWindowAttemptID = nil
        pairingWindowExpiresAt = nil
        if cancelTask {
            pairingWindowTask?.cancel()
        }
        pairingWindowTask = nil
        if hadPublicWindow {
            controlSink.enqueue(.pairingWindowChanged(nil))
        }
    }

    /// Expiry runs in the window task itself, so it must clear the state without
    /// cancelling that currently executing task.
    func expirePairingWindow(for attemptID: PairingAttemptID) {
        guard pairingWindowAttemptID == attemptID, pairingWindowExpiresAt != nil else { return }
        closePairingWindow(for: attemptID, cancelTask: false)
    }

    func cancelPairing(attemptID: PairingAttemptID) async throws {
        if pairingWindowAttemptID == attemptID {
            closePairingWindow()
            guard let activeID = pairingAttemptID else { return }
            await abortPairingAttempt(reason: .userCancelled, attemptID: activeID)
            return
        }
        guard pairingAttemptID == attemptID else { throw SendspinClientError.stalePairingAttempt(attemptID) }
        guard dynamicPairingAttempt != nil || staticPairingAttempt != nil || pendingPairingPsk != nil || pairingAttemptActive else {
            closePairingWindow()
            throw SendspinClientError.stalePairingAttempt(attemptID)
        }
        closePairingWindow()
        discardingPairingMessages = true
        clearPairingAttempt(reason: .userCancelled)
        guard pairingAttemptID == nil else { return }
        pairingAbortAuthorization = attemptID
        try? await sendPairingWrapped(
            PairAbortMessage(payload: PairAbortPayload(reason: .userCancelled)),
            attemptID: attemptID,
            allowClearedAbort: true
        )
    }

    func handleServerPairInit(_ message: ServerPairInitMessage) async throws {
        if discardingPairingMessages {
            return
        }
        guard var attempt = dynamicPairingAttempt, attempt.pairInitSent,
              attempt.cpace == nil, attempt.serverShare == nil
        else { throw PairingProtocolError.invalidSequence }
        guard let authorizedAttemptID = pairingAttemptID else { return }
        if attempt.prs == nil {
            guard let encodedNonceA = message.payload.nonceA,
                  let nonceA = Base64URL.decode(encodedNonceA, count: 32)
            else { throw PairingProtocolError.invalidSequence }
            attempt.nonceA = nonceA
            var input = Data("sendspin-pairing-code-derive-v1".utf8)
            #if DEBUG
                input.append(pairingHandshakeHashOverride ?? channel.handshakeHash)
            #else
                input.append(channel.handshakeHash)
            #endif
            input.append(nonceA); input.append(attempt.nonceB)
            let digest = Data(SHA256.hash(data: input))
            let prs: Data
            let emission: PairingCodeEmission
            switch attempt.format {
            case .digits:
                var value: UInt64 = 0
                for byte in digest {
                    value = (value * 256 + UInt64(byte)) % 1_000_000
                }
                prs = Data(String(format: "%06llu", value).utf8)
                emission = PairingCodeEmission(
                    format: .digits,
                    payload: String(data: prs, encoding: .utf8)!,
                    languages: serverLanguages
                )
            case .qrCode:
                prs = digest.prefix(24)
                emission = PairingCodeEmission(format: .qrCode, payload: PairingToken.dynamicCodeToken(Data(prs)), languages: serverLanguages)
            }
            attempt.prs = prs
            attempt.emission = emission
        } else {
            guard message.payload.nonceA == nil else {
                throw PairingProtocolError.invalidSequence
            }
            attempt.clientConfirmationSent = false
            attempt.serverShare = nil
            attempt.secrets = nil
            attempt.sid = nil
            attempt.cpace = nil
        }
        guard let prs = attempt.prs, let emission = attempt.emission else { throw PairingProtocolError.invalidSequence }
        guard let pairingStore else {
            await failPairingStorage(for: authorizedAttemptID)
            return
        }
        guard pairingAttemptID == authorizedAttemptID, pairingAttemptActive else { return }
        let reservation: DynamicPairingRoundReservation
        do {
            reservation = try await pairingStore.reserveDynamicPairingRound(limit: dynamicPairingRoundLimit)
        } catch {
            Log.client.error("Dynamic pairing budget reservation failed: \(error.localizedDescription)")
            await failPairingStorage(for: authorizedAttemptID)
            return
        }
        // An attempt superseded during the store await consumes a round without emitting.
        // This only reduces remaining attempts, never exceeds the limit; a refund requires
        // a persistence API.
        guard pairingAttemptID == authorizedAttemptID, pairingAttemptActive else { return }
        guard case .reserved = reservation else {
            await abortPairingAttempt(reason: .pairingCodeMismatch, attemptID: authorizedAttemptID)
            return
        }
        // Each emitted round consumes global budget, but its sid counts only this attempt.
        attempt.round += 1
        enqueuePairingCode(emission)
        #if DEBUG
            let pairingHandshakeHash = pairingHandshakeHashOverride ?? channel.handshakeHash
        #else
            let pairingHandshakeHash = channel.handshakeHash
        #endif
        let sid = CPaceSessionIdentifier.make(
            handshakeHash: pairingHandshakeHash,
            counter: attempt.pairingIndex,
            round: attempt.round
        )
        attempt.sid = sid
        attempt.cpace = try CPace(
            role: .responder,
            prs: prs,
            sid: sid,
            scalarOverride: pairingScalarBOverride
        )
        dynamicPairingAttempt = attempt
    }

    func handleServerPairAuth(_ message: ServerPairAuthMessage) async throws {
        if discardingPairingMessages {
            return
        }
        if var attempt = dynamicPairingAttempt, attempt.serverShare == nil,
           let cpace = attempt.cpace,
           let share = Base64URL.decode(message.payload.pakeMsg1, count: 32) {
            attempt.serverShare = share
            attempt.secrets = try cpace.derive(remoteShare: share)
            dynamicPairingAttempt = attempt
            guard let attemptID = pairingAttemptID else { return }
            try await sendPairingWrapped(
                ClientPairAuthMessage(payload: ClientPairAuthPayload(pakeMsg2: Base64URL.encode(cpace.publicShare))),
                attemptID: attemptID
            )
            return
        }
        guard var attempt = staticPairingAttempt, attempt.serverShare == nil,
              let cpace = attempt.cpace,
              let share = Base64URL.decode(message.payload.pakeMsg1, count: 32)
        else { throw PairingProtocolError.invalidSequence }
        attempt.serverShare = share
        attempt.secrets = try cpace.derive(remoteShare: share)
        staticPairingAttempt = attempt
        guard let attemptID = pairingAttemptID else { return }
        try await sendPairingWrapped(
            ClientPairAuthMessage(payload: ClientPairAuthPayload(pakeMsg2: Base64URL.encode(cpace.publicShare))),
            attemptID: attemptID
        )
    }

    func handleServerPairConfirm(_ message: ServerPairConfirmMessage) async throws {
        if discardingPairingMessages {
            return
        }
        if dynamicPairingAttempt != nil {
            try await handleDynamicServerPairConfirm(message)
        } else {
            try await handleStaticServerPairConfirm(message)
        }
    }

    private func handleStaticServerPairConfirm(_ message: ServerPairConfirmMessage) async throws {
        guard var attempt = staticPairingAttempt,
              !attempt.clientConfirmationSent,
              let cpace = attempt.cpace,
              let secrets = attempt.secrets,
              let serverShare = attempt.serverShare,
              let tag = Base64URL.decode(message.payload.serverKc, count: 64)
        else { throw PairingProtocolError.invalidSequence }
        guard CPaceX25519.constantTimeEqual(
            tag,
            CPaceX25519.mcfTag(isk: secrets.isk, sid: attempt.sid, share: serverShare, associatedData: CPaceX25519.defaultInitiatorAD)
        ) else {
            guard let attemptID = pairingAttemptID else { return }
            if pairingWindowOpen {
                pairingWindowFailedConfirmations += 1
                if pairingWindowFailedConfirmations >= staticPairingWindowFailureLimit {
                    closePairingWindow()
                }
            }
            await abortPairingAttempt(reason: .pairingCodeMismatch, attemptID: attemptID)
            return
        }
        guard let authorizedAttemptID = pairingAttemptID else { return }
        let generated = await selectPairingLongTermPsk()
        guard pairingAttemptID == authorizedAttemptID, pairingAttemptActive else { return }
        pendingPairingPsk = generated
        attempt.clientConfirmationSent = true
        staticPairingAttempt = attempt
        let clientTag = CPaceX25519.mcfTag(
            isk: secrets.isk,
            sid: attempt.sid,
            share: cpace.publicShare,
            associatedData: CPaceX25519.defaultResponderAD
        )
        try await sendPairingWrapped(ClientPairConfirmMessage(
            payload: ClientPairConfirmPayload(
                clientKc: Base64URL.encode(clientTag),
                wrappedNonceB: nil
            )
        ), attemptID: authorizedAttemptID)
        let wrappedPsk = try PairingWrap.wrap(
            plaintext: generated.bytes,
            label: Data("sendspin-pair-psk-wrap-v1".utf8),
            sid: attempt.sid,
            isk: secrets.isk,
            suite: suite
        )
        try await sendPairingWrapped(ClientPairFinalizeMessage(
            payload: ClientPairFinalizePayload(wrappedPsk: Base64URL.encode(wrappedPsk))
        ), attemptID: authorizedAttemptID)
    }

    private func handleDynamicServerPairConfirm(_ message: ServerPairConfirmMessage) async throws {
        guard let authorizedAttemptID = pairingAttemptID else { return }
        guard var attempt = dynamicPairingAttempt,
              !attempt.clientConfirmationSent,
              let sid = attempt.sid,
              let cpace = attempt.cpace,
              let secrets = attempt.secrets,
              let serverShare = attempt.serverShare,
              let tag = Base64URL.decode(message.payload.serverKc, count: 64)
        else { throw PairingProtocolError.invalidSequence }
        let expected = CPaceX25519.mcfTag(isk: secrets.isk, sid: sid, share: serverShare, associatedData: CPaceX25519.defaultInitiatorAD)
        guard CPaceX25519.constantTimeEqual(tag, expected) else {
            guard let pairingStore else {
                await failPairingStorage(for: authorizedAttemptID)
                return
            }
            let count: UInt32
            do {
                count = try await pairingStore.dynamicPairingRoundCount()
            } catch {
                Log.client.error("Dynamic pairing budget read failed: \(error.localizedDescription)")
                await failPairingStorage(for: authorizedAttemptID)
                return
            }
            guard pairingAttemptID == authorizedAttemptID, pairingAttemptActive else { return }
            if count < dynamicPairingRoundLimit {
                attempt.serverShare = nil
                attempt.cpace = nil
                attempt.secrets = nil
                attempt.sid = nil
                dynamicPairingAttempt = attempt
                guard pairingAttemptID == authorizedAttemptID, pairingAttemptActive else { return }
                try? await sendPairingWrapped(
                    ClientPairRetryMessage(payload: ClientPairRetryPayload()),
                    attemptID: authorizedAttemptID
                )
                guard pairingAttemptID == authorizedAttemptID, pairingAttemptActive else { return }
                // The server starts the next round; binding values and the timeout stay in place.
            } else {
                guard pairingAttemptID == authorizedAttemptID, pairingAttemptActive else { return }
                await abortPairingAttempt(reason: .pairingCodeMismatch, attemptID: authorizedAttemptID)
            }
            return
        }
        do {
            try await pairingStore?.resetDynamicPairingBudget()
        } catch {
            Log.client.error("Dynamic pairing budget reset failed: \(error.localizedDescription)")
            guard pairingAttemptID == authorizedAttemptID, pairingAttemptActive else { return }
            clearPairingAttempt()
            disconnectReason = .connectionLost(nil)
            await transport.disconnect()
            return
        }
        guard pairingAttemptID == authorizedAttemptID, pairingAttemptActive else { return }
        let clientTag = CPaceX25519.mcfTag(
            isk: secrets.isk,
            sid: sid,
            share: cpace.publicShare,
            associatedData: CPaceX25519.defaultResponderAD
        )
        let wrappedNonce = try PairingWrap.wrap(
            plaintext: attempt.nonceB,
            label: Data("sendspin-pair-nonce-wrap-v1".utf8),
            sid: sid,
            isk: secrets.isk,
            suite: suite
        )
        let generated = await selectPairingLongTermPsk()
        guard pairingAttemptID == authorizedAttemptID, pairingAttemptActive else { return }
        pendingPairingPsk = generated
        attempt.clientConfirmationSent = true
        dynamicPairingAttempt = attempt
        try await sendPairingWrapped(ClientPairConfirmMessage(
            payload: ClientPairConfirmPayload(
                clientKc: Base64URL.encode(clientTag),
                wrappedNonceB: Base64URL.encode(wrappedNonce)
            )
        ), attemptID: authorizedAttemptID)
        let wrappedPsk = try PairingWrap.wrap(
            plaintext: generated.bytes,
            label: Data("sendspin-pair-psk-wrap-v1".utf8),
            sid: sid,
            isk: secrets.isk,
            suite: suite
        )
        try await sendPairingWrapped(ClientPairFinalizeMessage(
            payload: ClientPairFinalizePayload(wrappedPsk: Base64URL.encode(wrappedPsk))
        ), attemptID: authorizedAttemptID)
    }

    func pairingAttemptTimedOut(attemptID: PairingAttemptID?) async {
        guard let attemptID, pairingAttemptID == attemptID else { return }
        // A stale wake (its handle was cancelled and replaced by a newer attempt
        // or teardown) must not detach the newer handle or abort the fresh attempt.
        guard !Task.isCancelled else { return }
        guard pendingPairingPsk != nil || dynamicPairingAttempt != nil || staticPairingAttempt != nil else { return }
        // Detach this task's handle before clear: clearPairingAttempt cancels the
        // owned task, which would self-cancel the abort send below.
        pairingAttemptTask = nil
        await abortPairingAttempt(reason: .attemptTimeout, attemptID: attemptID)
    }

    private func failPairingStorage(for attemptID: PairingAttemptID) async {
        guard pairingAttemptID == attemptID else { return }
        clearPairingAttempt()
        disconnectReason = .connectionLost(nil)
        await transport.disconnect()
    }

    private func abortPairingAttempt(reason: PairAbortReason, attemptID: PairingAttemptID) async {
        guard pairingAttemptID == attemptID else { return }
        pairingAbortAuthorization = attemptID
        discardingPairingMessages = true
        clearPairingAttempt(reason: reason)
        try? await sendPairingWrapped(
            PairAbortMessage(payload: PairAbortPayload(reason: reason)),
            attemptID: attemptID,
            allowClearedAbort: true
        )
    }

    func clearPairingAttempt(reason: PairAbortReason? = nil, emitCodeRemoval: Bool = true) {
        if let reason, let id = pairingAttemptID, let peer = pairingAttemptPeer {
            let snapshot = PairingAttemptSnapshot(id: id, peer: peer, phase: .ended(reason), code: nil)
            controlSink.enqueue(.pairingAttemptEnded(snapshot))
            controlSink.enqueue(.pairingCodeChanged(snapshot))
        }
        if emitCodeRemoval, reason == nil, pairingAttemptID != nil {
            enqueuePairingCode(nil)
        }
        pairingAttemptActive = false
        pendingPairingPsk = nil
        dynamicPairingAttempt = nil
        staticPairingAttempt = nil
        pairingAttemptTask?.cancel()
        pairingAttemptTask = nil
        pairingAttemptID = nil
        pairingAttemptPeer = nil
    }

    func handleServerPairFinalize(_: ServerPairFinalizeMessage) async throws {
        if discardingPairingMessages {
            return
        }
        guard let generated = pendingPairingPsk, let pairingStore else { throw PairingProtocolError.invalidSequence }
        guard let authorizedAttemptID = pairingAttemptID else { return }
        let successSnapshot: PairingAttemptSnapshot? = if let id = pairingAttemptID, let peer = pairingAttemptPeer {
            PairingAttemptSnapshot(id: id, peer: peer, phase: .succeeded, code: nil)
        } else {
            nil
        }
        let records: [PairingRecord]
        do {
            records = try await pairingStore.listRecords()
        } catch {
            await failPairingStorage(for: authorizedAttemptID)
            return
        }
        guard pairingAttemptID == authorizedAttemptID, pairingAttemptActive else { return }
        if records.contains(where: { $0.pskId == generated.pskId }) {
            do {
                try await pairingStore.markUsed(pskId: generated.pskId)
            } catch {
                await failPairingStorage(for: authorizedAttemptID)
                return
            }
            guard pairingAttemptID == authorizedAttemptID, pairingAttemptActive else { return }
            closePairingWindow()
            clearPairingAttempt()
            if let successSnapshot {
                controlSink.enqueue(.paired(successSnapshot))
            }
            return
        }
        do {
            let lease = try await pairingStore.insertOrReplaceAndProtect(
                PairingRecord(psk: generated, serverId: currentServerId)
            )
            guard pairingAttemptID == authorizedAttemptID, pairingAttemptActive else {
                try? await pairingStore.releaseProtection(lease)
                return
            }
            if let incumbentLease = pairingProtectionLease {
                try? await pairingStore.releaseProtection(incumbentLease)
            }
            pairingProtectionLease = lease
            closePairingWindow()
            clearPairingAttempt()
            if let successSnapshot {
                controlSink.enqueue(.paired(successSnapshot))
            }
        } catch {
            guard pairingAttemptID == authorizedAttemptID, pairingAttemptActive else { return }
            Log.client.error("Pairing record persistence failed: \(error.localizedDescription)")
            clearPairingAttempt()
            disconnectReason = .connectionLost(nil)
            await transport.disconnect()
        }
    }

    func handleServerUnpair(_: ServerUnpairMessage) async {
        guard case .longTerm = pskCategory else { return }
        if let pairingStore {
            do {
                let records = try await pairingStore.listRecords()
                if let record = records.first(where: { $0.psk.pskId == matchedPskId }), record.serverId != nil {
                    try await pairingStore.remove(pskId: matchedPskId)
                }
            } catch {
                Log.client.error("Pairing record removal failed: \(error.localizedDescription)")
            }
        }
        try? await sendWrapped(ClientGoodbyeMessage(payload: GoodbyePayload(reason: .unpaired)))
        disconnectReason = .explicit(.unpaired)
        await transport.disconnect()
    }

    func handleServerTime(
        _ message: ServerTimeMessage,
        clientReceived: Int64
    ) async {
        await clock.processServerTime(
            clientTransmitted: message.payload.clientTransmitted,
            serverReceived: message.payload.serverReceived,
            serverTransmitted: message.payload.serverTransmitted,
            clientReceived: clientReceived
        )
        // First-sync flip: once the filter converges, allow chunks through the gate
        // and report readiness — `available` becomes true here, and the spec's
        // initial client/state goes out on this transition.
        if !isClockSynced, await clock.hasSynced {
            isClockSynced = true
            controlSink.enqueue(.clockSyncEstablished)
            try? await publishClientState()
        }

        // Push updated snapshot for sync correction (per-frame cross-boundary).
        if let snapshot = await clock.snapshot() {
            await audioEngine.updateClockSnapshot(snapshot)
        }
    }

    func handleServerState(_ message: ServerStateMessage) async {
        // Metadata and color have no stream boundary: pending updates remain until
        // their translated timestamp, an immediate update, or an explicit role null.
        if case .null = message.payload.metadataRole {
            metadataPending = nil
            metadataScheduleTask?.cancel()
            metadataScheduleTask = nil
            currentMetadata = nil
            controlSink.enqueue(.metadataCleared)
        }
        if let metadata = message.payload.metadata {
            let progress: PlaybackProgress? = switch metadata.progress {
            case let .value(prog):
                PlaybackProgress(
                    trackProgressMs: prog.trackProgress,
                    trackDurationMs: prog.trackDuration,
                    playbackSpeedX1000: prog.playbackSpeed,
                    timestamp: metadata.timestamp ?? MonotonicClock.nowMicroseconds()
                )
            case .null, .absent:
                nil
            }

            // A present role object is a complete snapshot; omitted fields clear
            // their prior values. Only omission of the role object preserves state.
            let trackMetadata = TrackMetadata(
                title: metadata.title.merge(previous: nil),
                artist: metadata.artist.merge(previous: nil),
                album: metadata.album.merge(previous: nil),
                albumArtist: metadata.albumArtist.merge(previous: nil),
                track: metadata.track.merge(previous: nil),
                year: metadata.year.merge(previous: nil),
                artworkURL: metadata.artworkUrl.merge(previous: nil),
                progress: progress
            )
            let timestamp = metadata.timestamp ?? 0
            let localTime = await clock.serverTimeToLocal(timestamp)
            if localTime > scheduleNow() {
                metadataPending = ScheduledMetadata(metadata: trackMetadata, localDisplayTime: localTime)
                metadataScheduleTask?.cancel()
                let sleep = scheduleSleep
                let now = scheduleNow
                metadataScheduleTask = Task { [weak self] in
                    try? await sleep(.microseconds(max(0, localTime - now())))
                    await self?.applyPendingMetadata()
                }
            } else {
                metadataPending = nil
                metadataScheduleTask?.cancel()
                metadataScheduleTask = nil
                currentMetadata = trackMetadata
                controlSink.enqueue(.metadataReceived(trackMetadata))
            }
        }

        // A present controller object is a complete snapshot. `seek_max_ms` is
        // the only optional field and is therefore nil when absent or null.
        if case .null = message.payload.controllerRole {
            currentControllerState = nil
            controlSink.enqueue(.controllerStateCleared)
        }
        if let controller = message.payload.controller {
            let controllerState = ControllerState(
                supportedCommands: controller.supportedCommands.map(Set.init) ?? [],
                volume: controller.volume ?? 0,
                muted: controller.muted ?? false,
                repeatMode: controller.repeat,
                shuffle: controller.shuffle,
                seekMaxMs: controller.seekMaxMsDelta.merge(previous: nil)
            )
            currentControllerState = controllerState
            controlSink.enqueue(.controllerStateUpdated(controllerState))
        }

        await handleColorState(message.payload.color)
    }

    private func handleColorState(_ value: Nullable<ServerColorState>) async {
        // A present color object is a complete snapshot; omitted color fields are nil.
        switch value {
        case .absent:
            break
        case .null:
            currentColorState = nil
            colorPending = nil
            colorScheduleTask?.cancel()
            colorScheduleTask = nil
            controlSink.enqueue(.colorStateCleared)
        case let .value(color):
            let localDisplayTime = await clock.serverTimeToLocal(color.timestamp)
            let colorState = ColorState(
                serverTimestamp: color.timestamp,
                localDisplayTime: localDisplayTime,
                backgroundDark: color.backgroundDark.merge(previous: nil),
                backgroundLight: color.backgroundLight.merge(previous: nil),
                primary: color.primary.merge(previous: nil),
                accent: color.accent.merge(previous: nil),
                onDark: color.onDark.merge(previous: nil),
                onLight: color.onLight.merge(previous: nil)
            )
            if localDisplayTime > scheduleNow() {
                colorPending = ScheduledColor(color: colorState, localDisplayTime: localDisplayTime)
                colorScheduleTask?.cancel()
                let sleep = scheduleSleep
                let now = scheduleNow
                colorScheduleTask = Task { [weak self] in
                    try? await sleep(.microseconds(max(0, localDisplayTime - now())))
                    await self?.applyPendingColor()
                }
            } else {
                colorPending = nil
                colorScheduleTask?.cancel()
                colorScheduleTask = nil
                currentColorState = colorState
                controlSink.enqueue(.colorStateUpdated(colorState))
            }
        }
    }

    private func applyPendingColor() {
        guard let pending = colorPending, pending.localDisplayTime <= scheduleNow() else { return }
        colorPending = nil
        colorScheduleTask = nil
        currentColorState = pending.color
        controlSink.enqueue(.colorStateUpdated(pending.color))
    }

    // swiftlint:disable:next function_body_length
    func handleStreamStart(_ message: StreamStartMessage) async {
        // Handle artwork stream
        if let artworkInfo = message.payload.artwork {
            let previous = artworkStreamChannels
            artworkStreamChannels = artworkInfo.channels
            artworkStreamActive = true
            for channel in 0 ..< max(previous.count, artworkInfo.channels.count) {
                let oldConfig = previous.indices.contains(channel) ? previous[channel] : nil
                let newConfig = artworkInfo.channels.indices.contains(channel) ? artworkInfo.channels[channel] : nil
                if oldConfig?.source != newConfig?.source || oldConfig?.format != newConfig?.format
                    || oldConfig?.width != newConfig?.width || oldConfig?.height != newConfig?.height {
                    invalidateArtworkDelivery()
                    clearPendingArtwork(channel: channel)
                    if artworkTransfer?.channel == channel {
                        artworkTransfer = nil
                    }
                }
            }
            controlSink.enqueue(.artworkStreamStarted(artworkInfo.channels))
        }

        // Handle visualizer stream. The server's configuration is authoritative for
        // decoding each subsequent binary type until stream/end.
        if let visualizerInfo = message.payload.visualizer {
            let isValid = !visualizerInfo.types.isEmpty
                && visualizerInfo.rateMax > 0
                && visualizerInfo.types.contains(.spectrum) == (visualizerInfo.spectrum != nil)
                && visualizerInfo.types.contains(.beat) == (visualizerInfo.tracksDownbeats != nil)
                && (visualizerInfo.spectrum.map { $0.nDispBins > 0 && $0.fMin >= 0 && $0.fMax > $0.fMin } ?? true)
                && (visualizerState.map { requested in
                    visualizerInfo.types.allSatisfy { requested.types.contains($0) }
                        && visualizerInfo.rateMax <= requested.rateMax
                        && visualizerInfo.spectrum == requested.spectrum
                } ?? false)
            if !isValid {
                Log.client.warning("Discarding invalid visualizer stream configuration")
                visualizerStreamActive = false
                visualizerStreamConfiguration = nil
                resetVisualizerDelivery(resetTimestampFloor: true)
            } else {
                let startsNewStream = !visualizerStreamActive
                if startsNewStream {
                    resetVisualizerDelivery(resetTimestampFloor: true)
                }
                visualizerStreamConfiguration = VisualizerStreamConfiguration(
                    types: visualizerInfo.types,
                    rateMax: visualizerInfo.rateMax,
                    tracksDownbeats: visualizerInfo.tracksDownbeats,
                    spectrum: visualizerInfo.spectrum
                )
                visualizerStreamActive = true
                if let visualizerStreamConfiguration {
                    controlSink.enqueue(.visualizerStreamStarted(visualizerStreamConfiguration))
                }
            }
        }

        // Handle player stream
        guard let playerInfo = message.payload.player else {
            Log.client.info("stream/start: artwork only (no player payload)")
            return
        }

        // Open gate BEFORE validation (must stay open on failure for recovery)
        playerStreamActive = true

        Log.client.info("stream/start: \(playerInfo.codec) \(playerInfo.sampleRate)Hz \(playerInfo.channels)ch \(playerInfo.bitDepth)bit")

        // Validate codec
        guard let codec = AudioCodec(rawValue: playerInfo.codec) else {
            clientOperationalState = .error
            controlSink.enqueue(.streamError(.unsupportedCodec(playerInfo.codec)))
            controlSink.enqueue(.operationalState(.error))
            try? await publishClientState()
            return
        }

        // Validate format
        let format: AudioFormatSpec
        do {
            format = try AudioFormatSpec(
                codec: codec,
                channels: playerInfo.channels,
                sampleRate: playerInfo.sampleRate,
                bitDepth: playerInfo.bitDepth
            )
        } catch {
            clientOperationalState = .error
            controlSink.enqueue(.streamError(.invalidFormat(error.errorDescription ?? "\(error)")))
            controlSink.enqueue(.operationalState(.error))
            try? await publishClientState()
            return
        }

        var transitionPolicy: AudioFormatTransitionPolicy?
        if outputSampleRatePolicy == .requireCurrentOutput {
            switch await handleOutputFormatStreamStart(format) {
            case .rejected:
                return
            case let .accepted(policy):
                transitionPolicy = policy
            }
        }

        // Parse codec header. A present-but-malformed (non-base64) header is a
        // corrupt stream/start, not an absent header: surface it as a format error
        // rather than starting headerless (which, for FLAC, fails every decode
        // silently and produces permanent silence with no error reported).
        var codecHeader: Data?
        if let headerBase64 = playerInfo.codecHeader {
            guard let decoded = Data(base64Encoded: headerBase64) else {
                clientOperationalState = .error
                controlSink.enqueue(.streamError(.invalidFormat("codec_header is not valid base64")))
                controlSink.enqueue(.operationalState(.error))
                try? await publishClientState()
                return
            }
            codecHeader = decoded
        }

        // Classification uses the wire-announced format and header before any await.
        // An identical active-stream announcement preserves the existing audio timeline.
        let previous = announcedPlayerStream
        let isFormatChange = previous.map { $0.format != format || $0.codecHeader != codecHeader } ?? false
        announcedPlayerStream = (format: format, codecHeader: codecHeader)
        if outputSampleRatePolicy != .requireCurrentOutput, previous == nil || isFormatChange || pendingOutputFormatRequest != nil {
            if case let .accepted(policy) = await handleOutputFormatStreamStart(format) {
                transitionPolicy = policy
            }
        }

        let failed = if case .failed = playerStartState {
            true
        } else {
            false
        }
        if previous != nil, !isFormatChange, !failed {
            if routeInvalidationPending || transitionPolicy == .routeInvalidated {
                if format.sampleRate == outputSnapshot?.sampleRate {
                    audioEngine.clearRouteInvalidation()
                    routeInvalidationPending = false
                    transitionPolicy = .ordered
                } else if pendingOutputFormatRequest != nil {
                    routeInvalidationPending = true
                    return
                } else {
                    transitionPolicy = .routeInvalidated
                    routeInvalidationPending = false
                }
            }
            if transitionPolicy != .routeInvalidated {
                if case .started = playerStartState, clientOperationalState == .error {
                    clientOperationalState = .synchronized
                    controlSink.enqueue(.operationalState(.synchronized))
                    try? await publishClientState()
                }
                return
            }
        }
        if routeInvalidationPending {
            transitionPolicy = .routeInvalidated
            routeInvalidationPending = false
        }
        // Sibling report and message tasks require identity before enqueue to protect newer starts.
        playerStartGeneration &+= 1
        let generation = playerStartGeneration
        playerStartState = .pending(generation)
        controlSink.enqueue(.streamAccepted(format))
        if previous == nil || failed {
            if clientOperationalState == .error {
                clientOperationalState = .synchronized
                controlSink.enqueue(.operationalState(.synchronized))
                try? await publishClientState()
            }
            audioEngine.enqueueStreamStart(format: format, codecHeader: codecHeader, startGeneration: generation)
        } else if transitionPolicy == .routeInvalidated {
            audioEngine.enqueueRouteInvalidatedFormatChange(format: format, codecHeader: codecHeader, startGeneration: generation)
        } else {
            audioEngine.commands.enqueue(.withStartGeneration(generation, .formatChange(format, codecHeader: codecHeader)))
        }
    }

    func handleStreamClear(_ message: StreamClearMessage) async {
        let roles = message.payload.roles

        if roles == nil || roles?.contains("player") == true {
            audioEngine.commands.enqueue(.streamClear(roles: roles))
        }
        if roles == nil || roles?.contains("visualizer") == true {
            resetVisualizerDelivery(resetTimestampFloor: true)
        }
        // stream/clear invalidates queued visualizer frames without ending the negotiated stream.

        controlSink.enqueue(.streamCleared(roles: roles))
    }

    func handleStreamEnd(_ message: StreamEndMessage) async {
        let endedRoles = message.payload.roles

        if endedRoles == nil || endedRoles?.contains("player") == true {
            playerStreamActive = false
            audioEngine.enqueueStreamEnd(roles: endedRoles)
            announcedPlayerStream = nil
            playerStartState = .none
            resetOutputFormatNegotiationForStreamBoundary()
        }

        if endedRoles == nil || endedRoles?.contains("artwork") == true {
            invalidateArtworkDelivery()
            artworkStreamActive = false
            artworkTransfer = nil
            clearPendingArtwork()
        }

        if endedRoles == nil || endedRoles?.contains("visualizer") == true {
            visualizerStreamActive = false
            visualizerStreamConfiguration = nil
            resetVisualizerDelivery(resetTimestampFloor: true)
        }

        // Per spec, entering external_source causes the server to end active streams.
        // That cleanup must not be interpreted as leaving external_source; only the
        // explicit exitExternalSource() path restores synchronized participation.
        if clientOperationalState != .externalSource {
            clientOperationalState = .synchronized
        }

        controlSink.enqueue(.streamEnded(roles: endedRoles))
    }

    func handleServerCommand(_ message: ServerCommandMessage) async {
        guard let playerCmd = message.payload.player else { return }

        // Apply commands only when advertised and when their argument shape is exact.
        guard advertisedCommands.contains(playerCmd.command) else {
            Log.client.debug("Ignoring server/command: not in advertised supported_commands")
            return
        }

        switch playerCmd.command {
        case .volume:
            guard let volume = playerCmd.volume, (0 ... 100).contains(volume),
                  playerCmd.mute == nil, playerCmd.outputDelayMs == nil else {
                Log.client.debug("Ignoring malformed server/command volume")
                return
            }
            currentVolume = volume
            await audioEngine.setGain(Float(volume) / 100.0)
            controlSink.enqueue(.playerVolumeChanged(volume))
            try? await publishClientState()

        case .mute:
            guard let mute = playerCmd.mute,
                  playerCmd.volume == nil, playerCmd.outputDelayMs == nil else {
                Log.client.debug("Ignoring malformed server/command mute")
                return
            }
            currentMuted = mute
            await audioEngine.setMuted(mute)
            controlSink.enqueue(.playerMutedChanged(mute))
            try? await publishClientState()

        case .setOutputDelay:
            guard let delayMs = playerCmd.outputDelayMs,
                  (0 ... maxOutputDelayMs).contains(delayMs),
                  playerCmd.volume == nil, playerCmd.mute == nil else {
                Log.client.debug("Ignoring malformed server/command set_output_delay")
                return
            }
            currentOutputDelayMs = delayMs
            audioEngine.commands.enqueue(.setOutputDelay(delayMs))
            controlSink.enqueue(.outputDelayChanged(milliseconds: delayMs))
            try? await publishClientState()
        }
    }

    func handleGroupUpdate(_ message: GroupUpdateMessage) async {
        let info = GroupInfo(
            groupId: message.payload.groupId,
            groupName: message.payload.groupName,
            playbackState: message.payload.playbackState
        )
        currentGroup = info
        controlSink.enqueue(.groupUpdated(info))

        // If group update indicates playback is playing and we have a server ID, emit lastPlayedServerChanged
        if message.payload.playbackState == .playing, let serverId = currentServerId {
            controlSink.enqueue(.lastPlayedServerChanged(serverId: serverId))
        }
    }

    // MARK: - Binary message handlers

    func handleAudioChunk(_ message: BinaryMessage, arrival: Int64 = MonotonicClock.absoluteMicroseconds()) async {
        guard playerStateSent, playerStreamActive else {
            Log.client.warning("Discarding audio chunk: player state or stream is not active")
            return
        }

        await recordArrivalDelay(message: message, arrival: arrival)

        if emitRawAudio {
            let chunk = AudioChunk(
                data: message.data,
                serverTimestamp: message.timestamp,
                sendAhead: message.sendAhead
            )
            if let dataDelivery {
                dataDelivery.yieldAudioIfValid(chunk, validity: validity)
            } else {
                validity.yieldIfValid(chunk, to: audioSink)
            }
        }

        // Only enqueue to engine if clock is synced. Tag the frame at ingress so a format
        // announcement invalidates chunks already waiting in the FIFO before they are decoded.
        if isClockSynced {
            audioEngine.enqueueAudioChunk(
                data: message.data,
                timestamp: message.timestamp,
                sendAhead: message.sendAhead
            )
        }
    }

    func handleArtworkBinary(_ raw: Data) async throws {
        let message = try ArtworkWireMessage(data: raw)
        if message.isAnnounce {
            guard artworkTransfer == nil else { throw ArtworkTransferError.announceWhileInFlight }
            guard let timestamp = message.timestamp, let totalSize = message.totalSize else { throw ArtworkTransferError.tooShort }
            // A new announce replaces the channel's pending image immediately, even
            // when this transfer is gated and its completed bytes will be discarded.
            clearPendingArtwork(channel: message.channel)
            let deliver = artworkStreamActive && artworkStateSent && channelIsEnabled(message.channel)
            artworkTransfer = ArtworkTransfer(channel: message.channel, timestamp: timestamp, totalSize: totalSize, deliver: deliver)
            if totalSize == 0 {
                let result = try completeArtworkTransfer()
                if result.deliver {
                    await receiveCompletedArtwork(result)
                }
            }
        } else if message.isCancel {
            // Cancel discards the in-flight transfer as well as any pending image;
            // the current image remains untouched until a completed image is applied.
            if artworkTransfer?.channel == message.channel {
                artworkTransfer = nil
            }
            clearPendingArtwork(channel: message.channel)
        } else {
            guard var transfer = artworkTransfer else { throw ArtworkTransferError.partWithoutTransfer }
            guard transfer.channel == message.channel else { throw ArtworkTransferError.partWrongChannel }
            if let result = try transfer.append(message.data) {
                artworkTransfer = nil
                if result.deliver {
                    await receiveCompletedArtwork(result)
                }
            } else {
                artworkTransfer = transfer
            }
        }
    }

    private func completeArtworkTransfer() throws -> ArtworkTransferResult {
        guard let transfer = artworkTransfer else { throw ArtworkTransferError.partWithoutTransfer }
        guard transfer.received == transfer.totalSize else { throw ArtworkTransferError.partPastTotalSize }
        artworkTransfer = nil
        return ArtworkTransferResult(channel: transfer.channel, timestamp: transfer.timestamp, data: transfer.data, deliver: transfer.deliver)
    }

    private func channelIsEnabled(_ channel: Int) -> Bool {
        guard artworkStateSent else { return false }
        guard artworkStreamChannels.indices.contains(channel) else { return false }
        return artworkStreamChannels[channel].source != .none
    }

    private func invalidateArtworkDelivery() {
        artworkDeliveryValidity.invalidate()
        artworkDeliveryValidity = SessionValidityToken()
    }

    private func receiveCompletedArtwork(_ result: ArtworkTransferResult) async {
        let deliveryValidity = artworkDeliveryValidity
        let localTime = await clock.serverTimeToLocal(result.timestamp)
        guard deliveryValidity === artworkDeliveryValidity else { return }
        let artwork = ArtworkData(channel: result.channel, data: result.data, localDisplayTime: localTime)
        let now = scheduleNow()
        if localTime <= now {
            artworkPending[result.channel] = nil
            artworkScheduleTasks[result.channel]?.cancel()
            artworkScheduleTasks[result.channel] = nil
            if let dataDelivery {
                dataDelivery.yieldArtworkIfValid(artwork, validity: validity, deliveryValidity: deliveryValidity)
            } else {
                artworkObserver?(artwork)
                validity.yieldIfValid(artwork, to: artworkSink)
            }
        } else {
            artworkPending[result.channel] = ScheduledArtwork(artwork: artwork, localDisplayTime: localTime)
            artworkScheduleTasks[result.channel]?.cancel()
            let sleep = scheduleSleep
            let now = scheduleNow
            artworkScheduleTasks[result.channel] = Task { [weak self] in
                let delay = Duration.microseconds(localTime - now())
                try? await sleep(delay)
                await self?.applyPendingArtwork(channel: result.channel, deliveryValidity: deliveryValidity)
            }
        }
    }

    private func applyPendingArtwork(channel: Int, deliveryValidity: SessionValidityToken) {
        guard deliveryValidity === artworkDeliveryValidity else { return }
        guard let pending = artworkPending[channel], pending.localDisplayTime <= scheduleNow() else { return }
        artworkPending[channel] = nil
        artworkScheduleTasks[channel] = nil
        if let dataDelivery {
            dataDelivery.yieldArtworkIfValid(pending.artwork, validity: validity, deliveryValidity: deliveryValidity)
        } else {
            artworkObserver?(pending.artwork)
            validity.yieldIfValid(pending.artwork, to: artworkSink)
        }
    }

    private func recordArrivalDelay(message: BinaryMessage, arrival: Int64) async {
        // Samples are meaningful only after the clock filter converges.
        guard message.sendAhead != 0, message.sendAhead != UInt32.max,
              await clock.hasSynced else {
            return
        }
        let (transmitTimestamp, overflow) = message.timestamp.subtractingReportingOverflow(Int64(message.sendAhead))
        guard !overflow else { return }
        let expectedArrival = await clock.serverTimeToLocal(transmitTimestamp)
        let delay = arrival - expectedArrival
        // Negative delay means the message arrived before its advertised transmit time.
        guard delay >= 0 else { return }
        arrivalDelaySamples.append(delay)
        if arrivalDelaySamples.count > 128 {
            arrivalDelaySamples.removeFirst()
        }
        guard arrivalDelaySamples.count >= 16 else {
            return
        }
        let sorted = arrivalDelaySamples.sorted()
        let index = min(sorted.count - 1, (sorted.count * 95) / 100)
        let estimateMs = max(0, Int((sorted[index] + 999) / 1_000))
        let target = max(minBufferMs, estimateMs)
        if target == lastPublishedMinBufferMs {
            minBufferPersistenceCount = 0
            return
        }
        minBufferPersistenceCount += 1
        guard minBufferPersistenceCount >= 4 else { return }
        minBufferPersistenceCount = 0
        derivedMinBufferMs = target
        lastPublishedMinBufferMs = target
        try? await publishClientState()
    }

    private func applyPendingMetadata() {
        guard let pending = metadataPending, pending.localDisplayTime <= scheduleNow() else { return }
        metadataPending = nil
        metadataScheduleTask = nil
        currentMetadata = pending.metadata
        controlSink.enqueue(.metadataReceived(pending.metadata))
    }

    private func clearPendingArtwork(channel: Int) {
        artworkPending[channel] = nil
        artworkScheduleTasks[channel]?.cancel()
        artworkScheduleTasks[channel] = nil
    }

    private func clearPendingArtwork() {
        for channel in artworkPending.keys {
            clearPendingArtwork(channel: channel)
        }
    }

    func handleVisualizerBinary(_ message: BinaryMessage, arrival: Int64 = MonotonicClock.absoluteMicroseconds()) async {
        guard visualizerStateSent, visualizerStreamActive,
              activeRoles.contains(.visualizerV1),
              let configuration = visualizerStreamConfiguration,
              let type = message.type.visualizerType,
              configuration.types.contains(type) else {
            Log.client.warning("Discarding visualizer binary: visualizer state, stream, role, or type is not active")
            return
        }

        guard VisualizerBinaryPayloadValidator.isValid(
            type: type,
            data: message.data,
            configuration: configuration
        ) else {
            Log.client.warning("Discarding malformed visualizer binary payload for \(type.rawValue, privacy: .public)")
            return
        }

        guard isClockSynced else {
            Log.client.warning("Discarding visualizer binary: clock is not synced")
            return
        }

        let localDisplayTime = await clock.serverTimeToLocal(message.timestamp)
        guard localDisplayTime > arrival else {
            Log.client.warning("Discarding stale visualizer binary")
            return
        }
        if let floor = visualizerTimestampFloor, localDisplayTime < floor {
            Log.client.warning("Discarding out-of-order visualizer binary")
            return
        }
        visualizerTimestampFloor = localDisplayTime
        let visualizerData = VisualizerFrame(
            type: type,
            data: message.data,
            presentationTime: PresentationInstant(rawMicroseconds: localDisplayTime),
            configuration: configuration,
            validity: visualizerFrameValidity
        )
        if let dataDelivery {
            dataDelivery.offerVisualizerIfValid(visualizerData, validity: validity)
        } else if let visualizerDelivery {
            validity.offerIfValid(visualizerData, to: visualizerDelivery)
        } else {
            validity.yieldIfValid(visualizerData, to: visualizerSink)
        }
    }

    private func resetVisualizerDelivery(resetTimestampFloor: Bool) {
        visualizerFrameValidity.invalidate()
        visualizerFrameValidity = VisualizerFrameValidity()
        if let dataDelivery {
            dataDelivery.clearVisualizer()
        } else {
            visualizerDelivery?.clear()
        }
        if resetTimestampFloor {
            visualizerTimestampFloor = nil
        }
    }
}
