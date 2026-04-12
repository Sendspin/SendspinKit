// ABOUTME: Manages AudioQueue-based audio playback with frame-level sync correction
// ABOUTME: Applies drop/insert cadence from CorrectionPlanner to maintain clock sync

import AudioToolbox
import Foundation

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

/// Actor managing synchronized audio playback
actor AudioPlayer {
    private let bufferManager: BufferManager
    private let clockSync: ClockSynchronizer

    private var audioQueue: AudioQueueRef?
    private var decoder: AudioDecoder?
    private var currentFormat: AudioFormatSpec?

    private var _isPlaying: Bool = false

    /// Ring buffer consumed by AudioQueue callback.
    /// All fields accessed under pcmBufferLock from the audio thread.
    private nonisolated let pcmBufferLock = NSLock()
    /// Ring buffer sized relative to the compressed buffer capacity.
    /// Decompressed PCM is ~10-20x larger than compressed audio, but we don't
    /// need to buffer all of it — just enough for the AudioQueue pipeline (~2-3s).
    /// Default 512KB ≈ 2.7s at 48kHz/stereo/16-bit.
    private nonisolated(unsafe) var pcmRingBuffer: PCMRingBuffer
    /// Frame size in bytes (channels × bytesPerSample after decoding)
    private nonisolated(unsafe) var frameSize: Int = 0
    /// Last output frame for insert (sample-hold repeat) — fixed allocation, no Data on audio thread
    private nonisolated(unsafe) var lastFrameStorage: UnsafeMutableRawBufferPointer =
        .allocate(byteCount: 32, alignment: 8) // max: 8ch × 4bytes = 32
    private nonisolated(unsafe) var lastFrameValid: Bool = false

    // Sync correction state (accessed under pcmBufferLock from audio thread)
    private nonisolated(unsafe) var correctionSchedule = CorrectionSchedule()
    private nonisolated(unsafe) var dropCounter: UInt32 = 0
    private nonisolated(unsafe) var insertCounter: UInt32 = 0

    // Callback-driven sync: the audio callback computes error and runs the planner directly.
    // The time filter snapshot is pushed from the clock sync path; the planner lives here.
    private nonisolated(unsafe) var timeSnapshot: TimeFilterSnapshot = .invalid
    private nonisolated(unsafe) var syncPlanner = CorrectionPlanner(
        deadbandMicroseconds: 1_500, // Tight thresholds — measurement is now precise
        engageMicroseconds: 3_000,
        reanchorThresholdMicroseconds: 500_000
    )
    /// Latest sync error in µs, written by audio callback, read by telemetry
    private nonisolated(unsafe) var lastSyncErrorUs: Int64 = 0
    // Whether a reanchor was requested by the callback (handled by the actor method)
    private nonisolated(unsafe) var pendingReanchorServerTime: Int64 = 0
    private nonisolated(unsafe) var reanchorRequested: Bool = false
    /// Grace period: suppress sync correction after AudioQueue rebuild to avoid
    /// audible pitch shifts from transient sync error. Frames-based countdown
    /// (decremented in the callback). At 48kHz, 48000 frames = 1 second.
    private nonisolated(unsafe) var correctionGraceFrames: Int64 = 0

    // Playback cursor: tracks server-time position of what's being output.
    // Advanced by 1_000_000/sampleRate per frame consumed. Accessed under pcmBufferLock.
    private nonisolated(unsafe) var cursorMicroseconds: Int64 = 0
    private nonisolated(unsafe) var cursorRemainder: Int64 = 0 // sub-microsecond accumulation
    private nonisolated(unsafe) var sampleRate: Int = 0
    /// Total frames consumed (for diagnostics)
    private nonisolated(unsafe) var framesConsumed: Int64 = 0
    /// Number of buffer underruns (ring buffer empty when callback needs frames)
    private nonisolated(unsafe) var underrunCount: Int64 = 0

    private var currentVolume: Float = 1.0
    private var isMuted: Bool = false
    private let volumeControl: VolumeControl

    // Process callback for local visualization / audio effects.
    // Set once in init, read from audio thread under pcmBufferLock.
    // processCallbackFormat is set in start() under the lock.
    private nonisolated(unsafe) var processCallback: AudioProcessCallback?
    private nonisolated(unsafe) var processCallbackFormat: AudioFormatSpec?

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
        bufferManager: BufferManager,
        clockSync: ClockSynchronizer,
        pcmBufferCapacity: Int = 524_288,
        volumeControl: VolumeControl = SoftwareVolumeControl(),
        processCallback: AudioProcessCallback? = nil
    ) {
        self.bufferManager = bufferManager
        self.clockSync = clockSync
        pcmRingBuffer = PCMRingBuffer(capacity: pcmBufferCapacity)
        self.volumeControl = volumeControl
        self.processCallback = processCallback
    }

    deinit {
        pcmRingBuffer.deallocate()
        lastFrameStorage.deallocate()
    }

    /// Start playback with specified format
    ///
    /// **Unmanaged safety:** `passUnretained(self)` is used to pass `self` as the
    /// AudioQueue callback client data. This is safe because:
    /// - `audioQueue` is set immediately after `AudioQueueNewOutput` (no throwing
    ///   calls between creation and assignment)
    /// - `stop()` disposes the queue before releasing `self`
    /// - `deinit` calls `stop()` implicitly via cleanup
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

        // Initialize frame-level state
        let computedFrameSize = format.channels * bytesPerSample
        precondition(
            computedFrameSize <= lastFrameStorage.count,
            "Frame size \(computedFrameSize) exceeds lastFrameStorage capacity \(lastFrameStorage.count)"
        )
        pcmBufferLock.withLock {
            frameSize = computedFrameSize
            processCallbackFormat = effectiveFormat
            lastFrameValid = false
            memset(lastFrameStorage.baseAddress!, 0, lastFrameStorage.count)
            pcmRingBuffer.reset()
            sampleRate = format.sampleRate
            cursorMicroseconds = 0
            cursorRemainder = 0
            framesConsumed = 0
            underrunCount = 0
            correctionSchedule = CorrectionSchedule()
            dropCounter = 0
            insertCounter = 0
            lastSyncErrorUs = 0
            reanchorRequested = false
            pendingReanchorServerTime = 0
            // Suppress sync correction for ~1 second after rebuild.
            // The transient sync error from the AudioQueue rebuild settles
            // naturally; correcting during this period causes audible artifacts.
            correctionGraceFrames = Int64(format.sampleRate)
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

        pcmBufferLock.withLock {
            pcmRingBuffer.reset()
            cursorMicroseconds = 0
            cursorRemainder = 0
            framesConsumed = 0
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

        pcmBufferLock.withLock {
            // Set cursor to first chunk's timestamp if not yet initialized
            if framesConsumed == 0, cursorMicroseconds == 0 {
                cursorMicroseconds = serverTimestamp
            }
            _ = pcmRingBuffer.write(pcmData)
        }
    }

    // MARK: - Sync correction interface

    /// Push a new time filter snapshot for use by the audio callback.
    /// Called from the clock sync path whenever processServerTime updates the filter.
    func updateTimeSnapshot(_ snapshot: TimeFilterSnapshot) {
        pcmBufferLock.withLock {
            timeSnapshot = snapshot
        }
    }

    /// Reanchor the playback cursor to a new server time position.
    func reanchorCursor(to serverTimeMicros: Int64) {
        pcmBufferLock.withLock {
            cursorMicroseconds = serverTimeMicros
            cursorRemainder = 0
            pcmRingBuffer.reset()
            correctionSchedule = CorrectionSchedule()
            dropCounter = 0
            insertCounter = 0
            reanchorRequested = false
        }
    }

    /// Check if the audio callback requested a reanchor. Returns the target server time
    /// if so, and clears the flag. Called from the sync/telemetry loop.
    func pollReanchor() -> Int64? {
        pcmBufferLock.withLock {
            guard reanchorRequested else { return nil }
            reanchorRequested = false
            return pendingReanchorServerTime
        }
    }

    /// Telemetry snapshot — read by the external telemetry loop for logging.
    struct TelemetrySnapshot {
        let cursorMicroseconds: Int64
        let sampleRate: Int
        let syncErrorUs: Int64
        let correctionSchedule: CorrectionSchedule
        let underrunCount: Int64
    }

    /// Capture telemetry state atomically for the logging loop.
    var telemetrySnapshot: TelemetrySnapshot {
        pcmBufferLock.withLock {
            TelemetrySnapshot(
                cursorMicroseconds: cursorMicroseconds,
                sampleRate: sampleRate,
                syncErrorUs: lastSyncErrorUs,
                correctionSchedule: correctionSchedule,
                underrunCount: underrunCount
            )
        }
    }

    /// Current playback cursor in server time microseconds
    var playbackCursorMicroseconds: Int64 {
        pcmBufferLock.withLock { cursorMicroseconds }
    }

    /// Clear buffered PCM data (for seek/stream clear without stopping playback)
    func clearBuffer() {
        pcmBufferLock.withLock {
            pcmRingBuffer.reset()
        }
    }

    // MARK: - AudioQueue callback (runs on audio thread)

    fileprivate nonisolated func fillBuffer(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        let capacity = Int(buffer.pointee.mAudioDataBytesCapacity)
        let dest = buffer.pointee.mAudioData.assumingMemoryBound(to: UInt8.self)
        var outOffset = 0

        pcmBufferLock.lock()
        defer { pcmBufferLock.unlock() }

        let fs = frameSize
        guard fs > 0 else {
            memset(buffer.pointee.mAudioData, 0, capacity)
            buffer.pointee.mAudioDataByteSize = UInt32(capacity)
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            return
        }

        let sr = sampleRate

        // Snapshot callback + format under the lock so reads are race-free.
        let cb = processCallback
        let cbFormat = processCallbackFormat

        // --- Compute sync error and update correction schedule (in the callback!) ---
        // Monotonic clock and cursor are read in the same lock scope = zero jitter.
        if cursorMicroseconds > 0, timeSnapshot.isValid {
            let nowAbsolute = MonotonicClock.absoluteMicroseconds()
            let expectedServerTime = timeSnapshot.localToServerTime(nowAbsolute)

            // AQ pipeline latency: ~2 buffers active (1 playing + 1 queued).
            // This is the gap between what we've fed and what's actually at the DAC.
            let aqLatencyUs = Int64(2 * capacity) * 1_000_000 / Int64(sr * fs)

            let syncErrorUs = (expectedServerTime - cursorMicroseconds) - aqLatencyUs
            lastSyncErrorUs = syncErrorUs

            // During grace period after AudioQueue rebuild, measure sync error
            // (for telemetry) but don't engage correction. The transient error
            // from the rebuild settles naturally without pitch-shifting the audio.
            let framesInBuffer = capacity / fs
            if correctionGraceFrames > 0 {
                correctionGraceFrames -= Int64(framesInBuffer)
            }

            let newSchedule: CorrectionSchedule = if correctionGraceFrames > 0 {
                CorrectionSchedule() // no correction during grace period
            } else {
                syncPlanner.plan(
                    errorMicroseconds: syncErrorUs,
                    sampleRate: UInt32(sr),
                    currentlyCorrecting: correctionSchedule.isCorrecting
                )
            }

            if newSchedule.reanchor {
                // Can't reset the ring buffer and cursor here safely while iterating,
                // so signal the actor to handle it on the next poll.
                pendingReanchorServerTime = expectedServerTime
                reanchorRequested = true
                // Disable correction while waiting for reanchor
                correctionSchedule = CorrectionSchedule()
                dropCounter = 0
                insertCounter = 0
            } else if newSchedule != correctionSchedule {
                let wasActive = correctionSchedule.isCorrecting
                correctionSchedule = newSchedule
                if newSchedule.isCorrecting, !wasActive {
                    dropCounter = newSchedule.dropEveryNFrames
                    insertCounter = newSchedule.insertEveryNFrames
                }
            }
        }

        // --- Fill the buffer with PCM frames, applying drop/insert correction ---
        while outOffset + fs <= capacity {
            // --- Drop cadence: consume a frame without writing it ---
            if correctionSchedule.dropEveryNFrames > 0 {
                dropCounter = dropCounter > 0 ? dropCounter - 1 : 0
                if dropCounter == 0 {
                    dropCounter = correctionSchedule.dropEveryNFrames
                    if pcmRingBuffer.availableToRead >= fs {
                        pcmRingBuffer.skip(fs)
                        advanceCursor(sampleRate: sr)
                    }
                }
            }

            // --- Insert cadence: repeat last frame without consuming ---
            if correctionSchedule.insertEveryNFrames > 0 {
                insertCounter = insertCounter > 0 ? insertCounter - 1 : 0
                if insertCounter == 0 {
                    insertCounter = correctionSchedule.insertEveryNFrames
                    if lastFrameValid {
                        memcpy(dest + outOffset, lastFrameStorage.baseAddress!, fs)
                    } else {
                        memset(dest + outOffset, 0, fs)
                    }
                    outOffset += fs
                    continue
                }
            }

            // --- Normal: consume one frame and write it ---
            if pcmRingBuffer.availableToRead >= fs {
                pcmRingBuffer.read(into: dest + outOffset, count: fs)
                memcpy(lastFrameStorage.baseAddress!, dest + outOffset, fs)
                lastFrameValid = true
                advanceCursor(sampleRate: sr)
                outOffset += fs
            } else {
                underrunCount += 1
                break
            }
        }

        // Fill remaining space with silence (still under the lock — defer handles unlock)
        if outOffset < capacity {
            memset(dest + outOffset, 0, capacity - outOffset)
        }

        // Invoke process callback with the final buffer contents (including silence).
        // cb/cbFormat were captured under the lock above; the buffer is fully assembled
        // and won't be touched again before enqueue.
        if let cb, let cbFormat {
            let mutableBuffer = UnsafeMutableRawBufferPointer(
                start: buffer.pointee.mAudioData,
                count: capacity
            )
            cb(mutableBuffer, cbFormat)
        }

        buffer.pointee.mAudioDataByteSize = UInt32(capacity)
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    /// Advance cursor by one frame. Must be called under pcmBufferLock.
    private nonisolated func advanceCursor(sampleRate: Int) {
        // Integer arithmetic to avoid floating-point drift:
        // microseconds_per_frame = 1_000_000 / sampleRate (with remainder)
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
