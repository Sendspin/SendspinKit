import Foundation

final class AdvertisingTransportOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var transport: (any SendspinTransport)?

    init(_ transport: any SendspinTransport) {
        self.transport = transport
    }

    func adopt() -> Bool {
        lock.withLock {
            guard transport != nil else { return false }
            transport = nil
            return true
        }
    }

    func takeUnadopted() -> (any SendspinTransport)? {
        lock.withLock {
            let owned = transport
            transport = nil
            return owned
        }
    }

    func disconnectIfOwned() async {
        await takeUnadopted()?.disconnect()
    }
}
