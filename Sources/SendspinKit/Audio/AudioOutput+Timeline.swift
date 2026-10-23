import Foundation

extension AudioOutput {
    func playPCM(_ pcm: Data, serverTimestamp: Int64, playTimeMicroseconds: Int64?) async throws {
        try await playPCM(
            pcm, serverTimestamp: serverTimestamp, playTimeMicroseconds: playTimeMicroseconds,
            timelineAdjustmentUs: nil
        )
    }
}
