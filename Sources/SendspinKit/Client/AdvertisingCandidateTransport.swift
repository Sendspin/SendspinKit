import Foundation

actor AdvertisingCandidateTransport: SendspinTransport {
    let underlying: any SendspinTransport
    let ownership: AdvertisingTransportOwnership

    init(_ transport: any SendspinTransport, ownership: AdvertisingTransportOwnership) {
        underlying = transport
        self.ownership = ownership
    }

    var isConnected: Bool {
        get async { await underlying.isConnected }
    }

    private(set) var closeReason: TransportCloseReason?
    func nextFrame() async -> TransportFrame? {
        let frame = await underlying.nextFrame()
        if frame == nil {
            closeReason = await underlying.closeReason
        }
        return frame
    }

    func sendRawText(_ text: String) async throws {
        try await underlying.sendRawText(text)
    }

    func sendBinary(_ data: Data) async throws {
        try await underlying.sendBinary(data)
    }

    func disconnect() async {
        await ownership.disconnectIfOwned()
        closeReason = await underlying.closeReason
    }
}
