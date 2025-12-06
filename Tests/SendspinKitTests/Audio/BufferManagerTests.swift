@testable import SendspinKit
import Testing

@Suite("Buffer Manager Tests")
struct BufferManagerTests {
    @Test("Track buffered chunks and check capacity")
    func capacityTracking() async {
        let manager = BufferManager(capacity: 1000)

        // Initially has capacity
        let hasCapacity = await manager.hasCapacity(500)
        #expect(hasCapacity == true)

        // Register chunk
        await manager.register(endTimeMicros: 1000, byteCount: 600)

        // Now should not have capacity for another 500 bytes
        let stillHasCapacity = await manager.hasCapacity(500)
        #expect(stillHasCapacity == false)
    }

    @Test("Prune consumed chunks")
    func pruning() async {
        let manager = BufferManager(capacity: 1000)

        // Add chunks
        await manager.register(endTimeMicros: 1000, byteCount: 300)
        await manager.register(endTimeMicros: 2000, byteCount: 300)
        await manager.register(endTimeMicros: 3000, byteCount: 300)

        // No capacity for more
        var hasCapacity = await manager.hasCapacity(200)
        #expect(hasCapacity == false)

        // Prune chunks that finished before time 2500
        await manager.pruneConsumed(nowMicros: 2500)

        // Should have capacity now (first two chunks pruned)
        hasCapacity = await manager.hasCapacity(200)
        #expect(hasCapacity == true)
    }
}
