import Foundation

/// Thrown internally when a competing connection's handshake does not complete
/// (no `server/hello` before the timeout, or the socket closed first). Caught in
/// arbitration to fall back to keeping the existing connection.
private struct HandshakeIncomplete: Error {}

private enum HandshakeProbeResult {
    case hello(ServerHelloMessage)
    case ended
    case timedOut
}

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
        // One at a time: `performHandshake` suspends for up to 5s and the incumbent is only
        // read after it, so overlapping candidates would each arbitrate against a stale
        // incumbent and both switch. Dropped like a loser — silent close, no goodbye.
        guard !arbitrationInProgress else {
            Log.client.warning("An arbitration is already in flight; dropping the competing connection")
            await newTransport.disconnect()
            return
        }
        arbitrationInProgress = true
        defer { arbitrationInProgress = false }

        // Snapshot the incumbent before suspending. Reading it afterwards would
        // arbitrate against whatever the state happens to be up to 5s later.
        let incumbentReason = currentConnectionReason
        let arbitrationEpoch = sessionEpoch

        let hello: ServerHelloMessage
        let negotiation: SessionFormatNegotiation
        do {
            negotiation = try await makeSessionFormatNegotiation()
            hello = try await performHandshake(on: newTransport, negotiation: negotiation)
        } catch {
            // The new server never completed its handshake — keep the existing one
            // and drop the probe WITHOUT a goodbye. This is deliberate, not an
            // oversight: the spec forbids sending any message (including
            // client/goodbye) before the handshake completes, so a silent close is
            // the only compliant exit. The timeout bound itself is ours — the spec
            // is silent, and waiting unboundedly would let one stalled server wedge
            // arbitration and hold a half-open socket forever.
            await newTransport.disconnect()
            return
        }

        // An explicit `disconnect()` (or a fresh dial) during the handshake bumps the
        // epoch. The caller no longer wants a session, so drop the candidate.
        guard sessionEpoch == arbitrationEpoch else {
            Log.client.warning("The session changed during arbitration; dropping the competing connection")
            await newTransport.disconnect()
            return
        }

        // The incumbent died on its own while we were handshaking (epoch unchanged, so
        // this was not the caller's doing). There is nothing left to arbitrate against —
        // adopt the candidate rather than measuring it against a corpse and concluding
        // `.keepExisting`, which would leave us with no connection at all.
        guard connection != nil else {
            updateConnectionState(.connecting)
            await setupConnection(with: newTransport, preReadHello: hello, negotiation: negotiation)
            return
        }

        let lastPlayed = await persistenceProvider?.loadLastPlayedServerId()
        let decision = Self.arbitrate(
            newReason: hello.payload.connectionReason,
            existingReason: incumbentReason ?? .discovery,
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
            await setupConnection(with: newTransport, preReadHello: hello, negotiation: negotiation)
        }
    }

    /// Send `client/hello` on `transport` and require the server's first inbound
    /// frame to be `server/hello`, which is returned. Touches only the candidate
    /// `transport` passed in (the facade stores no transport of its own), so it
    /// is safe to run against a competing connection while another is active.
    ///
    /// - Throws: `HandshakeIncomplete` if the stream ends, the first inbound frame
    ///   is not `server/hello`, or `timeout` elapses before the first frame arrives.
    @MainActor
    private func performHandshake(
        on transport: any SendspinTransport,
        negotiation: SessionFormatNegotiation,
        timeout: Duration = .seconds(5)
    ) async throws -> ServerHelloMessage {
        let payload = buildClientHelloPayload(
            effectivePlayerFormats: negotiation.effectivePlayerFormats
        )
        try await transport.send(ClientHelloMessage(payload: payload))

        return try await withThrowingTaskGroup(of: HandshakeProbeResult.self) { group in
            group.addTask {
                guard let frame = await transport.nextFrame() else {
                    return .ended
                }
                guard case let .text(text) = frame,
                      let hello = Self.decodeServerHello(text) else {
                    return .ended
                }
                return .hello(hello)
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .timedOut
                } catch {
                    // A successful hello/EOF cancels the timeout child while the
                    // group drains; cancellation is not itself a handshake failure.
                    return .ended
                }
            }

            let result = try await group.next() ?? .ended

            // The reader parks in `nextFrame()`, which only closure releases — not
            // cancellation — so every outcome that leaves it parked must close the
            // transport or the drain below never returns. Only `.hello` is safe to skip:
            // it came from the reader itself, and the transport goes on to be promoted.
            // `.ended` covers external cancellation, where the reader IS still parked.
            if case .hello = result {} else {
                await transport.disconnect()
            }
            group.cancelAll()
            while try await group.next() != nil {}

            switch result {
            case let .hello(hello):
                return hello
            case .ended, .timedOut:
                // Don't misreport cancellation as "server was unresponsive".
                try Task.checkCancellation()
                throw HandshakeIncomplete()
            }
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
