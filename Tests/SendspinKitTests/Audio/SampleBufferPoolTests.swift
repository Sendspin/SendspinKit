// ABOUTME: Tests for SampleBufferPool - reusable audio sample buffer pool
// ABOUTME: Translated from sendspin-rs/tests/buffer_pool.rs

import Testing
@testable import SendspinKit

@Suite("Sample Buffer Pool")
struct SampleBufferPoolTests {

    @Test("pool creation with capacity")
    func bufferPoolCreation() {
        let pool = SampleBufferPool(poolSize: 10, bufferCapacity: 1024)
        #expect(pool.bufferCapacity == 1024)
    }

    @Test("get and return reuses buffers")
    func bufferPoolGetAndReturn() {
        let pool = SampleBufferPool(poolSize: 5, bufferCapacity: 1024)

        // Get a buffer
        var buf = pool.get()
        #expect(buf.capacity >= 1024)

        // Modify it
        buf.append(contentsOf: [Sample](repeating: .zero, count: 100))
        #expect(buf.count == 100)

        // Return it
        pool.put(&buf)

        // Get another - should be reused and cleared
        let buf2 = pool.get()
        #expect(buf2.capacity >= 1024)
        #expect(buf2.count == 0) // Should be cleared
    }

    @Test("fallback allocation when pool exhausted")
    func bufferPoolFallbackAllocation() {
        let pool = SampleBufferPool(poolSize: 2, bufferCapacity: 1024)

        // Get all buffers from pool
        let _buf1 = pool.get()
        let _buf2 = pool.get()

        // This should allocate a new buffer (fallback)
        let buf3 = pool.get()
        #expect(buf3.capacity >= 1024)
    }
}
