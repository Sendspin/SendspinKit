import Foundation
@testable import SendspinKit

enum LegacyConnectionReason {
    case discovery
    case playback
}

@MainActor
extension SendspinClient {
    convenience init(
        clientId _: String,
        name: String,
        roles: some Sequence<VersionedRole>,
        deviceInfo: DeviceInfo? = .current,
        playerConfig: PlayerConfiguration? = nil,
        artworkConfig: ArtworkConfiguration? = nil,
        unpairedAccessEnabled: Bool = true,
        persistenceProvider: (any SendspinPersistenceProvider)? = nil,
        audioOutputCapabilityProvider: any AudioOutputCapabilityProviding = AudioOutputCapabilityService()
    ) throws {
        try self.init(
            identity: .generate(),
            name: name,
            roles: roles,
            deviceInfo: deviceInfo,
            playerConfig: playerConfig,
            artworkConfig: artworkConfig,
            unpairedAccessEnabled: unpairedAccessEnabled,
            persistenceProvider: persistenceProvider,
            audioOutputCapabilityProvider: audioOutputCapabilityProvider
        )
    }
}
