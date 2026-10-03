import CryptoKit
import Foundation

/// Owns one candidate from Noise establishment through its first admitted activation.
enum HandshakeDriver {
    struct Result: ~Copyable {
        var channel: NoiseChannel
        let serverId: String
        let serverStaticPublicKey: Curve25519.KeyAgreement.PublicKey
        let suite: NoiseCipherSuite
        let identityPrivateKey: Curve25519.KeyAgreement.PrivateKey
        let serverName: String
        let serverLanguages: [String]
        let matchedCandidate: PskCandidate
        var protectionLease: PairingRecordProtectionLease?
        let pairingStore: (any PairingRecordStore)?
        let activities: Set<Activity>
        let activeRoles: Set<VersionedRole>
        let pairing: PairingDirective?
        let session: ActivationAdmissibility.SessionContext

        consuming func takeChannel() -> NoiseChannel {
            channel
        }
    }

    struct Configuration: Sendable {
        let identity: SendspinIdentity
        let candidates: [PskCandidate]
        let clientHello: ClientHelloPayload
        let supportedRoles: Set<VersionedRole>
        let unpairedAccessEnabled: Bool
        let pairingStore: (any PairingRecordStore)?

        init(
            identity: SendspinIdentity,
            candidates: [PskCandidate],
            clientHello: ClientHelloPayload,
            supportedRoles: Set<VersionedRole>,
            unpairedAccessEnabled: Bool,
            pairingStore: (any PairingRecordStore)? = nil
        ) {
            self.identity = identity
            self.candidates = candidates
            self.clientHello = clientHello
            self.supportedRoles = supportedRoles
            self.unpairedAccessEnabled = unpairedAccessEnabled
            self.pairingStore = pairingStore
        }
    }

    private static func protectionHooks(
        for configuration: Configuration
    ) -> NoiseSessionEstablisher.ProtectionHooks {
        NoiseSessionEstablisher.ProtectionHooks(
            onCandidateMatched: { candidate in
                guard candidate.category == .longTerm else { return nil }
                guard let pairingStore = configuration.pairingStore else {
                    throw PairingRecordStoreError.storageUnavailable
                }
                return try await pairingStore.acquireProtection(
                    pskId: candidate.psk.pskId,
                    serverId: candidate.requiredServerId
                )
            },
            releaseCandidateLease: { lease in
                guard let pairingStore = configuration.pairingStore else { return }
                try? await pairingStore.releaseProtection(lease)
            }
        )
    }

    static func establish(
        on transport: any SendspinTransport,
        configuration: Configuration,
        phaseTimeout: Duration = NoiseSessionEstablisher.defaultPhaseTimeout
    ) async throws -> Result {
        var protectionLease: PairingRecordProtectionLease?
        do {
            var outcome = try await NoiseSessionEstablisher.establish(
                on: transport,
                identity: configuration.identity,
                candidates: configuration.candidates,
                options: NoiseSessionEstablisher.Options(
                    phaseTimeout: phaseTimeout,
                    protectionHooks: protectionHooks(for: configuration)
                )
            )
            protectionLease = outcome.protectionLease
            let helloData = try await nextJSON(
                from: transport,
                channel: &outcome.channel,
                expected: ServerHelloMessage.typeString,
                timeout: phaseTimeout
            )
            let hello = try JSONDecoder().decode(ServerHelloMessage.self, from: helloData)
            let clientHello = configuration.clientHello
            try await sendJSON(
                ClientHelloMessage(payload: clientHello),
                on: transport,
                channel: &outcome.channel
            )

            let session = ActivationAdmissibility.SessionContext(
                category: outcome.matchedCandidate.category,
                unpairedAccessEnabled: configuration.unpairedAccessEnabled,
                offeredPairMethods: Set(clientHello.supportedPairMethods.keys),
                offeredDynamicFormats: Set(clientHello.supportedPairMethods[PairMethod.dynamicPairingCode]?.formats ?? [])
            )

            while true {
                let activateData = try await nextJSON(
                    from: transport,
                    channel: &outcome.channel,
                    expected: ServerActivateMessage.typeString,
                    timeout: phaseTimeout
                )
                let activate = try JSONDecoder().decode(ServerActivateMessage.self, from: activateData)
                let activities = Set(activate.payload.activities)
                let resolvedRoles = Set(activate.payload.activeRoles ?? []).intersection(configuration.supportedRoles)
                switch ActivationAdmissibility.evaluate(
                    activities: activities,
                    activeRoles: resolvedRoles,
                    pairing: activate.payload.pairing,
                    session: session
                ) {
                case .admit:
                    return Result(
                        channel: outcome.channel,
                        serverId: outcome.serverId,
                        serverStaticPublicKey: outcome.serverStaticPublicKey,
                        suite: outcome.suite,
                        identityPrivateKey: configuration.identity.privateKey,
                        serverName: hello.payload.name,
                        serverLanguages: hello.payload.languages ?? [],
                        matchedCandidate: outcome.matchedCandidate,
                        protectionLease: protectionLease,
                        pairingStore: configuration.pairingStore,
                        activities: activities,
                        activeRoles: resolvedRoles,
                        pairing: activate.payload.pairing,
                        session: session
                    )
                case let .close(reason):
                    try? await sendJSON(
                        ClientGoodbyeMessage(payload: GoodbyePayload(reason: reason)),
                        on: transport,
                        channel: &outcome.channel
                    )
                    await transport.disconnect()
                    throw HandshakeDriverError.rejected(reason)
                case .abortPairing:
                    try await sendJSON(
                        PairAbortMessage(payload: PairAbortPayload(reason: .methodNotSupported)),
                        on: transport,
                        channel: &outcome.channel
                    )
                }
            }
        } catch {
            if let protectionLease, let pairingStore = configuration.pairingStore {
                try? await pairingStore.releaseProtection(protectionLease)
            }
            await transport.disconnect()
            if let handshakeError = error as? HandshakeError,
               case let .connectionRefused(reason) = handshakeError {
                throw SendspinClientError.connectionRefused(reason)
            }
            throw error
        }
    }

    static func reject(
        _ outcome: consuming Result,
        reason: GoodbyeReason,
        on transport: any SendspinTransport
    ) async {
        let outcome = outcome
        var channel = outcome.channel
        if let protectionLease = outcome.protectionLease, let pairingStore = outcome.pairingStore {
            try? await pairingStore.releaseProtection(protectionLease)
        }
        if outcome.activities.contains(.pairing), reason == .concurrentAttempt {
            try? await sendJSON(
                PairAbortMessage(payload: PairAbortPayload(reason: .concurrentAttempt)),
                on: transport,
                channel: &channel
            )
        } else {
            try? await sendJSON(
                ClientGoodbyeMessage(payload: GoodbyePayload(reason: reason)),
                on: transport,
                channel: &channel
            )
        }
        await transport.disconnect()
    }

    private static func sendJSON(
        _ message: some Codable & Sendable,
        on transport: any SendspinTransport,
        channel: inout NoiseChannel
    ) async throws {
        let encoder = SendspinEncoding.makeEncoder()
        let json = try encoder.encode(message)
        var plaintext = Data([NoiseFrameType.json])
        plaintext.append(json)
        for frame in try channel.encryptMessage(plaintext) {
            try await transport.sendBinary(frame)
        }
    }

    private static func nextJSON(
        from transport: any SendspinTransport,
        channel: inout NoiseChannel,
        expected: String,
        timeout: Duration
    ) async throws -> Data {
        while true {
            let frame = try await nextFrame(from: transport, timeout: timeout)
            guard case let .binary(ciphertext) = frame else {
                throw HandshakeDriverError.protocolError
            }
            guard let plaintext = try channel.decryptFrame(ciphertext) else { continue }
            guard plaintext.first == NoiseFrameType.json else {
                throw HandshakeDriverError.protocolError
            }
            let json = Data(plaintext.dropFirst())
            guard SendspinEncoding.messageType(of: json) == expected else {
                throw HandshakeDriverError.protocolError
            }
            return json
        }
    }

    private static func nextFrame(
        from transport: any SendspinTransport,
        timeout: Duration
    ) async throws -> TransportFrame {
        try await withTaskCancellationHandler(operation: {
            try await withThrowingTaskGroup(of: TransportFrame?.self) { group in
                group.addTask {
                    await transport.nextFrame()
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    await transport.disconnect()
                    throw HandshakeError.timeout
                }
                guard let frame = try await group.next() else {
                    throw HandshakeError.transportClosed
                }
                group.cancelAll()
                guard let frame else {
                    throw HandshakeError.transportClosed
                }
                return frame
            }
        }, onCancel: {
            Task { await transport.disconnect() }
        })
    }
}

enum HandshakeDriverError: Error, Equatable {
    case protocolError
    case rejected(GoodbyeReason)
}
