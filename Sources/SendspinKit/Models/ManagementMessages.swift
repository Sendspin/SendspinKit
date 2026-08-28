import Foundation

struct ManagementEmptyPayload: Codable, Sendable, Equatable {}

struct ManagementListRecordsMessage: SendspinMessage, Equatable {
    static let typeString = "management/list-records"
    let type = Self.typeString
    let payload: ManagementEmptyPayload
}

struct ManagementAddRecordMessage: SendspinMessage, Equatable {
    static let typeString = "management/add-record"
    let type = Self.typeString
    let payload: ManagementAddRecordPayload
}

struct ManagementAddRecordPayload: Codable, Sendable, Equatable {
    let psk: String
    let serverId: String?

    enum CodingKeys: String, CodingKey {
        case psk
        case serverId = "server_id"
    }
}

struct ManagementRemoveRecordMessage: SendspinMessage, Equatable {
    static let typeString = "management/remove-record"
    let type = Self.typeString
    let payload: ManagementRemoveRecordPayload
}

struct ManagementRemoveRecordPayload: Codable, Sendable, Equatable {
    let pskId: String

    enum CodingKeys: String, CodingKey { case pskId = "psk_id" }
}

struct ManagementGetPairingConfigMessage: SendspinMessage, Equatable {
    static let typeString = "management/get-pairing-config"
    let type = Self.typeString
    let payload: ManagementEmptyPayload
}

struct ManagementSetPairingConfigMessage: SendspinMessage, Equatable {
    static let typeString = "management/set-pairing-config"
    let type = Self.typeString
    let payload: ManagementSetPairingConfigPayload
}

struct ManagementSetPairingConfigPayload: Codable, Sendable, Equatable {
    let pairingPsk: ManagementPairingPskPatch?
    let staticPairingCode: ManagementPairingCodePatch?
    let dynamicPairingCode: ManagementDynamicPairingCodePatch?
    let recordMode: ManagementRecordModePatch?
    let unpairedAccess: ManagementUnpairedAccessPatch?

    enum CodingKeys: String, CodingKey {
        case pairingPsk = "pairing_psk"
        case staticPairingCode = "static_pairing_code"
        case dynamicPairingCode = "dynamic_pairing_code"
        case recordMode = "record_mode"
        case unpairedAccess = "unpaired_access"
    }
}

struct ManagementPairingPskPatch: Codable, Sendable, Equatable {
    let enabled: Bool?
    let psk: String?
}

struct ManagementPairingCodePatch: Codable, Sendable, Equatable {
    let enabled: Bool?
    let code: String?
}

struct ManagementDynamicPairingCodePatch: Codable, Sendable, Equatable {
    let enabled: Bool?
}

struct ManagementRecordModePatch: Codable, Sendable, Equatable {
    let pskId: String

    enum CodingKeys: String, CodingKey { case pskId = "psk_id" }
}

struct ManagementUnpairedAccessPatch: Codable, Sendable, Equatable {
    let enabled: Bool?
}

struct ManagementOpenPairingWindowMessage: SendspinMessage, Equatable {
    static let typeString = "management/open-pairing-window"
    let type = Self.typeString
    let payload: ManagementEmptyPayload
}

struct ManagementRecordData: Codable, Sendable, Equatable {
    let pskId: String
    let serverId: String?
    let used: Bool

    enum CodingKeys: String, CodingKey {
        case pskId = "psk_id"
        case serverId = "server_id"
        case used
    }
}

struct ManagementRecordsData: Codable, Sendable, Equatable {
    let records: [ManagementRecordData]
}

struct ManagementPairingConfigData: Codable, Sendable, Equatable {
    let pairingPsk: ManagementPairingPskData
    let staticPairingCode: ManagementPairingCodeData?
    let dynamicPairingCode: ManagementDynamicPairingCodeData?
    let recordMode: ManagementRecordModeData
    let unpairedAccess: ManagementUnpairedAccessData

    enum CodingKeys: String, CodingKey {
        case pairingPsk = "pairing_psk"
        case staticPairingCode = "static_pairing_code"
        case dynamicPairingCode = "dynamic_pairing_code"
        case recordMode = "record_mode"
        case unpairedAccess = "unpaired_access"
    }
}

struct ManagementPairingPskData: Codable, Sendable, Equatable {
    let enabled: Bool
}

struct ManagementPairingCodeData: Codable, Sendable, Equatable {
    let enabled: Bool
}

struct ManagementDynamicPairingCodeData: Codable, Sendable, Equatable {
    let enabled: Bool
    let escalated: Bool
}

struct ManagementRecordModeData: Codable, Sendable, Equatable {
    let pskId: String

    enum CodingKeys: String, CodingKey { case pskId = "psk_id" }
}

struct ManagementUnpairedAccessData: Codable, Sendable, Equatable {
    let enabled: Bool
}

struct ManagementStorageData: Codable, Sendable, Equatable {
    let free: Int
    let capacity: Int?
    let costIndividual: Int?
    let costShared: Int?

    enum CodingKeys: String, CodingKey {
        case free
        case capacity
        case costIndividual = "cost_individual"
        case costShared = "cost_shared"
    }

    init(_ accounting: PairingStorageAccounting?, detailed: Bool) {
        free = accounting?.free ?? 0
        capacity = detailed ? accounting?.capacity : nil
        costIndividual = detailed ? accounting?.costIndividual : nil
        costShared = detailed ? accounting?.costShared : nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        free = try container.decode(Int.self, forKey: .free)
        capacity = try container.decodeIfPresent(Int.self, forKey: .capacity)
        costIndividual = try container.decodeIfPresent(Int.self, forKey: .costIndividual)
        costShared = try container.decodeIfPresent(Int.self, forKey: .costShared)
    }
}

enum ManagementResultCode: String, Codable, Sendable {
    case success = "ok"
    case permissionDenied = "permission_denied"
    case alreadyExists = "already_exists"
    case invalid
    case notFound = "not_found"
    case storageExhausted = "storage_exhausted"
}

struct ManagementResultMessage: SendspinMessage, Equatable {
    static let typeString = "management/result"
    let type = Self.typeString
    let payload: ManagementResultPayload
}

struct ManagementResultPayload: Codable, Sendable, Equatable {
    let result: ManagementResultCode
    let data: ManagementResultData?
    let storage: ManagementStorageData?
}

enum ManagementResultData: Codable, Sendable, Equatable {
    case records(ManagementRecordsData)
    case pairingConfig(ManagementPairingConfigData)

    init(from decoder: Decoder) throws {
        if let records = try? ManagementRecordsData(from: decoder) {
            self = .records(records)
        } else {
            let configuration = try ManagementPairingConfigData(from: decoder)
            self = .pairingConfig(configuration)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .records(data): try data.encode(to: encoder)
        case let .pairingConfig(data): try data.encode(to: encoder)
        }
    }
}
