import Foundation
@testable import SendspinKit

/// A mock transport for testing SendspinClient without a real WebSocket.
///
/// Inject server messages via `injectText(_:)` and `injectBinary(_:)`.
/// Inspect client-sent messages via `sentTextMessages` and `sentBinaryMessages`.
/// Simulate failures via `setShouldFailOnSend(_:)`.
actor MockTransport: ClientDialingTransport {
    private let inbox = FrameInbox()
    /// Client-sent frames, observable as an ordered pull stream so a test-side peer
    /// (e.g. the mock Noise server) can react to sends as they happen.
    private let outbox = FrameInbox()
    private var encryptedTextSender: (@Sendable (String) async throws -> Void)?
    private var encryptedBinarySender: (@Sendable (Data) async throws -> Void)?

    /// JSON-encoded messages sent by the client, captured as raw Data.
    private(set) var sentTextMessages: [Data] = []
    /// Binary messages sent by the client.
    private(set) var sentBinaryMessages: [Data] = []

    var hasSentFrames: Bool {
        !sentTextMessages.isEmpty || !sentBinaryMessages.isEmpty
    }

    /// When true, `send` and `sendBinary` throw to simulate transport failure.
    /// Mutate via `setShouldFailOnSend(_:)` from outside the actor.
    private(set) var shouldFailOnSend = false

    private(set) var isConnected = true

    /// Mirrors `NWWebSocketTransport`'s first-writer-wins semantics so tests exercise the
    /// same contract: `disconnect()` records `.cancelled`, and a test can simulate a peer
    /// close or a network failure via ``simulateClose(_:)`` before finishing the stream.
    private(set) var closeReason: TransportCloseReason?

    private(set) var disconnectCalled = false
    /// Number of times `disconnect()` was invoked. Lets tests prove teardown ran
    /// exactly once across idempotent/concurrent shutdown paths (not just "did not hang").
    private(set) var disconnectCallCount = 0

    /// When enabled, a `client/goodbye` send suspends until ``releaseGoodbyeGate()``.
    private var goodbyeGateEnabled = false
    private var goodbyeGateContinuation: CheckedContinuation<Void, Never>?

    private let encoder = SendspinEncoding.makeEncoder()

    // MARK: - SendspinTransport conformance

    func connect() async throws {}

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

    func sendRawText(_ text: String) async throws {
        if shouldFailOnSend {
            throw MockTransportError.simulatedFailure
        }
        sentTextMessages.append(Data(text.utf8))
        outbox.yield(.text(text))
    }

    func sendBinary(_ data: Data) async throws {
        if shouldFailOnSend {
            throw MockTransportError.simulatedFailure
        }
        sentBinaryMessages.append(data)
        outbox.yield(.binary(data))
    }

    /// Full teardown: marks disconnected and finishes both streams.
    func disconnect() async {
        recordCloseReason(.cancelled)
        isConnected = false
        disconnectCalled = true
        disconnectCallCount += 1
        finishStreams()
    }

    /// Simulate a terminal condition observed on the wire (peer close, network failure)
    /// before the stream finishes, so tests can drive the non-`.cancelled` paths.
    func simulateClose(_ reason: TransportCloseReason) {
        recordCloseReason(reason)
        isConnected = false
        finishStreams()
    }

    private func recordCloseReason(_ reason: TransportCloseReason) {
        guard closeReason == nil else { return }
        closeReason = reason
    }

    // MARK: - Test helpers

    /// Install an encrypted server-message sender for an established session.
    func installEncryptedTextSender(_ sender: @escaping @Sendable (String) async throws -> Void) {
        encryptedTextSender = sender
    }

    /// Inject a JSON text message as if the server sent it.
    func injectText(_ json: String) async {
        if let sender = encryptedTextSender {
            try? await sender(json)
        } else {
            inbox.yield(.text(json))
        }
    }

    /// Inject raw binary data as if the server sent it.
    func injectBinary(_ data: Data) {
        inbox.yield(.binary(data))
    }

    func installEncryptedBinarySender(_ sender: @escaping @Sendable (Data) async throws -> Void) {
        encryptedBinarySender = sender
    }

    func injectEncryptedBinary(_ data: Data) async {
        try? await encryptedBinarySender?(data)
    }

    /// Pull the next client-sent frame in send order. Returns `nil` after the
    /// transport closes. Single-consumer, like `nextFrame()`.
    func nextSentFrame() async -> TransportFrame? {
        await outbox.next()
    }

    /// Finish the frame stream (simulates connection close without changing `isConnected`).
    /// `disconnect()` delegates here for the stream teardown portion.
    /// Safe to call multiple times — `FrameInbox.finish()` is idempotent.
    func finishStreams() {
        inbox.finish()
        outbox.finish()
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
