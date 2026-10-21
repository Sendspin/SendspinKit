import Foundation
import os
@testable import SendspinKit
import Testing

struct AudioPlayerCancellationTests {
    @Test("cancelling a device-live wait releases the player task")
    func cancellationReleasesDeviceLiveWait() async {
        let player = AudioPlayer()
        let completed = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            try await player.waitUntilOutputDeviceIsLive()
            completed.withLock { $0 = true }
        }
        await Task.yield()
        task.cancel()
        #expect(await waitUntil(timeout: audioProcessingBudget) { completed.withLock { $0 } })
        await player.stop()
        _ = await task.result
    }
}
