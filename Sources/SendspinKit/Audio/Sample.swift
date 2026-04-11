// ABOUTME: 24-bit audio sample value type
// ABOUTME: Wraps Int32, provides conversions between i16, i24 LE/BE, and f32

import Foundation

/// 24-bit audio sample stored in Int32.
/// Range: -8388608 to 8388607 (2^23)
public struct Sample: Equatable, Hashable, Sendable {
    /// The raw 24-bit sample value stored in an Int32
    public let value: Int32

    /// Maximum valid 24-bit sample value (2^23 - 1)
    public static let max = Sample(8_388_607)
    /// Minimum valid 24-bit sample value (-2^23)
    public static let min = Sample(-8_388_608)
    /// Zero sample value
    public static let zero = Sample(0)

    public init(_ value: Int32) {
        self.value = value
    }

    /// Convert from 16-bit sample (shift left 8 bits to fill 24-bit range)
    public static func fromI16(_ s: Int16) -> Sample {
        Sample(Int32(s) << 8)
    }

    /// Convert from 24-bit little-endian bytes
    public static func fromI24LE(_ bytes: [UInt8]) -> Sample {
        let val = Int32(bytes[0]) | (Int32(bytes[1]) << 8) | (Int32(bytes[2]) << 16)
        // Sign-extend from 24-bit to 32-bit
        let extended = (val & 0x00800000 != 0) ? (val | Int32(bitPattern: 0xFF000000)) : val
        return Sample(extended)
    }

    /// Convert from 24-bit big-endian bytes
    public static func fromI24BE(_ bytes: [UInt8]) -> Sample {
        let val = (Int32(bytes[0]) << 16) | (Int32(bytes[1]) << 8) | Int32(bytes[2])
        // Sign-extend from 24-bit to 32-bit
        let extended = (val & 0x00800000 != 0) ? (val | Int32(bitPattern: 0xFF000000)) : val
        return Sample(extended)
    }

    /// Convert to 16-bit sample (shift right 8 bits)
    public func toI16() -> Int16 {
        Int16(value >> 8)
    }

    /// Convert to f32 in the range [-1.0, 1.0].
    /// MIN maps to exactly -1.0, MAX maps to ~0.9999999.
    public func toF32() -> Float {
        Float(value) / 8_388_608.0
    }

    /// Clamp to valid 24-bit range
    public func clamped() -> Sample {
        Sample(Swift.min(Swift.max(value, Sample.min.value), Sample.max.value))
    }
}
