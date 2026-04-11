// ABOUTME: Tests for PCMRingBuffer — the real-time audio thread ring buffer
// ABOUTME: Validates wrap-around, partial writes, skip, peek, and capacity behavior

import Foundation
import Testing
@testable import SendspinKit

@Suite("PCM Ring Buffer")
struct PCMRingBufferTests {

    @Test("Capacity rounds up to power of 2")
    func capacityRoundsUp() {
        var buf = PCMRingBuffer(capacity: 100)
        #expect(buf.capacity == 128)
        #expect(buf.availableToRead == 0)
        #expect(buf.availableToWrite == 128)
        buf.deallocate()

        var buf2 = PCMRingBuffer(capacity: 256)
        #expect(buf2.capacity == 256)
        buf2.deallocate()
    }

    @Test("Basic write and read")
    func basicWriteRead() {
        var buf = PCMRingBuffer(capacity: 64)
        defer { buf.deallocate() }

        let source: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let written = source.withUnsafeBytes { ptr in
            buf.write(from: ptr.baseAddress!, count: 8)
        }
        #expect(written == 8)
        #expect(buf.availableToRead == 8)
        #expect(buf.availableToWrite == 56)

        var dest = [UInt8](repeating: 0, count: 8)
        let readCount = dest.withUnsafeMutableBytes { ptr in
            buf.read(into: ptr.baseAddress!, count: 8)
        }
        #expect(readCount == 8)
        #expect(dest == source)
        #expect(buf.availableToRead == 0)
    }

    @Test("Write wraps around the boundary")
    func wrapAround() {
        var buf = PCMRingBuffer(capacity: 16)
        defer { buf.deallocate() }

        // Fill 12 bytes, read 12, then write 8 more (should wrap)
        let data12 = Data(repeating: 0xAA, count: 12)
        buf.write(data12)
        #expect(buf.availableToRead == 12)

        var trash = [UInt8](repeating: 0, count: 12)
        trash.withUnsafeMutableBytes { ptr in
            buf.read(into: ptr.baseAddress!, count: 12)
        }
        #expect(buf.availableToRead == 0)

        // Now write position is at 12, read position at 12.
        // Writing 8 bytes should wrap: 4 at end, 4 at beginning
        let source: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        source.withUnsafeBytes { ptr in
            buf.write(from: ptr.baseAddress!, count: 8)
        }
        #expect(buf.availableToRead == 8)

        var dest = [UInt8](repeating: 0, count: 8)
        dest.withUnsafeMutableBytes { ptr in
            buf.read(into: ptr.baseAddress!, count: 8)
        }
        #expect(dest == source)
    }

    @Test("Write truncates when buffer is full")
    func writeTruncatesWhenFull() {
        var buf = PCMRingBuffer(capacity: 8) // rounds to 8
        defer { buf.deallocate() }

        let data = Data(repeating: 0xFF, count: 12)
        let written = buf.write(data)
        #expect(written == 8) // only capacity bytes written
        #expect(buf.availableToRead == 8)
        #expect(buf.availableToWrite == 0)
    }

    @Test("Skip discards bytes without copying")
    func skipDiscardsBytes() {
        var buf = PCMRingBuffer(capacity: 32)
        defer { buf.deallocate() }

        let data: [UInt8] = [10, 20, 30, 40, 50, 60]
        data.withUnsafeBytes { ptr in
            buf.write(from: ptr.baseAddress!, count: 6)
        }

        let skipped = buf.skip(4)
        #expect(skipped == 4)
        #expect(buf.availableToRead == 2)

        var dest = [UInt8](repeating: 0, count: 2)
        dest.withUnsafeMutableBytes { ptr in
            buf.read(into: ptr.baseAddress!, count: 2)
        }
        #expect(dest == [50, 60])
    }

    @Test("Peek last frame reads without consuming")
    func peekLastFrame() {
        var buf = PCMRingBuffer(capacity: 32)
        defer { buf.deallocate() }

        // Write 3 frames of 4 bytes each
        let frames: [UInt8] = [1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3]
        frames.withUnsafeBytes { ptr in
            buf.write(from: ptr.baseAddress!, count: 12)
        }

        var lastFrame = [UInt8](repeating: 0, count: 4)
        let ok = lastFrame.withUnsafeMutableBytes { ptr in
            buf.peekLastFrame(into: ptr.baseAddress!, frameSize: 4)
        }
        #expect(ok)
        #expect(lastFrame == [3, 3, 3, 3])
        // Peek should not consume
        #expect(buf.availableToRead == 12)
    }

    @Test("Peek next frame reads oldest unread data without consuming")
    func peekNextFrame() {
        var buf = PCMRingBuffer(capacity: 32)
        defer { buf.deallocate() }

        let frames: [UInt8] = [1, 1, 1, 1, 2, 2, 2, 2]
        frames.withUnsafeBytes { ptr in
            buf.write(from: ptr.baseAddress!, count: 8)
        }

        // Skip first frame
        buf.skip(4)

        var nextFrame = [UInt8](repeating: 0, count: 4)
        let ok = nextFrame.withUnsafeMutableBytes { ptr in
            buf.peekNextFrame(into: ptr.baseAddress!, frameSize: 4)
        }
        #expect(ok)
        #expect(nextFrame == [2, 2, 2, 2])
        #expect(buf.availableToRead == 4) // still there
    }

    @Test("Reset clears the buffer")
    func resetClears() {
        var buf = PCMRingBuffer(capacity: 32)
        defer { buf.deallocate() }

        buf.write(Data(repeating: 0xAB, count: 16))
        #expect(buf.availableToRead == 16)

        buf.reset()
        #expect(buf.availableToRead == 0)
        #expect(buf.availableToWrite == 32)
    }

    @Test("Write from Data convenience method")
    func writeFromData() {
        var buf = PCMRingBuffer(capacity: 32)
        defer { buf.deallocate() }

        let data = Data([10, 20, 30, 40])
        let written = buf.write(data)
        #expect(written == 4)

        var dest = [UInt8](repeating: 0, count: 4)
        dest.withUnsafeMutableBytes { ptr in
            buf.read(into: ptr.baseAddress!, count: 4)
        }
        #expect(dest == [10, 20, 30, 40])
    }

    @Test("Repeated wrap-around cycles maintain data integrity")
    func repeatedWrapAroundCycles() {
        var buf = PCMRingBuffer(capacity: 16)
        defer { buf.deallocate() }

        // Do many cycles of write-then-read to exercise wrap-around heavily
        for cycle in 0 ..< 100 {
            let value = UInt8(cycle & 0xFF)
            let source = [UInt8](repeating: value, count: 7)

            source.withUnsafeBytes { ptr in
                buf.write(from: ptr.baseAddress!, count: 7)
            }

            var dest = [UInt8](repeating: 0, count: 7)
            dest.withUnsafeMutableBytes { ptr in
                buf.read(into: ptr.baseAddress!, count: 7)
            }
            #expect(dest == source, "Mismatch at cycle \(cycle)")
        }
    }

    @Test("Partial read returns only available bytes")
    func partialRead() {
        var buf = PCMRingBuffer(capacity: 16)
        defer { buf.deallocate() }

        buf.write(Data([1, 2, 3]))
        var dest = [UInt8](repeating: 0, count: 10)
        let readCount = dest.withUnsafeMutableBytes { ptr in
            buf.read(into: ptr.baseAddress!, count: 10)
        }
        #expect(readCount == 3)
        #expect(dest[0...2] == [1, 2, 3])
    }
}
