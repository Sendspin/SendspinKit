import Foundation
import os
@testable import SendspinKit
import Testing

struct DeviceGainSamplerTests {
    @Test("pending device gain query does not block snapshots or accumulate refreshes")
    func pendingQueryCoalescesRequests() async throws {
        let queue = DispatchQueue(label: "DeviceGainSamplerTests.query")
        let caller = DispatchQueue(label: "DeviceGainSamplerTests.caller")
        let gate = DeviceGainQueryGate(queue: queue)
        defer { gate.releaseAll() }
        let sampler = DeviceGainSampler(queue: queue) { gate.query() }
        let unknown = DeviceGainSample(volume: nil, muted: nil)

        let initial = try await request(on: caller, gate: gate) { sampler.sample() }
        #expect(initial == unknown)
        #expect(await waitUntil { gate.count == 1 })

        let snapshots = try await request(on: caller, gate: gate) {
            (0 ..< 100).map { _ in sampler.sample() }
        }
        #expect(snapshots.allSatisfy { $0 == unknown })
        #expect(gate.count == 1)
        gate.releaseOne()
        await drain(queue)
        #expect(gate.count == 1)

        let first = try await request(on: caller, gate: gate) { sampler.sample() }
        #expect(first == gate.result(for: 1))
        #expect(await waitUntil { gate.count == 2 })
        let cached = try await request(on: caller, gate: gate) { sampler.sample() }
        #expect(cached == first)
        gate.releaseOne()
        await drain(queue)
        #expect(gate.count == 2)

        gate.releaseAll()
        let second = sampler.sample()
        #expect(second == gate.result(for: 2))
        await drain(queue)
    }

    @Test("a queued refresh does not retain its sampler and is skipped after release")
    func queuedQueryDoesNotRetainSampler() async {
        let queue = DispatchQueue(label: "DeviceGainSamplerTests.queued")
        let gate = DeviceGainQueryGate(queue: queue)
        defer { gate.releaseAll() }
        queue.async { _ = gate.query() }
        #expect(await waitUntil { gate.count == 1 })
        let queries = OSAllocatedUnfairLock(initialState: 0)
        var sampler: DeviceGainSampler? = DeviceGainSampler(queue: queue) {
            queries.withLock { $0 += 1 }
            return DeviceGainSample(volume: nil, muted: nil)
        }
        weak let releasedSampler = sampler
        _ = sampler?.sample()
        sampler = nil
        #expect(releasedSampler == nil)
        gate.releaseAll()
        await drain(queue)
        #expect(queries.withLock { $0 } == 0)
    }

    @Test("a running device query does not retain its sampler")
    func runningQueryDoesNotRetainSampler() async {
        let queue = DispatchQueue(label: "DeviceGainSamplerTests.running")
        let gate = DeviceGainQueryGate(queue: queue)
        defer { gate.releaseAll() }
        var sampler: DeviceGainSampler? = DeviceGainSampler(queue: queue) { gate.query() }
        weak let releasedSampler = sampler
        _ = sampler?.sample()
        #expect(await waitUntil { gate.count == 1 })
        sampler = nil
        #expect(releasedSampler == nil)
        gate.releaseAll()
        await drain(queue)
    }

    private func request<Value: Sendable>(
        on queue: DispatchQueue,
        gate: DeviceGainQueryGate,
        operation: @escaping @Sendable () -> Value
    ) async throws -> Value {
        try await runUnstructuredWithDeadline(
            .seconds(2),
            label: "device gain snapshot",
            onTimeout: { gate.releaseAll() },
            operation: {
                await withCheckedContinuation { continuation in
                    queue.async { continuation.resume(returning: operation()) }
                }
            }
        )
    }

    private func drain(_ queue: DispatchQueue) async {
        do {
            try await runUnstructuredWithDeadline(.seconds(2), label: "device gain queue drain") {
                await withCheckedContinuation { continuation in
                    queue.async { continuation.resume() }
                }
            }
        } catch {
            Issue.record(error)
        }
    }
}

private final class DeviceGainQueryGate: @unchecked Sendable {
    private let queue: DispatchQueue
    private let condition = NSCondition()
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    private var permits = 0
    private var released = false

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    var count: Int {
        calls.withLock { $0 }
    }

    func result(for call: Int) -> DeviceGainSample {
        DeviceGainSample(volume: Float(call) / 10, muted: call.isMultiple(of: 2))
    }

    func query() -> DeviceGainSample {
        // Only the dedicated query queue may block; async test tasks always suspend.
        dispatchPrecondition(condition: .onQueue(queue))
        condition.lock()
        let call = calls.withLock { count in
            count += 1
            return count
        }
        while permits == 0, !released {
            condition.wait()
        }
        if permits > 0 {
            permits -= 1
        }
        condition.unlock()
        return result(for: call)
    }

    func releaseOne() {
        condition.lock()
        permits += 1
        condition.signal()
        condition.unlock()
    }

    func releaseAll() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
