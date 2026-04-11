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

    // Continuous byte buffer consumed by AudioQueue callback.
    // All fields accessed under pcmBufferLock from the audio thread.
    private nonisolated let pcmBufferLock = NSLock()
    private nonisolated(unsafe) var pcmByteBuffer = Data()
    // Frame size in bytes (channels × bytesPerSample after decoding)
    private nonisolated(unsafe) var frameSize: Int = 0
    // Last output frame for insert (sample-hold repeat)
    private nonisolated(unsafe) var lastFrame = Data()

    // Sync correction state (accessed under pcmBufferLock)
    private nonisolated(unsafe) var correctionSchedule = CorrectionSchedule()
    private nonisolated(unsafe) var dropCounter: UInt32 = 0
    private nonisolated(unsafe) var insertCounter: UInt32 = 0

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

        // 24-bit input is unpacked to 32-bit Int32 by the decoder
        let effectiveBitDepth = (format.bitDepth == 24) ? 32 : format.bitDepth
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
            lastFrame = Data(count: computedFrameSize)
            sampleRate = format.sampleRate
            cursorMicroseconds = 0
            cursorRemainder = 0
            framesConsumed = 0
            correctionSchedule = CorrectionSchedule()
            dropCounter = 0
            insertCounter = 0
        }

        // Allocate and prime buffers
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
            pcmByteBuffer.removeAll(keepingCapacity: false)
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
            pcmByteBuffer.append(pcmData)
        }
    }

    /// Play PCM data directly (legacy path, no timestamp)
    public func playPCM(_ pcmData: Data) async throws {
        guard audioQueue != nil, currentFormat != nil else {
            throw AudioPlayerError.notStarted
        }

        pcmBufferLock.withLock {
            pcmByteBuffer.append(pcmData)
        }
    }

    // MARK: - Sync correction interface

    /// Update the correction schedule (called from scheduler loop)
    public func updateCorrectionSchedule(_ schedule: CorrectionSchedule) {
        pcmBufferLock.withLock {
            let wasActive = correctionSchedule.isCorrecting
            correctionSchedule = schedule

            // Reset counters when schedule changes
            if schedule.isCorrecting && !wasActive {
                dropCounter = schedule.dropEveryNFrames
                insertCounter = schedule.insertEveryNFrames
            }

            if schedule.reanchor {
                // Reanchor handled externally — just clear correction state
                correctionSchedule = CorrectionSchedule()
                dropCounter = 0
                insertCounter = 0
            }
        }
    }

    /// Reanchor the playback cursor to a new server time position
    public func reanchorCursor(to serverTimeMicros: Int64) {
        pcmBufferLock.withLock {
            cursorMicroseconds = serverTimeMicros
            cursorRemainder = 0
            pcmByteBuffer.removeAll(keepingCapacity: true)
        }
    }

    /// Current playback cursor in server time microseconds
    public var playbackCursorMicroseconds: Int64 {
        pcmBufferLock.withLock { cursorMicroseconds }
    }

    /// Current sample rate (for CorrectionPlanner)
    public var currentSampleRate: Int {
        pcmBufferLock.withLock { sampleRate }
    }

    /// Current correction schedule (for hysteresis check)
    public var currentCorrectionSchedule: CorrectionSchedule {
        pcmBufferLock.withLock { correctionSchedule }
    }

    /// Current frame size in bytes (channels × bytesPerSample)
    public var currentFrameSize: Int {
        pcmBufferLock.withLock { frameSize }
    }

    /// Clear buffered PCM data (for seek/stream clear without stopping playback)
    public func clearBuffer() {
        pcmBufferLock.withLock {
            pcmByteBuffer.removeAll(keepingCapacity: true)
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

        while outOffset + fs <= capacity {
            // --- Drop cadence: consume a frame without writing it ---
            if correctionSchedule.dropEveryNFrames > 0 {
                dropCounter = dropCounter > 0 ? dropCounter - 1 : 0
                if dropCounter == 0 {
                    dropCounter = correctionSchedule.dropEveryNFrames
                    // Consume one frame silently (skip it)
                    if pcmByteBuffer.count >= fs {
                        pcmByteBuffer.removeFirst(fs)
                        advanceCursor(sampleRate: sr)
                    }
                    // Don't write anything — continue to next output frame
                }
            }

            // --- Insert cadence: repeat last frame without consuming ---
            if correctionSchedule.insertEveryNFrames > 0 {
                insertCounter = insertCounter > 0 ? insertCounter - 1 : 0
                if insertCounter == 0 {
                    insertCounter = correctionSchedule.insertEveryNFrames
                    // Write last frame again (sample-hold)
                    lastFrame.withUnsafeBytes { src in
                        memcpy(dest + outOffset, src.baseAddress!, fs)
                    }
                    outOffset += fs
                    // Don't consume from buffer, don't advance cursor
                    continue
                }
            }

            // --- Normal: consume one frame and write it ---
            if pcmByteBuffer.count >= fs {
                pcmByteBuffer.withUnsafeBytes { src in
                    memcpy(dest + outOffset, src.baseAddress!, fs)
                }
                // Save as last frame for potential insert repeat
                lastFrame = pcmByteBuffer.prefix(fs)
                pcmByteBuffer.removeFirst(fs)
                advanceCursor(sampleRate: sr)
                outOffset += fs
            } else {
                // Underrun — write silence for remaining capacity
                break
            }
        }

        pcmBufferLock.unlock()

        // Fill any remaining space with silence
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
    public func setVolume(_ volume: Float) {
        guard let queue = audioQueue else { return }
        let clampedVolume = max(0.0, min(1.0, volume))
        currentVolume = clampedVolume
        AudioQueueSetParameter(queue, kAudioQueueParam_Volume, clampedVolume)
    }

    /// Set mute state
    public func setMute(_ muted: Bool) {
        guard let queue = audioQueue else { return }
        isMuted = muted
        let effectiveVolume = muted ? 0.0 : currentVolume
        AudioQueueSetParameter(queue, kAudioQueueParam_Volume, effectiveVolume)
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
