// ABOUTME: Tests for FrameInbox, the single-consumer async frame queue.
// ABOUTME: Verifies FIFO order, parked-consumer resume, finish-driven release, and post-finish drop.

import Foundation
@testable import SendspinKit
import Testing

struct FrameInboxTests {
    // MARK: - FIFO delivery

    @Test("Buffered frames are delivered FIFO")
    func bufferedFramesFIFO() async {
        let inbox = FrameInbox()
        inbox.yield(.text("a"))
        inbox.yield(.binary(Data([0x01])))

        #expect(await isText(inbox.next(), "a"))
        #expect(await isBinary(inbox.next(), Data([0x01])))
    }

    @Test("Text and binary frames preserve interleaved wire order")
    func interleavedKindsPreserveOrder() async {
        let inbox = FrameInbox()
        inbox.yield(.text("1"))
        inbox.yield(.binary(Data([0x02])))
        inbox.yield(.text("3"))
        inbox.finish()

        #expect(await isText(inbox.next(), "1"))
        #expect(await isBinary(inbox.next(), Data([0x02])))
        #expect(await isText(inbox.next(), "3"))
        #expect(await inbox.next() == nil)
    }

    @Test("Order is preserved across a large burst (exercises buffer compaction)")
    func largeBurstPreservesOrder() async {
        let inbox = FrameInbox()
        let count = 1_000
        for i in 0 ..< count {
            inbox.yield(.binary(Data([UInt8(i & 0xFF)])))
        }
        inbox.finish()

        var received: [UInt8] = []
        while let frame = await inbox.next() {
            if case let .binary(data) = frame, let byte = data.first { received.append(byte) }
        }
        #expect(received.count == count)
        #expect(received == (0 ..< count).map { UInt8($0 & 0xFF) })
    }

    // MARK: - Parked consumer

    @Test("A consumer parked before any yield resumes with the next frame")
    func parkedConsumerResumesOnYield() async {
        let inbox = FrameInbox()

        async let pulled = inbox.next() // parks: no buffered frame, not finished
        // Let the consumer actually park (exercises the parked path; the assertion
        // holds even if the yield wins the race and the frame buffers first).
        try? await Task.sleep(for: .milliseconds(20))
        inbox.yield(.text("late"))

        #expect(await isText(pulled, "late"))
    }

    @Test("finish() unblocks a parked consumer with nil")
    func finishUnblocksParkedConsumer() async {
        let inbox = FrameInbox()

        async let pulled = inbox.next() // parks
        try? await Task.sleep(for: .milliseconds(20))
        inbox.finish()

        #expect(await pulled == nil)
    }

    @Test("finish() is idempotent while and after unblocking a parked consumer")
    func finishIsIdempotentForParkedConsumer() async {
        let inbox = FrameInbox()

        async let pulled = inbox.next() // parks
        try? await Task.sleep(for: .milliseconds(20))
        inbox.finish()
        inbox.finish()

        #expect(await pulled == nil)
        inbox.finish()
        #expect(await inbox.next() == nil)
    }

    @Test("finish(), not task cancellation, is the parked-consumer release mechanism")
    func finishIsParkedConsumerReleaseMechanism() async {
        let inbox = FrameInbox()

        let parkedPull = Task { await inbox.next() }
        try? await Task.sleep(for: .milliseconds(20))
        parkedPull.cancel()
        // Cancellation alone is intentionally not FrameInbox's lifecycle contract;
        // transport/session owners must close the mailbox explicitly.
        inbox.finish()
        #expect(await parkedPull.value == nil)

        #expect(await inbox.next() == nil)
    }

    @Test("cancelling a parked next() does NOT release it; only finish() does")
    func cancellationDoesNotReleaseParkedConsumer() async {
        // Stronger than the test above (which cancels AND finishes): this proves the
        // *negative* — after cancellation alone, the parked pull stays suspended and
        // does not complete until finish() arrives. Mutation guard: make FrameInbox
        // release on cancellation and the mid-test `!completed` assertion fails.
        let inbox = FrameInbox()
        let done = TestBox<Bool>(false)

        let parkedPull = Task { () -> TransportFrame? in
            let frame = await inbox.next()
            await done.set(true)
            return frame
        }
        try? await Task.sleep(for: .milliseconds(20)) // let it park
        parkedPull.cancel()
        try? await Task.sleep(for: .milliseconds(40)) // give a wrong release time to fire

        #expect(await done.value == false, "cancellation alone must NOT complete a parked next()")

        inbox.finish() // the actual release mechanism
        #expect(await parkedPull.value == nil, "finish() releases the parked pull with nil")
        #expect(await done.value, "after finish(), the pull completes")
    }

    // MARK: - Terminal / finished semantics

    @Test("finish() makes a subsequent next() return nil")
    func finishReturnsNil() async {
        let inbox = FrameInbox()
        inbox.finish()
        #expect(await inbox.next() == nil)
    }

    @Test("nil is terminal: buffered frames drain first, then next() stays nil")
    func terminalNilAfterDrain() async {
        let inbox = FrameInbox()
        inbox.yield(.text("a"))
        inbox.finish()

        #expect(await isText(inbox.next(), "a")) // buffered frame drains
        #expect(await inbox.next() == nil) // then terminal nil
        #expect(await inbox.next() == nil) // and stays nil
    }

    @Test("Frames yielded after finish() are dropped")
    func yieldAfterFinishDropped() async {
        let inbox = FrameInbox()
        inbox.finish()
        inbox.yield(.text("ignored"))
        #expect(await inbox.next() == nil)
    }

    // MARK: - Single-consumer contract

    //
    // FrameInbox.next() traps via precondition on overlapping calls. A precondition
    // failure is fatal and uncatchable in-process, so — mirroring NextFrameTests —
    // we do NOT write a test that deliberately trips it; that would crash the run.
    // The library's message loop is the single consumer, and the in-repo integration
    // tests (NextFrameTests.exactlyOnceHandoff) would crash if that contract broke.
}

// MARK: - Frame matchers

private func isText(_ frame: TransportFrame?, _ expected: String) -> Bool {
    if case let .text(value) = frame { return value == expected }
    return false
}

private func isBinary(_ frame: TransportFrame?, _ expected: Data) -> Bool {
    if case let .binary(value) = frame { return value == expected }
    return false
}
