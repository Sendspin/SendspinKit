import Foundation

/// Immutable output-format negotiation inputs shared by every handshake in one session.
struct SessionFormatNegotiation: Sendable {
    let outputSnapshot: AudioOutputSnapshot?
    let outputSnapshotSequence: UInt64
    let effectivePlayerFormats: [AudioFormatSpec]?
}

enum PairingCandidateBuilder {
    static func candidates(configuration: PairingConfiguration?) async -> [PskCandidate] {
        var candidates = [PskCandidate(psk: .sentinel, category: .sentinel)]
        guard let configuration else { return candidates }
        let current = await configuration.runtime.snapshot()
        guard current.pairingPskEnabled else { return candidates }
        candidates.append(PskCandidate(psk: current.pairingPsk, category: .pairing))
        let records = await configuration.store.listRecords()
        candidates.append(contentsOf: records.map {
            PskCandidate(psk: $0.psk, category: .longTerm, requiredServerId: $0.serverId)
        })
        return candidates
    }
}

extension SendspinClient {
    /// Build the live candidate set for one connection attempt.
    func pairingCandidates() async -> [PskCandidate] {
        await PairingCandidateBuilder.candidates(configuration: pairingConfiguration)
    }

    /// Capture one capability snapshot and derive the player catalog for a session.
    func makeSessionFormatNegotiation() async throws(OutputFormatError) -> SessionFormatNegotiation {
        await sessionNegotiationHook()
        guard roleSet.contains(.playerV1), let playerConfig else {
            return SessionFormatNegotiation(
                outputSnapshot: nil,
                outputSnapshotSequence: audioOutputSnapshotSequence,
                effectivePlayerFormats: nil
            )
        }

        let output = await audioOutputCapabilityProvider.snapshot()
        audioOutputSnapshotSequence += 1
        let formats = try effectiveSupportedFormats(
            playerConfig.supportedFormats,
            policy: playerConfig.outputSampleRatePolicy,
            outputSampleRate: output.sampleRate
        )
        return SessionFormatNegotiation(
            outputSnapshot: output,
            outputSnapshotSequence: audioOutputSnapshotSequence,
            effectivePlayerFormats: formats
        )
    }

    /// Prepare pairing storage and restore persisted management settings once per client lifetime.
    func preparePairingConfiguration() async {
        guard !pairingSetupComplete, let configuration = pairingConfiguration else { return }
        pairingSetupComplete = true
        await configuration.store.ensurePreProvisionedSharedRecord(configuration.preProvisionedSharedRecord)
        let current = await configuration.runtime.snapshot()
        let initial = PairingManagementConfiguration(
            pairingPsk: current.pairingPsk,
            pairingPskEnabled: current.pairingPskEnabled,
            recordModePskId: current.recordModePskId,
            unpairedAccessEnabled: unpairedAccessEnabled
        )
        let loaded = await configuration.store.loadManagementConfiguration(default: initial)
        await configuration.runtime.update(loaded)
    }

    func pairingRuntimeConfiguration() async -> PairingManagementConfiguration {
        guard let runtime = pairingConfiguration?.runtime else {
            return PairingManagementConfiguration(
                pairingPsk: .sentinel,
                pairingPskEnabled: false,
                recordModePskId: "",
                unpairedAccessEnabled: unpairedAccessEnabled
            )
        }
        return await runtime.snapshot()
    }

    /// Build the client/hello payload from the catalog fixed for this session.
    func buildClientHelloPayload(
        effectivePlayerFormats: [AudioFormatSpec]? = nil,
        pairingPskEnabled: Bool = false,
        unpairedAccessEnabled: Bool? = nil
    ) -> ClientHelloPayload {
        var playerV1Support: PlayerSupport?
        if roleSet.contains(.playerV1), let playerConfig {
            let formats = effectivePlayerFormats ?? playerConfig.supportedFormats
            precondition(!formats.isEmpty, "A player hello must advertise at least one supported format")
            playerV1Support = PlayerSupport(
                supportedFormats: formats,
                bufferCapacity: playerConfig.bufferCapacity,
                supportedCommands: volumeCapabilities.playerCommands
            )
        }

        var artworkV1Support: ArtworkSupport?
        if roleSet.contains(.artworkV1), let artworkConfig {
            artworkV1Support = ArtworkSupport(channels: artworkConfig.channels)
        }

        return ClientHelloPayload(
            name: name,
            deviceInfo: deviceInfo,
            trustLevel: .none,
            supportedPairMethods: pairingPskEnabled
                ? [PairMethodDescriptor(method: PairMethod.pairingPsk, locations: ["operator"])]
                : [],
            unpairedAccess: UnpairedAccessAdvertisement(enabled: unpairedAccessEnabled ?? self.unpairedAccessEnabled),
            supportedRoles: roles,
            playerV1Support: playerV1Support,
            artworkV1Support: artworkV1Support,
            visualizerV1Support: nil
        )
    }
}
