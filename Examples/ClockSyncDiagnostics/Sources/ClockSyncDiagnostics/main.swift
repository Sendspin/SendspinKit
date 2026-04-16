// ABOUTME: Real-time clock synchronization diagnostics dashboard
// ABOUTME: Polls currentClockSyncStats() and renders an ANSI terminal dashboard

import ArgumentParser
import Dispatch
import Foundation
import SendspinKit

// MARK: - ANSI helpers

private enum ANSI {
    static let clearScreen = "\u{1B}[2J\u{1B}[H"
    static let green = "\u{1B}[32m"
    static let yellow = "\u{1B}[33m"
    static let red = "\u{1B}[31m"
    static let reset = "\u{1B}[0m"
}

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

// MARK: - Quality display

/// Render a ``ClockSyncQuality`` tier as an uppercase label + ANSI color.
/// The qualitative thresholds themselves live on ``ClockSyncQuality`` so every
/// SendspinKit consumer agrees on what "good" means.
private func display(for quality: ClockSyncQuality) -> (label: String, color: String) {
    switch quality {
    case .excellent:    return ("EXCELLENT", ANSI.green)
    case .good:         return ("GOOD", ANSI.green)
    case .fair:         return ("FAIR", ANSI.yellow)
    case .poor:         return ("POOR", ANSI.yellow)
    case .unacceptable: return ("UNACCEPTABLE", ANSI.red)
    }
}

// MARK: - Dashboard renderer

/// Pad (or truncate) a string to exactly `width` characters, left-aligned.
private func pad(_ str: String, _ width: Int) -> String {
    if str.count >= width { return String(str.prefix(width)) }
    return str + String(repeating: " ", count: width - str.count)
}

/// Render a full-screen stats dashboard. Clears the terminal and redraws from scratch
/// each tick so the display never scrolls — it's a live-updating panel, not a log.
private func renderDashboard(stats: ClockSyncStats, serverName: String, refreshInterval: Double) {
    let (qualityLabel, qualityColor) = display(for: stats.quality)

    // Convert offset and RTT to both μs and ms for readability at different magnitudes.
    let offsetMs = Double(stats.offset) / 1_000.0
    let rttMs = Double(stats.rtt) / 1_000.0
    let rawRttMs = Double(stats.rawRtt) / 1_000.0

    // Drift is dimensionless (μs per μs); multiply by 1,000,000 for parts-per-million.
    let driftPPM = stats.drift * 1_000_000

    let errStr = String(format: "%.2f μs", stats.estimatedError)

    // Format specifiers for Int64 must be `%lld`, not `%d`. `String(format:)`
    // is C `printf` under the hood — `%d` expects a 32-bit `int` and silently
    // truncates `Int64` to its low 32 bits, which is particularly nasty for
    // offset values (easily in the billions of μs between two process-relative
    // monotonic clocks). The `%.3f` ms conversion uses `Double`, so it's always
    // correct — a disagreement between the μs and ms columns is the tell.
    let offsetStr = String(format: "%+lld μs  (%+.3f ms)", stats.offset, offsetMs)
    let rttStr = String(format: "%lld μs  (%.3f ms)", stats.rtt, rttMs)
    // Raw RTT presentation uses `rawRttWasRejected` — comparing `rawRtt == rtt`
    // confuses an accepted sample with a rejected one that happens to match.
    let rawRttStr = stats.rawRttWasRejected
        ? String(format: "%lld μs  (%.3f ms)  rejected", stats.rawRtt, rawRttMs)
        : "(same as accepted)"
    let driftStr = String(format: "%+.3f PPM", driftPPM)

    // The box border is 66 chars wide (between ╔ and ╗). Each content row
    // uses "║" + 20-char label + padded value + " ║". To fill the 66-char
    // interior: 20 (label) + valueWidth + 1 (trailing space) = 66.
    let valueWidth = 45

    print(ANSI.clearScreen, terminator: "")
    print("╔══════════════════════════════════════════════════════════════════╗")
    print("║              Sendspin Clock Sync Diagnostics                     ║")
    print("╠══════════════════════════════════════════════════════════════════╣")
    print("║  Server:           \(pad(serverName, valueWidth)) ║")
    print("║  Refresh interval: \(pad(String(format: "%.1fs", refreshInterval), valueWidth)) ║")
    print("╠══════════════════════════════════════════════════════════════════╣")
    print("║  Offset:           \(pad(offsetStr, valueWidth)) ║")
    print("║  RTT (accepted):   \(pad(rttStr, valueWidth)) ║")
    print("║  RTT (raw):        \(pad(rawRttStr, valueWidth)) ║")
    print("║  Drift:            \(pad(driftStr, valueWidth)) ║")
    print("║  Estimated error:  \(pad(errStr, valueWidth)) ║")
    print("║  Samples accepted: \(pad("\(stats.sampleCount)", valueWidth)) ║")
    print("╠══════════════════════════════════════════════════════════════════╣")
    print("║  Quality:          \(qualityColor)\(pad(qualityLabel, valueWidth))\(ANSI.reset) ║")
    print("╚══════════════════════════════════════════════════════════════════╝")
    print("  Press Ctrl-C to quit.")
}

// MARK: - Shared dashboard state

/// Holds state shared between the event-monitoring task and the polling loop.
///
/// Both consumers run on `@MainActor`, so MainActor isolation is sufficient —
/// no locks, no `nonisolated(unsafe)`, and no actor hop overhead. The SIGINT
/// handler runs on the main dispatch queue and uses `Task { @MainActor in … }`
/// to mutate state.
@MainActor
private final class DashboardState {
    var serverName: String
    var shouldQuit: Bool = false

    init(serverName: String) {
        self.serverName = serverName
    }
}

// MARK: - Command

@main
struct ClockSyncDiagnostics: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "ClockSyncDiagnostics",
        abstract: "Display a live clock synchronization diagnostics dashboard."
    )

    @Option(name: .long, help: "Server WebSocket URL (e.g. ws://192.168.1.5:8927).")
    var server: String?

    @Flag(name: .long, help: "Auto-discover a server via mDNS instead of --server.")
    var discover: Bool = false

    @Option(name: .long, help: "mDNS discovery timeout in seconds.")
    var timeout: Double = 5.0

    @Option(name: .long, help: "Dashboard refresh interval in seconds.")
    var interval: Double = 0.5

    @MainActor
    func run() async throws {
        let url = try await resolveServerURL(server: server, discover: discover, timeout: timeout)

        // Connect with metadata role only — it's the lightest role that still triggers
        // the clock sync protocol. The server/hello handshake initiates time exchanges
        // for all connected clients regardless of role.
        let client = try SendspinClient(
            clientId: "clock-sync-diagnostics",
            name: "Clock Sync Diagnostics",
            roles: [.metadataV1]
        )

        let state = DashboardState(serverName: url.host ?? url.absoluteString)

        signal(SIGINT, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            // The .main queue maps to the main thread, which is where @MainActor
            // runs, but the closure itself is non-isolated. Hop onto MainActor
            // to mutate state and disconnect.
            Task { @MainActor in
                state.shouldQuit = true
                await client.disconnect()
            }
        }
        sigintSource.resume()

        try await client.connect(to: url)

        // Background task: monitor connection events and print status changes.
        // Runs concurrently with the polling loop below.
        //
        // `client.events` is kept alive by SendspinClient across reconnects,
        // so we explicitly break on `.disconnected` rather than relying on
        // the stream finishing.
        let eventTask = Task { @MainActor in
            eventLoop: for await event in client.events {
                switch event {
                case .serverConnected(let info):
                    state.serverName = info.name
                case .disconnected(let reason):
                    switch reason {
                    case .connectionLost:
                        print("\n[Disconnected: connection lost]")
                    case .explicit:
                        break // SIGINT path — we already printed a message
                    }
                    state.shouldQuit = true
                    break eventLoop
                default:
                    break
                }
            }
        }

        // MARK: Polling loop
        // Poll currentClockSyncStats() on the requested interval and redraw the dashboard.
        // The loop exits when shouldQuit is set (SIGINT or connection loss).
        while !state.shouldQuit {
            if let stats = await client.currentClockSyncStats() {
                renderDashboard(stats: stats, serverName: state.serverName, refreshInterval: interval)
            } else {
                // Clock sync hasn't produced an accepted sample yet.
                // Show a waiting message while keeping the screen clear.
                print(ANSI.clearScreen, terminator: "")
                print("╔══════════════════════════════════════════════════════════════════╗")
                print("║              Sendspin Clock Sync Diagnostics                     ║")
                print("╠══════════════════════════════════════════════════════════════════╣")
                print("║  Waiting for clock sync...                                       ║")
                print("║  (server/time exchanges are in progress)                         ║")
                print("╚══════════════════════════════════════════════════════════════════╝")
                print("  Press Ctrl-C to quit.")
            }

            try? await Task.sleep(for: .seconds(interval))
        }

        eventTask.cancel()
        print("\nDone.")
    }
}
