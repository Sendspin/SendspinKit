import CryptoKit
import Foundation
import os

enum PairingProtocolError: Error {
    case invalidSequence
}

extension SendspinConnection {
    // MARK: - Frame routing

    /// Route a text frame: classify and dispatch.
    func route(text: String, clientReceived: Int64) async {
        guard let data = text.data(using: .utf8) else { return }

        guard let msgType = SendspinEncoding.messageType(of: data) else {
            Log.client.error("Message missing 'type' field: \(text.prefix(200))")
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
                clearPairingAttempt(reason: abort.payload.reason)

            case "client/pair-pending", "client/pair-init", "client/pair-auth", "client/pair-confirm":
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
                || msgType == "server/pair-init"
                || msgType == "server/pair-auth"
                || msgType == "server/pair-confirm"
                || msgType == "client/pair-pending"
                || msgType == "client/pair-init"
                || msgType == "client/pair-auth"
                || msgType == "client/pair-confirm"
                || msgType == "pair/abort"
                || (msgType == ServerHelloMessage.typeString && awaitingRehandshakeActivation) {
                disconnectReason = .incompatibleServer
                await transport.disconnect()
            }
        }
    }

    /// Route a binary frame to the matching role data stream if its stream gate is open.
    func route(binary data: Data) async {
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
        guard let message = BinaryMessage(data: data) else {
            if data.first == BinaryMessageType.digitAudioClip.rawValue {
                disconnectReason = .incompatibleServer
                await transport.disconnect()
            }
            return
        }

        switch message.type {
        case .audioChunk:
            await handleAudioChunk(message)

        case .digitAudioClip:
            do {
                try handleDigitAudioClip(message)
            } catch {
                disconnectReason = .incompatibleServer
                await transport.disconnect()
            }

        case .visualizerData:
            await handleVisualizerBinary(message)

        default:
            preconditionFailure("Artwork messages are routed by the range pre-check")
        }
    }

    // MARK: - Text message handlers

    func handleRehandshake(_ message: NoiseHandshakeMessage) async {
        guard !rehandshakeInProgress else { return }
        rehandshakeInProgress = true
        do {
            let candidates = await candidateProvider()
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
            let message2 = try handshake.writeMessage2(psk: candidate.psk, payload: noiseMessage2Payload)
            let newTransport = try handshake.makeTransport()
            let reply = NoiseHandshakeMessage(
                payload: NoiseHandshakePayload(data: Base64URL.encode(message2))
            )
            // The gate covers the old-key reply and the synchronous key swap.
            try await sendWrapped(reply, bypassRehandshakeGate: true)
            channel.rekey(to: newTransport)
            pskCategory = candidate.category
            matchedPskId = candidate.psk.pskId
            if candidate.category == .longTerm, let pairingStore {
                await pairingStore.markUsed(pskId: candidate.psk.pskId)
            }
            let advertisement = await livePairingAdvertisement()
            sessionContext = ActivationAdmissibility.SessionContext(
                category: candidate.category,
                unpairedAccessEnabled: advertisement.unpairedAccessEnabled,
                offeredPairMethods: advertisement.offeredPairMethods
            )
            activeRoles = []
            playerStateSent = false
            visualizerStateSent = false
            clearPairingAttempt()
            pairingActivateCounter = 0
            awaitingRehandshakeActivation = true
            controlSink.enqueue(.serverConnected(ServerInfo(
                serverId: currentServerId ?? "",
                name: serverName,
                trustLevel: candidate.category == .longTerm ? .user : .none,
                activeRoles: [],
                activities: activities
            )))
        } catch {
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
            let speaker = configuration.digitAudio != nil
            methods[PairMethod.dynamicPairingCode] = PairMethodDescriptor(
                outChannels: speaker ? ["display", "speaker"] : ["display"],
                formats: ["digits", "qr_code"],
                digitAudio: configuration.digitAudio
            )
        }
        if configuration.staticPairingCodeIsAdvertised {
            methods[PairMethod.staticPairingCode] = PairMethodDescriptor(locations: ["operator"])
        }
        return (methods, configuration.unpairedAccessEnabled, Set(methods.keys))
    }

    func handleServerHello(_ message: ServerHelloMessage) async {
        guard awaitingRehandshakeActivation else { return }
        serverName = message.payload.name
        let advertisement = await livePairingAdvertisement()
        let hello = ClientHelloPayload(
            name: clientHelloPayload.name,
            deviceInfo: clientHelloPayload.deviceInfo,
            supportedPairMethods: advertisement.supportedPairMethods,
            unpairedAccess: UnpairedAccessAdvertisement(enabled: advertisement.unpairedAccessEnabled),
            supportedRoles: clientHelloPayload.supportedRoles,
            playerV1Support: clientHelloPayload.playerV1Support,
            visualizerV1Support: clientHelloPayload.visualizerV1Support
        )
        do {
            try await sendWrapped(ClientHelloMessage(payload: hello), bypassRehandshakeGate: true)
        } catch {
            return
        }
    }

    func handleServerActivate(_ message: ServerActivateMessage) async {
        let advertisement = await livePairingAdvertisement()
        sessionContext = ActivationAdmissibility.SessionContext(
            category: sessionContext.category,
            unpairedAccessEnabled: advertisement.unpairedAccessEnabled,
            offeredPairMethods: advertisement.offeredPairMethods,
            offeredDynamicFormats: Set(advertisement.supportedPairMethods[PairMethod.dynamicPairingCode]?.formats ?? [])
        )
        let nextActivities = Set(message.payload.activities)
        if nextActivities == [.pairing] {
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
            activities = nextActivities
            let completedRehandshake = awaitingRehandshakeActivation
            if completedRehandshake {
                awaitingRehandshakeActivation = false
            }
            // Full state goes out when a role becomes active (spec client/state);
            // an activate that changes nothing sends nothing.
            let rolesChanged = nextRoles != activeRoles
            activeRoles = nextRoles
            if rolesChanged || completedRehandshake {
                playerStateSent = false
                visualizerStateSent = false
                artworkStateSent = false
                artworkTransfer = nil
            }
            try? await publishClientState(bypassRehandshakeGate: completedRehandshake)
            if completedRehandshake {
                rehandshakeInProgress = false
            }
            controlSink.enqueue(.serverActivated(activities: activities, activeRoles: activeRoles))
            if nextActivities == [.pairing], message.payload.pairing?.method == PairMethod.pairingPsk {
                await beginPairingAttempt()
            } else if nextActivities == [.pairing], message.payload.pairing?.method == PairMethod.dynamicPairingCode {
                await beginDynamicPairingAttempt(format: message.payload.pairing?.format)
            } else if nextActivities == [.pairing], message.payload.pairing?.method == PairMethod.staticPairingCode {
                await beginStaticPairingAttempt(format: message.payload.pairing?.format)
            } else if pendingPairingPsk != nil || dynamicPairingAttempt != nil || staticPairingAttempt != nil {
                if dynamicPairingAttempt != nil {
                    controlSink.enqueue(.pairingCodeChanged(nil))
                }
                clearPairingAttempt()
            }
        case let .close(reason):
            try? await sendWrapped(ClientGoodbyeMessage(payload: GoodbyePayload(reason: reason)))
            disconnectReason = .explicit(reason)
            await transport.disconnect()
        case .abortPairing:
            if pendingPairingPsk != nil || dynamicPairingAttempt != nil || staticPairingAttempt != nil {
                clearPairingAttempt(reason: .methodNotSupported)
            }
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

    func beginPairingAttempt() async {
        guard pskCategory == .pairing,
              pendingPairingPsk == nil,
              dynamicPairingAttempt == nil,
              staticPairingAttempt == nil
        else {
            if pskCategory != .pairing {
                try? await sendWrapped(PairAbortMessage(payload: PairAbortPayload(reason: .methodNotSupported)))
            }
            return
        }
        let generated = await selectPairingLongTermPsk()
        pendingPairingPsk = generated
        pairingAttemptTask?.cancel()
        pairingAttemptTask = Task { [weak self] in
            try? await Task.sleep(for: self?.pairingAttemptTimeout ?? .seconds(120))
            guard !Task.isCancelled else { return }
            await self?.pairingAttemptTimedOut()
        }
        try? await sendWrapped(ClientPairFinalizeMessage(
            payload: ClientPairFinalizePayload(longTermPsk: generated.base64URL)
        ))
    }

    /// The long-term PSK offered in `client/pair-finalize`. Normally freshly
    /// generated; when bounded storage cannot fit a new stored-pubkey record,
    /// the record-mode shared record's PSK is offered instead (spec record mode) —
    /// that record already exists, so the finalize acknowledgement persists nothing.
    /// The PSK is committed to the wire before the server's acknowledgement, so
    /// this choice must happen here, not at persistence time.
    private func selectPairingLongTermPsk() async -> Psk {
        guard let pairingStore,
              let accounting = await pairingStore.storageAccounting(),
              let costIndividual = accounting.costIndividual,
              accounting.free < costIndividual,
              let runtime = pairingConfigurationRuntime
        else {
            return Psk.generate()
        }
        let fallbackId = await runtime.snapshot().recordModePskId
        let records = await pairingStore.listRecords()
        guard let shared = records.first(where: { $0.pskId == fallbackId && $0.serverId == nil }) else {
            // Mis-provisioned fallback: offer a fresh PSK; the insert failure
            // at acknowledgement stays terminal.
            return Psk.generate()
        }
        return shared.psk
    }

    func beginDynamicPairingAttempt(format: String?) async {
        guard pskCategory == .sentinel,
              let rawFormat = format,
              let selectedFormat = PairingCodeFormat(rawValue: rawFormat),
              await dynamicPairingCodeIsOffered(format: selectedFormat)
        else {
            clearPairingAttempt(reason: .methodNotSupported)
            try? await sendWrapped(PairAbortMessage(payload: PairAbortPayload(reason: .methodNotSupported)))
            return
        }
        guard dynamicPairingAttempt == nil, staticPairingAttempt == nil, pendingPairingPsk == nil else {
            try? await sendWrapped(PairAbortMessage(payload: PairAbortPayload(reason: .concurrentAttempt)))
            await transport.disconnect()
            return
        }
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
        let sid = CPaceSessionIdentifier.make(handshakeHash: pairingHandshakeHash, counter: pairingActivateCounter)
        let advertisement = await livePairingAdvertisement()
        let dynamicDescriptor = advertisement.supportedPairMethods[PairMethod.dynamicPairingCode]
        let digitAudioDescriptor = selectedFormat == .digits && dynamicDescriptor?.outChannels?.contains("speaker") == true
            ? dynamicDescriptor?.digitAudio
            : nil
        dynamicPairingAttempt = DynamicPairingAttempt(
            format: selectedFormat,
            pairingIndex: pairingActivateCounter,
            sid: sid,
            nonceB: nonceB,
            commitB: commitB,
            digitAudioDescriptor: digitAudioDescriptor,
            digitAudioValidator: digitAudioDescriptor.map { DigitAudioPackValidator(descriptor: $0) },
            nonceA: nil,
            pairInitSent: false,
            serverShare: nil,
            cpace: nil,
            secrets: nil,
            clientConfirmationSent: false
        )
        let count = await pairingStore?.dynamicPairingFailureCount() ?? 0
        let escalated = count >= dynamicPairingFailureEscalationThreshold
        if escalated, !pairingWindowOpen {
            try? await sendWrapped(ClientPairPendingMessage(
                payload: ClientPairPendingPayload(pairingIndex: pairingActivateCounter)
            ))
        } else {
            await sendDynamicPairInit()
        }
    }

    func dynamicPairingCodeIsOffered(format: PairingCodeFormat) async -> Bool {
        let advertisement = await livePairingAdvertisement()
        return advertisement.supportedPairMethods[PairMethod.dynamicPairingCode]?.formats?.contains(format.rawValue) == true
    }

    func beginStaticPairingAttempt(format: String?) async {
        guard pskCategory == .sentinel, format == nil,
              let runtime = pairingConfigurationRuntime
        else {
            clearPairingAttempt(reason: .methodNotSupported)
            try? await sendWrapped(PairAbortMessage(payload: PairAbortPayload(reason: .methodNotSupported)))
            return
        }
        let configuration = await runtime.snapshot()
        guard configuration.staticPairingCodeIsAdvertised,
              let code = configuration.staticPairingCode,
              PairingManagementConfiguration.isValidStaticPairingCode(code)
        else {
            clearPairingAttempt(reason: .methodNotSupported)
            try? await sendWrapped(PairAbortMessage(payload: PairAbortPayload(reason: .methodNotSupported)))
            return
        }
        guard dynamicPairingAttempt == nil, staticPairingAttempt == nil, pendingPairingPsk == nil else {
            try? await sendWrapped(PairAbortMessage(payload: PairAbortPayload(reason: .concurrentAttempt)))
            await transport.disconnect()
            return
        }
        #if DEBUG
            let pairingHandshakeHash = pairingHandshakeHashOverride ?? channel.handshakeHash
        #else
            let pairingHandshakeHash = channel.handshakeHash
        #endif
        let sid = CPaceSessionIdentifier.make(handshakeHash: pairingHandshakeHash, counter: pairingActivateCounter)
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
            try? await sendWrapped(ClientPairPendingMessage(
                payload: ClientPairPendingPayload(pairingIndex: pairingActivateCounter)
            ))
        }
    }

    func sendDynamicPairInit() async {
        guard var attempt = dynamicPairingAttempt else { return }
        pairingWindowOpen = false
        pairingWindowTask?.cancel()
        pairingWindowTask = nil
        pairingAttemptTask?.cancel()
        pairingAttemptTask = Task { [weak self] in
            try? await Task.sleep(for: self?.pairingAttemptTimeout ?? .seconds(120))
            guard !Task.isCancelled else { return }
            await self?.pairingAttemptTimedOut()
        }
        attempt.nonceA = nil
        dynamicPairingAttempt = attempt
        do {
            try await sendWrapped(ClientPairInitMessage(payload: ClientPairInitPayload(
                pairingIndex: attempt.pairingIndex,
                commitB: Base64URL.encode(attempt.commitB)
            )))
            attempt.pairInitSent = true
            dynamicPairingAttempt = attempt
        } catch {
            clearPairingAttempt()
        }
    }

    func openPairingWindow() async {
        guard !pairingWindowOpen else { return }
        pairingWindowOpen = true
        pairingWindowTask?.cancel()
        pairingWindowTask = Task { [weak self] in
            try? await Task.sleep(for: self?.pairingWindowLifetime ?? .seconds(300))
            guard !Task.isCancelled else { return }
            await self?.closePairingWindow()
        }
        if dynamicPairingAttempt != nil {
            await sendDynamicPairInit()
        } else if staticPairingAttempt != nil {
            await sendStaticPairInit()
        }
    }

    func sendStaticPairInit() async {
        guard var attempt = staticPairingAttempt, attempt.cpace == nil else { return }
        pairingWindowOpen = false
        pairingWindowTask?.cancel()
        pairingWindowTask = nil
        pairingAttemptTask?.cancel()
        pairingAttemptTask = Task { [weak self] in
            try? await Task.sleep(for: self?.pairingAttemptTimeout ?? .seconds(120))
            guard !Task.isCancelled else { return }
            await self?.pairingAttemptTimedOut()
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
        try? await sendWrapped(ClientPairInitMessage(
            payload: ClientPairInitPayload(pairingIndex: attempt.pairingIndex, commitB: nil)
        ))
    }

    func closePairingWindow() {
        pairingWindowOpen = false
        pairingWindowTask?.cancel()
        pairingWindowTask = nil
    }

    func cancelPairingAttempt() async {
        guard dynamicPairingAttempt != nil || staticPairingAttempt != nil || pendingPairingPsk != nil else {
            closePairingWindow()
            return
        }
        clearPairingAttempt(reason: .userCancelled)
        try? await sendWrapped(PairAbortMessage(payload: PairAbortPayload(reason: .userCancelled)))
    }

    func handleDigitAudioClip(_ message: BinaryMessage) throws {
        // Pairing traffic that arrives after a local abort has no effect.
        guard var attempt = dynamicPairingAttempt else { return }
        guard attempt.format == .digits,
              attempt.pairInitSent,
              attempt.nonceA == nil,
              var validator = attempt.digitAudioValidator,
              let digit = message.digit
        else { throw PairingProtocolError.invalidSequence }
        try validator.append(digit: digit, data: message.data)
        attempt.digitAudioValidator = validator
        dynamicPairingAttempt = attempt
    }

    func handleServerPairInit(_ message: ServerPairInitMessage) async throws {
        // A server message left over after an ended attempt is discarded silently.
        guard dynamicPairingAttempt != nil || staticPairingAttempt != nil else { return }
        guard var attempt = dynamicPairingAttempt, attempt.pairInitSent, attempt.nonceA == nil,
              let nonceA = Base64URL.decode(message.payload.nonceA, count: 32)
        else { throw PairingProtocolError.invalidSequence }
        let digitAudioPack: DigitAudioPack? = if let validator = attempt.digitAudioValidator {
            try validator.finish()
        } else {
            nil
        }
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
                digitAudioPack: digitAudioPack
            )
        case .qrCode:
            prs = digest.prefix(24)
            emission = PairingCodeEmission(format: .qrCode, payload: PairingToken.dynamicCodeToken(Data(prs)))
        }
        attempt.cpace = try CPace(
            role: .responder,
            prs: prs,
            sid: attempt.sid,
            scalarOverride: pairingScalarBOverride
        )
        dynamicPairingAttempt = attempt
        controlSink.enqueue(.pairingCodeChanged(emission))
    }

    func handleServerPairAuth(_ message: ServerPairAuthMessage) async throws {
        guard dynamicPairingAttempt != nil || staticPairingAttempt != nil else { return }
        if var attempt = dynamicPairingAttempt, attempt.serverShare == nil,
           let cpace = attempt.cpace,
           let share = Base64URL.decode(message.payload.pakeMsg1, count: 32) {
            attempt.serverShare = share
            attempt.secrets = try cpace.derive(remoteShare: share)
            dynamicPairingAttempt = attempt
            try await sendWrapped(ClientPairAuthMessage(payload: ClientPairAuthPayload(pakeMsg2: Base64URL.encode(cpace.publicShare))))
            return
        }
        guard var attempt = staticPairingAttempt, attempt.serverShare == nil,
              let cpace = attempt.cpace,
              let share = Base64URL.decode(message.payload.pakeMsg1, count: 32)
        else { throw PairingProtocolError.invalidSequence }
        attempt.serverShare = share
        attempt.secrets = try cpace.derive(remoteShare: share)
        staticPairingAttempt = attempt
        try await sendWrapped(ClientPairAuthMessage(payload: ClientPairAuthPayload(pakeMsg2: Base64URL.encode(cpace.publicShare))))
    }

    func handleServerPairConfirm(_ message: ServerPairConfirmMessage) async throws {
        guard dynamicPairingAttempt != nil || staticPairingAttempt != nil else { return }
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
            clearPairingAttempt(reason: .pairingCodeMismatch)
            try? await sendWrapped(PairAbortMessage(payload: PairAbortPayload(reason: .pairingCodeMismatch)))
            return
        }
        let generated = await selectPairingLongTermPsk()
        pendingPairingPsk = generated
        attempt.clientConfirmationSent = true
        staticPairingAttempt = attempt
        let clientTag = CPaceX25519.mcfTag(
            isk: secrets.isk,
            sid: attempt.sid,
            share: cpace.publicShare,
            associatedData: CPaceX25519.defaultResponderAD
        )
        try await sendWrapped(ClientPairConfirmMessage(
            payload: ClientPairConfirmPayload(
                clientKc: Base64URL.encode(clientTag),
                wrappedNonceB: nil
            )
        ))
        let wrappedPsk = try PairingWrap.wrap(
            plaintext: generated.bytes,
            label: Data("sendspin-pair-psk-wrap-v1".utf8),
            sid: attempt.sid,
            isk: secrets.isk,
            suite: suite
        )
        try await sendWrapped(ClientPairFinalizeMessage(
            payload: ClientPairFinalizePayload(wrappedPsk: Base64URL.encode(wrappedPsk))
        ))
    }

    private func handleDynamicServerPairConfirm(_ message: ServerPairConfirmMessage) async throws {
        guard var attempt = dynamicPairingAttempt,
              !attempt.clientConfirmationSent,
              let cpace = attempt.cpace,
              let secrets = attempt.secrets,
              let serverShare = attempt.serverShare,
              let tag = Base64URL.decode(message.payload.serverKc, count: 64)
        else { throw PairingProtocolError.invalidSequence }
        let expected = CPaceX25519.mcfTag(isk: secrets.isk, sid: attempt.sid, share: serverShare, associatedData: CPaceX25519.defaultInitiatorAD)
        guard CPaceX25519.constantTimeEqual(tag, expected) else {
            _ = await pairingStore?.incrementDynamicPairingFailureCount()
            clearPairingAttempt(reason: .pairingCodeMismatch)
            try? await sendWrapped(PairAbortMessage(payload: PairAbortPayload(reason: .pairingCodeMismatch)))
            return
        }
        await pairingStore?.resetDynamicPairingFailureCount()
        let clientTag = CPaceX25519.mcfTag(
            isk: secrets.isk,
            sid: attempt.sid,
            share: cpace.publicShare,
            associatedData: CPaceX25519.defaultResponderAD
        )
        let wrappedNonce = try PairingWrap.wrap(
            plaintext: attempt.nonceB,
            label: Data("sendspin-pair-nonce-wrap-v1".utf8),
            sid: attempt.sid,
            isk: secrets.isk,
            suite: suite
        )
        let generated = await selectPairingLongTermPsk()
        pendingPairingPsk = generated
        attempt.clientConfirmationSent = true
        dynamicPairingAttempt = attempt
        try await sendWrapped(ClientPairConfirmMessage(
            payload: ClientPairConfirmPayload(
                clientKc: Base64URL.encode(clientTag),
                wrappedNonceB: Base64URL.encode(wrappedNonce)
            )
        ))
        let wrappedPsk = try PairingWrap.wrap(
            plaintext: generated.bytes,
            label: Data("sendspin-pair-psk-wrap-v1".utf8),
            sid: attempt.sid,
            isk: secrets.isk,
            suite: suite
        )
        try await sendWrapped(ClientPairFinalizeMessage(
            payload: ClientPairFinalizePayload(wrappedPsk: Base64URL.encode(wrappedPsk))
        ))
    }

    func pairingAttemptTimedOut() async {
        guard pendingPairingPsk != nil || dynamicPairingAttempt != nil || staticPairingAttempt != nil else { return }
        clearPairingAttempt(reason: .attemptTimeout)
        try? await sendWrapped(PairAbortMessage(payload: PairAbortPayload(reason: .attemptTimeout)))
    }

    func clearPairingAttempt(reason: PairAbortReason? = nil) {
        pendingPairingPsk = nil
        dynamicPairingAttempt = nil
        staticPairingAttempt = nil
        pairingAttemptTask?.cancel()
        pairingAttemptTask = nil
        closePairingWindow()
        if let reason {
            controlSink.enqueue(.pairingAttemptEnded(reason))
            controlSink.enqueue(.pairingCodeChanged(nil))
        }
    }

    func handleServerPairFinalize(_: ServerPairFinalizeMessage) async {
        guard let generated = pendingPairingPsk, let pairingStore else { return }
        let hadCodeAttempt = dynamicPairingAttempt != nil || staticPairingAttempt != nil
        if hadCodeAttempt {
            controlSink.enqueue(.pairingCodeChanged(nil))
        }
        clearPairingAttempt()
        let records = await pairingStore.listRecords()
        if records.contains(where: { $0.pskId == generated.pskId }) {
            await pairingStore.markUsed(pskId: generated.pskId)
            controlSink.enqueue(.paired(serverId: currentServerId ?? ""))
            return
        }
        do {
            try await pairingStore.insert(PairingRecord(psk: generated, serverId: currentServerId))
            controlSink.enqueue(.paired(serverId: currentServerId ?? ""))
        } catch {
            Log.client.error("Pairing record persistence failed: \(error.localizedDescription)")
            disconnectReason = .connectionLost(nil)
            await transport.disconnect()
        }
    }

    func handleServerUnpair(_: ServerUnpairMessage) async {
        guard case .longTerm = pskCategory else { return }
        if let pairingStore {
            let records = await pairingStore.listRecords()
            if let record = records.first(where: { $0.psk.pskId == matchedPskId }), record.serverId != nil {
                await pairingStore.remove(pskId: matchedPskId)
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
                    clearPendingArtwork(channel: channel)
                    if artworkTransfer?.channel == channel {
                        artworkTransfer = nil
                    }
                }
            }
            controlSink.enqueue(.artworkStreamStarted(artworkInfo.channels))
        }

        // Handle visualizer stream
        if message.payload.visualizer != nil {
            visualizerStreamActive = true
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

        if outputSampleRatePolicy == .requireCurrentOutput {
            guard await handleOutputFormatStreamStart(format) else { return }
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

        // Seamless change detection on format OR codec header: a gapless track
        // change re-announces the same format with fresh codec_header (FLAC
        // streaminfo); routed as .streamStart the player would early-return
        // and silently discard the new header.
        let previous = announcedPlayerStream
        let isFormatChange = previous.map { $0.format != format || $0.codecHeader != codecHeader } ?? false
        announcedPlayerStream = (format: format, codecHeader: codecHeader)
        if outputSampleRatePolicy != .requireCurrentOutput {
            _ = await handleOutputFormatStreamStart(format)
        }

        if isFormatChange {
            audioEngine.enqueueFormatChange(format: format, codecHeader: codecHeader)
        } else {
            if clientOperationalState == .error {
                clientOperationalState = .synchronized
                controlSink.enqueue(.operationalState(.synchronized))
                try? await publishClientState()
            }
            controlSink.enqueue(.streamAccepted(format))
            audioEngine.commands.enqueue(.streamStart(format, codecHeader: codecHeader))
        }
    }

    func handleStreamClear(_ message: StreamClearMessage) async {
        let roles = message.payload.roles

        if roles == nil || roles?.contains("player") == true {
            audioEngine.commands.enqueue(.streamClear(roles: roles))
        }

        controlSink.enqueue(.streamCleared(roles: roles))
    }

    func handleStreamEnd(_ message: StreamEndMessage) async {
        let endedRoles = message.payload.roles

        if endedRoles == nil || endedRoles?.contains("player") == true {
            playerStreamActive = false
            audioEngine.commands.enqueue(.streamEnd(roles: endedRoles))
            announcedPlayerStream = nil
            resetOutputFormatNegotiationForStreamBoundary()
        }

        if endedRoles == nil || endedRoles?.contains("artwork") == true {
            artworkStreamActive = false
            artworkTransfer = nil
            clearPendingArtwork()
        }

        if endedRoles == nil || endedRoles?.contains("visualizer") == true {
            visualizerStreamActive = false
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

        // Gate: only apply commands in the advertised supported set.
        guard advertisedCommands.contains(playerCmd.command) else {
            Log.client.debug("Ignoring server/command: not in advertised supported_commands")
            return
        }

        switch playerCmd.command {
        case .volume:
            if let volume = playerCmd.volume {
                // Clamp to the spec's 0–100 range rather than trusting the server,
                // matching set_output_delay below and the local setVolume API.
                let clamped = max(0, min(100, volume))
                currentVolume = clamped
                await audioEngine.setGain(Float(clamped) / 100.0)
                controlSink.enqueue(.playerVolumeChanged(clamped))
                try? await publishClientState()
            }

        case .mute:
            if let mute = playerCmd.mute {
                currentMuted = mute
                await audioEngine.setMuted(mute)
                controlSink.enqueue(.playerMutedChanged(mute))
                try? await publishClientState()
            }

        case .setOutputDelay:
            if let delayMs = playerCmd.outputDelayMs {
                // Clamp to the spec range rather than trusting the server.
                let clamped = max(0, min(maxOutputDelayMs, delayMs))
                currentOutputDelayMs = clamped
                audioEngine.commands.enqueue(.setOutputDelay(clamped))
                controlSink.enqueue(.outputDelayChanged(milliseconds: clamped))
                try? await publishClientState()
            }
        }
    }

    func handleGroupUpdate(_ message: GroupUpdateMessage) async {
        let prev = currentGroup
        let info = GroupInfo(
            groupId: message.payload.hasGroupId ? message.payload.groupId ?? "" : prev?.groupId ?? "",
            groupName: message.payload.hasGroupName ? message.payload.groupName ?? "" : prev?.groupName ?? "",
            playbackState: message.payload.hasPlaybackState ? message.payload.playbackState : prev?.playbackState
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
            validity.yieldIfValid(chunk, to: audioSink)
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

    private func receiveCompletedArtwork(_ result: ArtworkTransferResult) async {
        let localTime = await clock.serverTimeToLocal(result.timestamp)
        let artwork = ArtworkData(channel: result.channel, data: result.data, localDisplayTime: localTime)
        let now = scheduleNow()
        if localTime <= now {
            artworkPending[result.channel] = nil
            artworkScheduleTasks[result.channel]?.cancel()
            artworkScheduleTasks[result.channel] = nil
            artworkObserver?(artwork)
            validity.yieldIfValid(artwork, to: artworkSink)
        } else {
            artworkPending[result.channel] = ScheduledArtwork(artwork: artwork, localDisplayTime: localTime)
            artworkScheduleTasks[result.channel]?.cancel()
            let sleep = scheduleSleep
            let now = scheduleNow
            artworkScheduleTasks[result.channel] = Task { [weak self] in
                let delay = Duration.microseconds(localTime - now())
                try? await sleep(delay)
                await self?.applyPendingArtwork(channel: result.channel)
            }
        }
    }

    private func applyPendingArtwork(channel: Int) {
        guard let pending = artworkPending[channel], pending.localDisplayTime <= scheduleNow() else { return }
        artworkPending[channel] = nil
        artworkScheduleTasks[channel] = nil
        artworkObserver?(pending.artwork)
        validity.yieldIfValid(pending.artwork, to: artworkSink)
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

    func handleVisualizerBinary(_ message: BinaryMessage) async {
        guard visualizerStateSent, visualizerStreamActive else {
            Log.client.warning("Discarding visualizer binary: visualizer state or stream is not active")
            return
        }

        guard isClockSynced else {
            Log.client.warning("Discarding visualizer binary: clock is not synced")
            return
        }

        let localDisplayTime = await clock.serverTimeToLocal(message.timestamp)
        let visualizerData = VisualizerData(data: message.data, localDisplayTime: localDisplayTime)
        validity.yieldIfValid(visualizerData, to: visualizerSink)
    }
}
