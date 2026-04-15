// ABOUTME: Top-level namespace and protocol constants for SendspinKit
// ABOUTME: Defines spec-defined defaults for ports, paths, and service types

import Foundation

/// Marker protocol for all errors thrown by SendspinKit.
///
/// Consumers can catch any library error with `catch let error as SendspinError`
/// or match specific types for targeted handling.
public protocol SendspinError: Error, Sendable {}

/// Error thrown when attempting to start a discovery or advertiser instance that
/// has been permanently stopped. Create a new instance instead.
public struct TerminatedError: Error, Sendable, LocalizedError, CustomStringConvertible {
    public var errorDescription: String? {
        "Instance has been permanently stopped; create a new one"
    }

    public var description: String {
        errorDescription!
    }
}

extension TerminatedError: SendspinError {}

/// Protocol-level constants from the Sendspin specification.
public enum SendspinDefaults {
    /// Default port for clients to listen on (server-initiated connections).
    /// Spec: "recommended: 8928"
    public static let clientPort: UInt16 = 8_928

    /// Default port for servers to listen on (client-initiated connections).
    /// Spec: "recommended: 8927"
    public static let serverPort: UInt16 = 8_927

    /// Default WebSocket endpoint path.
    /// Spec: "recommended: /sendspin"
    public static let webSocketPath: String = "/sendspin"

    /// Bonjour service type for client advertisement (server-initiated connections).
    /// Spec: "_sendspin._tcp.local."
    public static let clientServiceType: String = "_sendspin._tcp"

    /// Bonjour service type for server advertisement (client-initiated connections).
    /// Spec: "_sendspin-server._tcp.local."
    public static let serverServiceType: String = "_sendspin-server._tcp"
}
