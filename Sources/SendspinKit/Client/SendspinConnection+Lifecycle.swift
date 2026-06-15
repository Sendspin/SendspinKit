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

        if let hello = parsedHello {
            // Multi-server handoff: the facade already sent client/hello and read
            // this server/hello during arbitration. Process it; do not re-send hello.
            await handleServerHello(hello)
        } else {
            // Normal path: client/hello must be the first message (spec §103).
            do {
                try await sendWrapped(ClientHelloMessage(payload: clientHelloPayload))
            } catch {
                disconnectReason = disconnectReason ?? .connectionLost
                return
            }
        }

        while let frame = await transport.nextFrame() {
            // Stamp arrival time immediately after nextFrame() returns.
            let clientReceived = MonotonicClock.nowMicroseconds()

            // Route based on frame type
            switch frame {
            case let .text(json):
                await route(text: json, clientReceived: clientReceived)

            case let .binary(data):
                await route(binary: data)
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
                // Send failure; stop the loop (connection lost)
                break
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
                try? await sendClientStateIfChanged()

            case let .started(format):
                // Successful start: restore to synchronized after an earlier error.
                clientOperationalState = .synchronized
                controlSink.enqueue(.streamStarted(format))
                controlSink.enqueue(.operationalState(.synchronized))
                try? await sendClientStateIfChanged()

            case let .formatApplied(format):
                controlSink.enqueue(.streamFormatChanged(format))

            case let .startFailed(reason):
                // Audio start failed: emit error and stay in error state
                let error = StreamingError.audioStartFailed(reason)
                clientOperationalState = .error
                controlSink.enqueue(.streamError(error))
                controlSink.enqueue(.operationalState(.error))
                try? await sendClientStateIfChanged()
            }
        }
    }

    /// Main supervisor: run the three child loops, await the first to finish,
    /// then cancel the rest.
    func runLoop() async {
        await withTaskGroup(of: Void.self) { group in
            // The message loop owns the handshake; clock sync is started from
            // handleServerHello once server/hello arrives (spec §104), not here.
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
        guard lifecycle == .running || lifecycle == .shuttingDown else { return }
        lifecycle = .shuttingDown

        // Invalidate the token
        validity.invalidate()

        // Stop the engine (async cleanup: close output, finish channels)
        await audioEngine.shutdown()

        // Emit exactly one .disconnected (terminal event)
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
        lifecycle = .stopped
        validity.invalidate()
        controlSink.finish()
        await transport.disconnect()
    }
}
