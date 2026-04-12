// ABOUTME: Tests for PCMRingBuffer — the real-time audio thread ring buffer
// ABOUTME: Validates wrap-around, partial writes, skip, peek, and capacity behavior

import Foundation
@testable import SendspinKit
import Testing

struct PCMRingBufferTests {
    @Test
    func `Capacity rounds up to power of 2`() {
        var buf = PCMRingBuffer(capacity: 100)
        #expect(buf.capacity == 128)
        #expect(buf.availableToRead == 0)
        #expect(buf.availableToWrite == 128)
        buf.deallocate()

        var buf2 = PCMRingBuffer(capacity: 256)
        #expect(buf2.capacity == 256)
        buf2.deallocate()
    }

    @Test
    func `Basic write and read`() {
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

    @Test
    func `Write wraps around the boundary`() {
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

    @Test
    func `Write truncates when buffer is full`() {
        var buf = PCMRingBuffer(capacity: 8) // rounds to 8
        defer { buf.deallocate() }

        let data = Data(repeating: 0xFF, count: 12)
        let written = buf.write(data)
        #expect(written == 8) // only capacity bytes written
        #expect(buf.availableToRead == 8)
        #expect(buf.availableToWrite == 0)
    }

    @Test
    func `Skip discards bytes without copying`() {
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

    @Test
    func `Reset clears the buffer`() {
        var buf = PCMRingBuffer(capacity: 32)
        defer { buf.deallocate() }

        buf.write(Data(repeating: 0xAB, count: 16))
        #expect(buf.availableToRead == 16)

        buf.reset()
        #expect(buf.availableToRead == 0)
        #expect(buf.availableToWrite == 32)
    }

    @Test
    func `Write from Data convenience method`() {
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

    @Test
    func `Repeated wrap-around cycles maintain data integrity`() {
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

    @Test
    func `Partial read returns only available bytes`() {
        var buf = PCMRingBuffer(capacity: 16)
        defer { buf.deallocate() }

        buf.write(Data([1, 2, 3]))
        var dest = [UInt8](repeating: 0, count: 10)
        let readCount = dest.withUnsafeMutableBytes { ptr in
            buf.read(into: ptr.baseAddress!, count: 10)
        }
        #expect(readCount == 3)
        #expect(dest[0 ... 2] == [1, 2, 3])
    }
}
