import Foundation
@testable import SendspinKit
import Testing

struct WebSocketTransportTests {
    @Test
    func createsAsyncStreamForFrames() throws {
        let url = try #require(URL(string: "ws://localhost:8927/sendspin"))
        let transport = WebSocketTransport(url: url)

        // Verify the ordered frame stream exists (no data yet).
        // (This is a basic structure test - full WebSocket testing requires mock server)
        _ = transport.frames.makeAsyncIterator()
    }
}
