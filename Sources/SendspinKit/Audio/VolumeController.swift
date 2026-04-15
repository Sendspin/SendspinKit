// ABOUTME: Abstraction over software and hardware volume control
// ABOUTME: Detects CoreAudio device capabilities and routes volume/mute commands accordingly

import AudioToolbox
import Foundation
import os

#if os(macOS)
    import CoreAudio
#endif

/// Resolved volume capabilities for the current audio output.
/// Determines what gets advertised in `supported_commands` to the server.
/// When volume is supported, mute is always supported too (we can always
/// zero the output, whether via AudioQueue gain, hardware volume, or
/// hardware mute toggle).
struct VolumeCapabilities {
    /// Whether this device supports volume (and therefore mute) control
    let supportsVolume: Bool

    /// Player commands to advertise in client/hello based on these capabilities
    var playerCommands: [PlayerCommand] {
        supportsVolume ? [.volume, .mute] : []
    }

    static let all = VolumeCapabilities(supportsVolume: true)
    static let unsupported = VolumeCapabilities(supportsVolume: false)
}

/// Protocol for applying volume/mute changes to audio output.
/// Implementations handle software (AudioQueue) vs hardware (CoreAudio device) control.
///
/// **Caller contract:** Volume and mute are separate axes. For `SoftwareVolumeControl`,
/// both map to the same AudioQueue gain parameter, so `setVolume` after `setMute(true)`
/// will effectively unmute. For `HardwareVolumeControl`, mute is an independent hardware
/// toggle — `setVolume` does not affect mute state. The caller (`AudioPlayer`) is
/// responsible for coordinating these correctly (e.g., not calling `setVolume` while muted).
protocol VolumeControl: Sendable {
    /// Set volume (0.0-1.0 linear, implementation applies perceptual curve if needed)
    func setVolume(_ volume: Float, on queue: AudioQueueRef?)
    /// Set mute state
    func setMute(_ muted: Bool, currentVolume: Float, on queue: AudioQueueRef?)
}

// MARK: - Software volume (AudioQueue gain)

/// Controls volume via AudioQueue parameter — works on all platforms.
struct SoftwareVolumeControl: VolumeControl {
    func setVolume(_ volume: Float, on queue: AudioQueueRef?) {
        guard let queue else { return }
        let gain = AudioPlayer.perceptualGain(volume)
        let status = AudioQueueSetParameter(queue, kAudioQueueParam_Volume, gain)
        if status != noErr {
            Log.volume.error("AudioQueueSetParameter failed (OSStatus \(status))")
        }
    }

    func setMute(_ muted: Bool, currentVolume: Float, on queue: AudioQueueRef?) {
        guard let queue else { return }
        let gain = muted ? 0.0 : AudioPlayer.perceptualGain(currentVolume)
        let status = AudioQueueSetParameter(queue, kAudioQueueParam_Volume, gain)
        if status != noErr {
            Log.volume.error("AudioQueueSetParameter (mute) failed (OSStatus \(status))")
        }
    }
}

// MARK: - Hardware volume (CoreAudio device properties, macOS only)

#if os(macOS)

    /// Controls volume via CoreAudio hardware device properties.
    /// Mute uses the hardware mute property if available, otherwise zeros
    /// the hardware volume and restores on unmute.
    struct HardwareVolumeControl: VolumeControl {
        func setVolume(_ volume: Float, on _: AudioQueueRef?) {
            let deviceID = Self.defaultOutputDevice()
            guard deviceID != kAudioObjectUnknown else { return }
            // Apply the same perceptual gain curve as software volume so that
            // volume 50% sounds equally loud regardless of volume mode.
            let gain = AudioPlayer.perceptualGain(max(0.0, min(1.0, volume)))
            Self.setVolumeOnDevice(gain, device: deviceID)
        }

        func setMute(_ muted: Bool, currentVolume: Float, on _: AudioQueueRef?) {
            let deviceID = Self.defaultOutputDevice()
            guard deviceID != kAudioObjectUnknown else { return }

            // Prefer hardware mute toggle if available
            if Self.deviceHasProperty(deviceID, selector: kAudioDevicePropertyMute) {
                var muteValue: UInt32 = muted ? 1 : 0
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyMute,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: kAudioObjectPropertyElementMain
                )
                let status = AudioObjectSetPropertyData(
                    deviceID, &address, 0, nil,
                    UInt32(MemoryLayout<UInt32>.size), &muteValue
                )
                if status != noErr {
                    Log.volume.error("Hardware mute failed (OSStatus \(status))")
                }
            } else {
                // No hardware mute — fake it by zeroing/restoring volume.
                // Apply perceptual curve for consistency with setVolume.
                let gain = muted ? Float(0.0) : AudioPlayer.perceptualGain(max(0.0, min(1.0, currentVolume)))
                Self.setVolumeOnDevice(gain, device: deviceID)
            }
        }

        // MARK: - CoreAudio helpers

        static func defaultOutputDevice() -> AudioDeviceID {
            var deviceID = AudioDeviceID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address, 0, nil, &size, &deviceID
            )
            return status == noErr ? deviceID : AudioDeviceID(kAudioObjectUnknown)
        }

        /// Check if a device supports a specific property.
        static func deviceHasProperty(
            _ device: AudioDeviceID,
            selector: AudioObjectPropertySelector,
            channel: UInt32 = 0
        ) -> Bool {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: channel
            )
            return AudioObjectHasProperty(device, &address)
        }

        /// Query whether the default output device supports hardware volume control.
        /// If volume is supported, mute is always available (via hardware toggle or
        /// by zeroing the volume).
        static func queryCapabilities() -> VolumeCapabilities {
            let deviceID = defaultOutputDevice()
            guard deviceID != kAudioObjectUnknown else {
                return .unsupported
            }

            // Check master channel first, then individual channels
            let hasVolume = deviceHasProperty(deviceID, selector: kAudioDevicePropertyVolumeScalar, channel: 0)
                || deviceHasProperty(deviceID, selector: kAudioDevicePropertyVolumeScalar, channel: 1)

            return VolumeCapabilities(supportsVolume: hasVolume)
        }

        /// Set volume on a device, trying master channel first, falling back to L+R.
        private static func setVolumeOnDevice(_ volume: Float, device: AudioDeviceID) {
            if !setVolumeScalar(volume, device: device, channel: 0) {
                setVolumeScalar(volume, device: device, channel: 1)
                setVolumeScalar(volume, device: device, channel: 2)
            }
        }

        @discardableResult
        private static func setVolumeScalar(_ volume: Float, device: AudioDeviceID, channel: UInt32) -> Bool {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: channel
            )

            guard AudioObjectHasProperty(device, &address) else { return false }

            var value = volume
            let status = AudioObjectSetPropertyData(
                device, &address, 0, nil,
                UInt32(MemoryLayout<Float32>.size), &value
            )
            return status == noErr
        }
    }

#endif

// MARK: - Factory

/// Resolve the volume mode into concrete capabilities and control implementation.
enum VolumeControlFactory {
    static func resolve(mode: VolumeMode) -> (capabilities: VolumeCapabilities, control: VolumeControl) {
        switch mode {
        case .software:
            return (.all, SoftwareVolumeControl())

        case .none:
            // No commands advertised, but still use software control internally
            // (the server just won't send volume/mute commands)
            return (.unsupported, SoftwareVolumeControl())

        case .hardware:
            #if os(macOS)
                let caps = HardwareVolumeControl.queryCapabilities()
                return (caps, HardwareVolumeControl())
            #else
                // iOS/tvOS/watchOS don't expose per-device volume via CoreAudio.
                // Fall back to software control.
                Log.volume.notice("Hardware volume requested but unavailable on this platform, using software")
                return (.all, SoftwareVolumeControl())
            #endif
        }
    }
}
