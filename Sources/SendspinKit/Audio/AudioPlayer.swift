// ABOUTME: Manages AudioQueue-based audio playback with frame-level sync correction
// ABOUTME: Applies drop/insert cadence from CorrectionPlanner to maintain clock sync

import AudioToolbox
import AVFoundation
import Foundation

/// Actor managing synchronized audio playback
public actor AudioPlayer {
    private let bufferManager: BufferManager
    private let clockSync: ClockSynchronizer

    private var audioQueue: AudioQueueRef?
    private var decoder: AudioDecoder?
    private var currentFormat: AudioFormatSpec?

    private var _isPlaying: Bool = false

    // Ring buffer consumed by AudioQueue callback.
    // All fields accessed under pcmBufferLock from the audio thread.
    private nonisolated let pcmBufferLock = NSLock()
    // 512KB ring buffer — ~2.7s at 48kHz/stereo/16-bit
    private nonisolated(unsafe) var pcmRingBuffer = PCMRingBuffer(capacity: 524_288)
    // Frame size in bytes (channels × bytesPerSample after decoding)
    private nonisolated(unsafe) var frameSize: Int = 0
    // Last output frame for insert (sample-hold repeat) — fixed allocation, no Data on audio thread
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
        deadbandMicroseconds: 1_500,   // Tight thresholds — measurement is now precise
        engageMicroseconds: 3_000,
        reanchorThresholdMicroseconds: 500_000
    )
    // Latest sync error in µs, written by audio callback, read by telemetry
    private nonisolated(unsafe) var lastSyncErrorUs: Int64 = 0
    // Whether a reanchor was requested by the callback (handled by the actor method)
    private nonisolated(unsafe) var pendingReanchorServerTime: Int64 = 0
    private nonisolated(unsafe) var reanchorRequested: Bool = false

    // Playback cursor: tracks server-time position of what's being output.
    // Advanced by 1_000_000/sampleRate per frame consumed. Accessed under pcmBufferLock.
    private nonisolated(unsafe) var cursorMicroseconds: Int64 = 0
    private nonisolated(unsafe) var cursorRemainder: Int64 = 0 // sub-microsecond accumulation
    private nonisolated(unsafe) var sampleRate: Int = 0
    // Total frames consumed (for diagnostics)
    private nonisolated(unsafe) var framesConsumed: Int64 = 0

    private var currentVolume: Float = 1.0
    private var isMuted: Bool = false

    public var isPlaying: Bool { _isPlaying }
    public var volume: Float { currentVolume }
    public var muted: Bool { isMuted }

    public init(bufferManager: BufferManager, clockSync: ClockSynchronizer) {
        self.bufferManager = bufferManager
        self.clockSync = clockSync
    }

    deinit {
        pcmRingBuffer.deallocate()
        lastFrameStorage.deallocate()
    }

    /// Start playback with specified format
    public func start(format: AudioFormatSpec, codecHeader: Data?) throws {
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

        // Both 24-bit PCM and FLAC decoders output Int32 (4 bytes per sample):
        // - 24-bit PCM: unpacked from 3 bytes to 4 bytes, left-shifted 8 bits
        // - FLAC: libFLAC always outputs Int32, shifted to fill 32-bit range
        // - Opus: also outputs Int32 (converted from float32)
        let decoderOutputs32Bit = (format.bitDepth == 24 || format.codec == .flac || format.codec == .opus)
        let effectiveBitDepth = decoderOutputs32Bit ? 32 : format.bitDepth
        let bytesPerSample = effectiveBitDepth / 8

        audioFormat.mBytesPerPacket = UInt32(format.channels * bytesPerSample)
        audioFormat.mBytesPerFrame = UInt32(format.channels * bytesPerSample)
        audioFormat.mBitsPerChannel = UInt32(effectiveBitDepth)

        var queue: AudioQueueRef?
        let status = AudioQueueNewOutput(
            &audioFormat,
            audioQueueCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            nil, nil, 0,
            &queue
        )

        guard status == noErr, let queue = queue else {
            throw AudioPlayerError.queueCreationFailed
        }

        audioQueue = queue
        currentFormat = format

        // Initialize frame-level state
        let computedFrameSize = format.channels * bytesPerSample
        pcmBufferLock.withLock {
            frameSize = computedFrameSize
            lastFrameValid = false
            memset(lastFrameStorage.baseAddress!, 0, lastFrameStorage.count)
            pcmRingBuffer.reset()
            sampleRate = format.sampleRate
            cursorMicroseconds = 0
            cursorRemainder = 0
            framesConsumed = 0
            correctionSchedule = CorrectionSchedule()
            dropCounter = 0
            insertCounter = 0
            lastSyncErrorUs = 0
            reanchorRequested = false
            pendingReanchorServerTime = 0
        }

        // Allocate and prime buffers.
        // 16384 bytes = ~4096 frames @ 48kHz stereo 16-bit = ~85ms per callback.
        // 3 buffers primed = ~256ms pipeline latency. Sync correction runs inside
        // each callback, so we get ~85ms feedback loops — sufficient for ±1-3ms
        // steady-state accuracy. Smaller buffers cause instability due to the
        // correction schedule updating too frequently relative to its effect.
        let bufferSize: UInt32 = 16384
        for _ in 0 ..< 3 {
            var buffer: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(queue, bufferSize, &buffer) == noErr, let buffer = buffer {
                fillBuffer(queue: queue, buffer: buffer)
            }
        }

        let startStatus = AudioQueueStart(queue, nil)
        if startStatus != noErr {
            fputs("[AUDIO] AudioQueueStart failed with status: \(startStatus)\n", stderr)
            throw AudioPlayerError.queueCreationFailed
        }
        fputs("[AUDIO] AudioQueue started: \(format.codec.rawValue) \(format.sampleRate)Hz \(format.channels)ch \(format.bitDepth)bit (output: \(effectiveBitDepth)-bit)\n", stderr)
        _isPlaying = true
    }

    /// Stop playback and clean up
    public func stop() {
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

    /// Decode compressed audio data to PCM
    public func decode(_ data: Data) throws -> Data {
        guard let decoder = decoder else {
            throw AudioPlayerError.notStarted
        }
        return try decoder.decode(data)
    }

    /// Play PCM data with associated server timestamp
    public func playPCM(_ pcmData: Data, serverTimestamp: Int64) async throws {
        guard audioQueue != nil, currentFormat != nil else {
            throw AudioPlayerError.notStarted
        }

        pcmBufferLock.withLock {
            // Set cursor to first chunk's timestamp if not yet initialized
            if framesConsumed == 0, cursorMicroseconds == 0 {
                cursorMicroseconds = serverTimestamp
            }
            pcmRingBuffer.write(pcmData)
        }
    }

    /// Play PCM data directly (legacy path, no timestamp)
    public func playPCM(_ pcmData: Data) async throws {
        guard audioQueue != nil, currentFormat != nil else {
            throw AudioPlayerError.notStarted
        }

        pcmBufferLock.withLock {
            pcmRingBuffer.write(pcmData)
        }
    }

    // MARK: - Sync correction interface

    /// Push a new time filter snapshot for use by the audio callback.
    /// Called from the clock sync path whenever processServerTime updates the filter.
    public func updateTimeSnapshot(_ snapshot: TimeFilterSnapshot) {
        pcmBufferLock.withLock {
            timeSnapshot = snapshot
        }
    }

    /// Reanchor the playback cursor to a new server time position.
    public func reanchorCursor(to serverTimeMicros: Int64) {
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
    public func pollReanchor() -> Int64? {
        pcmBufferLock.withLock {
            guard reanchorRequested else { return nil }
            reanchorRequested = false
            return pendingReanchorServerTime
        }
    }

    /// Telemetry snapshot — read by the external telemetry loop for logging.
    public struct TelemetrySnapshot: Sendable {
        public let cursorMicroseconds: Int64
        public let sampleRate: Int
        public let syncErrorUs: Int64
        public let correctionSchedule: CorrectionSchedule
    }

    /// Capture telemetry state atomically for the logging loop.
    public var telemetrySnapshot: TelemetrySnapshot {
        pcmBufferLock.withLock {
            TelemetrySnapshot(
                cursorMicroseconds: cursorMicroseconds,
                sampleRate: sampleRate,
                syncErrorUs: lastSyncErrorUs,
                correctionSchedule: correctionSchedule
            )
        }
    }

    /// Current playback cursor in server time microseconds
    public var playbackCursorMicroseconds: Int64 {
        pcmBufferLock.withLock { cursorMicroseconds }
    }

    /// Clear buffered PCM data (for seek/stream clear without stopping playback)
    public func clearBuffer() {
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

        let fs = frameSize
        guard fs > 0 else {
            pcmBufferLock.unlock()
            memset(buffer.pointee.mAudioData, 0, capacity)
            buffer.pointee.mAudioDataByteSize = UInt32(capacity)
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            return
        }

        let sr = sampleRate

        // --- Compute sync error and update correction schedule (in the callback!) ---
        // Wall clock and cursor are read in the same lock scope = zero jitter.
        if cursorMicroseconds > 0, timeSnapshot.isValid {
            let nowAbsolute = Int64(Date().timeIntervalSince1970 * 1_000_000)
            let expectedServerTime = timeSnapshot.localToServerTime(nowAbsolute)

            // AQ pipeline latency: ~2 buffers active (1 playing + 1 queued).
            // This is the gap between what we've fed and what's actually at the DAC.
            let aqLatencyUs = Int64(2 * capacity) * 1_000_000 / Int64(sr * fs)

            let syncErrorUs = (expectedServerTime - cursorMicroseconds) - aqLatencyUs
            lastSyncErrorUs = syncErrorUs

            let newSchedule = syncPlanner.plan(
                errorMicroseconds: syncErrorUs,
                sampleRate: UInt32(sr),
                currentlyCorrecting: correctionSchedule.isCorrecting
            )

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
                break // underrun
            }
        }

        pcmBufferLock.unlock()

        // Fill remaining space with silence
        if outOffset < capacity {
            memset(dest + outOffset, 0, capacity - outOffset)
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

    /// Set volume (0.0 to 1.0)
    /// Set volume (0.0 to 1.0 linear, mapped to perceptual amplitude)
    public func setVolume(_ volume: Float) {
        guard let queue = audioQueue else { return }
        let clampedVolume = max(0.0, min(1.0, volume))
        currentVolume = clampedVolume
        let gain = Self.perceptualGain(clampedVolume)
        AudioQueueSetParameter(queue, kAudioQueueParam_Volume, muted ? 0.0 : gain)
    }

    /// Set mute state
    public func setMute(_ muted: Bool) {
        guard let queue = audioQueue else { return }
        isMuted = muted
        let gain = muted ? Float(0.0) : Self.perceptualGain(currentVolume)
        AudioQueueSetParameter(queue, kAudioQueueParam_Volume, gain)
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

// AudioQueue callback (C function)
private let audioQueueCallback: AudioQueueOutputCallback = { userData, queue, buffer in
    guard let userData = userData else { return }
    let player = Unmanaged<AudioPlayer>.fromOpaque(userData).takeUnretainedValue()
    player.fillBuffer(queue: queue, buffer: buffer)
}

public enum AudioPlayerError: Error {
    case queueCreationFailed
    case notStarted
    case decodingFailed
    case bufferFull
}
