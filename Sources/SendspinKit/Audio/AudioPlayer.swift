// ABOUTME: Manages AudioQueue-based audio playback with frame-level sync correction
// ABOUTME: Applies drop/insert cadence from CorrectionPlanner to maintain clock sync

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

    // Last output frame for insert (sample-hold repeat) — fixed allocation
    var lastFrameStorage: UnsafeMutableRawBufferPointer =
        .allocate(byteCount: maxFrameBytes, alignment: 8)
    var lastFrameValid: Bool = false

    // Sync correction
    var correctionSchedule = CorrectionSchedule()
    var dropCounter: UInt32 = 0
    var insertCounter: UInt32 = 0
    var syncPlanner = CorrectionPlanner()
    var timeSnapshot: TimeFilterSnapshot = .invalid

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
        precondition(sampleRate > 0, "advanceCursor called before sampleRate was set")
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

    private var _isPlaying: Bool = false

    /// All state shared between the actor and the audio thread, protected by
    /// `OSAllocatedUnfairLock` with priority donation. Access is structurally
    /// enforced: every read/write goes through `withLock`.
    private nonisolated let lockedState: OSAllocatedUnfairLock<LockedState>

    private var currentVolume: Float = 1.0
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
        // Dispose the AudioQueue synchronously to prevent callbacks firing into
        // a dangling Unmanaged pointer. We can't call the actor-isolated stop()
        // from nonisolated deinit, so we dispose via the nonisolated copy.
        if let queue = audioQueueForDeinit {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
        }
        lockedState.withLock { $0.deallocateResources() }
    }

    /// Start playback with specified format
    ///
    /// **Unmanaged safety:** `passUnretained(self)` is used to pass `self` as the
    /// AudioQueue callback client data. This is safe because:
    /// - `audioQueue` is set immediately after `AudioQueueNewOutput` (no throwing
    ///   calls between creation and assignment)
    /// - `stop()` disposes the queue during normal operation
    /// - `deinit` disposes the queue directly (can't call actor-isolated `stop()`)
    /// Do not insert throwing calls between `AudioQueueNewOutput` and `audioQueue = queue`.
    func start(format: AudioFormatSpec, codecHeader: Data?) throws {
        if _isPlaying, currentFormat == format { return }

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
        let effectiveFormat = AudioFormatSpec(
            codec: .pcm,
            channels: format.channels,
            sampleRate: format.sampleRate,
            bitDepth: effectiveBitDepth
        )

        let computedFrameSize = format.channels * bytesPerSample
        precondition(
            computedFrameSize <= maxFrameBytes,
            "Frame size \(computedFrameSize) exceeds lastFrameStorage capacity \(maxFrameBytes)"
        )

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
            // The transient sync error from the AudioQueue rebuild settles
            // naturally; correcting during this period causes audible artifacts.
            state.correctionGraceFrames = Int64(format.sampleRate)
        }

        // Allocate and prime buffers.
        // 16384 bytes = ~4096 frames @ 48kHz stereo 16-bit = ~85ms per callback.
        // 3 buffers primed = ~256ms pipeline latency. Sync correction runs inside
        // each callback, so we get ~85ms feedback loops — sufficient for ±1-3ms
        // steady-state accuracy. Smaller buffers cause instability due to the
        // correction schedule updating too frequently relative to its effect.
        let bufferSize: UInt32 = 16_384
        for _ in 0 ..< 3 {
            var buffer: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(queue, bufferSize, &buffer) == noErr, let buffer {
                fillBuffer(queue: queue, buffer: buffer)
            }
        }

        let startStatus = AudioQueueStart(queue, nil)
        if startStatus != noErr {
            // Clean up the allocated-but-not-started queue to prevent resource leak
            AudioQueueDispose(queue, true)
            audioQueue = nil
            currentFormat = nil
            decoder = nil
            throw AudioPlayerError.queueStartFailed(startStatus)
        }
        let desc = "\(format.codec.rawValue) \(format.sampleRate)Hz"
            + " \(format.channels)ch \(format.bitDepth)bit (output: \(effectiveBitDepth)-bit)"
        fputs("[AUDIO] AudioQueue started: \(desc)\n", stderr)
        _isPlaying = true
    }

    /// Stop playback and clean up
    func stop() {
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

            // --- Compute sync error and update correction schedule ---
            // Monotonic clock and cursor are read in the same lock scope = zero jitter.
            if state.cursorMicroseconds > 0, state.timeSnapshot.isValid {
                let nowAbsolute = MonotonicClock.absoluteMicroseconds()
                let expectedServerTime = state.timeSnapshot.localToServerTime(nowAbsolute)

                // AQ pipeline latency estimate: ~2 buffers in flight (1 playing + 1 queued).
                // Actual depth can vary slightly, but this is sufficient for the continuous
                // sync correction loop which converges regardless of a small constant bias.
                let aqLatencyUs = Int64(2 * capacity) * 1_000_000 / Int64(sr * fs)

                let syncErrorUs = (expectedServerTime - state.cursorMicroseconds) - aqLatencyUs
                state.lastSyncErrorUs = syncErrorUs

                // During grace period after AudioQueue rebuild, measure sync error
                // (for telemetry) but don't engage correction. The transient error
                // from the rebuild settles naturally without pitch-shifting the audio.
                let framesInBuffer = capacity / fs
                if state.correctionGraceFrames > 0 {
                    state.correctionGraceFrames -= Int64(framesInBuffer)
                }

                let newSchedule: CorrectionSchedule = if state.correctionGraceFrames > 0 {
                    CorrectionSchedule() // no correction during grace period
                } else {
                    state.syncPlanner.plan(
                        errorMicroseconds: syncErrorUs,
                        sampleRate: UInt32(sr),
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
                        // Initialize counters to the full cadence value — the first
                        // correction fires after one full cycle, giving the schedule
                        // time to stabilize before modifying the output.
                        state.dropCounter = newSchedule.dropEveryNFrames
                        state.insertCounter = newSchedule.insertEveryNFrames
                    }
                }
            }

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

    /// Set volume (0.0 to 1.0 linear). Delegates to the configured VolumeControl.
    func setVolume(_ volume: Float) {
        let clampedVolume = max(0.0, min(1.0, volume))
        currentVolume = clampedVolume
        if !isMuted {
            volumeControl.setVolume(clampedVolume, on: audioQueue)
        }
    }

    /// Set mute state. Delegates to the configured VolumeControl.
    func setMute(_ muted: Bool) {
        isMuted = muted
        volumeControl.setMute(muted, currentVolume: currentVolume, on: audioQueue)
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

/// AudioQueue callback (C function)
private let audioQueueCallback: AudioQueueOutputCallback = { userData, queue, buffer in
    guard let userData else { return }
    let player = Unmanaged<AudioPlayer>.fromOpaque(userData).takeUnretainedValue()
    player.fillBuffer(queue: queue, buffer: buffer)
}

enum AudioPlayerError: Error, LocalizedError {
    case queueAllocationFailed(OSStatus)
    case queueStartFailed(OSStatus)
    case notStarted

    var errorDescription: String? {
        switch self {
        case let .queueAllocationFailed(status):
            "AudioQueue allocation failed (OSStatus \(status))"
        case let .queueStartFailed(status):
            "AudioQueue start failed (OSStatus \(status))"
        case .notStarted:
            "Audio player not started"
        }
    }
}
