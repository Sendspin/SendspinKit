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
