// ABOUTME: Tests for the control-plane ControlEventSink specialization of WatermarkedSink
// ABOUTME: Pins the small control watermark and its one-warning-per-excursion crossing

import Foundation
@testable import SendspinKit
import Testing

struct ControlEventSinkTests {
    @Test("control watermark warns once, strictly above the threshold")
    func watermarkCrossingWarnsOnce() {
        let warningCount = AtomicInt(0)
        let sink = ControlEventSink { _ in
            warningCount.increment()
        }

        // Exactly AT the watermark: no warning (warn requires depth > watermark).
        for _ in 0 ..< ControlEventSink.highWatermark {
            sink.enqueue(.clockSyncEstablished)
        }
        #expect(warningCount.value == 0, "no warning at exactly the control watermark")

        // One past: the excursion begins, exactly one warning.
        sink.enqueue(.clockSyncEstablished)
        #expect(warningCount.value == 1)

        // Still above: no flapping.
        sink.enqueue(.clockSyncEstablished)
        #expect(warningCount.value == 1, "one warning per excursion")
    }

    @Test("the control watermark is far smaller than the data plane's")
    func controlWatermarkIsSmall() {
        // Control events are sparse (mostly clock-sync chatter); a backlog of even a
        // few dozen means the facade drain has stalled. Waiting for the data plane's
        // 512 would mean minutes of thumb-twiddling before any diagnostic.
        #expect(ControlEventSink.highWatermark < DataPlaneSink.highWatermark)
    }
}
