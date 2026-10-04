import Foundation

extension SendspinClient {
    /// Applies local policy and closes sessions whose normal access depends on being unpaired.
    public func setAccessPolicy(_ policy: AccessPolicy) async throws {
        try requireOpen()
        let previous = accessPolicyUpdateTask
        let task = Task { @MainActor [weak self] in
            _ = try? await previous?.value
            guard let self else { return }
            try requireOpen()
            guard accessPolicy != policy else { return }
            unpairedAccessEnabled = policy == .allowUnpaired
            sessionEpoch += 1
            if let runtime = pairingConfiguration?.runtime {
                let configuration = await runtime.snapshot()
                await runtime.update(PairingManagementConfiguration(
                    pairingPsk: configuration.pairingPsk,
                    pairingPskEnabled: configuration.pairingPskEnabled,
                    unpairedAccessEnabled: policy == .allowUnpaired,
                    presentation: configuration.pairingPresentation,
                    outChannels: configuration.outChannels,
                    formats: configuration.formats,
                    staticPairingCode: configuration.staticPairingCode
                ))
            }
            let pending = Array(pendingTransports.values)
            for transport in pending {
                await transport.disconnect()
            }
            try requireOpen()
            let sessions = [connection, pairingConnection].compactMap(\.self)
            for session in sessions {
                try await session.updateAccessPolicy(policy)
            }
            if connection == nil, connectionState == .connecting {
                updateConnectionState(.disconnected)
            }
        }
        accessPolicyUpdateTask = task
        try await task.value
    }

    /// Creates a client with explicit storage ownership, pairing presentation, and access policy.
    public convenience init(
        device: SendspinDevice,
        name: String,
        roles: some Sequence<VersionedRole>,
        deviceInfo: DeviceInfo? = .current,
        playerConfig: PlayerConfiguration? = nil,
        artworkConfig: ArtworkConfiguration? = nil,
        visualizerConfig: VisualizerConfiguration? = nil,
        pairing: PairingPresentation = .tokenOnly,
        access: AccessPolicy
    ) throws {
        if pairing == .staticCode, device.staticCode == nil {
            throw SendspinDeviceError.invalidStaticCode
        }
        let lease = try device.acquire()
        do {
            let store = DevicePairingRecordStore(device: device)
            try self.init(
                identity: device.identity,
                name: name,
                roles: roles,
                deviceInfo: deviceInfo,
                playerConfig: playerConfig,
                artworkConfig: artworkConfig,
                visualizerConfig: visualizerConfig,
                unpairedAccessEnabled: access == .allowUnpaired,
                persistenceProvider: store,
                pairing: PairingConfiguration(
                    presentation: pairing,
                    pairingPsk: device.pairingPsk,
                    store: store,
                    unpairedAccessEnabled: access == .allowUnpaired,
                    staticPairingCode: device.staticCode
                )
            )
            ownedDevice = device
            deviceLease = lease
        } catch {
            try? device.release(lease)
            throw error
        }
    }
}
