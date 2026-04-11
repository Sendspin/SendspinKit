// ABOUTME: Manages AudioQueue-based audio playback with microsecond-precise synchronization
// ABOUTME: Handles format setup, chunk decoding, and timestamp-based playback scheduling

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

    // Continuous byte buffer consumed by AudioQueue callback
    private nonisolated let pcmBufferLock = NSLock()
    private nonisolated(unsafe) var pcmByteBuffer = Data()

    private var currentVolume: Float = 1.0
    private var isMuted: Bool = false

    public var isPlaying: Bool {
        return _isPlaying
    }

    public var volume: Float {
        return currentVolume
    }

    public var muted: Bool {
        return isMuted
    }

    public init(bufferManager: BufferManager, clockSync: ClockSynchronizer) {
        self.bufferManager = bufferManager
        self.clockSync = clockSync
    }

    /// Start playback with specified format
    public func start(format: AudioFormatSpec, codecHeader: Data?) throws {
        // Don't restart if already playing with same format
        if _isPlaying, currentFormat == format {
            return
        }

        // Stop existing playback
        stop()

        // Create decoder for codec
        decoder = try AudioDecoderFactory.create(
            codec: format.codec,
            sampleRate: format.sampleRate,
            channels: format.channels,
            bitDepth: format.bitDepth,
            header: codecHeader
        )

        // Configure AudioQueue format (always output PCM)
        var audioFormat = AudioStreamBasicDescription()
        audioFormat.mSampleRate = Float64(format.sampleRate)
        audioFormat.mFormatID = kAudioFormatLinearPCM
        audioFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked
        audioFormat.mFramesPerPacket = 1
        audioFormat.mChannelsPerFrame = UInt32(format.channels)

        // For 24-bit, decoder unpacks to 32-bit Int32, so configure AudioQueue for 32-bit
        let effectiveBitDepth = (format.bitDepth == 24) ? 32 : format.bitDepth
        let bytesPerSample = effectiveBitDepth / 8

        audioFormat.mBytesPerPacket = UInt32(format.channels * bytesPerSample)
        audioFormat.mBytesPerFrame = UInt32(format.channels * bytesPerSample)
        audioFormat.mBitsPerChannel = UInt32(effectiveBitDepth)

        // Create AudioQueue
        var queue: AudioQueueRef?
        let status = AudioQueueNewOutput(
            &audioFormat,
            audioQueueCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil,
            0,
            &queue
        )

        guard status == noErr, let queue = queue else {
            throw AudioPlayerError.queueCreationFailed
        }

        audioQueue = queue
        currentFormat = format

        // Allocate and prime buffers BEFORE starting the queue
        let bufferSize: UInt32 = 16384 // 16KB per buffer
        for _ in 0 ..< 3 { // 3 buffers for smooth playback
            var buffer: AudioQueueBufferRef?
            let status = AudioQueueAllocateBuffer(queue, bufferSize, &buffer)

            if status == noErr, let buffer = buffer {
                // Prime buffer with initial chunk
                fillBuffer(queue: queue, buffer: buffer)
            }
        }

        // Start the queue AFTER buffers are enqueued
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

        // Clear PCM buffer to prevent stale audio on restart
        pcmBufferLock.withLock {
            pcmByteBuffer.removeAll(keepingCapacity: false)
        }
    }

    /// Decode compressed audio data to PCM
    public func decode(_ data: Data) throws -> Data {
        guard let decoder = decoder else {
            throw AudioPlayerError.notStarted
        }
        return try decoder.decode(data)
    }

    /// Play PCM data directly (for scheduled playback)
    public func playPCM(_ pcmData: Data) async throws {
        guard audioQueue != nil, currentFormat != nil else {
            throw AudioPlayerError.notStarted
        }

        // Append to continuous byte buffer for AudioQueue callback to consume
        pcmBufferLock.withLock {
            pcmByteBuffer.append(pcmData)
        }
    }

    fileprivate nonisolated func fillBuffer(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        let capacity = Int(buffer.pointee.mAudioDataBytesCapacity)

        pcmBufferLock.lock()
        let available = pcmByteBuffer.count
        let copySize = min(available, capacity)

        if copySize > 0 {
            pcmByteBuffer.withUnsafeBytes { srcBytes in
                memcpy(buffer.pointee.mAudioData, srcBytes.baseAddress!, copySize)
            }
            pcmByteBuffer.removeFirst(copySize)
            pcmBufferLock.unlock()

            buffer.pointee.mAudioDataByteSize = UInt32(copySize)
        } else {
            pcmBufferLock.unlock()

            // No data available — enqueue silence to keep the queue alive
            memset(buffer.pointee.mAudioData, 0, capacity)
            buffer.pointee.mAudioDataByteSize = UInt32(capacity)
        }

        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    /// Clear buffered PCM data (for seek/stream clear without stopping playback)
    public func clearBuffer() {
        pcmBufferLock.withLock {
            pcmByteBuffer.removeAll(keepingCapacity: true)
        }
    }

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

        // Set volume to 0 when muted, restore when unmuted
        let effectiveVolume = muted ? 0.0 : currentVolume
        AudioQueueSetParameter(queue, kAudioQueueParam_Volume, effectiveVolume)
    }

    // Cleanup happens in stop() method called explicitly before deallocation
    // AudioQueue will be disposed when stop() is called or connection is closed
}

// AudioQueue callback (C function)
private let audioQueueCallback: AudioQueueOutputCallback = { userData, queue, buffer in
    guard let userData = userData else {
        return
    }

    let player = Unmanaged<AudioPlayer>.fromOpaque(userData).takeUnretainedValue()
    player.fillBuffer(queue: queue, buffer: buffer)
}

public enum AudioPlayerError: Error {
    case queueCreationFailed
    case notStarted
    case decodingFailed
    case bufferFull
}
