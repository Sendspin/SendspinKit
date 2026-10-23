import Foundation

struct PCMTimestampSpan {
    var frames: Int = 0
    var serverTime: Int64 = 0
    var remainder: Int64 = 0
    var timelineAdjustmentUs: Int64?
    var generation: UInt64 = 0

    mutating func advance(_ count: Int, sampleRate: Int) {
        let rate = Int64(sampleRate)
        let elapsed = Int64(count) * 1_000_000
        let serverTotal = remainder + elapsed
        serverTime = serverTime.saturatingAdding(serverTotal / rate)
        remainder = serverTotal % rate
        frames -= count
    }
}

/// Owns fixed storage; like PCMRingBuffer, it must not be copied or freed twice.
struct PCMTimestampSpans: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<PCMTimestampSpan>
    let capacity: Int
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = .allocate(capacity: self.capacity)
        storage.initialize(repeating: PCMTimestampSpan(), count: self.capacity)
    }

    var first: PCMTimestampSpan? {
        count > 0 ? storage[head] : nil
    }

    var end: PCMTimestampSpan? {
        guard count > 0 else { return nil }
        return storage[(head + count - 1) % capacity]
    }

    /// Wire timestamps quantize to microseconds; retain the accumulated rational phase.
    static func isContinuous(_ span: PCMTimestampSpan, after end: PCMTimestampSpan, sampleRate: Int) -> Bool {
        let delta = span.serverTime.subtractingReportingOverflow(end.serverTime)
        guard !delta.overflow, (-1 ... 1).contains(delta.partialValue) else { return false }
        let phaseDelta = delta.partialValue * Int64(sampleRate) + span.remainder - end.remainder
        return abs(phaseDelta) <= Int64(sampleRate)
            && end.generation == span.generation
            && (end.timelineAdjustmentUs ?? 0) == (span.timelineAdjustmentUs ?? 0)
    }

    func canAppend(_ span: PCMTimestampSpan, sampleRate: Int) -> Bool {
        count < capacity || canMerge(span, sampleRate: sampleRate)
    }

    private func canMerge(_ span: PCMTimestampSpan, sampleRate: Int) -> Bool {
        guard count > 0 else { return false }
        var end = storage[(head + count - 1) % capacity]
        end.advance(end.frames, sampleRate: sampleRate)
        return Self.isContinuous(span, after: end, sampleRate: sampleRate)
    }

    mutating func append(_ span: PCMTimestampSpan, sampleRate: Int) {
        if canMerge(span, sampleRate: sampleRate) {
            storage[(head + count - 1) % capacity].frames += span.frames
        } else {
            precondition(count < capacity)
            storage[(head + count) % capacity] = span
            count += 1
        }
    }

    mutating func consume(_ frames: Int, sampleRate: Int) -> PCMTimestampSpan? {
        guard count > 0 else { return nil }
        precondition(frames <= storage[head].frames)
        storage[head].advance(frames, sampleRate: sampleRate)
        let end = storage[head]
        if end.frames == 0 {
            head = (head + 1) % capacity
            count -= 1
        }
        return end
    }

    mutating func reset() {
        head = 0
        count = 0
    }

    mutating func deallocate() {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }
}
