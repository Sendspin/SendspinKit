import Foundation

extension SendspinConnection {
    func managementStorage(detailed: Bool) async -> ManagementStorageData? {
        guard let accounting = await pairingStore?.storageAccounting() else { return nil }
        return ManagementStorageData(accounting, detailed: detailed)
    }

    func sendManagementResult(
        _ result: ManagementResultCode,
        data: ManagementResultData? = nil,
        detailedStorage: Bool = false
    ) async {
        let storage = result == .permissionDenied ? nil : await managementStorage(detailed: detailedStorage)
        let payload = ManagementResultPayload(result: result, data: data, storage: storage)
        try? await sendWrapped(ManagementResultMessage(payload: payload))
    }

    func managementGuard() -> Bool {
        activities.contains(.management) && pskCategory == .longTerm
    }

    func handleManagementListRecords(_: ManagementListRecordsMessage) async throws {
        guard managementGuard() else {
            await sendManagementResult(.permissionDenied)
            return
        }
        let records = await pairingStore?.listRecords() ?? []
        await sendManagementResult(
            .success,
            data: .records(ManagementRecordsData(records: records.map {
                ManagementRecordData(pskId: $0.pskId, serverId: $0.serverId, used: $0.used)
            })),
            detailedStorage: true
        )
    }

    func handleManagementAddRecord(_ message: ManagementAddRecordMessage) async throws {
        guard managementGuard() else {
            await sendManagementResult(.permissionDenied)
            return
        }
        guard let store = pairingStore, let psk = Psk(base64URL: message.payload.psk) else {
            await sendManagementResult(.invalid)
            return
        }
        let records = await store.listRecords()
        let pairingPskId = await pairingConfigurationRuntime?.snapshot().pairingPsk.pskId
        guard !records.contains(where: { $0.pskId == psk.pskId }),
              psk.pskId != Psk.sentinel.pskId,
              psk.pskId != pairingPskId
        else {
            await sendManagementResult(.alreadyExists)
            return
        }
        do {
            try await store.insert(PairingRecord(psk: psk, serverId: message.payload.serverId))
            await sendManagementResult(.success)
        } catch PairingRecordStoreError.duplicatePskId {
            await sendManagementResult(.alreadyExists)
        } catch PairingRecordStoreError.storageExhausted {
            await sendManagementResult(.storageExhausted)
        } catch {
            await sendManagementResult(.invalid)
        }
    }

    func handleManagementRemoveRecord(_ message: ManagementRemoveRecordMessage) async throws {
        guard managementGuard() else {
            await sendManagementResult(.permissionDenied)
            return
        }
        guard let store = pairingStore else {
            await sendManagementResult(.notFound)
            return
        }
        let records = await store.listRecords()
        guard records.contains(where: { $0.pskId == message.payload.pskId }) else {
            await sendManagementResult(.notFound)
            return
        }
        let configuration = await pairingConfigurationRuntime?.snapshot()
        if configuration?.recordModePskId == message.payload.pskId {
            await sendManagementResult(.invalid)
            return
        }
        let ownRecord = message.payload.pskId == matchedPskId
        await store.remove(pskId: message.payload.pskId)
        await sendManagementResult(.success)
        if ownRecord {
            try? await sendWrapped(ClientGoodbyeMessage(payload: GoodbyePayload(reason: .unauthorized)))
            disconnectReason = .explicit(.unauthorized)
            await transport.disconnect()
        }
    }

    func handleManagementGetPairingConfig(_: ManagementGetPairingConfigMessage) async throws {
        guard managementGuard(), let runtime = pairingConfigurationRuntime else {
            await sendManagementResult(.permissionDenied)
            return
        }
        let configuration = await runtime.snapshot()
        await sendManagementResult(
            .success,
            data: .pairingConfig(ManagementPairingConfigData(
                pairingPsk: ManagementPairingPskData(enabled: configuration.pairingPskEnabled),
                recordMode: ManagementRecordModeData(pskId: configuration.recordModePskId),
                unpairedAccess: ManagementUnpairedAccessData(enabled: configuration.unpairedAccessEnabled)
            )),
            detailedStorage: true
        )
    }

    func handleManagementSetPairingConfig(_ message: ManagementSetPairingConfigMessage) async throws {
        guard managementGuard(), let runtime = pairingConfigurationRuntime, let store = pairingStore else {
            await sendManagementResult(.permissionDenied)
            return
        }
        let old = await runtime.snapshot()
        var next = old
        if let patch = message.payload.pairingPsk {
            if let pskText = patch.psk {
                guard let psk = Psk(base64URL: pskText) else {
                    await sendManagementResult(.invalid)
                    return
                }
                let records = await store.listRecords()
                guard psk.pskId != Psk.sentinel.pskId,
                      !records.contains(where: { $0.pskId == psk.pskId })
                else {
                    await sendManagementResult(.alreadyExists)
                    return
                }
                next = PairingManagementConfiguration(
                    pairingPsk: psk,
                    pairingPskEnabled: patch.enabled ?? old.pairingPskEnabled,
                    recordModePskId: next.recordModePskId,
                    unpairedAccessEnabled: next.unpairedAccessEnabled
                )
            } else if let enabled = patch.enabled {
                next = PairingManagementConfiguration(
                    pairingPsk: old.pairingPsk,
                    pairingPskEnabled: enabled,
                    recordModePskId: next.recordModePskId,
                    unpairedAccessEnabled: next.unpairedAccessEnabled
                )
            }
        }
        if message.payload.staticPairingCode != nil || message.payload.dynamicPairingCode != nil {
            await sendManagementResult(.invalid)
            return
        }
        if let recordMode = message.payload.recordMode {
            let records = await store.listRecords()
            guard let record = records.first(where: { $0.pskId == recordMode.pskId }), record.serverId == nil else {
                await sendManagementResult(.invalid)
                return
            }
            next = PairingManagementConfiguration(
                pairingPsk: next.pairingPsk,
                pairingPskEnabled: next.pairingPskEnabled,
                recordModePskId: record.pskId,
                unpairedAccessEnabled: next.unpairedAccessEnabled
            )
        }
        if let unpairedAccess = message.payload.unpairedAccess, let enabled = unpairedAccess.enabled {
            next = PairingManagementConfiguration(
                pairingPsk: next.pairingPsk,
                pairingPskEnabled: next.pairingPskEnabled,
                recordModePskId: next.recordModePskId,
                unpairedAccessEnabled: enabled
            )
        }
        do {
            try await store.saveManagementConfiguration(next)
            await runtime.update(next)
            sessionContext = ActivationAdmissibility.SessionContext(
                category: sessionContext.category,
                unpairedAccessEnabled: next.unpairedAccessEnabled,
                offeredPairMethods: sessionContext.offeredPairMethods
            )
            await sendManagementResult(.success)
        } catch PairingRecordStoreError.storageExhausted {
            await sendManagementResult(.storageExhausted)
        } catch {
            await sendManagementResult(.invalid)
        }
    }

    func handleMalformedManagementRequest() async {
        guard managementGuard() else {
            await sendManagementResult(.permissionDenied)
            return
        }
        await sendManagementResult(.invalid)
    }

    func handleManagementOpenPairingWindow(_: ManagementOpenPairingWindowMessage) async throws {
        guard managementGuard() else {
            await sendManagementResult(.permissionDenied)
            return
        }
        await sendManagementResult(.invalid)
    }
}
