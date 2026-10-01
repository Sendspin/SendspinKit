import Foundation

/// Host persistence for the last server that entered playback.
public protocol SendspinPersistenceProvider: Sendable {
    func loadLastPlayedServerId() async -> String?
    func saveLastPlayedServerId(_ serverId: String) async
}

/// A long-term PSK record bound to one server when `serverId` is non-nil.
public struct PairingRecord: Sendable, Equatable, Hashable {
    public let psk: Psk
    public let serverId: String?
    public var used: Bool

    public init(psk: Psk, serverId: String? = nil, used: Bool = false) {
        self.psk = psk
        self.serverId = serverId
        self.used = used
    }

    public var pskId: String {
        psk.pskId
    }
}

/// Compatibility diagnostic retained for internal fixtures; storage policy is store-owned.
struct PairingStorageAccounting: Sendable, Equatable {
    let free: Int
    let capacity: Int?
    let costIndividual: Int?
    let costShared: Int?

    init(free: Int, capacity: Int? = nil, costIndividual: Int? = nil, costShared: Int? = nil) {
        self.free = free
        self.capacity = capacity
        self.costIndividual = costIndividual
        self.costShared = costShared
    }
}

let dynamicPairingRoundLimit: UInt32 = 20
let minimumPairingRecordCapacity = 5

/// Presentation capabilities shared by candidate handshakes and live sessions.
struct PairingManagementConfiguration: Sendable, Equatable {
    let pairingPsk: Psk
    let pairingPskEnabled: Bool
    let unpairedAccessEnabled: Bool
    let pairingPresentation: PairingPresentation?
    let outChannels: [String]
    let formats: [String]

    // Kept for internal fixture migration. New callers should use `presentation`.
    let dynamicPairingCodeEnabled: Bool
    let staticPairingCodeEnabled: Bool
    let staticPairingCode: String?

    init(
        pairingPsk: Psk,
        pairingPskEnabled: Bool,
        unpairedAccessEnabled: Bool,
        presentation: PairingPresentation? = nil,
        outChannels: [String]? = nil,
        formats: [String]? = nil,
        dynamicPairingCodeEnabled: Bool = false,
        staticPairingCodeEnabled: Bool = false,
        staticPairingCode: String? = nil
    ) {
        precondition(staticPairingCode.map(Self.isValidStaticPairingCode) ?? true)
        precondition(!(dynamicPairingCodeEnabled && staticPairingCodeEnabled), "Advertise at most one pairing-code method")
        let resolvedPresentation = presentation ?? Self.legacyPresentation(
            dynamicEnabled: dynamicPairingCodeEnabled,
            staticEnabled: staticPairingCodeEnabled
        )
        self.pairingPsk = pairingPsk
        self.pairingPskEnabled = pairingPskEnabled
        self.unpairedAccessEnabled = unpairedAccessEnabled
        pairingPresentation = resolvedPresentation
        self.outChannels = outChannels ?? resolvedPresentation?.outChannels ?? []
        self.formats = formats ?? resolvedPresentation?.formats ?? []
        let resolvedDynamicPairingCodeEnabled = dynamicPairingCodeEnabled || resolvedPresentation?.usesDynamicCode == true
        let resolvedStaticPairingCodeEnabled = staticPairingCodeEnabled || resolvedPresentation == .staticCode
        self.dynamicPairingCodeEnabled = resolvedDynamicPairingCodeEnabled
        self.staticPairingCodeEnabled = resolvedStaticPairingCodeEnabled
        self.staticPairingCode = staticPairingCode
    }

    var staticPairingCodeIsAdvertised: Bool {
        staticPairingCodeEnabled && staticPairingCode != nil
    }

    static func isValidStaticPairingCode(_ code: String) -> Bool {
        let bytes = Array(code.utf8)
        return bytes.count == 8 && bytes.allSatisfy { (48 ... 57).contains($0) }
    }

    private static func legacyPresentation(
        dynamicEnabled: Bool,
        staticEnabled: Bool
    ) -> PairingPresentation? {
        if staticEnabled {
            return .staticCode
        }
        guard dynamicEnabled else { return nil }
        return .display
    }
}

/// Shared mutable pairing settings. The facade remains the policy owner.
actor PairingConfigurationRuntime {
    private var configuration: PairingManagementConfiguration

    init(configuration: PairingManagementConfiguration) {
        self.configuration = configuration
    }

    func snapshot() -> PairingManagementConfiguration {
        configuration
    }

    func update(_ configuration: PairingManagementConfiguration) {
        self.configuration = configuration
    }
}

public enum DynamicPairingRoundReservation: Sendable, Equatable {
    case reserved(round: UInt32, remaining: UInt32)
    case exhausted
}

/// Opaque, one-shot protection held while a PSK is being authenticated or used.
struct PairingRecordProtectionLease: Sendable, Equatable, Hashable {
    let id: UUID
    let pskIds: Set<String>
}

/// Durable record storage and atomic protection coordination.
protocol PairingRecordStore: Sendable {
    func listRecords() async throws -> [PairingRecord]
    func insertOrReplace(_ record: PairingRecord) async throws
    func insertOrReplaceAndProtect(_ record: PairingRecord) async throws -> PairingRecordProtectionLease
    func remove(pskId: String) async throws
    func markUsed(pskId: String) async throws
    func acquireProtection(pskId: String, serverId: String?) async throws -> PairingRecordProtectionLease
    func releaseProtection(_ lease: PairingRecordProtectionLease) async throws
    func storageAccounting() async throws -> PairingStorageAccounting?
    func dynamicPairingRoundCount() async throws -> UInt32
    func reserveDynamicPairingRound(limit: UInt32) async throws -> DynamicPairingRoundReservation
    func resetDynamicPairingBudget() async throws
}

enum PairingRecordStoreError: Error, Sendable, Equatable {
    case duplicatePskId
    case duplicateServerId
    case storageExhausted
    case recordProtected
    case unknownProtectionLease
    case pskLookupMiss
    case storageUnavailable
    case invalidCapacity
}

/// In-memory store for explicit ephemeral clients and test fixtures.
actor InMemoryPairingRecordStore: PairingRecordStore {
    private var records: [PairingRecord]
    private var dynamicPairingRoundCount: UInt32 = 0
    private let reservedPskIds: Set<String>
    private let capacity: Int
    private var protections: [UUID: Set<String>] = [:]

    init(pairingPsk: Psk? = nil, preProvisionedRecord: PairingRecord? = nil, capacity: Int = 16) {
        precondition(capacity >= minimumPairingRecordCapacity)
        var reserved = Set([Psk.sentinel.pskId])
        if let pairingPsk {
            reserved.insert(pairingPsk.pskId)
        }
        reservedPskIds = reserved
        self.capacity = capacity
        records = preProvisionedRecord.map { [$0] } ?? []
    }

    init(records: [PairingRecord], pairingPsk: Psk? = nil, capacity: Int = 16) throws {
        guard capacity >= minimumPairingRecordCapacity else { throw PairingRecordStoreError.invalidCapacity }
        var reserved = Set([Psk.sentinel.pskId])
        if let pairingPsk {
            reserved.insert(pairingPsk.pskId)
        }
        var seenPskIds = reserved
        var seenServerIds = Set<String>()
        for record in records {
            guard seenPskIds.insert(record.pskId).inserted else { throw PairingRecordStoreError.duplicatePskId }
            if let serverId = record.serverId, !seenServerIds.insert(serverId).inserted {
                throw PairingRecordStoreError.duplicateServerId
            }
        }
        reservedPskIds = reserved
        self.capacity = capacity
        self.records = records
    }

    func listRecords() async throws -> [PairingRecord] {
        records
    }

    func insertOrReplace(_ record: PairingRecord) async throws {
        try insertOrReplaceImpl(record)
    }

    func insertOrReplaceAndProtect(_ record: PairingRecord) async throws -> PairingRecordProtectionLease {
        let previousRecords = records
        let replacesServerRecord = record.serverId.map { serverId in
            records.contains { $0.serverId == serverId }
        } ?? false
        do {
            try insertOrReplaceImpl(record)
            return try acquireProtectionImpl(
                pskId: record.pskId,
                serverId: record.serverId,
                allowFullProtection: replacesServerRecord
            )
        } catch {
            records = previousRecords
            throw error
        }
    }

    private func insertOrReplaceImpl(_ record: PairingRecord) throws {
        guard !reservedPskIds.contains(record.pskId) else { throw PairingRecordStoreError.duplicatePskId }
        if let serverId = record.serverId, let index = records.firstIndex(where: { $0.serverId == serverId }) {
            guard records[index].pskId == record.pskId || !records.contains(where: { $0.pskId == record.pskId }) else {
                throw PairingRecordStoreError.duplicatePskId
            }
            records[index] = record
            return
        }
        guard !records.contains(where: { $0.pskId == record.pskId }) else { throw PairingRecordStoreError.duplicatePskId }
        if records.count >= capacity {
            guard let index = records.firstIndex(where: { !isProtected($0.pskId) }) else {
                throw PairingRecordStoreError.storageExhausted
            }
            records.remove(at: index)
        }
        records.append(record)
    }

    /// Explicit unpairing may remove a record even while its session lease is active;
    /// the lease remains tracked so connection teardown can release it normally.
    func remove(pskId: String) async throws {
        guard let index = records.firstIndex(where: { $0.pskId == pskId }) else { return }
        records.remove(at: index)
    }

    func markUsed(pskId: String) async throws {
        guard let index = records.firstIndex(where: { $0.pskId == pskId }) else { return }
        records[index].used = true
    }

    func acquireProtection(pskId: String, serverId: String?) async throws -> PairingRecordProtectionLease {
        try acquireProtectionImpl(pskId: pskId, serverId: serverId)
    }

    private func acquireProtectionImpl(
        pskId: String,
        serverId: String?,
        allowFullProtection: Bool = false
    ) throws -> PairingRecordProtectionLease {
        guard let current = records.first(where: { $0.pskId == pskId }), current.serverId == serverId else {
            throw PairingRecordStoreError.pskLookupMiss
        }
        let activeLimit = max(1, capacity - 1)
        guard allowFullProtection || protections.count < activeLimit else { throw PairingRecordStoreError.storageExhausted }
        let lease = PairingRecordProtectionLease(id: UUID(), pskIds: [pskId])
        protections[lease.id] = lease.pskIds
        return lease
    }

    func releaseProtection(_ lease: PairingRecordProtectionLease) async throws {
        guard protections.removeValue(forKey: lease.id) != nil else {
            throw PairingRecordStoreError.unknownProtectionLease
        }
    }

    func storageAccounting() async throws -> PairingStorageAccounting? {
        PairingStorageAccounting(free: max(0, capacity - records.count), capacity: capacity, costIndividual: 1, costShared: 1)
    }

    func dynamicPairingRoundCount() async throws -> UInt32 {
        dynamicPairingRoundCount
    }

    func reserveDynamicPairingRound(limit: UInt32) async throws -> DynamicPairingRoundReservation {
        guard dynamicPairingRoundCount < limit else { return .exhausted }
        dynamicPairingRoundCount += 1
        return .reserved(round: dynamicPairingRoundCount, remaining: limit - dynamicPairingRoundCount)
    }

    func resetDynamicPairingBudget() async throws {
        dynamicPairingRoundCount = 0
    }

    private func isProtected(_ pskId: String) -> Bool {
        protections.values.contains { $0.contains(pskId) }
    }
}

/// Internal compatibility configuration used by legacy fixture initializers.
struct PairingConfiguration: Sendable {
    let pairingPsk: Psk
    let store: any PairingRecordStore
    let enabled: Bool
    let dynamicPairingCodeEnabled: Bool
    let staticPairingCodeEnabled: Bool
    let staticPairingCode: String?
    let unpairedAccessEnabled: Bool
    let runtime: PairingConfigurationRuntime

    init(
        presentation: PairingPresentation,
        pairingPsk: Psk,
        store: any PairingRecordStore,
        unpairedAccessEnabled: Bool,
        staticPairingCode: String? = nil
    ) {
        precondition(presentation != .staticCode || staticPairingCode != nil)
        precondition(staticPairingCode.map(PairingManagementConfiguration.isValidStaticPairingCode) ?? true)
        self.pairingPsk = pairingPsk
        self.store = store
        enabled = true
        dynamicPairingCodeEnabled = presentation.usesDynamicCode
        staticPairingCodeEnabled = presentation == .staticCode
        self.staticPairingCode = staticPairingCode
        self.unpairedAccessEnabled = unpairedAccessEnabled
        let initialConfiguration = PairingManagementConfiguration(
            pairingPsk: pairingPsk,
            pairingPskEnabled: true,
            unpairedAccessEnabled: unpairedAccessEnabled,
            presentation: presentation,
            staticPairingCode: staticPairingCode
        )
        runtime = PairingConfigurationRuntime(configuration: initialConfiguration)
    }

    init(
        pairingPsk: Psk? = nil,
        store: (any PairingRecordStore)? = nil,
        enabled: Bool = true,
        dynamicPairingCodeEnabled: Bool = false,
        staticPairingCode: String? = nil,
        staticPairingCodeEnabled: Bool = false
    ) {
        precondition(!staticPairingCodeEnabled || staticPairingCode != nil)
        precondition(staticPairingCode.map(PairingManagementConfiguration.isValidStaticPairingCode) ?? true)
        precondition(!(dynamicPairingCodeEnabled && staticPairingCodeEnabled), "Advertise at most one pairing-code method")
        let resolved = pairingPsk ?? .generate()
        let resolvedStore = store ?? InMemoryPairingRecordStore(pairingPsk: resolved)
        self.pairingPsk = resolved
        self.store = resolvedStore
        self.enabled = enabled
        self.dynamicPairingCodeEnabled = dynamicPairingCodeEnabled
        self.staticPairingCodeEnabled = staticPairingCodeEnabled
        self.staticPairingCode = staticPairingCode
        unpairedAccessEnabled = true
        let initialConfiguration = PairingManagementConfiguration(
            pairingPsk: resolved,
            pairingPskEnabled: enabled,
            unpairedAccessEnabled: true,
            presentation: staticPairingCodeEnabled ? .staticCode :
                (dynamicPairingCodeEnabled ? .display : nil),
            staticPairingCode: staticPairingCode
        )
        runtime = PairingConfigurationRuntime(configuration: initialConfiguration)
    }
}

public struct PairingToken: Sendable, Equatable, Hashable {
    public let clientKey: Data
    public let pairingPsk: Psk

    public init(clientKey: Data, pairingPsk: Psk) {
        precondition(clientKey.count == 32)
        self.clientKey = clientKey
        self.pairingPsk = pairingPsk
    }

    static func dynamicCodeToken(_ code: Data) -> String {
        "SP:1\(encode(code))"
    }

    public var string: String {
        "SP:0\(Self.encode(clientKey + pairingPsk.bytes))"
    }

    public init(string: String) throws {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let body = normalized.hasPrefix("SP:") ? String(normalized.dropFirst(3)) : normalized
        guard body.first == "0" else { throw PairingTokenError.invalidVersion }
        let bytes = try Self.decode(String(body.dropFirst()))
        guard bytes.count >= 64, let psk = Psk(bytes: Data(bytes.dropFirst(32).prefix(32))) else {
            throw PairingTokenError.invalidPayload
        }
        clientKey = Data(bytes.prefix(32))
        pairingPsk = psk
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    private static func encode(_ bytes: Data) -> String {
        var output = ""
        var accumulator = 0
        var bits = 0
        for byte in bytes {
            accumulator = (accumulator << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[(accumulator >> bits) & 31])
            }
        }
        if bits > 0 {
            output.append(alphabet[(accumulator << (5 - bits)) & 31])
        }
        return output.replacingOccurrences(of: "2", with: "9")
    }

    private static func decode(_ input: String) throws -> [UInt8] {
        let restored = input.replacingOccurrences(of: "9", with: "2")
        var accumulator = 0
        var bits = 0
        var output: [UInt8] = []
        for character in restored {
            guard let value = alphabet.firstIndex(of: character) else { throw PairingTokenError.invalidEncoding }
            accumulator = (accumulator << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((accumulator >> bits) & 0xFF))
            }
        }
        if bits > 0, (accumulator & ((1 << bits) - 1)) != 0 {
            throw PairingTokenError.invalidEncoding
        }
        return output
    }
}

public enum PairingTokenError: Error, Sendable, Equatable {
    case invalidVersion
    case invalidEncoding
    case invalidPayload
}
