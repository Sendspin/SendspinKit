import Foundation
import Network
@testable import SendspinKit
import Testing

struct ClientAdvertiserListenerTests {
    @Test("cancelled listener clears running state and finishes connections")
    func cancelledListenerIsTerminal() async throws {
        let fake = TestListenerHandle()
        let advertiser = ClientAdvertiser(
            name: "Test",
            port: 0,
            path: "/sendspin",
            listenerFactory: { _, _ in fake }
        )
        let start = Task { try await advertiser.start() }
        try await fake.waitForStateHandler()
        fake.emit(.ready)
        try await start.value
        #expect(await advertiser.isRunning)

        let connections = Task { await advertiser.connections.first(where: { _ in true }) }
        fake.emit(.cancelled)

        #expect(await waitUntil { await !(advertiser.isRunning) })
        #expect(await advertiser.isTerminated)
        #expect(await connections.value == nil)
    }

    @Test("stale cancellation from a retired listener cannot stop a replacement")
    func staleCallbackCannotChangeNewAdvertiser() async throws {
        let fake = TestListenerHandle()
        let advertiser = ClientAdvertiser(
            name: "Test",
            port: 0,
            path: "/sendspin",
            listenerFactory: { _, _ in fake }
        )
        let start = Task { try await advertiser.start() }
        try await fake.waitForStateHandler()
        let staleCallback = try #require(fake.stateUpdateHandler)
        staleCallback(.ready)
        try await start.value
        await advertiser.stop()
        #expect(await advertiser.isTerminated)

        // A single advertiser is intentionally terminal; a callback after stop must not
        // resurrect it or create a second listener behind the caller's back.
        staleCallback(.ready)
        staleCallback(.cancelled)
        #expect(await !(advertiser.isRunning))
        #expect(await advertiser.isTerminated)
    }

    @Test("cancelled listener resumes a pending startup")
    func cancelledListenerResumesStart() async throws {
        let fake = TestListenerHandle()
        let advertiser = ClientAdvertiser(
            name: "Test",
            port: 0,
            path: "/sendspin",
            listenerFactory: { _, _ in fake }
        )
        let start = Task { try await advertiser.start() }
        try await fake.waitForStateHandler()
        fake.emit(.cancelled)

        await #expect(throws: CancellationError.self) {
            try await start.value
        }
        #expect(await advertiser.isTerminated)
        #expect(await !(advertiser.isRunning))
    }

    @Test("failed listener resumes readiness with a listener error")
    func failedListenerResumesStart() async throws {
        let fake = TestListenerHandle()
        let advertiser = ClientAdvertiser(
            name: "Test",
            port: 0,
            path: "/sendspin",
            listenerFactory: { _, _ in fake }
        )
        let start = Task { try await advertiser.start() }
        try await fake.waitForStateHandler()
        fake.emit(.failed("bind failed"))

        await #expect(throws: ClientAdvertiserError.listenerFailed("bind failed")) {
            try await start.value
        }
        #expect(await advertiser.isTerminated)
        #expect(await !(advertiser.isRunning))
    }

    @Test("pending NW connections are capped before readiness")
    func pendingConnectionCapRejectsOverflow() async throws {
        let fake = TestListenerHandle()
        let advertiser = ClientAdvertiser(
            name: "Test",
            port: 0,
            path: "/sendspin",
            maximumPendingConnections: 1,
            pendingConnectionTimeout: .seconds(10),
            listenerFactory: { _, _ in fake }
        )
        let start = Task { try await advertiser.start() }
        try await fake.waitForStateHandler()
        fake.emit(.ready)
        try await start.value

        let first = TestPendingConnection()
        let second = TestPendingConnection()
        fake.emit(first)
        try #require(await waitUntil { first.started })
        fake.emit(second)

        try #require(await waitUntil { second.cancelled })
        #expect(!second.started)
        #expect(!first.cancelled)
        await advertiser.stop()
        #expect(first.cancelled)
        #expect(!first.hasStateHandler)
        #expect(!second.hasStateHandler)
    }

    @Test("failed and cancelled pending connections release their slots", arguments: [false, true])
    func terminalPendingConnectionReleasesSlot(failed: Bool) async throws {
        let fake = TestListenerHandle()
        let advertiser = ClientAdvertiser(
            name: "Test",
            port: 0,
            path: SendspinDefaults.webSocketPath,
            maximumPendingConnections: 1,
            listenerFactory: { _, _ in fake }
        )
        let start = Task { try await advertiser.start() }
        try await fake.waitForStateHandler()
        fake.emit(.ready)
        try await start.value

        let pending = TestPendingConnection()
        fake.emit(pending)
        try #require(await waitUntil { pending.started })
        pending.emit(failed ? .failed(.posix(.ECONNRESET)) : .cancelled)
        try #require(await waitUntil { !pending.hasStateHandler })
        #expect(pending.cancelled == failed)

        let replacement = TestPendingConnection()
        fake.emit(replacement)
        try #require(await waitUntil { replacement.started })
        await advertiser.stop()
        #expect(replacement.cancelled)
        #expect(!replacement.hasStateHandler)
    }

    @Test("pending NW connections time out and are removed")
    func pendingConnectionTimeoutCancelsResource() async throws {
        let fake = TestListenerHandle()
        let advertiser = ClientAdvertiser(
            name: "Test",
            port: 0,
            path: "/sendspin",
            maximumPendingConnections: 1,
            pendingConnectionTimeout: .milliseconds(20),
            listenerFactory: { _, _ in fake }
        )
        let start = Task { try await advertiser.start() }
        try await fake.waitForStateHandler()
        fake.emit(.ready)
        try await start.value

        let pending = TestPendingConnection()
        fake.emit(pending)
        try #require(await waitUntil { pending.started })
        try #require(await waitUntil(timeout: .seconds(2)) { pending.cancelled })
        #expect(!pending.hasStateHandler)

        let replacement = TestPendingConnection()
        fake.emit(replacement)
        try #require(await waitUntil { replacement.started })
        replacement.emit(.ready)
        let admitted = Task { await advertiser.connections.first(where: { _ in true }) }
        switch await observeTask(admitted, timeout: .seconds(2), onTimeout: { await advertiser.stop() }) {
        case let .completed(transport):
            #expect(transport != nil)
        case .timedOut:
            Issue.record("ready replacement must be admitted after timeout frees the pending slot")
        }
        #expect(!replacement.hasStateHandler)
        await advertiser.stop()
        #expect(!replacement.cancelled)
        #expect(await !replacement.transport.disconnectCalled)
        await replacement.transport.disconnect()
    }
}

private final class TestPendingConnection: ClientConnectionHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (NWConnection.State) -> Void)?
    private var startedStorage = false
    private var cancelledStorage = false
    let transport = MockTransport()

    var stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    var started: Bool {
        lock.withLock { startedStorage }
    }

    var cancelled: Bool {
        lock.withLock { cancelledStorage }
    }

    var hasStateHandler: Bool {
        lock.withLock { handler != nil }
    }

    func start(queue _: DispatchQueue) {
        lock.withLock { startedStorage = true }
    }

    func cancel() {
        lock.withLock { cancelledStorage = true }
    }

    func emit(_ state: NWConnection.State) {
        let callback = lock.withLock { handler }
        callback?(state)
    }

    func makeTransport() async -> any SendspinTransport {
        transport
    }
}

private enum TestListenerError: Error {
    case stateHandlerNotInstalled
}

private final class TestListenerHandle: ClientListenerHandle, @unchecked Sendable {
    private let lock = NSLock()
    private let stateHandlerReady: AsyncStream<Void>
    private let stateHandlerReadyContinuation: AsyncStream<Void>.Continuation
    private var stateUpdateHandlerStorage: (@Sendable (ClientListenerState) -> Void)?
    private var newConnectionHandlerStorage: (@Sendable (any ClientConnectionHandle) -> Void)?
    private var serviceStorage: NWListener.Service?
    private var portStorage: UInt16?

    var stateUpdateHandler: (@Sendable (ClientListenerState) -> Void)? {
        get { lock.withLock { stateUpdateHandlerStorage } }
        set {
            lock.withLock {
                stateUpdateHandlerStorage = newValue
            }
            if newValue != nil {
                stateHandlerReadyContinuation.yield()
            }
        }
    }

    var newConnectionHandler: (@Sendable (any ClientConnectionHandle) -> Void)? {
        get { lock.withLock { newConnectionHandlerStorage } }
        set {
            lock.withLock {
                newConnectionHandlerStorage = newValue
            }
        }
    }

    var service: NWListener.Service? {
        get { lock.withLock { serviceStorage } }
        set {
            lock.withLock {
                serviceStorage = newValue
            }
        }
    }

    var port: UInt16? {
        lock.withLock { portStorage }
    }

    init() {
        var continuation: AsyncStream<Void>.Continuation?
        stateHandlerReady = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        // The stream initializer synchronously supplies its continuation.
        stateHandlerReadyContinuation = continuation!
    }

    func start(queue _: DispatchQueue) {}

    func cancel() {}

    func emit(_ state: ClientListenerState) {
        let handler = lock.withLock { stateUpdateHandlerStorage }
        handler?(state)
    }

    func emit(_ connection: any ClientConnectionHandle) {
        let handler = lock.withLock { newConnectionHandlerStorage }
        handler?(connection)
    }

    func waitForStateHandler(timeout: Duration = .seconds(2)) async throws {
        let received = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = self.stateHandlerReady.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        guard received else {
            throw TestListenerError.stateHandlerNotInstalled
        }
    }
}
