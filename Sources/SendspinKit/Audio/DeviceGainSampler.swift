import Dispatch
import os

struct DeviceGainSample: Sendable, Equatable {
    let volume: Float?
    let muted: Bool?
}

/// Device diagnostics may stall; return cached gain while at most one background query runs.
final class DeviceGainSampler: Sendable {
    private struct State {
        var cached = DeviceGainSample(volume: nil, muted: nil)
        var queryPending = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue: DispatchQueue
    private let query: @Sendable () -> DeviceGainSample

    init(
        queue: DispatchQueue = DispatchQueue(label: "SendspinKit.device-gain", qos: .utility),
        query: @escaping @Sendable () -> DeviceGainSample = {
            let gain = OutputDeviceLatency.currentDeviceGain()
            return DeviceGainSample(volume: gain.volume, muted: gain.muted)
        }
    ) {
        self.queue = queue
        self.query = query
    }

    func sample() -> DeviceGainSample {
        let (cached, refresh) = state.withLock { state in
            let refresh = !state.queryPending
            state.queryPending = true
            return (state.cached, refresh)
        }
        if refresh {
            let query = query
            // A slow query must not retain the sampler for its entire duration.
            queue.async { [weak self] in
                guard self != nil else { return }
                let result = query()
                self?.state.withLock { state in
                    state.cached = result
                    state.queryPending = false
                }
            }
        }
        return cached
    }
}
