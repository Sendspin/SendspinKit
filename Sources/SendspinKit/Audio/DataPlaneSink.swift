// ABOUTME: Data-plane specialization of WatermarkedSink carrying DataPlaneCommands to the engine
// ABOUTME: Preserves data-plane vocabulary (commands) and the 512-command watermark over the generic

import Foundation

/// Ordered, unbounded sink for `DataPlaneCommand`s sent from the message loop to the audio engine.
/// The locking, depth-tracking, and watermark hysteresis live in ``WatermarkedSink``.
typealias DataPlaneSink = WatermarkedSink<DataPlaneCommand>

extension WatermarkedSink where Element == DataPlaneCommand {
    /// High-watermark threshold for depth-based warnings (in commands, not bytes).
    static var highWatermark: Int {
        512
    }

    /// The `AsyncStream` of commands the engine drains.
    nonisolated var commands: AsyncStream<DataPlaneCommand> {
        elements
    }

    /// Initializes the sink with an optional warning hook (for testing).
    /// - Parameter onWarning: Closure called when depth crosses the high watermark. Defaults to `Log.audio.warning`.
    convenience init(onWarning: (@Sendable (String) -> Void)? = nil) {
        self.init(
            highWatermark: Self.highWatermark,
            onWarning: onWarning ?? { message in
                Log.audio.warning("DataPlaneSink: \(message)")
            }
        )
    }
}
