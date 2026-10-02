@testable import SendspinKit

/// Starts the single report consumer before a test triggers the engine effect it observes.
actor EngineReportObservation {
    private(set) var isReady = false
    private(set) var matched = false
    private var task: Task<Void, Never>?

    func start(
        engine: AudioEngine,
        where predicate: @escaping @Sendable (EngineReport) -> Bool
    ) {
        task = Task {
            isReady = true
            for await report in engine.reports where predicate(report) {
                matched = true
                return
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
