import Foundation

/// A Sendspin server discovered via mDNS.
///
/// ``Identifiable/id`` is the Bonjour service name (``serviceName``), which is the
/// canonical DNS-SD identity within a service type. ``name`` is the user-facing
/// display name and may come from the server's TXT `name` record. ``Equatable``
/// and ``Hashable`` use all fields so that change detection (e.g. SwiftUI list
/// diffing) picks up updates like a service re-registering on a different port
/// or changing its friendly display name.
public struct DiscoveredServer: Sendable, Identifiable, Equatable, Hashable {
    /// Unique identifier — the Bonjour service name.
    public var id: String {
        serviceName
    }

    /// Bonjour service name, used as the stable DNS-SD identity.
    public let serviceName: String

    /// Human-readable server display name.
    ///
    /// Discovery uses the TXT `name` value when present and non-empty, otherwise
    /// it falls back to ``serviceName``.
    public let name: String

    /// WebSocket URL to connect to this server
    public let url: URL

    /// Server hostname
    public let hostname: String

    /// Server port
    public let port: UInt16

    /// Additional metadata from TXT records
    public let metadata: [String: String]

    public init(
        serviceName: String? = nil,
        name: String,
        url: URL,
        hostname: String,
        port: UInt16,
        metadata: [String: String] = [:]
    ) {
        self.serviceName = serviceName ?? name
        self.name = name
        self.url = url
        self.hostname = hostname
        self.port = port
        self.metadata = metadata
    }
}
