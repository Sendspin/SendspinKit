// ABOUTME: Tests for Sample type - 24-bit audio sample value type
// ABOUTME: Translated from sendspin-rs/tests/audio_types.rs

import Testing
@testable import SendspinKit

@Suite("Sample Type")
struct SampleTests {

    // MARK: - i16 Roundtrip

    @Test("i16 roundtrip preserves value")
    func sampleFromI16Roundtrip() {
        #expect(Sample.fromI16(1000).toI16() == 1000)
    }

    @Test("i16 boundary values roundtrip")
    func sampleFromI16BoundaryValues() {
        #expect(Sample.fromI16(Int16.max).toI16() == Int16.max)
        #expect(Sample.fromI16(Int16.min).toI16() == Int16.min)
        #expect(Sample.fromI16(0).toI16() == 0)
        #expect(Sample.fromI16(-1).toI16() == -1)
        #expect(Sample.fromI16(1).toI16() == 1)
    }

    // MARK: - i24 Little-Endian

    @Test("i24 LE decodes correctly")
    func sampleFromI24LE() {
        let bytes: [UInt8] = [0x00, 0x10, 0x00] // 4096 in 24-bit LE
        let sample = Sample.fromI24LE(bytes)
        #expect(sample.toF32() == Float(4096.0 / 8_388_608.0))
    }

    @Test("i24 LE negative value")
    func sampleFromI24LENegative() {
        // -1 in 24-bit LE: 0xFF 0xFF 0xFF
        let sample = Sample.fromI24LE([0xFF, 0xFF, 0xFF])
        #expect(sample == Sample(-1))
    }

    @Test("i24 LE boundary values")
    func sampleFromI24LEBoundaryValues() {
        // Max 24-bit: 0x7FFFFF = 8388607
        let maxSample = Sample.fromI24LE([0xFF, 0xFF, 0x7F])
        #expect(maxSample == Sample.max)

        // Min 24-bit: 0x800000 = -8388608
        let minSample = Sample.fromI24LE([0x00, 0x00, 0x80])
        #expect(minSample == Sample.min)

        // Zero
        let zero = Sample.fromI24LE([0x00, 0x00, 0x00])
        #expect(zero == Sample.zero)
    }

    // MARK: - i24 Big-Endian

    @Test("i24 BE roundtrip")
    func sampleFromI24BERoundtrip() {
        // 4096 in 24-bit BE: 0x00 0x10 0x00
        let sample = Sample.fromI24BE([0x00, 0x10, 0x00])
        #expect(sample == Sample(4096))

        // -1 in 24-bit BE
        let neg = Sample.fromI24BE([0xFF, 0xFF, 0xFF])
        #expect(neg == Sample(-1))
    }

    @Test("i24 BE boundary values")
    func sampleFromI24BEBoundaryValues() {
        // Max 24-bit: 0x7FFFFF = 8388607
        let maxSample = Sample.fromI24BE([0x7F, 0xFF, 0xFF])
        #expect(maxSample == Sample.max)

        // Min 24-bit: 0x800000 = -8388608
        let minSample = Sample.fromI24BE([0x80, 0x00, 0x00])
        #expect(minSample == Sample.min)

        // Zero
        let zero = Sample.fromI24BE([0x00, 0x00, 0x00])
        #expect(zero == Sample.zero)
    }

    // MARK: - Clamp

    @Test("clamp out of range")
    func sampleClampOutOfRange() {
        let overMax = Sample(10_000_000)
        #expect(overMax.clamped() == Sample.max)

        let underMin = Sample(-10_000_000)
        #expect(underMin.clamped() == Sample.min)
    }

    @Test("clamp within range is identity")
    func sampleClampWithinRange() {
        let inRange = Sample(42)
        #expect(inRange.clamped() == Sample(42))

        #expect(Sample.zero.clamped() == Sample.zero)
        #expect(Sample.max.clamped() == Sample.max)
        #expect(Sample.min.clamped() == Sample.min)
    }

    // MARK: - Float conversion

    @Test("toF32 range")
    func sampleToF32Range() {
        // MIN should map to exactly -1.0
        #expect(Sample.min.toF32() == -1.0)
        // ZERO should map to 0.0
        #expect(Sample.zero.toF32() == 0.0)
        // MAX should be close to but not exceed 1.0
        let maxF32 = Sample.max.toF32()
        #expect(maxF32 > 0.999 && maxF32 < 1.0)
    }

    @Test("toF32 typical values")
    func sampleToF32TypicalValues() {
        // Half of max should be ~0.5
        let half = Sample(8_388_608 / 2).toF32()
        #expect(abs(half - 0.5) < 0.001)

        // Negative half should be ~-0.5
        let negHalf = Sample(-8_388_608 / 2).toF32()
        #expect(abs(negHalf - (-0.5)) < 0.001)

        // Small positive value from i16 conversion
        let fromI16 = Sample.fromI16(1000)
        let f = fromI16.toF32()
        #expect(f > 0.0 && f < 1.0)
    }

    // MARK: - AudioFormatSpec equality

    @Test("AudioFormatSpec equality")
    func audioFormatSpecEquality() {
        let format1 = AudioFormatSpec(
            codec: .pcm,
            channels: 2,
            sampleRate: 48000,
            bitDepth: 24
        )
        let format2 = AudioFormatSpec(
            codec: .pcm,
            channels: 2,
            sampleRate: 48000,
            bitDepth: 24
        )
        #expect(format1 == format2)

        let different = AudioFormatSpec(
            codec: .pcm,
            channels: 2,
            sampleRate: 44100,
            bitDepth: 16
        )
        #expect(format1 != different)
    }
}
