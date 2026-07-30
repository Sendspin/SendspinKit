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

/// Maximum frame size in bytes: 8 channels × 4 bytes (Int32) per sample.
/// Constrains the fixed-size `lastFrameStorage` allocation.
private let maxFrameBytes = 8 * MemoryLayout<Int32>.size

/// Above this, `AudioQueueStart` is reported as a fault rather than a measurement. A healthy
/// start is 230-400ms on the machines measured; seconds means CoreAudio's IO thread never
/// reached its running state, which has coincided with audio that is consumed but inaudible.
let audioQueueStartSlowThresholdUs: Int64 = 2_000_000

/// Skip starting the queue at `prepare()` and start it at the release instant instead.
///
/// Diagnostic escape hatch for a CoreAudio stall seen in the field: `AudioQueueStart` blocks
/// for ~13.2s while the HAL IO thread never reaches its running state, after which the device
/// renders but is inaudible. Pre-warming calls `AudioQueueStart` within milliseconds of
/// `AudioQueueNewOutput`, where the previous design left seconds of buffering between them, so
/// the suspicion is a race with CoreAudio's asynchronous device setup. This exists so both
/// paths can be compared on one binary; delete it once that is settled either way.
let audioQueuePrewarmDisabled = ProcessInfo.processInfo.environment["SENDSPIN_NO_PREWARM"] == "1"

/// Byte size of each prepared AudioQueue buffer.
/// Shared with startup latency estimation so priming and correction use the same model.
let audioQueueBufferByteSize: UInt32 = 16_384

/// Buffers allocated and primed by `prepare()`, and so the pipeline depth once running.
///
/// Must stay the single source of truth for both the allocation loop and the latency
/// model: a mismatch is a constant offset that `graceExpiryRebaselineCursor` bakes in
/// permanently at grace expiry (~85ms per buffer at 48kHz/stereo/16-bit).
let audioQueueBufferCount = 3

private let volumeRampStepCount = 5
private let volumeRampStepDuration: Duration = .milliseconds(10)

/// All mutable state accessed from both the actor and the audio thread.
///
/// Wrapped in `OSAllocatedUnfairLock<LockedState>` so access is structurally
/// enforced: every read/write goes through `withLock`, making it impossible
/// to accidentally touch this state without holding the lock.
///
/// **Must not be copied.** The struct contains `UnsafeMutableRawBufferPointer`
/// fields that own their allocations. `withLock` provides `inout` access
/// (no copy), but `@unchecked Sendable` means the compiler won't catch
/// accidental copies elsewhere. Only one instance should ever exist,
/// owned by the `OSAllocatedUnfairLock` in `AudioPlayer`.
private struct LockedState: @unchecked Sendable {
    // Ring buffer
    var pcmRingBuffer: PCMRingBuffer
    var frameSize: Int = 0

    /// Last output frame for insert (sample-hold repeat) — fixed allocation
    var lastFrameStorage: UnsafeMutableRawBufferPointer =
        .allocate(byteCount: maxFrameBytes, alignment: 8)
    var lastFrameValid: Bool = false

    // Sync correction
    var correctionSchedule = CorrectionSchedule()
    var dropCounter: UInt32 = 0
    var insertCounter: UInt32 = 0
    var syncPlanner = CorrectionPlanner()
    /// `nil` until first sync snapshot arrives via `updateTimeSnapshot`.
    /// When nil, the audio callback skips sync correction — audio plays
    /// unsynchronized until the first clock sync completes.
    var timeSnapshot: TimeFilterSnapshot?

    /// Latest sync error in µs, written by audio callback, read by telemetry
    var lastSyncErrorUs: Int64 = 0
    var pendingReanchorServerTime: Int64 = 0
    var reanchorRequested: Bool = false
    /// Grace period: suppress sync correction after AudioQueue rebuild.
    /// Frames-based countdown (at 48kHz, 48000 frames = 1 second).
    var correctionGraceFrames: Int64 = 0

    // Playback cursor (server-time position of what's being output)
    var cursorMicroseconds: Int64 = 0
    var cursorRemainder: Int64 = 0
    var sampleRate: Int = 0
    var framesConsumed: Int64 = 0

    /// Latency beyond our own buffers — HAL, transport and DAC — captured at `prepare()`.
    /// The audio thread cannot query the HAL, so the value is read once and stored here.
    var deviceLatencyUs: Int64 = 0

    /// Absolute time `AudioQueueStart` was called, or 0 before it has been.
    var queueStartAbsoluteUs: Int64 = 0

    /// Frames handed to the AudioQueue since the queue started, silence included. With the
    /// device's played-frame count this gives the frames still in flight, and so when a frame
    /// written to the ring now will be audible.
    var totalFramesEnqueued: Int64 = 0

    /// True from `prepare()` until the first real PCM reaches the ring. The queue is running
    /// on silence in that window so the device pays its spin-up before audio depends on it,
    /// and an empty ring there is the intent rather than a dropout.
    var prewarming: Bool = true

    /// Absolute-time gap between `AudioQueueStart` and the device's first callback,
    /// or -1 until that callback lands. An idle USB DAC takes far longer to begin
    /// producing than the primed depth predicts, and the gap varies run to run, so it
    /// is measured rather than modelled.
    var spinUpUs: Int64 = -1

    /// Silence frames inserted ahead of the first real frame to land it on its due instant.
    var startupPadFrames: Int64 = 0

    /// Enqueue calls the queue refused, cumulative. A queue primed with fewer buffers than
    /// intended starts without error and then produces silence, so a discarded status here is
    /// indistinguishable from working until someone listens.
    var enqueueFailures: Int64 = 0

    /// Buffers handed to the device with nothing read from the ring, since the last telemetry
    /// read. Counted separately from underruns, which are suppressed during pre-warm.
    var silentBufferCount: Int64 = 0

    /// Largest absolute sample value handed to the device since the last telemetry read,
    /// as a fraction of full scale. The most basic health question — is anything actually
    /// coming out — is otherwise unanswerable: every counter reads clean over silence.
    var peakOutputLevel: Float = 0

    /// Sync error at the instant grace expired, before the rebaseline absorbed it, or
    /// `nil` until then. This is the offset playback actually starts at; without it the
    /// post-rebaseline error reads ~0 no matter how far out the start was.
    var startupOffsetUs: Int64?

    // Diagnostics
    var underrunCount: Int64 = 0
    var pcmBytesDropped: Int64 = 0

    /// Effective format for the process callback — set in start(),
    /// read from the audio thread to pass to the callback.
    var processCallbackFormat: AudioFormatSpec?

    /// Advance the playback cursor by one frame using integer arithmetic
    /// to avoid floating-point drift.
    mutating func advanceCursor() {
        guard sampleRate > 0 else { return }
        let usPerFrame = 1_000_000 / Int64(sampleRate)
        let usRemainder = 1_000_000 % Int64(sampleRate)

        cursorMicroseconds += usPerFrame
        cursorRemainder += usRemainder
        if cursorRemainder >= Int64(sampleRate) {
            cursorRemainder -= Int64(sampleRate)
            cursorMicroseconds += 1
        }
        framesConsumed += 1
    }

    /// Deallocate owned resources. Must be called exactly once before the
    /// containing `OSAllocatedUnfairLock` is released.
    mutating func deallocateResources() {
        pcmRingBuffer.deallocate()
        lastFrameStorage.deallocate()
    }
}

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

    /// Buffers held back for `startPrepared()` when pre-warm is disabled; empty otherwise.
    private var pendingStartBuffers: [AudioQueueBufferRef] = []

    private var _isPlaying: Bool = false

    /// All state shared between the actor and the audio thread, protected by
    /// `OSAllocatedUnfairLock` with priority donation. Access is structurally
    /// enforced: every read/write goes through `withLock`.
    private nonisolated let lockedState: OSAllocatedUnfairLock<LockedState>

    private var currentVolume: Float = 1.0
    private var appliedVolume: Float = 1.0
    private var volumeRampTask: Task<Void, Never>?
    private var volumeRampID = 0
    private var isMuted: Bool = false
    private let volumeControl: VolumeControl

    /// Process callback for local visualization / audio effects.
    /// Set once at init, never mutated — `@Sendable` and safe to read from any context.
    private nonisolated let processCallback: AudioProcessCallback?

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
        processCallback: AudioProcessCallback? = nil
    ) {
        self.volumeControl = volumeControl
        self.processCallback = processCallback
        lockedState = OSAllocatedUnfairLock(
            initialState: LockedState(pcmRingBuffer: PCMRingBuffer(capacity: pcmBufferCapacity))
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
        stop()

        decoder = try AudioDecoderFactory.create(
            codec: format.codec,
            sampleRate: format.sampleRate,
            channels: format.channels,
            bitDepth: format.bitDepth,
            header: codecHeader
        )

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
            state.startupPadFrames = 0
            state.enqueueFailures = 0
            state.startupOffsetUs = nil
            state.frameSize = computedFrameSize
            state.processCallbackFormat = effectiveFormat
            state.lastFrameValid = false
            memset(state.lastFrameStorage.baseAddress!, 0, state.lastFrameStorage.count)
            state.pcmRingBuffer.reset()
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

        try allocateAndPrewarm(queue: queue)
    }

    /// Allocate the queue's buffers and start it on silence.
    ///
    /// Started here rather than at the release instant because an idle DAC takes 300-400ms to
    /// begin producing and the figure varies by ~100ms between starts, so it cannot be led by an
    /// estimate — but paid during the window already spent buffering, it is spent before any
    /// audio depends on it. The ring is empty, so every buffer enqueued below is silence.
    private func allocateAndPrewarm(queue: AudioQueueRef) throws {
        var allocated: [AudioQueueBufferRef] = []
        for _ in 0 ..< audioQueueBufferCount {
            var buffer: AudioQueueBufferRef?
            let allocStatus = AudioQueueAllocateBuffer(queue, audioQueueBufferByteSize, &buffer)
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
            // Operational, app-owner-facing: the engine's command loop is stalled for this whole
            // span, and a start this slow has been seen to leave the device consuming audio that
            // never reaches the speakers. Logged at .notice so it appears in a user-collected
            // diagnostic without debug logging enabled.
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
    }

    /// Delay between handing a frame to the output and hearing it: the depth of the AudioQueue
    /// buffers this player primes, plus the device path beyond them.
    ///
    /// Single source for both consumers of that quantity — the engine, deciding when to hand
    /// the first chunk over, and the sync corrector, deciding how far the cursor should lead
    /// the speaker. They describe the same physical span, and two formulas for it drift.
    ///
    /// Zero before `prepare()`, which is the only point at which the format and the device are
    /// both known.
    func pipelineLatencyMicroseconds() -> Int64 {
        guard let format = currentFormat else { return 0 }
        let bytesPerFrame = format.channels * (format.effectiveOutputBitDepth / 8)
        guard bytesPerFrame > 0, format.sampleRate > 0 else { return 0 }
        let queueDepthUs = Int64(audioQueueBufferCount) * Int64(audioQueueBufferByteSize) * 1_000_000
            / Int64(format.sampleRate * bytesPerFrame)
        return queueDepthUs + lockedState.withLock { $0.deviceLatencyUs }
    }

    /// True once the device has delivered its first callback.
    ///
    /// Until then nothing is known about the pipeline: `AudioQueueGetCurrentTime` reports
    /// nothing played, so a placement computed against it is fiction, and PCM released on
    /// schedule sits in the ring until the device wakes and then plays that stale. Spin-up is
    /// normally a few hundred milliseconds but has been measured at 13 seconds.
    var outputDeviceIsLive: Bool {
        // With pre-warm disabled the queue does not exist until the release, so there is no
        // device to wait for and gating on it would deadlock the startup path.
        audioQueuePrewarmDisabled || lockedState.withLock { $0.spinUpUs >= 0 }
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
            return
        }

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
        }
        let desc = "\(format.codec.rawValue) \(format.sampleRate)Hz"
            + " \(format.channels)ch \(format.bitDepth)bit (output: \(format.effectiveOutputBitDepth)-bit)"
        Log.audio.info("AudioQueue started: \(desc, privacy: .public)")
        _isPlaying = true
    }

    /// Start playback with specified format.
    func start(format: AudioFormatSpec, codecHeader: Data?) throws {
        try prepare(format: format, codecHeader: codecHeader)
        try startPrepared()
    }

    /// Stop playback and clean up
    func stop() {
        cancelVolumeRamp()
        guard let queue = audioQueue else { return }

        AudioQueueStop(queue, true)
        AudioQueueDispose(queue, true)

        audioQueue = nil
        decoder = nil
        currentFormat = nil
        _isPlaying = false

        lockedState.withLock { state in
            state.pcmRingBuffer.reset()
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
        currentFormat = format
    }

    /// Decode compressed audio data to PCM
    func decode(_ data: Data) throws -> Data {
        guard let decoder else {
            throw AudioPlayerError.notStarted
        }
        return try decoder.decode(data)
    }

    /// Enqueue PCM data into the ring buffer for consumption by the AudioQueue callback.
    func playPCM(_ pcmData: Data, serverTimestamp: Int64) throws {
        guard let queue = audioQueue, currentFormat != nil else {
            throw AudioPlayerError.notStarted
        }

        // Only the pad allocation happens outside the lock. The three quantities the placement
        // divides — frames played, the instant that reading describes, and frames enqueued —
        // must come from one coherent moment: a callback landing between them advances the
        // enqueued count against a stale played count, overstating what is in flight by a whole
        // buffer and collapsing the pad to nothing.
        let silence = lockedState.withLock { $0.prewarming } ? Data(count: maxStartupPadBytes()) : Data()

        // Unchecked because the queue handle is not `Sendable`; this closure runs synchronously
        // on the actor and the handle outlives it.
        lockedState.withLockUnchecked { state in
            if state.prewarming {
                Self.placeFirstFrame(
                    state: &state,
                    serverTimestamp: serverTimestamp,
                    framesPlayed: Self.framesPlayed(queue: queue),
                    nowAbsolute: MonotonicClock.absoluteMicroseconds(),
                    silence: silence
                )
            }
            state.prewarming = false
            // Frame-aligned: a byte-truncated write would misalign every later frame read.
            let written = state.pcmRingBuffer.writeFrames(pcmData, frameSize: state.frameSize)
            let dropped = pcmData.count - written
            if dropped > 0 {
                state.pcmBytesDropped += Int64(dropped)
            }
        }
    }

    /// Ceiling on the startup silence pad, in bytes: one pipeline depth of frames.
    private func maxStartupPadBytes() -> Int {
        guard let format = currentFormat else { return 0 }
        let frameSize = format.channels * (format.effectiveOutputBitDepth / 8)
        let frames = pipelineLatencyMicroseconds() * Int64(format.sampleRate) / 1_000_000
        return Int(frames) * frameSize
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

    /// Pad the ring with silence so the first real frame lands on its due instant.
    ///
    /// Once the queue is running the device consumes at exactly the sample rate, so a frame's
    /// audible instant is fixed by its position in the stream, not by when the callback
    /// happened to pull it. That makes the placement exact rather than quantised to the
    /// callback cadence: the next frame written becomes audible once the frames still in
    /// flight have played, plus the device path.
    ///
    /// A negative pad means the release instant has already passed; those frames can never be
    /// audible on time, so they are dropped rather than played late.
    private static func placeFirstFrame(
        state: inout LockedState,
        serverTimestamp: Int64,
        framesPlayed: Int64,
        nowAbsolute: Int64,
        silence: Data
    ) {
        let sampleRate = Int64(state.sampleRate)
        guard sampleRate > 0, state.frameSize > 0, let snapshot = state.timeSnapshot else {
            // Without clock sync there is no due instant to place against.
            state.cursorMicroseconds = serverTimestamp
            return
        }

        let framesInFlight = max(0, state.totalFramesEnqueued - framesPlayed)
        let audibleServerTime = snapshot.localTimeToServer(nowAbsolute)
            + framesInFlight * 1_000_000 / sampleRate
            + state.deviceLatencyUs

        let padCapacityFrames = Int64(silence.count / state.frameSize)
        let padFrames = min(
            max((serverTimestamp - audibleServerTime) * sampleRate / 1_000_000, 0),
            padCapacityFrames
        )
        if padFrames > 0 {
            state.pcmRingBuffer.writeFrames(
                silence.prefix(Int(padFrames) * state.frameSize),
                frameSize: state.frameSize
            )
        }

        // The pad is indistinguishable from audio once in the ring, so it advances the cursor
        // too. Seating the cursor this far back leaves it reading exactly `serverTimestamp`
        // at the moment the first real frame is handed over.
        state.cursorMicroseconds = serverTimestamp - padFrames * 1_000_000 / sampleRate
        state.startupPadFrames = padFrames
    }

    // MARK: - Sync correction interface

    /// Push a new time filter snapshot for use by the audio callback.
    /// Called from the clock sync path whenever processServerTime updates the filter.
    /// Cleared back to nil by `stop()`.
    func updateTimeSnapshot(_ snapshot: TimeFilterSnapshot) {
        lockedState.withLock { $0.timeSnapshot = snapshot }
    }

    /// Reanchor the playback cursor to a new server time position.
    func reanchorCursor(to serverTimeMicros: Int64) {
        lockedState.withLock { state in
            state.cursorMicroseconds = serverTimeMicros
            state.cursorRemainder = 0
            state.pcmRingBuffer.reset()
            state.correctionSchedule = CorrectionSchedule()
            state.dropCounter = 0
            state.insertCounter = 0
            state.reanchorRequested = false
        }
    }

    /// Check if the audio callback requested a reanchor. Returns the target server time
    /// if so, and clears the flag. Called from the sync/telemetry loop.
    func pollReanchor() -> Int64? {
        lockedState.withLock { state -> Int64? in
            guard state.reanchorRequested else { return nil }
            state.reanchorRequested = false
            return state.pendingReanchorServerTime
        }
    }

    /// Telemetry snapshot — read by the external telemetry loop for logging.
    struct TelemetrySnapshot {
        let cursorMicroseconds: Int64
        let sampleRate: Int
        let syncErrorUs: Int64
        let correctionSchedule: CorrectionSchedule
        let underrunCount: Int64
        let pcmBytesDropped: Int64
        /// Sync error at grace expiry, before the rebaseline froze it. `nil` until then.
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
    }

    /// Capture telemetry state atomically for the logging loop.
    var telemetrySnapshot: TelemetrySnapshot {
        let played = audioQueue.map { Self.framesPlayed(queue: $0) } ?? 0
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
        let deviceGain = OutputDeviceLatency.currentDeviceGain()
        // Read-and-clear: the peak describes the interval since the last read, so a signal that
        // stops is visible rather than latched forever by one loud buffer.
        let (peak, silentBuffers) = lockedState.withLock { state -> (Float, Int64) in
            let values = (state.peakOutputLevel, state.silentBufferCount)
            state.peakOutputLevel = 0
            state.silentBufferCount = 0
            return values
        }
        return lockedState.withLock { state in
            TelemetrySnapshot(
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
                framesInFlight: max(0, state.totalFramesEnqueued - played)
            )
        }
    }

    /// Clear buffered PCM data (for seek/stream clear without stopping playback)
    func clearBuffer() {
        lockedState.withLock { $0.pcmRingBuffer.reset() }
    }

    // MARK: - AudioQueue callback (runs on audio thread)

    /// Result of the locked buffer-fill operation. Captures everything needed
    /// for post-lock work (silence fill, process callback, enqueue).
    private struct FillResult {
        let outOffset: Int
        let cb: AudioProcessCallback?
        let cbFormat: AudioFormatSpec?
    }

    private static func updateCorrectionSchedule(
        state: inout LockedState,
        capacity: Int,
        frameSize: Int,
        sampleRate: Int
    ) {
        guard state.cursorMicroseconds > 0, let snapshot = state.timeSnapshot else { return }
        let nowAbsolute = MonotonicClock.absoluteMicroseconds()
        let expectedServerTime = snapshot.localTimeToServer(nowAbsolute)

        // Everything between pulling a frame here and hearing it: every primed buffer — so this
        // must use the same count `prepare()` primes — plus the device path beyond them.
        let queueDepthUs = Int64(audioQueueBufferCount * capacity) * 1_000_000 / Int64(sampleRate * frameSize)
        let aqLatencyUs = queueDepthUs + state.deviceLatencyUs

        // A frame pulled here is audible `aqLatencyUs` from now, and must be audible at
        // `local(cursor)` — so in equilibrium the cursor LEADS `expectedServerTime` by that
        // latency. Subtracting it instead of adding puts the reported error `2 * aqLatencyUs`
        // from the truth, which makes every change to the latency model move the equilibrium
        // by twice the change. Positive means late: the cursor is behind where it should be.
        let syncErrorUs = (expectedServerTime + aqLatencyUs) - state.cursorMicroseconds
        state.lastSyncErrorUs = syncErrorUs

        let framesInBuffer = capacity / frameSize
        var graceAbsorbedThisCallback = false
        if state.correctionGraceFrames > 0 {
            state.correctionGraceFrames -= Int64(framesInBuffer)
            if state.correctionGraceFrames <= 0 {
                // The grace window intentionally plays startup audio without pitch
                // correction while AudioQueue callback/cursor bookkeeping settles.
                // Do not feed the accumulated grace-era bias directly into the
                // corrector on the expiry callback — that creates an audible max-rate
                // insert/drop ramp at ~1s. Instead, rebaseline the cursor to the same
                // equilibrium used by the sync-error formula, then let the next
                // callback correct only real drift.
                state.startupOffsetUs = syncErrorUs
                state.cursorMicroseconds = graceExpiryRebaselineCursor(
                    expectedServerTime: expectedServerTime,
                    audioQueueLatencyUs: aqLatencyUs
                )
                state.cursorRemainder = 0
                state.correctionSchedule = CorrectionSchedule()
                state.dropCounter = 0
                state.insertCounter = 0
                state.lastSyncErrorUs = 0
                graceAbsorbedThisCallback = true
            }
        }

        let newSchedule: CorrectionSchedule = if state.correctionGraceFrames > 0 || graceAbsorbedThisCallback {
            CorrectionSchedule() // no correction during grace period or its expiry handoff
        } else {
            state.syncPlanner.plan(
                errorMicroseconds: syncErrorUs,
                sampleRate: UInt32(sampleRate),
                currentlyCorrecting: state.correctionSchedule.isCorrecting
            )
        }

        if newSchedule.reanchor {
            // Can't reset the ring buffer and cursor here safely while iterating,
            // so signal the actor to handle it on the next poll.
            // The cursor leads by the pipeline latency in equilibrium, so a reanchor must
            // target that, not bare `expectedServerTime` — which would leave the very next
            // callback reporting the latency itself as error.
            state.pendingReanchorServerTime = graceExpiryRebaselineCursor(
                expectedServerTime: expectedServerTime,
                audioQueueLatencyUs: aqLatencyUs
            )
            state.reanchorRequested = true
            state.correctionSchedule = CorrectionSchedule()
            state.dropCounter = 0
            state.insertCounter = 0
        } else if newSchedule != state.correctionSchedule {
            let wasActive = state.correctionSchedule.isCorrecting
            state.correctionSchedule = newSchedule
            if newSchedule.isCorrecting, !wasActive {
                // Initialize counters to the full cadence value — the first correction
                // fires after one full cycle, giving the schedule time to stabilize
                // before modifying the output.
                state.dropCounter = newSchedule.dropEveryNFrames
                state.insertCounter = newSchedule.insertEveryNFrames
            }
        }
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
            guard fs > 0 else {
                return FillResult(outOffset: 0, cb: nil, cbFormat: nil)
            }

            let sr = state.sampleRate
            let cb = processCallback // nonisolated let, not in locked state
            let cbFormat = state.processCallbackFormat
            let channels = cbFormat?.channels ?? 2

            // `prepare()` fills every buffer through this path before the queue is started,
            // so the first callback with a start time recorded is the device's own.
            if state.spinUpUs < 0, state.queueStartAbsoluteUs > 0 {
                state.spinUpUs = MonotonicClock.absoluteMicroseconds() - state.queueStartAbsoluteUs
            }

            Self.updateCorrectionSchedule(state: &state, capacity: capacity, frameSize: fs, sampleRate: sr)

            // --- Fill the buffer with PCM frames, applying drop/insert correction ---
            var outOffset = 0
            while outOffset + fs <= capacity {
                // --- Drop cadence: consume a frame without writing it ---
                if state.correctionSchedule.dropEveryNFrames > 0 {
                    state.dropCounter = state.dropCounter > 0 ? state.dropCounter - 1 : 0
                    if state.dropCounter == 0 {
                        state.dropCounter = state.correctionSchedule.dropEveryNFrames
                        if state.pcmRingBuffer.availableToRead >= fs {
                            state.pcmRingBuffer.skip(fs)
                            state.advanceCursor()
                        }
                    }
                }

                // --- Insert cadence: repeat last frame without consuming ---
                if state.correctionSchedule.insertEveryNFrames > 0 {
                    state.insertCounter = state.insertCounter > 0 ? state.insertCounter - 1 : 0
                    if state.insertCounter == 0 {
                        state.insertCounter = state.correctionSchedule.insertEveryNFrames
                        if state.lastFrameValid {
                            memcpy(dest + outOffset, state.lastFrameStorage.baseAddress!, fs)
                        } else {
                            memset(dest + outOffset, 0, fs)
                        }
                        outOffset += fs
                        continue
                    }
                }

                // --- Normal: consume one frame and write it ---
                if state.pcmRingBuffer.availableToRead >= fs {
                    state.pcmRingBuffer.read(into: dest + outOffset, count: fs)
                    memcpy(state.lastFrameStorage.baseAddress!, dest + outOffset, fs)
                    state.lastFrameValid = true
                    state.advanceCursor()
                    outOffset += fs
                } else {
                    if !state.prewarming {
                        state.underrunCount += 1
                    }
                    break
                }
            }

            state.totalFramesEnqueued += Int64(capacity / fs)
            if outOffset == 0 {
                state.silentBufferCount += 1
            }
            let peak = Self.peakMagnitude(dest, byteCount: outOffset, bytesPerSample: fs / max(1, channels))
            state.peakOutputLevel = max(state.peakOutputLevel, peak)

            return FillResult(outOffset: outOffset, cb: cb, cbFormat: cbFormat)
        }

        // --- Post-lock: silence fill, process callback, enqueue ---
        // None of this touches shared state.

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

        buffer.pointee.mAudioDataByteSize = UInt32(capacity)
        let enqueueStatus = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        // Only touched on failure, so the normal path pays nothing for the check.
        if enqueueStatus != noErr {
            lockedState.withLock { $0.enqueueFailures += 1 }
        }
    }

    // MARK: - Volume

    /// Set volume (0.0 to 1.0 linear). Applies a short ramp to avoid audible clicks.
    func setVolume(_ volume: Float) {
        let clampedVolume = max(0.0, min(1.0, volume))
        currentVolume = clampedVolume
        if !isMuted {
            startVolumeRamp(to: clampedVolume)
        }
    }

    /// Set mute state.
    func setMute(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
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

        volumeRampTask = Task { [weak self] in
            for step in 1 ... volumeRampStepCount {
                if Task.isCancelled {
                    return
                }
                if step > 1 {
                    try? await Task.sleep(for: volumeRampStepDuration)
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

    /// Cursor position that makes the sync-error formula evaluate to equilibrium
    /// at the startup correction-grace handoff.
    ///
    /// Cursor position at which the sync-error formula reads zero — the equilibrium in
    /// which the cursor leads `expectedServerTime` by the pipeline latency.
    ///
    /// While startup grace is open, correction is intentionally disabled so AudioQueue
    /// callback/cursor bookkeeping can settle without pitch-shifting output. On the
    /// expiry callback, the measured error can include that grace-era bookkeeping
    /// bias; feeding it directly to the corrector creates an audible max-rate ramp.
    ///
    /// This *asserts* the equilibrium rather than measuring it, so whatever misalignment
    /// exists at grace expiry becomes permanent and subsequently reads as perfect sync.
    /// `TelemetrySnapshot.startupOffsetUs` is the only place that misalignment is visible.
    static func graceExpiryRebaselineCursor(expectedServerTime: Int64, audioQueueLatencyUs: Int64) -> Int64 {
        expectedServerTime + audioQueueLatencyUs
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
