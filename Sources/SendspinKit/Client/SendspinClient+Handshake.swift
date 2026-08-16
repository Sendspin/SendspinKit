import Foundation

extension SendspinClient {
    /// Build the client/hello payload (used by both connect paths)
    func buildClientHelloPayload() -> ClientHelloPayload {
        var playerV1Support: PlayerSupport?
        if roleSet.contains(.playerV1), let playerConfig {
            playerV1Support = PlayerSupport(
                supportedFormats: playerConfig.supportedFormats,
                bufferCapacity: playerConfig.bufferCapacity,
                supportedCommands: volumeCapabilities.playerCommands
            )
        }

        var artworkV1Support: ArtworkSupport?
        if roleSet.contains(.artworkV1), let artworkConfig {
            artworkV1Support = ArtworkSupport(channels: artworkConfig.channels)
        }

        // aiosendspin 6.x hard-rejects a client/hello whose visualizer@v1_support
        // is incomplete (the old empty {} shape breaks the handshake), so the
        // support object is always built from a validated VisualizerConfiguration.
        var visualizerV1Support: VisualizerSupport?
        if roleSet.contains(.visualizerV1), let visualizerConfig {
            visualizerV1Support = VisualizerSupport(
                bufferCapacity: visualizerConfig.bufferCapacity,
                rateMax: visualizerConfig.rateMax,
                types: visualizerConfig.types,
                spectrum: visualizerConfig.spectrum
            )
        }

        return ClientHelloPayload(
            clientId: clientId,
            name: name,
            deviceInfo: deviceInfo,
            version: 1,
            supportedRoles: roles,
            playerV1Support: playerV1Support,
            artworkV1Support: artworkV1Support,
            visualizerV1Support: visualizerV1Support
        )
    }
}
