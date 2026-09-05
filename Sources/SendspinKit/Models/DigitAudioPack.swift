import Foundation

/// One validated server-supplied spoken-digit clip.
public struct DigitAudioClip: Sendable, Equatable {
    public let digit: UInt8
    public let data: Data

    public init(digit: UInt8, data: Data) {
        self.digit = digit
        self.data = data
    }
}

/// The ten clips used by a dynamic digits pairing attempt.
public struct DigitAudioPack: Sendable, Equatable {
    public let clips: [DigitAudioClip]

    public init(clips: [DigitAudioClip]) {
        self.clips = clips
    }
}

/// Header constants for the wire formats validated below.
public enum DigitAudioPackConstants {
    public static let clipCount = 10
    public static let maximumDurationSeconds = 2
    public static let opusGranuleRate = 48_000
    public static let flacStreamInfoOffset = 8
    public static let flacStreamInfoLength = 34
    public static let flacSampleRateOffset = 18
    public static let flacChannelsBitsOffset = 20
    public static let flacBitDepthBitsOffset = 20
    public static let flacTotalSamplesOffset = 21
    public static let oggPageHeaderSize = 27
    public static let oggGranulePositionOffset = 6
    public static let opusHeadLength = 19
}

/// The pack is presentation-only, so this validator checks stream headers and bounds while the host decoder remains the final arbiter.
struct DigitAudioPackValidator {
    enum Error: Swift.Error, Equatable {
        case invalidDigit
        case wrongOrder
        case duplicateDigit
        case malformedClip
        case contradictoryParameters
        case tooLong
        case tooLarge
        case incomplete
    }

    let descriptor: DigitAudioDescriptor
    private(set) var clips: [DigitAudioClip] = []
    private(set) var totalBytes = 0

    mutating func append(digit: UInt8, data: Data) throws {
        guard Int(digit) < DigitAudioPackConstants.clipCount else { throw Error.invalidDigit }
        guard digit == UInt8(clips.count) else {
            if clips.contains(where: { $0.digit == digit }) {
                throw Error.duplicateDigit
            }
            throw Error.wrongOrder
        }
        guard !data.isEmpty else { throw Error.malformedClip }
        guard totalBytes <= descriptor.maxBytes,
              data.count <= descriptor.maxBytes - totalBytes
        else { throw Error.tooLarge }
        try validateClip(data)
        let checkedTotal = totalBytes.addingReportingOverflow(data.count)
        guard !checkedTotal.overflow else { throw Error.tooLarge }
        clips.append(DigitAudioClip(digit: digit, data: data))
        totalBytes = checkedTotal.partialValue
    }

    func finish() throws -> DigitAudioPack {
        guard clips.count == DigitAudioPackConstants.clipCount else { throw Error.incomplete }
        return DigitAudioPack(clips: clips)
    }

    private func validateClip(_ data: Data) throws {
        switch descriptor.codec {
        case .pcm:
            let bytesPerSample = (descriptor.bitDepth + 7) / 8
            guard data.count % bytesPerSample == 0 else { throw Error.malformedClip }
            let samples = data.count / bytesPerSample
            guard samples <= descriptor.sampleRate * DigitAudioPackConstants.maximumDurationSeconds else { throw Error.tooLong }
        case .flac:
            try validateFLAC(data)
        case .opus:
            try validateOpus(data)
        }
    }

    private func validateFLAC(_ data: Data) throws {
        let streamInfoEnd = DigitAudioPackConstants.flacStreamInfoOffset + DigitAudioPackConstants.flacStreamInfoLength
        guard data.count >= streamInfoEnd, data.prefix(4) == Data("fLaC".utf8) else { throw Error.malformedClip }
        var offset = 4
        var streamInfoFound = false
        var metadataEnded = false
        while !metadataEnded {
            guard offset <= data.count - 4 else { throw Error.malformedClip }
            let header = data[offset]
            let blockLength = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            guard blockLength <= data.count - offset - 4 else { throw Error.malformedClip }
            let blockStart = offset + 4
            if header & 0x7F == 0 {
                guard !streamInfoFound, blockLength == DigitAudioPackConstants.flacStreamInfoLength,
                      blockLength >= 18 else { throw Error.malformedClip }
                streamInfoFound = true
                let d18 = data[blockStart + 10], d19 = data[blockStart + 11], d20 = data[blockStart + 12]
                let sampleRate = Int(d18) << 12 | Int(d19) << 4 | Int(d20 >> 4)
                let channels = Int((d20 >> 1) & 7) + 1
                let bitDepth = Int((d20 & 1) << 4 | (data[blockStart + 13] >> 4)) + 1
                let totalSamples = UInt64(data[blockStart + 13] & 0x0F) << 32
                    | UInt64(data[blockStart + 14]) << 24 | UInt64(data[blockStart + 15]) << 16
                    | UInt64(data[blockStart + 16]) << 8 | UInt64(data[blockStart + 17])
                guard channels == 1, sampleRate == descriptor.sampleRate, bitDepth == descriptor.bitDepth else {
                    throw Error.contradictoryParameters
                }
                guard totalSamples <= UInt64(descriptor.sampleRate) * UInt64(DigitAudioPackConstants.maximumDurationSeconds) else {
                    throw Error.tooLong
                }
            }
            metadataEnded = header & 0x80 != 0
            offset = blockStart + blockLength
        }
        guard streamInfoFound, offset < data.count else { throw Error.malformedClip }
    }

    private func validateOpus(_ data: Data) throws {
        var offset = 0
        var pages: [(granule: UInt64, payload: Data)] = []
        while offset < data.count {
            guard data.count - offset >= DigitAudioPackConstants.oggPageHeaderSize,
                  data[offset ..< offset + 4] == Data("OggS".utf8), data[offset + 4] == 0 else { throw Error.malformedClip }
            let segmentCount = Int(data[offset + 26])
            guard data.count - offset >= 27 + segmentCount else { throw Error.malformedClip }
            let payloadLength = (0 ..< segmentCount).reduce(into: 0) { total, index in total += Int(data[offset + 27 + index]) }
            let pageLength = 27 + segmentCount + payloadLength
            guard payloadLength > 0, pageLength <= data.count - offset else { throw Error.malformedClip }
            let granule = data[offset + 6 ..< offset + 14].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
            pages.append((granule, Data(data[(offset + 27 + segmentCount) ..< (offset + pageLength)])))
            offset += pageLength
        }
        guard let first = pages.first, pages.count >= 2,
              data[5] & 0x02 != 0,
              first.payload.count >= DigitAudioPackConstants.opusHeadLength,
              first.payload.prefix(8) == Data("OpusHead".utf8), first.payload[8] == 1,
              first.payload[9] == 1
        else { throw Error.malformedClip }
        let preSkip = UInt64(first.payload[10]) | UInt64(first.payload[11]) << 8
        guard let lastGranule = pages.last?.granule,
              lastGranule != UInt64.max,
              lastGranule >= preSkip
        else { throw Error.malformedClip }
        guard lastGranule - preSkip <= UInt64(
            DigitAudioPackConstants.opusGranuleRate * DigitAudioPackConstants.maximumDurationSeconds
        ) else { throw Error.tooLong }
    }
}
