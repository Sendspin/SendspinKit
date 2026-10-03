import Foundation

/// Immutable output-format negotiation inputs shared by every handshake in one session.
struct SessionFormatNegotiation: Sendable {
    let outputSnapshot: AudioOutputSnapshot?
    let outputSnapshotSequence: UInt64
    let effectivePlayerFormats: [AudioFormatSpec]?
}

enum PairingCandidateBuilder {
    static func candidates(configuration: PairingConfiguration?) async throws -> [PskCandidate] {
        var candidates = [PskCandidate(psk: .sentinel, category: .sentinel)]
        guard let configuration else { return candidates }
        let current = await configuration.runtime.snapshot()
        if current.pairingPskEnabled {
            candidates.append(PskCandidate(psk: current.pairingPsk, category: .pairing))
        }
        let records = try await configuration.store.listRecords()
        candidates.append(contentsOf: records.map {
            PskCandidate(psk: $0.psk, category: .longTerm, requiredServerId: $0.serverId)
        })
        return candidates
    }
}

extension SendspinClient {
    /// Build the live candidate set for one connection attempt.
    func pairingCandidates() async throws -> [PskCandidate] {
        try await PairingCandidateBuilder.candidates(configuration: pairingConfiguration)
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

    /// Mark pairing configuration as ready for handshake use.
    func preparePairingConfiguration() async {
        guard !pairingSetupComplete, pairingConfiguration != nil else { return }
        pairingSetupComplete = true
    }

    func pairingRuntimeConfiguration() async -> PairingManagementConfiguration {
        guard let runtime = pairingConfiguration?.runtime else {
            return PairingManagementConfiguration(
                pairingPsk: .sentinel,
                pairingPskEnabled: false,
                unpairedAccessEnabled: unpairedAccessEnabled,
                presentation: nil,
                outChannels: [],
                formats: []
            )
        }
        return await runtime.snapshot()
    }

    /// Build the client/hello payload from the catalog fixed for this session.
    func buildClientHelloPayload(
        effectivePlayerFormats: [AudioFormatSpec]? = nil,
        configuration: PairingManagementConfiguration
    ) -> ClientHelloPayload {
        var playerV1Support: PlayerSupport?
        if roleSet.contains(.playerV1), let playerConfig {
            let formats = effectivePlayerFormats ?? playerConfig.supportedFormats
            precondition(!formats.isEmpty, "A player hello must advertise at least one supported format")
            playerV1Support = PlayerSupport(
                supportedFormats: formats,
                bufferCapacity: playerConfig.bufferCapacity
            )
        }

        return ClientHelloPayload(
            name: name,
            deviceInfo: deviceInfo,
            supportedPairMethods: {
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
                return methods
            }(),
            unpairedAccess: UnpairedAccessAdvertisement(enabled: configuration.unpairedAccessEnabled),
            supportedRoles: roles,
            playerV1Support: playerV1Support,
            visualizerV1Support: roleSet.contains(.visualizerV1) ? VisualizerSupport(bufferCapacity: visualizerConfig?.bufferCapacity ?? 0) : nil
        )
    }
}
