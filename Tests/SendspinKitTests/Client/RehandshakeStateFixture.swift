import Foundation
@testable import SendspinKit

extension SendspinConnection {
    func prepareRehandshakeAudioIngress(format: AudioFormatSpec) {
        isClockSynced = true
        playerStateSent = true
        playerStreamActive = true
        announcedPlayerStream = (format, nil)
        audioEngine.enqueueStreamStart(format: format, codecHeader: nil)
    }

    func seedRehandshakeStreamState(format: AudioFormatSpec) {
        playerStreamActive = true
        playerStateSent = true
        announcedPlayerStream = (format, nil)
        let channel = 0
        let totalSize: UInt32 = 2
        artworkTransfer = ArtworkTransfer(channel: channel, timestamp: 0, totalSize: totalSize, deliver: true)
        artworkTransfer?.received = 1
        artworkTransfer?.data = Data([BinaryMessageType.audioChunk.rawValue])
        pairingActivateCounter = 2
    }
}
