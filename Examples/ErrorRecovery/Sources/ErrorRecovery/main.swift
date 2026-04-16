// ABOUTME: Demonstrates robust reconnection with exponential backoff and error classification
// ABOUTME: Shows how to handle transient vs permanent errors and retry safely

import ArgumentParser
import Dispatch
import Foundation
import SendspinKit

// MARK: - URL resolution helper

private func resolveServerURL(server: String?, discover: Bool, timeout: Double) async throws -> URL {
    if let server {
        guard let url = URL(string: server) else {
            throw ValidationError("Invalid server URL: \(server)")
        }
        return url
    }
    if discover {
        print("Discovering Sendspin servers (\(timeout)s timeout)...")
        // Preserve fractional seconds — `.seconds(Int(timeout))` would truncate
        // `--timeout 2.5` to 2.0. `.milliseconds` is whole-number friendly.
        let servers = try await SendspinClient.discoverServers(
            timeout: .milliseconds(Int(timeout * 1000))
        )
        guard let first = servers.first else {
            throw ValidationError("No servers found via mDNS discovery")
        }
        print("Discovered: \(first.name) at \(first.url)")
        return first.url
    }
    throw ValidationError("Provide --server <url> or --discover")
}

// MARK: - Error classification

/// Classify errors as retryable (transient) or fatal (permanent).
///
/// Fatal errors mean the server fundamentally cannot serve this client —
/// retrying would just fail again immediately and waste resources.
/// Transient errors (network drops, audio init failures) are worth retrying.
///
/// The classification is deliberately explicit: anything not recognized is
/// treated as fatal so a typo'd URL or a library change doesn't put us into
/// an unbounded retry loop. If you need retry on a new error type, add it here.
private func isRetryableError(_ error: any Error) -> Bool {
    // Cooperative cancellation (SIGINT → disconnect()) — definitely fatal.
    if error is CancellationError { return false }

    if let streaming = error as? StreamingError {
        switch streaming {
        case .unsupportedCodec, .invalidFormat:
            // The server can't serve a format we support — retrying won't help.
            return false
        case .audioStartFailed:
            // Audio device may be temporarily unavailable (e.g. device switch).
            return true
        }
    }

    // URL-layer errors: split into "the URL itself is broken" (fatal) vs.
    // "transient network / server / TLS problem" (retryable).
    if let urlError = error as? URLError {
        switch urlError.code {
        case .badURL,
             .unsupportedURL,
             .userCancelledAuthentication,
             .userAuthenticationRequired,
             .secureConnectionFailed,
             .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return false
        default:
            // Network unreachable, timeout, DNS failure, connection refused, etc.
            return true
        }
    }

    if let clientError = error as? SendspinClientError {
        switch clientError {
        case .alreadyConnected:
            // Programmer error — we're not calling disconnect() between
            // attempts. Shouldn't happen in this loop, but if it does, retry
            // won't help.
            return false
        case .notConnected, .sendFailed:
            return true
        }
    }

    // Anything unrecognised (including POSIXError, CoreFoundation errors, etc.)
    // is treated as fatal to avoid a surprise infinite loop on a typo'd URL or
    // a library change. Expand this block as new transient error types are
    // identified.
    return false
}

// MARK: - Timestamp helper

private func timestamp() -> String {
    let now = Date()
    let calendar = Calendar.current
    let hour = calendar.component(.hour, from: now)
    let minute = calendar.component(.minute, from: now)
    let second = calendar.component(.second, from: now)
    return String(format: "%02d:%02d:%02d", hour, minute, second)
}

// MARK: - Shared retry state

/// Holds the shutdown flag shared between the SIGINT handler, the event loop,
/// and the retry loop.
///
/// All three access this on `@MainActor`, so MainActor isolation is sufficient —
/// no locks and no `nonisolated(unsafe)`. The SIGINT handler runs on the main
/// dispatch queue and uses `Task { @MainActor in … }` to mutate.
@MainActor
private final class RetryState {
    var shouldQuit: Bool = false
}

// MARK: - Command

@main
struct ErrorRecovery: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "ErrorRecovery",
        abstract: "Connect to a Sendspin server with exponential backoff retry on failure."
    )

    @Option(name: .long, help: "Server WebSocket URL (e.g. ws://192.168.1.5:8927).")
    var server: String?

    @Flag(name: .long, help: "Auto-discover a server via mDNS instead of --server.")
    var discover: Bool = false

    @Option(name: .long, help: "mDNS discovery timeout in seconds.")
    var timeout: Double = 5.0

    @Option(name: .long, help: "Maximum number of connection attempts (0 = unlimited).")
    var maxRetries: Int = 0

    @Option(name: .long, help: "Base retry delay in seconds (doubles each attempt, capped at 30s).")
    var retryDelay: Double = 1.0

    @MainActor
    func run() async throws {
        let url = try await resolveServerURL(server: server, discover: discover, timeout: timeout)

        // Shared quit flag: SIGINT handler and the event loop both set this;
        // the retry loop reads it. All accesses happen on MainActor.
        let state = RetryState()

        // Build client once. disconnect() resets state to .disconnected, so
        // we can call connect() again on the same instance without rebuilding.
        let client = try SendspinClient(
            clientId: "error-recovery-example",
            name: "Error Recovery",
            roles: [.playerV1],
            playerConfig: try PlayerConfiguration(
                bufferCapacity: 65_536,
                supportedFormats: [
                    try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
                ]
            )
        )

        // SIGINT: graceful shutdown. Set flag first so the retry loop exits,
        // then disconnect to send client/goodbye. The dispatch handler runs on
        // the main thread but isn't @MainActor-isolated — hop on via a Task.
        signal(SIGINT, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            print("\n[\(timestamp())] Caught SIGINT — shutting down...")
            Task { @MainActor in
                state.shouldQuit = true
                await client.disconnect()
            }
        }
        sigintSource.resume()

        print("[\(timestamp())] Target: \(url)")
        print("[\(timestamp())] Max retries: \(maxRetries == 0 ? "unlimited" : "\(maxRetries)")")
        print("[\(timestamp())] Base delay: \(retryDelay)s (exponential, capped at 30s)\n")

        var attempt = 0

        // MARK: Retry loop
        while !state.shouldQuit {
            attempt += 1
            let limitReached = maxRetries > 0 && attempt > maxRetries
            if limitReached {
                print("[\(timestamp())] Reached maximum retry limit (\(maxRetries)). Giving up.")
                break
            }

            print("[\(timestamp())] Attempt \(attempt): connecting to \(url)...")

            do {
                // connect() throws if the transport can't reach the server, or if
                // already connected. Since disconnect() resets to .disconnected,
                // the alreadyConnected case won't happen here.
                try await client.connect(to: url)
                print("[\(timestamp())] Connected. Monitoring events...")

                // Reset attempt counter on successful connect so backoff restarts
                // from the base delay after the next drop, not from a long delay
                // built up during earlier failures.
                attempt = 0

                // Monitor events until disconnect.
                // The loop exits when the AsyncStream finishes (i.e. after disconnect).
                for await event in client.events {
                    switch event {
                    case .serverConnected(let info):
                        print("[\(timestamp())] Server: \(info.name) (id: \(info.serverId))")

                    case .streamStarted(let format):
                        print("[\(timestamp())] Stream started: \(format.codec.rawValue) " +
                              "\(format.sampleRate)Hz \(format.channels)ch \(format.bitDepth)-bit")

                    case .streamEnded:
                        print("[\(timestamp())] Stream ended.")

                    case .disconnected(let reason):
                        switch reason {
                        case .connectionLost:
                            print("[\(timestamp())] Connection lost.")
                        case .explicit(let goodbye):
                            print("[\(timestamp())] Disconnected: \(goodbye.rawValue)")
                            // An explicit disconnect from SIGINT — we're done.
                            state.shouldQuit = true
                        }
                        // The stream is finished; the inner for-await exits naturally.

                    default:
                        break
                    }
                }

            } catch {
                print("[\(timestamp())] Connect error: \(error.localizedDescription)")

                if !isRetryableError(error) {
                    print("[\(timestamp())] Error is not retryable. Exiting.")
                    break
                }
            }

            // Don't delay if the quit flag was set while monitoring events.
            guard !state.shouldQuit else { break }

            // Exponential backoff: base * 2^(attempt-1), capped at 30s, with ±25% jitter.
            // Jitter prevents thundering-herd reconnects if many clients lost connection
            // at the same time (e.g. server restart).
            let exponential = retryDelay * pow(2.0, Double(max(0, attempt - 1)))
            let capped = min(exponential, 30.0)
            let jitter = Double.random(in: 0.75 ... 1.25)
            let delay = capped * jitter

            print("[\(timestamp())] Retrying in \(String(format: "%.1f", delay))s " +
                  "(attempt \(attempt + 1)\(maxRetries > 0 ? "/\(maxRetries)" : ""))...")
            try? await Task.sleep(for: .seconds(delay))
        }

        print("[\(timestamp())] Done.")
    }
}
