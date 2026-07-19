// Conformance fixtures for the visualizer@v1 role, hand-derived from the
// aiosendspin 6.0.5 reference implementation (Music Assistant 2.9.x):
//   models/visualizer.py — ClientHelloVisualizerSupport, ClientHelloVisualizerSpectrum,
//                          StreamStartVisualizer, VisualizerType, SpectrumScale
//   models/types.py      — BinaryMessageType 16-21, BINARY_HEADER_FORMAT ">Bq"
//   server/roles/visualizer/v1.py — per-feature binary payload packing
//
// The hello fixtures are the regression guard for the "empty support object"
// outage: aiosendspin 6.x hard-rejects a client/hello whose visualizer@v1_support
// is `{}`, so the encoded object must always carry every validated field.

import Foundation
@testable import SendspinKit
import Testing

struct VisualizerModelTests {
    // MARK: - Helpers

    private func encodeToObject(_ message: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(message)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let data = try #require(json.data(using: .utf8))
        return try JSONDecoder().decode(type, from: data)
    }

    /// Build a `[type:1][timestamp:8 big-endian][payload]` binary frame
    /// (aiosendspin BINARY_HEADER_FORMAT ">Bq").
    private func binaryFrame(_ type: BinaryMessageType, timestamp: Int64, payload: [UInt8]) -> Data {
        var data = Data([type.rawValue])
        withUnsafeBytes(of: timestamp.bigEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: payload)
        return data
    }

    // MARK: - client/hello visualizer@v1_support (models/visualizer.py ClientHelloVisualizerSupport)

    @Test
    func clientHello_visualizerSupportIsAFullObjectNeverEmpty() throws {
        // ClientHelloVisualizerSupport requires buffer_capacity > 0, rate_max > 0,
        // non-empty types, and a spectrum object when "spectrum" is in types
        // (ClientHelloVisualizerSpectrum). An empty {} is rejected with the whole hello.
        let payload = try ClientHelloPayload(
            clientId: "test-visualizer",
            name: "Test Visualizer",
            deviceInfo: nil,
            version: 1,
            supportedRoles: [.visualizerV1],
            playerV1Support: nil,
            artworkV1Support: nil,
            visualizerV1Support: VisualizerSupport(
                bufferCapacity: 1_000_000,
                rateMax: 30,
                types: [.loudness, .spectrum, .beat],
                spectrum: VisualizerSpectrumConfig(nDispBins: 48, scale: .log, fMin: 40, fMax: 16_000)
            )
        )
        let obj = try encodeToObject(ClientHelloMessage(payload: payload))
        let payloadObj = try #require(obj["payload"] as? [String: Any])

        #expect((payloadObj["supported_roles"] as? [String])?.contains("visualizer@v1") == true)
        let support = try #require(payloadObj["visualizer@v1_support"] as? [String: Any])
        // The exact fields aiosendspin 6.x validates; the rejected empty-{} shape must never occur.
        #expect(!support.isEmpty)
        #expect(support["buffer_capacity"] as? Int == 1_000_000)
        #expect(support["rate_max"] as? Int == 30)
        #expect(support["types"] as? [String] == ["loudness", "spectrum", "beat"])
        let spectrum = try #require(support["spectrum"] as? [String: Any])
        #expect(spectrum["n_disp_bins"] as? Int == 48)
        #expect(spectrum["scale"] as? String == "log")
        #expect(spectrum["f_min"] as? Int == 40)
        #expect(spectrum["f_max"] as? Int == 16_000)
    }

    @Test
    func clientHello_spectrumlessSupportOmitsSpectrumKey() throws {
        let payload = ClientHelloPayload(
            clientId: "test-visualizer",
            name: "Test Visualizer",
            deviceInfo: nil,
            version: 1,
            supportedRoles: [.visualizerV1],
            playerV1Support: nil,
            artworkV1Support: nil,
            visualizerV1Support: VisualizerSupport(
                bufferCapacity: VisualizerConfiguration.defaultBufferCapacity,
                rateMax: VisualizerConfiguration.defaultRateMax,
                types: [.loudness],
                spectrum: nil
            )
        )
        let obj = try encodeToObject(ClientHelloMessage(payload: payload))
        let payloadObj = try #require(obj["payload"] as? [String: Any])
        let support = try #require(payloadObj["visualizer@v1_support"] as? [String: Any])
        // Absent spectrum must be an omitted key, not an explicit null.
        #expect(support.keys.contains("spectrum") == false)
    }

    @Test
    @MainActor
    func clientFacade_buildsFullVisualizerSupportFromConfiguration() throws {
        let client = try SendspinClient(
            clientId: "test-visualizer",
            name: "Test Visualizer",
            roles: [.visualizerV1],
            visualizerConfig: VisualizerConfiguration(
                types: [.loudness, .spectrum],
                spectrum: VisualizerSpectrumConfig(nDispBins: 64, scale: .mel, fMin: 20, fMax: 20_000)
            )
        )
        let hello = client.buildClientHelloPayload()
        let support = try #require(hello.visualizerV1Support)
        #expect(support.bufferCapacity == VisualizerConfiguration.defaultBufferCapacity)
        #expect(support.rateMax == VisualizerConfiguration.defaultRateMax)
        #expect(support.types == [.loudness, .spectrum])
        #expect(support.spectrum?.nDispBins == 64)
    }

    @Test
    @MainActor
    func visualizerRole_requiresConfiguration() {
        #expect(throws: ConfigurationError.visualizerRoleRequiresConfiguration) {
            _ = try SendspinClient(
                clientId: "test-visualizer",
                name: "Test Visualizer",
                roles: [.visualizerV1]
            )
        }
    }

    // MARK: - VisualizerConfiguration validation (mirrors ClientHelloVisualizerSupport)

    @Test
    func configuration_rejectsInvalidInput() throws {
        #expect(throws: ConfigurationError.emptyVisualizerTypes) {
            _ = try VisualizerConfiguration(types: [])
        }
        #expect(throws: ConfigurationError.nonPositiveVisualizerBufferCapacity(0)) {
            _ = try VisualizerConfiguration(types: [.loudness], bufferCapacity: 0)
        }
        #expect(throws: ConfigurationError.nonPositiveVisualizerRateMax(-1)) {
            _ = try VisualizerConfiguration(types: [.loudness], rateMax: -1)
        }
        // "spectrum" in types requires a spectrum config.
        #expect(throws: ConfigurationError.spectrumConfigurationRequired) {
            _ = try VisualizerConfiguration(types: [.loudness, .spectrum])
        }
        #expect(throws: ConfigurationError.nonPositiveSpectrumBins(0)) {
            _ = try VisualizerSpectrumConfig(nDispBins: 0, scale: .log, fMin: 40, fMax: 16_000)
        }
        #expect(throws: ConfigurationError.invalidSpectrumFrequencyRange(fMin: 100, fMax: 100)) {
            _ = try VisualizerSpectrumConfig(nDispBins: 48, scale: .log, fMin: 100, fMax: 100)
        }
    }

    // MARK: - stream/start visualizer (models/visualizer.py StreamStartVisualizer)

    @Test
    func streamStart_withPlayerAndVisualizerSectionsDecodes() throws {
        let json = """
        {
          "type": "stream/start",
          "payload": {
            "player": {"codec": "flac", "sample_rate": 48000, "channels": 2, "bit_depth": 24, "codec_header": "ZkxhQw=="},
            "visualizer": {"types": ["loudness", "spectrum", "beat"], "rate_max": 60, "tracks_downbeats": true,
                           "spectrum": {"n_disp_bins": 48, "scale": "log", "f_min": 40, "f_max": 16000}}
          }
        }
        """
        let message = try decode(StreamStartMessage.self, json)
        let player = try #require(message.payload.player)
        #expect(player.codec == "flac")

        let visualizer = try #require(message.payload.visualizer)
        #expect(visualizer.types == [.loudness, .spectrum, .beat])
        #expect(visualizer.rateMax == 60)
        #expect(visualizer.tracksDownbeats == true)
        #expect(visualizer.spectrum?.nDispBins == 48)
        #expect(visualizer.spectrum?.scale == .log)
    }

    @Test
    func streamStart_visualizerDropsUnknownFeatureStringsWithoutFailing() throws {
        // A newer server may stream feature types this client doesn't know.
        // They must be dropped — not fail the whole stream/start (which would
        // also kill the player section and silence audio).
        let json = """
        {"type": "stream/start", "payload": {"visualizer": {"types": ["loudness", "chroma"], "rate_max": 30}}}
        """
        let message = try decode(StreamStartMessage.self, json)
        #expect(message.payload.visualizer?.types == [.loudness])
        #expect(message.payload.visualizer?.rateMax == 30)
        #expect(message.payload.player == nil)
    }

    // MARK: - Binary visualizer frames (models/types.py 16-21, server/roles/visualizer/v1.py packing)

    @Test
    func binaryTypes_coverTheVisualizerRange() {
        // models/types.py BinaryMessageType: one ID per feature in 16-21.
        #expect(BinaryMessageType.visualizerLoudness.rawValue == 16)
        #expect(BinaryMessageType.visualizerBeat.rawValue == 17)
        #expect(BinaryMessageType.visualizerFPeak.rawValue == 18)
        #expect(BinaryMessageType.visualizerSpectrum.rawValue == 19)
        #expect(BinaryMessageType.visualizerPeak.rawValue == 20)
        #expect(BinaryMessageType.visualizerPitch.rawValue == 21)

        #expect(BinaryMessageType.visualizerBeat.visualizerFeature == .beat)
        #expect(BinaryMessageType.audioChunk.visualizerFeature == nil)
        #expect(BinaryMessageType.artworkChannel0.visualizerFeature == nil)
    }

    @Test
    func binaryLoudnessFrame_decodesAU16() throws {
        // v1.py — struct.pack(">H", loudness).
        let message = try #require(BinaryMessage(data: binaryFrame(.visualizerLoudness, timestamp: 5_000_000, payload: [0x12, 0x34])))
        #expect(message.type == .visualizerLoudness)
        #expect(message.timestamp == 5_000_000)
        let frame = try #require(VisualizerFrame(type: .loudness, payload: message.data))
        #expect(frame == .loudness(0x1234))
    }

    @Test
    func binaryBeatFrame_decodesTheDownbeatFlag() throws {
        // v1.py — one flags byte; bit 0 = downbeat.
        let downbeat = try #require(BinaryMessage(data: binaryFrame(.visualizerBeat, timestamp: 1, payload: [0x01])))
        #expect(VisualizerFrame(type: .beat, payload: downbeat.data) == .beat(isDownbeat: true))
        let offbeat = try #require(BinaryMessage(data: binaryFrame(.visualizerBeat, timestamp: 2, payload: [0x00])))
        #expect(VisualizerFrame(type: .beat, payload: offbeat.data) == .beat(isDownbeat: false))
    }

    @Test
    func binaryFPeakFrame_decodesFrequencyAndAmplitude() throws {
        // v1.py — struct.pack(">HH", freq, amp).
        let message = try #require(BinaryMessage(data: binaryFrame(.visualizerFPeak, timestamp: 3, payload: [0x01, 0x00, 0x00, 0xFF])))
        #expect(VisualizerFrame(type: .fPeak, payload: message.data) == .fPeak(frequencyHz: 256, amplitude: 255))
    }

    @Test
    func binarySpectrumFrame_decodesNegotiatedBinCountU16Values() throws {
        // v1.py — spectrum.astype(">u2"); sizing requires the negotiated n_disp_bins.
        let message = try #require(BinaryMessage(data: binaryFrame(
            .visualizerSpectrum, timestamp: 4, payload: [0x00, 0x01, 0x00, 0x02, 0x00, 0x03]
        )))
        let frame = try #require(VisualizerFrame(type: .spectrum, payload: message.data, spectrumBins: 3))
        #expect(frame == .spectrum([1, 2, 3]))
        // A mismatched bin count (or an unknown one) must reject, not mis-slice.
        #expect(VisualizerFrame(type: .spectrum, payload: message.data, spectrumBins: 2) == nil)
        #expect(VisualizerFrame(type: .spectrum, payload: message.data) == nil)
    }

    @Test
    func binaryPeakAndPitchFrames_decode() throws {
        // v1.py — peak: one u8 strength byte; pitch: struct.pack(">H", midi_q88) + confidence byte.
        let peak = try #require(BinaryMessage(data: binaryFrame(.visualizerPeak, timestamp: 5, payload: [0xAB])))
        #expect(VisualizerFrame(type: .peak, payload: peak.data) == .peak(strength: 0xAB))

        let pitch = try #require(BinaryMessage(data: binaryFrame(.visualizerPitch, timestamp: 6, payload: [0x2D, 0x00, 0x80])))
        #expect(VisualizerFrame(type: .pitch, payload: pitch.data) == .pitch(midiQ88: 0x2D00, confidence: 0x80))
    }

    @Test
    func wrongLengthPayloads_rejectRatherThanMisdecode() {
        #expect(VisualizerFrame(type: .loudness, payload: Data([0x01])) == nil)
        #expect(VisualizerFrame(type: .beat, payload: Data()) == nil)
        #expect(VisualizerFrame(type: .fPeak, payload: Data([0x01, 0x02])) == nil)
        #expect(VisualizerFrame(type: .peak, payload: Data([0x01, 0x02])) == nil)
        #expect(VisualizerFrame(type: .pitch, payload: Data([0x01, 0x02])) == nil)
    }

    @Test
    func visualizerData_decodesItsPayloadThroughFrame() {
        let data = VisualizerData(type: .loudness, data: Data([0x00, 0x7F]), localDisplayTime: 1_000)
        #expect(data.frame() == .loudness(0x7F))
    }
}
