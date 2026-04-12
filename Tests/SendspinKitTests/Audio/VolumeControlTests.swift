import AudioToolbox
import Foundation
@testable import SendspinKit
import Testing

@Suite("Volume Control")
struct VolumeControlTests {

    // MARK: - VolumeCapabilities

    @Test("VolumeCapabilities.all advertises volume and mute")
    func capabilitiesAll() {
        let caps = VolumeCapabilities.all
        #expect(caps.supportsVolume == true)
        #expect(caps.playerCommands == [.volume, .mute])
    }

    @Test("VolumeCapabilities.none advertises nothing")
    func capabilitiesNone() {
        let caps = VolumeCapabilities.none
        #expect(caps.supportsVolume == false)
        #expect(caps.playerCommands.isEmpty)
    }

    // MARK: - VolumeControlFactory

    @Test("Software mode resolves to full capabilities")
    func factorySoftware() {
        let (caps, control) = VolumeControlFactory.resolve(mode: .software)
        #expect(caps.supportsVolume == true)
        #expect(caps.playerCommands == [.volume, .mute])
        #expect(control is SoftwareVolumeControl)
    }

    @Test("None mode resolves to no capabilities but still has control")
    func factoryNone() {
        let (caps, control) = VolumeControlFactory.resolve(mode: .none)
        #expect(caps.supportsVolume == false)
        #expect(caps.playerCommands.isEmpty)
        // Still uses software control internally (for any programmatic volume)
        #expect(control is SoftwareVolumeControl)
    }

    @Test("Hardware mode resolves on this platform")
    func factoryHardware() {
        let (caps, control) = VolumeControlFactory.resolve(mode: .hardware)
        // On macOS: should detect hardware capabilities from default output device
        // On iOS: falls back to software
        #if os(macOS)
            // We can't guarantee hardware volume on CI, but it should at least resolve
            #expect(control is HardwareVolumeControl)
            // Most macOS devices (built-in speakers, headphones) do support volume
            // but we don't hard-assert since CI might be headless
            _ = caps // silence unused warning
        #else
            #expect(caps.supportsVolume == true) // iOS fallback = software = all
            #expect(control is SoftwareVolumeControl)
        #endif
    }

    // MARK: - SoftwareVolumeControl

    @Test("SoftwareVolumeControl handles nil queue gracefully")
    func softwareNilQueue() {
        let control = SoftwareVolumeControl()
        // Should not crash with nil queue
        control.setVolume(0.5, on: nil)
        control.setMute(true, currentVolume: 0.5, on: nil)
        control.setMute(false, currentVolume: 0.5, on: nil)
    }

    // MARK: - PlayerConfiguration VolumeMode

    @Test("PlayerConfiguration defaults to software volume mode")
    func configDefaultsToSoftware() {
        let config = PlayerConfiguration(
            bufferCapacity: 1024,
            supportedFormats: [AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16)]
        )
        switch config.volumeMode {
        case .software: break // expected
        default: Issue.record("Expected .software, got \(config.volumeMode)")
        }
    }

    @Test("PlayerConfiguration accepts explicit volume mode")
    func configExplicitVolumeMode() {
        let config = PlayerConfiguration(
            bufferCapacity: 1024,
            supportedFormats: [AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16)],
            volumeMode: .none
        )
        switch config.volumeMode {
        case .none: break // expected
        default: Issue.record("Expected .none, got \(config.volumeMode)")
        }
    }

    // MARK: - Integration: AudioPlayer with VolumeControl

    @Test("AudioPlayer uses provided VolumeControl for volume")
    func audioPlayerUsesVolumeControl() async throws {
        let recorder = RecordingVolumeControl()
        let bufferManager = BufferManager(capacity: 1024)
        let clockSync = ClockSynchronizer()
        let player = AudioPlayer(
            bufferManager: bufferManager,
            clockSync: clockSync,
            volumeControl: recorder
        )

        let format = AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16)
        try await player.start(format: format, codecHeader: nil)

        await player.setVolume(0.75)
        let calls = recorder.calls
        #expect(calls.contains { $0.starts(with: "setVolume(0.75") })

        await player.stop()
    }

    @Test("AudioPlayer uses provided VolumeControl for mute")
    func audioPlayerUsesVolumeControlForMute() async throws {
        let recorder = RecordingVolumeControl()
        let bufferManager = BufferManager(capacity: 1024)
        let clockSync = ClockSynchronizer()
        let player = AudioPlayer(
            bufferManager: bufferManager,
            clockSync: clockSync,
            volumeControl: recorder
        )

        let format = AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16)
        try await player.start(format: format, codecHeader: nil)

        await player.setMute(true)
        let calls = recorder.calls
        #expect(calls.contains { $0.starts(with: "setMute(true") })

        await player.stop()
    }

    @Test("AudioPlayer does not call setVolume when muted")
    func audioPlayerSkipsVolumeWhenMuted() async throws {
        let recorder = RecordingVolumeControl()
        let bufferManager = BufferManager(capacity: 1024)
        let clockSync = ClockSynchronizer()
        let player = AudioPlayer(
            bufferManager: bufferManager,
            clockSync: clockSync,
            volumeControl: recorder
        )

        let format = AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16)
        try await player.start(format: format, codecHeader: nil)

        await player.setMute(true)
        recorder.calls.removeAll()

        // Setting volume while muted should NOT call setVolume on the control
        await player.setVolume(0.5)
        #expect(!recorder.calls.contains { $0.starts(with: "setVolume") })

        await player.stop()
    }

    #if os(macOS)
    // MARK: - HardwareVolumeControl (macOS only)

    @Test("HardwareVolumeControl can query default output device")
    func hardwareDefaultDevice() {
        let deviceID = HardwareVolumeControl.defaultOutputDevice()
        // On a real macOS system, there should be a default output device
        // On headless CI, this might be kAudioObjectUnknown
        _ = deviceID // just verify it doesn't crash
    }

    @Test("HardwareVolumeControl.queryCapabilities does not crash")
    func hardwareQueryCapabilities() {
        let caps = HardwareVolumeControl.queryCapabilities()
        // Just verify it returns something reasonable without crashing
        _ = caps.supportsVolume
        _ = caps.playerCommands
    }
    #endif
}

// MARK: - Test helpers

/// A VolumeControl that records calls for verification in tests.
private final class RecordingVolumeControl: VolumeControl, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []

    var calls: [String] {
        get { lock.withLock { _calls } }
        set { lock.withLock { _calls = newValue } }
    }

    func setVolume(_ volume: Float, on queue: AudioQueueRef?) {
        lock.withLock {
            _calls.append("setVolume(\(volume), queue: \(queue != nil ? "non-nil" : "nil"))")
        }
        // Also apply to queue so AudioPlayer's behavior is realistic
        if let queue {
            AudioQueueSetParameter(queue, kAudioQueueParam_Volume, AudioPlayer.perceptualGain(volume))
        }
    }

    func setMute(_ muted: Bool, currentVolume: Float, on queue: AudioQueueRef?) {
        lock.withLock {
            _calls.append("setMute(\(muted), currentVolume: \(currentVolume), queue: \(queue != nil ? "non-nil" : "nil"))")
        }
        if let queue {
            let gain = muted ? Float(0.0) : AudioPlayer.perceptualGain(currentVolume)
            AudioQueueSetParameter(queue, kAudioQueueParam_Volume, gain)
        }
    }
}
