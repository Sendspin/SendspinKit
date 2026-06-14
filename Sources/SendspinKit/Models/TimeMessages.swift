// ABOUTME: Defines Sendspin clock synchronization message payloads
// ABOUTME: Carries client and server timestamps used by ClockSyncProtocol

import Foundation

/// Client time message for clock sync
struct ClientTimeMessage: SendspinMessage, Equatable {
    static let typeString = "client/time"
    let type = Self.typeString
    let payload: ClientTimePayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ClientTimePayload: Codable, Equatable {
    let clientTransmitted: Int64

    enum CodingKeys: String, CodingKey {
        case clientTransmitted = "client_transmitted"
    }
}

/// Server time response for clock sync
struct ServerTimeMessage: SendspinMessage, Equatable {
    static let typeString = "server/time"
    let type = Self.typeString
    let payload: ServerTimePayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ServerTimePayload: Codable, Equatable {
    let clientTransmitted: Int64
    let serverReceived: Int64
    let serverTransmitted: Int64

    enum CodingKeys: String, CodingKey {
        case clientTransmitted = "client_transmitted"
        case serverReceived = "server_received"
        case serverTransmitted = "server_transmitted"
    }
}
