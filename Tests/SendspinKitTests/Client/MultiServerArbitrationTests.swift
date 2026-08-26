import Foundation
@testable import SendspinKit
import Testing

@MainActor
struct MultiServerArbitrationTests {
    @Test("a weaker candidate is rejected with concurrent_attempt")
    func keepExistingRejectsCandidateThroughEncryptedGoodbye() async throws {
        let client = try makeTestClient()
        let incumbent = try await connectClient(client, activities: [.playback])
        let candidateTransport = MockTransport()
        let candidate = MockNoiseServer(transport: candidateTransport, psk: .sentinel)

        async let accepted: Void = client.acceptConnection(candidateTransport)
        try await candidate.establishSession(activities: [], activeRoles: [.playerV1, .controllerV1])
        try await accepted

        let reasons = await candidate.sentTextMessages
            .filter { SendspinEncoding.messageType(of: $0) == ClientGoodbyeMessage.typeString }
            .compactMap { try? JSONDecoder().decode(ClientGoodbyeMessage.self, from: $0).payload.reason }
        #expect(reasons.contains(.concurrentAttempt))
        #expect(client.connection != nil)
        _ = incumbent
        await client.disconnect()
    }

    @Test("an equal candidate retires incumbent with another_server and becomes live")
    func acceptIncomingRetiresExistingThroughEncryptedGoodbye() async throws {
        let client = try makeTestClient()
        let incumbent = try await connectClient(client, activities: [.playback])
        let incumbentConnection = client.connection
        let candidateTransport = MockTransport()
        let candidate = MockNoiseServer(transport: candidateTransport, psk: .sentinel)

        async let accepted: Void = client.acceptConnection(candidateTransport)
        try await candidate.establishSession(name: "Candidate", activities: [.playback], activeRoles: [.playerV1, .controllerV1])
        try await accepted

        let reasons = await incumbent.sentTextMessages
            .filter { SendspinEncoding.messageType(of: $0) == ClientGoodbyeMessage.typeString }
            .compactMap { try? JSONDecoder().decode(ClientGoodbyeMessage.self, from: $0).payload.reason }
        #expect(reasons.contains(.anotherServer))
        #expect(client.connection !== incumbentConnection)
        try await candidate.sendJSON(#"{"type":"server/state","payload":{"metadata":{"title":"Candidate Track"}}}"#)
        #expect(await waitUntil { await MainActor.run { client.currentMetadata?.title == "Candidate Track" } })
        await client.disconnect()
    }
}
