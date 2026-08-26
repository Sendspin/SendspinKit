import Foundation

/// Storage hook for the spec's "last played server" bookkeeping.
///
/// The Sendspin multi-server rules require a client to *persistently* remember the
/// `server_id` of the server that most recently had `playback_state: playing`. When
/// two servers compete and both connect with `connection_reason: discovery`, the
/// client breaks the tie in favor of that remembered server.
///
/// ``SendspinClient`` calls ``saveLastPlayedServerId(_:)`` whenever a `group/update`
/// reports that playback has started, and ``loadLastPlayedServerId()`` when it needs
/// the stored value for arbitration. Back it with whatever storage is appropriate —
/// `UserDefaults`, a file, the keychain, etc.
///
/// If no provider is supplied to ``SendspinClient/init(identity:name:roles:deviceInfo:playerConfig:artworkConfig:persistenceProvider:)``,
/// SendspinKit performs no implicit persistence and treats the last-played value as
/// absent during multi-server arbitration. Host apps that need the spec's persisted
/// last-played tiebreak should provide an implementation explicitly.
///
/// Methods are `async` so implementations may perform I/O off the main actor, and the
/// protocol is `Sendable` because the provider is shared across concurrency domains.
public protocol SendspinPersistenceProvider: Sendable {
    /// The persisted last-played `server_id`, or `nil` if none has been stored yet.
    func loadLastPlayedServerId() async -> String?

    /// Persist `serverId` as the most recently playing server.
    func saveLastPlayedServerId(_ serverId: String) async
}

/// A long-term Sendspin PSK record.
public struct PairingRecord: Sendable, Equatable, Hashable {
    /// The PSK used by the record.
    public let psk: Psk
    /// The server identity for stored-pubkey records, or `nil` for shared PSKs.
    public let serverId: String?
    /// Whether this record has authenticated at least one session.
    public var used: Bool

    public init(psk: Psk, serverId: String? = nil, used: Bool = false) {
        self.psk = psk
        self.serverId = serverId
        self.used = used
    }

    /// The identifier carried in Noise message 1.
    public var pskId: String {
        psk.pskId
    }
}

/// Persistence for long-term pairing records.
///
/// SendspinKit never persists pairing records implicitly. Applications provide a
/// Keychain, file, or database implementation when records must survive process
/// restarts. Methods are async so storage I/O stays outside the main actor.
public struct PairingStorageAccounting: Sendable, Equatable {
    public let free: Int
    public let capacity: Int?
    public let costIndividual: Int?
    public let costShared: Int?

    public init(free: Int, capacity: Int? = nil, costIndividual: Int? = nil, costShared: Int? = nil) {
        self.free = free
        self.capacity = capacity
        self.costIndividual = costIndividual
        self.costShared = costShared
    }
}

/// The mutable pairing settings exposed through the management role.
public struct PairingManagementConfiguration: Sendable, Equatable {
    public let pairingPsk: Psk
    public let pairingPskEnabled: Bool
    public let recordModePskId: String
    public let unpairedAccessEnabled: Bool

    public init(
        pairingPsk: Psk,
        pairingPskEnabled: Bool,
        recordModePskId: String,
        unpairedAccessEnabled: Bool
    ) {
        self.pairingPsk = pairingPsk
        self.pairingPskEnabled = pairingPskEnabled
        self.recordModePskId = recordModePskId
        self.unpairedAccessEnabled = unpairedAccessEnabled
    }
}

/// Shared mutable state used by handshake candidates and management updates.
public actor PairingConfigurationRuntime {
    private var configuration: PairingManagementConfiguration

    public init(configuration: PairingManagementConfiguration) {
        self.configuration = configuration
    }

    public func snapshot() -> PairingManagementConfiguration {
        configuration
    }

    public func update(_ configuration: PairingManagementConfiguration) {
        self.configuration = configuration
    }
}

/// The store is the host app's durability boundary: mutating operations must be
/// serialized with one another and complete durably before they return. This prevents
/// a successful pairing or management update from being lost while a new handshake
/// is already using the changed record set.
public protocol PairingRecordStore: Sendable {
    /// Return all configured records in a stable implementation-defined order.
    func listRecords() async -> [PairingRecord]

    /// Insert a record, rejecting `psk_id` collisions across all categories.
    func insert(_ record: PairingRecord) async throws

    /// Remove a record by its `psk_id`; missing records are ignored.
    func remove(pskId: String) async

    /// Mark a record as used after successful Noise authentication.
    func markUsed(pskId: String) async

    /// Ensure the generated shared fallback record exists in the provider.
    /// Implementations insert it only when its `psk_id` is absent; repeated calls
    /// never create duplicates.
    func ensurePreProvisionedSharedRecord(_ record: PairingRecord) async

    /// Return storage accounting, or nil when the store is unbounded or unknown.
    func storageAccounting() async -> PairingStorageAccounting?

    /// Load management settings. The supplied value is used by stores without
    /// separate configuration persistence.
    func loadManagementConfiguration(default configuration: PairingManagementConfiguration) async -> PairingManagementConfiguration

    /// Persist management settings atomically with the store's other settings.
    func saveManagementConfiguration(_ configuration: PairingManagementConfiguration) async throws
}

public extension PairingRecordStore {
    func ensurePreProvisionedSharedRecord(_: PairingRecord) async {}

    func storageAccounting() async -> PairingStorageAccounting? {
        nil
    }

    func loadManagementConfiguration(default configuration: PairingManagementConfiguration) async -> PairingManagementConfiguration {
        configuration
    }

    func saveManagementConfiguration(_: PairingManagementConfiguration) async throws {}
}

/// Errors raised while configuring pairing records.
public enum PairingRecordStoreError: Error, Sendable, Equatable {
    /// The PSK identifier is already occupied by another category or record.
    case duplicatePskId
    /// The backing store cannot persist another entry or setting.
    case storageExhausted
}

/// A non-persistent pairing store suitable for clients and tests that do not
/// provide an application persistence implementation.
public actor InMemoryPairingRecordStore: PairingRecordStore {
    private var records: [PairingRecord]
    private let reservedPskIds: Set<String>

    public init(pairingPsk: Psk? = nil, preProvisionedRecord: PairingRecord? = nil) {
        var reserved = Set([Psk.sentinel.pskId])
        if let pairingPsk {
            reserved.insert(pairingPsk.pskId)
        }
        reservedPskIds = reserved
        records = preProvisionedRecord.map { [$0] } ?? []
    }

    public init(records: [PairingRecord], pairingPsk: Psk? = nil) throws {
        var reserved = Set([Psk.sentinel.pskId])
        if let pairingPsk {
            reserved.insert(pairingPsk.pskId)
        }
        var seen = reserved
        for record in records where seen.insert(record.pskId).inserted == false {
            throw PairingRecordStoreError.duplicatePskId
        }
        reservedPskIds = reserved
        self.records = records
    }

    public func listRecords() async -> [PairingRecord] {
        records
    }

    public func insert(_ record: PairingRecord) async throws {
        guard !reservedPskIds.contains(record.pskId), !records.contains(where: { $0.pskId == record.pskId }) else {
            throw PairingRecordStoreError.duplicatePskId
        }
        records.append(record)
    }

    public func remove(pskId: String) async {
        records.removeAll { $0.pskId == pskId }
    }

    public func markUsed(pskId: String) async {
        guard let index = records.firstIndex(where: { $0.pskId == pskId }) else { return }
        records[index].used = true
    }

    public func ensurePreProvisionedSharedRecord(_ record: PairingRecord) async {
        guard !records.contains(where: { $0.pskId == record.pskId }) else { return }
        records.append(record)
    }
}

/// Client-side Pairing PSK configuration.
///
/// The host app owns the lifetime and persistence of the pairing PSK and record store.
/// Keep the PSK private; construct a ``PairingToken`` only for an intentional setup flow
/// and treat its ``PairingToken/string`` value as a secret until it is delivered securely.
public struct PairingConfiguration: Sendable {
    /// The per-device Pairing PSK. A value is generated when omitted; persist the chosen
    /// value with the identity if pairing must remain available after a process restart.
    public let pairingPsk: Psk
    /// Application persistence for long-term records.
    public let store: any PairingRecordStore
    /// Whether Pairing PSK is offered and included in handshake candidates.
    public let enabled: Bool
    /// Shared-PSK fallback used when a newly paired record cannot be stored individually.
    public let recordModePskId: String
    /// Runtime state shared by active connections and future handshakes.
    let runtime: PairingConfigurationRuntime
    /// Shared record used by Record mode when individual records cannot be stored.
    let preProvisionedSharedRecord: PairingRecord

    public init(pairingPsk: Psk? = nil, store: (any PairingRecordStore)? = nil, enabled: Bool = true) {
        let resolved = pairingPsk ?? .generate()
        let fallback = PairingRecord(psk: .generate())
        let resolvedStore = store ?? InMemoryPairingRecordStore(pairingPsk: resolved, preProvisionedRecord: fallback)
        self.pairingPsk = resolved
        self.store = resolvedStore
        self.enabled = enabled
        recordModePskId = fallback.pskId
        preProvisionedSharedRecord = fallback
        runtime = PairingConfigurationRuntime(configuration: PairingManagementConfiguration(
            pairingPsk: resolved,
            pairingPskEnabled: enabled,
            recordModePskId: fallback.pskId,
            unpairedAccessEnabled: true
        ))
    }
}

/// Version-zero pairing token containing the client identity and Pairing PSK.
public struct PairingToken: Sendable, Equatable, Hashable {
    public let clientKey: Data
    public let pairingPsk: Psk

    public init(clientKey: Data, pairingPsk: Psk) {
        precondition(clientKey.count == 32)
        self.clientKey = clientKey
        self.pairingPsk = pairingPsk
    }

    /// Encode as `SP:0` plus the spec's QR-safe base32 body.
    public var string: String {
        "SP:0\(Self.encode(clientKey + pairingPsk.bytes))"
    }

    /// Decode lenient operator input, including an optional `SP:` prefix.
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
