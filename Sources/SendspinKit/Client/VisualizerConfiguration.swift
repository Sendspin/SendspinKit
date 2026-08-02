/// Configuration for the visualizer role, provided when creating a ``SendspinClient``.
///
/// Declares which visualizer feature types the client wants and how fast the server
/// may send them. Encoded into `client/hello` as the `visualizer@v1_support` object,
/// which aiosendspin 6.x validates strictly — an incomplete (or empty) support object
/// is hard-rejected and the connection fails during the handshake, which is why the
/// role cannot be advertised without this configuration.
///
/// This is a client-side configuration container, not a wire type — it is not `Codable`.
/// The wire encoding is the internal `VisualizerSupport` hello struct.
public struct VisualizerConfiguration: Sendable, Hashable {
    /// Default `rate_max` (Hz per feature type).
    ///
    /// Deliberately conservative: the server multiplies this by the number of active
    /// feature types, and frames for the whole audio write-ahead window are queued
    /// per-role on the server. Against aiosendspin (4096-slot per-role queue), 5 types
    /// × 60 Hz = 300 frames/s overflows the queue once the write-ahead exceeds ~13.6 s
    /// — which a 2 MB player `buffer_capacity` reaches on well-compressed FLAC — and
    /// the server then disconnects the client ("Role queue full for visualizer").
    /// 30 Hz keeps a 5-type client safe past 27 s of write-ahead.
    public static let defaultRateMax = 30

    /// Default `buffer_capacity` in bytes of visualizer frames the client can hold.
    public static let defaultBufferCapacity = 1_000_000

    /// Feature types to advertise (non-empty). The server intersects these with
    /// what it can produce and announces the active set in `stream/start`.
    public let types: [VisualizerFeatureType]
    /// Spectrum binning to request; required when ``types`` contains `.spectrum`.
    public let spectrum: VisualizerSpectrumConfig?
    /// How many bytes of visualizer frames the client can buffer.
    public let bufferCapacity: Int
    /// Maximum per-feature frame rate in Hz the server may send.
    public let rateMax: Int

    public init(
        types: [VisualizerFeatureType],
        spectrum: VisualizerSpectrumConfig? = nil,
        bufferCapacity: Int = Self.defaultBufferCapacity,
        rateMax: Int = Self.defaultRateMax
    ) throws(ConfigurationError) {
        // Mirrors aiosendspin's ClientHelloVisualizerSupport validation
        // (models/visualizer.py): non-empty types, positive buffer_capacity and
        // rate_max, spectrum required when "spectrum" is in types.
        guard !types.isEmpty else { throw .emptyVisualizerTypes }
        guard bufferCapacity > 0 else { throw .nonPositiveVisualizerBufferCapacity(bufferCapacity) }
        guard rateMax > 0 else { throw .nonPositiveVisualizerRateMax(rateMax) }
        guard !types.contains(.spectrum) || spectrum != nil else { throw .spectrumConfigurationRequired }
        self.types = types
        self.spectrum = spectrum
        self.bufferCapacity = bufferCapacity
        self.rateMax = rateMax
    }
}
