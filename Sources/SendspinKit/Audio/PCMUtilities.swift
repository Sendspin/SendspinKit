// ABOUTME: PCM sample conversion utilities for multi-bit-depth audio
// ABOUTME: Handles 24-bit unpacking for decoder pipeline

import Foundation

/// PCM sample conversion utilities
enum PCMUtilities {
    /// Unpack 3-byte little-endian to Int32 with sign extension
    /// - Parameters:
    ///   - bytes: Source byte array
    ///   - offset: Starting offset in bytes array
    /// - Returns: Signed 24-bit value as Int32
    static func unpack24Bit(_ bytes: [UInt8], offset: Int) -> Int32 {
        let b0 = Int32(bytes[offset])
        let b1 = Int32(bytes[offset + 1])
        let b2 = Int32(bytes[offset + 2])

        var value = b0 | (b1 << 8) | (b2 << 16)

        // Sign extend if negative (bit 23 set)
        if value & 0x80_0000 != 0 {
            value |= ~0xFF_FFFF
        }

        return value
    }
}
