import Foundation
import os

/// Observable lifecycle of the client-owned Bonjour listener.
public enum AdvertisingState: Sendable, Equatable {
    case stopped
    case starting
    case running
    case failed(String)
}

/// Internal seam for client-owned advertising. Production uses `ClientAdvertiser`; tests
/// can inject a deterministic listener without opening a Bonjour socket.
protocol ClientAdvertising: AnyObject, Sendable {
    var connections: AsyncStream<any SendspinTransport> { get }
    func matches(port: UInt16, path: String) async -> Bool
    func start() async throws
    func stop() async
}

extension ClientAdvertiser: ClientAdvertising {}

public extension SendspinClient {
    /// Current listener lifecycle, independent from ``connectionState``.
    var listenerState: AdvertisingState {
        advertisingState
    }

    /// Start the client-owned Bonjour listener and wait for actual listener readiness.
    @MainActor
    func startAdvertising(
        port: UInt16 = SendspinDefaults.clientPort,
        path: String = SendspinDefaults.webSocketPath
    ) async throws {
        try requireOpen()

        // A running listener remains idempotent even after it admits a session. A caller
        // cannot silently change the advertised endpoint without stopping first.
        if let currentAdvertiser = advertiser {
            guard await currentAdvertiser.matches(port: port, path: path) else {
                throw SendspinClientError.modeConflict
            }
            if advertisingState == .running {
                return
            }
            if advertisingState == .starting || advertisingStartTask != nil {
                try await waitForAdvertisingStart()
                return
            }
        }

        guard connectionState == .disconnected, connection == nil, !outgoingAttemptInProgress else {
            throw SendspinClientError.modeConflict
        }

        // Startup failure is reported in the state until a new attempt is made. A retry
        // gets a fresh single-use advertiser rather than being blocked by stale error state.
        advertisingStartError = nil
        if advertisingStartTask == nil {
            let newAdvertiser = advertisingFactory(name, port, path)
            advertiser = newAdvertiser
            advertisingState = .starting
            advertisingAccepting = false
            advertisingStartTask = Task { @MainActor [weak self, newAdvertiser] in
                do {
                    try await newAdvertiser.start()
                    self?.advertisingDidStart(newAdvertiser)
                } catch {
                    self?.advertisingDidFail(newAdvertiser, error: error)
                }
            }
        }

        try await waitForAdvertisingStart()
    }

    /// Stop accepting new inbound candidates. Admitted sessions remain connected.
    @MainActor
    func stopAdvertising() async {
        await shutdownAdvertising()
    }

    /// Internal terminal listener teardown used by `close()` and `stopAdvertising()`.
    @MainActor
    internal func shutdownAdvertising() async {
        let hasAdvertisingWork = advertiser != nil
            || advertisingAccepting
            || !advertisingPendingIDs.isEmpty
            || advertisingIncomingTask != nil
        if hasAdvertisingWork {
            // Invalidate every parked advertising admission before the first suspension.
            // This does not retire an already installed connection.
            sessionEpoch += 1
        }
        advertisingAccepting = false

        let startTask = advertisingStartTask
        advertisingStartTask = nil
        startTask?.cancel()
        let waiters = advertisingStartWaiters
        advertisingStartWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(throwing: CancellationError())
        }

        let currentAdvertiser = advertiser
        advertiser = nil
        if let currentAdvertiser {
            await currentAdvertiser.stop()
        }
        await startTask?.value

        let incomingTask = advertisingIncomingTask
        advertisingIncomingTask = nil
        incomingTask?.cancel()

        // Disconnect parked candidates before joining admission tasks. A handshake may
        // be suspended in transport I/O, and its task can only finish once that I/O closes.
        let pending = detachPendingAdvertisingTransports()
        for transport in pending {
            await transport.disconnect()
        }
        await incomingTask?.value
        advertisingStartWaiters.removeAll()
        advertisingStartError = nil
        advertisingState = .stopped
    }
}

private extension SendspinClient {
    func waitForAdvertisingStart() async throws {
        if advertisingState == .running {
            return
        }
        let waiterID = UUID()
        if let advertisingStartError {
            throw advertisingStartError
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    advertisingStartWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelAdvertisingWaiter(waiterID)
            }
        }
    }

    func cancelAdvertisingWaiter(_ waiterID: UUID) {
        guard let waiter = advertisingStartWaiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(throwing: CancellationError())
        guard advertisingStartWaiters.isEmpty, advertisingState == .starting else { return }
        let currentAdvertiser = advertiser
        let startTask = advertisingStartTask
        advertiser = nil
        advertisingStartTask?.cancel()
        advertisingStartTask = nil
        advertisingAccepting = false
        advertisingState = .stopped
        Task { @MainActor in
            await currentAdvertiser?.stop()
            await startTask?.value
        }
    }

    @MainActor
    func admitAdvertisingTransport(
        _ transport: any SendspinTransport,
        from startedAdvertiser: any ClientAdvertising,
        admissionGate: AdvertisingAdmissionGate
    ) async {
        defer { admissionGate.release() }
        guard advertiser === startedAdvertiser, advertisingAccepting else {
            await transport.disconnect()
            return
        }
        guard advertisingPendingIDs.count < clientAdvertiserPendingLimit else {
            await transport.disconnect()
            return
        }
        let acceptance = Task { @MainActor [weak self, startedAdvertiser] in
            guard let self,
                  advertiser === startedAdvertiser,
                  advertisingAccepting
            else {
                await transport.disconnect()
                return
            }
            try await acceptConnection(transport)
        }
        defer { acceptance.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await acceptance.value
                    }
                    group.addTask {
                        try await Task.sleep(for: clientAdvertiserPendingConnectionTimeout)
                        await transport.disconnect()
                        throw CancellationError()
                    }
                    try await group.next()
                    group.cancelAll()
                }
            } onCancel: {
                Task { await transport.disconnect() }
            }
        } catch {
            Log.client.error("Advertised connection acceptance failed: \(error.localizedDescription, privacy: .public)")
            await transport.disconnect()
        }
    }

    func advertisingDidStart(_ startedAdvertiser: any ClientAdvertising) {
        guard advertiser === startedAdvertiser, advertisingState == .starting else { return }
        advertisingState = .running
        advertisingAccepting = true
        advertisingStartTask = nil
        advertisingIncomingTask = Task { @MainActor [weak self, startedAdvertiser] in
            let admissionGate = AdvertisingAdmissionGate(capacity: clientAdvertiserPendingLimit)
            await withTaskGroup(of: Void.self) { group in
                for await transport in startedAdvertiser.connections {
                    guard !Task.isCancelled,
                          let self,
                          self.advertiser === startedAdvertiser,
                          self.advertisingAccepting
                    else {
                        await transport.disconnect()
                        continue
                    }
                    guard admissionGate.tryAcquire() else {
                        await transport.disconnect()
                        continue
                    }
                    group.addTask { [weak self, startedAdvertiser, admissionGate] in
                        await self?.admitAdvertisingTransport(
                            transport,
                            from: startedAdvertiser,
                            admissionGate: admissionGate
                        )
                    }
                }

                if let self {
                    let pending = self.advertisingDidEnd(startedAdvertiser) ?? []
                    for transport in pending {
                        await transport.disconnect()
                    }
                }
                group.cancelAll()
            }
        }
        let waiters = advertisingStartWaiters
        advertisingStartWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    func advertisingDidFail(_ failedAdvertiser: any ClientAdvertising, error: Error) {
        guard advertiser === failedAdvertiser else { return }
        advertiser = nil
        advertisingStartTask = nil
        advertisingAccepting = false
        advertisingStartError = error
        advertisingState = .failed(error.localizedDescription)
        let waiters = advertisingStartWaiters
        advertisingStartWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(throwing: error)
        }
        Task { await failedAdvertiser.stop() }
    }

    @discardableResult
    func advertisingDidEnd(_ endedAdvertiser: any ClientAdvertising) -> [any SendspinTransport]? {
        guard advertiser === endedAdvertiser, advertisingAccepting else { return nil }
        advertiser = nil
        advertisingAccepting = false
        advertisingStartError = nil
        advertisingState = .failed("The advertising listener stopped unexpectedly")
        let pending = detachPendingAdvertisingTransports()
        Task { await endedAdvertiser.stop() }
        return pending
    }

    func detachPendingAdvertisingTransports() -> [any SendspinTransport] {
        let ids = advertisingPendingIDs
        advertisingPendingIDs.removeAll()
        return ids.compactMap { pendingTransports.removeValue(forKey: $0) }
    }
}

extension SendspinClient {
    var advertisingFactory: @Sendable (String, UInt16, String) -> any ClientAdvertising {
        get { advertisingFactoryStorage }
        set { advertisingFactoryStorage = newValue }
    }
}
