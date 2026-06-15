import Foundation

extension SendspinConnection {
    /// Send a `stream/request-format` for the player role.
    ///
    /// The protocol-intent gate lives here — the single authority. It is open
    /// between the role's `stream/start` and `stream/end` (including after an
    /// unsupported/invalid start, which is exactly the state a client recovers
    /// from by requesting a supported format) and stays open across
    /// `stream/clear`, which clears buffers without ending the stream.
    func requestFormat(player request: PlayerFormatRequest) async throws {
        guard playerStreamActive else { throw SendspinClientError.streamNotActive(.player) }
        try await send(clientMessage: StreamRequestFormatMessage(
            payload: StreamRequestFormatPayload(player: request)
        ))
    }

    /// Send a `stream/request-format` for the artwork role. See
    /// ``requestFormat(player:)`` for the gate contract.
    func requestFormat(artwork request: ArtworkFormatRequest) async throws {
        guard artworkStreamActive else { throw SendspinClientError.streamNotActive(.artwork) }
        try await send(clientMessage: StreamRequestFormatMessage(
            payload: StreamRequestFormatPayload(artwork: request)
        ))
    }
}
