import Foundation
@testable import SendspinKit
import Testing

@Suite("Digit audio pack validation")
struct DigitAudioPackTests {
    private let descriptor = DigitAudioDescriptor(codec: .pcm, sampleRate: 8_000, bitDepth: 16, maxBytes: 20)

    @Test("PCM pack requires ascending digits exactly once and emits ten clips")
    func completePack() throws {
        var validator = DigitAudioPackValidator(descriptor: descriptor)
        for digit in UInt8(0) ..< 10 {
            try validator.append(digit: digit, data: Data([0, 0]))
        }
        let pack = try validator.finish()
        #expect(pack.clips.map(\.digit) == Array(UInt8(0) ..< 10))
        #expect(pack.clips.allSatisfy { $0.data == Data([0, 0]) })
    }

    @Test("PCM validator rejects out of order, duplicate, and out of range clips")
    func sequenceErrors() throws {
        var outOfOrder = DigitAudioPackValidator(descriptor: descriptor)
        #expect(throws: DigitAudioPackValidator.Error.wrongOrder) {
            try outOfOrder.append(digit: 1, data: Data([0, 0]))
        }

        var duplicate = DigitAudioPackValidator(descriptor: descriptor)
        try duplicate.append(digit: 0, data: Data([0, 0]))
        #expect(throws: DigitAudioPackValidator.Error.duplicateDigit) {
            try duplicate.append(digit: 0, data: Data([0, 0]))
        }

        var invalid = DigitAudioPackValidator(descriptor: descriptor)
        #expect(throws: DigitAudioPackValidator.Error.invalidDigit) {
            try invalid.append(digit: 10, data: Data([0, 0]))
        }
    }

    @Test("PCM validator rejects malformed sample representation, duration, and total size")
    func pcmLimits() throws {
        var malformed = DigitAudioPackValidator(descriptor: descriptor)
        #expect(throws: DigitAudioPackValidator.Error.malformedClip) {
            try malformed.append(digit: 0, data: Data([0]))
        }

        var tooLong = DigitAudioPackValidator(descriptor: DigitAudioDescriptor(codec: .pcm, sampleRate: 8_000, bitDepth: 16, maxBytes: 40_000))
        #expect(throws: DigitAudioPackValidator.Error.tooLong) {
            try tooLong.append(digit: 0, data: Data(repeating: 0, count: 32_002))
        }

        var tooLarge = DigitAudioPackValidator(descriptor: descriptor)
        #expect(throws: DigitAudioPackValidator.Error.tooLarge) {
            try tooLarge.append(digit: 0, data: Data(repeating: 0, count: 22))
        }
    }

    @Test("real libFLAC fixture has the expected STREAMINFO fields")
    func realFLACFixtureHeader() throws {
        let descriptor = DigitAudioDescriptor(codec: .flac, sampleRate: 44_100, bitDepth: 16, maxBytes: 100_000)
        var validator = DigitAudioPackValidator(descriptor: descriptor)
        for digit in UInt8(0) ..< 10 {
            try validator.append(digit: digit, data: FLACChannelSafetyTests.monoFLAC)
        }
        #expect(try validator.finish().clips.first?.digit == 0)
    }

    @Test("incomplete pack is rejected at server pair-init completion")
    func incompletePack() throws {
        var validator = DigitAudioPackValidator(descriptor: descriptor)
        try validator.append(digit: 0, data: Data([0, 0]))
        #expect(throws: DigitAudioPackValidator.Error.incomplete) {
            try validator.finish()
        }
    }
}
