import Foundation
@testable import SendspinKit
import Testing

struct ArtworkTransferTests {
    private func announce(
        channel: Int = 0,
        timestamp: Int64 = 10,
        totalSize: UInt32 = 3,
        flags: UInt8 = ArtworkWireMessage.announceFlag
    ) -> Data {
        var bytes = Data([BinaryMessageType.artworkChannel0.rawValue + UInt8(channel), flags])
        var timestamp = timestamp.bigEndian
        var totalSize = totalSize.bigEndian
        bytes.append(Data(bytes: &timestamp, count: MemoryLayout<Int64>.size))
        bytes.append(Data(bytes: &totalSize, count: MemoryLayout<UInt32>.size))
        return bytes
    }

    private func part(channel: Int = 0, data: Data = Data([1, 2, 3]), flags: UInt8 = 0) -> Data {
        Data([BinaryMessageType.artworkChannel0.rawValue + UInt8(channel), flags]) + data
    }

    private func cancel(channel: Int = 0, suffix: Data = Data()) -> Data {
        Data([BinaryMessageType.artworkChannel0.rawValue + UInt8(channel), ArtworkWireMessage.cancelFlag]) + suffix
    }

    private func activeArtworkState() throws -> ArtworkStateObject {
        try ArtworkStateObject(channels: [
            ArtworkStateChannel(source: .album, format: .jpeg, width: 64, height: 64),
            ArtworkStateChannel(source: .artist, format: .png, width: 64, height: 64)
        ])
    }

    private func artworkStart(source: ArtworkSource = .album) -> StreamStartMessage {
        StreamStartMessage(payload: StreamStartPayload(
            player: nil,
            artwork: StreamStartArtwork(channels: [
                StreamArtworkChannelConfig(source: source, format: .jpeg, width: 64, height: 64),
                StreamArtworkChannelConfig(source: .artist, format: .png, width: 64, height: 64)
            ]),
            visualizer: nil
        ))
    }

    private func readyArtworkConnection(
        sink: AsyncStream<ArtworkData>.Continuation = AsyncStream<ArtworkData>.makeStream().1,
        scheduleNow: @escaping @Sendable () -> Int64 = { 1_000_000 },
        scheduleSleep: @escaping @Sendable (Duration) async throws -> Void = { _ in },
        observer: (@Sendable (ArtworkData) -> Void)? = nil
    ) async throws -> EstablishedConnectionFixture {
        let fixture = try await makeEstablishedConnection(
            clock: MockClockSynchronizer(offset: 0, drift: 0),
            activeRoles: [.artworkV1],
            artworkSink: sink,
            roles: [.artworkV1],
            initialArtworkState: activeArtworkState(),
            scheduleNow: scheduleNow,
            scheduleSleep: scheduleSleep,
            artworkObserver: observer
        )
        try await fixture.connection.sendClientState()
        await fixture.connection.handleStreamStart(artworkStart())
        return fixture
    }

    private func assertMalformed(_ bytes: Data, source: String = #function) async throws {
        let fixture = try await makeEstablishedConnection(
            clock: MockClockSynchronizer(offset: 0, drift: 0),
            activeRoles: [.artworkV1],
            roles: [.artworkV1]
        )
        await fixture.connection.route(binary: bytes)
        #expect(await fixture.transport.disconnectCalled, "Malformed artwork fixture must close the connection: \(source)")
        await fixture.connection.shutdown()
    }

    @Test("artwork wire shapes are hand-derived and reassemble with announce timestamp")
    func happyPathReassemblesArtwork() async throws {
        let (stream, continuation) = AsyncStream<ArtworkData>.makeStream()
        let fixture = try await readyArtworkConnection(sink: continuation)
        try await fixture.connection.handleArtworkBinary(announce(timestamp: 123, totalSize: 5))
        try await fixture.connection.handleArtworkBinary(part(data: Data([0xA, 0xB])))
        try await fixture.connection.handleArtworkBinary(part(data: Data([0xC, 0xD, 0xE])))

        let result = await outcomeOfUnstructuredOperation(timeout: .seconds(2)) {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        let artwork = try #require(try? result?.get())
        #expect(artwork.channel == 0)
        #expect(artwork.data == Data([0xA, 0xB, 0xC, 0xD, 0xE]))
        #expect(artwork.localDisplayTime == 123)
        await fixture.connection.shutdown()
    }

    @Test("malformed artwork frames all close the connection")
    func malformedFramesCloseConnection() async throws {
        try await assertMalformed(Data([BinaryMessageType.artworkChannel0.rawValue]))
        try await assertMalformed(Data([BinaryMessageType.artworkChannel0.rawValue, 0]) + Data(
            repeating: 0,
            count: ArtworkWireMessage.maxMessageSize
        ))
        try await assertMalformed(Data([BinaryMessageType.artworkChannel0.rawValue, ArtworkWireMessage.announceFlag]))
        try await assertMalformed(announce() + Data([0]))
        try await assertMalformed(cancel() + Data([0]))
        try await assertMalformed(Data([BinaryMessageType.artworkChannel0.rawValue, ArtworkWireMessage.reservedMask]))
        try await assertMalformed(
            Data([BinaryMessageType.artworkChannel0.rawValue, ArtworkWireMessage.announceFlag | ArtworkWireMessage.cancelFlag]) +
                Data(
                    repeating: 0,
                    count: 12
                )
        )

        let inFlight = try await readyArtworkConnection()
        try await inFlight.connection.handleArtworkBinary(announce(totalSize: 3))
        await inFlight.connection.route(binary: announce(channel: 1, totalSize: 3))
        #expect(await inFlight.transport.disconnectCalled, "A second announce during an in-flight transfer must close the connection")
        await inFlight.connection.shutdown()

        try await assertMalformed(part())
        let wrongChannel = try await readyArtworkConnection()
        try await wrongChannel.connection.handleArtworkBinary(announce(totalSize: 3))
        await wrongChannel.connection.route(binary: part(channel: 1))
        #expect(await wrongChannel.transport.disconnectCalled, "A part on another channel must close the connection")
        await wrongChannel.connection.shutdown()

        let pastTotal = try await readyArtworkConnection()
        try await pastTotal.connection.handleArtworkBinary(announce(totalSize: 2))
        await pastTotal.connection.route(binary: part(data: Data([1, 2, 3])))
        #expect(await pastTotal.transport.disconnectCalled, "A part extending past total_size must close the connection")
        await pastTotal.connection.shutdown()
    }

    @Test("reject-but-track advances bytes without delivery and permits next transfer")
    func rejectedTransferIsTrackedNotDelivered() async throws {
        let (stream, continuation) = AsyncStream<ArtworkData>.makeStream()
        let fixture = try await makeEstablishedConnection(
            clock: MockClockSynchronizer(offset: 0, drift: 0), activeRoles: [.artworkV1], artworkSink: continuation, roles: [.artworkV1],
            initialArtworkState: activeArtworkState()
        )
        await fixture.connection.handleStreamStart(artworkStart())
        try await fixture.connection.handleArtworkBinary(announce(totalSize: 2))
        try await fixture.connection.handleArtworkBinary(part(data: Data([1, 2])))
        #expect(await !(fixture.transport.disconnectCalled), "A gated transfer remains a valid sequence")
        let noDelivery = await outcomeOfUnstructuredOperation(timeout: .milliseconds(50)) {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        #expect((try? noDelivery?.get()) == nil, "Rejected completion must not be publicly delivered")

        try await fixture.connection.handleArtworkBinary(announce(timestamp: 20, totalSize: 1))
        try await fixture.connection.handleArtworkBinary(part(data: Data([3])))
        #expect(await !(fixture.transport.disconnectCalled), "A later transfer remains usable after rejected completion")
        await fixture.connection.shutdown()
    }

    @Test("an empty artwork announce clears immediately and can be scheduled")
    func emptyArtworkAnnounceClearsImmediatelyAndSchedulesFutureClear() async throws {
        let (stream, continuation) = AsyncStream<ArtworkData>.makeStream()
        let fixture = try await readyArtworkConnection(sink: continuation)
        try await fixture.connection.handleArtworkBinary(announce(timestamp: 1, totalSize: 0))
        let immediate = await outcomeOfUnstructuredOperation(timeout: .seconds(2)) {
            var iterator = stream.makeAsyncIterator(); return await iterator.next()
        }
        let clear = try #require(try? immediate?.get())
        #expect(clear.data.isEmpty)
        #expect(clear.clearsArtwork)
        await fixture.connection.shutdown()

        let schedule = ManualTestClock(now: 0)
        let sleeper = ManualTestSleeper()
        let (futureStream, futureContinuation) = AsyncStream<ArtworkData>.makeStream()
        let future = try await readyArtworkConnection(
            sink: futureContinuation,
            scheduleNow: { schedule.now },
            scheduleSleep: { try await sleeper.sleep($0) }
        )
        try await future.connection.handleArtworkBinary(announce(timestamp: 100, totalSize: 0))
        let futureConnection = future.connection
        #expect(await waitUntil(timeout: .seconds(2)) { await futureConnection.artworkPending.count == 1 })
        schedule.now = 100
        await Task.yield()
        await sleeper.fireAll()
        let futureResult = await outcomeOfUnstructuredOperation(timeout: .seconds(2)) {
            var iterator = futureStream.makeAsyncIterator(); return await iterator.next()
        }
        #expect((try? futureResult?.get())?.clearsArtwork == true)
        await future.connection.shutdown()
    }

    @Test("cancel is channel-scoped and preserves current artwork")
    func cancelPreservesCurrentAndOtherChannelTransfer() async throws {
        let (stream, continuation) = AsyncStream<ArtworkData>.makeStream()
        let fixture = try await readyArtworkConnection(sink: continuation)
        try await fixture.connection.handleArtworkBinary(announce(timestamp: 1, totalSize: 1))
        try await fixture.connection.handleArtworkBinary(part(data: Data([9])))
        _ = await outcomeOfUnstructuredOperation(timeout: .seconds(2)) { var i = stream.makeAsyncIterator(); return await i.next() }
        try await fixture.connection.handleArtworkBinary(announce(timestamp: 2, totalSize: 2))
        try await fixture.connection.handleArtworkBinary(cancel(channel: 1))
        #expect(await !(fixture.transport.disconnectCalled))
        try await fixture.connection.handleArtworkBinary(part(data: Data([8, 9])))
        let next = await outcomeOfUnstructuredOperation(timeout: .seconds(2)) { var i = stream.makeAsyncIterator(); return await i.next() }
        let artwork = try #require(try? next?.get())
        #expect(artwork.channel == 0)
        #expect(artwork.data == Data([8, 9]))
        await fixture.connection.shutdown()
    }

    @Test("announce replaces pending image and stream boundaries discard only pending artwork")
    func pendingReplacementAndStreamCleanup() async throws {
        let schedule = ManualTestClock(now: 0)
        let sleeper = ManualTestSleeper()
        let (stream, continuation) = AsyncStream<ArtworkData>.makeStream()
        let fixture = try await readyArtworkConnection(
            sink: continuation,
            scheduleNow: { schedule.now },
            scheduleSleep: { duration in try await sleeper.sleep(duration) }
        )
        try await fixture.connection.handleArtworkBinary(announce(timestamp: 100, totalSize: 1))
        try await fixture.connection.handleArtworkBinary(part(data: Data([1])))
        try await fixture.connection.handleArtworkBinary(announce(timestamp: 200, totalSize: 1))
        try await fixture.connection.handleArtworkBinary(part(data: Data([2])))
        try await fixture.connection.handleArtworkBinary(announce(timestamp: 150, totalSize: 1))
        try await fixture.connection.handleArtworkBinary(part(data: Data([4])))
        schedule.now = 200
        await Task.yield()
        await sleeper.fireAll()
        let replacement = await outcomeOfUnstructuredOperation(timeout: .seconds(2)) { var i = stream.makeAsyncIterator(); return await i.next() }
        #expect((try? replacement?.get())?.data == Data([4]))

        try await fixture.connection.handleArtworkBinary(announce(timestamp: 300, totalSize: 1))
        try await fixture.connection.handleArtworkBinary(part(data: Data([3])))
        await fixture.connection.handleStreamEnd(StreamEndMessage(payload: StreamEndPayload(roles: [StreamRole.artwork.rawValue])))
        schedule.now = 300
        await Task.yield()
        await sleeper.fireAll()
        let discarded = await outcomeOfUnstructuredOperation(timeout: .milliseconds(50)) { var i = stream.makeAsyncIterator(); return await i.next() }
        #expect((try? discarded?.get()) == nil, "stream/end discards pending artwork")
        await fixture.connection.shutdown()
    }

    @Test("configuration-changing stream start discards affected channel pending image")
    func changingArtworkConfigurationDiscardsPending() async throws {
        let schedule = ManualTestClock(now: 0)
        let sleeper = ManualTestSleeper()
        let (stream, continuation) = AsyncStream<ArtworkData>.makeStream()
        let fixture = try await readyArtworkConnection(
            sink: continuation,
            scheduleNow: { schedule.now },
            scheduleSleep: { try await sleeper.sleep($0) }
        )
        try await fixture.connection.handleArtworkBinary(announce(timestamp: 100, totalSize: 1))
        try await fixture.connection.handleArtworkBinary(part(data: Data([1])))
        await fixture.connection.handleStreamStart(artworkStart(source: .artist))
        schedule.now = 100
        await sleeper.fireAll()
        let discarded = await outcomeOfUnstructuredOperation(timeout: .milliseconds(50)) { var i = stream.makeAsyncIterator(); return await i.next() }
        #expect((try? discarded?.get()) == nil)
        await fixture.connection.shutdown()
    }
}

private final class ManualTestClock: @unchecked Sendable {
    var now: Int64
    init(now: Int64) {
        self.now = now
    }
}

private actor ManualTestSleeper {
    private var continuations: [CheckedContinuation<Void, Error>] = []

    func sleep(_: Duration) async throws {
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func fireAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
