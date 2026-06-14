// ABOUTME: Unit tests for the pure multi-server arbitration decision function
// ABOUTME: Exercises the full spec decision table without any I/O

@testable import SendspinKit
import Testing

struct MultiServerArbitrationTests {
    private let newId = "new-server"
    private let existingId = "existing-server"

    @Test
    func newPlaybackBeatsExistingDiscovery() {
        #expect(SendspinClient.arbitrate(
            newReason: .playback,
            existingReason: .discovery,
            newServerId: newId,
            lastPlayedServerId: nil
        ) == .switchToNew)
    }

    @Test
    func newPlaybackBeatsExistingPlayback() {
        #expect(SendspinClient.arbitrate(
            newReason: .playback,
            existingReason: .playback,
            newServerId: newId,
            lastPlayedServerId: nil
        ) == .switchToNew)
    }

    /// A `discovery` connection must never displace an active `playback` server,
    /// even when the new server happens to be the last-played one.
    @Test
    func newDiscoveryYieldsToExistingPlayback() {
        #expect(SendspinClient.arbitrate(
            newReason: .discovery,
            existingReason: .playback,
            newServerId: newId,
            lastPlayedServerId: newId
        ) == .keepExisting)
    }

    @Test
    func bothDiscoveryLastPlayedIsNewSwitches() {
        #expect(SendspinClient.arbitrate(
            newReason: .discovery,
            existingReason: .discovery,
            newServerId: newId,
            lastPlayedServerId: newId
        ) == .switchToNew)
    }

    @Test
    func bothDiscoveryLastPlayedIsExistingKeeps() {
        #expect(SendspinClient.arbitrate(
            newReason: .discovery,
            existingReason: .discovery,
            newServerId: newId,
            lastPlayedServerId: existingId
        ) == .keepExisting)
    }

    /// A nil persistence provider loads no last-played value, so discovery ties
    /// must not invent a winner from hidden storage.
    @Test
    func bothDiscoveryNoPersistedLastPlayedKeepsExisting() {
        #expect(SendspinClient.arbitrate(
            newReason: .discovery,
            existingReason: .discovery,
            newServerId: newId,
            lastPlayedServerId: nil
        ) == .keepExisting)
    }

    @Test
    func bothDiscoveryUnrelatedLastPlayedKeeps() {
        #expect(SendspinClient.arbitrate(
            newReason: .discovery,
            existingReason: .discovery,
            newServerId: newId,
            lastPlayedServerId: "third-server"
        ) == .keepExisting)
    }
}
