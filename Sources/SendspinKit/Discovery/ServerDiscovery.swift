// ABOUTME: mDNS/Bonjour discovery for finding Sendspin servers on the local network
// ABOUTME: Uses Network framework NWBrowser to discover _sendspin-server._tcp services

import Foundation
import Network

/// Discovers Sendspin servers on the local network via mDNS.
///
/// Once ``stopDiscovery()`` is called, the ``servers`` stream is finished and
/// cannot be restarted. Create a new `ServerDiscovery` instance if you need
/// to browse again.
public actor ServerDiscovery {
    private var browser: NWBrowser?
    /// Keyed by Bonjour service name — the canonical DNS-SD identity within a service type.
    private var discoveries: [String: DiscoveredServer] = [:]

    /// Marked `nonisolated(unsafe)` because it is accessed in `deinit` (non-isolated).
    /// `AsyncStream.Continuation` is thread-safe; `finish()` is safe to call from any context.
    private nonisolated(unsafe) var updateContinuation: AsyncStream<[DiscoveredServer]>.Continuation?

    private var consecutiveFailures = 0
    private static let maxConsecutiveFailures = 3

    /// How long to wait for a service resolve before giving up.
    private static let resolveTimeout: Duration = .seconds(10)

    /// Outstanding connections used to resolve service endpoints to host:port.
    /// Tracked so they can be cancelled in ``stopDiscovery()``.
    private var pendingResolves: [NWConnection] = []

    /// Timeout tasks for pending resolves, keyed by connection identity.
    /// Cancelled when the resolve completes or in ``stopDiscovery()``.
    private var resolveTimeoutTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Stream of discovered servers (updates whenever servers appear/disappear)
    public let servers: AsyncStream<[DiscoveredServer]>

    /// Whether this discovery instance has been permanently stopped.
    /// Once `true`, ``startDiscovery()`` will throw and a new instance must be created.
    public var isTerminated: Bool {
        updateContinuation == nil
    }

    public init() {
        var continuation: AsyncStream<[DiscoveredServer]>.Continuation?
        servers = AsyncStream { continuation = $0 }
        updateContinuation = continuation
    }

    /// Start discovering servers.
    /// - Throws: ``TerminatedError`` if this instance has been permanently stopped.
    public func startDiscovery() throws {
        guard browser == nil else { return }
        guard updateContinuation != nil else { throw TerminatedError() }

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: SendspinDefaults.serverServiceType, domain: nil),
            using: parameters
        )
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleStateChange(state) }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { await self?.handleBrowseResults(results, changes: changes) }
        }

        browser.start(queue: .global(qos: .userInitiated))
    }

    /// Stop discovering servers.
    /// Finishes the ``servers`` stream — any `for await` loop consuming it will exit.
    /// This is terminal; create a new instance to browse again.
    public func stopDiscovery() {
        browser?.cancel()
        browser = nil
        discoveries.removeAll()
        for connection in pendingResolves {
            connection.cancel()
        }
        pendingResolves.removeAll()
        for task in resolveTimeoutTasks.values {
            task.cancel()
        }
        resolveTimeoutTasks.removeAll()
        terminateStream()
    }

    // MARK: - Private

    /// Finish the servers stream and nil out the continuation, making this
    /// discovery instance permanently unable to yield new results.
    private func terminateStream() {
        updateContinuation?.finish()
        updateContinuation = nil
    }

    private func handleStateChange(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            consecutiveFailures = 0
        case let .failed(error):
            fputs("[ServerDiscovery] browser failed: \(error)\n", stderr)
            browser?.cancel()
            browser = nil

            consecutiveFailures += 1
            guard consecutiveFailures < Self.maxConsecutiveFailures else {
                fputs(
                    "[ServerDiscovery] \(consecutiveFailures) consecutive failures — giving up\n",
                    stderr
                )
                terminateStream()
                return
            }
            do {
                try startDiscovery()
            } catch {
                fputs("[ServerDiscovery] restart failed: \(error) — giving up\n", stderr)
                terminateStream()
            }
        case .setup, .cancelled, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func handleBrowseResults(_: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case let .added(result):
                resolveAndAdd(result)

            case let .removed(result):
                removeServer(for: result)

            case .changed(old: _, new: let result, flags: _):
                resolveAndAdd(result)

            case .identical:
                break

            @unknown default:
                break
            }
        }
    }

    private func resolveAndAdd(_ result: NWBrowser.Result) {
        guard case let .service(name, type, domain, interface) = result.endpoint else {
            return
        }

        // Create a temporary connection to resolve the service endpoint to host:port
        let descriptor = NWEndpoint.service(name: name, type: type, domain: domain, interface: interface)
        let connection = NWConnection(to: descriptor, using: .tcp)
        let connectionID = ObjectIdentifier(connection)
        pendingResolves.append(connection)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task {
                    await self?.extractServerInfo(from: connection, result: result, name: name)
                    connection.cancel()
                }
            case .failed:
                connection.cancel()
            case .cancelled:
                // Terminal state for all paths (.ready → cancel, .failed → cancel,
                // timeout cancel, or external cancel from stopDiscovery).
                // Single cleanup point.
                Task { await self?.resolveCompleted(connection, id: connectionID) }
            case .setup, .preparing, .waiting:
                break
            @unknown default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))

        // Cancel the resolve if it hasn't completed within the timeout.
        // Prevents connections stuck in .waiting from accumulating indefinitely.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.resolveTimeout)
            guard !Task.isCancelled else { return }
            guard await self?.isPendingResolve(connection) == true else { return }
            fputs("[ServerDiscovery] resolve timed out for \(name)\n", stderr)
            connection.cancel()
        }
        resolveTimeoutTasks[connectionID] = timeoutTask
    }

    /// Check if a connection is still in the pending resolves list.
    private func isPendingResolve(_ connection: NWConnection) -> Bool {
        pendingResolves.contains { $0 === connection }
    }

    /// Clean up tracking for a completed/cancelled resolve connection.
    private func resolveCompleted(_ connection: NWConnection, id: ObjectIdentifier) {
        pendingResolves.removeAll { $0 === connection }
        resolveTimeoutTasks[id]?.cancel()
        resolveTimeoutTasks.removeValue(forKey: id)
    }

    /// Format an IPv6 address for use in a URL, wrapped in brackets per RFC 2732.
    ///
    /// Uses `inet_ntop` for stable formatting instead of `debugDescription`.
    /// Note: `inet_ntop` strips zone IDs (e.g. `%en0`). Link-local addresses
    /// will be formatted without zone scope, which may cause routing issues on
    /// multi-interface hosts. The `interface` from the NWBrowser result provides
    /// the correct scope when establishing the actual NWConnection.
    private static func formatIPv6(_ address: IPv6Address) -> String? {
        let raw = address.rawValue

        // Check for link-local (fe80::/10) directly from raw bytes,
        // avoiding platform-specific in6_addr layout.
        if raw.count >= 2, raw[raw.startIndex] == 0xFE, (raw[raw.startIndex + 1] & 0xC0) == 0x80 {
            fputs("[ServerDiscovery] link-local IPv6 address detected; zone ID unavailable in URL\n", stderr)
        }

        var addr = in6_addr()
        _ = withUnsafeMutableBytes(of: &addr) { dest in
            raw.copyBytes(to: dest)
        }

        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard let formatted = inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count)) else {
            return nil
        }
        return "[\(String(cString: formatted))]"
    }

    private func extractServerInfo(from connection: NWConnection, result: NWBrowser.Result, name: String) {
        guard case .service = result.endpoint else { return }

        var hostname = "localhost"
        var port = SendspinDefaults.serverPort

        if case let .hostPort(host, portValue) = connection.currentPath?.remoteEndpoint {
            switch host {
            case let .name(hostName, _):
                hostname = hostName
            case let .ipv4(address):
                hostname = address.debugDescription
            case let .ipv6(address):
                guard let formatted = Self.formatIPv6(address) else {
                    fputs("[ServerDiscovery] could not format IPv6 address for \(name)\n", stderr)
                    return
                }
                hostname = formatted
            @unknown default:
                break
            }
            port = portValue.rawValue
        }

        // Extract TXT record metadata
        var metadata: [String: String] = [:]
        var path = SendspinDefaults.webSocketPath

        if case let .bonjour(txtRecord) = result.metadata {
            metadata = txtRecord.dictionary
            if let customPath = metadata["path"] {
                path = customPath
            }
        }

        guard let url = URL(string: "ws://\(hostname):\(port)\(path)") else {
            fputs("[ServerDiscovery] could not form URL for \(hostname):\(port)\(path)\n", stderr)
            return
        }

        let server = DiscoveredServer(
            name: name,
            url: url,
            hostname: hostname,
            port: port,
            metadata: metadata
        )

        // Key by service name — the canonical DNS-SD identity within a service type.
        // If a service re-registers on a new port, this naturally updates the entry.
        discoveries[name] = server
        updateContinuation?.yield(Array(discoveries.values))
    }

    private func removeServer(for result: NWBrowser.Result) {
        guard case let .service(name, _, _, _) = result.endpoint else { return }

        if discoveries.removeValue(forKey: name) != nil {
            updateContinuation?.yield(Array(discoveries.values))
        }
    }

    // Callers should call stopDiscovery() before releasing. The cancel/finish
    // calls below are thread-safe no-ops if stopDiscovery() was already called.
    deinit {
        browser?.cancel()
        for connection in pendingResolves {
            connection.cancel()
        }
        for task in resolveTimeoutTasks.values {
            task.cancel()
        }
        updateContinuation?.finish()
    }
}
