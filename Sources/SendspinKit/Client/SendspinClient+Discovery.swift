import Foundation

public extension SendspinClient {
    /// Continuously discover Sendspin servers on the local network.
    ///
    /// Returns a `ServerDiscovery` whose `servers` stream emits an updated list
    /// whenever servers appear or disappear. The caller owns the lifecycle —
    /// call `stopDiscovery()` when done.
    ///
    /// ```swift
    /// let discovery = try await SendspinClient.discoverServers()
    /// for await servers in discovery.servers {
    ///     print("Found \(servers.count) server(s)")
    /// }
    /// // Later:
    /// await discovery.stopDiscovery()
    /// ```
    nonisolated static func discoverServers() async throws -> ServerDiscovery {
        let discovery = ServerDiscovery()
        try await discovery.startDiscovery()
        return discovery
    }

    /// Resolve a server WebSocket URL from either an explicit URL string or mDNS discovery.
    ///
    /// This convenience lifts the common example-app pattern into the library:
    /// pass `server` when the user supplied a URL, or pass `discover: true` to
    /// browse for `_sendspin-server._tcp.local.` and return the first discovered server.
    ///
    /// - Parameters:
    ///   - server: Optional explicit WebSocket URL string.
    ///   - discover: Whether to discover servers when `server` is nil.
    ///   - timeout: Discovery timeout. Fractional command-line values can be preserved
    ///     with `.milliseconds(Int(seconds * 1000))`.
    /// - Returns: The explicit URL or the first discovered server URL.
    /// - Throws: ``SendspinClientError/invalidServerURL(_:)`` for malformed URLs,
    ///   ``SendspinClientError/noDiscoveredServers`` when discovery finds none, or
    ///   discovery transport errors from ``discoverServers(timeout:)``.
    nonisolated static func resolveServerURL(
        server: String?,
        discover: Bool,
        timeout: Duration = .seconds(3)
    ) async throws -> URL {
        if let server {
            guard let url = URL(string: server), url.scheme != nil else {
                throw SendspinClientError.invalidServerURL(server)
            }
            return url
        }

        if discover {
            guard let first = try await discoverServers(timeout: timeout).first else {
                throw SendspinClientError.noDiscoveredServers
            }
            return first.url
        }

        throw SendspinClientError.serverURLRequired
    }

    /// Discover Sendspin servers on the local network (one-shot with timeout).
    ///
    /// Convenience wrapper that browses for `timeout`, then returns whatever was found.
    /// For continuous discovery (live-updating server list), use `discoverServers()`
    /// which returns a `ServerDiscovery` with an async stream.
    ///
    /// - Parameter timeout: How long to search for servers (default: 3 seconds)
    /// - Returns: Array of discovered servers
    nonisolated static func discoverServers(timeout: Duration = .seconds(3)) async throws -> [DiscoveredServer] {
        let discovery = try await discoverServers()

        return await withTaskGroup(of: Void.self) { group in
            // Stop browsing after the timeout, which finishes the `servers` stream
            // and ends the drain loop below. On caller cancellation the group
            // propagates to this child (sleep cancels → stopDiscovery fires).
            group.addTask {
                try? await Task.sleep(for: timeout)
                await discovery.stopDiscovery()
            }

            // The stream yields a fresh full list on every change; keep the latest.
            var latest: [DiscoveredServer] = []
            for await servers in discovery.servers {
                latest = servers
            }

            group.cancelAll()
            return latest
        }
    }
}
