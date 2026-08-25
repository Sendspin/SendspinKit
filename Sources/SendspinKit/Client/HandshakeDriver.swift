import Foundation

/// Owns one candidate from Noise establishment through its first admitted activation.
enum HandshakeDriver {
    struct Result: ~Copyable {
        var channel: NoiseChannel
        let serverId: String
        let serverName: String
        let matchedCandidate: PskCandidate
        let activities: Set<Activity>
        let activeRoles: Set<VersionedRole>
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
    }

    static func establish(
        on transport: any SendspinTransport,
        configuration: Configuration,
        phaseTimeout: Duration = NoiseSessionEstablisher.defaultPhaseTimeout
    ) async throws -> Result {
        do {
            var outcome = try await NoiseSessionEstablisher.establish(
                on: transport,
                identity: configuration.identity,
                suite: .chaChaPoly,
                candidates: configuration.candidates,
                phaseTimeout: phaseTimeout
            )
            let helloData = try await nextJSON(
                from: transport,
                channel: &outcome.channel,
                expected: ServerHelloMessage.typeString,
                timeout: phaseTimeout
            )
            let hello = try JSONDecoder().decode(ServerHelloMessage.self, from: helloData)
            try await sendJSON(
                ClientHelloMessage(payload: configuration.clientHello),
                on: transport,
                channel: &outcome.channel
            )

            let session = ActivationAdmissibility.SessionContext(
                category: outcome.matchedCandidate.category,
                unpairedAccessEnabled: configuration.unpairedAccessEnabled,
                offeredPairMethods: []
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
                        serverName: hello.payload.name,
                        matchedCandidate: outcome.matchedCandidate,
                        activities: activities,
                        activeRoles: resolvedRoles,
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
            await transport.disconnect()
            throw error
        }
    }

    private static func sendJSON(
        _ message: some Codable & Sendable,
        on transport: any SendspinTransport,
        channel: inout NoiseChannel
    ) async throws {
        var encoder = SendspinEncoding.makeEncoder()
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
