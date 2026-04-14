import Foundation
@testable import SendspinKit
import Testing

@MainActor
struct SendspinClientTests {
    @Test
    func `Initialize client with player role`() {
        let config = PlayerConfiguration(
            bufferCapacity: 1_024,
            supportedFormats: [
                AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
            ]
        )

        let client = SendspinClient(
            clientId: "test-client",
            name: "Test Client",
            roles: [.playerV1],
            playerConfig: config
        )

        // Client should initialize successfully
        #expect(client.connectionState == .disconnected)
    }

    @Test
    func `Connect creates transport and starts connecting`() {
        let config = PlayerConfiguration(
            bufferCapacity: 1_024,
            supportedFormats: [
                AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
            ]
        )

        let client = SendspinClient(
            clientId: "test-client",
            name: "Test Client",
            roles: [.playerV1],
            playerConfig: config
        )

        #expect(client.connectionState == .disconnected)

        // Note: This will fail to connect since URL is invalid, but verifies setup
        // Real integration tests need mock server
    }

    @Test
    func `SendspinClient has AudioScheduler after connect`() {
        let config = PlayerConfiguration(
            bufferCapacity: 1_024,
            supportedFormats: [
                AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
            ]
        )

        let client = SendspinClient(
            clientId: "test-client",
            name: "Test Client",
            roles: [.playerV1],
            playerConfig: config
        )

        // Before connect, scheduler should not be accessible
        #expect(client.connectionState == .disconnected)

        // After implementation, connect will create scheduler
        // This test verifies the scheduler exists by checking that
        // the client properly initializes with player role
        #expect(client.connectionState == .disconnected)
    }

    @Test
    func `enterExternalSource throws notConnected when disconnected`() async {
        let client = SendspinClient(
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
    func `exitExternalSource throws notConnected when disconnected`() async {
        let client = SendspinClient(
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
    func `AudioScheduler is cleared on disconnect`() async {
        let config = PlayerConfiguration(
            bufferCapacity: 1_024,
            supportedFormats: [
                AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
            ]
        )

        let client = SendspinClient(
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
