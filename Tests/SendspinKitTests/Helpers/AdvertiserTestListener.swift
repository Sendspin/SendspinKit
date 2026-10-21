import Foundation
import Network
@testable import SendspinKit

final class AdvertiserTestListenerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: AdvertiserTestListener?

    var listener: AdvertiserTestListener? {
        lock.withLock { storage }
    }

    func makeListener(parameters: NWParameters, port: NWEndpoint.Port) throws -> AdvertiserTestListener {
        let listener = try AdvertiserTestListener(parameters: parameters, port: port)
        lock.withLock { storage = listener }
        return listener
    }
}

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

    var newConnectionHandler: (@Sendable (any ClientConnectionHandle) -> Void)? {
        didSet {
            let handler = newConnectionHandler
            let callback: (@Sendable (NWConnection) -> Void)? = if let handler {
                { connection in handler(connection) }
            } else {
                nil
            }
            listener.newConnectionHandler = callback
        }
    }

    var service: NWListener.Service? {
        get { listener.service }
        set { listener.service = newValue }
    }

    var port: UInt16? {
        listener.port?.rawValue
    }

    init(parameters: NWParameters, port: NWEndpoint.Port) throws {
        listener = try NWListener(using: parameters, on: port)
    }

    func start(queue: DispatchQueue) {
        listener.start(queue: queue)
    }

    func cancel() {
        listener.cancel()
    }
}
