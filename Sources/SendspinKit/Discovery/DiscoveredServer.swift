// ABOUTME: Represents a discovered Sendspin server from mDNS
// ABOUTME: Contains server name, URL, and metadata from TXT records

import Foundation

/// A Sendspin server discovered via mDNS.
///
/// ``Identifiable/id`` is the Bonjour service name (``name``), which is the
/// canonical DNS-SD identity within a service type. ``Equatable`` and ``Hashable``
/// use all fields so that change detection (e.g. SwiftUI list diffing) picks up
/// updates like a service re-registering on a different port.
public struct DiscoveredServer: Sendable, Identifiable, Equatable, Hashable {
    /// Unique identifier — the Bonjour service name (same as ``name``).
    public var id: String {
        name
    }

    /// Human-readable server name (also the Bonjour service name)
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
        name: String,
        url: URL,
        hostname: String,
        port: UInt16,
        metadata: [String: String] = [:]
    ) {
        self.name = name
        self.url = url
        self.hostname = hostname
        self.port = port
        self.metadata = metadata
    }
}
