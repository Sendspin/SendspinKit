import Foundation
@testable import SendspinKit
import Testing

private actor NoiseReadbackRegistry {
    private var servers: [ObjectIdentifier: MockNoiseServer] = [:]

    func insert(_ server: MockNoiseServer, for transport: MockTransport) {
        servers[ObjectIdentifier(transport)] = server
    }

    func messages(for transport: MockTransport) async -> [Data] {
        guard let server = servers[ObjectIdentifier(transport)] else { return [] }
        return await server.sentTextMessages
    }
}

private let noiseReadbackRegistry = NoiseReadbackRegistry()

@MainActor
struct SendspinClientTests {
    @Test
    func clientHelloPreservesSupportedRolePriorityOrder() throws {
        let client = try SendspinClient(
            identity: .generate(),
            name: "Priority Test",
            roles: [.metadataV1, .controllerV1, .metadataV1]
        )

        let payload = client.buildClientHelloPayload(pairingPskEnabled: false)

        #expect(payload.supportedRoles == [.metadataV1, .controllerV1])
    }

    @Test
    func clientHelloPairingMethodUsesLiveRuntimeConfiguration() async throws {
        let pairingPsk = Psk.generate()
        let pairing = PairingConfiguration(pairingPsk: pairingPsk, enabled: true)
        let client = try SendspinClient(
            identity: .generate(),
            name: "Pairing Test",
            roles: [.metadataV1],
            pairing: pairing
        )

        let enabled = await pairing.runtime.snapshot()
        #expect(enabled.pairingPskEnabled)
        #expect(client.buildClientHelloPayload(pairingPskEnabled: enabled.pairingPskEnabled)
            .supportedPairMethods.map(\.method) == [PairMethod.pairingPsk])

        let longTermPsk = Psk.generate()
        try await pairing.store.insert(PairingRecord(psk: longTermPsk, serverId: "server"))
        await pairing.runtime.update(PairingManagementConfiguration(
            pairingPsk: pairingPsk,
            pairingPskEnabled: false,
            recordModePskId: pairing.recordModePskId,
            unpairedAccessEnabled: enabled.unpairedAccessEnabled
        ))
        let disabled = await pairing.runtime.snapshot()
        #expect(!disabled.pairingPskEnabled)
        #expect(client.buildClientHelloPayload(pairingPskEnabled: disabled.pairingPskEnabled)
            .supportedPairMethods.isEmpty)

        let candidates = await PairingCandidateBuilder.candidates(configuration: pairing)
        #expect(candidates.contains(where: { $0.category == .pairing }) == false)
        #expect(candidates.contains(where: { $0.psk == longTermPsk && $0.category == .longTerm }))
    }

    @Test
    func colorRoleIsAdvertisedWithoutASupportObject() throws {
        let client = try SendspinClient(
            identity: .generate(),
            name: "Color Test",
            roles: [.colorV1]
        )

        let payload = client.buildClientHelloPayload(pairingPskEnabled: false)

        #expect(payload.supportedRoles == [.colorV1])
        #expect(payload.visualizerV1Support == nil)
    }

    @Test
    func clientHelloUsesConfiguredDeviceInfo() throws {
        let deviceInfo = DeviceInfo(
            productName: "Host Product",
            manufacturer: "Host Manufacturer",
            softwareVersion: "1.2.3",
            macAddress: "aa:bb:cc:dd:ee:ff"
        )
        let client = try SendspinClient(
            identity: .generate(),
            name: "Device Info Test",
            roles: [.metadataV1],
            deviceInfo: deviceInfo
        )

        let payload = client.buildClientHelloPayload(pairingPskEnabled: false)

        #expect(payload.deviceInfo == deviceInfo)
    }

    @Test
    func initializeClientWithPlayerRole() throws {
        let config = try PlayerConfiguration(
            bufferCapacity: 1_024,
            supportedFormats: [
                AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
            ]
        )

        let client = try SendspinClient(
            identity: .generate(),
            name: "Test Client",
            roles: [.playerV1],
            playerConfig: config,
            audioOutputCapabilityProvider: makeInertAudioOutputCapabilityProvider()
        )

        #expect(client.connectionState == .disconnected)
    }

    @Test
    func enterExternalSource_throwsNotConnectedWhenDisconnected() async throws {
        let client = try SendspinClient(
            identity: .generate(),
            name: "Test Client",
            roles: [.playerV1],
            playerConfig: PlayerConfiguration(
                bufferCapacity: 1_024,
                supportedFormats: [
                    AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
                ]
            ),
            audioOutputCapabilityProvider: makeInertAudioOutputCapabilityProvider()
        )

        await #expect(throws: SendspinClientError.notConnected) {
            try await client.enterExternalSource()
        }
    }

    @Test
    func exitExternalSource_throwsNotConnectedWhenDisconnected() async throws {
        let client = try SendspinClient(
            identity: .generate(),
            name: "Test Client",
            roles: [.playerV1],
            playerConfig: PlayerConfiguration(
                bufferCapacity: 1_024,
                supportedFormats: [
                    AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
                ]
            ),
            audioOutputCapabilityProvider: makeInertAudioOutputCapabilityProvider()
        )

        await #expect(throws: SendspinClientError.notConnected) {
            try await client.exitExternalSource()
        }
    }

    @Test
    func failedConnectRollsBackToDisconnectedAndAllowsReconnect() async throws {
        let client = try SendspinClient(
            identity: .generate(),
            name: "Test Client",
            roles: [.metadataV1]
        )
        let failingURL = try #require(URL(string: "ws://127.0.0.1:1/sendspin"))

        let result = await outcomeOfUnstructuredOperation(
            timeout: .seconds(2),
            onTimeout: { await client.disconnect() },
            operation: { try await client.connect(to: failingURL) }
        )

        switch result {
        case nil:
            Issue.record("connect(to:) timed out instead of failing promptly")
        case .success:
            Issue.record("connect(to:) unexpectedly succeeded against a closed localhost port")
        case .failure:
            break
        }

        #expect(client.connectionState == .disconnected)
        #expect(client.connection == nil)

        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport, psk: .sentinel)
        async let accepted: Void = client.acceptConnection(transport)
        try await server.establishSession(activeRoles: [.playerV1])
        try await accepted
        await noiseReadbackRegistry.insert(server, for: transport)
        #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })

        await client.disconnect()
    }

    @Test
    func alreadyConnectedErrorHasCorrectDescription() {
        let error = SendspinClientError.alreadyConnected
        #expect(error.errorDescription == "Already connected or connecting to a Sendspin server")
    }

    @Test
    func sendFailedErrorIncludesReason() {
        let error = SendspinClientError.sendFailed("connection reset")
        #expect(error.errorDescription == "Failed to send message: connection reset")
    }

    @Test
    func resolveServerURLUsesExplicitURLAndValidatesInputs() async throws {
        let url = try await SendspinClient.resolveServerURL(server: "ws://127.0.0.1:8927/sendspin", discover: false)
        #expect(url.absoluteString == "ws://127.0.0.1:8927/sendspin")

        await #expect(throws: SendspinClientError.invalidServerURL("not a url")) {
            try await SendspinClient.resolveServerURL(server: "not a url", discover: false)
        }
        await #expect(throws: SendspinClientError.serverURLRequired) {
            try await SendspinClient.resolveServerURL(server: nil, discover: false)
        }
    }

    @Test
    func audioSchedulerIsClearedOnDisconnect() async throws {
        let config = try PlayerConfiguration(
            bufferCapacity: 1_024,
            supportedFormats: [
                AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
            ]
        )

        let client = try SendspinClient(
            identity: .generate(),
            name: "Test Client",
            roles: [.playerV1],
            playerConfig: config,
            audioOutputCapabilityProvider: makeInertAudioOutputCapabilityProvider()
        )

        // Disconnect should clean up all resources including scheduler
        await client.disconnect()

        // After disconnect, state should be disconnected
        #expect(client.connectionState == .disconnected)
    }

    @Test
    func closeBeforeConnectIsPermanentAndFinishesEveryStream() async throws {
        let client = try makePlayerClient(capabilityProvider: FakeAudioOutputCapabilityProvider())
        let events = client.events()
        let audio = client.audioChunks
        let artwork = client.artwork
        let visualizer = client.visualizerData

        async let firstClose: Void = client.close()
        async let secondClose: Void = client.close()
        _ = await (firstClose, secondClose)

        #expect(client.connectionState == .disconnected)
        #expect(client.currentAudioOutput == nil)
        #expect(client.currentOutputFormatStatus == nil)
        #expect(await streamFinishes(events))
        #expect(await streamFinishes(audio))
        #expect(await streamFinishes(artwork))
        #expect(await streamFinishes(visualizer))
        #expect(await streamFinishes(client.events()))

        await #expect(throws: TerminatedError.self) {
            try await client.acceptConnection(MockTransport())
        }
        await #expect(throws: TerminatedError.self) {
            try await client.requestPlayerFormat(sampleRate: 48_000)
        }
        await #expect(throws: TerminatedError.self) {
            try await client.setAudioSessionActivationState(AudioSessionActivationState.active)
        }
    }

    @Test
    func closeWhileConnectedSendsShutdownGoodbyeBeforeCompletingTeardown() async throws {
        let provider = FakeAudioOutputCapabilityProvider()
        let client = try makePlayerClient(capabilityProvider: provider)
        let transport = MockTransport()
        let events = client.events()
        let audio = client.audioChunks
        let artwork = client.artwork
        let visualizer = client.visualizerData
        let collectedEvents = Task { @MainActor in
            var values: [ClientEvent] = []
            for await event in events {
                values.append(event)
            }
            return values
        }
        let server = MockNoiseServer(transport: transport, psk: .sentinel)
        async let accepted: Void = client.acceptConnection(transport)
        try await server.establishSession(activeRoles: [.playerV1])
        try await accepted
        await noiseReadbackRegistry.insert(server, for: transport)
        #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })

        await provider.publish(output(48_000, "Retained"))
        #expect(await waitUntil { await MainActor.run { client.currentAudioOutput?.sampleRate == 48_000 } })
        let closing = Task { @MainActor in await client.close() }
        await closing.value
        await provider.publish(output(44_100, "Stale"))

        let goodbyeReasons = await sentGoodbyeReasons(from: transport)
        #expect(goodbyeReasons == [.shutdown])
        #expect(await transport.disconnectCallCount >= 1)
        #expect(client.connection == nil)
        #expect(client.currentAudioOutput == nil)
        #expect(client.currentOutputFormatStatus == nil)
        let closedEvents = await collectedEvents.value
        #expect(!closedEvents.contains {
            if case .disconnected = $0 {
                true
            } else {
                false
            }
        })
        #expect(await streamFinishes(audio))
        #expect(await streamFinishes(artwork))
        #expect(await streamFinishes(visualizer))
        #expect(await provider.stopCount == 1)
    }

    @Test
    func closeDuringConnectNegotiationThrowsTerminatedError() async throws {
        let transport = MockTransport()
        let negotiationGate = AsyncGate()
        let client = try SendspinClient(
            identity: .generate(),
            name: "Close During Connect",
            roles: [.metadataV1],
            audioOutputCapabilityProvider: FakeAudioOutputCapabilityProvider(),
            outboundTransportFactory: { _ in transport },
            sessionNegotiationHook: { await negotiationGate.wait() }
        )
        let url = try #require(URL(string: "ws://unused.invalid/sendspin"))
        let connecting = Task { @MainActor in
            try await client.connect(to: url)
        }

        #expect(await waitUntil { await negotiationGate.isWaiting })
        await client.close()
        await negotiationGate.release()
        let result = await outcomeOfUnstructuredOperation(
            timeout: .seconds(1),
            onTimeout: { connecting.cancel() },
            operation: { try await connecting.value }
        )

        guard let result else {
            Issue.record("connect(to:) did not finish after negotiation resumed")
            return
        }
        switch result {
        case .success:
            Issue.record("connect(to:) returned success after close() terminated the client")
        case let .failure(error):
            #expect(error is TerminatedError)
        }
        #expect(await transport.disconnectCalled)
        #expect(client.connection == nil)
    }

    @Test
    func closeDuringCompetingHandshakeReleasesEveryTransport() async throws {
        let client = try makePlayerClient(capabilityProvider: FakeAudioOutputCapabilityProvider())
        let incumbent = MockTransport()
        let incumbentServer = MockNoiseServer(transport: incumbent, psk: .sentinel)
        async let incumbentAccepted: Void = client.acceptConnection(incumbent)
        try await incumbentServer.establishSession(activities: [.playback], activeRoles: [.playerV1])
        try await incumbentAccepted
        #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })

        let candidate = MockTransport()
        let server = MockNoiseServer(transport: candidate, psk: .sentinel)
        let accepting = Task { @MainActor in
            try await client.acceptConnection(candidate)
        }
        #expect(await waitUntil { await candidate.hasSentFrames })
        try await server.respondToHandshake()
        await client.close()
        let result = await outcomeOfUnstructuredOperation(
            timeout: .seconds(1),
            operation: { try await accepting.value }
        )

        #expect(result != nil)
        #expect(await incumbent.disconnectCalled)
        #expect(await candidate.disconnectCalled)
        #expect(client.connection == nil)
    }

    @Test
    func disconnectStillAllowsReconnectAndKeepsClientStreamsOpen() async throws {
        let client = try makePlayerClient(capabilityProvider: FakeAudioOutputCapabilityProvider())
        let first = MockTransport()
        let firstServer = MockNoiseServer(transport: first, psk: .sentinel)
        async let firstAccepted: Void = client.acceptConnection(first)
        try await firstServer.establishSession(activities: [.playback], activeRoles: [.playerV1])
        try await firstAccepted
        #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })
        await client.disconnect()

        let second = MockTransport()
        let secondServer = MockNoiseServer(transport: second, psk: .sentinel)
        async let secondAccepted: Void = client.acceptConnection(second)
        try await secondServer.establishSession(activities: [.playback], activeRoles: [.playerV1])
        try await secondAccepted
        #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })
        #expect(!client.isTerminated)
        await client.close()
    }

    @Test
    func outputRetainedStateIsAppliedBeforeMatchingEvents() async throws {
        let provider = FakeAudioOutputCapabilityProvider()
        let client = try makePlayerClient(capabilityProvider: provider)
        let output = AudioOutputSnapshot(
            sampleRate: 48_000,
            reportedBitDepth: 24,
            diagnosticDescription: "Test Output"
        )
        let stream = client.events()
        #expect(await waitUntil { await provider.monitoringStarted })

        let observed = Task { @MainActor in
            for await event in stream {
                guard case .audioOutputChanged(output) = event else { continue }
                return client.currentAudioOutput == output
            }
            return false
        }

        await provider.publish(output)

        let result = await outcomeOfUnstructuredOperation(
            timeout: .seconds(2),
            onTimeout: { observed.cancel() },
            operation: { await observed.value }
        )
        #expect(try result?.get() == true)
        await client.finishAudioOutputCapabilityMonitoring()
    }

    @Test
    func disconnectResetsSessionStatusButPreservesAudioOutput() async throws {
        let provider = FakeAudioOutputCapabilityProvider()
        let client = try makePlayerClient(capabilityProvider: provider)
        let output = AudioOutputSnapshot(
            sampleRate: 44_100,
            reportedBitDepth: 16,
            diagnosticDescription: "Persistent Output"
        )
        #expect(await waitUntil { await provider.monitoringStarted })
        await provider.publish(output)
        let applied = await outcomeOfUnstructuredOperation(
            timeout: .seconds(2),
            operation: { @MainActor in
                while client.currentAudioOutput != output {
                    await Task.yield()
                }
                return true
            }
        )
        #expect(try applied?.get() == true)

        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport, psk: .sentinel)
        async let accepted: Void = client.acceptConnection(transport)
        try await server.establishSession(activities: [.playback], activeRoles: [.playerV1])
        try await accepted
        await client.disconnect(reason: .userRequest)

        #expect(client.currentAudioOutput == output)
        #expect(client.currentOutputFormatStatus == nil)
        await client.finishAudioOutputCapabilityMonitoring()
    }

    @Test
    func activationStateIsForwardedBeforeAsyncAPIReturns() async throws {
        let provider = FakeAudioOutputCapabilityProvider()
        let client = try makePlayerClient(capabilityProvider: provider)

        try await client.setAudioSessionActivationState(.active)

        #expect(await provider.activationState == .active)
        await client.finishAudioOutputCapabilityMonitoring()
    }

    @Test
    func newClientEventsUsePayloadEqualityAndRemainDistinct() {
        let output = AudioOutputSnapshot(
            sampleRate: 48_000,
            reportedBitDepth: 24,
            diagnosticDescription: "Equality Output"
        )
        let status = OutputFormatStatus(output: output, state: .outputUnknown)
        let failure = StreamingError.audioStartFailed("test failure")

        #expect(ClientEvent.audioOutputChanged(output) == .audioOutputChanged(output))
        #expect(ClientEvent.outputFormatStatusChanged(status) == .outputFormatStatusChanged(status))
        #expect(ClientEvent.streamingFailed(failure) == .streamingFailed(failure))
        #expect(ClientEvent.audioOutputChanged(output) != .outputFormatStatusChanged(status))
        #expect(ClientEvent.outputFormatStatusChanged(status) != .streamingFailed(failure))
    }

    @Test
    func helloUsesOneSnapshotAndPolicyAppliedOrderingThenResetsCatalog() async throws {
        let formats = try [
            AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16),
            AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 24),
            AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16),
            AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 96_000, bitDepth: 24)
        ]
        let expected = [formats[1], formats[2], formats[0], formats[3]]
        let provider = FakeAudioOutputCapabilityProvider(initialSnapshot: AudioOutputSnapshot(
            sampleRate: 48_000,
            reportedBitDepth: nil,
            diagnosticDescription: "Native output"
        ))
        let client = try makePlayerClient(
            formats: formats,
            policy: .preferCurrentOutput,
            capabilityProvider: provider
        )
        #expect(await waitUntil { await provider.monitoringStarted })
        let baselineSnapshots = await provider.snapshotCount
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport, psk: .sentinel)
        async let accepted: Void = client.acceptConnection(transport)
        try await server.respondToHandshake()
        try await server.sendJSON(#"{"type":"server/hello","payload":{"name":"Output Capability Test"}}"#)
        let helloData = try await server.nextClientJSON()
        let hello = try JSONDecoder().decode(ClientHelloMessage.self, from: helloData)
        try await server.sendJSON(#"{"type":"server/activate","payload":{"activities":[],"active_roles":["player@v1"]}}"#)
        try await accepted

        #expect(hello.payload.playerV1Support?.supportedFormats == expected)
        #expect(client.effectivePlayerFormats == expected)
        #expect(client.connection?.effectivePlayerFormats == expected)
        #expect(await provider.snapshotCount == baselineSnapshots + 1)

        await client.disconnect()
        #expect(client.effectivePlayerFormats == nil)
        await client.finishAudioOutputCapabilityMonitoring()
    }

    @Test(arguments: [
        AudioOutputSnapshot(sampleRate: nil, reportedBitDepth: nil, diagnosticDescription: "Unknown"),
        AudioOutputSnapshot(sampleRate: 96_000, reportedBitDepth: nil, diagnosticDescription: "No match")
    ])
    func strictHandshakeFailsBeforeHello(snapshot: AudioOutputSnapshot) async throws {
        let provider = FakeAudioOutputCapabilityProvider(initialSnapshot: snapshot)
        let client = try makePlayerClient(policy: .requireCurrentOutput, capabilityProvider: provider)
        let transport = MockTransport()

        if snapshot.sampleRate == nil {
            await #expect(throws: OutputFormatError.routeUnavailable) {
                try await client.acceptConnection(transport)
            }
        } else {
            await #expect(throws: OutputFormatError.noMatchingFormat) {
                try await client.acceptConnection(transport)
            }
        }

        #expect(await transport.sentTextMessages.isEmpty)
        #expect(await transport.disconnectCalled)
        #expect(client.connectionState == .disconnected)
        #expect(client.connection == nil)
        #expect(client.effectivePlayerFormats == nil)
        await client.finishAudioOutputCapabilityMonitoring()
    }

    @Test
    func strictCandidateFailureUsesOneSnapshotAndPreservesIncumbent() async throws {
        let provider = FakeAudioOutputCapabilityProvider(initialSnapshot: AudioOutputSnapshot(
            sampleRate: 48_000,
            reportedBitDepth: nil,
            diagnosticDescription: "Initial output"
        ))
        let client = try makePlayerClient(policy: .requireCurrentOutput, capabilityProvider: provider)
        let incumbent = MockTransport()
        let incumbentServer = MockNoiseServer(transport: incumbent, psk: .sentinel)
        async let incumbentAccepted: Void = client.acceptConnection(incumbent)
        try await incumbentServer.establishSession(activities: [.playback], activeRoles: [.playerV1])
        try await incumbentAccepted
        #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })

        await provider.publish(AudioOutputSnapshot(
            sampleRate: nil,
            reportedBitDepth: nil,
            diagnosticDescription: "Route unavailable"
        ))
        let baselineSnapshots = await provider.snapshotCount
        let candidate = MockTransport()
        await #expect(throws: OutputFormatError.routeUnavailable) {
            try await client.acceptConnection(candidate)
        }

        #expect(await provider.snapshotCount == baselineSnapshots + 1)
        #expect(await candidate.sentTextMessages.isEmpty)
        #expect(await waitUntil { await candidate.disconnectCalled })
        #expect(await !incumbent.disconnectCalled)
        #expect(client.connectionState == .connected)
        #expect(client.connection?.effectivePlayerFormats == client.effectivePlayerFormats)

        await client.disconnect()
        await client.finishAudioOutputCapabilityMonitoring()
    }

    @Test
    func strictStreamMismatchFailsBeforeEngineAndDisconnectsInOrder() async throws {
        let provider = FakeAudioOutputCapabilityProvider(initialSnapshot: AudioOutputSnapshot(
            sampleRate: 48_000,
            reportedBitDepth: nil,
            diagnosticDescription: "Strict output"
        ))
        let client = try makePlayerClient(policy: .requireCurrentOutput, capabilityProvider: provider)
        let transport = MockTransport()
        let events = client.events()
        let server = MockNoiseServer(transport: transport, psk: .sentinel)
        async let accepted: Void = client.acceptConnection(transport)
        try await server.establishSession(activeRoles: [.playerV1])
        try await accepted
        await transport.installEncryptedTextSender(server.encryptedTextSender())
        await transport.installEncryptedBinarySender(server.encryptedBinarySender())
        await noiseReadbackRegistry.insert(server, for: transport)
        #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })
        let engine = try #require(client.connection?.audioEngineForTesting)
        let collector = Task { () -> [ClientEvent] in
            var collected: [ClientEvent] = []
            for await event in events {
                collected.append(event)
                if case .disconnected = event {
                    break
                }
            }
            return collected
        }

        let mismatchedStart = StreamStartMessage(payload: StreamStartPayload(
            player: StreamStartPlayer(
                codec: AudioCodec.pcm.rawValue,
                sampleRate: 44_100,
                channels: 2,
                bitDepth: 16,
                codecHeader: nil
            ),
            artwork: nil,
            visualizer: nil
        ))
        let mismatchedJSON = try #require(String(
            data: JSONEncoder().encode(mismatchedStart),
            encoding: .utf8
        ))
        await transport.injectText(mismatchedJSON)
        let result = await outcomeOfUnstructuredOperation(
            timeout: .seconds(3),
            onTimeout: { collector.cancel() },
            operation: { await collector.value }
        )
        let collected = try #require(try result?.get())
        let failureIndex = try #require(collected.firstIndex(of: .streamingFailed(.outputFormat(.noMatchingFormat))))
        let disconnectIndex = try #require(collected.firstIndex(of: .disconnected(
            reason: .outputFormatRejected(.noMatchingFormat)
        )))

        #expect(failureIndex < disconnectIndex)
        #expect(await !engine.appliedCommandKinds().contains(.streamStart))
        #expect(client.connectionState == .disconnected)
        await client.finishAudioOutputCapabilityMonitoring()
    }

    @Test
    func outputFormatStatusIsAppliedBeforeItsEvent() async throws {
        let native = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let output = AudioOutputSnapshot(sampleRate: 48_000, reportedBitDepth: nil, diagnosticDescription: "Native")
        let provider = FakeAudioOutputCapabilityProvider(initialSnapshot: output)
        let client = try makePlayerClient(formats: [native], capabilityProvider: provider)
        _ = try await connectOutputClient(client)
        let events = client.events()
        let observed = Task { @MainActor in
            for await event in events {
                guard case let .outputFormatStatusChanged(status) = event,
                      status.state == .preferred(native)
                else { continue }
                return client.currentOutputFormatStatus == status
            }
            return false
        }
        await Task.yield()
        await provider.publish(AudioOutputSnapshot(
            sampleRate: 48_000,
            reportedBitDepth: nil,
            diagnosticDescription: "Native refreshed"
        ))

        let observation = await observeTask(observed, timeout: .seconds(2))
        guard case let .completed(appliedBeforeEvent) = observation else {
            Issue.record("status event did not arrive")
            return
        }
        #expect(appliedBeforeEvent)
        await client.disconnect()
        await client.finishAudioOutputCapabilityMonitoring()
    }

    @Test
    func routeNegotiationCoalescesByRateAndSendsOneCompleteTuple() async throws {
        let fallback = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
        let native = try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 24)
        let provider = FakeAudioOutputCapabilityProvider(initialSnapshot: output(44_100, "Initial"))
        let client = try makePlayerClient(formats: [fallback, native], capabilityProvider: provider, settle: .zero)
        let transport = try await connectOutputClient(client)
        try await transport.injectText(streamStartJSON(fallback))
        #expect(await waitUntil { await client.connection?.announcedPlayerStream?.format == fallback })

        await provider.publish(output(48_000, "USB A", bitDepth: 16))
        await provider.publish(output(48_000, "USB B", bitDepth: 32))
        #expect(await waitUntil { await requestFormats(transport).count == 1 })
        let request = try #require(await requestFormats(transport).first?.payload.player)
        #expect(request.codec == native.codec)
        #expect(request.channels == native.channels)
        #expect(request.sampleRate == native.sampleRate)
        #expect(request.bitDepth == native.bitDepth)
        #expect(client.currentOutputFormatStatus?.state == .requesting(native))

        await provider.publish(output(48_000, "USB C", bitDepth: 24))
        let duplicate = await waitUntil(timeout: .milliseconds(200)) { await requestFormats(transport).count > 1 }
        #expect(!duplicate)
        await client.disconnect()
        await client.finishAudioOutputCapabilityMonitoring()
    }

    @Test
    func outOfOrderOutputSnapshotsCannotReplaceTheLatestSequence() async throws {
        let initial = output(44_100, "Initial")
        let latest = output(48_000, "Latest")
        let stale = output(44_100, "Stale")
        let provider = FakeAudioOutputCapabilityProvider(initialSnapshot: initial)
        let client = try makePlayerClient(capabilityProvider: provider, settle: .zero)
        _ = try await connectOutputClient(client)
        let connection = try #require(client.connection)
        let seed = await connection.latestOutputSnapshotSequence

        await connection.receiveAudioOutputSnapshot(latest, sequence: seed + 2)
        await connection.receiveAudioOutputSnapshot(stale, sequence: seed + 1)

        #expect(await connection.outputSnapshot == latest)
        #expect(await connection.latestOutputSnapshotSequence == seed + 2)
        await client.disconnect()
        await client.finishAudioOutputCapabilityMonitoring()
    }

    @Test
    func automaticRequestMatchingAndFallbackResponsesAreTruthfulAndOneShot() async throws {
        let fallback = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
        let native = try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 24)
        let provider = FakeAudioOutputCapabilityProvider(initialSnapshot: output(44_100, "Initial"))
        let client = try makePlayerClient(formats: [fallback, native], capabilityProvider: provider, settle: .zero)
        let transport = try await connectOutputClient(client)
        try await transport.injectText(streamStartJSON(fallback))
        #expect(await waitUntil { await client.connection?.announcedPlayerStream?.format == fallback })
        await provider.publish(output(48_000, "New route"))
        #expect(await waitUntil { await requestFormats(transport).count == 1 })

        try await transport.injectText(streamStartJSON(native))
        #expect(await waitUntil { await MainActor.run { client.currentOutputFormatStatus?.state == .activeNative(native) } })

        await provider.publish(output(44_100, "Back"))
        #expect(await waitUntil { await requestFormats(transport).count == 2 })
        try await transport.injectText(streamStartJSON(native))
        #expect(await waitUntil { await MainActor.run { client.currentOutputFormatStatus?.state == .activeFallback(native) } })
        let retried = await waitUntil(timeout: .milliseconds(200)) { await requestFormats(transport).count > 2 }
        #expect(!retried)
        await client.disconnect()
        await client.finishAudioOutputCapabilityMonitoring()
    }

    @Test
    func automaticRequestTimeoutPublishesFallbackWithoutRetry() async throws {
        let fallback = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
        let native = try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 24)
        let provider = FakeAudioOutputCapabilityProvider(initialSnapshot: output(44_100, "Initial"))
        let client = try makePlayerClient(
            formats: [fallback, native],
            capabilityProvider: provider,
            settle: .zero,
            requestTimeout: .zero
        )
        let transport = try await connectOutputClient(client)
        try await transport.injectText(streamStartJSON(fallback))
        #expect(await waitUntil { await client.connection?.announcedPlayerStream?.format == fallback })
        await provider.publish(output(48_000, "New route"))

        #expect(await waitUntil { await requestFormats(transport).count == 1 })
        #expect(await waitUntil { await MainActor.run { client.currentOutputFormatStatus?.state == .activeFallback(fallback) } })
        let retried = await waitUntil(timeout: .milliseconds(200)) { await requestFormats(transport).count > 1 }
        #expect(!retried)
        await client.disconnect()
        await client.finishAudioOutputCapabilityMonitoring()
    }

    @Test
    func applicationRequestSupersedesAutomaticAndSuppressesUntilBoundary() async throws {
        let initial = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
        let automatic = try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 24)
        let application = try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let provider = FakeAudioOutputCapabilityProvider(initialSnapshot: output(44_100, "Initial"))
        let client = try makePlayerClient(
            formats: [initial, automatic, application],
            capabilityProvider: provider,
            settle: .zero
        )
        let transport = try await connectOutputClient(client)
        try await transport.injectText(streamStartJSON(initial))
        #expect(await waitUntil { await client.connection?.announcedPlayerStream?.format == initial })
        await provider.publish(output(48_000, "Route A"))
        #expect(await waitUntil { await requestFormats(transport).count == 1 })

        try await client.requestPlayerFormat(application)
        #expect(await waitUntil { await requestFormats(transport).count == 2 })
        #expect(client.currentOutputFormatStatus?.state == .requesting(application))
        await provider.publish(output(44_100, "Route B"))
        await provider.publish(output(48_000, "Route C"))
        #expect(await waitUntil { await client.connection?.settledOutputSampleRate == 48_000 })
        #expect(await client.connection?.automaticRequestsSuppressed == true)
        #expect(await client.connection?.pendingOutputFormatRequest?.origin == .application)
        #expect(await requestFormats(transport).count == 2)

        try await transport.injectText(streamEndJSON())
        try await transport.injectText(streamStartJSON(initial))
        #expect(await waitUntil { await client.connection?.announcedPlayerStream?.format == initial })
        #expect(await waitUntil { await client.connection?.automaticRequestsSuppressed == false })
        await provider.publish(output(44_100, "Boundary route"))
        #expect(await waitUntil { await requestFormats(transport).count == 3 })
        await client.disconnect()
        await client.finishAudioOutputCapabilityMonitoring()
    }

    @Test
    func failedApplicationRequestRestoresAutomaticNegotiation() async throws {
        let initial = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
        let automatic = try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 24)
        let application = try AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let provider = FakeAudioOutputCapabilityProvider(initialSnapshot: output(44_100, "Initial"))
        let client = try makePlayerClient(
            formats: [initial, automatic, application],
            capabilityProvider: provider,
            settle: .milliseconds(50)
        )
        let transport = try await connectOutputClient(client)
        try await transport.injectText(streamStartJSON(initial))
        #expect(await waitUntil { await client.connection?.announcedPlayerStream?.format == initial })
        #expect(await waitUntil { await client.connection?.playerStreamActive == true })
        await provider.publish(output(48_000, "Automatic route"))
        #expect(await waitUntil { await client.connection?.outputSnapshot?.sampleRate == 48_000 })
        await transport.setShouldFailOnSend(true)

        await #expect(throws: SendspinClientError.self) {
            try await client.requestPlayerFormat(application)
        }
        // The failed request rolls back its optimistic negotiation state...
        #expect(await client.connection?.automaticRequestsSuppressed ?? false == false)
        #expect(await client.connection?.pendingOutputFormatRequest == nil)

        // ...and the session ends: the failed send already consumed AEAD nonces,
        // so no later frame could decrypt at the server. Retrying on the same
        // connection is impossible by construction under Noise.
        #expect(await waitUntil { await MainActor.run { client.connectionState == .disconnected } })
        #expect(await transport.disconnectCalled)
        await client.finishAudioOutputCapabilityMonitoring()
    }

    @Test
    func preservePolicyPublishesFallbackButNeverRequests() async throws {
        let streamFormat = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)
        let native = try AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 24)
        let provider = FakeAudioOutputCapabilityProvider(initialSnapshot: output(44_100, "Initial"))
        let client = try makePlayerClient(
            formats: [streamFormat, native],
            policy: .preserveFormatOrder,
            capabilityProvider: provider,
            settle: .zero
        )
        let transport = try await connectOutputClient(client)
        try await transport.injectText(streamStartJSON(streamFormat))
        #expect(await waitUntil { await client.connection?.announcedPlayerStream?.format == streamFormat })
        await provider.publish(output(48_000, "New route"))

        #expect(await waitUntil { await MainActor.run { client.currentOutputFormatStatus?.state == .activeFallback(streamFormat) } })
        #expect(await requestFormats(transport).isEmpty)
        await client.disconnect()
        await client.finishAudioOutputCapabilityMonitoring()
    }

    @Test
    func strictStreamStartUsesSettledRouteDuringSettleWindow() async throws {
        let native = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let provider = FakeAudioOutputCapabilityProvider(initialSnapshot: output(48_000, "Initial"))
        let client = try makePlayerClient(
            formats: [native],
            policy: .requireCurrentOutput,
            capabilityProvider: provider,
            settle: .seconds(10)
        )
        let transport = try await connectOutputClient(client)
        let connection = try #require(client.connection)
        let sequence = await connection.latestOutputSnapshotSequence
        await connection.receiveAudioOutputSnapshot(output(44_100, "Unsettled"), sequence: sequence + 1)

        try await transport.injectText(streamStartJSON(native))

        #expect(await waitUntil { await connection.announcedPlayerStream?.format == native })
        #expect(await transport.isConnected)
        await client.disconnect()
        await client.finishAudioOutputCapabilityMonitoring()
    }

    @Test
    func strictRouteChangeWithoutTargetUsesTypedTerminalFailure() async throws {
        let native = try AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        let provider = FakeAudioOutputCapabilityProvider(initialSnapshot: output(48_000, "Initial"))
        let client = try makePlayerClient(
            formats: [native],
            policy: .requireCurrentOutput,
            capabilityProvider: provider,
            settle: .zero
        )
        let events = client.events()
        let transport = try await connectOutputClient(client)
        try await transport.injectText(streamStartJSON(native))
        #expect(await waitUntil { await client.connection?.announcedPlayerStream?.format == native })
        let terminal = Task {
            var values: [ClientEvent] = []
            for await event in events {
                values.append(event)
                if case .disconnected = event {
                    return values
                }
            }
            return values
        }
        await provider.publish(output(44_100, "Unsupported"))
        let result = await observeTask(terminal, timeout: .seconds(2), onTimeout: { terminal.cancel() })
        guard case let .completed(values) = result else {
            Issue.record("strict route failure did not terminate")
            return
        }
        let expectedFailure = ClientEvent.streamingFailed(StreamingError.outputFormat(OutputFormatError.noMatchingFormat))
        let expectedDisconnect = ClientEvent.disconnected(
            reason: DisconnectReason.outputFormatRejected(OutputFormatError.noMatchingFormat)
        )
        let failure = try #require(values.firstIndex(of: expectedFailure))
        let disconnected = try #require(values.firstIndex(of: expectedDisconnect))
        #expect(failure < disconnected)
        await client.finishAudioOutputCapabilityMonitoring()
    }

    private func makePlayerClient(
        formats: [AudioFormatSpec]? = nil,
        policy: OutputSampleRatePolicy = .preferCurrentOutput,
        capabilityProvider: any AudioOutputCapabilityProviding,
        settle: Duration = .milliseconds(250),
        requestTimeout: Duration = .seconds(3)
    ) throws -> SendspinClient {
        let formats = try formats ?? [
            AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16)
        ]
        return try SendspinClient(
            identity: .generate(),
            name: "Output Capability Test",
            roles: [.playerV1],
            playerConfig: PlayerConfiguration(
                bufferCapacity: 1_024,
                supportedFormats: formats,
                outputSampleRatePolicy: policy
            ),
            audioOutputCapabilityProvider: capabilityProvider,
            outputSettleInterval: settle,
            outputRequestTimeout: requestTimeout
        )
    }

    private func connectOutputClient(_ client: SendspinClient) async throws -> MockTransport {
        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport, psk: .sentinel)
        async let accepted: Void = client.acceptConnection(transport)
        try await server.establishSession(activities: [.playback], activeRoles: [.playerV1])
        try await accepted
        #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })
        // The server's readback task retains it; the transport's encrypted-sender
        // shims carry the channel. No further anchoring needed.
        await transport.installEncryptedTextSender(server.encryptedTextSender())
        await transport.installEncryptedBinarySender(server.encryptedBinarySender())
        await noiseReadbackRegistry.insert(server, for: transport)
        return transport
    }

    private func output(_ rate: Int, _ description: String, bitDepth: Int? = nil) -> AudioOutputSnapshot {
        AudioOutputSnapshot(sampleRate: rate, reportedBitDepth: bitDepth, diagnosticDescription: description)
    }

    private func streamStartJSON(_ format: AudioFormatSpec) throws -> String {
        let message = StreamStartMessage(payload: StreamStartPayload(
            player: StreamStartPlayer(
                codec: format.codec.rawValue,
                sampleRate: format.sampleRate,
                channels: format.channels,
                bitDepth: format.bitDepth,
                codecHeader: nil
            ),
            artwork: nil,
            visualizer: nil
        ))
        return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
    }

    private func streamEndJSON() throws -> String {
        let message = StreamEndMessage(payload: StreamEndPayload(roles: [StreamRole.player.rawValue]))
        return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
    }

    private func requestFormats(_ transport: MockTransport) async -> [StreamRequestFormatMessage] {
        let messages = await noiseReadbackRegistry.messages(for: transport)
        return messages.compactMap { data in
            guard SendspinEncoding.messageType(of: data) == StreamRequestFormatMessage.typeString else { return nil }
            return try? JSONDecoder().decode(StreamRequestFormatMessage.self, from: data)
        }
    }

    private func sentGoodbyeReasons(from transport: MockTransport) async -> [GoodbyeReason] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return await noiseReadbackRegistry.messages(for: transport)
            .filter { SendspinEncoding.messageType(of: $0) == ClientGoodbyeMessage.typeString }
            .compactMap { (try? decoder.decode(ClientGoodbyeMessage.self, from: $0))?.payload.reason }
    }

    private func streamFinishes(_ stream: AsyncStream<some Sendable>) async -> Bool {
        let result = await outcomeOfUnstructuredOperation(
            timeout: .seconds(1),
            operation: {
                var iterator = stream.makeAsyncIterator()
                while await iterator.next() != nil {}
                return true
            }
        )
        return (try? result?.get()) == true
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool {
        continuation != nil
    }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor FakeAudioOutputCapabilityProvider: AudioOutputCapabilityProviding {
    private let stream: AsyncStream<AudioOutputSnapshot>
    private let continuation: AsyncStream<AudioOutputSnapshot>.Continuation
    private var currentSnapshot: AudioOutputSnapshot
    private(set) var activationState: AudioSessionActivationState = .unknown
    private(set) var monitoringStarted = false
    private(set) var snapshotCount = 0
    private(set) var queueTransitionRates: [Int] = []
    private(set) var queueStartCount = 0
    private(set) var stopCount = 0

    init(
        initialSnapshot: AudioOutputSnapshot = AudioOutputSnapshot(
            sampleRate: nil,
            reportedBitDepth: nil,
            diagnosticDescription: nil
        )
    ) {
        currentSnapshot = initialSnapshot
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func snapshot() -> AudioOutputSnapshot {
        snapshotCount += 1
        return currentSnapshot
    }

    func audioQueueTransitionWillBegin(sampleRate: Int) {
        queueTransitionRates.append(sampleRate)
    }

    func audioQueueTransitionDidStart() {
        queueStartCount += 1
    }

    func startMonitoring() -> AsyncStream<AudioOutputSnapshot> {
        monitoringStarted = true
        return stream
    }

    func setAudioSessionActivationState(_ state: AudioSessionActivationState) {
        activationState = state
    }

    func publish(_ snapshot: AudioOutputSnapshot) {
        currentSnapshot = snapshot
        continuation.yield(snapshot)
    }

    func stopMonitoring() {
        guard stopCount == 0 else { return }
        stopCount += 1
        continuation.finish()
    }
}
