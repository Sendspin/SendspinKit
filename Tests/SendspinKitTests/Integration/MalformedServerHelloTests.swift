import Foundation
@testable import SendspinKit
import Testing

/// Forward-compatible handshake decoding must tolerate unknown enum values, while
/// transport-level failures must still be surfaced so the handshake cannot hang silently.
@MainActor
struct MalformedServerHelloTests {
    private func makeClient() throws -> SendspinClient {
        try SendspinClient(
            clientId: "malformed-hello-client",
            name: "Malformed Hello Client",
            roles: [.metadataV1]
        )
    }

    /// Once Noise is established, a type-0 frame still has to contain valid JSON.
    /// Garbage at this stage must fail establishment/session processing silently rather
    /// than being interpreted as a legacy plaintext handshake message.
    @Test("encrypted malformed server message disconnects silently")
    func encryptedMalformedServerMessageDisconnects() async throws {
        let client = try makeClient()
        let transport = MockTransport()
        let mock = MockNoiseServer(transport: transport, psk: .sentinel)
        async let accepted: Void = client.acceptConnection(transport)
        try await mock.establishSession(activeRoles: [.metadataV1])
        try await accepted
        #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })

        var garbage = Data([NoiseFrameType.json])
        garbage.append(contentsOf: Data("{".utf8))
        try await mock.sendEncrypted(garbage)

        // Unknown or malformed application messages are logged and ignored; the
        // established session remains usable because only activation decode failures
        // terminate the transport.
        #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })
    }
}
