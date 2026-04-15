import Foundation
@testable import SendspinKit
import Testing

struct AudioProcessCallbackTests {
    // Standard test format used across all tests in this suite
    // swiftlint:disable:next force_try
    private static let stereo16 = try! AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)

    /// Maximum time to wait for an async audio callback condition.
    private static let pollTimeout: Duration = .milliseconds(2_000)
    /// Interval between polls.
    private static let pollInterval: Duration = .milliseconds(25)

    /// Poll until `condition` returns `true`, checking every ``pollInterval``
    /// up to ``pollTimeout``. Returns `true` if the condition was met.
    private static func pollUntil(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + pollTimeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: pollInterval)
        }
        return condition()
    }

    // MARK: - Callback invocation

    @Test
    func callbackIsInvokedDuringPlayback() async throws {
        let invoked = CallbackRecorder()

        let player = AudioPlayer(
            processCallback: { samples, format in
                invoked.record(byteCount: samples.count, format: format)
            }
        )

        try await player.start(format: Self.stereo16, codecHeader: nil)

        // Feed enough PCM data that the AudioQueue callback must fire.
        // At 48kHz stereo 16-bit, each frame is 4 bytes. 16384-byte buffers
        // need ~4096 frames. Feed 2 seconds to ensure at least one callback.
        let bytesPerFrame = Self.stereo16.channels * (Self.stereo16.bitDepth / 8)
        let twoSeconds = Self.stereo16.sampleRate * bytesPerFrame * 2
        let pcmData = Data(repeating: 0, count: twoSeconds)
        try await player.playPCM(pcmData, serverTimestamp: 0)

        let fired = try await Self.pollUntil { invoked.count > 0 }
        #expect(fired, "Process callback should have been invoked at least once")

        await player.stop()
    }

    @Test
    func callbackReceivesCorrectFormatFor16BitStereo() async throws {
        let invoked = CallbackRecorder()

        let player = AudioPlayer(
            processCallback: { samples, format in
                invoked.record(byteCount: samples.count, format: format)
            }
        )

        try await player.start(format: Self.stereo16, codecHeader: nil)

        let pcmData = Data(repeating: 0, count: 48_000 * 4)
        try await player.playPCM(pcmData, serverTimestamp: 0)

        let fired = try await Self.pollUntil { invoked.count > 0 }
        #expect(fired, "Should have recorded at least one callback")

        let formats = invoked.formats
        if let format = formats.first {
            #expect(format.codec == .pcm)
            #expect(format.channels == 2)
            #expect(format.sampleRate == 48_000)
            // 16-bit PCM stays 16-bit (no expansion)
            #expect(format.bitDepth == 16)
        }

        await player.stop()
    }

    @Test
    func callbackReceives32BitEffectiveFormatFor24BitSource() async throws {
        let invoked = CallbackRecorder()

        let format24 = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 24)

        let player = AudioPlayer(
            processCallback: { samples, format in
                invoked.record(byteCount: samples.count, format: format)
            }
        )

        try await player.start(format: format24, codecHeader: nil)

        // 24-bit PCM is unpacked to 32-bit (4 bytes per sample)
        let bytesPerFrame = 2 * 4 // channels * 4 bytes (32-bit effective)
        let pcmData = Data(repeating: 0, count: 48_000 * bytesPerFrame)
        try await player.playPCM(pcmData, serverTimestamp: 0)

        let fired = try await Self.pollUntil { !invoked.formats.isEmpty }
        #expect(fired)

        if let format = invoked.formats.first {
            #expect(format.bitDepth == 32, "24-bit source should report 32-bit effective output")
        }

        await player.stop()
    }

    @Test
    func callbackReceivesMutableBuffer() async throws {
        let modified = CallbackRecorder()

        let player = AudioPlayer(
            processCallback: { samples, _ in
                // Write a known pattern to verify mutability
                if samples.count >= 4 {
                    samples.storeBytes(of: UInt32(0xDEAD_BEEF), toByteOffset: 0, as: UInt32.self)
                }
                modified.record(byteCount: samples.count, format: Self.stereo16)
            }
        )

        try await player.start(format: Self.stereo16, codecHeader: nil)

        let pcmData = Data(repeating: 0, count: 48_000 * 4)
        try await player.playPCM(pcmData, serverTimestamp: 0)

        let fired = try await Self.pollUntil { modified.count > 0 }
        // If we got here without crashing, the mutable access worked
        #expect(fired, "Callback with mutation should have fired")

        await player.stop()
    }

    @Test
    func callbackFiresEvenWithEmptyRingBufferSilence() async throws {
        let invoked = CallbackRecorder()

        let player = AudioPlayer(
            processCallback: { samples, format in
                invoked.record(byteCount: samples.count, format: format)
            }
        )

        // Start playback but don't feed any PCM data — the AudioQueue
        // will callback with silence-filled buffers
        try await player.start(format: Self.stereo16, codecHeader: nil)

        let fired = try await Self.pollUntil { invoked.count > 0 }
        #expect(fired, "Callback should fire during silence (underrun)")

        await player.stop()
    }

    @Test
    func bufferByteCountMatchesAudioQueueBufferSize() async throws {
        let invoked = CallbackRecorder()

        let player = AudioPlayer(
            processCallback: { samples, _ in
                invoked.record(byteCount: samples.count, format: Self.stereo16)
            }
        )

        try await player.start(format: Self.stereo16, codecHeader: nil)

        let pcmData = Data(repeating: 0, count: 48_000 * 4)
        try await player.playPCM(pcmData, serverTimestamp: 0)

        let fired = try await Self.pollUntil { !invoked.byteCounts.isEmpty }
        #expect(fired)

        let byteCounts = invoked.byteCounts
        // AudioPlayer uses 16384-byte buffers
        let expectedBufferSize = 16_384
        for byteCount in byteCounts {
            #expect(
                byteCount == expectedBufferSize,
                "Callback buffer should be \(expectedBufferSize) bytes, got \(byteCount)"
            )
        }

        await player.stop()
    }

    // MARK: - No callback configured

    @Test
    func playerWorksFineWithoutAProcessCallback() async throws {
        let player = AudioPlayer(
            // no processCallback
        )

        try await player.start(format: Self.stereo16, codecHeader: nil)

        let pcmData = Data(repeating: 0, count: 48_000 * 4)
        try await player.playPCM(pcmData, serverTimestamp: 0)

        // Brief sleep to let the AudioQueue prime — no callback to poll here
        try await Task.sleep(for: .milliseconds(50))

        let isPlaying = await player.isPlaying
        #expect(isPlaying == true)

        await player.stop()
    }

    // MARK: - PlayerConfiguration integration

    @Test
    func playerConfiguration_defaultsToNilProcessCallback() throws {
        let config = try PlayerConfiguration(
            bufferCapacity: 1_024,
            supportedFormats: [Self.stereo16]
        )
        #expect(config.processCallback == nil)
    }

    @Test
    func playerConfiguration_storesProcessCallback() throws {
        let recorder = CallbackRecorder()
        let config = try PlayerConfiguration(
            bufferCapacity: 1_024,
            supportedFormats: [Self.stereo16],
            processCallback: { _, format in recorder.record(byteCount: 0, format: format) }
        )
        #expect(config.processCallback != nil)

        // Invoke it to verify it's the right closure
        let dummyBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 16, alignment: 1)
        defer { dummyBuffer.deallocate() }
        config.processCallback?(dummyBuffer, Self.stereo16)
        #expect(recorder.count == 1)
    }
}

// MARK: - Test helpers

/// Thread-safe recorder for process callback invocations.
private final class CallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _formats: [AudioFormatSpec] = []
    private var _byteCounts: [Int] = []

    func record(byteCount: Int, format: AudioFormatSpec) {
        lock.withLock {
            _formats.append(format)
            _byteCounts.append(byteCount)
        }
    }

    var count: Int {
        lock.withLock { _formats.count }
    }

    var formats: [AudioFormatSpec] {
        lock.withLock { _formats }
    }

    var byteCounts: [Int] {
        lock.withLock { _byteCounts }
    }
}
