// ABOUTME: Multi-server arbitration for SendspinClient (handshake-first switching)
// ABOUTME: Decides whether a competing server connection should displace the active one

import Foundation

/// Thrown internally when a competing connection's handshake does not complete
/// (no `server/hello` before the timeout, or the socket closed first). Caught in
/// arbitration to fall back to keeping the existing connection.
private struct HandshakeIncomplete: Error {}

extension SendspinClient {
    /// Outcome of multi-server arbitration when a second server connects.
    enum ArbitrationDecision: Equatable {
        case switchToNew
        case keepExisting
    }

    /// Decide whether to switch to a newly-connected server, per the spec's
    /// multiple-servers rules. Pure (no I/O) so the full decision table is
    /// exhaustively unit-testable.
    ///
    /// - new `playback` always wins (a server wants this client for playback).
    /// - new `discovery` never displaces an existing `playback`.
    /// - both `discovery`: switch only if the new server is the persisted
    ///   last-played one, otherwise keep whoever is already connected.
    nonisolated static func arbitrate(
        newReason: ConnectionReason,
        existingReason: ConnectionReason,
        newServerId: String,
        lastPlayedServerId: String?
    ) -> ArbitrationDecision {
        switch (newReason, existingReason) {
        case (.playback, _):
            return .switchToNew
        case (.discovery, .playback):
            return .keepExisting
        case (.discovery, .discovery):
            if let lastPlayedServerId, newServerId == lastPlayedServerId {
                return .switchToNew
            }
            return .keepExisting
        }
    }

    /// Handle a competing server connection per the spec's multi-server rules.
    ///
    /// Completes the `client/hello` ↔ `server/hello` handshake on the *new*
    /// connection first (without disturbing the active connection), then applies
    /// ``arbitrate(newReason:existingReason:newServerId:existingServerId:lastPlayedServerId:)``.
    /// On a switch we leave the current server with `another_server` and adopt the
    /// new one; otherwise we send the new (losing) server `another_server` and drop it.
    @MainActor
    func handleCompetingConnection(_ newTransport: any SendspinTransport) async throws {
        let hello: ServerHelloMessage
        do {
            hello = try await performHandshake(on: newTransport)
        } catch {
            // The new server never completed its handshake — keep the existing one.
            await newTransport.disconnect()
            return
        }

        let lastPlayed = await persistenceProvider?.loadLastPlayedServerId()
        let decision = Self.arbitrate(
            newReason: hello.payload.connectionReason,
            existingReason: currentConnectionReason ?? .discovery,
            newServerId: hello.payload.serverId,
            lastPlayedServerId: lastPlayed
        )

        switch decision {
        case .keepExisting:
            try? await newTransport.send(
                ClientGoodbyeMessage(payload: GoodbyePayload(reason: .anotherServer))
            )
            await newTransport.disconnect()
        case .switchToNew:
            await disconnect(reason: .anotherServer)
            updateConnectionState(.connecting)
            try await setupConnection(with: newTransport, preReadHello: hello)
        }
    }

    /// Send `client/hello` on `transport` and read its message stream until the
    /// first `server/hello`, which is returned. Reads only `transport`'s own
    /// stream and never touches `self.transport`, so it is safe to run against a
    /// competing connection while another is active.
    ///
    /// - Throws: `HandshakeIncomplete` if the stream ends or `timeout` elapses
    ///   before a `server/hello` arrives.
    @MainActor
    private func performHandshake(
        on transport: any SendspinTransport,
        timeout: Duration = .seconds(5)
    ) async throws -> ServerHelloMessage {
        try await transport.send(ClientHelloMessage(payload: buildClientHelloPayload()))

        return try await withThrowingTaskGroup(of: ServerHelloMessage?.self) { group in
            group.addTask {
                for await frame in transport.frames {
                    // server/hello is the first message per spec; ignore anything before it.
                    guard case let .text(text) = frame,
                          let hello = Self.decodeServerHello(text) else { continue }
                    return hello
                }
                return nil // stream ended without a server/hello
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil // timed out
            }
            defer { group.cancelAll() }
            if let hello = try await group.next() ?? nil {
                return hello
            }
            throw HandshakeIncomplete()
        }
    }

    /// Decode a raw text frame as a `server/hello`, or `nil` if it is a different
    /// message type. Mirrors the type-first dispatch in `handleTextMessage`.
    private nonisolated static func decodeServerHello(_ text: String) -> ServerHelloMessage? {
        guard let data = text.data(using: .utf8),
              SendspinEncoding.messageType(of: data) == "server/hello"
        else { return nil }
        return try? JSONDecoder().decode(ServerHelloMessage.self, from: data)
    }
}
