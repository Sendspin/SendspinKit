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
///
/// Immutable after init — safe to use from any context.
struct PCMDecoder: AudioDecoder {
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

    /// Unpack 3-byte little-endian 24-bit samples into left-justified Int32
    /// for AudioQueue (which expects 32-bit containers for 24-bit audio).
    /// Works directly on Data's underlying bytes — no intermediate [UInt8] copy.
    private func decode24Bit(_ data: Data) throws -> Data {
        let bytesPerSample = 3
        guard data.count % bytesPerSample == 0 else {
            throw AudioDecoderError.invalidDataSize(
                expected: "multiple of 3",
                actual: data.count
            )
        }

        let sampleCount = data.count / bytesPerSample

        return data.withUnsafeBytes { src in
            let base = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
            // Allocate output: 4 bytes per sample (Int32)
            let output = UnsafeMutableBufferPointer<Int32>.allocate(capacity: sampleCount)
            defer { output.deallocate() }

            for i in 0 ..< sampleCount {
                let off = i * bytesPerSample
                var value = Int32(base[off])
                    | (Int32(base[off + 1]) << 8)
                    | (Int32(base[off + 2]) << 16)

                // Sign extend: if bit 23 is set, the value is negative
                if value & 0x80_0000 != 0 {
                    value |= ~0xFF_FFFF
                }

                // Left-shift into 32-bit range for AudioQueue
                output[i] = value << 8
            }

            return Data(buffer: output)
        }
    }
}

/// Opus decoder using libopus via swift-opus package
///
/// **Threading contract:** Not thread-safe. Like `FLACDecoder`, this must be used
/// from a single serial context. In practice it is only accessed from `AudioPlayer`
/// (an actor). `Opus.Decoder` from swift-opus wraps a C `OpusDecoder*` and handles
/// its own cleanup in `deinit`.
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

        // swift-opus outputs interleaved float32 into floatChannelData[0].
        // opus_decode_float always writes interleaved samples (L R L R...),
        // and swift-opus passes floatChannelData![0] as the output pointer.
        // The buffer format is interleaved, so floatChannelData has exactly
        // one pointer — accessing [1] etc. would be out of bounds.
        guard let floatChannelData = pcmBuffer.floatChannelData else {
            throw AudioDecoderError.conversionFailed("No float channel data in decoded buffer")
        }

        let frameLength = Int(pcmBuffer.frameLength)
        let totalSamples = frameLength * channels
        var int32Samples = [Int32](repeating: 0, count: totalSamples)

        // Convert interleaved float32 samples to int32
        // float range [-1.0, 1.0] -> int32 range [Int32.min, Int32.max]
        //
        // Clamping is required because Float(Int32.max) rounds up to 2147483648.0,
        // so a sample of exactly 1.0 would overflow Int32 without clamping.
        let floatData = floatChannelData[0]
        for i in 0 ..< totalSamples {
            int32Samples[i] = clampFloatToInt32(floatData[i])
        }

        // Convert [Int32] to Data
        return int32Samples.withUnsafeBytes { Data($0) }
    }

    /// Convert a float sample in [-1.0, 1.0] to Int32 range with safe clamping.
    private func clampFloatToInt32(_ sample: Float) -> Int32 {
        // Float(Int32.max) rounds up to 2147483648.0 (not representable as Int32),
        // so a sample of exactly 1.0 produces a scaled value that overflows Int32.
        // The Int64 intermediate + clamping handles this: 1.0 maps to Int32.max,
        // and any out-of-range values (e.g. from hot signals) are clamped rather
        // than trapping.
        let scaled = sample * Float(Int32.max)
        return Int32(clamping: Int64(scaled))
    }
}

/// FLAC decoder using libFLAC via flac-binary-xcframework
///
/// **Threading contract:** This type is *not* thread-safe. It must be used
/// from a single serial context (e.g. an actor). The C callbacks registered
/// with libFLAC are synchronous — they fire during `FLAC__stream_decoder_process_single`
/// on the same thread as `decode()`, so no concurrent access to mutable state occurs.
///
/// **Unmanaged safety:** `passUnretained(self)` is used to pass `self` as the
/// C callback client data. This is safe because the libFLAC decoder (`self.decoder`)
/// is owned by this instance and callbacks only fire during `decode()`, which
/// requires `self` to be alive. If this class ever becomes failable after the
/// `Unmanaged` call in `init`, this assumption would break.
class FLACDecoder: AudioDecoder {
    private var decoder: UnsafeMutablePointer<FLAC__StreamDecoder>?
    private let sampleRate: Int
    private let channels: Int
    private let bitDepth: Int

    /// Pending compressed data waiting for libFLAC to consume.
    /// Uses an index-based sliding window: `readOffset` tracks the libFLAC
    /// read position, and we compact the buffer when the consumed prefix
    /// exceeds half the total size, avoiding O(n) removeFirst on every decode.
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

            // If readOffset hasn't advanced at all since this decode() call started,
            // the decoder needs more data than we have. We check against startOffset
            // (not the previous iteration) because the normal flow is: iteration 1
            // processes a metadata block (advances offset, no samples), iteration 2
            // processes the audio frame (advances offset, produces samples). Tracking
            // per-iteration would incorrectly break after the metadata block.
            if readOffset == startOffset, iterations > 1 {
                break
            }

            // Safety limit: 100 process_single calls without producing samples
            // means something is deeply wrong with the stream data.
            if iterations > 100 {
                throw AudioDecoderError.conversionFailed(
                    "FLAC decode stalled: \(iterations) iterations without audio output"
                )
            }
        }

        // Check for errors reported via error callback
        if let error = lastError {
            throw AudioDecoderError.conversionFailed("FLAC decoder error: \(error)")
        }

        // Compact the pending buffer: instead of removing consumed bytes every
        // call (O(n) with Data.removeFirst), we let the consumed prefix grow
        // and only compact when it exceeds half the buffer. This amortises the
        // copy cost over many decode() calls.
        let bytesConsumed = readOffset - startOffset
        if bytesConsumed > 0, readOffset > pendingData.count / 2 {
            pendingData.removeFirst(readOffset)
            readOffset = 0
        }

        // Return decoded samples as Data
        return decodedSamples.withUnsafeBytes { Data($0) }
    }

    private func readCallback(
        buffer: UnsafeMutablePointer<FLAC__byte>?,
        bytes: UnsafeMutablePointer<Int>?
    ) -> FLAC__StreamDecoderReadStatus {
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
            guard let base = srcBytes.baseAddress else { return }
            let src = base.advanced(by: readOffset)
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

        // FLAC outputs int32 samples per channel — interleave for AudioQueue.
        // We use `channels` from init (not the frame header) because FLAC
        // encodes channel count in STREAMINFO, which is fixed for the entire
        // stream. Unlike bit depth, channel count can't vary per frame.
        decodedSamples.reserveCapacity(decodedSamples.count + blocksize * channels)
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
enum AudioDecoderError: Error, LocalizedError {
    case unsupportedBitDepth(Int)
    case invalidDataSize(expected: String, actual: Int)
    case formatCreationFailed(String)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedBitDepth(depth):
            "Unsupported bit depth: \(depth)"
        case let .invalidDataSize(expected, actual):
            "Invalid data size: expected \(expected), got \(actual) bytes"
        case let .formatCreationFailed(detail):
            "Audio format creation failed: \(detail)"
        case let .conversionFailed(detail):
            "Audio conversion failed: \(detail)"
        }
    }
}
