import Foundation
@testable import SendspinKit
import Testing

struct AudioFormatSpecTests {
    // MARK: - Wire format

    @Test
    func audioFormatSpec_encodesWithSnakeCaseKeys() throws {
        let spec = try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16)

        let data = try JSONEncoder().encode(spec)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["codec"] as? String == "opus")
        #expect(json["channels"] as? Int == 2)
        #expect(json["sample_rate"] as? Int == 48_000)
        #expect(json["bit_depth"] as? Int == 16)
        // Verify no camelCase keys leaked
        #expect(!json.keys.contains("sampleRate"))
        #expect(!json.keys.contains("bitDepth"))
    }

    @Test
    func audioFormatSpec_roundTripsThroughJSON() throws {
        let original = try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 24)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioFormatSpec.self, from: data)

        #expect(decoded == original)
    }

    @Test
    func audioFormatSpec_decodesFromSpecCompliantJSON() throws {
        let json = Data("""
        {"codec": "pcm", "channels": 1, "sample_rate": 44100, "bit_depth": 16}
        """.utf8)

        let spec = try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        #expect(spec.codec == .pcm)
        #expect(spec.channels == 1)
        #expect(spec.sampleRate == 44_100)
        #expect(spec.bitDepth == 16)
    }

    @Test
    func audioFormatSpec_supportsAllCodecs() throws {
        for codec in [AudioCodec.opus, .flac, .pcm] {
            let spec = try AudioFormatSpec(codec: codec, channels: 2, sampleRate: 48_000, bitDepth: 16)
            let data = try JSONEncoder().encode(spec)
            let decoded = try JSONDecoder().decode(AudioFormatSpec.self, from: data)
            #expect(decoded.codec == codec)
        }
    }

    // MARK: - Decode validation

    @Test
    func audioFormatSpec_rejectsZeroChannelsViaDecode() {
        let json = Data("""
        {"codec": "pcm", "channels": 0, "sample_rate": 48000, "bit_depth": 16}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        }
    }

    @Test
    func audioFormatSpec_rejectsNegativeChannelsViaDecode() {
        let json = Data("""
        {"codec": "pcm", "channels": -1, "sample_rate": 48000, "bit_depth": 16}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        }
    }

    @Test
    func audioFormatSpec_rejectsChannelsAboveMaxViaDecode() {
        let overMax = AudioFormatSpec.maxChannels + 1
        let json = Data("""
        {"codec": "pcm", "channels": \(overMax), "sample_rate": 48000, "bit_depth": 16}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        }
    }

    @Test
    func audioFormatSpec_rejectsZeroSampleRateViaDecode() {
        let json = Data("""
        {"codec": "pcm", "channels": 2, "sample_rate": 0, "bit_depth": 16}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        }
    }

    @Test
    func audioFormatSpec_rejectsSampleRateAboveMaxViaDecode() {
        let overMax = AudioFormatSpec.maxSampleRate + 1
        let json = Data("""
        {"codec": "pcm", "channels": 2, "sample_rate": \(overMax), "bit_depth": 16}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        }
    }

    @Test
    func audioFormatSpec_rejectsInvalidBitDepthViaDecode() {
        let json = Data("""
        {"codec": "pcm", "channels": 2, "sample_rate": 48000, "bit_depth": 8}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        }
    }

    @Test
    func audioFormatSpec_acceptsNon16BitDepthForOpusMetadata() throws {
        for bitDepth in [24, 32] {
            let format = try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: bitDepth)
            #expect(format.bitDepth == bitDepth)
        }
    }

    @Test
    func audioFormatSpec_acceptsNon16BitDepthForOpusViaDecode() throws {
        let json = Data("""
        {"codec": "opus", "channels": 2, "sample_rate": 48000, "bit_depth": 24}
        """.utf8)

        let format = try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        #expect(format.codec == .opus)
        #expect(format.bitDepth == 24)
    }

    @Test
    func audioFormatSpec_rejectsUnknownCodecViaDecode() {
        // AudioCodec is a String-backed enum — unknown values fail at the Codable layer
        let json = Data("""
        {"codec": "aac", "channels": 2, "sample_rate": 48000, "bit_depth": 16}
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioFormatSpec.self, from: json)
        }
    }

    @Test
    func audioFormatSpec_acceptsBoundaryValues() throws {
        // Upper bounds
        let specMax = try AudioFormatSpec(
            codec: .pcm,
            channels: AudioFormatSpec.maxChannels,
            sampleRate: AudioFormatSpec.maxSampleRate,
            bitDepth: 32
        )
        let dataMax = try JSONEncoder().encode(specMax)
        let decodedMax = try JSONDecoder().decode(AudioFormatSpec.self, from: dataMax)
        #expect(decodedMax.channels == AudioFormatSpec.maxChannels)
        #expect(decodedMax.sampleRate == AudioFormatSpec.maxSampleRate)
        #expect(decodedMax.bitDepth == 32)

        // Lower bounds
        let specMin = try AudioFormatSpec(codec: .pcm, channels: 1, sampleRate: 1, bitDepth: 16)
        let dataMin = try JSONEncoder().encode(specMin)
        let decodedMin = try JSONDecoder().decode(AudioFormatSpec.self, from: dataMin)
        #expect(decodedMin.channels == 1)
        #expect(decodedMin.sampleRate == 1)
    }

    @Test
    func audioFormatSpec_acceptsAllSupportedBitDepths() throws {
        for bitDepth in AudioFormatSpec.supportedBitDepths.sorted() {
            let spec = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: bitDepth)
            let data = try JSONEncoder().encode(spec)
            let decoded = try JSONDecoder().decode(AudioFormatSpec.self, from: data)
            #expect(decoded.bitDepth == bitDepth)
        }
    }

    // MARK: - Init validation (ConfigurationError)

    @Test
    func audioFormatSpec_initRejectsZeroChannels() {
        #expect(throws: ConfigurationError.self) {
            try AudioFormatSpec(codec: .pcm, channels: 0, sampleRate: 48_000, bitDepth: 16)
        }
    }

    @Test
    func audioFormatSpec_initRejectsNegativeChannels() {
        #expect(throws: ConfigurationError.self) {
            try AudioFormatSpec(codec: .pcm, channels: -1, sampleRate: 48_000, bitDepth: 16)
        }
    }

    @Test
    func audioFormatSpec_initRejectsZeroSampleRate() {
        #expect(throws: ConfigurationError.self) {
            try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 0, bitDepth: 16)
        }
    }

    @Test
    func audioFormatSpec_initRejectsUnsupportedBitDepth() {
        #expect(throws: ConfigurationError.self) {
            try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 8)
        }
    }

    // MARK: - effectiveOutputBitDepth

    @Test
    func effectiveOutputBitDepth_returns32ForFLACRegardlessOfBitDepth() throws {
        // FLAC always decodes to Int32 via libFLAC
        let spec16 = try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 16)
        let spec24 = try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 24)
        let spec32 = try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 32)
        #expect(spec16.effectiveOutputBitDepth == 32)
        #expect(spec24.effectiveOutputBitDepth == 32)
        #expect(spec32.effectiveOutputBitDepth == 32)
    }

    @Test
    func effectiveOutputBitDepth_returns32ForOpus() throws {
        let spec = try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16)
        #expect(spec.effectiveOutputBitDepth == 32)
    }

    @Test
    func effectiveOutputBitDepth_returns32For24BitPCM() throws {
        let spec = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 24)
        #expect(spec.effectiveOutputBitDepth == 32)
    }

    @Test
    func effectiveOutputBitDepth_passesThrough16BitPCM() throws {
        let spec = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        #expect(spec.effectiveOutputBitDepth == 16)
    }

    @Test
    func effectiveOutputBitDepth_passesThrough32BitPCM() throws {
        let spec = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 32)
        #expect(spec.effectiveOutputBitDepth == 32)
    }

    // MARK: - Output sample-rate policy

    @Test
    func preferredOutputRateIsStablePartitionAndPreservesBitDepthChoices() throws {
        let formats = try [
            AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 24),
            AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16),
            AudioFormatSpec(codec: .pcm, channels: 1, sampleRate: 48_000, bitDepth: 32),
            AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 16)
        ]

        let effective = try effectiveSupportedFormats(
            formats,
            policy: .preferCurrentOutput,
            outputSampleRate: 48_000
        )

        #expect(effective == [formats[1], formats[2], formats[0], formats[3]])
    }

    @Test
    func preferredPolicyPreservesCatalogWhenOutputIsUnknownOrHasNoMatch() throws {
        let formats = try [
            AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 16),
            AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16)
        ]

        #expect(try effectiveSupportedFormats(formats, policy: .preferCurrentOutput, outputSampleRate: nil) == formats)
        #expect(try effectiveSupportedFormats(formats, policy: .preferCurrentOutput, outputSampleRate: 96_000) == formats)
    }

    @Test
    func preservePolicyLeavesCatalogUnchanged() throws {
        let formats = try [
            AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16),
            AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 24)
        ]

        #expect(try effectiveSupportedFormats(formats, policy: .preserveFormatOrder, outputSampleRate: 44_100) == formats)
    }

    @Test
    func requirePolicyFiltersMatchingFormatsAndRejectsUnknownOrNoMatch() throws {
        let formats = try [
            AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 16),
            AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16),
            AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 32)
        ]

        #expect(
            try effectiveSupportedFormats(formats, policy: .requireCurrentOutput, outputSampleRate: 48_000)
                == [formats[1], formats[2]]
        )
        #expect(throws: OutputFormatError.routeUnavailable) {
            try effectiveSupportedFormats(formats, policy: .requireCurrentOutput, outputSampleRate: nil)
        }
        #expect(throws: OutputFormatError.noMatchingFormat) {
            try effectiveSupportedFormats(formats, policy: .requireCurrentOutput, outputSampleRate: 96_000)
        }
        #expect(try effectiveSupportedFormats([], policy: .preserveFormatOrder, outputSampleRate: 48_000).isEmpty)
        #expect(try effectiveSupportedFormats([], policy: .preferCurrentOutput, outputSampleRate: 48_000).isEmpty)
        #expect(throws: OutputFormatError.noMatchingFormat) {
            try effectiveSupportedFormats([], policy: .requireCurrentOutput, outputSampleRate: 48_000)
        }
    }

    @Test
    func playerConfigurationDefaultsToPreferCurrentOutput() throws {
        let format = try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let configuration = try PlayerConfiguration(bufferCapacity: 1, supportedFormats: [format])

        #expect(configuration.outputSampleRatePolicy == .preferCurrentOutput)
    }

    @Test
    func playerConfigurationStoresExplicitOutputSampleRatePolicy() throws {
        let format = try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 24)
        let configuration = try PlayerConfiguration(
            bufferCapacity: 1,
            supportedFormats: [format],
            outputSampleRatePolicy: .requireCurrentOutput
        )

        #expect(configuration.outputSampleRatePolicy == .requireCurrentOutput)
    }

    // MARK: - Output capability values

    @Test
    func audioOutputSnapshotEqualityUsesEveryPublicField() {
        let reference = AudioOutputSnapshot(
            sampleRate: 48_000,
            reportedBitDepth: 24,
            diagnosticDescription: "Built-in Output"
        )
        let equalValue = AudioOutputSnapshot(
            sampleRate: reference.sampleRate,
            reportedBitDepth: reference.reportedBitDepth,
            diagnosticDescription: reference.diagnosticDescription
        )
        let changedRate = AudioOutputSnapshot(
            sampleRate: 44_100,
            reportedBitDepth: reference.reportedBitDepth,
            diagnosticDescription: reference.diagnosticDescription
        )
        let changedBitDepth = AudioOutputSnapshot(
            sampleRate: reference.sampleRate,
            reportedBitDepth: 32,
            diagnosticDescription: reference.diagnosticDescription
        )
        let changedDescription = AudioOutputSnapshot(
            sampleRate: reference.sampleRate,
            reportedBitDepth: reference.reportedBitDepth,
            diagnosticDescription: "External Output"
        )

        #expect(reference == equalValue)
        #expect(reference != changedRate)
        #expect(reference != changedBitDepth)
        #expect(reference != changedDescription)
        #expect(Set([reference, equalValue, changedRate, changedBitDepth, changedDescription]).count == 4)
    }

    @Test
    func outputFormatStatusConstructsEveryDistinctState() throws {
        let output = AudioOutputSnapshot(
            sampleRate: 48_000,
            reportedBitDepth: nil,
            diagnosticDescription: "Test Route"
        )
        let native = try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let fallback = try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 44_100, bitDepth: 24)
        let states: [OutputFormatStatus.State] = [
            .outputUnknown,
            .noMatchingFormat,
            .preferred(native),
            .requesting(fallback),
            .activeNative(native),
            .activeFallback(fallback)
        ]
        let statuses = states.map { OutputFormatStatus(output: output, state: $0) }

        #expect(statuses.map(\.output) == Array(repeating: output, count: states.count))
        #expect(statuses.map(\.state) == states)
        #expect(Set(states).count == states.count)
        #expect(Set(statuses).count == statuses.count)
    }

    @Test
    func audioSessionActivationStatesAreDistinctAndHashable() {
        let states: Set<AudioSessionActivationState> = [.unknown, .inactive, .active]

        #expect(states.count == 3)
        #expect(states.contains(.unknown))
        #expect(states.contains(.inactive))
        #expect(states.contains(.active))
    }

    @Test
    func capabilityServiceRetainsSnapshotPublishesUpdatesAndFinishesOnStop() async throws {
        let initial = AudioOutputSnapshot(
            sampleRate: nil,
            reportedBitDepth: nil,
            diagnosticDescription: "Route unavailable"
        )
        let updated = AudioOutputSnapshot(
            sampleRate: 48_000,
            reportedBitDepth: 24,
            diagnosticDescription: "USB Output"
        )
        let ignoredAfterStop = AudioOutputSnapshot(
            sampleRate: 44_100,
            reportedBitDepth: 16,
            diagnosticDescription: "Retired Output"
        )
        let service = AudioOutputCapabilityService(
            initialSnapshot: initial,
            platformMonitor: FakeAudioOutputPlatformMonitor()
        )
        let stream = await service.startMonitoring()
        let received = Task { () -> [AudioOutputSnapshot] in
            var snapshots: [AudioOutputSnapshot] = []
            for await snapshot in stream {
                snapshots.append(snapshot)
            }
            return snapshots
        }

        #expect(await service.snapshot() == initial)
        await service.update(updated)
        await service.stopMonitoring()
        await service.stopMonitoring()
        await service.update(ignoredAfterStop)

        let snapshots = try await runUnstructuredWithDeadline(
            .seconds(1),
            label: "audio output capability stream cleanup",
            onTimeout: { received.cancel() },
            operation: { await received.value }
        )
        #expect(snapshots == [updated])
        #expect(await service.snapshot() == updated)
    }

    @Test
    func capabilityServiceBuffersOnlyLatestUpdateBeforeConsumption() async {
        let first = AudioOutputSnapshot(sampleRate: 44_100, reportedBitDepth: 16, diagnosticDescription: "First")
        let latest = AudioOutputSnapshot(sampleRate: 48_000, reportedBitDepth: 24, diagnosticDescription: "Latest")
        let service = AudioOutputCapabilityService(platformMonitor: FakeAudioOutputPlatformMonitor())
        let stream = await service.startMonitoring()

        await service.update(first)
        await service.update(latest)
        await service.stopMonitoring()

        var snapshots: [AudioOutputSnapshot] = []
        for await snapshot in stream {
            snapshots.append(snapshot)
        }
        #expect(snapshots == [latest])
    }

    @Test(arguments: [
        (nil, nil),
        (Double.nan, nil),
        (Double.infinity, nil),
        (-48_000.0, nil),
        (0.0, nil),
        (48_000.009, 48_000),
        (44_099.991, 44_100),
        (48_000.02, nil)
    ])
    func capabilityServiceNormalizesOnlyTrustworthyIntegralRates(value: Double?, expected: Int?) {
        #expect(AudioOutputCapabilityService.normalizeSampleRate(value) == expected)
    }

    @Test
    func capabilityServiceCoalescesRepeatedSnapshotsButPublishesDiagnosticChanges() async throws {
        let monitor = FakeAudioOutputPlatformMonitor(requiresActiveAudioSession: false)
        let service = AudioOutputCapabilityService(platformMonitor: monitor)
        let stream = await service.startMonitoring()
        await monitor.waitForStartCount(1)
        let received = Task { () -> [AudioOutputSnapshot] in
            var snapshots: [AudioOutputSnapshot] = []
            for await snapshot in stream {
                snapshots.append(snapshot)
            }
            return snapshots
        }

        let builtIn = AudioOutputSnapshot(
            sampleRate: 48_000,
            reportedBitDepth: 16,
            diagnosticDescription: "Built-in"
        )
        let usb = AudioOutputSnapshot(sampleRate: 48_000, reportedBitDepth: 24, diagnosticDescription: "USB")
        await monitor.emit(.init(sampleRate: 47_999.999, reportedBitDepth: 16, diagnosticDescription: "Built-in"))
        await waitForSnapshot(service, equalTo: builtIn)
        await monitor.emit(.init(sampleRate: 48_000.001, reportedBitDepth: 16, diagnosticDescription: "Built-in"))
        await monitor.emit(.init(sampleRate: 48_000, reportedBitDepth: 24, diagnosticDescription: "USB"))
        await waitForSnapshot(service, equalTo: usb)
        await service.stopMonitoring()

        let snapshots = try await runUnstructuredWithDeadline(
            .seconds(1),
            label: "normalized output snapshot coalescing",
            onTimeout: { received.cancel() },
            operation: { await received.value }
        )
        #expect(snapshots == [builtIn, usb])
        #expect(AudioOutputCapabilityService.normalizedSampleRateKey(for: builtIn) ==
            AudioOutputCapabilityService.normalizedSampleRateKey(for: usb))
        let differentRate = AudioOutputSnapshot(sampleRate: 44_100, reportedBitDepth: nil, diagnosticDescription: "Different")
        #expect(AudioOutputCapabilityService.normalizedSampleRateKey(for: builtIn) !=
            AudioOutputCapabilityService.normalizedSampleRateKey(for: differentRate))
    }

    @Test
    func capabilityServiceGatesSessionMonitoringAndRequiresReassertionAfterInvalidation() async {
        let monitor = FakeAudioOutputPlatformMonitor(requiresActiveAudioSession: true)
        let service = AudioOutputCapabilityService(platformMonitor: monitor)
        _ = await service.startMonitoring()

        #expect(await monitor.startCount == 0)
        #expect(await service.snapshot().sampleRate == nil)

        await service.setAudioSessionActivationState(.active)
        await monitor.waitForStartCount(1)
        await service.setAudioSessionActivationState(.active)
        #expect(await monitor.startCount == 1)
        #expect(await monitor.stopCount == 1)
        await monitor.emit(.init(sampleRate: 48_000, reportedBitDepth: nil, diagnosticDescription: "Speaker"))
        await waitForSnapshot(service, sampleRate: 48_000)
        await monitor.emit(.init(sampleRate: nil, reportedBitDepth: nil, diagnosticDescription: "Route unavailable"))
        await waitForSnapshot(service, sampleRate: nil)
        #expect(await service.audioSessionActivationState == .active)
        #expect(await monitor.activeListenerCount == 1)

        await monitor.emit(.init(
            sampleRate: nil,
            reportedBitDepth: nil,
            diagnosticDescription: nil,
            requiresActivationReassertion: true
        ))
        await monitor.waitForStopCount(2)
        #expect(await service.audioSessionActivationState == .unknown)
        #expect(await service.snapshot().sampleRate == nil)

        await service.setAudioSessionActivationState(.active)
        await monitor.waitForStartCount(2)
        await service.setAudioSessionActivationState(.inactive)
        #expect(await service.snapshot().sampleRate == nil)
        #expect(await monitor.activeListenerCount == 0)
        await service.stopMonitoring()
    }

    @Test
    func capabilityServiceIgnoresStaleGenerationsAndCleansUpExactlyOnce() async {
        let monitor = FakeAudioOutputPlatformMonitor(requiresActiveAudioSession: true, finishStreamsOnStop: false)
        let service = AudioOutputCapabilityService(platformMonitor: monitor)
        _ = await service.startMonitoring()
        await service.setAudioSessionActivationState(.active)
        await monitor.waitForStartCount(1)
        await monitor.emit(.init(sampleRate: 44_100, reportedBitDepth: nil, diagnosticDescription: "Old"), generation: 0)
        await waitForSnapshot(service, sampleRate: 44_100)

        await service.setAudioSessionActivationState(.inactive)
        await service.setAudioSessionActivationState(.active)
        await monitor.waitForStartCount(2)
        await monitor.emit(.init(sampleRate: 96_000, reportedBitDepth: nil, diagnosticDescription: "Retired"), generation: 0)
        await monitor.emit(.init(sampleRate: 48_000, reportedBitDepth: nil, diagnosticDescription: "Current"), generation: 1)
        await waitForSnapshot(service, sampleRate: 48_000)

        await service.stopMonitoring()
        await service.stopMonitoring()
        await monitor.emit(.init(sampleRate: 96_000, reportedBitDepth: nil, diagnosticDescription: "Stopped"), generation: 1)
        #expect(await service.snapshot().sampleRate == 48_000)
        #expect(await monitor.stopCount == 4)
        #expect(await monitor.activeListenerCount == 0)
    }

    @Test
    func audioQueueInducedTransitionsWaitForStablePostStartObservation() async throws {
        let initial = AudioOutputSnapshot(sampleRate: 44_100, reportedBitDepth: nil, diagnosticDescription: "Initial")
        let monitor = FakeAudioOutputPlatformMonitor()
        let service = AudioOutputCapabilityService(
            initialSnapshot: initial,
            platformMonitor: monitor,
            queueSettleInterval: .milliseconds(30),
            queueMaximumSuppression: .milliseconds(120)
        )
        let stream = await service.startMonitoring()
        await monitor.waitForStartCount(1)
        let received = Task {
            var values: [AudioOutputSnapshot] = []
            for await value in stream {
                values.append(value)
            }
            return values
        }

        await service.audioQueueTransitionWillBegin(sampleRate: 48_000)
        await monitor.emit(.init(sampleRate: 48_000, reportedBitDepth: nil, diagnosticDescription: "Queue transition"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await service.snapshot() == initial)
        await service.audioQueueTransitionDidStart()
        await monitor.emit(.init(sampleRate: 48_000, reportedBitDepth: 24, diagnosticDescription: "Stable"))
        await monitor.emit(.init(sampleRate: 48_000, reportedBitDepth: 24, diagnosticDescription: "Stable"))
        try await Task.sleep(for: .milliseconds(50))

        let stable = AudioOutputSnapshot(sampleRate: 48_000, reportedBitDepth: 24, diagnosticDescription: "Stable")
        #expect(await service.snapshot() == stable)
        await service.stopMonitoring()
        #expect(await received.value == [stable])
    }

    @Test
    func audioQueueSuppressionIsBoundedWhenStartNeverCompletes() async throws {
        let initial = AudioOutputSnapshot(sampleRate: 44_100, reportedBitDepth: nil, diagnosticDescription: "Initial")
        let monitor = FakeAudioOutputPlatformMonitor()
        let service = AudioOutputCapabilityService(
            initialSnapshot: initial,
            platformMonitor: monitor,
            queueSettleInterval: .milliseconds(30),
            queueMaximumSuppression: .milliseconds(60)
        )
        _ = await service.startMonitoring()
        await monitor.waitForStartCount(1)
        await service.audioQueueTransitionWillBegin(sampleRate: 48_000)
        await monitor.emit(.init(sampleRate: 48_000, reportedBitDepth: nil, diagnosticDescription: "Recovered"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await service.snapshot() == initial)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await service.snapshot().sampleRate == 48_000)
        await service.stopMonitoring()
    }

    @Test
    func capabilityServiceStopsAPlatformMonitorWhoseStartCompletesAfterCancellation() async {
        let monitor = BlockingStartAudioOutputPlatformMonitor()
        let service = AudioOutputCapabilityService(platformMonitor: monitor)
        _ = await service.startMonitoring()
        await monitor.waitUntilStartEntered()

        let stopped = Task { await service.stopMonitoring() }
        await monitor.waitUntilStartWasCancelled()
        monitor.releaseStart()
        await stopped.value

        #expect(await monitor.startCount == 1)
        #expect(await monitor.stopCount == 1)
        #expect(await monitor.activeListenerCount == 0)
    }

    private func waitForSnapshot(_ service: AudioOutputCapabilityService, sampleRate: Int?) async {
        while await service.snapshot().sampleRate != sampleRate {
            await Task.yield()
        }
    }

    private func waitForSnapshot(
        _ service: AudioOutputCapabilityService,
        equalTo expected: AudioOutputSnapshot
    ) async {
        while await service.snapshot() != expected {
            await Task.yield()
        }
    }
}

private actor BlockingStartAudioOutputPlatformMonitor: AudioOutputPlatformMonitoring {
    nonisolated let requiresActiveAudioSession = false
    private nonisolated let gate = BlockingStartGate()
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var activeListenerCount = 0

    func startMonitoring() -> AsyncStream<AudioOutputPlatformObservation> {
        startCount += 1
        gate.enterAndWaitForCancellationThenRelease()
        activeListenerCount = 1
        return AsyncStream { _ in }
    }

    func stopMonitoring() {
        stopCount += 1
        activeListenerCount = 0
    }

    nonisolated func waitUntilStartEntered() async {
        while !gate.hasEntered {
            await Task.yield()
        }
    }

    nonisolated func waitUntilStartWasCancelled() async {
        while !gate.hasObservedCancellation {
            await Task.yield()
        }
    }

    nonisolated func releaseStart() {
        gate.release()
    }
}

private final class BlockingStartGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var cancellationObserved = false
    private var released = false

    func enterAndWaitForCancellationThenRelease() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released {
            if Task.isCancelled {
                cancellationObserved = true
                condition.broadcast()
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.01))
        }
        condition.unlock()
    }

    var hasEntered: Bool {
        condition.withLock { entered }
    }

    var hasObservedCancellation: Bool {
        condition.withLock { cancellationObserved }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private actor FakeAudioOutputPlatformMonitor: AudioOutputPlatformMonitoring {
    nonisolated let requiresActiveAudioSession: Bool
    private let finishStreamsOnStop: Bool
    private var continuations: [AsyncStream<AudioOutputPlatformObservation>.Continuation] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var activeListenerCount = 0

    init(requiresActiveAudioSession: Bool = false, finishStreamsOnStop: Bool = true) {
        self.requiresActiveAudioSession = requiresActiveAudioSession
        self.finishStreamsOnStop = finishStreamsOnStop
    }

    func startMonitoring() -> AsyncStream<AudioOutputPlatformObservation> {
        startCount += 1
        activeListenerCount = 1
        let (stream, continuation) = AsyncStream.makeStream(
            of: AudioOutputPlatformObservation.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations.append(continuation)
        return stream
    }

    func stopMonitoring() {
        stopCount += 1
        activeListenerCount = 0
        if finishStreamsOnStop {
            continuations.last?.finish()
        }
    }

    func emit(_ observation: AudioOutputPlatformObservation, generation: Int? = nil) {
        let index = generation ?? continuations.index(before: continuations.endIndex)
        continuations[index].yield(observation)
    }

    func waitForStartCount(_ expected: Int) async {
        while startCount < expected {
            await Task.yield()
        }
    }

    func waitForStopCount(_ expected: Int) async {
        while stopCount < expected {
            await Task.yield()
        }
    }
}
