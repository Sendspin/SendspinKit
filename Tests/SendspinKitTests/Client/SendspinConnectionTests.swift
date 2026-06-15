// swiftlint:disable file_length

import Foundation
@testable import SendspinKit
import Testing

@Suite("SendspinConnection")
struct SendspinConnectionTests {
    @Test("facade does not retain or directly command audio/clock internals")
    func facadeDoesNotReachThroughToAudioOrClockInternals() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let clientSource = try String(contentsOf: root.appending(path: "Sources/SendspinKit/Client/SendspinClient.swift"), encoding: .utf8)
        let commandSource = try String(contentsOf: root.appending(path: "Sources/SendspinKit/Client/SendspinClient+Commands.swift"), encoding: .utf8)

        #expect(!clientSource.contains("var clockSync: ClockSynchronizer?"))
        #expect(!clientSource.contains("var audioEngine: AudioEngine?"))
        #expect(!clientSource.contains("self.clockSync ="))
        #expect(!clientSource.contains("self.audioEngine ="))
        #expect(!clientSource.contains("conn.engine"))
        #expect(!clientSource.contains("audioEngineForTesting"))
        #expect(!commandSource.contains("if let audioEngine"))
        #expect(!commandSource.contains("await audioEngine."))
    }

    // MARK: - Facade-independent audio routing

    /// Test that a connection can be driven directly with MockTransport (no SendspinClient).
    @Test("audio reaches the engine without going through the facade")
    func audioReachesEngineWithoutFacade() async throws {
        // Drive the connection directly with a MockTransport — no SendspinClient
        // anywhere — so anything that reaches the engine did so via the
        // connection→engine channel, not the facade.
        let transport = MockTransport()
        let clock = StubClock()
        let (connection, _, engine, _) = makeConnectionWithSpyEngine(clock, transport)

        await connection.start()
        try await transport.injectText(serverHelloJSON())

        // Sync the clock so audio chunks pass the pre-sync gate and reach the engine.
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        try await transport.injectText(serverTimeJSON(clientTransmitted: now, serverReceived: now + 100, serverTransmitted: now + 200))

        // Inject stream/start, then a real binary audio frame.
        try await transport.injectText(streamStartJSON(codec: "pcm"))
        await transport.injectBinary(audioChunkFrame())

        // The audio must reach the engine as a `.chunk` command WITHOUT routing
        // through any facade — the whole point of the connection→engine channel.
        // Observing `appliedCommandKinds()` proves the frame was decoded into a
        // command and drained, not merely that the run did not hang.
        #expect(
            await waitUntil(timeout: .seconds(3)) {
                let kinds = await engine.appliedCommandKinds()
                return kinds.contains(.streamStart) && kinds.contains(.chunk)
            },
            "stream/start and the binary audio frame must reach the engine as .streamStart + .chunk"
        )

        // Inject stream/end and close
        try await transport.injectText(streamEndJSON())
        await transport.finishStreams()

        let disconnectEvent = await collectConnectionEvent(from: connection) {
            if case .disconnected = $0 { true } else { false }
        }

        #expect(disconnectEvent != nil, "Should emit .disconnected")
        #expect(
            await waitUntil(timeout: .seconds(3)) { await engine.appliedCommandKinds().contains(.streamEnd) },
            "stream/end must also reach the engine through the connection channel"
        )
    }

    @Test("binary audio arriving after the validity token is retired is dropped (teardown race)")
    func lateBinaryDuringTeardownRaceIsDropped() async throws {
        // Retire flips the validity token synchronously, but the dying connection's
        // message loop can still be draining buffered binary frames. Any audio chunk
        // it routes AFTER the token is invalidated must be dropped at the emit point
        // (`validity.yieldIfValid`) — not leaked onto the public audio stream of a
        // session the facade has already replaced. This pins the *during-teardown*
        // window, complementing SessionRetireTests' synchronous-retire coverage.
        let transport = MockTransport()
        let clock = StubClock()
        let token = SessionValidityToken()
        let (audioStream, audioCont) = AsyncStream<AudioChunk>.makeStream()

        let output = SpyAudioOutput()
        let scheduler = AudioScheduler(clockSync: clock)
        let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)
        let connection = SendspinConnection(
            transport: transport,
            parsedHello: nil,
            clientHelloPayload: testClientHelloPayload(),
            audioSink: audioCont,
            validity: token,
            advertisedCommands: [.setStaticDelay],
            roles: [.playerV1],
            clock: clock,
            engine: engine
        )

        let chunkCount = TestBox<Int>(0)
        let consumer = Task {
            for await _ in audioStream {
                await chunkCount.update { $0 += 1 }
            }
        }

        await connection.start()
        try await transport.injectText(serverHelloJSON())
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        try await transport.injectText(serverTimeJSON(clientTransmitted: now, serverReceived: now + 100, serverTransmitted: now + 200))
        try await transport.injectText(streamStartJSON())

        // Positive control: a chunk emitted while the token is still valid reaches the
        // public audio stream.
        await transport.injectBinary(audioChunkFrame(index: 0))
        #expect(
            await waitUntil(timeout: .seconds(3)) { await chunkCount.value == 1 },
            "a chunk routed while valid must reach the public audio stream"
        )

        // Retire mid-flight: invalidate the token exactly as retireSession() does,
        // WITHOUT tearing down the loop — then push a late chunk through.
        token.invalidate()
        await transport.injectBinary(audioChunkFrame(index: 1))

        // The late chunk must be dropped. Give it ample time to (wrongly) surface.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await chunkCount.value == 1, "a chunk routed AFTER retire must be dropped, not emitted")

        consumer.cancel()
        await connection.shutdown()
    }

    @Test("supervisor closes transport when inbound frame stream ends")
    func supervisorClosesTransportWhenFrameStreamEnds() async throws {
        let transport = MockTransport()
        let connection = try makeConnectionWithTransport(transport)
        await connection.start()
        try await transport.injectText(serverHelloJSON())

        await transport.finishStreams()

        _ = await collectConnectionEvent(from: connection) {
            if case .disconnected = $0 { true } else { false }
        }

        #expect(await transport.disconnectCalled, "runLoop must close the transport to release any parked frame pull")
    }

    @Test("supervisor releases a parked message loop when a sibling loop ends first")
    func supervisorReleasesParkedMessageLoopWhenSiblingEndsFirst() async throws {
        // Head-on guard for the deadlock the lifecycle fix prevents: the message loop is
        // parked in nextFrame() (no EOF) while a *sibling* supervisor loop exits first.
        // Because FrameInbox no longer releases on task cancellation, group.cancelAll()
        // cannot unblock the parked pull — runLoop MUST close the transport (which calls
        // FrameInbox.finish()) before cancelling, or teardown hangs forever.
        //
        // We reproduce "sibling ends first" by finishing the engine's report stream out
        // from under the connection, which ends reportDrain() while the message loop stays
        // parked. Built inline so the test can hold the engine reference.
        let transport = MockTransport()
        let engine = try AudioEngine(
            clock: ClockSynchronizer(),
            config: PlayerConfiguration(
                bufferCapacity: 100_000,
                supportedFormats: [AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)]
            )
        )
        let connection = SendspinConnection(
            transport: transport,
            parsedHello: nil,
            clientHelloPayload: testClientHelloPayload(),
            validity: SessionValidityToken(),
            advertisedCommands: [.setStaticDelay],
            engine: engine
        )

        await connection.start()
        try await transport.injectText(serverHelloJSON())

        // Single consumer of the control stream: when `.serverConnected` arrives the
        // message loop has provably run past `audioEngine.start()` and re-parked on
        // nextFrame(), so shutting the engine down now ends reportDrain() first without
        // racing the engine's own start. Then await the terminal `.disconnected`, which
        // only arrives if runLoop releases the parked message loop.
        let reachedDisconnectResult = await outcomeOfUnstructuredOperation(timeout: .seconds(2)) {
            for await event in connection.events {
                if case .serverConnected = event {
                    await engine.shutdown()
                }
                if case .disconnected = event { return true }
            }
            return false
        }
        let reachedDisconnect = (try? reachedDisconnectResult?.get()) ?? false

        #expect(reachedDisconnect, "runLoop must close the transport to release the parked message loop and reach teardown")
        #expect(await transport.disconnectCalled, "runLoop must call transport.disconnect() to finish the frame inbox")
    }

    // MARK: - Handshake validation

    @Test("server/hello with unsupported core version is rejected before handshake completion")
    func serverHelloUnsupportedVersionRejectedBeforeHandshakeCompletion() async throws {
        let transport = MockTransport()
        let connection = try makeConnectionWithTransport(transport)
        await connection.start()

        try await transport.injectText(serverHelloJSON(version: 2))

        let events = await collectConnectionEvents(from: connection, until: { events in
            events.contains { if case .disconnected = $0 { true } else { false } }
        })

        #expect(!events.contains { if case .serverConnected = $0 { true } else { false } })
        #expect(events.contains { if case .disconnected(.incompatibleServer) = $0 { true } else { false } })
        #expect(await transport.disconnectCalled, "unsupported server/hello version must close the transport")
        #expect(
            await !waitForSentMessage(ofType: ClientStateMessage.typeString, on: transport, attempts: 20),
            "client/state must not be sent before accepting server/hello.version == 1"
        )
    }

    // MARK: - Idempotent shutdown

    @Test("shutdown() is idempotent")
    func shutdownIsIdempotent() async throws {
        let transport = MockTransport()
        let token = SessionValidityToken()
        let connection = try makeConnectionWithTransport(transport, validity: token)
        await connection.start()

        await connection.shutdown()
        await connection.shutdown()

        // The second shutdown must be a true no-op: lifecycle-guarded teardown runs
        // once, so exactly one terminal `.disconnected` is emitted (not one per call)
        // and the session-validity token is invalidated.
        let events = await collectConnectionEvents(from: connection, until: { _ in false })
        let disconnects = events.count(where: { if case .disconnected = $0 { true } else { false } })
        #expect(disconnects == 1, "teardown must emit exactly one terminal .disconnected across two shutdowns")
        #expect(!token.isValid, "shutdown must invalidate the session-validity token")
    }

    @Test("concurrent shutdown() calls run teardown once")
    func concurrentShutdownRunsTeardownOnce() async throws {
        let transport = MockTransport()
        let token = SessionValidityToken()
        let connection = try makeConnectionWithTransport(transport, validity: token)
        await connection.start()
        try await transport.injectText(serverHelloJSON())

        // Run two shutdown() calls concurrently
        async let shutdown1: Void = connection.shutdown()
        async let shutdown2: Void = connection.shutdown()

        _ = await (shutdown1, shutdown2)

        // Only the first caller runs teardown; the second observes `shuttingDown`
        // and merely awaits the supervisor. Exactly one terminal `.disconnected`
        // (finishTeardown is lifecycle-guarded) proves teardown ran once.
        let events = await collectConnectionEvents(from: connection, until: { _ in false })
        let disconnects = events.count(where: { if case .disconnected = $0 { true } else { false } })
        #expect(disconnects == 1, "concurrent shutdowns must run teardown exactly once (one .disconnected)")
        #expect(!token.isValid, "the token must be invalidated by the single teardown")
    }

    // MARK: - Goodbye semantics

    @Test("disconnect(reason:) sends exactly one client/goodbye")
    func disconnectSendsExactlyOneGoodbye() async throws {
        let transport = MockTransport()
        let connection = try makeConnectionWithTransport(transport)
        await connection.start()
        try await transport.injectText(serverHelloJSON())
        #expect(
            await waitForSentMessage(ofType: ClientStateMessage.typeString, on: transport),
            "server/hello should complete the handshake before a graceful disconnect sends goodbye"
        )

        await connection.disconnect(reason: .userRequest)

        let goodbyes = await transport.sentTextMessages.filter { data in
            guard let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains("goodbye")
        }

        #expect(goodbyes.count == 1, "Should send exactly one goodbye")
    }

    @Test("concurrent disconnects send exactly one client/goodbye")
    func concurrentDisconnectsSendExactlyOneGoodbye() async throws {
        let transport = MockTransport()
        let connection = try makeConnectionWithTransport(transport)
        await connection.start()
        try await transport.injectText(serverHelloJSON())
        #expect(
            await waitForSentMessage(ofType: ClientStateMessage.typeString, on: transport),
            "server/hello should complete the handshake before a graceful disconnect sends goodbye"
        )

        await transport.enableGoodbyeGate()
        async let firstDisconnect: Void = connection.disconnect(reason: .userRequest)
        #expect(
            await waitUntil { await transport.isGoodbyeGateWaiting },
            "first disconnect should park while sending goodbye"
        )

        async let secondDisconnect: Void = connection.disconnect(reason: .shutdown)
        try await Task.sleep(for: .milliseconds(50))

        let goodbyesWhileFirstSendIsParked = await transport.sentTextMessages.filter { data in
            guard let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains("goodbye")
        }
        #expect(goodbyesWhileFirstSendIsParked.isEmpty, "mock records the parked goodbye only after release")

        await transport.releaseGoodbyeGate()
        _ = await (firstDisconnect, secondDisconnect)

        let goodbyes = await transport.sentTextMessages.filter { data in
            guard let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains("goodbye")
        }
        #expect(goodbyes.count == 1, "concurrent disconnects must send exactly one goodbye")
    }

    @Test("unsolicited close sends no goodbye")
    func unsolicitedCloseSendsNoGoodbye() async throws {
        let transport = MockTransport()
        let connection = try makeConnectionWithTransport(transport)
        await connection.start()
        try await transport.injectText(serverHelloJSON())

        await transport.finishStreams()

        _ = await collectConnectionEvent(from: connection) {
            if case .disconnected = $0 { true } else { false }
        }

        let goodbyes = await transport.sentTextMessages.filter { data in
            guard let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains("goodbye")
        }

        #expect(goodbyes.isEmpty, "Unsolicited close should not send goodbye")
    }

    @Test("explicit disconnect reason wins a disconnect-versus-loss race")
    func disconnectVsLossRace() async throws {
        let transport = MockTransport()
        let connection = try makeConnectionWithTransport(transport)
        await connection.start()
        try await transport.injectText(serverHelloJSON())

        // Enable goodbye gate so disconnect can run to its await
        await transport.enableGoodbyeGate()

        // Start disconnect (will park on goodbye gate)
        async let disconnectTask = connection.disconnect(reason: .userRequest)

        // Give it time to reach the gate
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Now inject loss while goodbye is parked
        await transport.finishStreams()

        // Release the gate to let disconnect complete
        await transport.releaseGoodbyeGate()

        await disconnectTask

        let disconnectReason: DisconnectReason? = await {
            guard let event = await collectConnectionEvent(from: connection, where: {
                if case .disconnected = $0 { true } else { false }
            }) else { return nil }
            if case let .disconnected(reason) = event { return reason }
            return nil
        }()

        // Should have the explicit reason (not connectionLost)
        if case let .explicit(goodbyeReason) = disconnectReason {
            #expect(goodbyeReason == .userRequest)
        } else {
            Issue.record("Expected .explicit(.userRequest), got \(String(describing: disconnectReason))")
        }
    }

    @Test("second disconnect after teardown is a no-op")
    func secondDisconnectAfterTeardownIsNoop() async throws {
        let transport = MockTransport()
        let connection = try makeConnectionWithTransport(transport)
        await connection.start()
        try await transport.injectText(serverHelloJSON())

        #expect(
            await waitForSentMessage(ofType: ClientStateMessage.typeString, on: transport),
            "server/hello should complete the handshake before the graceful disconnect"
        )

        await connection.disconnect(reason: .userRequest)

        _ = await collectConnectionEvent(from: connection) {
            if case .disconnected = $0 { true } else { false }
        }

        let goodbyesAfterFirst = await transport.sentTextMessages
            .count(where: { SendspinEncoding.messageType(of: $0) == ClientGoodbyeMessage.typeString })
        let closesAfterFirst = await transport.disconnectCallCount

        // Second disconnect after teardown must be a true no-op: no second goodbye
        // on the wire and no second transport close — it only awaits the supervisor.
        await connection.disconnect(reason: .shutdown)

        #expect(goodbyesAfterFirst == 1, "first graceful disconnect sends exactly one goodbye")
        #expect(
            await transport.sentTextMessages
                .count(where: { SendspinEncoding.messageType(of: $0) == ClientGoodbyeMessage.typeString }) == 1,
            "second disconnect must NOT send another goodbye"
        )
        #expect(await transport.disconnectCallCount == closesAfterFirst, "second disconnect must NOT close the transport again")
    }

    // MARK: - Validity token

    @Test("validity token starts valid and can be invalidated")
    func validityTokenBasicBehavior() {
        let token = SessionValidityToken()

        #expect(token.isValid, "Token should be initially valid")

        token.invalidate()

        #expect(!token.isValid, "Token should be invalid after invalidate()")
    }

    @Test("yieldIfValid atomically drops events after invalidation")
    func yieldIfValidIsAtomic() async {
        let token = SessionValidityToken()
        let (stream, continuation) = AsyncStream<ClientEvent>.makeStream()

        // Start collecting events in background
        let collectorTask = Task { () -> [ClientEvent] in
            var events: [ClientEvent] = []
            for await event in stream {
                events.append(event)
            }
            return events
        }

        // Create a test event
        let testEvent = ClientEvent.disconnected(reason: .connectionLost)

        // Yield while valid
        token.yieldIfValid(testEvent, to: continuation)

        // Invalidate
        token.invalidate()

        // Try to yield after invalidation (should be dropped)
        token.yieldIfValid(testEvent, to: continuation)

        // Finish the stream
        continuation.finish()

        let receivedEvents = await collectorTask.value

        // Should have received exactly one event (the first one)
        #expect(receivedEvents.count == 1, "Should receive exactly one event (the valid one)")
    }

    // MARK: - Unsolicited close

    @Test("unsolicited close emits exactly one disconnected connection-lost event")
    func unsolicitedCloseSingleDisconnected() async throws {
        let transport = MockTransport()
        let connection = try makeConnectionWithTransport(transport)
        await connection.start()
        try await transport.injectText(serverHelloJSON())

        await transport.finishStreams()

        let disconnectEvents = await collectConnectionEvents(from: connection, until: { events in
            events.contains { if case .disconnected = $0 { true } else { false } }
        })
        let disconnected = disconnectEvents.compactMap { event -> DisconnectReason? in
            if case let .disconnected(reason) = event { return reason }
            return nil
        }

        #expect(disconnected.count == 1, "Should emit exactly one .disconnected")
        #expect(disconnected.contains { if case .connectionLost = $0 { true } else { false } }, "Should be .connectionLost reason")
    }

    // MARK: - Clock synchronization fidelity

    @Test("server/time samples are delivered in receipt order with frame-read timestamps")
    func serverTimeFramesProcessedSafely() async throws {
        let transport = MockTransport()
        let clock = RecordingClockSynchronizer()
        let connection = try makeConnectionWithClockAndTransport(clock, transport)
        await connection.start()

        try await transport.injectText(serverHelloJSON())

        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let sampleTimestamps: [
            (clientTransmitted: Int64, serverReceived: Int64, serverTransmitted: Int64)
        ] = [
            (now, now + 100, now + 200),
            (now + 1_000, now + 1_100, now + 1_200),
            (now + 2_000, now + 2_100, now + 2_200)
        ]

        // Bracket the arrival window in the MONOTONIC domain (the connection stamps
        // clientReceived via MonotonicClock.nowMicroseconds()). A stale/constant stamp
        // would fall outside this bracket.
        let monoBefore = MonotonicClock.nowMicroseconds()

        for (clientTx, serverRx, serverTx) in sampleTimestamps {
            let json = try serverTimeJSON(
                clientTransmitted: clientTx, serverReceived: serverRx, serverTransmitted: serverTx
            )
            await transport.injectText(json)
        }

        let recorded = await clock.waitForRecordedSamples(count: sampleTimestamps.count)
        let monoAfter = MonotonicClock.nowMicroseconds()

        #expect(
            recorded.count == sampleTimestamps.count,
            "All server/time frames should be delivered in receipt order, got \(recorded.count) of \(sampleTimestamps.count)"
        )

        for (index, (_, serverRx, serverTx)) in sampleTimestamps.enumerated() {
            guard index < recorded.count else { break }
            let sample = recorded[index]

            #expect(
                sample.serverReceived == serverRx,
                "Sample \(index) serverReceived should match receipt order: expected \(serverRx), got \(sample.serverReceived)"
            )
            #expect(
                sample.serverTransmitted == serverTx,
                "Sample \(index) serverTransmitted should match receipt order: expected \(serverTx), got \(sample.serverTransmitted)"
            )
            #expect(
                sample.clientReceived >= monoBefore && sample.clientReceived <= monoAfter,
                "Sample \(index) clientReceived must be a monotonic arrival stamp in [\(monoBefore), \(monoAfter)]: got \(sample.clientReceived)"
            )
        }

        await connection.shutdown()
    }

    // MARK: - Stream start failures

    @Test("stream/start with an unsupported codec emits streamError(.unsupportedCodec)")
    func streamStartUnsupportedCodecEmitsError() async throws {
        let transport = MockTransport()
        let connection = try makeConnectionWithTransport(transport)
        await connection.start()
        try await transport.injectText(serverHelloJSON())

        // Inject stream/start with unknown codec
        try await transport.injectText(
            streamStartJSON(codec: "unknownCodec")
        )

        let errorEvent = await collectConnectionEvent(from: connection) {
            if case .streamError(.unsupportedCodec) = $0 { true } else { false }
        }
        if case let .streamError(.unsupportedCodec(codec)) = errorEvent {
            #expect(codec == "unknownCodec")
        }

        #expect(errorEvent != nil, "Should emit streamError(.unsupportedCodec)")
    }

    @Test("stream/start with an unsupported codec does not enqueue streamStart to the engine")
    func streamStartUnsupportedCodecDoesNotEnqueueToEngine() async throws {
        let transport = MockTransport()
        let engine = try AudioEngine(
            clock: ClockSynchronizer(),
            config: PlayerConfiguration(
                bufferCapacity: 100_000,
                supportedFormats: [AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)]
            )
        )
        let connection = SendspinConnection(
            transport: transport,
            parsedHello: nil,
            clientHelloPayload: testClientHelloPayload(),
            validity: SessionValidityToken(),
            advertisedCommands: [.setStaticDelay],
            engine: engine
        )

        await connection.start()
        try await transport.injectText(serverHelloJSON())

        // Inject invalid format
        try await transport.injectText(streamStartJSON(codec: "unknownCodec"))

        // Give it time to process
        try await Task.sleep(nanoseconds: 50_000_000)

        // Check that a streamError event was emitted
        let errorEvent = await collectConnectionEvent(from: connection) {
            if case .streamError(.unsupportedCodec) = $0 { true } else { false }
        }
        if case let .streamError(.unsupportedCodec(codec)) = errorEvent {
            #expect(codec == "unknownCodec")
        }

        #expect(errorEvent != nil, "Should emit streamError for invalid codec")
    }

    // MARK: - Unlisted command ignored (GAP 1 test)

    @Test("unlisted server commands are ignored while listed commands apply")
    func unlistedCommandIgnoredListedCommandApplies() async throws {
        let transport = MockTransport()
        let engine = try AudioEngine(
            clock: ClockSynchronizer(),
            config: PlayerConfiguration(
                bufferCapacity: 100_000,
                supportedFormats: [AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)]
            )
        )

        // Player role so client/state carries a player object; advertise ONLY
        // setStaticDelay (no volume/mute) so a volume command is unlisted.
        let connection = SendspinConnection(
            transport: transport,
            parsedHello: nil,
            clientHelloPayload: testClientHelloPayload(),
            validity: SessionValidityToken(),
            advertisedCommands: [.setStaticDelay],
            roles: [.playerV1],
            engine: engine
        )

        /// Count only client/state messages — the clock-sync loop emits client/time
        /// periodically, which would pollute a raw message count.
        func sentClientStateCount() async -> Int {
            await transport.sentTextMessages
                .count(where: { SendspinEncoding.messageType(of: $0) == ClientStateMessage.typeString })
        }
        /// Deterministic poll: wait until the count reaches `target` (or time out).
        func waitForClientStateCount(atLeast target: Int) async -> Bool {
            for _ in 0 ..< 100 {
                if await sentClientStateCount() >= target { return true }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return false
        }

        await connection.start()
        try await transport.injectText(serverHelloJSON())

        // Wait for the hello's initial client/state, then baseline (deterministic — avoids
        // a delayed hello send racing into the measurement window under parallel load).
        #expect(await waitForClientStateCount(atLeast: 1), "hello should send an initial client/state")
        let baseline = await sentClientStateCount()

        // Inject an UNLISTED command (volume — not in advertised set), then a LISTED one
        // (set_static_delay). The message loop is ordered, so when the listed command's
        // client/state appears the unlisted command has already been fully processed.
        try await transport.injectText(serverCommandJSON(PlayerCommandObject(command: .volume, volume: 75)))
        try await transport.injectText(serverCommandJSON(PlayerCommandObject(command: .setStaticDelay, staticDelayMs: 500)))

        // The listed command must produce exactly one client/state; the unlisted one none.
        // If the unlisted command had wrongly sent state, the delta would be 2.
        #expect(await waitForClientStateCount(atLeast: baseline + 1), "listed command should send client/state")
        let delta = await sentClientStateCount() - baseline
        #expect(delta == 1, "Listed command sends exactly one client/state; the unlisted command sends none")

        await connection.shutdown()
    }

    @Test("VolumeMode.none advertises no volume or mute commands")
    func volumeModeNoneAdvertisesNoCommands() {
        // VolumeCapabilities for .none mode should advertise no volume/mute
        let capabilities = VolumeCapabilities(supportsVolume: false)
        let commands = capabilities.playerCommands
        #expect(!commands.contains(.volume), "Should not advertise volume when supportsVolume=false")
        #expect(!commands.contains(.mute), "Should not advertise mute when supportsVolume=false")
    }

    // MARK: - Pre-sync audio gate

    @Test("pre-sync audio chunks are raw-emitted but not enqueued to the engine until synced")
    func presyncAudioChunkGate() async throws {
        // Collect binary events the connection emits straight to the public sink.
        let transport = MockTransport()
        let clock = StubClock() // hasSynced == true, but the connection only flips its
        // own isClockSynced after it processes a server/time frame.
        let (connection, _, engine, _) = makeConnectionWithSpyEngine(clock, transport)

        await connection.start()
        try await transport.injectText(serverHelloJSON())
        try await transport.injectText(streamStartJSON())

        // PRE-SYNC: inject a chunk before any server/time.
        await transport.injectBinary(audioChunkFrame(index: 0))
        try await Task.sleep(nanoseconds: 80_000_000)

        let kindsBeforeSync = await engine.appliedCommandKinds()
        let chunksEnqueuedPreSync = kindsBeforeSync.count(where: { $0 == .chunk })
        #expect(chunksEnqueuedPreSync == 0, "Pre-sync chunk must NOT be enqueued to the engine")

        // Sync the clock, then inject a post-sync chunk.
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        try await transport.injectText(serverTimeJSON(clientTransmitted: now, serverReceived: now + 100, serverTransmitted: now + 200))
        try await Task.sleep(nanoseconds: 80_000_000)
        await transport.injectBinary(audioChunkFrame(index: 1))
        try await Task.sleep(nanoseconds: 80_000_000)

        let kindsAfterSync = await engine.appliedCommandKinds()
        let chunksEnqueuedPostSync = kindsAfterSync.count(where: { $0 == .chunk })
        #expect(chunksEnqueuedPostSync >= 1, "Post-sync chunk MUST be enqueued to the engine")

        await transport.finishStreams()
        _ = await collectConnectionEvent(from: connection) {
            if case .disconnected = $0 { true } else { false }
        }
        // (Raw-emit-regardless-of-sync is covered by the binary-gate tests in
        // FrameOrderingTests; here the focus is the engine-enqueue clock gate.)
    }

    // MARK: - Clock snapshot forwarding

    @Test("each server/time pushes a clock snapshot to the engine output")
    func clockSnapshotForward() async throws {
        // StubClock.snapshot() returns a non-nil snapshot, so the connection's
        // `engine.updateClockSnapshot(snapshot)` forwards to `output.updateTimeSnapshot`.
        let transport = MockTransport()
        let clock = StubClock()
        let (connection, output, _, _) = makeConnectionWithSpyEngine(clock, transport)

        await connection.start()
        try await transport.injectText(serverHelloJSON())

        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        try await transport.injectText(serverTimeJSON(clientTransmitted: now, serverReceived: now + 100, serverTransmitted: now + 200))
        try await transport.injectText(serverTimeJSON(clientTransmitted: now + 1_000, serverReceived: now + 1_100, serverTransmitted: now + 1_200))
        try await Task.sleep(nanoseconds: 100_000_000)

        await transport.finishStreams()
        _ = await collectConnectionEvent(from: connection) {
            if case .disconnected = $0 { true } else { false }
        }

        // Each processed server/time must forward a snapshot to the engine output.
        // Mutation: removing `engine.updateClockSnapshot` in handleServerTime → zero calls → fails.
        let snapshotCalls = await output.recordedCalls.count(where: { $0 == "updateTimeSnapshot()" })
        #expect(snapshotCalls >= 2, "Each server/time should push a snapshot to the engine (got \(snapshotCalls))")
    }

    // MARK: - Invalid stream/start format

    @Test("stream/start with invalid format emits .invalidFormat error")
    func streamStartInvalidFormatError() async throws {
        let transport = MockTransport()
        let connection = try makeConnectionWithTransport(transport)
        await connection.start()
        try await transport.injectText(serverHelloJSON())

        // Inject stream/start with zero channels (invalid format)
        let invalidStartJSON = """
        {"type":"stream/start","payload":{"player":{"codec":"pcm","sample_rate":44100,"channels":0,"bit_depth":16}}}
        """
        await transport.injectText(invalidStartJSON)

        let invalidFormatEvent = await collectConnectionEvent(from: connection) {
            if case .streamError(.invalidFormat) = $0 { true } else { false }
        }

        #expect(invalidFormatEvent != nil, "Should emit .invalidFormat for invalid format spec")
    }

    @Test("stream/start with invalid format keeps the player gate open and reports error state")
    func streamStartInvalidFormatState() async throws {
        let transport = MockTransport()
        let connection = try makeConnectionWithTransport(transport)
        await connection.start()
        try await transport.injectText(serverHelloJSON())

        // Inject invalid stream/start
        let invalidStartJSON = """
        {"type":"stream/start","payload":{"player":{"codec":"pcm","sample_rate":44100,"channels":0,"bit_depth":16}}}
        """
        await transport.injectText(invalidStartJSON)

        let events = await collectConnectionEvents(from: connection, until: { events in
            events.contains { if case .operationalState(.error) = $0 { true } else { false } }
        })
        let sawError = events.contains { if case .streamError(.invalidFormat) = $0 { true } else { false } }
        let sawOperationalError = events.contains { if case .operationalState(.error) = $0 { true } else { false } }

        #expect(sawError, "Should emit streamError(.invalidFormat)")
        #expect(sawOperationalError, "Should emit operationalState(.error)")
    }

    // MARK: - Engine start-failure mapping

    @Test("engine start failure maps to stream error, operational error, and client/state")
    func engineStartFailedMapping() async throws {
        struct StartError: Error {}
        let transport = MockTransport()
        let clock = StubClock()
        let (connection, output, _, _) = makeConnectionWithSpyEngine(clock, transport)

        // Force the audio output to fail on start, so applying stream/start makes the
        // engine report .startFailed.
        await output.setForcedStartThrow(StartError())

        await connection.start()
        try await transport.injectText(serverHelloJSON())
        let baselineState = await transport.sentTextMessages
            .count(where: { SendspinEncoding.messageType(of: $0) == ClientStateMessage.typeString })
        try await transport.injectText(streamStartJSON(codec: "pcm"))

        // Bounded so a regression (mapping removed) fails cleanly instead of hanging.
        let startFailureResult = await outcomeOfUnstructuredOperation(timeout: .seconds(2)) {
            var failed = false
            var errored = false
            for await event in connection.events {
                if case .streamError(.audioStartFailed) = event { failed = true }
                if case .operationalState(.error) = event { errored = true }
                if failed, errored { return (true, true) }
                if case .disconnected = event { break }
            }
            return (failed, errored)
        }
        let (sawAudioStartFailed, sawErrorState) = (try? startFailureResult?.get()) ?? (false, false)

        #expect(sawAudioStartFailed, "engine .startFailed must surface as streamError(.audioStartFailed)")
        #expect(sawErrorState, "engine .startFailed must surface operationalState(.error)")

        let afterState = await transport.sentTextMessages
            .count(where: { SendspinEncoding.messageType(of: $0) == ClientStateMessage.typeString })
        #expect(afterState > baselineState, "a failed start must send a client/state reporting the error")

        await connection.shutdown()
    }

    // MARK: - Operational-state recovery

    @Test("valid stream/start recovers operational state after an earlier stream error")
    func operationalStateRecovery() async throws {
        let transport = MockTransport()
        let connection = try makeConnectionWithTransport(transport)
        await connection.start()
        try await transport.injectText(serverHelloJSON())

        // Inject invalid stream/start (bad codec)
        try await transport.injectText(streamStartJSON(codec: "unknownCodec"))

        let firstError = await collectConnectionEvent(from: connection) {
            if case .streamError(.unsupportedCodec) = $0 { true } else { false }
        }
        #expect(firstError != nil, "Should emit unsupported codec error")

        // Now inject valid stream/start
        try await transport.injectText(streamStartJSON(codec: "pcm"))

        // Bounded collection so a regression (recovery emission removed) surfaces as a
        // clean expectation failure rather than a 90s hang.
        let recoveredResult = await outcomeOfUnstructuredOperation(timeout: .seconds(2)) {
            for await event in connection.events {
                if case .operationalState(.synchronized) = event { return true }
                if case .disconnected = event { return false }
            }
            return false
        }
        let recovered = (try? recoveredResult?.get()) ?? false

        #expect(recovered, "Should return to synchronized state after a successful start following an error")

        await connection.shutdown()
    }

    @Test("Default startup does not apply volume to the output device")
    func defaultStartupDoesNotApplyVolumeToOutputDevice() async throws {
        let transport = MockTransport()
        let clock = StubClock()
        let (connection, output, _, _) = makeConnectionWithSpyEngine(clock, transport)

        await connection.start()
        try await transport.injectText(serverHelloJSON())
        #expect(
            await waitForSentMessage(ofType: "client/hello", on: transport),
            "startup must reach the message loop before asserting it did not apply volume"
        )

        let calls = await output.recordedCalls
        #expect(!calls.contains("setVolume(1.0)"), "default volume must not be written to hardware on startup")
        #expect(!calls.contains(where: { $0.hasPrefix("setVolume(") }), "startup must not apply any output volume before an explicit change")

        await connection.shutdown()
    }

    @Test("Non-default carried player state seeds a fresh engine")
    func nonDefaultCarriedPlayerStateSeedsFreshEngine() async throws {
        let transport = MockTransport()
        let clock = StubClock()
        let (connection, output, _, _) = makeConnectionWithSpyEngine(
            clock,
            transport,
            initialVolume: 42,
            initialMuted: true
        )

        await connection.start()
        try await transport.injectText(serverHelloJSON())
        #expect(
            await waitUntil {
                let calls = await output.recordedCalls
                return calls.contains("setVolume(0.42)") && calls.contains("setMute(true)")
            },
            "non-default carried player state must seed the fresh engine"
        )

        let calls = await output.recordedCalls
        #expect(calls.contains("setVolume(0.42)"), "non-default carried volume must still seed the fresh engine")
        #expect(calls.contains("setMute(true)"), "carried mute must still seed the fresh engine")

        await connection.shutdown()
    }

    // MARK: - Watermark flood behavior

    @Test("high-watermark flood drops no chunks and never disconnects")
    func watermarkFloodNoDrop() async throws {
        let transport = MockTransport()
        let clock = StubClock()
        let (connection, _, engine, _) = makeConnectionWithSpyEngine(clock, transport)

        await connection.start()
        try await transport.injectText(serverHelloJSON())
        // Sync the clock so chunks pass the gate and reach the engine.
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        try await transport.injectText(serverTimeJSON(clientTransmitted: now, serverReceived: now + 100, serverTransmitted: now + 200))
        try await transport.injectText(streamStartJSON())
        try await Task.sleep(nanoseconds: 50_000_000)

        // Flood well past the DataPlaneSink high-watermark.
        let chunkCount = 100
        for i in 0 ..< chunkCount {
            await transport.injectBinary(audioChunkFrame(index: i))
        }

        // Wait until all chunks have been applied by the engine (bounded).
        var applied = 0
        for _ in 0 ..< 100 {
            applied = await engine.appliedCommandKinds().count(where: { $0 == .chunk })
            if applied >= chunkCount { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        // Every chunk reaches the engine (watermark is diagnostic-only, never drops).
        // A premature disconnect under watermark pressure would yield fewer applied chunks.
        #expect(applied == chunkCount, "All \(chunkCount) chunks must reach the engine; got \(applied)")

        await connection.shutdown()
    }

    // MARK: - Connection and engine deallocation

    @Test("connection and engine deallocate after shutdown")
    func weakRefDealloc() async throws {
        weak var connectionRef: SendspinConnection?
        weak var engineRef: AudioEngine?

        do {
            let transport = MockTransport()
            let engine = try AudioEngine(
                clock: ClockSynchronizer(),
                config: PlayerConfiguration(
                    bufferCapacity: 100_000,
                    supportedFormats: [AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)]
                )
            )
            engineRef = engine

            let token = SessionValidityToken()

            let connection = SendspinConnection(
                transport: transport,
                parsedHello: nil,
                clientHelloPayload: testClientHelloPayload(),
                validity: token,
                advertisedCommands: [.setStaticDelay],
                engine: engine
            )
            connectionRef = connection

            await connection.start()
            try await transport.injectText(serverHelloJSON())

            await connection.shutdown()
        }

        // After exiting scope, both should be deallocated
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(connectionRef == nil, "Connection should be deallocated (no retain cycle)")
        #expect(engineRef == nil, "Engine should be deallocated (no retain cycle)")
    }

    // MARK: - Start idempotence

    @Test("calling start() twice increments the supervisor spawn count once")
    func spawnCounterIdempotence() async throws {
        let transport = MockTransport()
        let connection = try makeConnectionWithTransport(transport)

        let initialCount = await connection.supervisorSpawnCount
        #expect(initialCount == 0, "Initial spawn count should be 0")

        await connection.start()
        let afterFirstStart = await connection.supervisorSpawnCount
        #expect(afterFirstStart == 1, "First start() should increment to 1")

        await connection.start()
        let afterSecondStart = await connection.supervisorSpawnCount
        #expect(afterSecondStart == 1, "Second start() should remain 1 (idempotent)")

        await connection.shutdown()
    }

    // MARK: - Frame close ordering

    @Test("frame at close does not enqueue to a finished engine")
    func frameCloseOrdering() async throws {
        let transport = MockTransport()
        let connection = try makeConnectionWithTransport(transport)

        await connection.start()
        try await transport.injectText(serverHelloJSON())
        try await transport.injectText(streamStartJSON())

        // Inject a chunk immediately before closing
        await transport.injectBinary(Data([0x01]))

        // Close the transport
        await transport.finishStreams()

        let disconnectEvents = await collectConnectionEvents(from: connection, until: { events in
            events.contains { if case .disconnected = $0 { true } else { false } }
        })
        let disconnectCount = disconnectEvents.count { if case .disconnected = $0 { true } else { false } }

        #expect(disconnectCount == 1, "Should cleanly disconnect without error")
    }

    // MARK: - Handshake ordering (spec §103/§104)

    @Test("client/hello is the first message and client/time is gated on server/hello")
    func helloIsFirstAndClockSyncGatedOnServerHello() async throws {
        let transport = MockTransport()
        let connection = try makeConnectionWithTransport(transport)
        await connection.start()

        // Spec §103: client/hello must be sent, and first.
        #expect(
            await waitForSentMessage(ofType: ClientHelloMessage.typeString, on: transport),
            "client/hello must be sent on connect"
        )
        let beforeServerHello = await transport.sentTextMessages
        #expect(
            beforeServerHello.first.flatMap { SendspinEncoding.messageType(of: $0) }
                == ClientHelloMessage.typeString,
            "client/hello must be the FIRST message"
        )
        // Spec §104: no other client messages before the handshake completes.
        let clientTimeType = ClientTimeMessage.typeString
        #expect(
            !beforeServerHello.contains { SendspinEncoding.messageType(of: $0) == clientTimeType },
            "no client/time may be sent before server/hello"
        )

        // After server/hello, clock sync starts and client/time flows.
        try await transport.injectText(serverHelloJSON())
        #expect(
            await waitForSentMessage(ofType: clientTimeType, on: transport),
            "client/time must flow once the handshake completes"
        )

        await connection.shutdown()
    }
}

/// Session-lifecycle behaviors: stream re-announce classification, carried player
/// state, control-stream depth, and idle teardown. Split from the main suite to
/// keep both type bodies within the lint budget.
@Suite("SendspinConnection session lifecycle")
struct SendspinConnectionSessionTests {
    // MARK: - Stream re-announce classification (codec header)

    /// A gapless track change re-announces the same format with a NEW `codec_header`
    /// (e.g. fresh FLAC streaminfo). Classifying on format alone routed `.streamStart`,
    /// which the player early-returns on, silently ignoring the new header and leaving
    /// a stale decoder. The header must participate in change detection.
    @Test("same-format stream/start with a new codec_header routes a seamless format change")
    func sameFormatNewHeaderRoutesFormatChange() async throws {
        let transport = MockTransport()
        let (connection, _, engine, _) = makeConnectionWithSpyEngine(StubClock(), transport)
        let headerA = Data("streaminfo-A".utf8).base64EncodedString()
        let headerB = Data("streaminfo-B".utf8).base64EncodedString()

        await connection.start()
        try await transport.injectText(serverHelloJSON())
        try await transport.injectText(streamStartJSON(codecHeader: headerA))
        #expect(
            await waitUntil { await engine.appliedCommandKinds().contains(.streamStart) },
            "the initial announce must route .streamStart"
        )

        try await transport.injectText(streamStartJSON(codecHeader: headerB))
        #expect(
            await waitUntil { await engine.appliedCommandKinds().contains(.formatChange) },
            "a new codec_header on an active stream must route .formatChange, not a re-start"
        )
        let kinds = await engine.appliedCommandKinds()
        #expect(
            kinds.count(where: { $0 == .streamStart }) == 1,
            "the header-only re-announce must not route a second .streamStart"
        )

        await connection.shutdown()
    }

    /// The complement guard: an identical re-announce (same format, same header) must
    /// stay `.streamStart` — the player's early-return preserves buffered audio, and a
    /// spurious `.formatChange` would needlessly tear down the decoder.
    @Test("same-format same-header re-announce stays a stream start")
    func sameFormatSameHeaderReannounceStaysStreamStart() async throws {
        let transport = MockTransport()
        let (connection, _, engine, _) = makeConnectionWithSpyEngine(StubClock(), transport)
        let header = Data("streaminfo-A".utf8).base64EncodedString()

        await connection.start()
        try await transport.injectText(serverHelloJSON())
        try await transport.injectText(streamStartJSON(codecHeader: header))
        try await transport.injectText(streamStartJSON(codecHeader: header))
        #expect(
            await waitUntil { await engine.appliedCommandKinds().count(where: { $0 == .streamStart }) == 2 },
            "an identical re-announce must route .streamStart again (player early-return keeps buffers)"
        )
        #expect(
            await !engine.appliedCommandKinds().contains(.formatChange),
            "an identical re-announce must not be classified as a format change"
        )

        await connection.shutdown()
    }

    /// After `stream/end` the announce state must reset: the next `stream/start` is
    /// a fresh start, never a seamless change relative to the ended stream.
    @Test("stream/start after stream/end routes a fresh stream start")
    func streamStartAfterEndRoutesFreshStart() async throws {
        let transport = MockTransport()
        let (connection, _, engine, _) = makeConnectionWithSpyEngine(StubClock(), transport)
        let headerA = Data("streaminfo-A".utf8).base64EncodedString()
        let headerB = Data("streaminfo-B".utf8).base64EncodedString()

        await connection.start()
        try await transport.injectText(serverHelloJSON())
        try await transport.injectText(streamStartJSON(codecHeader: headerA))
        try await transport.injectText(streamEndJSON())
        try await transport.injectText(streamStartJSON(codecHeader: headerB))
        #expect(
            await waitUntil { await engine.appliedCommandKinds().count(where: { $0 == .streamStart }) == 2 },
            "a stream/start after stream/end must route .streamStart, not a seamless change"
        )
        #expect(
            await !engine.appliedCommandKinds().contains(.formatChange),
            "an ended stream must not participate in format-change detection"
        )

        await connection.shutdown()
    }

    // MARK: - Session start seeds the engine with carried player state

    /// A fresh engine boots at default gain/unmuted, but the connection may be
    /// created with carried player state (multi-server switch keeps the user's
    /// volume/mute). Session start must apply that state to the engine, or the
    /// audible output diverges from the reported `client/state`.
    @Test("session start seeds the engine with carried volume and mute")
    func sessionStartSeedsEngineWithCarriedState() async throws {
        let transport = MockTransport()
        let (connection, output, _, _) = makeConnectionWithSpyEngine(
            StubClock(),
            transport,
            initialVolume: 42,
            initialMuted: true
        )

        await connection.start()
        try await transport.injectText(serverHelloJSON())

        #expect(
            await waitUntil {
                let calls = await output.recordedCalls
                return calls.contains("setVolume(0.42)") && calls.contains("setMute(true)")
            },
            "the engine must be seeded with the carried gain and mute at session start"
        )

        await connection.shutdown()
    }

    // MARK: - Control-stream depth diagnostics

    /// The control stream got the same depth observability as the data plane:
    /// every yielded event counts until the facade drain decrements it. With no
    /// drain attached, the depth must reflect the undrained backlog.
    @Test("undrained control events are counted in controlEventDepth")
    func controlDepthTracksUndrainedEvents() async throws {
        let transport = MockTransport()
        let connection = try makeConnectionWithTransport(transport)

        await connection.start()
        try await transport.injectText(serverHelloJSON())
        #expect(
            await waitUntil { connection.controlSink.depth > 0 },
            "control events yielded with no consumer must register as depth"
        )

        await transport.finishStreams()
        await connection.shutdown()
    }

    // MARK: - Teardown from idle (disconnect/shutdown before start)

    /// `disconnect()` before `start()` must terminally stop the connection:
    /// transport closed, and a later `start()` must NOT run a session. Pre-fix,
    /// disconnect-in-idle returned without touching the transport and left
    /// `lifecycle == .idle`, so a later `start()` ran a full session despite the
    /// disconnect intent.
    @Test("disconnect() before start() terminally stops the connection")
    func disconnectBeforeStartPreventsLaterSession() async throws {
        let transport = MockTransport()
        let token = SessionValidityToken()
        let connection = try makeConnectionWithTransport(transport, validity: token)

        await connection.disconnect(reason: .shutdown)
        #expect(await transport.disconnectCalled, "idle disconnect must close the transport")
        #expect(!token.isValid, "idle teardown must invalidate the session validity token")

        // No goodbye either: nothing was ever handshaken on this socket.
        #expect(await transport.sentTextMessages.isEmpty, "idle disconnect must not send messages")

        await connection.start()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(
            await transport.sentTextMessages.isEmpty,
            "start() after an idle disconnect must be a no-op (no client/hello)"
        )

        // The control stream is finished without a .disconnected: the facade
        // installs its drain only after start(), so no consumer exists yet.
        // Race full iteration against a deadline so an unfinished stream FAILS
        // the test instead of wedging it (nil = the deadline won).
        let eventsResult = await outcomeOfUnstructuredOperation(timeout: .milliseconds(500)) {
            var collected: [ConnectionEvent] = []
            for await event in connection.events {
                collected.append(event)
            }
            return collected
        }
        let events = try? eventsResult?.get()
        #expect(
            events?.isEmpty == true,
            "the control stream must be finished, with no events, for a never-started connection"
        )

        // Pre-fix, the erroneous session from start() parks on the never-finished
        // inbox and shutdown() would await it forever (skipping the transport close
        // because shuttingDown is already set). Finish the streams first so this
        // test FAILS rather than wedges. Post-fix this is an idempotent no-op.
        await transport.finishStreams()
        await connection.shutdown()
    }

    /// Same contract for the hard path: `shutdown()` before `start()`.
    @Test("shutdown() before start() terminally stops the connection")
    func shutdownBeforeStartPreventsLaterSession() async throws {
        let transport = MockTransport()
        let connection = try makeConnectionWithTransport(transport)

        await connection.shutdown()
        #expect(await transport.disconnectCalled, "idle shutdown must close the transport")

        await connection.start()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(
            await transport.sentTextMessages.isEmpty,
            "start() after an idle shutdown must be a no-op (no client/hello)"
        )
    }
}

// MARK: - Connection factories (shared by both suites)

private func makeConnectionWithTransport(
    _ transport: MockTransport,
    validity token: SessionValidityToken = SessionValidityToken()
) throws -> SendspinConnection {
    let engine = try AudioEngine(
        clock: ClockSynchronizer(),
        config: PlayerConfiguration(
            bufferCapacity: 100_000,
            supportedFormats: [AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)]
        )
    )
    return SendspinConnection(
        transport: transport,
        parsedHello: nil,
        clientHelloPayload: testClientHelloPayload(),
        validity: token,
        advertisedCommands: [.setStaticDelay],
        engine: engine
    )
}

private func makeConnectionWithClockAndTransport(
    _ clock: any ClockSyncProtocol,
    _ transport: MockTransport
) throws -> SendspinConnection {
    let engine = try AudioEngine(
        clock: clock,
        config: PlayerConfiguration(
            bufferCapacity: 100_000,
            supportedFormats: [AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44_100, bitDepth: 16)]
        )
    )
    let token = SessionValidityToken()

    return SendspinConnection(
        transport: transport,
        parsedHello: nil,
        clientHelloPayload: testClientHelloPayload(),
        validity: token,
        advertisedCommands: [.setStaticDelay],
        clock: clock,
        engine: engine
    )
}

/// Build a connection whose engine is backed by a `SpyAudioOutput`, so tests can
/// observe what actually reached the engine (`appliedCommandKinds()`, recorded
/// output calls, and forced start failures).
private func makeConnectionWithSpyEngine(
    _ clock: any ClockSyncProtocol,
    _ transport: MockTransport,
    initialVolume: Int = 100,
    initialMuted: Bool = false
) -> (
    connection: SendspinConnection,
    output: SpyAudioOutput,
    engine: AudioEngine,
    binaryStream: AsyncStream<ClientEvent>
) {
    let output = SpyAudioOutput()
    let scheduler = AudioScheduler(clockSync: clock)
    let engine = AudioEngine(output: output, scheduler: scheduler, clock: clock)
    let (binaryStream, _) = AsyncStream<ClientEvent>.makeStream()
    let connection = SendspinConnection(
        transport: transport,
        parsedHello: nil,
        clientHelloPayload: testClientHelloPayload(),
        validity: SessionValidityToken(),
        advertisedCommands: [.setStaticDelay],
        roles: [.playerV1],
        initialVolume: initialVolume,
        initialMuted: initialMuted,
        clock: clock,
        engine: engine
    )
    return (connection, output, engine, binaryStream)
}

// MARK: - Test helpers

/// Minimal `client/hello` payload for connection tests. The connection sends this
/// as the first message; tests assert on the message type, not its contents.
private func testClientHelloPayload() -> ClientHelloPayload {
    ClientHelloPayload(
        clientId: "test-client",
        name: "Test Client",
        deviceInfo: .current,
        version: 1,
        supportedRoles: [.playerV1],
        playerV1Support: nil,
        artworkV1Support: nil,
        visualizerV1Support: nil
    )
}

/// Poll the transport until a text message of `type` has been sent, or give up.
private func waitForSentMessage(
    ofType type: String,
    on transport: MockTransport,
    attempts: Int = 100
) async -> Bool {
    for _ in 0 ..< attempts {
        let sent = await transport.sentTextMessages
        if sent.contains(where: { SendspinEncoding.messageType(of: $0) == type }) {
            return true
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

/// Build a valid binary audio-chunk frame (type byte + big-endian timestamp + PCM).
private func audioChunkFrame(index: Int = 0, baseTimestamp: Int64 = 1_000_000) -> Data {
    var frame = Data()
    frame.append(BinaryMessageType.audioChunk.rawValue)
    var timestamp = (baseTimestamp + Int64(index) * 25_000).bigEndian
    frame.append(Data(bytes: &timestamp, count: 8))
    frame.append(Data(repeating: 0x7F, count: 400))
    return frame
}

/// Encode a `stream/start` carrying a player format. `codec` is a raw wire string
/// (not `AudioCodec`) so callers can deliberately exercise the unsupported-codec
/// path — see `streamStartUnknownCodec_emitsClientStateError`.
private func streamStartJSON(codec: String = AudioCodec.pcm.rawValue, codecHeader: String? = nil) throws -> String {
    let message = StreamStartMessage(payload: StreamStartPayload(
        player: StreamStartPlayer(
            codec: codec,
            sampleRate: 44_100,
            channels: 2,
            bitDepth: 16,
            codecHeader: codecHeader
        ),
        artwork: nil,
        visualizer: nil
    ))
    return try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
}

private func streamEndJSON() throws -> String {
    try #require(String(data: JSONEncoder().encode(StreamEndMessage()), encoding: .utf8))
}

// MARK: - Recording clock for server/time receipt-order testing

actor RecordingClockSynchronizer: ClockSyncProtocol {
    private(set) var recordedSamples: [(clientReceived: Int64, serverReceived: Int64, serverTransmitted: Int64)] = []
    private var _hasSynced: Bool = false

    var hasSynced: Bool {
        _hasSynced
    }

    func waitForRecordedSamples(count: Int, timeout: Duration = .seconds(2)) async -> [(
        clientReceived: Int64,
        serverReceived: Int64,
        serverTransmitted: Int64
    )] {
        let deadline = ContinuousClock.now + timeout
        while recordedSamples.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return recordedSamples
    }

    func processServerTime(
        clientTransmitted _: Int64,
        serverReceived: Int64,
        serverTransmitted: Int64,
        clientReceived: Int64
    ) {
        recordedSamples.append((
            clientReceived: clientReceived,
            serverReceived: serverReceived,
            serverTransmitted: serverTransmitted
        ))
        // Sync after the first sample so post-sync chunk tests can advance deterministically.
        if recordedSamples.count >= 1 {
            _hasSynced = true
        }
    }

    func serverTimeToLocal(_ serverTime: Int64) -> Int64 {
        serverTime
    }

    func localTimeToServer(_ localTime: Int64) -> Int64 {
        localTime
    }

    func snapshot() -> TimeFilterSnapshot? {
        TimeFilterSnapshot(
            offset: 0,
            drift: 0,
            lastUpdate: Int64(Date().timeIntervalSince1970 * 1_000_000),
            useDrift: false,
            clientProcessStartAbsolute: Int64(Date().timeIntervalSince1970 * 1_000_000)
        )
    }

    func diagnosticSnapshot() -> ClockSynchronizer.DiagnosticSnapshot? {
        nil
    }
}
