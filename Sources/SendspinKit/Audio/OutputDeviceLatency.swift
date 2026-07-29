#if os(macOS)
    import CoreAudio
#elseif canImport(AVFAudio)
    import AVFAudio
#endif

/// Latency of the audio path beyond our own buffers: the HAL, the transport and the DAC.
///
/// `AudioPlayer` models the depth of the AudioQueue buffers it owns, which is exact. Everything
/// downstream of handing a buffer over is not ours to compute, and treating it as zero
/// understates how far ahead of the speaker we are — on a USB DAC, by roughly 15ms.
///
/// There is no Audio Queue property for this. macOS answers through the HAL; the session-based
/// platforms answer through `AVAudioSession`. Where neither applies the value is zero, which
/// leaves behaviour exactly as it is rather than guessing.
enum OutputDeviceLatency {
    /// Total latency of the current output device in microseconds, or zero if it cannot be read.
    ///
    /// Read at stream start and whenever the output device changes: the dominant term is the
    /// HAL buffer size, which is a property of the route rather than a constant.
    static func currentMicroseconds() -> Int64 {
        #if os(macOS)
            return macOSOutputLatencyMicroseconds()
        #elseif canImport(AVFAudio)
            // `outputLatency` is seconds, and covers the same span the HAL sum does.
            return Int64(AVAudioSession.sharedInstance().outputLatency * 1_000_000)
        #else
            return 0
        #endif
    }

    #if os(macOS)
        /// Sum of the device's own latency, its safety offset, the IO buffer and the stream's
        /// latency — the four terms CoreAudio separates and nobody totals for you.
        private static func macOSOutputLatencyMicroseconds() -> Int64 {
            guard let device = defaultOutputDevice() else { return 0 }
            let rate = nominalSampleRate(device)
            guard rate > 0 else { return 0 }

            var frames = frameProperty(device, kAudioDevicePropertyLatency)
            frames += frameProperty(device, kAudioDevicePropertySafetyOffset)
            frames += frameProperty(device, kAudioDevicePropertyBufferFrameSize)
            if let stream = firstOutputStream(device) {
                frames += frameProperty(stream, kAudioStreamPropertyLatency, scope: kAudioObjectPropertyScopeGlobal)
            }
            return Int64(Double(frames) / rate * 1_000_000)
        }

        /// The queue reports its device as `AQDefaultDevice`, so it follows this one.
        static func defaultOutputDevice() -> AudioDeviceID? {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var device = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
            )
            return status == noErr ? device : nil
        }

        private static func frameProperty(
            _ object: AudioObjectID,
            _ selector: AudioObjectPropertySelector,
            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
        ) -> UInt32 {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
            )
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            // A property the device does not implement contributes nothing rather than failing
            // the whole measurement.
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
                return 0
            }
            return value
        }

        private static func nominalSampleRate(_ device: AudioDeviceID) -> Float64 {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var rate: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else {
                return 0
            }
            return rate
        }

        private static func firstOutputStream(_ device: AudioDeviceID) -> AudioStreamID? {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
                return nil
            }
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr else {
                return nil
            }
            return streams.first
        }
    #endif
}
