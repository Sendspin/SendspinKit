import Foundation
@testable import SendspinKit
import Testing

@Suite("Player state contract")
struct PlayerStateContractTests {
    @Test("supported command update republishes complete snapshot and enables command")
    func supportedCommandUpdateEnablesLiveAcceptance() async throws {
        let fixture = try await makeEstablishedConnection(advertisedCommands: [.setOutputDelay])
        let connection = fixture.connection
        let server = fixture.server
        try await server.injectText(serverHelloJSON())
        try await server.injectText(serverActivateJSON(activeRoles: [.playerV1]))
        #expect(await waitUntil(timeout: .seconds(3)) { await stateMessages(server).isEmpty == false })

        let oldVolume = await connection.currentVolume
        try await server.injectText(serverCommandJSON(PlayerCommandObject(command: .volume, volume: oldVolume == 100 ? 42 : 100)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await connection.currentVolume == oldVolume, "volume is rejected before it is advertised")

        try await connection.updateAdvertisedCommands([.volume, .setOutputDelay])
        #expect(await waitUntil(timeout: .seconds(3)) {
            await Set(stateMessages(server).last?.payload.player?.supportedCommands ?? []) == Set([.volume, .setOutputDelay])
        })
        let newVolume = oldVolume == 100 ? 42 : 100
        try await server.injectText(serverCommandJSON(PlayerCommandObject(command: .volume, volume: newVolume)))
        #expect(await waitUntil(timeout: .seconds(3)) { await connection.currentVolume == newVolume })
        await connection.shutdown()
        // Mutation claim: immutable advertisedCommands or skipped republish fails either wire or acceptance assertion.
    }

    @Test("removing a supported command immediately stops server command acceptance")
    func supportedCommandRemovalDisablesLiveAcceptance() async throws {
        let fixture = try await makeEstablishedConnection(advertisedCommands: [.volume, .setOutputDelay])
        let connection = fixture.connection
        let server = fixture.server
        try await server.injectText(serverHelloJSON())
        try await server.injectText(serverActivateJSON(activeRoles: [.playerV1]))
        #expect(await waitUntil(timeout: .seconds(3)) { await stateMessages(server).isEmpty == false })

        let original = await connection.currentVolume
        try await connection.updateAdvertisedCommands([.setOutputDelay])
        let changed = original == 100 ? 41 : 100
        try await server.injectText(serverCommandJSON(PlayerCommandObject(command: .volume, volume: changed)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await connection.currentVolume == original, "volume is rejected after it is withdrawn")
        #expect(await stateMessages(server).last?.payload.player?.supportedCommands == [.setOutputDelay])
        await connection.shutdown()
    }

    @Test("volume and mute support require their corresponding state fields")
    func supportedCommandsRequireReportableFields() throws {
        #expect(throws: ConfigurationError.missingRequiredStateField("volume")) {
            try PlayerStateObject(supportedCommands: [.volume])
        }
        #expect(throws: ConfigurationError.missingRequiredStateField("muted")) {
            try PlayerStateObject(supportedCommands: [.mute])
        }
        let state = try PlayerStateObject(volume: 50, muted: false, supportedCommands: [.volume, .mute])
        #expect(state.volume == 50)
        #expect(state.muted == false)
        // Mutation claim: dropping either MUST-include construction guard must fail its named case.
    }

    private func stateMessages(_ server: MockNoiseServer) async -> [ClientStateMessage] {
        await server.clientJSONMessages(ofType: ClientStateMessage.typeString).compactMap {
            try? JSONDecoder().decode(ClientStateMessage.self, from: $0)
        }
    }
}
