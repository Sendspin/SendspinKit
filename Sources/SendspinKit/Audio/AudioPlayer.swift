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

/// Byte size of each prepared AudioQueue buffer.
/// Shared with startup latency estimation so priming and correction use the same model.
let audioQueueBufferByteSize: UInt32 = 16_384

/// Approximate number of AudioQueue buffers audible/in flight.
/// The sync-error formula treats one buffer as playing and one as queued.
let audioQueueEstimatedInFlightBuffers = 2

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
    private var pendingStartBuffers: [AudioQueueBufferRef] = []
    private var preparedStartCursorAnchor: Int64?

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

        lockedState.withLock { state in
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

        // Buffers are allocated here but intentionally not enqueued yet. Enqueuing
        // calls `fillBuffer`, and startup must first put decoded PCM into the ring;
        // otherwise the primed AudioQueue buffers are silence and the sync corrector
        // has to audibly insert its way out of the initial empty-ring offset.
        pendingStartBuffers.removeAll(keepingCapacity: true)
        preparedStartCursorAnchor = nil
        for _ in 0 ..< 3 {
            var buffer: AudioQueueBufferRef?
            let allocStatus = AudioQueueAllocateBuffer(queue, audioQueueBufferByteSize, &buffer)
            guard allocStatus == noErr, let buffer else {
                AudioQueueDispose(queue, true)
                audioQueue = nil
                currentFormat = nil
                decoder = nil
                pendingStartBuffers.removeAll()
                throw AudioPlayerError.queueAllocationFailed(allocStatus)
            }
            pendingStartBuffers.append(buffer)
        }
    }

    /// Start a prepared queue after decoded PCM has been written to the ring.
    func startPrepared() throws {
        guard let queue = audioQueue, let format = currentFormat else {
            throw AudioPlayerError.notStarted
        }
        if _isPlaying { return }

        for buffer in pendingStartBuffers {
            fillBuffer(queue: queue, buffer: buffer)
        }
        pendingStartBuffers.removeAll(keepingCapacity: true)
        if let preparedStartCursorAnchor {
            lockedState.withLock { state in
                // `startPrepared()` pre-fills AudioQueue buffers synchronously before
                // any samples are audible. Reset the cursor to the first primed sample;
                // the startup correction-grace handoff rebaselines any transient
                // callback/bookkeeping bias when correction is enabled.
                state.cursorMicroseconds = preparedStartCursorAnchor
                state.cursorRemainder = 0
            }
            self.preparedStartCursorAnchor = nil
        }

        let startStatus = AudioQueueStart(queue, nil)
        if startStatus != noErr {
            // Clean up the allocated-but-not-started queue to prevent resource leak
            AudioQueueDispose(queue, true)
            audioQueue = nil
            currentFormat = nil
            decoder = nil
            pendingStartBuffers.removeAll()
            throw AudioPlayerError.queueStartFailed(startStatus)
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
        pendingStartBuffers.removeAll()
        preparedStartCursorAnchor = nil
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

    /// Configure the startup cursor anchor that will be applied after
    /// `startPrepared()` synchronously fills the initial AudioQueue buffers, but
    /// before `AudioQueueStart` lets the render callback race with actor state.
    func alignPreparedStartCursor(firstServerTimestamp: Int64) {
        preparedStartCursorAnchor = firstServerTimestamp
    }

    /// Enqueue PCM data into the ring buffer for consumption by the AudioQueue callback.
    func playPCM(_ pcmData: Data, serverTimestamp: Int64) throws {
        guard audioQueue != nil, currentFormat != nil else {
            throw AudioPlayerError.notStarted
        }

        lockedState.withLock { state in
            // Set cursor to first chunk's timestamp if not yet initialized
            if state.framesConsumed == 0, state.cursorMicroseconds == 0 {
                state.cursorMicroseconds = serverTimestamp
            }
            let written = state.pcmRingBuffer.write(pcmData)
            let dropped = pcmData.count - written
            if dropped > 0 {
                state.pcmBytesDropped += Int64(dropped)
            }
        }
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
    }

    /// Capture telemetry state atomically for the logging loop.
    var telemetrySnapshot: TelemetrySnapshot {
        lockedState.withLock { state in
            TelemetrySnapshot(
                cursorMicroseconds: state.cursorMicroseconds,
                sampleRate: state.sampleRate,
                syncErrorUs: state.lastSyncErrorUs,
                correctionSchedule: state.correctionSchedule,
                underrunCount: state.underrunCount,
                pcmBytesDropped: state.pcmBytesDropped
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

        // AQ pipeline latency estimate: ~2 buffers in flight (1 playing + 1 queued).
        // Actual depth can vary slightly, but this is sufficient for the continuous
        // sync correction loop which converges regardless of a small constant bias.
        let aqLatencyUs = Int64(2 * capacity) * 1_000_000 / Int64(sampleRate * frameSize)

        let syncErrorUs = (expectedServerTime - state.cursorMicroseconds) - aqLatencyUs
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
            state.pendingReanchorServerTime = expectedServerTime
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
                    state.underrunCount += 1
                    break
                }
            }

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
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
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
                if Task.isCancelled { return }
                if step > 1 {
                    try? await Task.sleep(for: volumeRampStepDuration)
                    if Task.isCancelled { return }
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
    /// `fillBuffer` computes sync error as `(expectedServerTime - cursor) - aqLatency`.
    /// While startup grace is open, correction is intentionally disabled so AudioQueue
    /// callback/cursor bookkeeping can settle without pitch-shifting output. On the
    /// expiry callback, the measured error can include that grace-era bookkeeping
    /// bias; feeding it directly to the corrector creates an audible max-rate ramp.
    /// Rebaselining to this cursor absorbs the grace-era bias while preserving future
    /// drift correction.
    static func graceExpiryRebaselineCursor(expectedServerTime: Int64, audioQueueLatencyUs: Int64) -> Int64 {
        expectedServerTime - audioQueueLatencyUs
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
