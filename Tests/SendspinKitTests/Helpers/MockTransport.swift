// ABOUTME: Mock transport for integration testing SendspinClient
// ABOUTME: Captures sent messages, injects server messages via continuations, simulates failures

import Foundation
@testable import SendspinKit

/// A mock transport for testing SendspinClient without a real WebSocket.
///
/// Inject server messages via `injectText(_:)` and `injectBinary(_:)`.
/// Inspect client-sent messages via `sentTextMessages` and `sentBinaryMessages`.
/// Simulate failures via `setShouldFailOnSend(_:)`.
actor MockTransport: SendspinTransport {
    nonisolated let textMessages: AsyncStream<String>
    nonisolated let binaryMessages: AsyncStream<Data>

    private let textContinuation: AsyncStream<String>.Continuation
    private let binaryContinuation: AsyncStream<Data>.Continuation

    /// JSON-encoded messages sent by the client, captured as raw Data.
    private(set) var sentTextMessages: [Data] = []
    /// Binary messages sent by the client.
    private(set) var sentBinaryMessages: [Data] = []

    /// When true, `send` and `sendBinary` throw to simulate transport failure.
    /// Mutate via `setShouldFailOnSend(_:)` from outside the actor.
    private(set) var shouldFailOnSend = false

    private(set) var isConnected = true
    private(set) var disconnectCalled = false

    private let encoder = SendspinEncoding.makeEncoder()

    init() {
        (textMessages, textContinuation) = AsyncStream.makeStream()
        (binaryMessages, binaryContinuation) = AsyncStream.makeStream()
    }

    // MARK: - SendspinTransport conformance

    func send(_ message: some Codable & Sendable) async throws {
        if shouldFailOnSend {
            throw MockTransportError.simulatedFailure
        }
        let data = try encoder.encode(message)
        sentTextMessages.append(data)
    }

    func sendBinary(_ data: Data) async throws {
        if shouldFailOnSend {
            throw MockTransportError.simulatedFailure
        }
        sentBinaryMessages.append(data)
    }

    /// Full teardown: marks disconnected and finishes both streams.
    func disconnect() async {
        isConnected = false
        disconnectCalled = true
        finishStreams()
    }

    // MARK: - Test helpers

    /// Inject a JSON text message as if the server sent it.
    func injectText(_ json: String) {
        textContinuation.yield(json)
    }

    /// Inject raw binary data as if the server sent it.
    func injectBinary(_ data: Data) {
        binaryContinuation.yield(data)
    }

    /// Finish both streams (simulates connection close without changing `isConnected`).
    /// `disconnect()` delegates here for the stream teardown portion.
    /// Safe to call multiple times — `AsyncStream.Continuation.finish()` is idempotent.
    func finishStreams() {
        textContinuation.finish()
        binaryContinuation.finish()
    }

    /// Enable or disable simulated send failures.
    ///
    /// Actor-isolated properties can only be mutated from within the actor,
    /// so this method provides the cross-isolation mutation point.
    func setShouldFailOnSend(_ value: Bool) {
        shouldFailOnSend = value
    }
}

enum MockTransportError: Error, LocalizedError {
    case simulatedFailure

    var errorDescription: String? {
        switch self {
        case .simulatedFailure:
            "Simulated transport failure"
        }
    }
}
