import Foundation

extension SendspinConnection {
    /// Send a `stream/request-format` for the player role.
    ///
    /// Per spec, a client may request a format even when no player stream is
    /// active. The server must not start a stream in response, but should remember
    /// the request and apply it to the next player stream it starts.
    func requestFormat(player request: PlayerFormatRequest) async throws {
        try await send(clientMessage: StreamRequestFormatMessage(
            payload: StreamRequestFormatPayload(player: request)
        ))
    }

    /// Send a `stream/request-format` for the artwork role. See
    /// ``requestFormat(player:)`` for the no-active-stream contract.
    func requestFormat(artwork request: ArtworkFormatRequest) async throws {
        try await send(clientMessage: StreamRequestFormatMessage(
            payload: StreamRequestFormatPayload(artwork: request)
        ))
    }
}
