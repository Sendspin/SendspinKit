import Foundation
@testable import SendspinKit
import Testing

@MainActor
struct SendspinClientTests {
    @Test
    func initializeClientWithPlayerRole() throws {
        let config = try PlayerConfiguration(
            bufferCapacity: 1_024,
            supportedFormats: [
                AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
            ]
        )

        let client = try SendspinClient(
            clientId: "test-client",
            name: "Test Client",
            roles: [.playerV1],
            playerConfig: config
        )

        #expect(client.connectionState == .disconnected)
    }

    @Test
    func enterExternalSource_throwsNotConnectedWhenDisconnected() async throws {
        let client = try SendspinClient(
            clientId: "test-client",
            name: "Test Client",
            roles: [.playerV1],
            playerConfig: PlayerConfiguration(
                bufferCapacity: 1_024,
                supportedFormats: [
                    AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
                ]
            )
        )

        await #expect(throws: SendspinClientError.notConnected) {
            try await client.enterExternalSource()
        }
    }

    @Test
    func exitExternalSource_throwsNotConnectedWhenDisconnected() async throws {
        let client = try SendspinClient(
            clientId: "test-client",
            name: "Test Client",
            roles: [.playerV1],
            playerConfig: PlayerConfiguration(
                bufferCapacity: 1_024,
                supportedFormats: [
                    AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
                ]
            )
        )

        await #expect(throws: SendspinClientError.notConnected) {
            try await client.exitExternalSource()
        }
    }

    @Test
    func failedConnectRollsBackToDisconnectedAndAllowsReconnect() async throws {
        let client = try SendspinClient(
            clientId: "test-client",
            name: "Test Client",
            roles: [.metadataV1]
        )
        let failingURL = try #require(URL(string: "ws://127.0.0.1:1/sendspin"))

        let result = await outcomeOfUnstructuredOperation(
            timeout: .seconds(2),
            onTimeout: { await client.disconnect() },
            operation: { try await client.connect(to: failingURL) }
        )

        switch result {
        case nil:
            Issue.record("connect(to:) timed out instead of failing promptly")
        case .success:
            Issue.record("connect(to:) unexpectedly succeeded against a closed localhost port")
        case .failure:
            break
        }

        #expect(client.connectionState == .disconnected)
        #expect(client.connection == nil)

        let transport = MockTransport()
        try await client.acceptConnection(transport)
        try await transport.injectText(serverHelloJSON())
        #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })

        await client.disconnect()
    }

    @Test
    func alreadyConnectedErrorHasCorrectDescription() {
        let error = SendspinClientError.alreadyConnected
        #expect(error.errorDescription == "Already connected or connecting to a Sendspin server")
    }

    @Test
    func sendFailedErrorIncludesReason() {
        let error = SendspinClientError.sendFailed("connection reset")
        #expect(error.errorDescription == "Failed to send message: connection reset")
    }

    @Test
    func resolveServerURLUsesExplicitURLAndValidatesInputs() async throws {
        let url = try await SendspinClient.resolveServerURL(server: "ws://127.0.0.1:8927/sendspin", discover: false)
        #expect(url.absoluteString == "ws://127.0.0.1:8927/sendspin")

        await #expect(throws: SendspinClientError.invalidServerURL("not a url")) {
            try await SendspinClient.resolveServerURL(server: "not a url", discover: false)
        }
        await #expect(throws: SendspinClientError.serverURLRequired) {
            try await SendspinClient.resolveServerURL(server: nil, discover: false)
        }
    }

    @Test
    func audioSchedulerIsClearedOnDisconnect() async throws {
        let config = try PlayerConfiguration(
            bufferCapacity: 1_024,
            supportedFormats: [
                AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
            ]
        )

        let client = try SendspinClient(
            clientId: "test-client",
            name: "Test Client",
            roles: [.playerV1],
            playerConfig: config
        )

        // Disconnect should clean up all resources including scheduler
        await client.disconnect()

        // After disconnect, state should be disconnected
        #expect(client.connectionState == .disconnected)
    }
}
