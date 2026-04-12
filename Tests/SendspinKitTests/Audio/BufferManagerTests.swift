@testable import SendspinKit
import Testing

struct BufferManagerTests {
    @Test
    func `Track buffered chunks and check capacity`() async {
        let manager = BufferManager(capacity: 1_000)

        // Initially has capacity
        let hasCapacity = await manager.hasCapacity(500)
        #expect(hasCapacity == true)

        // Register chunk
        await manager.register(endTimeMicros: 1_000, byteCount: 600)

        // Now should not have capacity for another 500 bytes
        let stillHasCapacity = await manager.hasCapacity(500)
        #expect(stillHasCapacity == false)
    }

    @Test
    func `Prune consumed chunks`() async {
        let manager = BufferManager(capacity: 1_000)

        // Add chunks
        await manager.register(endTimeMicros: 1_000, byteCount: 300)
        await manager.register(endTimeMicros: 2_000, byteCount: 300)
        await manager.register(endTimeMicros: 3_000, byteCount: 300)

        // No capacity for more
        var hasCapacity = await manager.hasCapacity(200)
        #expect(hasCapacity == false)

        // Prune chunks that finished before time 2500
        await manager.pruneConsumed(nowMicros: 2_500)

        // Should have capacity now (first two chunks pruned)
        hasCapacity = await manager.hasCapacity(200)
        #expect(hasCapacity == true)
    }
}
