import Network

protocol ClientConnectionHandle: AnyObject, Sendable {
    var stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
    func makeTransport() async -> any SendspinTransport
}

extension NWConnection: ClientConnectionHandle {
    func makeTransport() async -> any SendspinTransport {
        let transport = NWWebSocketTransport(connection: self)
        await transport.startReceiving()
        return transport
    }
}
