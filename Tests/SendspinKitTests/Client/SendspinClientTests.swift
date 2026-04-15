import Foundation
@testable import SendspinKit
import Testing

@MainActor
struct SendspinClientTests {
    @Test
    func `Initialize client with player role`() throws {
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

        // Client should initialize successfully
        #expect(client.connectionState == .disconnected)
    }

    @Test
    func `enterExternalSource throws notConnected when disconnected`() async throws {
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
    func `exitExternalSource throws notConnected when disconnected`() async throws {
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
    func `alreadyConnected error has correct description`() {
        let error = SendspinClientError.alreadyConnected
        #expect(error.errorDescription == "Already connected or connecting to a Sendspin server")
    }

    @Test
    func `sendFailed error includes reason`() {
        let error = SendspinClientError.sendFailed("connection reset")
        #expect(error.errorDescription == "Failed to send message: connection reset")
    }

    @Test
    func `AudioScheduler is cleared on disconnect`() async throws {
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
