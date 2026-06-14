// ABOUTME: Persistence hook for the spec's multi-server "last played server" bookkeeping
// ABOUTME: Lets the host store and restore the server_id used for arbitration tiebreaks

import Foundation

/// Storage hook for the spec's "last played server" bookkeeping.
///
/// The Sendspin multi-server rules require a client to *persistently* remember the
/// `server_id` of the server that most recently had `playback_state: playing`. When
/// two servers compete and both connect with `connection_reason: discovery`, the
/// client breaks the tie in favor of that remembered server.
///
/// ``SendspinClient`` calls ``saveLastPlayedServerId(_:)`` whenever a `group/update`
/// reports that playback has started, and ``loadLastPlayedServerId()`` when it needs
/// the stored value for arbitration. Back it with whatever storage is appropriate —
/// `UserDefaults`, a file, the keychain, etc.
///
/// If no provider is supplied to ``SendspinClient/init(clientId:name:roles:deviceInfo:playerConfig:artworkConfig:persistenceProvider:)``,
/// SendspinKit performs no implicit persistence and treats the last-played value as
/// absent during multi-server arbitration. Host apps that need the spec's persisted
/// last-played tiebreak should provide an implementation explicitly.
///
/// Methods are `async` so implementations may perform I/O off the main actor, and the
/// protocol is `Sendable` because the provider is shared across concurrency domains.
public protocol SendspinPersistenceProvider: Sendable {
    /// The persisted last-played `server_id`, or `nil` if none has been stored yet.
    func loadLastPlayedServerId() async -> String?

    /// Persist `serverId` as the most recently playing server.
    func saveLastPlayedServerId(_ serverId: String) async
}
