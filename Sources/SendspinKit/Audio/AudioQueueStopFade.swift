import AudioToolbox
import Foundation

/// Queue-local gain is downstream of queued PCM and independent of device volume.
enum AudioQueueStopFade {
    static let durationSeconds: Float32 = 0.005
    static let maximumSettleMicroseconds: Int64 = 250_000

    static func begin(setParameter: (AudioQueueParameterID, AudioQueueParameterValue) -> OSStatus) -> OSStatus {
        let status = setParameter(kAudioQueueParam_VolumeRampTime, durationSeconds)
        guard status == noErr else { return status }
        return setParameter(kAudioQueueParam_Volume, 0)
    }

    static func settlingDuration(deviceLatencyMicroseconds: Int64) -> Duration {
        // Allow a render quantum to observe the request, then let the faded samples reach output.
        let latency = min(maximumSettleMicroseconds, max(0, deviceLatencyMicroseconds))
        let rampMicroseconds = Int64(Double(durationSeconds) * 1_000_000)
        return .microseconds(min(maximumSettleMicroseconds, rampMicroseconds + max(20_000, 2 * latency)))
    }
}

extension AudioOutput {
    func stopAfterFade() async {
        await stop()
    }
}
