import Network
@testable import SendspinKit

/// Keeps the actual listener accessible without exposing a test-only port on the advertiser API.
final class AdvertiserTestListener: ClientListenerHandle, @unchecked Sendable {
    private let listener: NWListener
    var stateUpdateHandler: (@Sendable (ClientListenerState) -> Void)? {
        didSet {
            let handler = stateUpdateHandler
            listener.stateUpdateHandler = { state in
                switch state {
                case .setup: handler?(.setup)
                case .waiting: handler?(.waiting)
                case .ready: handler?(.ready)
                case let .failed(error): handler?(.failed(String(describing: error)))
                case .cancelled: handler?(.cancelled)
                @unknown default: handler?(.cancelled)
                }
            }
        }
    }

    var newConnectionHandler: (@Sendable (NWConnection) -> Void)? {
        get { listener.newConnectionHandler }
        set { listener.newConnectionHandler = newValue }
    }

    var service: NWListener.Service? {
        get { listener.service }
        set { listener.service = newValue }
    }

    var port: UInt16? {
        listener.port?.rawValue
    }

    init() throws {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start(queue: DispatchQueue) {
        listener.start(queue: queue)
    }

    func cancel() {
        listener.cancel()
    }
}
