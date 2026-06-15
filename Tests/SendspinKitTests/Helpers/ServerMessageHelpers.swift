import Foundation
@testable import SendspinKit

// MARK: - Constants

/// Default server ID used by test helpers. Shared across all test suites to avoid divergence.
let testServerId = "test-server"

// MARK: - Helpers

/// Encode a server/hello message using the actual Codable types.
func serverHelloJSON(
    serverId: String = testServerId,
    name: String = "Test Server",
    version: Int = 1,
    activeRoles: [VersionedRole] = [.playerV1, .controllerV1],
    connectionReason: ConnectionReason = .discovery
) throws -> String {
    let message = ServerHelloMessage(
        payload: ServerHelloPayload(
            serverId: serverId,
            name: name,
            version: version,
            activeRoles: activeRoles,
            connectionReason: connectionReason
        )
    )
    let data = try JSONEncoder().encode(message)
    return String(bytes: data, encoding: .utf8) ?? ""
}

/// Encode a `server/command` (player command object) using the actual Codable types,
/// so tests never hand-author the `server/command`/`player`/command JSON by hand.
func serverCommandJSON(_ player: PlayerCommandObject) throws -> String {
    let message = ServerCommandMessage(payload: ServerCommandPayload(player: player))
    let data = try JSONEncoder().encode(message)
    return String(bytes: data, encoding: .utf8) ?? ""
}

/// Encode a `server/time` response using the actual Codable types.
///
/// Mirrors a server echoing the client's transmit timestamp. Callers pass a
/// recent `clientTransmitted` (sampled from the client's own monotonic clock)
/// so the synchronizer's RTT gate (`clientReceived - clientTransmitted`)
/// accepts the sample.
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
