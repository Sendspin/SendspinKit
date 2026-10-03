import Foundation
import os

extension SendspinConnection {
    // MARK: - Message loop

    /// Ordered message loop: pull frames, stamp arrival, classify, route.
    ///
    /// Exits when the transport returns nil (close), triggering supervisor teardown.
    func messageLoop() async {
        await audioEngine.start()
        // Seed the fresh engine only from non-default carried player state: a
        // multi-server switch keeps user/server volume and mute on the facade,
        // but a brand-new connection starts at protocol defaults. Applying the
        // default volume of 100 would be a no-op in software mode, but in
        // hardware mode it writes to the system output device and can raise the
        // user's system volume to maximum.
        if currentVolume != 100 {
            await audioEngine.setGain(Float(currentVolume) / 100.0)
        }
        if currentMuted {
            await audioEngine.setMuted(currentMuted)
        }

        controlSink.enqueue(.serverConnected(ServerInfo(
            serverId: currentServerId ?? "",
            name: serverName,
            trustLevel: pskCategory == .longTerm ? .user : .none,
            activeRoles: activeRoles,
            activities: activities
        )))
        if clockSyncTask == nil {
            clockSyncTask = Task { [weak self] in
                await self?.clockSyncLoop()
            }
        }

        while let frame = await transport.nextFrame() {
            let clientReceived = MonotonicClock.nowMicroseconds()
            guard case let .binary(ciphertext) = frame else {
                disconnectReason = .incompatibleServer
                await transport.disconnect()
                return
            }
            do {
                guard let plaintext = try channel.decryptFrame(ciphertext) else { continue }
                guard let type = plaintext.first else { throw NoiseError.malformedMessage }
                // Ordered decryption/routing and rekey's receive-transport swap make every post-swap frame new-key.
                // Only server/activate is allowed before activation; old-key frames fail AEAD before this guard.
                if awaitingRehandshakeActivation,
                   type != NoiseFrameType.json
                   || SendspinEncoding.messageType(of: Data(plaintext.dropFirst())) != ServerActivateMessage.typeString {
                    disconnectReason = .incompatibleServer
                    await transport.disconnect()
                    return
                }
                let applicationArrival = MonotonicClock.absoluteMicroseconds()
                if type == NoiseFrameType.json {
                    await route(text: String(bytes: plaintext.dropFirst(), encoding: .utf8) ?? "", clientReceived: clientReceived)
                } else if type == BinaryMessageType.audioChunk.rawValue {
                    guard let message = BinaryMessage(data: plaintext) else {
                        disconnectReason = .incompatibleServer
                        await transport.disconnect()
                        return
                    }
                    await handleAudioChunk(message, arrival: applicationArrival)
                } else {
                    await route(binary: plaintext, arrival: applicationArrival)
                }
            } catch let error as NoiseError {
                Log.client.error("Noise frame rejected: \(String(describing: error))")
                disconnectReason = .incompatibleServer
                await transport.disconnect()
                return
            } catch {
                disconnectReason = .incompatibleServer
                await transport.disconnect()
                return
            }
        }
    }

    /// Clock sync loop: continuous background sampling.
    /// Cancellation-cooperative via Task.sleep.
    func clockSyncLoop() async {
        var sampleCount: UInt32 = 0
        while !Task.isCancelled {
            // Send client/time samples. The clock sync itself is handled by
            // processServerTime in the message loop. This loop just keeps the
            // sampling going with the tuned double-tap cadence: first 2 samples
            // ~10ms apart (for quick filter initialization), then 1s steady-state.
            do {
                let now = MonotonicClock.nowMicroseconds()
                try await sendWrapped(ClientTimeMessage(payload: ClientTimePayload(clientTransmitted: now)))
                sampleCount = sampleCount &+ 1
            } catch {
                // The re-handshake gate rejects sends transiently — sampling must
                // resume once the exchange completes. Only a terminal teardown
                // (which sets shuttingDown) ends the loop.
                if shuttingDown || lifecycle != .running {
                    break
                }
            }

            // First two samples 10 ms apart so the filter's count==1→2
            // branch fires quickly (that branch initializes drift from the
            // finite difference between the first two samples); then relax
            // to a 1-second cadence.
            let delay: Duration = sampleCount < 2
                ? .milliseconds(10)
                : .seconds(1)
            try? await Task.sleep(for: delay)
        }
    }

    /// Report drain: consume engine reports and translate to control events.
    func reportDrain() async {
        for await report in audioEngine.reports {
            switch report {
            case let .operationalState(state):
                clientOperationalState = state
                controlSink.enqueue(.operationalState(state))
                // Send client/state on every operational state change
                try? await publishClientState()

            case let .started(format, generation):
                guard playerStartState == .pending(generation) else {
                    Log.client.debug("Ignoring stale player start report generation=\(generation)")
                    continue
                }
                // Report drain and message loop are sibling tasks; identity protects newer announcements.
                playerStartState = .started(generation)
                controlSink.enqueue(.streamStarted(format))
                if clientOperationalState == .error {
                    // Successful start: restore to synchronized after an earlier error.
                    clientOperationalState = .synchronized
                    controlSink.enqueue(.operationalState(.synchronized))
                    try? await publishClientState()
                }

            case let .formatApplied(format, generation):
                guard playerStartState == .pending(generation) else {
                    Log.client.debug("Ignoring stale player format report generation=\(generation)")
                    continue
                }
                playerStartState = .started(generation)
                controlSink.enqueue(.streamFormatChanged(format))
                if clientOperationalState == .error {
                    clientOperationalState = .synchronized
                    controlSink.enqueue(.operationalState(.synchronized))
                    try? await publishClientState()
                }

            case let .startFailed(reason, generation):
                guard playerStartState == .pending(generation) else {
                    Log.client.debug("Ignoring stale player failure report generation=\(generation)")
                    continue
                }
                playerStartState = .failed(generation)
                // Audio start failed: emit error and stay in error state
                let error = StreamingError.audioStartFailed(reason)
                clientOperationalState = .error
                controlSink.enqueue(.streamError(error))
                controlSink.enqueue(.operationalState(.error))
                try? await publishClientState()
            }
        }
    }

    /// Main supervisor: run the three child loops, await the first to finish,
    /// then cancel the rest.
    func runLoop() async {
        await withTaskGroup(of: Void.self) { group in
            // The message loop owns post-handoff sequencing; clock sync starts
            // when the loop begins.
            group.addTask { await self.messageLoop() }
            group.addTask { await self.reportDrain() }

            // Wait for the first to finish (normally the message loop on EOF)
            _ = await group.next()

            // Transport/session closure is the release mechanism for a parked
            // `nextFrame()`. If a sibling loop exits first, close the transport
            // before cancellation so the message loop observes EOF instead of
            // relying on task cancellation to unwind FrameInbox internals.
            await transport.disconnect()

            // Cancel the rest
            group.cancelAll()

            // Drain the group to ensure all tasks complete
            while await group.next() != nil {}
        }

        // Stop the unstructured clock-sync task (cancellation-cooperative) and wait
        // for it to finish so it cannot outlive the connection.
        clockSyncTask?.cancel()
        await clockSyncTask?.value
        clockSyncTask = nil
    }

    /// Finalize teardown: invalidate token, stop engine, emit one .disconnected.
    ///
    /// Runs only once (lifecycle-guarded) and only after runLoop() returns,
    /// so no frame can reach a finished engine channel.
    func finishTeardown(_ reason: DisconnectReason) async {
        let teardownStartedAt = MonotonicClock.absoluteMicroseconds()
        guard lifecycle == .running || lifecycle == .shuttingDown else { return }
        lifecycle = .shuttingDown

        stopOutputFormatNegotiation()

        // Invalidate both the session and any queued visualizer frames.
        validity.invalidate()
        visualizerFrameValidity.invalidate()
        if let dataDelivery {
            dataDelivery.clearVisualizer()
        } else {
            visualizerDelivery?.clear()
        }
        if pairingAttemptID != nil {
            enqueuePairingCode(nil)
        }
        pairingAttemptTask?.cancel()
        closePairingWindow()
        pairingAttemptActive = false
        pendingPairingPsk = nil
        dynamicPairingAttempt = nil
        staticPairingAttempt = nil
        pairingAttemptID = nil
        pairingAttemptPeer = nil
        pairingAttemptTask?.cancel()
        if let lease = pairingProtectionLease {
            pairingProtectionLease = nil
            do {
                try await pairingStore?.releaseProtection(lease)
            } catch {
                Log.client.error("Pairing protection release failed: \(error.localizedDescription)")
            }
        }

        // Stop the engine (async cleanup: close output, finish channels)
        let engineStartedAt = MonotonicClock.absoluteMicroseconds()
        await audioEngine.shutdown()
        let engineUs = MonotonicClock.absoluteMicroseconds() - engineStartedAt

        // Emit exactly one .disconnected (terminal event)
        let teardownUs = MonotonicClock.absoluteMicroseconds() - teardownStartedAt
        Log.client.info(
            """
            teardown: engine=\(engineUs, privacy: .public)us total=\(teardownUs, privacy: .public)us \
            reason=\(String(describing: reason), privacy: .public)
            """
        )
        controlSink.enqueue(.disconnected(reason: reason))

        // Finish the control stream
        controlSink.finish()

        lifecycle = .stopped
    }

    /// Terminal teardown for a connection that never started. `lifecycle = .stopped`
    /// lands before the first await so a concurrent `start()` cannot sneak a session
    /// past an already-issued disconnect/shutdown. No `.disconnected` is emitted:
    /// the facade installs its drain only after `start()`, so no consumer exists.
    func teardownFromIdle() async {
        stopOutputFormatNegotiation()
        lifecycle = .stopped
        validity.invalidate()
        visualizerFrameValidity.invalidate()
        if let lease = pairingProtectionLease {
            pairingProtectionLease = nil
            do {
                try await pairingStore?.releaseProtection(lease)
            } catch {
                Log.client.error("Pairing protection release failed: \(error.localizedDescription)")
            }
        }
        if let dataDelivery {
            dataDelivery.clearVisualizer()
        } else {
            visualizerDelivery?.clear()
        }
        controlSink.finish()
        await transport.disconnect()
    }
}
