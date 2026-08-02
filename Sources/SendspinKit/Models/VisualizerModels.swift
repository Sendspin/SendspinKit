import Foundation

// MARK: - Visualizer feature vocabulary

/// Visualizer feature types negotiable via the visualizer role, per spec.
///
/// The client advertises a subset in `client/hello`'s `visualizer@v1_support.types`;
/// the server intersects that with what it can produce and announces the active
/// set in `stream/start`'s `visualizer.types`.
///
/// Raw values match the aiosendspin wire strings (models/visualizer.py `VisualizerType`).
public enum VisualizerFeatureType: String, Codable, Sendable, Hashable, CaseIterable {
    /// Perceptual loudness, one u16 per frame (binary type 16).
    case loudness
    /// Beat markers with a downbeat flag (binary type 17).
    case beat
    /// Dominant frequency + amplitude (binary type 18).
    case fPeak = "f_peak"
    /// Display-binned spectrum, `n_disp_bins` × u16 (binary type 19).
    case spectrum
    /// Energy-onset strength (binary type 20).
    case peak
    /// Perceived pitch as MIDI note + confidence (binary type 21).
    case pitch
}

/// Spectrum binning scale (aiosendspin models/visualizer.py `SpectrumScale`).
public enum SpectrumScale: String, Codable, Sendable, Hashable {
    /// Linear frequency binning.
    case lin
    /// Logarithmic frequency binning.
    case log
    /// Mel-scale (perceptual) frequency binning.
    case mel
}

/// Spectrum configuration, required when ``VisualizerFeatureType/spectrum`` is advertised.
///
/// Appears in two places on the wire: the client's `visualizer@v1_support.spectrum`
/// (validated client input — use ``init(nDispBins:scale:fMin:fMax:)``) and the server's
/// negotiated `stream/start.visualizer.spectrum` (server-provided values, decoded
/// without validation like other server payloads — treat as untrusted informational
/// metadata and sanity-check before relying on them).
public struct VisualizerSpectrumConfig: Codable, Sendable, Hashable {
    /// Number of display bins in each binary spectrum frame. Drives the expected
    /// payload size of binary type 19 frames (`nDispBins` × 2 bytes).
    public let nDispBins: Int
    /// Frequency binning scale.
    public let scale: SpectrumScale
    /// Lower frequency bound in Hz.
    public let fMin: Int
    /// Upper frequency bound in Hz.
    public let fMax: Int

    enum CodingKeys: String, CodingKey {
        case nDispBins = "n_disp_bins"
        case scale
        case fMin = "f_min"
        case fMax = "f_max"
    }

    /// Create a validated spectrum configuration for `client/hello`.
    ///
    /// Mirrors aiosendspin's `ClientHelloVisualizerSpectrum` validation
    /// (models/visualizer.py): positive bin count and a non-inverted, non-negative
    /// frequency range.
    public init(nDispBins: Int, scale: SpectrumScale, fMin: Int, fMax: Int) throws(ConfigurationError) {
        guard nDispBins > 0 else { throw .nonPositiveSpectrumBins(nDispBins) }
        guard fMin >= 0, fMax > fMin else { throw .invalidSpectrumFrequencyRange(fMin: fMin, fMax: fMax) }
        self.nDispBins = nDispBins
        self.scale = scale
        self.fMin = fMin
        self.fMax = fMax
    }
}

// MARK: - Negotiated stream/start visualizer object

/// The server's negotiated visualizer stream announcement in `stream/start`
/// (aiosendspin models/visualizer.py `StreamStartVisualizer`).
///
/// Decoding is deliberately tolerant: `stream/start` is one message carrying the
/// player, artwork, AND visualizer sections, so a malformed or forward-incompatible
/// visualizer block must not fail the whole decode and silence audio. Unknown
/// feature strings are dropped from ``types``; missing fields decode to safe
/// defaults. Values are server-provided informational metadata — no validation
/// beyond `Decodable`.
public struct StreamVisualizerConfig: Codable, Sendable, Hashable {
    /// Active feature types the server will stream (unknown wire strings are dropped).
    public let types: [VisualizerFeatureType]
    /// Maximum per-feature frame rate in Hz the server will send (0 if absent/malformed).
    public let rateMax: Int
    /// Whether beat frames distinguish downbeats, when the server reports it.
    public let tracksDownbeats: Bool?
    /// Negotiated spectrum binning, present when ``types`` contains `.spectrum`.
    /// `spectrum.nDispBins` sizes binary spectrum frames (see ``VisualizerFrame``).
    public let spectrum: VisualizerSpectrumConfig?

    enum CodingKeys: String, CodingKey {
        case types
        case rateMax = "rate_max"
        case tracksDownbeats = "tracks_downbeats"
        case spectrum
    }

    public init(
        types: [VisualizerFeatureType],
        rateMax: Int,
        tracksDownbeats: Bool? = nil,
        spectrum: VisualizerSpectrumConfig? = nil
    ) {
        self.types = types
        self.rateMax = rateMax
        self.tracksDownbeats = tracksDownbeats
        self.spectrum = spectrum
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerate unknown/newer feature strings by dropping them rather than
        // failing the whole stream/start decode.
        let rawTypes = (try? container.decode([String].self, forKey: .types)) ?? []
        types = rawTypes.compactMap(VisualizerFeatureType.init(rawValue:))
        rateMax = (try? container.decode(Int.self, forKey: .rateMax)) ?? 0
        tracksDownbeats = try? container.decodeIfPresent(Bool.self, forKey: .tracksDownbeats)
        spectrum = try? container.decodeIfPresent(VisualizerSpectrumConfig.self, forKey: .spectrum)
    }
}

// MARK: - Binary visualizer frames

/// A decoded visualizer feature frame from binary types 16–21
/// (aiosendspin server/roles/visualizer/v1.py wire packing, all big-endian).
///
/// On the v1 wire each binary message carries exactly one feature, so this is an
/// enum, not a struct of optionals. Values are the raw unsigned integers from the
/// wire; scaling to display units is the consumer's concern.
public enum VisualizerFrame: Sendable, Hashable {
    /// Perceptual loudness (u16) — binary type 16.
    case loudness(UInt16)
    /// Beat marker; `isDownbeat` is bit 0 of the flags byte — binary type 17.
    case beat(isDownbeat: Bool)
    /// Dominant frequency in Hz + amplitude (u16 each) — binary type 18.
    /// `frequencyHz == 0` implies `amplitude == 0`.
    case fPeak(frequencyHz: UInt16, amplitude: UInt16)
    /// Display-binned spectrum, one u16 per negotiated bin — binary type 19.
    case spectrum([UInt16])
    /// Energy-onset strength (u8) — binary type 20.
    case peak(strength: UInt8)
    /// Perceived pitch as MIDI note in Q8.8 fixed point + confidence (u8) — binary type 21.
    case pitch(midiQ88: UInt16, confidence: UInt8)

    /// Decode a frame body for the given feature type.
    ///
    /// - Parameters:
    ///   - type: Which feature the payload encodes (from the binary message type byte).
    ///   - payload: The frame body after the 9-byte Sendspin binary header.
    ///   - spectrumBins: Negotiated `n_disp_bins`, required to size a spectrum frame.
    ///     Pass the value from the `stream/start.visualizer.spectrum` announcement
    ///     (or the client's own hello support config). Ignored for other types.
    /// - Returns: The decoded frame, or `nil` if the payload length is wrong for the type.
    public init?(type: VisualizerFeatureType, payload: Data, spectrumBins: Int = 0) {
        switch type {
        case .loudness:
            // v1.py — struct.pack(">H", loudness).
            guard payload.count == 2 else { return nil }
            self = .loudness(Self.readUInt16(payload, at: payload.startIndex))
        case .beat:
            // v1.py — a single flags byte; bit 0 = downbeat.
            guard payload.count == 1 else { return nil }
            self = .beat(isDownbeat: (payload[payload.startIndex] & 0b0000_0001) != 0)
        case .fPeak:
            // v1.py — struct.pack(">HH", freq, amp).
            guard payload.count == 4 else { return nil }
            self = .fPeak(
                frequencyHz: Self.readUInt16(payload, at: payload.startIndex),
                amplitude: Self.readUInt16(payload, at: payload.startIndex + 2)
            )
        case .spectrum:
            // v1.py — spectrum.astype(">u2"), n_disp_bins values.
            guard spectrumBins > 0, payload.count == spectrumBins * 2 else { return nil }
            var bins = [UInt16]()
            bins.reserveCapacity(spectrumBins)
            var index = payload.startIndex
            for _ in 0 ..< spectrumBins {
                bins.append(Self.readUInt16(payload, at: index))
                index += 2
            }
            self = .spectrum(bins)
        case .peak:
            // v1.py — one u8 strength byte.
            guard payload.count == 1 else { return nil }
            self = .peak(strength: payload[payload.startIndex])
        case .pitch:
            // v1.py — struct.pack(">H", midi_q88) + confidence byte.
            guard payload.count == 3 else { return nil }
            self = .pitch(
                midiQ88: Self.readUInt16(payload, at: payload.startIndex),
                confidence: payload[payload.startIndex + 2]
            )
        }
    }

    /// Read a big-endian u16 at the given absolute index within `data`.
    private static func readUInt16(_ data: Data, at index: Data.Index) -> UInt16 {
        (UInt16(data[index]) << 8) | UInt16(data[index + 1])
    }
}
