// ABOUTME: Audio decoder for FLAC, Opus, and PCM codecs
// ABOUTME: Converts compressed audio to PCM for playback, handles 24-bit unpacking

@preconcurrency import AVFoundation
import FLAC
import Foundation
import Opus

/// Audio decoder protocol
protocol AudioDecoder {
    func decode(_ data: Data) throws -> Data
}

/// PCM decoder supporting 16-bit and 24-bit formats
class PCMDecoder: AudioDecoder {
    private let bitDepth: Int
    private let channels: Int

    init(bitDepth: Int, channels: Int) {
        self.bitDepth = bitDepth
        self.channels = channels
    }

    func decode(_ data: Data) throws -> Data {
        switch bitDepth {
        case 16:
            // 16-bit PCM - pass through (already correct format)
            return data

        case 24:
            // 24-bit PCM - unpack 3-byte samples to 4-byte Int32
            return try decode24Bit(data)

        case 32:
            // 32-bit PCM - pass through
            return data

        default:
            throw AudioDecoderError.unsupportedBitDepth(bitDepth)
        }
    }

    private func decode24Bit(_ data: Data) throws -> Data {
        let bytesPerSample = 3
        guard data.count % bytesPerSample == 0 else {
            throw AudioDecoderError.invalidDataSize(
                expected: "multiple of 3",
                actual: data.count
            )
        }

        let sampleCount = data.count / bytesPerSample
        let bytes = [UInt8](data)

        // Unpack 24-bit samples to Int32 (4 bytes per sample)
        var samples = [Int32]()
        samples.reserveCapacity(sampleCount)

        for i in 0 ..< sampleCount {
            let sample = PCMUtilities.unpack24Bit(bytes, offset: i * bytesPerSample)
            // Left-shift 8 bits: 24-bit range → 32-bit range for AudioQueue
            samples.append(sample << 8)
        }

        // Convert Int32 array to Data
        return samples.withUnsafeBytes { Data($0) }
    }
}

/// Opus decoder using libopus via swift-opus package
class OpusDecoder: AudioDecoder {
    private let decoder: Opus.Decoder
    private let channels: Int

    init(sampleRate: Int, channels: Int, bitDepth _: Int) throws {
        self.channels = channels

        // Create AVAudioFormat for Opus decoder
        // swift-opus accepts standard PCM formats and handles Opus internally
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else {
            throw AudioDecoderError.formatCreationFailed("Failed to create audio format for Opus")
        }

        // Create opus decoder (validates sample rate internally)
        do {
            decoder = try Opus.Decoder(format: format)
        } catch {
            throw AudioDecoderError.formatCreationFailed("Opus decoder: \(error.localizedDescription)")
        }
    }

    func decode(_ data: Data) throws -> Data {
        // Decode Opus packet to AVAudioPCMBuffer
        let pcmBuffer: AVAudioPCMBuffer
        do {
            pcmBuffer = try decoder.decode(data)
        } catch {
            throw AudioDecoderError.conversionFailed("Opus decode failed: \(error.localizedDescription)")
        }

        // swift-opus outputs float32 in AVAudioPCMBuffer
        // Convert float32 → int32 (24-bit left-justified format)
        guard let floatChannelData = pcmBuffer.floatChannelData else {
            throw AudioDecoderError.conversionFailed("No float channel data in decoded buffer")
        }

        let frameLength = Int(pcmBuffer.frameLength)
        let totalSamples = frameLength * channels
        var int32Samples = [Int32](repeating: 0, count: totalSamples)

        // Convert interleaved float32 samples to int32
        // float range [-1.0, 1.0] → int32 range [Int32.min, Int32.max]
        if channels == 1 {
            // Mono: direct conversion
            let floatData = floatChannelData[0]
            for i in 0 ..< frameLength {
                let floatSample = floatData[i]
                int32Samples[i] = Int32(floatSample * Float(Int32.max))
            }
        } else {
            // Stereo or multi-channel: interleave
            for channel in 0 ..< channels {
                let floatData = floatChannelData[channel]
                for frame in 0 ..< frameLength {
                    let floatSample = floatData[frame]
                    let sampleIndex = frame * channels + channel
                    int32Samples[sampleIndex] = Int32(floatSample * Float(Int32.max))
                }
            }
        }

        // Convert [Int32] to Data
        return int32Samples.withUnsafeBytes { Data($0) }
    }
}

/// FLAC decoder using libFLAC via flac-binary-xcframework
class FLACDecoder: AudioDecoder {
    private var decoder: UnsafeMutablePointer<FLAC__StreamDecoder>?
    private let sampleRate: Int
    private let channels: Int
    private let bitDepth: Int
    private var pendingData: Data = .init()
    private var decodedSamples: [Int32] = []
    private var readOffset: Int = 0
    private var lastError: FLAC__StreamDecoderErrorStatus?

    init(sampleRate: Int, channels: Int, bitDepth: Int, header: Data? = nil) throws {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth

        // Create FLAC stream decoder
        guard let flacDecoder = FLAC__stream_decoder_new() else {
            throw AudioDecoderError.formatCreationFailed("Failed to create FLAC stream decoder")
        }
        decoder = flacDecoder

        // Initialize decoder with callbacks
        // We need to use Unmanaged to pass self to C callbacks
        let clientData = Unmanaged.passUnretained(self).toOpaque()

        let initStatus = FLAC__stream_decoder_init_stream(
            decoder,
            { _, buffer, bytes, clientData -> FLAC__StreamDecoderReadStatus in
                guard let clientData else {
                    return FLAC__STREAM_DECODER_READ_STATUS_ABORT
                }
                let selfRef = Unmanaged<FLACDecoder>.fromOpaque(clientData).takeUnretainedValue()
                return selfRef.readCallback(buffer: buffer, bytes: bytes)
            },
            nil, // seek callback (optional)
            nil, // tell callback (optional)
            nil, // length callback (optional)
            nil, // eof callback (optional)
            { _, frame, buffer, clientData -> FLAC__StreamDecoderWriteStatus in
                guard let clientData else {
                    return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
                }
                let selfRef = Unmanaged<FLACDecoder>.fromOpaque(clientData).takeUnretainedValue()
                return selfRef.writeCallback(frame: frame, buffer: buffer)
            },
            nil, // metadata callback (optional)
            { _, status, clientData in
                // Error callback - store error for later checking
                guard let clientData else { return }
                let selfRef = Unmanaged<FLACDecoder>.fromOpaque(clientData).takeUnretainedValue()
                selfRef.lastError = status
            },
            clientData
        )

        guard initStatus == FLAC__STREAM_DECODER_INIT_STATUS_OK else {
            FLAC__stream_decoder_delete(flacDecoder)
            throw AudioDecoderError.formatCreationFailed("FLAC decoder init failed: \(initStatus)")
        }

        // Prepend the codec header (fLaC magic + STREAMINFO) so the decoder
        // can parse the stream. Without this, libFLAC can't decode any frames.
        if let header {
            pendingData.append(header)
        }
    }

    func decode(_ data: Data) throws -> Data {
        // Append new data to pending buffer
        pendingData.append(data)
        decodedSamples.removeAll(keepingCapacity: true)
        lastError = nil

        // Process single frame
        guard let decoder else {
            throw AudioDecoderError.conversionFailed("FLAC decoder not initialized")
        }

        // CRITICAL: readOffset tracks decoder's position in pendingData
        // DON'T reset to 0 - decoder maintains internal state and continues from last position
        // The readCallback will be called and will read from readOffset

        // Process blocks until we get audio samples
        // First block is always STREAMINFO metadata, subsequent blocks are audio frames
        // For complete FLAC files, we need multiple process_single() calls to advance
        // through metadata blocks to reach audio frames
        var iterations = 0
        let startOffset = readOffset
        while decodedSamples.isEmpty {
            iterations += 1
            let success = FLAC__stream_decoder_process_single(decoder)
            let state = FLAC__stream_decoder_get_state(decoder)

            guard success != 0 else {
                throw AudioDecoderError.conversionFailed("FLAC frame processing failed: state=\(state)")
            }

            // Check if we've hit end of stream or processed all available data
            if state == FLAC__STREAM_DECODER_END_OF_STREAM {
                break
            }

            // If readOffset didn't advance, we need more data (for streaming use case)
            if readOffset == startOffset, iterations > 1 {
                break
            }

            // Safety limit to prevent infinite loops
            if iterations > 100 {
                break
            }
        }

        // Check for errors reported via error callback
        if let error = lastError {
            throw AudioDecoderError.conversionFailed("FLAC decoder error: \(error)")
        }

        // Remove consumed bytes from pending buffer to prevent memory leak
        // Only remove bytes that were actually read during THIS decode() call
        let bytesConsumed = readOffset - startOffset
        if bytesConsumed > 0 {
            pendingData.removeFirst(bytesConsumed)
            readOffset = startOffset // Adjust readOffset to account for removed bytes
        }

        // Return decoded samples as Data
        return decodedSamples.withUnsafeBytes { Data($0) }
    }

    private func readCallback(buffer: UnsafeMutablePointer<FLAC__byte>?, bytes: UnsafeMutablePointer<Int>?) -> FLAC__StreamDecoderReadStatus {
        guard let buffer, let bytes else {
            return FLAC__STREAM_DECODER_READ_STATUS_ABORT
        }

        let bytesToRead = min(bytes.pointee, pendingData.count - readOffset)

        guard bytesToRead > 0 else {
            bytes.pointee = 0
            return FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM
        }

        // Copy data from pending buffer
        pendingData.withUnsafeBytes { srcBytes in
            let src = srcBytes.baseAddress!.advanced(by: readOffset)
            memcpy(buffer, src, bytesToRead)
        }

        readOffset += bytesToRead
        bytes.pointee = bytesToRead

        return FLAC__STREAM_DECODER_READ_STATUS_CONTINUE
    }

    private func writeCallback(
        frame: UnsafePointer<FLAC__Frame>?,
        buffer: UnsafePointer<UnsafePointer<FLAC__int32>?>?
    ) -> FLAC__StreamDecoderWriteStatus {
        guard let frame, let buffer else {
            return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
        }

        let blocksize = Int(frame.pointee.header.blocksize)
        // Use the frame's actual bit depth, not the init parameter.
        // During format transitions, old FLAC frames may be decoded by a
        // new decoder initialized with a different bit depth. The frame
        // header always has the correct value.
        let frameBitsPerSample = Int(frame.pointee.header.bits_per_sample)
        let shift = 32 - frameBitsPerSample

        // FLAC outputs int32 samples per channel
        // Interleave channels if stereo
        for i in 0 ..< blocksize {
            for channel in 0 ..< channels {
                guard let channelBuffer = buffer[channel] else {
                    return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
                }
                let sample = channelBuffer[i]

                // FLAC outputs right-aligned samples in Int32.
                // Shift left to fill the full 32-bit range for AudioQueue.
                let normalizedSample = shift > 0 ? sample << Int32(shift) : sample

                decodedSamples.append(normalizedSample)
            }
        }

        return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE
    }

    deinit {
        if let decoder {
            FLAC__stream_decoder_finish(decoder)
            FLAC__stream_decoder_delete(decoder)
        }
    }
}

/// Creates decoder for specified codec
enum AudioDecoderFactory {
    static func create(
        codec: AudioCodec,
        sampleRate: Int,
        channels: Int,
        bitDepth: Int,
        header: Data?
    ) throws -> AudioDecoder {
        switch codec {
        case .pcm:
            PCMDecoder(bitDepth: bitDepth, channels: channels)
        case .opus:
            try OpusDecoder(sampleRate: sampleRate, channels: channels, bitDepth: bitDepth)
        case .flac:
            try FLACDecoder(sampleRate: sampleRate, channels: channels, bitDepth: bitDepth, header: header)
        }
    }
}

/// Audio decoder errors
enum AudioDecoderError: Error {
    case unsupportedBitDepth(Int)
    case invalidDataSize(expected: String, actual: Int)
    case formatCreationFailed(String)
    case conversionFailed(String)
}
