// ABOUTME: Abstraction over software and hardware volume control
// ABOUTME: Detects CoreAudio device capabilities and routes volume/mute commands accordingly

import AudioToolbox
import Foundation

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
    static let none = VolumeCapabilities(supportsVolume: false)
}

/// Protocol for applying volume/mute changes to audio output.
/// Implementations handle software (AudioQueue) vs hardware (CoreAudio device) control.
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
        AudioQueueSetParameter(queue, kAudioQueueParam_Volume, gain)
    }

    func setMute(_ muted: Bool, currentVolume: Float, on queue: AudioQueueRef?) {
        guard let queue else { return }
        let gain = muted ? Float(0.0) : AudioPlayer.perceptualGain(currentVolume)
        AudioQueueSetParameter(queue, kAudioQueueParam_Volume, gain)
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

            // Set volume on the master channel (0), falling back to channels 1+2
            let clamped = max(0.0, min(1.0, volume))
            if !Self.setVolumeScalar(clamped, device: deviceID, channel: 0) {
                // Some devices don't have a master channel — set L+R individually
                Self.setVolumeScalar(clamped, device: deviceID, channel: 1)
                Self.setVolumeScalar(clamped, device: deviceID, channel: 2)
            }
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
                AudioObjectSetPropertyData(
                    deviceID, &address, 0, nil,
                    UInt32(MemoryLayout<UInt32>.size), &muteValue
                )
            } else {
                // No hardware mute — fake it by zeroing/restoring volume
                let target: Float = muted ? 0.0 : currentVolume
                if !Self.setVolumeScalar(target, device: deviceID, channel: 0) {
                    Self.setVolumeScalar(target, device: deviceID, channel: 1)
                    Self.setVolumeScalar(target, device: deviceID, channel: 2)
                }
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
                return .none
            }

            // Check master channel first, then individual channels
            let hasVolume = deviceHasProperty(deviceID, selector: kAudioDevicePropertyVolumeScalar, channel: 0)
                || deviceHasProperty(deviceID, selector: kAudioDevicePropertyVolumeScalar, channel: 1)

            return VolumeCapabilities(supportsVolume: hasVolume)
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
            return (.none, SoftwareVolumeControl())

        case .hardware:
            #if os(macOS)
                let caps = HardwareVolumeControl.queryCapabilities()
                return (caps, HardwareVolumeControl())
            #else
                // iOS/tvOS/watchOS don't expose per-device volume via CoreAudio.
                // Fall back to software control.
                return (.all, SoftwareVolumeControl())
            #endif
        }
    }
}
