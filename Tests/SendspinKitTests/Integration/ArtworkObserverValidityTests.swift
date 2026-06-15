import Foundation
@testable import SendspinKit
import Testing

@MainActor
struct ArtworkObserverValidityTests {
    private func makeArtworkClient() throws -> SendspinClient {
        try SendspinClient(
            clientId: "test-client",
            name: "Test Client",
            roles: [.artworkV1],
            artworkConfig: ArtworkConfiguration(channels: [
                ArtworkChannel(source: .album, format: .jpeg, mediaWidth: 300, mediaHeight: 300)
            ])
        )
    }

    private func artworkStreamStartJSON() throws -> String {
        let message = StreamStartMessage(payload: StreamStartPayload(
            player: nil,
            artwork: StreamStartArtwork(channels: [
                StreamArtworkChannelConfig(source: .album, format: .jpeg, width: 300, height: 300)
            ]),
            visualizer: nil
        ))
        return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
    }

    /// Binary artwork frame (type byte + big-endian timestamp + image bytes).
    private func artworkFrame(channel: Int) -> Data {
        var frame = Data()
        frame.append(BinaryMessageType.artworkChannel0.rawValue + UInt8(channel))
        var timestamp = Int64(1_000_000).bigEndian
        frame.append(Data(bytes: &timestamp, count: 8))
        frame.append(Data(repeating: 0xFF, count: 100))
        return frame
    }

    @Test
    func staleArtworkBinaryDoesNotUpdateCurrentArtwork() async throws {
        // Session-validity contract: once the token is invalidated
        // (reconnect/shutdown), the dying connection's in-flight binary events
        // are dropped. The public artwork stream is guarded by yieldIfValid;
        // the MainActor `currentArtwork` observer must be guarded by the SAME
        // token, or a retired connection can schedule a stale facade update.
        let client = try makeArtworkClient()
        let mock = try await connectClient(client, activeRoles: [.artworkV1])

        try await mock.injectText(artworkStreamStartJSON())
        let active = await waitUntil { await MainActor.run { client.artworkStreamActive } }
        #expect(active, "Artwork stream should be active after stream/start")

        let token = try #require(client.sessionValidity)
        token.invalidate()

        await mock.injectBinary(artworkFrame(channel: 0))

        let leaked = await waitUntil(timeout: .milliseconds(500)) {
            await MainActor.run { client.currentArtwork != nil }
        }
        #expect(!leaked, "A stale artwork binary must not update currentArtwork after session invalidation")

        await client.disconnect()
    }
}
