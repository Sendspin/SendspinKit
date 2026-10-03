import AudioToolbox
import Darwin

struct CallbackDepthTelemetry: Sendable {
    var minimum: Int64 = 0
    var last: Int64 = 0
    var maximum: Int64 = 0
    var delayFrames: Int64 = 0
    var timeCostUs: Int64 = 0
    var samples: Int64 = 0
    var prewarmSkipped: Int64 = 0
    var zeroPlayedSkipped: Int64 = 0

    static func measuredDepth(total: Int64, played: Int64, previous: inout Int64?) -> Int64? {
        if played > 0 {
            previous = max(0, total - played)
        }
        return previous
    }

    static func depth(total: Int64, played: Int64, bufferFrames: Int64) -> (inFlight: Int64, delay: Int64) {
        let inFlight = max(0, total - played)
        let delay = max(0, Int64(audioQueueBufferCount - 1) * bufferFrames - inFlight)
        return (inFlight, delay)
    }

    mutating func record(total: Int64, played: Int64, bufferFrames: Int64, costUs: Int64, prewarming: Bool) {
        timeCostUs = max(timeCostUs, costUs)
        if prewarming {
            prewarmSkipped += 1
        } else if played == 0 {
            zeroPlayedSkipped += 1
        } else {
            let value = Self.depth(total: total, played: played, bufferFrames: bufferFrames)
            minimum = samples == 0 ? value.inFlight : min(minimum, value.inFlight)
            maximum = max(maximum, value.inFlight)
            last = value.inFlight
            delayFrames = max(delayFrames, value.delay)
            samples += 1
        }
    }
}

struct QueueTimelineTelemetry: Sendable {
    var deviceDeltaFrames: Double?
    var hostLagUs: Double?
    var deviceStatus: OSStatus = noErr
    var queueStatus: OSStatus = noErr
    var translateStatus: OSStatus = noErr
    var deviceFlags: UInt32 = 0
    var translatedFlags: UInt32 = 0

    static func read(queue: AudioQueueRef) -> Self {
        var result = Self()
        var device = AudioTimeStamp()
        var current = AudioTimeStamp()
        var translated = AudioTimeStamp()
        translated.mFlags = [.sampleTimeValid, .hostTimeValid]
        result.deviceStatus = AudioQueueDeviceGetCurrentTime(queue, &device)
        result.deviceFlags = device.mFlags.rawValue
        result.queueStatus = AudioQueueGetCurrentTime(queue, nil, &current, nil)
        let now = mach_absolute_time()
        if result.queueStatus == noErr {
            // Queue and device sample times have different origins; host time joins their timelines.
            var hostTimestamp = current
            hostTimestamp.mFlags = current.mFlags.intersection(.hostTimeValid)
            result.translateStatus = AudioQueueDeviceTranslateTime(queue, &hostTimestamp, &translated)
            if current.mFlags.contains(.hostTimeValid) {
                var timebase = mach_timebase_info_data_t()
                mach_timebase_info(&timebase)
                let ticks = Double(now) - Double(current.mHostTime)
                result.hostLagUs = ticks * Double(timebase.numer) / Double(timebase.denom) / 1_000
            }
            if result.deviceStatus == noErr, result.translateStatus == noErr,
               device.mFlags.contains(.sampleTimeValid), translated.mFlags.contains(.sampleTimeValid) {
                result.deviceDeltaFrames = translated.mSampleTime - device.mSampleTime
            }
        }
        result.translatedFlags = translated.mFlags.rawValue
        return result
    }
}
