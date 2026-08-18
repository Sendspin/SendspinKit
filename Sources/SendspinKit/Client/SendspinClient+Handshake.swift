import Foundation

/// Immutable output-format negotiation inputs shared by every handshake in one session.
struct SessionFormatNegotiation: Sendable {
    let outputSnapshot: AudioOutputSnapshot?
    let outputSnapshotSequence: UInt64
    let effectivePlayerFormats: [AudioFormatSpec]?
}

extension SendspinClient {
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

    /// Build the client/hello payload from the catalog fixed for this session.
    func buildClientHelloPayload(effectivePlayerFormats: [AudioFormatSpec]? = nil) -> ClientHelloPayload {
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
            clientId: clientId,
            name: name,
            deviceInfo: deviceInfo,
            version: 1,
            supportedRoles: roles,
            playerV1Support: playerV1Support,
            artworkV1Support: artworkV1Support,
            visualizerV1Support: roleSet.contains(.visualizerV1) ? VisualizerSupport() : nil
        )
    }
}
