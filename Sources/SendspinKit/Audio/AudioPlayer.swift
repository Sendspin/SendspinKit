import AudioToolbox
import Foundation
import os

/// Callback invoked on the audio thread with the buffer about to be played.
///
/// Called on every audio callback — including silence — so that consumers (e.g. VU
/// meters) observe silence rather than missing callbacks. The buffer contains
/// interleaved integer PCM samples (Int16 or Int32 depending on the stream's
/// effective bit depth) at full amplitude. Volume and mute are applied downstream
/// by either AudioQueue (software mode) or the hardware device (hardware mode),
/// so these samples always represent the full-scale signal.
///
/// > Note: Unlike the Rust reference implementation, which applies gain to the buffer
/// > before invoking its process callback, our volume is handled outside the sample
/// > buffer. If you need volume-adjusted levels for a VU meter, apply
/// > ``AudioPlayer/perceptualGain(_:)`` to the current volume yourself.
///
/// - Parameters:
///   - samples: Mutable pointer to the interleaved PCM sample buffer. Modify in
///     place to apply effects before playback. The byte count covers the entire
///     AudioQueue buffer including any silence padding at the end.
///   - format: Current audio format (sample rate, channels, bit depth). Use this to
///     interpret the sample data correctly.
///
/// **Audio thread contract:** Must not block, allocate memory, acquire locks, or
/// call into Objective-C/Swift runtime. Keep processing O(n) in sample count.
public typealias AudioProcessCallback = @Sendable (UnsafeMutableRawBufferPointer, AudioFormatSpec) -> Void

// MARK: - Lock-protected state

/// Report starts slower than this as a fault: a healthy start completes in hundreds of
/// milliseconds, while multi-second starts can leave CoreAudio consuming inaudible audio.
let audioQueueStartSlowThresholdUs: Int64 = 2_000_000

/// Report teardown calls that hold the output actor for half a second so slow
/// disconnects remain visible in user-collected diagnostics.
let audioQueueTeardownSlowThresholdUs: Int64 = 500_000

/// Leave the queue stopped until the release instant.
///
/// This diagnostic mode allows startup behavior to be compared with pre-warming when
/// investigating CoreAudio start stalls. Set `SENDSPIN_NO_PREWARM=1` to enable it.
let audioQueuePrewarmDisabled = ProcessInfo.processInfo.environment["SENDSPIN_NO_PREWARM"] == "1"

/// Startup lead, pad ceiling and modelled fallback describe depth in time,
/// so buffer duration stays independent of bit depth and sample rate.
let audioQueueBufferDuration: Duration = .milliseconds(50)

func audioQueueBufferSize(for format: AudioFormatSpec) -> (frames: Int, bytes: UInt32) {
    let components = audioQueueBufferDuration.components
    let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
    let frames = max(1, Int(seconds * Double(format.sampleRate)))
    let bytesPerFrame = format.channels * (format.effectiveOutputBitDepth / 8)
    return (frames, UInt32(frames * bytesPerFrame))
}

/// Allocated and primed buffer count matches the modelled queue depth.
let audioQueueBufferCount = 3

private let volumeRampStepCount = 5
private let volumeRampStepDuration: Duration = .milliseconds(10)

// MARK: - AudioPlayer

/// Actor managing synchronized audio playback
actor AudioPlayer {
    private var audioQueue: AudioQueueRef? {
        // didSet also fires during init (nil → nil), which is harmless.
        didSet { audioQueueForDeinit = audioQueue }
    }

    /// Mirror of `audioQueue` accessible from nonisolated `deinit`.
    /// `deinit` can't access actor-isolated properties, but must dispose
    /// the AudioQueue to prevent callbacks into a dangling Unmanaged pointer.
    private nonisolated(unsafe) var audioQueueForDeinit: AudioQueueRef?
    private var decoder: AudioDecoder?
    private var currentFormat: AudioFormatSpec?
    /// Changes whenever the AudioQueue handle is replaced or disposed. Boundary waits capture
    /// this identity and never dereference a handle after a lifecycle change.
    private var queueIdentity: UInt64 = 0

    /// Buffers held back for `startPrepared()` when pre-warm is disabled; empty otherwise.
    private var pendingStartBuffers: [AudioQueueBufferRef] = []
    private var outputDeviceLiveWaiter: OutputDeviceLiveWaiter?

    private var _isPlaying: Bool = false
    private let playerID = UUID().uuidString

    /// All state shared between the actor and the audio thread, protected by
    /// `OSAllocatedUnfairLock` with priority donation. Access is structurally
    /// enforced: every read/write goes through `withLock`.
    private nonisolated let lockedState: OSAllocatedUnfairLock<AudioRenderState>

    private var currentVolume: Float = 1.0
    private var appliedVolume: Float = 1.0
    private var volumeRampTask: Task<Void, Never>?
    private var volumeRampID = 0
    private var fadingStopIdentity: UInt64?
    private var isMuted: Bool = false
    private let volumeControl: VolumeControl
    private let deviceGainSampler = DeviceGainSampler()
    private let volumeRampSleep: @Sendable (Duration) async throws -> Void

    /// Process callback for local visualization / audio effects.
    /// Set once at init, never mutated — `@Sendable` and safe to read from any context.
    private nonisolated let processCallback: AudioProcessCallback?
    private let outputTransitionCallback: (@Sendable (AudioOutputTransition) -> Void)?

    var isPlaying: Bool {
        _isPlaying
    }

    var volume: Float {
        currentVolume
    }

    var muted: Bool {
        isMuted
    }

    /// - Parameter pcmBufferCapacity: Size of the PCM ring buffer in bytes.
    ///   Defaults to 524_288 (512KB ≈ 2.7s at 48kHz/stereo/16-bit).
    /// - Parameter volumeControl: How volume/mute commands are applied.
    ///   Defaults to `SoftwareVolumeControl` (AudioQueue gain).
    /// - Parameter processCallback: Optional callback invoked on the audio thread
    ///   with the final buffer contents before playback. See ``AudioProcessCallback``.
    init(
        pcmBufferCapacity: Int = 524_288,
        volumeControl: VolumeControl = SoftwareVolumeControl(),
        processCallback: AudioProcessCallback? = nil,
        outputTransitionCallback: (@Sendable (AudioOutputTransition) -> Void)? = nil,
        volumeRampSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.volumeRampSleep = volumeRampSleep
        self.volumeControl = volumeControl
        self.processCallback = processCallback
        self.outputTransitionCallback = outputTransitionCallback
        lockedState = OSAllocatedUnfairLock(
            initialState: AudioRenderState(pcmRingBuffer: PCMRingBuffer(capacity: pcmBufferCapacity))
        )
    }

    deinit {
        volumeRampTask?.cancel()
        // Dispose the AudioQueue synchronously to prevent callbacks firing into
        // a dangling Unmanaged pointer. We can't call the actor-isolated stop()
        // from nonisolated deinit, so we dispose via the nonisolated copy.
        if let queue = audioQueueForDeinit {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
        }
        lockedState.withLock { $0.deallocateResources() }
    }

    /// Prepare playback with specified format without starting the AudioQueue.
    ///
    /// The engine uses this for stream startup so decoded PCM can be written to the
    /// ring before the AudioQueue consumes its first primed buffers. Direct users can
    /// still call ``start(format:codecHeader:)``, which prepares and starts in one step.
    ///
    /// **Unmanaged safety:** `passUnretained(self)` is used to pass `self` as the
    /// AudioQueue callback client data. This is safe because:
    /// - `audioQueue` is set immediately after `AudioQueueNewOutput` (no throwing
    ///   calls between creation and assignment)
    /// - `stop()` disposes the queue during normal operation
    /// - `deinit` disposes the queue directly (can't call actor-isolated `stop()`)
    /// Do not insert throwing calls between `AudioQueueNewOutput` and `audioQueue = queue`.
    func prepare(format: AudioFormatSpec, codecHeader: Data?) throws {
        lockedState.withLock { $0.flowDiagnostics = PCMFlowDiagnostics() }
        try prepareQueue(format: format, codecHeader: codecHeader, createDecoder: true, preserveDecoder: false)
    }

    private func prepareQueue(
        format: AudioFormatSpec,
        codecHeader: Data?,
        createDecoder: Bool,
        preserveDecoder: Bool
    ) throws {
        let currentPlayerID = playerID
        let currentlyPlaying = _isPlaying
        let selectedDecoder = preserveDecoder ? decoder : nil
        defer {
            if preserveDecoder {
                decoder = selectedDecoder
            }
        }
        let prepareLog = "prepare player=\(currentPlayerID) format=\(format.codec.rawValue) isPlaying=\(currentlyPlaying)"
        Log.audio.debug("\(prepareLog, privacy: .public)")
        stop()
        if preserveDecoder {
            decoder = selectedDecoder
        }
        outputTransitionCallback?(.willBegin(sampleRate: format.sampleRate))

        if createDecoder {
            decoder = try AudioDecoderFactory.create(
                codec: format.codec,
                sampleRate: format.sampleRate,
                channels: format.channels,
                bitDepth: format.bitDepth,
                header: codecHeader
            )
        }

        var audioFormat = AudioStreamBasicDescription()
        audioFormat.mSampleRate = Float64(format.sampleRate)
        audioFormat.mFormatID = kAudioFormatLinearPCM
        audioFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked
        audioFormat.mFramesPerPacket = 1
        audioFormat.mChannelsPerFrame = UInt32(format.channels)

        let effectiveBitDepth = format.effectiveOutputBitDepth
        let bytesPerSample = effectiveBitDepth / 8

        audioFormat.mBytesPerPacket = UInt32(format.channels * bytesPerSample)
        audioFormat.mBytesPerFrame = UInt32(format.channels * bytesPerSample)
        audioFormat.mBitsPerChannel = UInt32(effectiveBitDepth)

        var queue: AudioQueueRef?
        // IMPORTANT: No throwing calls between AudioQueueNewOutput and audioQueue = queue.
        // See the Unmanaged safety note on this method.
        let status = AudioQueueNewOutput(
            &audioFormat,
            audioQueueCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            nil, nil, 0,
            &queue
        )

        guard status == noErr, let queue else {
            throw AudioPlayerError.queueAllocationFailed(status)
        }

        audioQueue = queue
        queueIdentity &+= 1
        currentFormat = format

        // Build the effective format for the process callback — uses the actual
        // output bit depth (e.g. 32 for 24-bit sources) so consumers interpret
        // samples correctly.
        let effectiveFormat = try AudioFormatSpec(
            codec: .pcm,
            channels: format.channels,
            sampleRate: format.sampleRate,
            bitDepth: effectiveBitDepth
        )

        let computedFrameSize = format.channels * bytesPerSample
        guard computedFrameSize <= maxFrameBytes else {
            // Release builds strip `assert`, yet the render callback later memcpys
            // into the fixed-size `lastFrameStorage` trusting this bound. Enforce it
            // unconditionally and tear down the queue we just built.
            AudioQueueDispose(queue, true)
            audioQueue = nil
            currentFormat = nil
            decoder = nil
            throw AudioPlayerError.frameSizeExceedsCapacity(computed: computedFrameSize, maximum: maxFrameBytes)
        }

        // Read once per prepared queue: querying the HAL is not possible from the audio thread,
        // and the dominant term is the route's IO buffer rather than a constant.
        let deviceLatencyUs = OutputDeviceLatency.currentMicroseconds()
        // Which device audio will actually reach. The queue follows the system default, so a
        // default pointing somewhere nobody is listening renders at full amplitude, silently.
        let deviceDescription = OutputDeviceLatency.currentDeviceDescription()
        Log.audio.info("output device: \(deviceDescription, privacy: .public) latency=\(deviceLatencyUs)us")

        lockedState.withLock { state in
            state.deviceLatencyUs = deviceLatencyUs
            state.queueStartAbsoluteUs = 0
            state.spinUpUs = -1
            state.prewarming = true
            state.totalFramesEnqueued = 0
            state.resetDepthTelemetry()
            state.enqueuedBufferCount = 0
            state.draining = false
            state.drainComplete = false
            state.drainTailBuffer = nil
            state.startupPadFrames = 0
            state.enqueueFailures = 0
            state.startupOffsetUs = nil
            state.frameSize = computedFrameSize
            state.processCallbackFormat = effectiveFormat
            state.lastFrameValid = false
            memset(state.lastFrameStorage.baseAddress!, 0, state.lastFrameStorage.count)
            state.clearPCM()
            state.sampleRate = format.sampleRate
            state.cursorMicroseconds = 0
            state.cursorRemainder = 0
            state.framesConsumed = 0
            state.underrunCount = 0
            state.pcmBytesDropped = 0
            // Note: syncPlanner is NOT reset — it's purely functional (all `let`
            // properties), so it has no accumulated state to carry over.
            state.correctionSchedule = CorrectionSchedule()
            state.dropCounter = 0
            state.insertCounter = 0
            state.lastSyncErrorUs = 0
            state.reanchorRequested = false
            state.pendingReanchorServerTime = 0
            // Suppress sync correction for ~1 second after rebuild.
            state.correctionGraceFrames = Int64(format.sampleRate)
        }

        try allocateAndPrewarm(queue: queue, format: format)
    }

    private func prepareHardwareQueue(format: AudioFormatSpec) throws {
        try prepareQueue(format: format, codecHeader: nil, createDecoder: false, preserveDecoder: true)
    }

    /// Allocate the queue's buffers and start it on silence.
    ///
    /// Started here rather than at the release instant because an idle DAC takes 300-400ms to
    /// begin producing and the figure varies by ~100ms between starts, so it cannot be led by an
    /// estimate — but paid during the window already spent buffering, it is spent before any
    /// audio depends on it. The ring is empty, so every buffer enqueued below is silence.
    private func allocateAndPrewarm(queue: AudioQueueRef, format: AudioFormatSpec) throws {
        let bufferSize = audioQueueBufferSize(for: format)
        var allocated: [AudioQueueBufferRef] = []
        for _ in 0 ..< audioQueueBufferCount {
            var buffer: AudioQueueBufferRef?
            let allocStatus = AudioQueueAllocateBuffer(queue, bufferSize.bytes, &buffer)
            guard allocStatus == noErr, let buffer else {
                AudioQueueDispose(queue, true)
                audioQueue = nil
                currentFormat = nil
                decoder = nil
                throw AudioPlayerError.queueAllocationFailed(allocStatus)
            }
            allocated.append(buffer)
        }

        guard !audioQueuePrewarmDisabled else {
            pendingStartBuffers = allocated
            return
        }

        for buffer in allocated {
            fillBuffer(queue: queue, buffer: buffer)
        }
        // Stamped after the fill loop: those calls run on this thread, and timing them would
        // measure our own enqueue rather than how long the device takes to answer.
        let startCalledAt = MonotonicClock.absoluteMicroseconds()
        lockedState.withLock { $0.queueStartAbsoluteUs = startCalledAt }
        let prewarmStatus = AudioQueueStart(queue, nil)
        // `AudioQueueStart` is synchronous and can reconfigure the device — notably when the
        // device's nominal rate differs from the queue's, which forces a rate change. That
        // happens on this actor, so anything it costs stalls the whole engine behind it.
        let startBlockedUs = MonotonicClock.absoluteMicroseconds() - startCalledAt
        let rateAfter = OutputDeviceLatency.currentDeviceDescription()
        if startBlockedUs > audioQueueStartSlowThresholdUs {
            // The command loop is stalled for the duration, and a slow start can leave the
            // device consuming audio that never reaches the speakers. Keep this at .notice so
            // it appears in user-collected diagnostics.
            Log.audio.notice(
                "AudioQueueStart blocked \(startBlockedUs)us on \(rateAfter, privacy: .public) — playback may start late or silent"
            )
        } else {
            Log.audio.info(
                "AudioQueueStart returned in \(startBlockedUs)us; device now \(rateAfter, privacy: .public)"
            )
        }
        guard prewarmStatus == noErr else {
            AudioQueueDispose(queue, true)
            audioQueue = nil
            currentFormat = nil
            decoder = nil
            throw AudioPlayerError.queueStartFailed(prewarmStatus)
        }
        outputTransitionCallback?(.didStart)
    }

    /// Modelled depth supplies the startup lead, pad ceiling and engine deferred-play lead.
    /// Correction reads the device; this conservative estimate is zero before `prepare()`.
    func pipelineLatencyMicroseconds() -> Int64 {
        guard let format = currentFormat else { return 0 }
        let bufferSize = audioQueueBufferSize(for: format)
        let queueDepthUs = Int64(audioQueueBufferCount) * Int64(bufferSize.frames) * 1_000_000
            / Int64(format.sampleRate)
        return queueDepthUs + lockedState.withLock { $0.deviceLatencyUs }
    }

    func setOutputDelayMicroseconds(_ delay: Int64) {
        lockedState.withLock { $0.outputDelayUs = max(0, delay) }
    }

    /// PCM release waits for the first device callback so the ring does not accumulate stale audio.
    /// AudioEngine.outputDeviceLiveTimeout bounds this gate while allowing slow device spin-up.
    func waitUntilOutputDeviceIsLive() async throws {
        // With pre-warm disabled the queue does not exist until the release, so there is no
        // device to wait for and gating on it would deadlock the startup path.
        guard !audioQueuePrewarmDisabled, lockedState.withLock({ $0.spinUpUs < 0 }) else { return }
        let waiter = OutputDeviceLiveWaiter()
        outputDeviceLiveWaiter = waiter
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.install(continuation)
                if lockedState.withLock({ $0.spinUpUs >= 0 }) {
                    waiter.resume()
                }
            }
        } onCancel: {
            waiter.resume()
        }
        if outputDeviceLiveWaiter === waiter {
            outputDeviceLiveWaiter = nil
        }
    }

    private func resumeOutputDeviceLiveWaiter() {
        outputDeviceLiveWaiter?.resume()
        outputDeviceLiveWaiter = nil
    }

    /// How far before a frame should be audible it must be written to the ring.
    ///
    /// The queue is already running on silence by then, so a released frame enters behind
    /// whatever silence is in flight and waits out the full depth — unlike a pre-start
    /// prime, which sits at the head and waits out only the device path.
    func startupLeadMicroseconds() -> Int64 {
        pipelineLatencyMicroseconds()
    }

    /// Start a prepared queue after decoded PCM has been written to the ring.
    func startPrepared() throws {
        guard audioQueue != nil, let format = currentFormat else {
            throw AudioPlayerError.notStarted
        }
        if _isPlaying {
            let currentPlayerID = playerID
            Log.audio.debug("startPrepared ignored player=\(currentPlayerID, privacy: .public) isPlaying=true")
            return
        }
        let currentPlayerID = playerID
        Log.audio.debug("startPrepared begin player=\(currentPlayerID, privacy: .public) format=\(format.codec.rawValue, privacy: .public)")

        // Normally `prepare()` already started the queue on silence and there is nothing to do
        // here. With pre-warm disabled the buffers were held back, so prime and start now.
        if audioQueuePrewarmDisabled, let queue = audioQueue {
            for buffer in pendingStartBuffers {
                fillBuffer(queue: queue, buffer: buffer)
            }
            pendingStartBuffers.removeAll(keepingCapacity: true)
            let startCalledAt = MonotonicClock.absoluteMicroseconds()
            lockedState.withLock { $0.queueStartAbsoluteUs = startCalledAt }
            let status = AudioQueueStart(queue, nil)
            let blockedUs = MonotonicClock.absoluteMicroseconds() - startCalledAt
            Log.audio.info("AudioQueueStart returned in \(blockedUs)us; device now (prewarm disabled)")
            guard status == noErr else {
                AudioQueueDispose(queue, true)
                audioQueue = nil
                currentFormat = nil
                decoder = nil
                throw AudioPlayerError.queueStartFailed(status)
            }
            outputTransitionCallback?(.didStart)
        }
        let desc = "\(format.codec.rawValue) \(format.sampleRate)Hz"
            + " \(format.channels)ch \(format.bitDepth)bit (output: \(format.effectiveOutputBitDepth)-bit)"
        Log.audio.info("AudioQueue started player=\(currentPlayerID, privacy: .public): \(desc, privacy: .public)")
        _isPlaying = true
    }

    /// Start playback with specified format.
    func start(format: AudioFormatSpec, codecHeader: Data?) throws {
        try prepare(format: format, codecHeader: codecHeader)
        try startPrepared()
    }

    /// Fade queue-local gain without changing the user's software or hardware volume.
    func stopAfterFade() async {
        guard let queue = audioQueue, _isPlaying else {
            stop()
            return
        }
        let identity = queueIdentity
        fadingStopIdentity = identity
        cancelVolumeRamp()
        let status = AudioQueueStopFade.begin {
            AudioQueueSetParameter(queue, $0, $1)
        }
        if status == noErr {
            let latency = lockedState.withLock { $0.deviceLatencyUs }
            // Cancellation must not truncate the ramp; lifecycle changes invalidate the captured queue.
            let settling = AudioQueueStopFade.settlingDuration(deviceLatencyMicroseconds: latency)
            await Task.detached { try? await Task.sleep(for: settling) }.value
        } else {
            Log.audio.error("Stop fade failed (OSStatus \(status)); stopping immediately")
        }
        guard queueIdentity == identity else { return }
        stop()
    }

    /// Stop playback and clean up
    func stop() {
        let currentPlayerID = playerID
        let currentlyPlaying = _isPlaying
        Log.audio.debug("stop player=\(currentPlayerID, privacy: .public) isPlaying=\(currentlyPlaying, privacy: .public)")
        cancelVolumeRamp()
        fadingStopIdentity = nil
        resumeOutputDeviceLiveWaiter()
        guard let queue = audioQueue else { return }

        let stopStartedAt = MonotonicClock.absoluteMicroseconds()
        AudioQueueStop(queue, true)
        let stopUs = MonotonicClock.absoluteMicroseconds() - stopStartedAt
        let disposeStartedAt = MonotonicClock.absoluteMicroseconds()
        AudioQueueDispose(queue, true)
        let disposeUs = MonotonicClock.absoluteMicroseconds() - disposeStartedAt
        let device = OutputDeviceLatency.currentDeviceDescription()
        Log.audio.info(
            """
            AudioQueueStop returned in \(stopUs, privacy: .public)us; \
            AudioQueueDispose returned in \(disposeUs, privacy: .public)us; \
            wasPlaying=\(currentlyPlaying, privacy: .public); device \(device, privacy: .public)
            """
        )
        if stopUs > audioQueueTeardownSlowThresholdUs || disposeUs > audioQueueTeardownSlowThresholdUs {
            Log.audio.notice(
                """
                Slow AudioQueue teardown: stop=\(stopUs, privacy: .public)us \
                dispose=\(disposeUs, privacy: .public)us; device \(device, privacy: .public)
                """
            )
        }

        audioQueue = nil
        queueIdentity &+= 1
        decoder = nil
        currentFormat = nil
        _isPlaying = false

        lockedState.withLock { state in
            state.clearPCM()
            state.enqueuedBufferCount = 0
            state.draining = false
            state.drainComplete = false
            state.drainTailBuffer = nil
            state.cursorMicroseconds = 0
            state.cursorRemainder = 0
            state.framesConsumed = 0
            state.timeSnapshot = nil
        }
    }

    /// Replace the decoder without stopping playback.
    /// Used for seamless mid-stream format transitions: the old AudioQueue
    /// keeps running with its existing ring buffer data while new incoming
    /// chunks get decoded by the new decoder.
    func swapDecoder(format: AudioFormatSpec, codecHeader: Data?) throws {
        decoder = try AudioDecoderFactory.create(
            codec: format.codec,
            sampleRate: format.sampleRate,
            channels: format.channels,
            bitDepth: format.bitDepth,
            header: codecHeader
        )
        // The hardware queue continues to use its existing format until the render boundary.
        // `currentFormat` describes that queue, not the decoder selected for future chunks.
    }

    /// Reconfigure the hardware queue at an ordered render boundary. The engine invokes this
    /// after older scheduled chunks have been handed to the current queue; finite-drain the queue's
    /// existing buffers before disposing it so old PCM is not truncated or replaced with silence.
    func switchHardwareFormat(format: AudioFormatSpec) async throws {
        guard audioQueue != nil, _isPlaying else {
            throw AudioPlayerError.notStarted
        }
        let identity = queueIdentity
        lockedState.withLock {
            $0.draining = true
            $0.drainComplete = false
            $0.drainTailBuffer = nil
        }
        var switched = false
        defer {
            if !switched {
                lockedState.withLock {
                    $0.draining = false
                    $0.drainComplete = false
                    $0.drainTailBuffer = nil
                }
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while true {
            // The queue is only borrowed for this synchronous snapshot. Never retain its
            // pointer across the sleep: stop() can dispose it while this task is suspended.
            guard queueIdentity == identity, audioQueue != nil, _isPlaying else {
                throw AudioPlayerError.notStarted
            }
            let state = lockedState.withLock { locked in
                (locked.enqueuedBufferCount, locked.pcmRingBuffer.availableToRead, locked.drainComplete)
            }
            if state.2, state.0 == 0, state.1 == 0 {
                break
            }
            guard ContinuousClock.now < deadline else {
                throw AudioPlayerError.queueStartFailed(-1)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        guard queueIdentity == identity, audioQueue != nil, _isPlaying else {
            throw AudioPlayerError.notStarted
        }
        try prepareHardwareQueue(format: format)
        try startPrepared()
        switched = true
    }

    /// Decode compressed audio data to PCM
    func decode(_ data: Data) throws -> Data {
        guard let decoder else {
            throw AudioPlayerError.notStarted
        }
        let startedAt = MonotonicClock.absoluteMicroseconds()
        defer {
            let elapsed = MonotonicClock.absoluteMicroseconds() - startedAt
            if elapsed > 20_000 {
                Log.audio.notice("Slow audio decode: \(elapsed)us bytes=\(data.count)")
            }
        }
        return try decoder.decode(data)
    }

    /// Enqueue PCM data into the ring buffer for consumption by the AudioQueue callback.
    func playPCM(
        _ pcmData: Data,
        serverTimestamp: Int64,
        playTimeMicroseconds: Int64? = nil,
        timelineAdjustmentUs: Int64? = nil
    ) async throws {
        guard audioQueue != nil, currentFormat != nil else {
            throw AudioPlayerError.notStarted
        }

        lockedState.withLock { state in
            state.prewarming = false
            let written = state.enqueuePCM(
                pcmData, serverTimestamp: serverTimestamp, localPlayTime: playTimeMicroseconds,
                timelineAdjustmentUs: timelineAdjustmentUs
            )
            let nowUs = MonotonicClock.absoluteMicroseconds()
            state.flowDiagnostics.writtenFrames += Int64(written / max(1, state.frameSize))
            state.flowDiagnostics.writes += 1
            if state.flowDiagnostics.lastWriteUs > 0 {
                state.flowDiagnostics.maximumWriteGapUs = max(
                    state.flowDiagnostics.maximumWriteGapUs, nowUs - state.flowDiagnostics.lastWriteUs
                )
            }
            state.flowDiagnostics.lastWriteUs = nowUs
            state.flowDiagnostics.deliveryLeadUs = (playTimeMicroseconds ?? nowUs) - nowUs
            let dropped = pcmData.count - written
            if dropped > 0 {
                state.pcmBytesDropped += Int64(dropped)
            }
        }
    }

    /// Peak absolute sample magnitude in the filled region, as a fraction of full scale.
    ///
    /// Runs on the audio thread, so it is a bounded scan of the buffer just written and nothing
    /// more — no allocation, no branching per sample beyond the comparison.
    private static func peakMagnitude(
        _ dest: UnsafeMutablePointer<UInt8>,
        byteCount: Int,
        bytesPerSample: Int
    ) -> Float {
        guard byteCount > 0 else { return 0 }
        var peak: Int32 = 0
        if bytesPerSample == 4 {
            let samples = UnsafeRawPointer(dest).bindMemory(to: Int32.self, capacity: byteCount / 4)
            for index in 0 ..< (byteCount / 4) {
                let magnitude = samples[index] == Int32.min ? Int32.max : abs(samples[index])
                peak = max(peak, magnitude)
            }
            return Float(peak) / Float(Int32.max)
        }
        if bytesPerSample == 2 {
            let samples = UnsafeRawPointer(dest).bindMemory(to: Int16.self, capacity: byteCount / 2)
            var peak16: Int16 = 0
            for index in 0 ..< (byteCount / 2) {
                let magnitude = samples[index] == Int16.min ? Int16.max : abs(samples[index])
                peak16 = max(peak16, magnitude)
            }
            return Float(peak16) / Float(Int16.max)
        }
        return 0
    }

    /// Frames the device has actually played since the queue started, or 0 if it cannot say.
    private static func framesPlayed(queue: AudioQueueRef) -> Int64 {
        var timestamp = AudioTimeStamp()
        guard AudioQueueGetCurrentTime(queue, nil, &timestamp, nil) == noErr,
              timestamp.mFlags.contains(.sampleTimeValid),
              timestamp.mSampleTime > 0
        else { return 0 }
        return Int64(timestamp.mSampleTime)
    }

    // MARK: - Sync correction interface

    /// Push a new time filter snapshot for use by the audio callback.
    /// Called from the clock sync path whenever processServerTime updates the filter.
    /// Cleared back to nil by `stop()`.
    func updateTimeSnapshot(_ snapshot: TimeFilterSnapshot) {
        lockedState.withLock { $0.timeSnapshot = snapshot }
    }

    /// Reanchor the playback cursor to a new server time position.
    func reanchorCursor(to _: Int64) {
        // Compatibility entry point: the next render uses its current clock and depth.
        lockedState.withLock { $0.reanchorRequested = true }
    }

    /// Reanchors are applied atomically by render; no captured target leaves the callback.
    func pollReanchor() -> Int64? {
        nil
    }

    /// Telemetry snapshot — read by the external telemetry loop for logging.
    struct TelemetrySnapshot {
        let cursorMicroseconds: Int64
        let sampleRate: Int
        let syncErrorUs: Int64
        let correctionSchedule: CorrectionSchedule
        let underrunCount: Int64
        let pcmBytesDropped: Int64
        /// Measured sync error at grace expiry, or `nil` until then.
        /// Recording this offset does not change the source PCM timestamp.
        let startupOffsetUs: Int64?
        /// `AudioQueueStart` to first device callback. -1 until that callback lands.
        let spinUpUs: Int64
        /// Silence frames inserted to land the first real frame on its due instant.
        let startupPadFrames: Int64
        /// Frames actually read out of the ring since the stream started. Distinguishes a
        /// starved pipeline from one that is running and inaudible; free, unlike the peak scan.
        let framesConsumed: Int64
        /// Buffers filled entirely from silence because the ring had nothing, since the previous
        /// read. Costs one comparison, so it can be trusted not to perturb what it measures.
        let silentBuffers: Int64
        /// Enqueue calls the queue refused, cumulative. Nonzero means the queue is running on
        /// fewer buffers than were primed, which is silent and otherwise unreported.
        let enqueueFailures: Int64
        /// Peak sample level handed to the device since the previous read, 0-1.
        let peakOutputLevel: Float
        /// Gain actually applied to the queue, after any ramp.
        let appliedVolume: Float
        /// The queue's own gain parameter, read back rather than assumed. Diverging from
        /// `appliedVolume` means a set was refused or overwritten.
        let queueGain: Float
        /// The output device's volume and mute as the HAL reports them. -1 where unavailable.
        let deviceVolume: Float
        let deviceMuted: Bool
        /// Frames handed to the queue but not yet played — the real pipeline depth, against
        /// the modelled one of every allocated buffer.
        let framesInFlight: Int64
        let callbackDepth: CallbackDepthTelemetry
        let queueTimeline: QueueTimelineTelemetry
        /// Lateness of the first frame when its silence pad clamps to zero.
        let startupLateUs: Int64
        var flowDiagnostics = PCMFlowDiagnostics()

        init(
            cursorMicroseconds: Int64, sampleRate: Int, syncErrorUs: Int64, correctionSchedule: CorrectionSchedule,
            underrunCount: Int64, pcmBytesDropped: Int64, startupOffsetUs: Int64?, spinUpUs: Int64,
            startupPadFrames: Int64, framesConsumed: Int64, silentBuffers: Int64, enqueueFailures: Int64,
            peakOutputLevel: Float, appliedVolume: Float, queueGain: Float, deviceVolume: Float,
            deviceMuted: Bool, framesInFlight: Int64, callbackDepth: CallbackDepthTelemetry = .init(),
            queueTimeline: QueueTimelineTelemetry = .init(), startupLateUs: Int64 = 0
        ) {
            self.cursorMicroseconds = cursorMicroseconds
            self.sampleRate = sampleRate
            self.syncErrorUs = syncErrorUs
            self.correctionSchedule = correctionSchedule
            self.underrunCount = underrunCount
            self.pcmBytesDropped = pcmBytesDropped
            self.startupOffsetUs = startupOffsetUs
            self.spinUpUs = spinUpUs
            self.startupPadFrames = startupPadFrames
            self.framesConsumed = framesConsumed
            self.silentBuffers = silentBuffers
            self.enqueueFailures = enqueueFailures
            self.peakOutputLevel = peakOutputLevel
            self.appliedVolume = appliedVolume
            self.queueGain = queueGain
            self.deviceVolume = deviceVolume
            self.deviceMuted = deviceMuted
            self.framesInFlight = framesInFlight
            self.callbackDepth = callbackDepth
            self.queueTimeline = queueTimeline
            self.startupLateUs = startupLateUs
        }
    }

    var totalFramesEnqueued: Int64 {
        lockedState.withLock { $0.totalFramesEnqueued }
    }

    /// Capture telemetry state atomically for the logging loop.
    var telemetrySnapshot: TelemetrySnapshot {
        let startedAt = MonotonicClock.absoluteMicroseconds()
        let played = audioQueue.map { Self.framesPlayed(queue: $0) } ?? 0
        let positionReadAt = MonotonicClock.absoluteMicroseconds()
        let timeline = audioQueue.map { QueueTimelineTelemetry.read(queue: $0) } ?? QueueTimelineTelemetry()
        let timelineReadAt = MonotonicClock.absoluteMicroseconds()
        defer {
            let elapsed = MonotonicClock.absoluteMicroseconds() - startedAt
            if elapsed > 20_000 {
                let positionUs = positionReadAt - startedAt
                let timelineUs = timelineReadAt - positionReadAt
                Log.audio.notice("Slow output telemetry: total=\(elapsed)us position=\(positionUs)us timeline=\(timelineUs)us")
            }
        }
        let appliedVolume = appliedVolume
        // Read back rather than trusted. `appliedVolume` is what this process believes it set;
        // these are what the queue and the device report, and the span between them is the only
        // one left unmeasured when full-amplitude audio is consumed at rate and heard by nobody.
        let queueGain: Float = {
            guard let queue = audioQueue else { return -1 }
            var value: Float32 = -1
            AudioQueueGetParameter(queue, kAudioQueueParam_Volume, &value)
            return value
        }()
        let deviceGain = deviceGainSampler.sample()
        // Read-and-clear: the peak describes the interval since the last read, so a signal that
        // stops is visible rather than latched forever by one loud buffer.
        let (peak, silentBuffers) = lockedState.withLock { state -> (Float, Int64) in
            let values = (state.peakOutputLevel, state.silentBufferCount)
            state.peakOutputLevel = 0
            state.silentBufferCount = 0
            return values
        }
        return lockedState.withLock { state in
            let callbackDepth = state.callbackDepth
            state.callbackDepth = CallbackDepthTelemetry()
            var snapshot = TelemetrySnapshot(
                cursorMicroseconds: state.cursorMicroseconds,
                sampleRate: state.sampleRate,
                syncErrorUs: state.lastSyncErrorUs,
                correctionSchedule: state.correctionSchedule,
                underrunCount: state.underrunCount,
                pcmBytesDropped: state.pcmBytesDropped,
                startupOffsetUs: state.startupOffsetUs,
                spinUpUs: state.spinUpUs,
                startupPadFrames: state.startupPadFrames,
                framesConsumed: state.framesConsumed,
                silentBuffers: silentBuffers,
                enqueueFailures: state.enqueueFailures,
                peakOutputLevel: peak,
                appliedVolume: appliedVolume,
                queueGain: queueGain,
                deviceVolume: deviceGain.volume ?? -1,
                deviceMuted: deviceGain.muted ?? false,
                framesInFlight: max(0, state.totalFramesEnqueued - played),
                callbackDepth: callbackDepth,
                queueTimeline: timeline,
                startupLateUs: state.startupLateUs
            )
            snapshot.flowDiagnostics = state.flowDiagnostics
            snapshot.flowDiagnostics.ringFrames = Int64(state.pcmRingBuffer.availableToRead / max(1, state.frameSize))
            return snapshot
        }
    }

    /// Clear buffered PCM data (for seek/stream clear without stopping playback)
    func clearBuffer() {
        lockedState.withLock { state in
            state.flowDiagnostics.clearedFrames += Int64(state.pcmRingBuffer.availableToRead / max(1, state.frameSize))
            state.clearPCM()
        }
    }

    // MARK: - AudioQueue callback (runs on audio thread)

    /// Result of the locked buffer-fill operation. Captures everything needed
    /// for post-lock work (silence fill, process callback, enqueue).
    private struct FillResult {
        let outOffset: Int
        let cb: AudioProcessCallback?
        let cbFormat: AudioFormatSpec?
        let enqueue: Bool
        var deviceBecameLive = false
    }

    /// Server-time cursor target for a frame handed to hardware at `localNow`.
    /// All latency is local-domain time before one exact snapshot inverse mapping. Saturating
    /// arithmetic keeps malformed snapshots or extreme latency values from trapping the callback.
    static func correctionEquilibriumServerTime(
        snapshot: TimeFilterSnapshot,
        localNow: Int64,
        pipelineLatencyUs: Int64,
        outputDelayUs: Int64
    ) -> Int64 {
        let audibleLocalTime = localNow
            .saturatingAdding(max(0, pipelineLatencyUs))
            .saturatingAdding(max(0, outputDelayUs))
        return snapshot.localTimeToServer(audibleLocalTime)
    }

    static func correctionPipelineLatencyUs(
        inFlightFrames: Int64?, sampleRate: Int, modelledQueueDepthUs: Int64, deviceLatencyUs: Int64
    ) -> Int64 {
        // Correction and placement describe the same physical span, so both read the device.
        // The model stands in before the first position; missed reads then hold the last measured depth.
        let queueDepthUs = inFlightFrames.map { $0 * 1_000_000 / Int64(sampleRate) } ?? modelledQueueDepthUs
        return queueDepthUs + deviceLatencyUs
    }

    private static func measureCallbackDepth(state: inout AudioRenderState, queue: AudioQueueRef, bufferFrames: Int64) -> Int64? {
        let start = MonotonicClock.absoluteMicroseconds()
        let played = framesPlayed(queue: queue)
        let cost = MonotonicClock.absoluteMicroseconds() - start
        state.callbackDepth.record(
            total: state.totalFramesEnqueued, played: played, bufferFrames: bufferFrames,
            costUs: cost, prewarming: state.prewarming
        )
        return CallbackDepthTelemetry.measuredDepth(
            total: state.totalFramesEnqueued, played: played, previous: &state.lastMeasuredDepthFrames
        )
    }

    fileprivate nonisolated func fillBuffer(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        let capacity = Int(buffer.pointee.mAudioDataBytesCapacity)
        let dest = buffer.pointee.mAudioData.assumingMemoryBound(to: UInt8.self)

        // All shared state access happens inside this single lock scope.
        // The closure writes decoded PCM into `dest` (the AudioQueue buffer,
        // which is NOT shared state) and returns info needed for post-lock work.
        // withLockUnchecked is required because `dest` (UnsafeMutablePointer)
        // is not Sendable, but we know this closure runs synchronously on the
        // audio thread and `dest` is a stack-local pointer to the AQ buffer.
        let result = lockedState.withLockUnchecked { state -> FillResult in
            let fs = state.frameSize
            if state.enqueuedBufferCount > 0 {
                state.enqueuedBufferCount -= 1
            }
            if state.draining, buffer == state.drainTailBuffer {
                state.drainTailBuffer = nil
                state.drainComplete = true
                return FillResult(outOffset: 0, cb: nil, cbFormat: nil, enqueue: false)
            }
            guard fs > 0 else {
                return FillResult(outOffset: 0, cb: nil, cbFormat: nil, enqueue: false)
            }
            if state.draining, state.drainComplete {
                return FillResult(outOffset: 0, cb: nil, cbFormat: nil, enqueue: false)
            }

            let cb = processCallback // nonisolated let, not in locked state
            let cbFormat = state.processCallbackFormat
            let channels = cbFormat?.channels ?? 2

            let inFlightAtCallback = Self.measureCallbackDepth(state: &state, queue: queue, bufferFrames: Int64(capacity / fs))

            // `prepare()` fills every buffer through this path before the queue is started,
            // so the first callback with a start time recorded is the device's own.
            let deviceBecameLive = state.spinUpUs < 0 && state.queueStartAbsoluteUs > 0
            if deviceBecameLive {
                state.spinUpUs = MonotonicClock.absoluteMicroseconds() - state.queueStartAbsoluteUs
            }

            if state.cursorMicroseconds > 0, state.timeSnapshot != nil {
                state.updateCorrectionSchedule(
                    localNow: MonotonicClock.absoluteMicroseconds(),
                    capacity: capacity, frameSize: fs, sampleRate: state.sampleRate, inFlightAtCallback: inFlightAtCallback
                )
            }
            let outOffset = state.fillFrames(into: dest, capacity: capacity)

            if outOffset == 0 {
                state.silentBufferCount += 1
            }
            let peak = Self.peakMagnitude(dest, byteCount: outOffset, bytesPerSample: fs / max(1, channels))
            state.peakOutputLevel = max(state.peakOutputLevel, peak)

            var enqueue = true
            if state.draining, state.pcmRingBuffer.availableToRead == 0 {
                if outOffset > 0 {
                    // Keep the tail buffer in AudioQueue once. Its next callback proves the
                    // final old-format PCM has played and can complete the drain.
                    state.drainTailBuffer = buffer
                } else if state.enqueuedBufferCount == 0 {
                    state.drainComplete = true
                } else {
                    // Silence buffers already in flight are allowed to return, but must not
                    // be manufactured again while the queue is draining.
                    enqueue = false
                }
            }
            return FillResult(outOffset: outOffset, cb: cb, cbFormat: cbFormat, enqueue: enqueue, deviceBecameLive: deviceBecameLive)
        }

        if result.deviceBecameLive {
            scheduleOutputDeviceLiveResume()
        }

        // --- Post-lock: silence fill, process callback, enqueue ---
        guard result.enqueue else { return }
        if result.outOffset < capacity {
            memset(dest + result.outOffset, 0, capacity - result.outOffset)
        }

        // Invoke process callback with the fully assembled buffer (including silence).
        if let cb = result.cb, let cbFormat = result.cbFormat {
            let mutableBuffer = UnsafeMutableRawBufferPointer(
                start: buffer.pointee.mAudioData,
                count: capacity
            )
            cb(mutableBuffer, cbFormat)
        }

        enqueueFilledBuffer(queue: queue, buffer: buffer, capacity: capacity)
    }

    private nonisolated func scheduleOutputDeviceLiveResume() {
        Task { [weak self] in
            await self?.resumeOutputDeviceLiveWaiter()
        }
    }

    private nonisolated func enqueueFilledBuffer(queue: AudioQueueRef, buffer: AudioQueueBufferRef, capacity: Int) {
        buffer.pointee.mAudioDataByteSize = UInt32(capacity)
        let enqueueStatus = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        if enqueueStatus == noErr {
            lockedState.withLock { state in
                // Depth counts frames the device will play; refused or withheld buffers never enter it.
                state.totalFramesEnqueued += Int64(capacity / state.frameSize)
                state.enqueuedBufferCount += 1
            }
        } else {
            lockedState.withLock { $0.enqueueFailures += 1 }
        }
    }

    // MARK: - Volume

    /// Set volume (0.0 to 1.0 linear). Applies a short ramp to avoid audible clicks.
    func setVolume(_ volume: Float) {
        let clampedVolume = max(0.0, min(1.0, volume))
        currentVolume = clampedVolume
        if !isMuted, fadingStopIdentity == nil {
            startVolumeRamp(to: clampedVolume)
        }
    }

    /// Set mute state.
    func setMute(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        guard fadingStopIdentity == nil else { return }
        if muted {
            cancelVolumeRamp()
            appliedVolume = 0.0
            volumeControl.setMute(true, currentVolume: currentVolume, on: audioQueue)
        } else {
            volumeControl.setVolume(0.0, on: audioQueue)
            volumeControl.setMute(false, currentVolume: 0.0, on: audioQueue)
            appliedVolume = 0.0
            startVolumeRamp(to: currentVolume)
        }
    }

    private func cancelVolumeRamp() {
        volumeRampTask?.cancel()
        volumeRampTask = nil
        volumeRampID += 1
    }

    private func startVolumeRamp(to targetVolume: Float) {
        cancelVolumeRamp()
        let rampID = volumeRampID
        let startVolume = appliedVolume
        guard startVolume != targetVolume else { return }

        let sleep = volumeRampSleep
        volumeRampTask = Task { [weak self] in
            for step in 1 ... volumeRampStepCount {
                if Task.isCancelled {
                    return
                }
                if step > 1 {
                    try? await sleep(volumeRampStepDuration)
                    if Task.isCancelled {
                        return
                    }
                }
                let progress = Float(step) / Float(volumeRampStepCount)
                let volume = startVolume + ((targetVolume - startVolume) * progress)
                await self?.applyRampVolume(volume, rampID: rampID, isFinal: step == volumeRampStepCount)
            }
        }
    }

    private func applyRampVolume(_ volume: Float, rampID: Int, isFinal: Bool) {
        guard rampID == volumeRampID else { return }
        appliedVolume = volume
        volumeControl.setVolume(volume, on: audioQueue)
        if isFinal {
            volumeRampTask = nil
        }
    }

    /// Reanchor target using the snapshot mapping of the local audible instant.
    /// Calculating a target does not change the timestamp of buffered source PCM.
    static func graceExpiryRebaselineCursor(
        snapshot: TimeFilterSnapshot,
        localNow: Int64,
        pipelineLatencyUs: Int64,
        outputDelayUs: Int64
    ) -> Int64 {
        correctionEquilibriumServerTime(
            snapshot: snapshot,
            localNow: localNow,
            pipelineLatencyUs: pipelineLatencyUs,
            outputDelayUs: outputDelayUs
        )
    }

    /// Convert linear volume (0.0-1.0) to perceptual amplitude.
    ///
    /// Uses a 1.5-power curve matching the Rust reference implementation.
    /// The spec requires volume 0-100 to represent perceived loudness, not
    /// linear amplitude — volume 50 should sound roughly half as loud as 100.
    static func perceptualGain(_ linearVolume: Float) -> Float {
        powf(linearVolume, 1.5)
    }
}

// MARK: - AudioOutput conformance

extension AudioPlayer: AudioOutput {
    // All required methods are already defined above
}

/// AudioQueue callback (C function)
private let audioQueueCallback: AudioQueueOutputCallback = { userData, queue, buffer in
    guard let userData else { return }
    let player = Unmanaged<AudioPlayer>.fromOpaque(userData).takeUnretainedValue()
    player.fillBuffer(queue: queue, buffer: buffer)
}

enum AudioPlayerError: Error, LocalizedError {
    case queueAllocationFailed(OSStatus)
    case queueStartFailed(OSStatus)
    case frameSizeExceedsCapacity(computed: Int, maximum: Int)
    case notStarted

    var errorDescription: String? {
        switch self {
        case let .queueAllocationFailed(status):
            "AudioQueue allocation failed (OSStatus \(status))"
        case let .queueStartFailed(status):
            "AudioQueue start failed (OSStatus \(status))"
        case let .frameSizeExceedsCapacity(computed, maximum):
            "Audio frame size \(computed) bytes exceeds capacity \(maximum) bytes"
        case .notStarted:
            "Audio player not started"
        }
    }
}
