import Foundation
@testable import SendspinKit
import Testing

/// Plain `write` truncates mid-frame on overflow. The reader always consumes whole
/// frames, so for any `frameSize` that doesn't divide the power-of-two capacity
/// (6-channel: 12 or 24 bytes/frame) the leftover partial frame permanently misaligns
/// every later read. Overflow here is routine, not exceptional.
struct PCMRingBufferFrameAlignmentTests {
    /// 6 channels × 16-bit = 12 bytes per frame. 12 does not divide any power of two.
    private static let surroundFrameSize = 12

    @Test("a frame-aligned write never leaves a partial frame when the buffer overflows")
    func overflowTruncatesOnFrameBoundary() {
        var buffer = PCMRingBuffer(capacity: 64)
        let frameSize = Self.surroundFrameSize

        // 64 is not a multiple of 12: 5 whole frames (60 bytes) fit, 4 bytes are unusable.
        let written = buffer.writeFrames(Data(repeating: 0xAB, count: 240), frameSize: frameSize)

        #expect(written % frameSize == 0, "a partial frame must never be written")
        #expect(written == 60, "5 whole 12-byte frames fit in a 64-byte ring")
        #expect(
            buffer.availableToRead % frameSize == 0,
            "the buffer must contain only whole frames after an overflowing write"
        )
    }

    /// The core invariant across many overflow/drain cycles.
    @Test("repeated overflow and drain keeps the read stream frame-aligned")
    func repeatedOverflowKeepsAlignment() throws {
        var buffer = PCMRingBuffer(capacity: 128)
        let frameSize = Self.surroundFrameSize
        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: 256, alignment: 16)
        defer { scratch.deallocate() }
        let scratchBase = try #require(scratch.baseAddress)

        for iteration in 0 ..< 50 {
            // Deliberately oversized writes so the ring overflows every time.
            _ = buffer.writeFrames(Data(repeating: UInt8(iteration % 251), count: 200), frameSize: frameSize)
            #expect(
                buffer.availableToRead % frameSize == 0,
                "iteration \(iteration): buffer holds a partial frame"
            )

            // Drain a couple of whole frames, as the render callback would.
            let toRead = min(frameSize * 2, buffer.availableToRead)
            _ = buffer.read(into: scratchBase, count: toRead)
            #expect(
                buffer.availableToRead % frameSize == 0,
                "iteration \(iteration): buffer misaligned after a whole-frame read"
            )
        }
    }

    /// Guards against the fix degenerating into "never write anything".
    @Test("a frame-aligned write still fills the buffer when there is room")
    func nonOverflowingWriteIsUnaffected() {
        var buffer = PCMRingBuffer(capacity: 256)
        let frameSize = Self.surroundFrameSize

        let payload = Data(repeating: 0x7F, count: frameSize * 4)
        let written = buffer.writeFrames(payload, frameSize: frameSize)

        #expect(written == payload.count, "a fitting whole-frame payload must be written entirely")
        #expect(buffer.availableToRead == payload.count)
    }

    /// A truncated chunk from the wire must not introduce misalignment either.
    @Test("a payload that is not a whole number of frames is truncated to whole frames")
    func partialFramePayloadIsTruncated() {
        var buffer = PCMRingBuffer(capacity: 256)
        let frameSize = Self.surroundFrameSize

        // 3.5 frames worth of bytes.
        let written = buffer.writeFrames(Data(repeating: 0x01, count: frameSize * 3 + 6), frameSize: frameSize)

        #expect(written == frameSize * 3, "the trailing partial frame must be dropped")
        #expect(buffer.availableToRead % frameSize == 0)
    }

    /// Power-of-two frame sizes divide the capacity, so this path must be a no-op for them.
    @Test("a frame size that divides the capacity writes exactly as before")
    func powerOfTwoFrameSizeMatchesPlainWrite() {
        let stereo16FrameSize = 4
        var aligned = PCMRingBuffer(capacity: 64)
        var plain = PCMRingBuffer(capacity: 64)

        let payload = Data(repeating: 0x33, count: 200)
        let alignedWritten = aligned.writeFrames(payload, frameSize: stereo16FrameSize)
        let plainWritten = plain.write(payload)

        #expect(alignedWritten == plainWritten)
        #expect(alignedWritten == 64)
    }

    /// Defensive: an unset frame size (before `prepare`) must not divide by zero.
    @Test("a zero frame size falls back to an unaligned write instead of trapping")
    func zeroFrameSizeFallsBack() {
        var buffer = PCMRingBuffer(capacity: 64)

        let written = buffer.writeFrames(Data(repeating: 0x05, count: 32), frameSize: 0)

        #expect(written == 32)
    }
}
