// ABOUTME: Real-time clock synchronization diagnostics for SendspinKit
// ABOUTME: Displays NTP-style sync stats including offset, RTT, drift, and quality

import Foundation
import SendspinKit
import ArgumentParser

@main
struct ClockSyncDiagnostics: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Display real-time clock synchronization diagnostics for Sendspin",
        discussion: """
            This tool connects to a Sendspin server as a player client and displays
            real-time clock synchronization statistics. It helps you understand how
            well your client is synchronized with the server's clock.

            Clock synchronization uses an NTP-style 4-way handshake to measure:
            • Offset: The time difference between server and client clocks
            • RTT: Round-trip time for sync messages (network latency)
            • Drift: Clock frequency difference (how fast clocks diverge)

            Sub-millisecond synchronization is critical for multi-room audio because
            all players must render the exact same audio frame at the exact same
            microsecond to avoid echo/phase issues.
            """
    )

    @Option(name: .shortAndLong, help: "Server URL (e.g., ws://192.168.1.100:8080)")
    var server: String?

    @Flag(name: .long, help: "Discover servers instead of connecting")
    var discover: Bool = false

    @Option(name: .shortAndLong, help: "Discovery timeout in seconds")
    var timeout: Int = 3

    @Option(name: .shortAndLong, help: "Display refresh interval in seconds")
    var interval: Double = 1.0

    mutating func run() async throws {
        // Validate parameters
        if !discover && server == nil {
            throw ValidationError("Must specify either --server or --discover")
        }

        if discover && server != nil {
            throw ValidationError("Cannot specify both --server and --discover")
        }

        guard interval > 0.1 && interval <= 60 else {
            throw ValidationError("Interval must be between 0.1 and 60 seconds")
        }

        // Discovery mode
        if discover {
            try await runDiscovery()
            return
        }

        // Connection mode
        guard let serverUrl = server else {
            throw ValidationError("Server URL required")
        }

        guard let url = URL(string: serverUrl) else {
            throw ValidationError("Invalid server URL: \(serverUrl)")
        }

        try await runDiagnostics(url: url)
    }

    func runDiscovery() async throws {
        print("🔍 Discovering Sendspin servers...")
        print("")

        let timeoutDuration = Duration.seconds(timeout)
        let servers = await SendspinClient.discoverServers(timeout: timeoutDuration)

        if servers.isEmpty {
            print("❌ No servers found")
            print("")
            print("💡 Tips:")
            print("   • Make sure a Sendspin server is running")
            print("   • Check that the server is on the same network")
            print("   • Try increasing timeout with --timeout")
            throw ExitCode.failure
        }

        print("✅ Found \(servers.count) server\(servers.count == 1 ? "" : "s"):")
        print("")

        for (index, server) in servers.enumerated() {
            print("[\(index + 1)] \(server.name)")
            print("    URL: \(server.url)")
            print("    Use: --server \(server.url)")
            print("")
        }
    }

    @MainActor
    func runDiagnostics(url: URL) async throws {
        // Create client as player (needed to receive sync messages)
        let client = SendspinClient(
            clientId: "clock-sync-diagnostics-\(UUID().uuidString)",
            name: "ClockSync Diagnostics",
            roles: [.playerV1],
            playerConfig: PlayerConfiguration(
                bufferCapacity: 2048,
                supportedFormats: [
                    AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16)
                ]
            )
        )

        print("🔌 Connecting to \(url)...")
        print("")

        do {
            try await client.connect(to: url)
            print("✅ Connected!")
            print("")
        } catch {
            print("❌ Connection failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        // Wait a moment for initial sync to complete
        try? await Task.sleep(for: .seconds(1))

        // Clear screen and position cursor
        print("\u{001B}[2J\u{001B}[H", terminator: "")

        // Main display loop
        var iteration = 0
        while !Task.isCancelled {
            // Get current stats
            let stats = await client.getClockStats()

            // Move cursor to top-left
            print("\u{001B}[H", terminator: "")

            displayStats(stats: stats, iteration: iteration)

            iteration += 1
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    func displayStats(stats: ClockStats?, iteration: Int) {
        let timestamp = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        print("╔════════════════════════════════════════════════════════════════╗")
        print("║          Sendspin Clock Synchronization Diagnostics           ║")
        print("╠════════════════════════════════════════════════════════════════╣")
        print("║ Time: \(formatter.string(from: timestamp))                    Update #\(String(format: "%4d", iteration))        ║")
        print("╚════════════════════════════════════════════════════════════════╝")
        print("")

        guard let stats = stats else {
            print("⚠️  Clock sync not yet initialized")
            print("")
            print("   Waiting for server connection...")
            print("")
            return
        }

        // Convert to milliseconds for display
        let offsetMs = Double(stats.offset) / 1000.0
        let rttMs = Double(stats.rtt) / 1000.0

        // Quality indicator
        let qualityEmoji: String
        let qualityText: String
        let qualityColor: String

        switch stats.quality {
        case .good:
            qualityEmoji = "🟢"
            qualityText = "EXCELLENT"
            qualityColor = "\u{001B}[32m" // Green
        case .degraded:
            qualityEmoji = "🟡"
            qualityText = "DEGRADED"
            qualityColor = "\u{001B}[33m" // Yellow
        case .lost:
            qualityEmoji = "🔴"
            qualityText = "LOST"
            qualityColor = "\u{001B}[31m" // Red
        }
        let resetColor = "\u{001B}[0m"

        // Display metrics
        print("📊 Synchronization Metrics")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("")
        print("  Clock Offset:     \(String(format: "%+8.3f", offsetMs)) ms")
        print("  Round-Trip Time:  \(String(format: "%8.3f", rttMs)) ms")
        print("  Drift Rate:       \(String(format: "%+.9f", stats.drift)) μs/μs")
        print("  Sample Count:     \(stats.sampleCount)")
        print("  Sync Quality:     \(qualityColor)\(qualityEmoji) \(qualityText)\(resetColor)")
        print("")

        // Educational explanations
        print("📖 What do these numbers mean?")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("")
        print("  Clock Offset")
        print("  The time difference between server and client clocks.")
        if abs(offsetMs) < 1.0 {
            print("  \(qualityColor)✓ Excellent: < 1ms offset is ideal for audio sync\(resetColor)")
        } else if abs(offsetMs) < 5.0 {
            print("  \(qualityColor)○ Good: < 5ms offset is acceptable\(resetColor)")
        } else {
            print("  \(qualityColor)✗ High: > 5ms offset may cause sync issues\(resetColor)")
        }
        print("")

        print("  Round-Trip Time (RTT)")
        print("  Network latency between client and server.")
        if rttMs < 10.0 {
            print("  \(qualityColor)✓ Excellent: < 10ms RTT enables precise sync\(resetColor)")
        } else if rttMs < 50.0 {
            print("  \(qualityColor)○ Good: < 50ms RTT is workable\(resetColor)")
        } else {
            print("  \(qualityColor)✗ High: > 50ms RTT degrades sync quality\(resetColor)")
        }
        print("")

        print("  Drift Rate")
        print("  Clock frequency difference (how fast clocks diverge).")
        if stats.sampleCount < 2 {
            print("  ○ Not yet calculated (need 2+ samples)")
        } else {
            let driftPPM = abs(stats.drift * 1_000_000)
            print("  \(String(format: "≈ %.1f", driftPPM)) PPM (parts per million)")
            if driftPPM < 50 {
                print("  \(qualityColor)✓ Excellent: Low drift, stable clocks\(resetColor)")
            } else {
                print("  \(qualityColor)○ Moderate: Kalman filter compensating\(resetColor)")
            }
        }
        print("")

        print("💡 Why does this matter?")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("")
        print("  Multi-room audio requires microsecond-level synchronization.")
        print("  All players must render the same audio sample at the same")
        print("  instant. Even 1-2ms offset causes audible echo/phase issues.")
        print("")
        print("  NTP-style 4-way handshake:")
        print("  1. Client sends timestamp t1")
        print("  2. Server receives at t2, replies at t3")
        print("  3. Client receives at t4")
        print("  4. Calculate: RTT = (t4-t1) - (t3-t2)")
        print("                Offset = ((t2-t1) + (t3-t4)) / 2")
        print("")
        print("  Kalman filter tracks both offset AND drift to handle")
        print("  clock frequency differences between devices.")
        print("")

        // Clear to end of screen to handle terminal resize
        print("\u{001B}[J", terminator: "")
    }
}
