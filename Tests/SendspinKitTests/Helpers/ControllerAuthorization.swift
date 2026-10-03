@testable import SendspinKit
import Testing

@MainActor
func authorizeController(_ client: SendspinClient, command: ControllerCommandType) async throws {
    let connection = try #require(client.connection)
    await connection.handleServerState(ServerStateMessage(payload: ServerStatePayload(
        controller: ServerControllerState(supportedCommands: [command], volume: 100, muted: false)
    )))
}
