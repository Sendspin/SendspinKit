import Foundation
@testable import SendspinKit
import Testing

@Suite(.serialized)
struct ScheduledPresentationTests {
    @Test("future metadata is held and applied at due time without convergence gating")
    func futureMetadataUsesCurrentBestEstimate() async throws {
        let clock = ScheduledTestClock()
        let schedule = ManualTestClock(now: 100)
        let sleeper = ScheduledTestSleeper()
        let fixture = try await makeEstablishedConnection(
            clock: clock,
            scheduleNow: { schedule.now },
            scheduleSleep: { duration in try await sleeper.sleep(duration) }
        )
        let metadata = ServerMetadataState(timestamp: 200, title: .value("future"))
        await fixture.connection.handleServerState(ServerStateMessage(payload: ServerStatePayload(metadata: metadata)))
        #expect(
            await waitUntil(timeout: .seconds(2)) { await sleeper.waitingCount == 1 },
            "The future metadata update must park in the injected sleeper"
        )
        #expect(await fixture.connection.metadataPending != nil)
        #expect(await fixture.connection.currentMetadata == nil)

        schedule.now = 200
        await sleeper.fireNext()
        let connection = fixture.connection
        #expect(
            await waitUntil(timeout: .seconds(2)) { await connection.currentMetadata?.title == "future" },
            "Due metadata must apply using the current best clock estimate"
        )
        await fixture.connection.shutdown()
    }

    @Test("an older future timestamp unconditionally replaces a newer pending update")
    func futureMetadataReplacementIsUnconditional() async throws {
        let schedule = ManualTestClock(now: 0)
        let fixture = try await makeEstablishedConnection(clock: ScheduledTestClock(), scheduleNow: { schedule.now }, scheduleSleep: { _ in })
        await fixture.connection.handleServerState(ServerStateMessage(payload: ServerStatePayload(metadata: ServerMetadataState(
            timestamp: 200,
            title: .value("newer")
        ))))
        await fixture.connection.handleServerState(ServerStateMessage(payload: ServerStatePayload(metadata: ServerMetadataState(
            timestamp: 100,
            title: .value("older")
        ))))
        #expect(await fixture.connection.metadataPending?.metadata.title == "older")
        _ = schedule
        await fixture.connection.shutdown()
    }

    @Test("past and present metadata applies immediately and discards pending")
    func presentMetadataDiscardsPending() async throws {
        let schedule = ManualTestClock(now: 100)
        let fixture = try await makeEstablishedConnection(clock: ScheduledTestClock(), scheduleNow: { schedule.now }, scheduleSleep: { _ in })
        await fixture.connection.handleServerState(ServerStateMessage(payload: ServerStatePayload(metadata: ServerMetadataState(
            timestamp: 200,
            title: .value("pending")
        ))))
        await fixture.connection.handleServerState(ServerStateMessage(payload: ServerStatePayload(metadata: ServerMetadataState(
            timestamp: 100,
            title: .value("now")
        ))))
        let connection = fixture.connection
        #expect(await waitUntil(timeout: .seconds(2)) { await connection.metadataPending == nil })
        #expect(await connection.currentMetadata?.title == "now")
        await fixture.connection.shutdown()
    }

    @Test("null metadata and color role objects clear state and pending values")
    func nullRolesClearStateAndPending() async throws {
        let schedule = ManualTestClock(now: 0)
        let fixture = try await makeEstablishedConnection(clock: ScheduledTestClock(), scheduleNow: { schedule.now }, scheduleSleep: { _ in })
        let color = ServerColorState(timestamp: 100, primary: .value(SendspinColor(red: 1, green: 2, blue: 3)))
        await fixture.connection.handleServerState(ServerStateMessage(payload: ServerStatePayload(
            metadata: ServerMetadataState(timestamp: 100, title: .value("old")),
            color: color
        )))
        await fixture.connection.handleServerState(ServerStateMessage(payload: ServerStatePayload(
            metadataDelta: .null,
            colorDelta: .null
        )))
        for _ in 0 ..< 4 {
            await Task.yield()
        }
        #expect(await fixture.connection.currentMetadata == nil)
        #expect(await fixture.connection.metadataPending == nil)
        #expect(await fixture.connection.currentColorState == nil)
        #expect(await fixture.connection.colorPending == nil)
        let events = await connectionEvents(fixture.connection)
        #expect(events.contains {
            if case .metadataCleared = $0 {
                return true
            }; return false
        })
        #expect(events.contains {
            if case .colorStateCleared = $0 {
                return true
            }; return false
        })
        await fixture.connection.shutdown()
    }

    @Test("null clears established metadata and color immediately")
    func nullClearsEstablishedMetadataAndColor() async throws {
        let fixture = try await makeEstablishedConnection(clock: ScheduledTestClock(), scheduleNow: { 100 })
        await fixture.connection.handleServerState(ServerStateMessage(payload: ServerStatePayload(
            metadata: ServerMetadataState(timestamp: 50, title: .value("current")),
            color: ServerColorState(timestamp: 50, primary: .value(SendspinColor(red: 1, green: 2, blue: 3)))
        )))
        #expect(await fixture.connection.currentMetadata?.title == "current")
        #expect(await fixture.connection.currentColorState?.primary?.red == 1)
        await fixture.connection.handleServerState(ServerStateMessage(payload: ServerStatePayload(
            metadataDelta: .null, colorDelta: .null
        )))
        #expect(await fixture.connection.currentMetadata == nil)
        #expect(await fixture.connection.currentColorState == nil)
        await fixture.connection.shutdown()
    }

    @Test("metadata and color pending survive stream/end while artwork pending is cleared")
    func streamEndClearsOnlyArtworkPending() async throws {
        let schedule = ManualTestClock(now: 0)
        let sleeper = ScheduledTestSleeper()
        let fixture = try await makeEstablishedConnection(
            clock: ScheduledTestClock(),
            activeRoles: [.artworkV1], roles: [.artworkV1], initialArtworkState: ArtworkStateObject(channels: [ArtworkStateChannel(
                source: .album,
                format: .jpeg,
                width: 8,
                height: 8
            )]),
            scheduleNow: { schedule.now }, scheduleSleep: { duration in try await sleeper.sleep(duration) }
        )
        let metadata = ServerMetadataState(timestamp: 100, title: .value("metadata"))
        let color = ServerColorState(timestamp: 100, primary: .value(SendspinColor(red: 1, green: 1, blue: 1)))
        await fixture.connection.handleServerState(ServerStateMessage(payload: ServerStatePayload(metadata: metadata, color: color)))
        try await fixture.connection.sendClientState()
        let streamStart = StreamStartMessage(payload: StreamStartPayload(
            player: nil,
            artwork: StreamStartArtwork(channels: [StreamArtworkChannelConfig(source: .album, format: .jpeg, width: 8, height: 8)]),
            visualizer: nil
        ))
        await fixture.connection.handleStreamStart(streamStart)
        try await fixture.connection.handleArtworkBinary(announce(timestamp: 100, totalSize: 1))
        try await fixture.connection.handleArtworkBinary(part(data: Data([8])))
        await fixture.connection.handleStreamEnd(StreamEndMessage())
        #expect(await fixture.connection.metadataPending != nil)
        #expect(await fixture.connection.colorPending != nil)
        #expect(await fixture.connection.artworkPending.isEmpty)
        #expect(await waitUntil(timeout: .seconds(2)) { await sleeper.waitingCount >= 1 })
        schedule.now = 100
        await sleeper.fireNext()
        #expect(await waitUntil(timeout: .seconds(2)) { await sleeper.waitingCount >= 1 })
        await sleeper.fireNext()
        let connection = fixture.connection
        #expect(await waitUntil(timeout: .seconds(2)) { await connection.currentMetadata?.title == "metadata" })
        #expect(await waitUntil(timeout: .seconds(2)) { await connection.currentColorState?.primary?.red == 1 })
        await fixture.connection.shutdown()
    }

    @Test("future color replacement applies only the due pending snapshot")
    func futureColorReplacementIsUnconditional() async throws {
        let schedule = ManualTestClock(now: 0)
        let sleeper = ScheduledTestSleeper()
        let fixture = try await makeEstablishedConnection(
            clock: ScheduledTestClock(), scheduleNow: { schedule.now },
            scheduleSleep: { duration in try await sleeper.sleep(duration) }
        )
        await fixture.connection.handleServerState(ServerStateMessage(payload: ServerStatePayload(
            color: ServerColorState(timestamp: 200, primary: .value(SendspinColor(red: 2, green: 2, blue: 2)))
        )))
        #expect(await waitUntil(timeout: .seconds(2)) { await sleeper.waitingCount == 1 })
        await fixture.connection.handleServerState(ServerStateMessage(payload: ServerStatePayload(
            color: ServerColorState(timestamp: 100, primary: .value(SendspinColor(red: 1, green: 1, blue: 1)))
        )))
        #expect(await fixture.connection.colorPending?.color.primary?.red == 1)
        schedule.now = 100
        await sleeper.fireNext()
        let connection = fixture.connection
        #expect(await waitUntil(timeout: .seconds(2)) { await connection.currentColorState?.primary?.red == 1 })
        await fixture.connection.shutdown()
    }

    @Test("a replaced sleeper firing late cannot apply the stale pending update")
    func staleSleeperCannotApplyReplacement() async throws {
        let schedule = ManualTestClock(now: 0)
        let sleeper = ScheduledTestSleeper()
        let fixture = try await makeEstablishedConnection(
            clock: ScheduledTestClock(),
            scheduleNow: { schedule.now },
            scheduleSleep: { duration in try await sleeper.sleep(duration) }
        )
        await fixture.connection.handleServerState(ServerStateMessage(payload: ServerStatePayload(metadata: ServerMetadataState(
            timestamp: 100,
            title: .value("stale")
        ))))
        #expect(
            await waitUntil(timeout: .seconds(2)) { await sleeper.waitingCount == 1 },
            "The first scheduled update must park in the injected sleeper"
        )
        await fixture.connection.handleServerState(ServerStateMessage(payload: ServerStatePayload(metadata: ServerMetadataState(
            timestamp: 200,
            title: .value("current")
        ))))
        #expect(
            await waitUntil(timeout: .seconds(2)) { await sleeper.waitingCount == 2 },
            "The replacement scheduled update must install its own sleeper"
        )

        schedule.now = 100
        // The first sleeper is intentionally fired after replacement; cancellation is
        // not relied on, so the pending due-time check is the isolation boundary.
        await sleeper.fireNext()
        await Task.yield()
        let connection = fixture.connection
        #expect(await connection.currentMetadata == nil, "A late replaced sleeper must re-check the current pending due time")

        schedule.now = 200
        await sleeper.fireNext()
        #expect(await waitUntil(timeout: .seconds(2)) { await connection.currentMetadata?.title == "current" })
        await fixture.connection.shutdown()
    }

    private func announce(channel: Int = 0, timestamp: Int64, totalSize: UInt32) -> Data {
        var bytes = Data([BinaryMessageType.artworkChannel0.rawValue + UInt8(channel), ArtworkWireMessage.announceFlag])
        var timestamp = timestamp.bigEndian
        var totalSize = totalSize.bigEndian
        bytes.append(Data(bytes: &timestamp, count: MemoryLayout<Int64>.size))
        bytes.append(Data(bytes: &totalSize, count: MemoryLayout<UInt32>.size))
        return bytes
    }

    private func part(data: Data) -> Data {
        Data([BinaryMessageType.artworkChannel0.rawValue, 0]) + data
    }
}

private final class ManualTestClock: @unchecked Sendable {
    var now: Int64
    init(now: Int64) {
        self.now = now
    }
}

private actor ScheduledTestClock: ClockSyncProtocol {
    var hasSynced: Bool {
        false
    }

    func processServerTime(clientTransmitted _: Int64, serverReceived _: Int64, serverTransmitted _: Int64, clientReceived _: Int64) {}
    func serverTimeToLocal(_ serverTime: Int64) -> Int64 {
        serverTime
    }

    func localTimeToServer(_ localTime: Int64) -> Int64 {
        localTime
    }

    func snapshot() -> TimeFilterSnapshot? {
        nil
    }

    func diagnosticSnapshot() -> ClockSynchronizer.DiagnosticSnapshot? {
        nil
    }
}

private actor ScheduledTestSleeper {
    private var continuations: [CheckedContinuation<Void, Error>] = []

    var waitingCount: Int {
        continuations.count
    }

    func sleep(_: Duration) async throws {
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func fireNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private func connectionEvents(_ connection: SendspinConnection) async -> [ConnectionEvent] {
    let result = await outcomeOfUnstructuredOperation(timeout: .seconds(2)) {
        var iterator = connection.events.makeAsyncIterator()
        var events: [ConnectionEvent] = []
        while !events.contains(where: {
            if case .metadataCleared = $0 {
                return true
            }; return false
        })
            || !events.contains(where: {
                if case .colorStateCleared = $0 {
                    return true
                }; return false
            }),
            let event = await iterator.next() {
            events.append(event)
        }
        return events
    }
    return (try? result?.get()) ?? []
}
