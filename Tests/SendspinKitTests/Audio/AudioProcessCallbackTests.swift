import Foundation
@testable import SendspinKit
import Testing

struct AudioProcessCallbackTests {
    /// Standard test format used across all tests in this suite
    private static let stereo16 = AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)

    // MARK: - Callback invocation

    @Test
    func `Callback is invoked during playback`() async throws {
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

        // AudioQueue callbacks are asynchronous — give a brief window for them to fire
        try await Task.sleep(for: .milliseconds(500))

        #expect(invoked.count > 0, "Process callback should have been invoked at least once")

        await player.stop()
    }

    @Test
    func `Callback receives correct format for 16-bit stereo`() async throws {
        let invoked = CallbackRecorder()

        let player = AudioPlayer(
            processCallback: { samples, format in
                invoked.record(byteCount: samples.count, format: format)
            }
        )

        try await player.start(format: Self.stereo16, codecHeader: nil)

        let pcmData = Data(repeating: 0, count: 48_000 * 4)
        try await player.playPCM(pcmData, serverTimestamp: 0)
        try await Task.sleep(for: .milliseconds(500))

        let formats = invoked.formats
        #expect(!formats.isEmpty, "Should have recorded at least one callback")

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
    func `Callback receives 32-bit effective format for 24-bit source`() async throws {
        let invoked = CallbackRecorder()

        let format24 = AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 24)

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
        try await Task.sleep(for: .milliseconds(500))

        let formats = invoked.formats
        #expect(!formats.isEmpty)

        if let format = formats.first {
            #expect(format.bitDepth == 32, "24-bit source should report 32-bit effective output")
        }

        await player.stop()
    }

    @Test
    func `Callback receives mutable buffer`() async throws {
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
        try await Task.sleep(for: .milliseconds(500))

        // If we got here without crashing, the mutable access worked
        #expect(modified.count > 0, "Callback with mutation should have fired")

        await player.stop()
    }

    @Test
    func `Callback fires even with empty ring buffer (silence)`() async throws {
        let invoked = CallbackRecorder()

        let player = AudioPlayer(
            processCallback: { samples, format in
                invoked.record(byteCount: samples.count, format: format)
            }
        )

        // Start playback but don't feed any PCM data — the AudioQueue
        // will callback with silence-filled buffers
        try await player.start(format: Self.stereo16, codecHeader: nil)
        try await Task.sleep(for: .milliseconds(500))

        #expect(invoked.count > 0, "Callback should fire during silence (underrun)")

        await player.stop()
    }

    @Test
    func `Buffer byte count matches AudioQueue buffer size`() async throws {
        let invoked = CallbackRecorder()

        let player = AudioPlayer(
            processCallback: { samples, _ in
                invoked.record(byteCount: samples.count, format: Self.stereo16)
            }
        )

        try await player.start(format: Self.stereo16, codecHeader: nil)

        let pcmData = Data(repeating: 0, count: 48_000 * 4)
        try await player.playPCM(pcmData, serverTimestamp: 0)
        try await Task.sleep(for: .milliseconds(500))

        let byteCounts = invoked.byteCounts
        #expect(!byteCounts.isEmpty)

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
    func `Player works fine without a process callback`() async throws {
        let player = AudioPlayer(
            // no processCallback
        )

        try await player.start(format: Self.stereo16, codecHeader: nil)

        let pcmData = Data(repeating: 0, count: 48_000 * 4)
        try await player.playPCM(pcmData, serverTimestamp: 0)
        try await Task.sleep(for: .milliseconds(200))

        let isPlaying = await player.isPlaying
        #expect(isPlaying == true)

        await player.stop()
    }

    // MARK: - PlayerConfiguration integration

    @Test
    func `PlayerConfiguration defaults to nil processCallback`() {
        let config = PlayerConfiguration(
            bufferCapacity: 1_024,
            supportedFormats: [Self.stereo16]
        )
        #expect(config.processCallback == nil)
    }

    @Test
    func `PlayerConfiguration stores processCallback`() {
        let recorder = CallbackRecorder()
        let config = PlayerConfiguration(
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
