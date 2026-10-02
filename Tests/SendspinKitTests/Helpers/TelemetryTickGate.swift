import Testing

actor TelemetryTickGate {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private(set) var sleepEntries = 0

    init() {
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    func sleep() async {
        sleepEntries += 1
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func tick() async throws {
        try #require(await waitUntil { await self.sleepEntries > 0 })
        let nextEntry = sleepEntries + 1
        continuation.yield(())
        try #require(await waitUntil { await self.sleepEntries >= nextEntry })
    }
}
