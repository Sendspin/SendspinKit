import Foundation

#if os(macOS)
    import CoreAudio
#elseif canImport(AVFAudio)
    import AVFAudio
#endif

/// Internal capability seam owned by a player client.
///
/// The concrete service owns platform listeners and exposes normalized snapshots.
/// Keeping this actor-isolated interface internal lets handshakes take deterministic
/// snapshots while client-lifetime monitoring has an explicit cleanup boundary.
protocol AudioOutputCapabilityProviding: Actor {
    /// Return the most recently observed output capability.
    func snapshot() -> AudioOutputSnapshot

    /// Mark an output transition that AudioQueue may induce on the active route.
    func audioQueueTransitionWillBegin(sampleRate: Int)

    /// Mark successful AudioQueue startup so held observations can settle.
    func audioQueueTransitionDidStart()

    /// Start monitoring and return the single client-owned stream of future updates.
    func startMonitoring() -> AsyncStream<AudioOutputSnapshot>

    /// Record the host application's audio-session activation state.
    ///
    /// Later platform-listener work uses this to decide whether session-backed
    /// capability snapshots are trustworthy.
    func setAudioSessionActivationState(_ state: AudioSessionActivationState) async

    /// Permanently stop monitoring and finish the update stream.
    func stopMonitoring() async
}

/// Raw values captured by a platform output monitor before normalization.
struct AudioOutputPlatformObservation: Sendable, Equatable {
    let sampleRate: Double?
    let reportedBitDepth: Int?
    let diagnosticDescription: String?
    let requiresActivationReassertion: Bool

    init(
        sampleRate: Double?,
        reportedBitDepth: Int?,
        diagnosticDescription: String?,
        requiresActivationReassertion: Bool = false
    ) {
        self.sampleRate = sampleRate
        self.reportedBitDepth = reportedBitDepth
        self.diagnosticDescription = diagnosticDescription
        self.requiresActivationReassertion = requiresActivationReassertion
    }
}

/// Platform-listener seam. Implementations own every listener they register.
protocol AudioOutputPlatformMonitoring: Actor {
    /// Whether observations are trustworthy only while the host reports an active audio session.
    nonisolated var requiresActiveAudioSession: Bool { get }

    /// Start a fresh, single-consumer observation stream.
    func startMonitoring() -> AsyncStream<AudioOutputPlatformObservation>

    /// Remove all listeners and finish the current observation stream.
    func stopMonitoring()
}

/// Client-lifetime owner of normalized output capability state.
actor AudioOutputCapabilityService: AudioOutputCapabilityProviding {
    static let integralSampleRateTolerance = 0.01
    static let audioQueueSettleInterval: Duration = .milliseconds(250)
    static let audioQueueMaximumSuppression: Duration = .seconds(2)

    private static let unknownSnapshot = AudioOutputSnapshot(
        sampleRate: nil,
        reportedBitDepth: nil,
        diagnosticDescription: nil
    )

    private let updates: AsyncStream<AudioOutputSnapshot>
    private let continuation: AsyncStream<AudioOutputSnapshot>.Continuation
    private let platformMonitor: any AudioOutputPlatformMonitoring
    private var currentSnapshot: AudioOutputSnapshot
    private var monitoringTask: Task<Void, Never>?
    private var monitoringIdentity: UUID?
    private var isStopped = false
    private var hasStartedMonitoring = false
    private(set) var audioSessionActivationState: AudioSessionActivationState = .unknown
    private var audioQueueTransitionGeneration: UInt64 = 0
    private var audioQueueTransitionStarted = false
    private var heldAudioQueueSnapshot: AudioOutputSnapshot?
    private var audioQueueSettleTask: Task<Void, Never>?
    private var audioQueueMaximumTask: Task<Void, Never>?
    private let queueSettleInterval: Duration
    private let queueMaximumSuppression: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        initialSnapshot: AudioOutputSnapshot = AudioOutputCapabilityService.unknownSnapshot,
        platformMonitor: (any AudioOutputPlatformMonitoring)? = nil,
        queueSettleInterval: Duration = AudioOutputCapabilityService.audioQueueSettleInterval,
        queueMaximumSuppression: Duration = AudioOutputCapabilityService.audioQueueMaximumSuppression,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        currentSnapshot = initialSnapshot
        self.platformMonitor = platformMonitor ?? Self.makePlatformMonitor()
        self.queueSettleInterval = queueSettleInterval
        self.queueMaximumSuppression = queueMaximumSuppression
        self.sleep = sleep
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func snapshot() -> AudioOutputSnapshot {
        currentSnapshot
    }

    func audioQueueTransitionWillBegin(sampleRate _: Int) {
        guard !isStopped else { return }
        audioQueueTransitionGeneration &+= 1
        let generation = audioQueueTransitionGeneration
        audioQueueTransitionStarted = false
        heldAudioQueueSnapshot = nil
        audioQueueSettleTask?.cancel()
        audioQueueSettleTask = nil
        audioQueueMaximumTask?.cancel()
        audioQueueMaximumTask = Task { [weak self, sleep, queueMaximumSuppression] in
            do {
                try await sleep(queueMaximumSuppression)
            } catch {
                return
            }
            await self?.finishAudioQueueTransition(generation: generation)
        }
    }

    func audioQueueTransitionDidStart() {
        guard !isStopped, audioQueueMaximumTask != nil else { return }
        audioQueueTransitionStarted = true
        scheduleAudioQueueSettle()
    }

    func startMonitoring() -> AsyncStream<AudioOutputSnapshot> {
        guard !isStopped else {
            assertionFailure("Audio output capability monitoring cannot restart after stopping")
            return updates
        }
        guard !hasStartedMonitoring else {
            assertionFailure("Audio output capability monitoring can only start once")
            return updates
        }
        hasStartedMonitoring = true
        if !platformMonitor.requiresActiveAudioSession || audioSessionActivationState == .active {
            beginPlatformMonitoring()
        } else {
            publish(Self.unknownSnapshot)
        }
        return updates
    }

    func setAudioSessionActivationState(_ state: AudioSessionActivationState) async {
        guard !isStopped, state != audioSessionActivationState else { return }
        audioSessionActivationState = state
        guard platformMonitor.requiresActiveAudioSession, hasStartedMonitoring else { return }

        await endPlatformMonitoring()
        if state == .active {
            beginPlatformMonitoring()
        } else {
            publish(Self.unknownSnapshot)
        }
    }

    func stopMonitoring() async {
        guard !isStopped else { return }
        isStopped = true
        audioQueueTransitionGeneration &+= 1
        audioQueueSettleTask?.cancel()
        audioQueueSettleTask = nil
        audioQueueMaximumTask?.cancel()
        audioQueueMaximumTask = nil
        heldAudioQueueSnapshot = nil
        await endPlatformMonitoring()
        continuation.finish()
    }

    /// Ingest a snapshot from an internal test.
    func update(_ snapshot: AudioOutputSnapshot) {
        guard !isStopped else { return }
        publish(snapshot)
    }

    /// The identity used by later negotiation coalescing deliberately excludes diagnostics.
    static func normalizedSampleRateKey(for snapshot: AudioOutputSnapshot) -> Int? {
        snapshot.sampleRate
    }

    static func normalizeSampleRate(_ value: Double?) -> Int? {
        guard let value, value.isFinite, value > 0 else { return nil }
        let rounded = value.rounded()
        guard abs(value - rounded) <= integralSampleRateTolerance,
              rounded <= Double(Int.max)
        else {
            return nil
        }
        return Int(rounded)
    }

    private static func makePlatformMonitor() -> any AudioOutputPlatformMonitoring {
        #if os(macOS)
            MacOSAudioOutputPlatformMonitor()
        #elseif canImport(AVFAudio)
            AudioSessionOutputPlatformMonitor()
        #else
            UnknownAudioOutputPlatformMonitor()
        #endif
    }

    private func beginPlatformMonitoring() {
        guard !isStopped, monitoringTask == nil else { return }
        let identity = UUID()
        monitoringIdentity = identity
        let monitor = platformMonitor
        monitoringTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let observations = await monitor.startMonitoring()
            guard !Task.isCancelled else { return }
            for await observation in observations {
                guard !Task.isCancelled else { return }
                await self?.receive(observation, identity: identity)
            }
        }
    }

    private func endPlatformMonitoring() async {
        monitoringIdentity = nil
        let task = monitoringTask
        task?.cancel()
        await task?.value
        monitoringTask = nil
        await platformMonitor.stopMonitoring()
    }

    private func receive(_ observation: AudioOutputPlatformObservation, identity: UUID) async {
        guard !isStopped, monitoringIdentity == identity else { return }
        let snapshot = AudioOutputSnapshot(
            sampleRate: Self.normalizeSampleRate(observation.sampleRate),
            reportedBitDepth: observation.reportedBitDepth,
            diagnosticDescription: observation.diagnosticDescription
        )
        if audioQueueMaximumTask != nil {
            heldAudioQueueSnapshot = snapshot
            if audioQueueTransitionStarted {
                scheduleAudioQueueSettle()
            }
        } else {
            publish(snapshot)
        }

        if platformMonitor.requiresActiveAudioSession, observation.requiresActivationReassertion {
            audioSessionActivationState = .unknown
            monitoringIdentity = nil
            monitoringTask = nil
            await platformMonitor.stopMonitoring()
        }
    }

    private func scheduleAudioQueueSettle() {
        let generation = audioQueueTransitionGeneration
        audioQueueSettleTask?.cancel()
        audioQueueSettleTask = Task { [weak self, sleep, queueSettleInterval] in
            do {
                try await sleep(queueSettleInterval)
            } catch {
                return
            }
            await self?.finishAudioQueueTransition(generation: generation)
        }
    }

    private func finishAudioQueueTransition(generation: UInt64) {
        guard !isStopped, generation == audioQueueTransitionGeneration else { return }
        audioQueueSettleTask?.cancel()
        audioQueueSettleTask = nil
        audioQueueMaximumTask?.cancel()
        audioQueueMaximumTask = nil
        audioQueueTransitionStarted = false
        if let snapshot = heldAudioQueueSnapshot {
            heldAudioQueueSnapshot = nil
            publish(snapshot)
        }
    }

    private func publish(_ snapshot: AudioOutputSnapshot) {
        guard !isStopped, snapshot != currentSnapshot else { return }
        currentSnapshot = snapshot
        continuation.yield(snapshot)
    }
}

private actor UnknownAudioOutputPlatformMonitor: AudioOutputPlatformMonitoring {
    nonisolated let requiresActiveAudioSession = false

    func startMonitoring() -> AsyncStream<AudioOutputPlatformObservation> {
        AsyncStream { continuation in
            continuation.yield(AudioOutputPlatformObservation(
                sampleRate: nil,
                reportedBitDepth: nil,
                diagnosticDescription: nil
            ))
            continuation.finish()
        }
    }

    func stopMonitoring() {}
}

#if os(macOS)
    private actor MacOSAudioOutputPlatformMonitor: AudioOutputPlatformMonitoring {
        nonisolated let requiresActiveAudioSession = false

        private let listenerQueue = DispatchQueue(label: "com.sendspin.audio-output-capability")
        private var continuation: AsyncStream<AudioOutputPlatformObservation>.Continuation?
        private var activeDevice: AudioDeviceID?
        private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
        private var nominalRateListener: AudioObjectPropertyListenerBlock?
        private var listenerIdentity = UUID()
        private var isMonitoring = false

        func startMonitoring() -> AsyncStream<AudioOutputPlatformObservation> {
            let (stream, continuation) = AsyncStream.makeStream(
                of: AudioOutputPlatformObservation.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            guard !isMonitoring else {
                assertionFailure("Platform output monitoring can only start once per lifecycle")
                continuation.finish()
                return stream
            }
            isMonitoring = true
            self.continuation = continuation
            listenerIdentity = UUID()
            installDefaultDeviceListener(identity: listenerIdentity)
            migrateToDefaultDevice(identity: listenerIdentity)
            return stream
        }

        func stopMonitoring() {
            guard isMonitoring else { return }
            isMonitoring = false
            listenerIdentity = UUID()
            removeDefaultDeviceListener()
            removeNominalRateListener(from: activeDevice)
            activeDevice = nil
            continuation?.finish()
            continuation = nil
        }

        private func installDefaultDeviceListener(identity: UUID) {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { await self?.defaultDeviceChanged(identity: identity) }
            }
            var address = Self.defaultDeviceAddress
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                listenerQueue,
                listener
            )
            // Store only installed listeners so teardown never removes an unregistered block.
            guard status == noErr else { return }
            defaultDeviceListener = listener
        }

        private func removeDefaultDeviceListener() {
            guard let listener = defaultDeviceListener else { return }
            var address = Self.defaultDeviceAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                listenerQueue,
                listener
            )
            defaultDeviceListener = nil
        }

        private func defaultDeviceChanged(identity: UUID) {
            guard isMonitoring, listenerIdentity == identity else { return }
            migrateToDefaultDevice(identity: identity)
        }

        private func migrateToDefaultDevice(identity: UUID) {
            let replacement = Self.defaultOutputDevice()
            if replacement != activeDevice {
                removeNominalRateListener(from: activeDevice)
                activeDevice = replacement
                if let replacement {
                    installNominalRateListener(on: replacement, identity: identity)
                }
            }
            publishCurrentDevice(identity: identity)
        }

        private func installNominalRateListener(on device: AudioDeviceID, identity: UUID) {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { await self?.nominalRateChanged(device: device, identity: identity) }
            }
            var address = Self.nominalRateAddress
            let status = AudioObjectAddPropertyListenerBlock(device, &address, listenerQueue, listener)
            guard status == noErr else { return }
            nominalRateListener = listener
        }

        private func removeNominalRateListener(from device: AudioDeviceID?) {
            guard let device, let listener = nominalRateListener else { return }
            var address = Self.nominalRateAddress
            AudioObjectRemovePropertyListenerBlock(device, &address, listenerQueue, listener)
            nominalRateListener = nil
        }

        private func nominalRateChanged(device: AudioDeviceID, identity: UUID) {
            guard isMonitoring, listenerIdentity == identity, activeDevice == device else { return }
            publishCurrentDevice(identity: identity)
        }

        private func publishCurrentDevice(identity: UUID) {
            guard isMonitoring, listenerIdentity == identity, let activeDevice else {
                continuation?.yield(AudioOutputPlatformObservation(
                    sampleRate: nil,
                    reportedBitDepth: nil,
                    diagnosticDescription: nil
                ))
                return
            }
            continuation?.yield(AudioOutputPlatformObservation(
                sampleRate: Self.nominalSampleRate(activeDevice),
                reportedBitDepth: Self.reportedBitDepth(activeDevice),
                diagnosticDescription: Self.deviceName(activeDevice)
            ))
        }

        private static var defaultDeviceAddress: AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        }

        private static var nominalRateAddress: AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        }

        private static func defaultOutputDevice() -> AudioDeviceID? {
            var address = defaultDeviceAddress
            var device = AudioDeviceID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
            ) == noErr, device != kAudioObjectUnknown else {
                return nil
            }
            return device
        }

        private static func nominalSampleRate(_ device: AudioDeviceID) -> Double? {
            var address = nominalRateAddress
            var value: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
                return nil
            }
            return value
        }

        private static func deviceName(_ device: AudioDeviceID) -> String? {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
                  let value
            else {
                return nil
            }
            return value.takeRetainedValue() as String
        }

        private static func reportedBitDepth(_ device: AudioDeviceID) -> Int? {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamFormat,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var value = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
                  value.mBitsPerChannel > 0
            else {
                return nil
            }
            return Int(value.mBitsPerChannel)
        }
    }
#elseif canImport(AVFAudio)
    private actor AudioSessionOutputPlatformMonitor: AudioOutputPlatformMonitoring {
        nonisolated let requiresActiveAudioSession = true

        private var continuation: AsyncStream<AudioOutputPlatformObservation>.Continuation?
        private var notificationTokens: [NSObjectProtocol] = []
        private var identity = UUID()
        private var isMonitoring = false

        func startMonitoring() -> AsyncStream<AudioOutputPlatformObservation> {
            let (stream, continuation) = AsyncStream.makeStream(
                of: AudioOutputPlatformObservation.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            guard !isMonitoring else {
                assertionFailure("Platform output monitoring can only start once per lifecycle")
                continuation.finish()
                return stream
            }
            isMonitoring = true
            self.continuation = continuation
            identity = UUID()
            installNotifications(identity: identity)
            publishRoute(identity: identity)
            return stream
        }

        func stopMonitoring() {
            guard isMonitoring else { return }
            isMonitoring = false
            identity = UUID()
            for token in notificationTokens {
                NotificationCenter.default.removeObserver(token)
            }
            notificationTokens.removeAll()
            continuation?.finish()
            continuation = nil
        }

        private func installNotifications(identity: UUID) {
            let center = NotificationCenter.default
            let session = AVAudioSession.sharedInstance()
            notificationTokens = [
                center.addObserver(
                    forName: AVAudioSession.routeChangeNotification,
                    object: session,
                    queue: nil
                ) { [weak self] _ in
                    Task { await self?.publishRoute(identity: identity) }
                },
                center.addObserver(
                    forName: AVAudioSession.interruptionNotification,
                    object: session,
                    queue: nil
                ) { [weak self] _ in
                    Task { await self?.invalidate(identity: identity) }
                },
                center.addObserver(
                    forName: AVAudioSession.mediaServicesWereResetNotification,
                    object: session,
                    queue: nil
                ) { [weak self] _ in
                    Task { await self?.invalidate(identity: identity) }
                }
            ]
        }

        private func publishRoute(identity: UUID) {
            guard isMonitoring, self.identity == identity else { return }
            let session = AVAudioSession.sharedInstance()
            let description = session.currentRoute.outputs
                .map { "\($0.portName) (\($0.portType.rawValue))" }
                .joined(separator: ", ")
            continuation?.yield(AudioOutputPlatformObservation(
                sampleRate: session.sampleRate,
                reportedBitDepth: nil,
                diagnosticDescription: description.isEmpty ? nil : description
            ))
        }

        private func invalidate(identity: UUID) {
            guard isMonitoring, self.identity == identity else { return }
            continuation?.yield(AudioOutputPlatformObservation(
                sampleRate: nil,
                reportedBitDepth: nil,
                diagnosticDescription: nil,
                requiresActivationReassertion: true
            ))
        }
    }
#endif

enum AudioOutputTransition: Sendable, Equatable {
    case willBegin(sampleRate: Int)
    case didStart
}

/// Protocol for audio output, abstracting the methods that AudioEngine calls on AudioPlayer.
///
/// This allows the engine to be tested in isolation with a mock `SpyAudioOutput` or `StubAudioOutput`,
/// avoiding the MainActor and real AudioQueue hardware.
protocol AudioOutput: Actor, Sendable {
    /// Whether audio is currently being played.
    var isPlaying: Bool { get }

    /// Current telemetry snapshot (underrun count, sync correction state, etc).
    var telemetrySnapshot: AudioPlayer.TelemetrySnapshot { get }

    /// Prepare playback with the given format and optional codec header without starting audible output.
    /// This lets the engine prime decoded PCM before the backend begins consuming it.
    func prepare(format: AudioFormatSpec, codecHeader: Data?) throws

    /// Start a previously prepared output after initial PCM has been queued.
    func startPrepared() throws

    /// Delay between handing a frame to the output and hearing it — buffer depth plus the
    /// device path. Valid once `prepare(format:codecHeader:)` has run.
    func pipelineLatencyMicroseconds() -> Int64

    /// Wait until the output device has actually begun producing. Releasing before this
    /// buffers audio into a pipeline that is not yet consuming.
    func waitUntilOutputDeviceIsLive() async throws

    /// How far ahead of a frame's due time `startPrepared()` must be called for that frame
    /// to be audible on time. Covers only the path beyond the primed buffers, which the
    /// pre-fill has already filled. Valid once `prepare(format:codecHeader:)` has run.
    func startupLeadMicroseconds() -> Int64

    /// Start playback with the given format and optional codec header.
    /// Throws if the AudioQueue cannot be initialized or audio playback cannot begin.
    func start(format: AudioFormatSpec, codecHeader: Data?) throws

    /// Stop playback. Safe to call even if not playing.
    func stop()

    /// Swap the decoder for seamless format transitions.
    /// Called before chunks in the new format arrive.
    func swapDecoder(format: AudioFormatSpec, codecHeader: Data?) throws

    /// Decode a chunk of encoded audio into PCM.
    /// Throws if decoding fails.
    func decode(_ data: Data) async throws -> Data

    /// Queue a PCM chunk for playback at the given server timestamp and effective local play time.
    /// Throws if playback cannot continue (e.g., underrun recovery failing).
    func playPCM(_ pcm: Data, serverTimestamp: Int64, playTimeMicroseconds: Int64?) async throws

    /// Clear buffered PCM without stopping playback (for stream clear or seek).
    func clearBuffer()

    /// Set playback volume (0.0 = silent, 1.0 = full).
    func setVolume(_ gain: Float)

    /// Set mute state.
    func setMute(_ muted: Bool)

    /// Update the time snapshot for sync correction (called per server/time).
    /// This is the per-server/time cross-boundary push that drives sync correction.
    func updateTimeSnapshot(_ snapshot: TimeFilterSnapshot)

    /// Poll for reanchor requests from the audio callback.
    /// Returns the target server time if a reanchor is pending, clears the flag, and returns nil otherwise.
    func pollReanchor() -> Int64?

    /// Reanchor the playback cursor to a specific server time position.
    func reanchorCursor(to: Int64)
}
