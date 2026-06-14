// ABOUTME: Control-plane specialization of WatermarkedSink carrying ConnectionEvents to the facade
// ABOUTME: Small watermark — control traffic is sparse, so even a modest backlog means a stalled drain

import Foundation

/// Ordered, unbounded sink for `ConnectionEvent`s sent from the connection to the facade drain.
/// The locking, depth-tracking, and watermark hysteresis live in ``WatermarkedSink``.
typealias ControlEventSink = WatermarkedSink<ConnectionEvent>

extension WatermarkedSink where Element == ConnectionEvent {
    /// Control events are sparse (mostly clock-sync chatter and rare lifecycle
    /// transitions): a backlog of even a few dozen means the facade drain has
    /// stalled, so warn far earlier than the data plane's 512.
    static var highWatermark: Int {
        32
    }

    /// Initializes the sink with an optional warning hook (for testing).
    /// - Parameter onWarning: Closure called when depth crosses the high watermark. Defaults to `Log.client.warning`.
    convenience init(onWarning: (@Sendable (String) -> Void)? = nil) {
        self.init(
            highWatermark: Self.highWatermark,
            onWarning: onWarning ?? { message in
                Log.client.warning("ControlEventSink: \(message)")
            }
        )
    }
}
