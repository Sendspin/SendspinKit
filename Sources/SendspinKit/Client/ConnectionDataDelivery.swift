import Foundation

/// Selects whether a connection's role data is visible on the facade.
enum ConnectionDeliveryMode: Sendable {
    case parked
    case primary
}

/// Owns role-data destinations for one connection. A parked connection consumes
/// protocol data but suppresses public delivery until the facade promotes it.
final class ConnectionDataDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var mode: ConnectionDeliveryMode = .parked

    private let audio: AsyncStream<AudioChunk>.Continuation
    private let artwork: AsyncStream<ArtworkData>.Continuation
    private let visualizer: VisualizerFrameMailbox
    private let artworkObserver: (@Sendable (ArtworkData, SessionValidityToken) -> Void)?

    init(
        audio: AsyncStream<AudioChunk>.Continuation,
        artwork: AsyncStream<ArtworkData>.Continuation,
        visualizer: VisualizerFrameMailbox,
        artworkObserver: (@Sendable (ArtworkData, SessionValidityToken) -> Void)?
    ) {
        self.audio = audio
        self.artwork = artwork
        self.visualizer = visualizer
        self.artworkObserver = artworkObserver
    }

    func promoteToPrimary() {
        lock.withLock { mode = .primary }
    }

    func park() {
        lock.withLock { mode = .parked }
    }

    func yieldAudioIfValid(_ value: AudioChunk, validity: SessionValidityToken) {
        lock.withLock {
            guard mode == .primary else { return }
            validity.yieldIfValid(value, to: audio)
        }
    }

    func yieldArtworkIfValid(_ value: ArtworkData, validity: SessionValidityToken, deliveryValidity: SessionValidityToken) {
        lock.withLock {
            guard mode == .primary else { return }
            artworkObserver?(value, deliveryValidity)
            deliveryValidity.performSendableIfValid {
                validity.yieldIfValid(value, to: artwork)
            }
        }
    }

    func offerVisualizerIfValid(_ value: VisualizerFrame, validity: SessionValidityToken) {
        lock.withLock {
            guard mode == .primary else { return }
            validity.offerIfValid(value, to: visualizer)
        }
    }

    func clearVisualizer() {
        lock.withLock {
            guard mode == .primary else { return }
            visualizer.clear()
        }
    }
}
