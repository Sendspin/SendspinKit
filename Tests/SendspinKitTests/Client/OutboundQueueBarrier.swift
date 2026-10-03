import Foundation
@testable import SendspinKit
import Testing

extension SendspinConnection {
    func requireOutboundWaiters(_ count: Int) async throws {
        try #require(await waitUntil(timeout: .seconds(2)) { await self.outboundWaiters.count == count })
    }
}
