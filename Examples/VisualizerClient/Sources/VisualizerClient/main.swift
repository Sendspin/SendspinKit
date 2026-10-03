import CoreVideo
import Foundation
import Observation
import SendspinKit
import SwiftUI
import VisualizerClientCore

private enum LaunchParseError: Error {
    case message(String)
}

private struct LaunchOptions: Sendable {
    let server: String?
    let discover: Bool
    let timeout: Double
    let name: String
    let pairing: Bool

    static func parse(_ arguments: ArraySlice<String>) -> Result<Self, LaunchParseError> {
        var server: String?
        var discover = false
        var timeout = 5.0
        var name = "Visualizer Client"
        var pairing = false
        var iterator = arguments.makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--server":
                guard let value = iterator.next() else { return .failure(.message("--server needs a URL")) }
                server = value
            case "--discover":
                discover = true
            case "--timeout":
                guard let value = iterator.next(), let parsed = Double(value), parsed > 0 else {
                    return .failure(.message("--timeout needs a positive number of seconds"))
                }
                timeout = parsed
            case "--name":
                guard let value = iterator.next(), !value.isEmpty else { return .failure(.message("--name needs a value")) }
                name = value
            case "--pairing":
                pairing = true
            case "--help", "-h":
                return .failure(.message(Self.usage))
            default:
                return .failure(.message("Unknown argument: \(argument)\n\n\(Self.usage)"))
            }
        }

        guard discover || server != nil else {
            return .failure(.message("Provide --server <url> or --discover\n\n\(Self.usage)"))
        }
        guard !(discover && server != nil) else {
            return .failure(.message("Choose either --server or --discover\n\n\(Self.usage)"))
        }
        return .success(Self(server: server, discover: discover, timeout: timeout, name: name, pairing: pairing))
    }

    static let usage = """
    Usage: VisualizerClient --server <ws-url> [--name <name>] [--pairing]
           VisualizerClient --discover [--timeout <seconds>] [--name <name>] [--pairing]
    """
}

private final class DisplayLinkCallbackToken: @unchecked Sendable {
    private let lock = NSLock()
    private let callback: @MainActor () -> Void
    private var stopped = false
    private var callbackQueued = false
    private var releaseWhenIdle: (() -> Void)?

    init(callback: @escaping @MainActor () -> Void) {
        self.callback = callback
    }

    func setReleaseWhenIdle(_ release: @escaping () -> Void) {
        lock.withLock {
            releaseWhenIdle = release
            releaseIfIdleLocked()
        }
    }

    func invoke() {
        let callbackToDeliver = lock.withLock { () -> (@MainActor () -> Void)? in
            guard !stopped, !callbackQueued else { return nil }
            callbackQueued = true
            return callback
        }
        guard let callbackToDeliver else { return }

        DispatchQueue.main.async { [self] in
            let shouldDeliver = lock.withLock { !stopped }
            if shouldDeliver { callbackToDeliver() }
            didDeliver()
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            releaseIfIdleLocked()
        }
    }

    private func didDeliver() {
        lock.withLock {
            callbackQueued = false
            releaseIfIdleLocked()
        }
    }

    private func releaseIfIdleLocked() {
        guard stopped, !callbackQueued, let releaseWhenIdle else { return }
        self.releaseWhenIdle = nil
        releaseWhenIdle()
    }
}

@MainActor
private final class DisplayLinkDriver {
    private nonisolated(unsafe) var link: CVDisplayLink?
    private var callbackContext: Unmanaged<DisplayLinkCallbackToken>?
    private var isStopped = false

    init(callback: @escaping @MainActor () -> Void) {
        var created: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&created)
        link = created
        guard let link else { return }

        let token = DisplayLinkCallbackToken(callback: callback)
        let retained = Unmanaged.passRetained(token)
        callbackContext = retained
        token.setReleaseWhenIdle { retained.release() }
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, context in
            guard let context else { return kCVReturnSuccess }
            Unmanaged<DisplayLinkCallbackToken>.fromOpaque(context).takeUnretainedValue().invoke()
            return kCVReturnSuccess
        }, retained.toOpaque())
    }

    func start() {
        guard let link, !isStopped else { return }
        CVDisplayLinkStart(link)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        if let link {
            CVDisplayLinkStop(link)
            CVDisplayLinkSetOutputCallback(link, nil, nil)
        }
        callbackContext?.takeUnretainedValue().stop()
        callbackContext = nil
        link = nil
    }

    deinit {
        if let link {
            CVDisplayLinkStop(link)
            CVDisplayLinkSetOutputCallback(link, nil, nil)
        }
        callbackContext?.takeUnretainedValue().stop()
    }
}

@MainActor
@Observable
private final class VisualizerAppModel {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
        case closed
    }

    private(set) var phase: Phase = .idle
    private(set) var serverName = ""
    private(set) var pairingSnapshot: PairingAttemptSnapshot?
    private(set) var pairingWindow: PairingWindowSnapshot?
    private(set) var pairingMessage = ""
    private(set) var loudness: Double = 0
    private(set) var spectrum = [Double]()
    private(set) var lastPresentedType: VisualizerType?
    private(set) var lastPresentationTime: PresentationInstant?
    private(set) var displayTickCount = 0

    private let options: LaunchOptions
    private let presentationClock = PresentationClock()
    private var client: SendspinClient?
    private var subscription: VisualizerFrameSubscription?
    private var consumerTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var displayLink: DisplayLinkDriver?
    private var scheduler = VisualizerPresentationScheduler(capacityBytes: 65_536)
    private var hasStarted = false

    init(options: LaunchOptions) {
        self.options = options
    }

    var statusText: String {
        switch phase {
        case .idle: return "Ready"
        case .connecting: return "Connecting…"
        case .connected: return serverName.isEmpty ? "Connected" : "Connected to \(serverName)"
        case let .failed(message): return "Error: \(message)"
        case .closed: return "Closed"
        }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        phase = .connecting

        do {
            let url = try await SendspinClient.resolveServerURL(
                server: options.server,
                discover: options.discover,
                timeout: .milliseconds(Int(options.timeout * 1_000))
            )
            // Ephemeral demo device: identity and pairing state vanish when the process exits.
            let device = SendspinDevice.ephemeral()
            let pairing: PairingPresentation = options.pairing ? .display : .tokenOnly
            if options.pairing {
                let token = device.makePairingToken()
                print("Pairing token (a real app pairs from a durable device): \(token.string)")
            }

            let visualizer = try VisualizerConfiguration(
                types: [.loudness, .spectrum],
                rateMax: 30,
                spectrum: SpectrumConfiguration(nDispBins: 32, scale: .log, fMin: 60, fMax: 16_000),
                bufferCapacity: 65_536
            )
            scheduler = VisualizerPresentationScheduler(capacityBytes: visualizer.bufferCapacity)
            let client = try SendspinClient(
                device: device,
                name: options.name,
                roles: [.visualizerV1, .metadataV1],
                visualizerConfig: visualizer,
                pairing: pairing,
                access: options.pairing ? .pairedOnly : .allowUnpaired
            )
            let subscription = try client.acquireVisualizerFrames()
            self.client = client
            self.subscription = subscription
            startEventTask(client: client)
            startFrameTask(subscription: subscription)
            displayLink = DisplayLinkDriver { [weak self] in
                self?.displayTick()
            }
            displayLink?.start()
            try await client.connect(to: url)
        } catch {
            let message = error.localizedDescription
            await close()
            phase = .failed(message)
        }
    }

    private func startEventTask(client: SendspinClient) {
        eventTask = Task { @MainActor [weak self] in
            for await event in client.events() {
                guard let self else { return }
                switch event {
                case let .serverConnected(info):
                    serverName = info.name
                    phase = .connected
                case let .pairingCodeChanged(snapshot):
                    pairingSnapshot = snapshot
                    pairingMessage = snapshot.code.map { "\($0.format.rawValue): \($0.payload)" } ?? "Code cleared"
                case let .pairingAttemptEnded(snapshot):
                    pairingSnapshot = snapshot
                    pairingWindow = client.pairingWindow
                    pairingMessage = "Attempt ended: \(snapshot.phase)"
                case .pairingAttemptSuperseded:
                    pairingSnapshot = client.currentPairing
                    pairingWindow = client.pairingWindow
                    pairingMessage = "Pairing attempt superseded"
                case let .streamEnded(roles):
                    if roles == nil || roles?.contains(StreamRole.visualizer.rawValue) == true {
                        clearPresentedVisualizer()
                    }
                case let .streamCleared(roles):
                    if roles == nil || roles?.contains(StreamRole.visualizer.rawValue) == true {
                        clearPresentedVisualizer()
                    }
                case let .paired(snapshot):
                    pairingSnapshot = snapshot
                    pairingMessage = "Paired: \(snapshot.peer.name) (\(snapshot.peer.trustLevel))"
                case let .pairingWindowChanged(window):
                    pairingWindow = window
                case let .disconnected(reason):
                    clearPresentedVisualizer()
                    pairingWindow = nil
                    pairingMessage = "Disconnected: \(reason)"
                    if phase != .closed { phase = .failed("Disconnected: \(reason)") }
                    return
                case .audioOutputChanged, .outputFormatStatusChanged, .streamingFailed,
                     .streamStarted, .streamFormatChanged,
                     .groupUpdated, .metadataReceived, .controllerStateUpdated,
                     .controllerStateCleared, .colorStateUpdated, .colorStateCleared,
                     .artworkStreamStarted, .visualizerStreamStarted, .outputDelayChanged,
                     .lastPlayedServerChanged:
                    break
                }
            }
        }
    }

    private func startFrameTask(subscription: VisualizerFrameSubscription) {
        frameTask(subscription: subscription)
    }

    private func frameTask(subscription: VisualizerFrameSubscription) {
        consumerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await VisualizerFrameIngestor.consume(from: subscription) { frame in
                await MainActor.run {
                    _ = self.scheduler.ingest(frame)
                }
            }
        }
    }

    private func clearPresentedVisualizer() {
        scheduler.reset()
        loudness = 0
        spectrum = []
        lastPresentedType = nil
        lastPresentationTime = nil
    }

    private func displayTick() {
        guard phase != .closed else { return }
        displayTickCount += 1
        let batch = scheduler.tick(at: presentationClock.now)
        for type in batch.clearedTypes {
            clearPresentedFrame(of: type)
        }
        for frame in batch.frames {
            switch frame.type {
            case .loudness:
                loudness = decodeLoudness(frame.data)
            case .spectrum:
                spectrum = decodeSpectrum(frame.data)
            default:
                break
            }
            lastPresentedType = frame.type
            lastPresentationTime = frame.presentationTime
        }
    }

    private func clearPresentedFrame(of type: VisualizerType) {
        switch type {
        case .loudness:
            loudness = 0
        case .spectrum:
            spectrum = []
        default:
            break
        }
        if lastPresentedType == type {
            lastPresentedType = nil
            lastPresentationTime = nil
        }
    }

    func openPairingWindow(for attemptID: PairingAttemptID?) async {
        guard let attemptID, let client else {
            pairingMessage = "No admitted pairing attempt"
            return
        }
        do {
            try await client.openPairingWindow(for: attemptID)
            pairingMessage = "Authorization window requested"
        } catch {
            pairingMessage = error.localizedDescription
        }
    }

    func cancelPairing(attemptID: PairingAttemptID?) async {
        guard let attemptID, let client else {
            pairingMessage = "No admitted pairing attempt"
            return
        }
        do {
            try await client.cancelPairing(attemptID: attemptID)
            pairingMessage = "Cancellation requested"
        } catch {
            pairingMessage = error.localizedDescription
        }
    }

    func close() async {
        guard phase != .closed else { return }
        phase = .closed
        consumerTask?.cancel()
        eventTask?.cancel()
        subscription?.cancel()
        displayLink?.stop()
        displayLink = nil
        clearPresentedVisualizer()
        if let client { await client.close() }
        subscription = nil
        self.client = nil
    }

    func pairingWindowText(for window: PairingWindowSnapshot) -> String {
        let duration = PresentationClock().duration(from: .now, to: window.expiresAt)
        let remaining = duration > .zero ? duration : .zero
        return "Window expires in \(remaining.formatted(.units(allowed: [.minutes, .seconds])))"
    }

    private func decodeLoudness(_ data: Data) -> Double {
        guard data.count == 2 else { return 0 }
        let value = (UInt16(data[data.startIndex]) << 8) | UInt16(data[data.index(data.startIndex, offsetBy: 1)])
        return Double(value) / Double(UInt16.max)
    }

    private func decodeSpectrum(_ data: Data) -> [Double] {
        guard data.count.isMultiple(of: 2) else { return [] }
        return stride(from: 0, to: data.count, by: 2).map { offset in
            let high = UInt16(data[data.index(data.startIndex, offsetBy: offset)])
            let low = UInt16(data[data.index(data.startIndex, offsetBy: offset + 1)])
            return Double((high << 8) | low) / Double(UInt16.max)
        }
    }
}

private struct VisualizerView: View {
    @Bindable var model: VisualizerAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sendspin Visualizer").font(.title)
            Text(model.statusText).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 4) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.blue)
                    .frame(width: 36, height: max(2, 180 * model.loudness))
                ForEach(Array(model.spectrum.enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.purple)
                        .frame(width: 5, height: max(2, 180 * value))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .bottomLeading)
            Text("Latest due frame: \(model.lastPresentedType.map(\.rawValue) ?? "none")")
                .font(.caption)
            if let renderedPairing = model.pairingSnapshot {
                Divider()
                Text("Pairing").font(.headline)
                Text(model.pairingMessage).font(.caption)
                let peerDescription = [
                    "Peer: \(renderedPairing.peer.name)",
                    "— \(renderedPairing.peer.id)",
                    "(\(String(describing: renderedPairing.peer.trustLevel)))"
                ].joined(separator: " ")
                Text(verbatim: peerDescription)
                    .font(.caption)
                if let window = model.pairingWindow,
                   window.attemptID == renderedPairing.id {
                    Text(model.pairingWindowText(for: window)).font(.caption)
                }
                let terminal = if case .ended = renderedPairing.phase { true } else { false }
                HStack {
                    Button("Authorize") {
                        let attemptID = renderedPairing.id
                        Task { await model.openPairingWindow(for: attemptID) }
                    }
                    .disabled(terminal || model.phase != .connected)
                    Button("Cancel attempt") {
                        let attemptID = renderedPairing.id
                        Task { await model.cancelPairing(attemptID: attemptID) }
                    }
                    .disabled(terminal || model.phase != .connected)
                }
            }
            HStack {
                Text("Display ticks: \(model.displayTickCount)").font(.caption)
                Spacer()
                Button("Close client") { Task { await model.close() } }
            }
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 360)
    }
}

@main
struct VisualizerClientApp: App {
    @State private var model: VisualizerAppModel

    init() {
        switch LaunchOptions.parse(CommandLine.arguments.dropFirst()) {
        case let .success(options):
            _model = State(initialValue: VisualizerAppModel(options: options))
        case let .failure(.message(message)):
            print(message)
            _model = State(initialValue: VisualizerAppModel(options: LaunchOptions(
                server: nil, discover: false, timeout: 5, name: "Visualizer Client", pairing: false
            )))
        }
    }

    var body: some Scene {
        WindowGroup("VisualizerClient") {
            VisualizerView(model: model)
                .task { await model.start() }
                .onDisappear { Task { await model.close() } }
        }
    }
}
