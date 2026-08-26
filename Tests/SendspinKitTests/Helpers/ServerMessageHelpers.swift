import Foundation
@testable import SendspinKit

let testServerId = "test-server"

func serverHelloJSON(
    name: String = "Test Server",
    serverId _: String? = nil,
    activeRoles _: [VersionedRole]? = nil,
    connectionReason _: LegacyConnectionReason? = nil,
    version _: Int? = nil
) throws -> String {
    let message = ServerHelloMessage(payload: ServerHelloPayload(name: name))
    let data = try JSONEncoder().encode(message)
    return String(bytes: data, encoding: .utf8) ?? ""
}

func serverActivateJSON(
    activities: Set<Activity> = [],
    activeRoles: [VersionedRole]? = []
) throws -> String {
    let message = ServerActivateMessage(
        payload: ServerActivatePayload(activities: Array(activities), activeRoles: activeRoles)
    )
    let data = try JSONEncoder().encode(message)
    return String(bytes: data, encoding: .utf8) ?? ""
}

func serverCommandJSON(_ player: PlayerCommandObject) throws -> String {
    let message = ServerCommandMessage(payload: ServerCommandPayload(player: player))
    let data = try JSONEncoder().encode(message)
    return String(bytes: data, encoding: .utf8) ?? ""
}

func serverTimeJSON(
    clientTransmitted: Int64,
    serverReceived: Int64,
    serverTransmitted: Int64
) throws -> String {
    let message = ServerTimeMessage(
        payload: ServerTimePayload(
            clientTransmitted: clientTransmitted,
            serverReceived: serverReceived,
            serverTransmitted: serverTransmitted
        )
    )
    let data = try JSONEncoder().encode(message)
    return String(bytes: data, encoding: .utf8) ?? ""
}
