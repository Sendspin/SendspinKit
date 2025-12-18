// ABOUTME: Demonstrates robust reconnection and error handling patterns with SendspinKit
// ABOUTME: Shows exponential backoff, connection state machine, and graceful degradation

import Foundation
import SendspinKit
import ArgumentParser

@main
struct ErrorRecovery: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Demonstrate error recovery and reconnection patterns for SendspinKit",
        discussion: """
            This example shows how to handle connection failures, unexpected disconnects,
            and server errors with robust reconnection logic using exponential backoff.

            Key teaching points:
            • Exponential backoff with jitter to avoid thundering herd
            • Connection state machine (disconnected → connecting → connected → error)
            • Distinguishing between retryable and non-retryable errors
            • Maximum retry limits and circuit breaker patterns
            • Graceful degradation when server is unavailable

            The example will continuously attempt to maintain connection to a Sendspin server,
            demonstrating real-world resilience patterns for production applications.
            """
    )

    @Option(name: .long, help: "Server WebSocket URL (e.g., ws://localhost:8927)")
    var server: String?

    @Flag(name: .long, help: "Discover servers on the local network")
    var discover: Bool = false

    @Option(name: .long, help: "Discovery timeout in seconds")
    var timeout: Int = 5

    @Option(name: .long, help: "Maximum reconnection attempts (0 = unlimited)")
    var maxRetries: Int = 0

    @Option(name: .long, help: "Base delay between retries in seconds (for exponential backoff)")
    var retryDelay: Double = 1.0

    mutating func validate() throws {
        // Must provide either --server or --discover
        if server == nil && !discover {
            throw ValidationError("Must specify either --server <url> or --discover")
        }

        if server != nil && discover {
            throw ValidationError("Cannot specify both --server and --discover")
        }

        if timeout <= 0 || timeout > 60 {
            throw ValidationError("Timeout must be between 1 and 60 seconds")
        }

        if maxRetries < 0 {
            throw ValidationError("Max retries must be >= 0 (0 = unlimited)")
        }

        if retryDelay < 0.1 || retryDelay > 60.0 {
            throw ValidationError("Retry delay must be between 0.1 and 60 seconds")
        }
    }

    @MainActor
    mutating func run() async throws {
        print("🔧 ErrorRecovery - Demonstrating Reconnection Patterns")
        print("================================================")
        print("")

        // Determine server URL
        let serverURL: URL

        if discover {
            print("🔍 Discovering Sendspin servers (timeout: \(timeout)s)...")
            let servers = await SendspinClient.discoverServers(timeout: .seconds(timeout))

            if servers.isEmpty {
                print("❌ No servers found on local network")
                print("💡 Tips:")
                print("   • Ensure a Sendspin server is running")
                print("   • Check network connectivity")
                print("   • Try increasing --timeout")
                throw ExitCode.failure
            }

            let selected = servers[0]
            print("✅ Found: \(selected.name) at \(selected.url)")
            serverURL = selected.url
        } else {
            guard let urlString = server, let url = URL(string: urlString) else {
                print("❌ Invalid server URL: \(server ?? "")")
                throw ExitCode.failure
            }
            serverURL = url
        }

        print("")
        print("📋 Configuration:")
        print("   Server:       \(serverURL)")
        print("   Max Retries:  \(maxRetries == 0 ? "unlimited" : String(maxRetries))")
        print("   Base Delay:   \(String(format: "%.1f", retryDelay))s")
        print("")

        // Create client with player capabilities
        let clientId = UUID().uuidString
        let client = SendspinClient(
            clientId: clientId,
            name: "ErrorRecovery-\(ProcessInfo.processInfo.hostName)",
            roles: [.playerV1],
            playerConfig: PlayerConfiguration(
                bufferCapacity: 8192,
                supportedFormats: [
                    AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16)
                ]
            )
        )

        // Start reconnection loop
        let recovery = ReconnectionManager(
            client: client,
            serverURL: serverURL,
            maxRetries: maxRetries,
            baseDelay: retryDelay
        )

        // Handle graceful shutdown
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signalSource.setEventHandler {
            print("\n\n🛑 Shutdown signal received")
            Task { @MainActor in
                await recovery.shutdown()
                Darwin.exit(0)
            }
        }
        signal(SIGINT, SIG_IGN)
        signalSource.resume()

        // Run the recovery loop
        await recovery.run()
    }
}

/// Connection state for tracking lifecycle
enum RecoveryState {
    case disconnected
    case discovering
    case connecting(attempt: Int)
    case connected
    case reconnecting(attempt: Int, reason: String)
    case backoff(attempt: Int, delay: TimeInterval)
    case failed(reason: String)
    case shuttingDown

    var displayName: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .discovering: return "Discovering"
        case .connecting(let attempt): return "Connecting (attempt \(attempt))"
        case .connected: return "Connected"
        case .reconnecting(let attempt, _): return "Reconnecting (attempt \(attempt))"
        case .backoff(let attempt, let delay): return "Backoff (attempt \(attempt), \(String(format: "%.1f", delay))s)"
        case .failed: return "Failed"
        case .shuttingDown: return "Shutting Down"
        }
    }
}

/// Manages reconnection logic with exponential backoff
@MainActor
class ReconnectionManager {
    private let client: SendspinClient
    private let serverURL: URL
    private let maxRetries: Int
    private let baseDelay: Double

    private var state: RecoveryState = .disconnected
    private var isRunning = false
    private var eventTask: Task<Void, Never>?

    init(client: SendspinClient, serverURL: URL, maxRetries: Int, baseDelay: Double) {
        self.client = client
        self.serverURL = serverURL
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
    }

    func run() async {
        isRunning = true
        var attemptCount = 0

        while isRunning {
            // Check if we've exceeded max retries
            if maxRetries > 0 && attemptCount >= maxRetries {
                setState(.failed(reason: "Exceeded maximum retry attempts (\(maxRetries))"))
                print("\n❌ FATAL: Maximum retry attempts exceeded")
                print("💡 The client has given up trying to connect")
                print("   This demonstrates when to stop retrying and fail gracefully")
                break
            }

            attemptCount += 1

            // Attempt connection
            setState(.connecting(attempt: attemptCount))
            print("\n🔌 Attempting connection (attempt \(attemptCount)/\(maxRetries == 0 ? "∞" : String(maxRetries)))...")

            do {
                try await client.connect(to: serverURL)
                setState(.connected)
                attemptCount = 0 // Reset on successful connection
                print("✅ Connected successfully!")

                // Start event monitoring
                startEventMonitoring()

                // Wait for disconnection by monitoring connection state
                await waitForDisconnection()

                // Stop event monitoring
                stopEventMonitoring()

                // Determine if we should reconnect
                if !isRunning {
                    break
                }

                setState(.reconnecting(attempt: attemptCount + 1, reason: "Connection lost"))
                print("\n⚠️  Connection lost - preparing to reconnect...")

            } catch {
                print("❌ Connection failed: \(error)")

                // Classify error
                let shouldRetry = classifyError(error)

                if !shouldRetry {
                    setState(.failed(reason: "Non-retryable error: \(error)"))
                    print("\n❌ FATAL: Non-retryable error encountered")
                    print("   Error type: \(type(of: error))")
                    print("   This demonstrates distinguishing retryable vs non-retryable errors")
                    break
                }

                // Calculate backoff delay with exponential growth and jitter
                let delay = calculateBackoff(attempt: attemptCount)
                setState(.backoff(attempt: attemptCount, delay: delay))

                print("⏱️  Backing off for \(String(format: "%.2f", delay))s (exponential backoff with jitter)...")
                print("   Formula: min(baseDelay * 2^(attempt-1) + jitter, 60s)")
                print("   Base delay: \(String(format: "%.1f", baseDelay))s, Attempt: \(attemptCount)")

                // Wait for backoff period (unless shutting down)
                let deadline = Date().addingTimeInterval(delay)
                while Date() < deadline && isRunning {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }

        setState(.shuttingDown)
    }

    func shutdown() async {
        print("\n🛑 Initiating graceful shutdown...")
        isRunning = false
        eventTask?.cancel()
        _ = await eventTask?.result  // Wait for task cancellation
        await client.disconnect()
        print("✅ Shutdown complete")
    }

    private func setState(_ newState: RecoveryState) {
        let oldState = state
        state = newState

        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] State: \(oldState.displayName) → \(newState.displayName)")
    }

    private func startEventMonitoring() {
        eventTask = Task { [weak self] in
            guard let self = self else { return }

            for await event in self.client.events {
                self.handleEvent(event)
            }
        }
    }

    private func stopEventMonitoring() {
        eventTask?.cancel()
        eventTask = nil
    }

    private func handleEvent(_ event: ClientEvent) {
        switch event {
        case .serverConnected(let info):
            print("📡 Server Info: \(info.name) (v\(info.version))")

        case .streamStarted(let format):
            print("🎵 Stream Started: \(format.codec.rawValue) \(format.sampleRate)Hz \(format.channels)ch")

        case .streamEnded:
            print("⏹️  Stream Ended")

        case .groupUpdated(let info):
            print("👥 Group: \(info.groupName) [\(info.playbackState ?? "unknown")]")

        case .metadataReceived(let metadata):
            if let title = metadata.title, let artist = metadata.artist {
                print("🎵 Now Playing: \(title) - \(artist)")
            }

        case .artworkReceived(let channel, _):
            print("🖼️  Artwork received (channel \(channel))")

        case .visualizerData:
            // High frequency - don't log
            break

        case .error(let message):
            print("⚠️  Server Error: \(message)")
        }
    }

    private func waitForDisconnection() async {
        // Monitor connection state until disconnected
        // In a real app, you'd observe the connection state property
        // For this example, we'll poll it
        while isRunning {
            let connectionState = client.connectionState

            if case .disconnected = connectionState {
                break
            }

            if case .error(let message) = connectionState {
                print("⚠️  Connection error: \(message)")
                break
            }

            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Classify error to determine if retry is appropriate
    private func classifyError(_ error: Error) -> Bool {
        // In a production app, you'd inspect specific error types
        // and determine retry strategy based on error category

        print("🔍 Classifying error for retry decision...")

        // Example classification logic:
        // - Network errors: Retry
        // - Authentication errors: Don't retry (would need user intervention)
        // - Server unavailable: Retry
        // - Protocol errors: Don't retry (client/server mismatch)

        let errorDescription = String(describing: error)

        // Check for non-retryable errors first (permanent failures)
        if errorDescription.contains("authentication") ||
           errorDescription.contains("unauthorized") ||
           errorDescription.contains("invalid") ||
           errorDescription.contains("protocol") {
            print("   ❌ Non-retryable error (permanent failure)")
            return false
        }

        // Retryable: network/connection issues
        if errorDescription.contains("connection") ||
           errorDescription.contains("timeout") ||
           errorDescription.contains("network") ||
           errorDescription.contains("refused") {
            print("   ✅ Retryable error (network/connection related)")
            return true
        }

        // Default to retrying for unknown errors
        print("   ⚠️ Unknown error type - retrying (default policy)")
        return true
    }

    /// Calculate exponential backoff delay with jitter
    private func calculateBackoff(attempt: Int) -> TimeInterval {
        // Exponential backoff: baseDelay * 2^(attempt-1)
        let exponential = baseDelay * pow(2.0, Double(attempt - 1))

        // Add jitter (±25% randomization to prevent thundering herd)
        let jitterPercent = Double.random(in: 0.75...1.25)
        let withJitter = exponential * jitterPercent

        // Cap at 60 seconds
        return min(withJitter, 60.0)
    }
}
