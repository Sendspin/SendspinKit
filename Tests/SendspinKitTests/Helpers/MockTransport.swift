import Foundation
@testable import SendspinKit

/// A mock transport for testing SendspinClient without a real WebSocket.
///
/// Inject server messages via `injectText(_:)` and `injectBinary(_:)`.
/// Inspect client-sent messages via `sentTextMessages` and `sentBinaryMessages`.
/// Simulate failures via `setShouldFailOnSend(_:)`.
actor MockTransport: SendspinTransport {
    private let inbox = FrameInbox()

    /// JSON-encoded messages sent by the client, captured as raw Data.
    private(set) var sentTextMessages: [Data] = []
    /// Binary messages sent by the client.
    private(set) var sentBinaryMessages: [Data] = []

    /// When true, `send` and `sendBinary` throw to simulate transport failure.
    /// Mutate via `setShouldFailOnSend(_:)` from outside the actor.
    private(set) var shouldFailOnSend = false

    private(set) var isConnected = true
    private(set) var disconnectCalled = false
    /// Number of times `disconnect()` was invoked. Lets tests prove teardown ran
    /// exactly once across idempotent/concurrent shutdown paths (not just "did not hang").
    private(set) var disconnectCallCount = 0

    /// When enabled, a `client/goodbye` send suspends until ``releaseGoodbyeGate()``.
    private var goodbyeGateEnabled = false
    private var goodbyeGateContinuation: CheckedContinuation<Void, Never>?

    private let encoder = SendspinEncoding.makeEncoder()

    // MARK: - SendspinTransport conformance

    func nextFrame() async -> TransportFrame? {
        await inbox.next()
    }

    func send(_ message: some Codable & Sendable) async throws {
        if shouldFailOnSend {
            throw MockTransportError.simulatedFailure
        }
        let data = try encoder.encode(message)
        // Deterministic seam for the disconnect-vs-loss race: block only the
        // `client/goodbye` send so a test can pin `disconnect()` past its entry
        // guard, mid-teardown, while another teardown path runs.
        // Match "goodbye" rather than the full "client/goodbye": JSONEncoder escapes
        // the slash ("client\/goodbye"), and only the goodbye message carries the word.
        if goodbyeGateEnabled, let text = String(data: data, encoding: .utf8), text.contains("goodbye") {
            await withCheckedContinuation { goodbyeGateContinuation = $0 }
        }
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
        disconnectCallCount += 1
        finishStreams()
    }

    // MARK: - Test helpers

    /// Inject a JSON text message as if the server sent it.
    func injectText(_ json: String) {
        inbox.yield(.text(json))
    }

    /// Inject raw binary data as if the server sent it.
    func injectBinary(_ data: Data) {
        inbox.yield(.binary(data))
    }

    /// Finish the frame stream (simulates connection close without changing `isConnected`).
    /// `disconnect()` delegates here for the stream teardown portion.
    /// Safe to call multiple times — `FrameInbox.finish()` is idempotent.
    func finishStreams() {
        inbox.finish()
    }

    /// Enable or disable simulated send failures.
    ///
    /// Actor-isolated properties can only be mutated from within the actor,
    /// so this method provides the cross-isolation mutation point.
    func setShouldFailOnSend(_ value: Bool) {
        shouldFailOnSend = value
    }

    /// Arm the goodbye gate: the next `client/goodbye` send will suspend until
    /// ``releaseGoodbyeGate()``.
    func enableGoodbyeGate() {
        goodbyeGateEnabled = true
    }

    /// Whether a `client/goodbye` send is currently parked on the gate.
    var isGoodbyeGateWaiting: Bool {
        goodbyeGateContinuation != nil
    }

    /// Release a parked goodbye send and disarm the gate.
    func releaseGoodbyeGate() {
        goodbyeGateEnabled = false
        goodbyeGateContinuation?.resume()
        goodbyeGateContinuation = nil
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
