import Foundation
@testable import SendspinKit
import Testing

// MARK: - Test Helpers

/// Thread-safe atomic integer wrapper for test counters.
final class AtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int

    init(_ value: Int) {
        _value = value
    }

    var value: Int {
        lock.withLock { _value }
    }

    func increment() {
        lock.withLock { _value += 1 }
    }
}

/// Thread-safe atomic list for collecting values across tasks.
final class AtomicList<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [T] = []

    var count: Int {
        lock.withLock { _items.count }
    }

    var all: [T] {
        lock.withLock { _items }
    }

    func append(_ item: T) {
        lock.withLock { _items.append(item) }
    }
}

struct DataPlaneSinkTests {
    // MARK: - Depth accuracy

    @Test
    func depthAccuracy_enqueueAndDecrement() throws {
        let sink = DataPlaneSink()
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let command = DataPlaneCommand.streamStart(format, codecHeader: nil)

        // Enqueue 5 commands
        for _ in 0 ..< 5 {
            sink.enqueue(command)
        }
        #expect(sink.depth == 5)

        // Decrement 3
        for _ in 0 ..< 3 {
            sink.decrementDepth()
        }
        #expect(sink.depth == 2)

        // Decrement 2 more to reach 0
        for _ in 0 ..< 2 {
            sink.decrementDepth()
        }
        #expect(sink.depth == 0)
    }

    @Test
    func depthAccuracy_enqueueAfterFinish() throws {
        let sink = DataPlaneSink()
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let command = DataPlaneCommand.streamStart(format, codecHeader: nil)

        // Enqueue 3
        for _ in 0 ..< 3 {
            sink.enqueue(command)
        }
        #expect(sink.depth == 3)

        // Finish the sink
        sink.finish()

        // Try to enqueue more — should be no-op
        sink.enqueue(command)
        #expect(sink.depth == 3)

        // Depth should still be decrmentable
        sink.decrementDepth()
        #expect(sink.depth == 2)
    }

    // MARK: - Rate-limited watermark

    @Test
    func rateLimitedWatermark_oneWarningPerExcursion() throws {
        let warningCount = AtomicInt(0)
        let sink = DataPlaneSink { _ in
            warningCount.increment()
        }

        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let command = DataPlaneCommand.streamStart(format, codecHeader: nil)

        // First excursion: enqueue to cross watermark
        for _ in 0 ..< (DataPlaneSink.highWatermark + 1) {
            sink.enqueue(command)
        }
        #expect(warningCount.value == 1)

        // Decrement back below watermark
        for _ in 0 ..< (DataPlaneSink.highWatermark + 1) {
            sink.decrementDepth()
        }
        #expect(sink.depth == 0)

        // Second excursion: should emit another warning
        for _ in 0 ..< (DataPlaneSink.highWatermark + 1) {
            sink.enqueue(command)
        }
        #expect(warningCount.value == 2)

        // Third excursion after decrementing back
        for _ in 0 ..< (DataPlaneSink.highWatermark + 1) {
            sink.decrementDepth()
        }

        for _ in 0 ..< (DataPlaneSink.highWatermark + 1) {
            sink.enqueue(command)
        }
        #expect(warningCount.value == 3)
    }

    @Test
    func rateLimitedWatermark_noWarningWhileAboveWatermark() throws {
        let warningCount = AtomicInt(0)
        let sink = DataPlaneSink { _ in
            warningCount.increment()
        }

        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let command = DataPlaneCommand.streamStart(format, codecHeader: nil)

        // Enqueue to cross watermark (1 warning)
        for _ in 0 ..< (DataPlaneSink.highWatermark + 10) {
            sink.enqueue(command)
        }
        #expect(warningCount.value == 1)

        // Keep enqueueing while above watermark — no additional warnings
        for _ in 0 ..< 5 {
            sink.enqueue(command)
        }
        #expect(warningCount.value == 1)
    }

    /// Characterization of the watermark boundary (review finding resolved as
    /// not-a-bug): warn only strictly ABOVE the watermark, re-arm only strictly
    /// BELOW it. The width-1 dead band at exactly the watermark means hovering
    /// there is one continuing excursion — one warning, no flapping.
    @Test
    func rateLimitedWatermark_boundaryHysteresisDeadBand() throws {
        let warningCount = AtomicInt(0)
        let sink = DataPlaneSink { _ in
            warningCount.increment()
        }

        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let command = DataPlaneCommand.streamStart(format, codecHeader: nil)

        // Exactly AT the watermark: no warning (warn requires depth > watermark).
        for _ in 0 ..< DataPlaneSink.highWatermark {
            sink.enqueue(command)
        }
        #expect(warningCount.value == 0, "no warning at exactly the watermark")

        // One past: the excursion begins, exactly one warning.
        sink.enqueue(command)
        #expect(warningCount.value == 1)

        // Hover at the boundary (+1 → 0 → +1 relative to the watermark): depth
        // == watermark does NOT re-arm (re-arm requires depth < watermark), so
        // the excursion continues silently.
        sink.decrementDepth()
        sink.enqueue(command)
        #expect(warningCount.value == 1, "hovering at the watermark must not flap the warning")

        // Dropping strictly BELOW ends the excursion: the next crossing warns.
        sink.decrementDepth()
        sink.decrementDepth()
        sink.enqueue(command)
        sink.enqueue(command)
        #expect(warningCount.value == 2, "a fresh excursion after re-arm warns again")
    }

    // MARK: - No disconnect, never drop

    @Test
    func noDrop_watermarkCrossing() throws {
        let sink = DataPlaneSink()
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let command = DataPlaneCommand.streamStart(format, codecHeader: nil)

        let enqueueCount = DataPlaneSink.highWatermark + 100

        // Enqueue many beyond watermark
        for _ in 0 ..< enqueueCount {
            sink.enqueue(command)
        }
        #expect(sink.depth == enqueueCount)

        // Drain all
        for _ in 0 ..< enqueueCount {
            sink.decrementDepth()
        }
        #expect(sink.depth == 0)

        // Sink is still open (not finished)
        let afterFinish = try AudioFormatSpec(codec: .pcm, channels: 1, sampleRate: 44_100, bitDepth: 24)
        let afterCommand = DataPlaneCommand.streamStart(afterFinish, codecHeader: nil)
        sink.enqueue(afterCommand)
        #expect(sink.depth == 1)
    }

    // MARK: - Atomicity Under Concurrency

    @Test
    func atomicity_concurrentEnqueueAndDecrement() async throws {
        let sink = DataPlaneSink()
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let command = DataPlaneCommand.streamStart(format, codecHeader: nil)

        // Prefill a cushion so depth never reaches 0 during the race. The
        // `decrementDepth` floor (`max(0, …)`) silently swallows decrements once
        // depth hits zero, which makes the final arithmetic nondeterministic if
        // decrements can outrun enqueues. Keeping depth >= cushion - decrementCount
        // > 0 throughout means every decrement takes effect, so the count is exact
        // and a lost/torn update under the lock would show as a mismatch.
        let cushion = 1_000
        for _ in 0 ..< cushion {
            sink.enqueue(command)
        }

        let enqueueCount = 500
        let decrementCount = 800

        async let enqueues: Void = Task {
            for _ in 0 ..< enqueueCount {
                sink.enqueue(command)
            }
        }.value
        async let decrements: Void = Task {
            for _ in 0 ..< decrementCount {
                sink.decrementDepth()
            }
        }.value
        _ = await (enqueues, decrements)

        // cushion (1000) - decrementCount (800) = 200 floor during the race, so the
        // result is exactly cushion + enqueueCount - decrementCount, deterministically.
        #expect(sink.depth == cushion + enqueueCount - decrementCount)
    }

    @Test
    func atomicity_finishRacingWithEnqueue() async throws {
        let sink = DataPlaneSink()
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let command = DataPlaneCommand.streamStart(format, codecHeader: nil)

        // Enqueue a few before the race
        let prefill = 2
        sink.enqueue(command)
        sink.enqueue(command)
        #expect(sink.depth == prefill)

        // Genuinely race enqueues against finish() — no pre-sleep tilting the
        // outcome (the old `Task.sleep(100ns)` all but guaranteed the enqueues
        // finished first, making the lower-bound check below tautological).
        let racingEnqueues = 100
        async let enqueues: Void = Task {
            for _ in 0 ..< racingEnqueues {
                sink.enqueue(command)
            }
        }.value
        async let finishing: Void = Task { sink.finish() }.value
        _ = await (enqueues, finishing)

        // Each racing enqueue either landed before finish() (counted, under the
        // lock) or was rejected after (no-op): depth is consistent within bounds,
        // never torn or double-counted.
        #expect(sink.depth >= prefill)
        #expect(sink.depth <= prefill + racingEnqueues)

        // The defining post-condition: once finished, every further enqueue is a no-op.
        let settled = sink.depth
        sink.enqueue(command)
        #expect(sink.depth == settled)
    }

    // MARK: - Commands Drain

    @Test
    func commandsDrain_receiveEnqueuedCommands() async throws {
        let sink = DataPlaneSink()
        let format = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)

        let cmd1 = DataPlaneCommand.streamStart(format, codecHeader: nil)
        let cmd2 = DataPlaneCommand.chunk(Data([1, 2, 3]), ts: 100)
        let cmd3 = DataPlaneCommand.streamEnd(roles: nil)

        sink.enqueue(cmd1)
        sink.enqueue(cmd2)
        sink.enqueue(cmd3)

        let received = AtomicList<DataPlaneCommand>()
        let drainTask = Task {
            for await command in sink.commands {
                received.append(command)
                if received.count == 3 {
                    break
                }
            }
        }

        // Give drain task time to collect
        try? await Task.sleep(nanoseconds: 1_000_000)

        // Finish to end the stream
        sink.finish()

        await drainTask.value

        #expect(received.count == 3)
        // Verify order
        if case let .streamStart(receivedFormat, _) = received.all[0] {
            #expect(receivedFormat.codec == format.codec)
        } else {
            Issue.record("Expected streamStart as first command")
        }
    }
}
