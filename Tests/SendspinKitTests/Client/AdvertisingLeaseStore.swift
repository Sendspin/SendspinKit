@testable import SendspinKit

actor AdvertisingLeaseStore: PairingRecordStore {
    private let base = InMemoryPairingRecordStore(pairingPsk: .generate())
    private(set) var releaseCount = 0

    func listRecords() async throws -> [PairingRecord] {
        try await base.listRecords()
    }

    func insertOrReplace(_ record: PairingRecord) async throws {
        try await base.insertOrReplace(record)
    }

    func insertOrReplaceAndProtect(_ record: PairingRecord) async throws -> PairingRecordProtectionLease {
        try await base.insertOrReplaceAndProtect(record)
    }

    func remove(pskId: String) async throws {
        try await base.remove(pskId: pskId)
    }

    func markUsed(pskId: String) async throws {
        try await base.markUsed(pskId: pskId)
    }

    func acquireProtection(pskId: String, serverId: String?) async throws -> PairingRecordProtectionLease {
        try await base.acquireProtection(pskId: pskId, serverId: serverId)
    }

    func releaseProtection(_ lease: PairingRecordProtectionLease) async throws {
        releaseCount += 1
        try await base.releaseProtection(lease)
    }

    func storageAccounting() async throws -> PairingStorageAccounting? {
        try await base.storageAccounting()
    }

    func dynamicPairingRoundCount() async throws -> UInt32 {
        try await base.dynamicPairingRoundCount()
    }

    func reserveDynamicPairingRound(limit: UInt32) async throws -> DynamicPairingRoundReservation {
        try await base.reserveDynamicPairingRound(limit: limit)
    }

    func resetDynamicPairingBudget() async throws {
        try await base.resetDynamicPairingBudget()
    }
}
