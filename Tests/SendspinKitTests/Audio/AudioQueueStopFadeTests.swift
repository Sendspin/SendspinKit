import AudioToolbox
@testable import SendspinKit
import Testing

struct AudioQueueStopFadeTests {
    @Test
    func configuresNativeRampBeforeSilencingOnlyThisQueue() {
        var parameters: [AudioQueueParameterID] = []
        var values: [AudioQueueParameterValue] = []
        let status = AudioQueueStopFade.begin { parameter, value in
            parameters.append(parameter)
            values.append(value)
            return noErr
        }
        #expect(status == noErr)
        #expect(parameters == [kAudioQueueParam_VolumeRampTime, kAudioQueueParam_Volume])
        #expect(values == [AudioQueueStopFade.durationSeconds, 0])
        #expect(AudioQueueStopFade.durationSeconds > 0)
    }

    @Test
    func rejectedRampDoesNotApplyAbruptGainChange() {
        var parameters: [AudioQueueParameterID] = []
        let failure = kAudioQueueErr_InvalidParameter
        let status = AudioQueueStopFade.begin { parameter, _ in
            parameters.append(parameter)
            return failure
        }
        #expect(status == failure)
        #expect(parameters == [kAudioQueueParam_VolumeRampTime])
    }

    @Test
    func propagatesGainFailure() {
        let failure = kAudioQueueErr_InvalidQueueType
        let status = AudioQueueStopFade.begin { parameter, _ in
            parameter == kAudioQueueParam_Volume ? failure : noErr
        }
        #expect(status == failure)
    }

    @Test
    func settlingCoversRampAndDevicePathButIsBounded() {
        let minimum = AudioQueueStopFade.settlingDuration(deviceLatencyMicroseconds: 0)
        #expect(minimum > .seconds(Double(AudioQueueStopFade.durationSeconds)))
        #expect(AudioQueueStopFade.settlingDuration(deviceLatencyMicroseconds: -1) == minimum)
        #expect(AudioQueueStopFade.settlingDuration(deviceLatencyMicroseconds: 30_000) > minimum)
        #expect(AudioQueueStopFade.settlingDuration(deviceLatencyMicroseconds: .max)
            == .microseconds(AudioQueueStopFade.maximumSettleMicroseconds))
    }
}
