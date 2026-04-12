import Foundation
@testable import SendspinKit
import Testing

struct WebSocketTransportTests {
    @Test
    func `Creates AsyncStreams for messages`() throws {
        let url = try #require(URL(string: "ws://localhost:8927/sendspin"))
        let transport = WebSocketTransport(url: url)

        // Verify streams exist
        _ = transport.textMessages.makeAsyncIterator()
        _ = transport.binaryMessages.makeAsyncIterator()

        // Streams should be ready but have no data yet
        // (This is a basic structure test - full WebSocket testing requires mock server)
    }
}
