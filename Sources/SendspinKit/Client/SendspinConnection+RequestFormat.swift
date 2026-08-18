import Foundation

struct PendingOutputFormatRequest: Sendable, Equatable {
    enum Origin: Sendable, Equatable {
        case automatic
        case application
    }

    let target: AudioFormatSpec
    let origin: Origin
    let generation: UInt64
}

extension SendspinConnection {
    /// Send an application-initiated `stream/request-format` for the player role.
    /// Explicit application intent supersedes automatic route negotiation and
    /// suppresses more automatic requests until the next player stream boundary.
    func requestFormat(player request: PlayerFormatRequest) async throws {
        let target = try matchingEffectiveFormat(for: request)
        let previousPendingRequest = pendingOutputFormatRequest
        let previousAutomaticRequestsSuppressed = automaticRequestsSuppressed

        outputNegotiationGeneration &+= 1
        outputSettleTask?.cancel()
        outputSettleTask = nil
        outputRequestDeadlineTask?.cancel()
        outputRequestDeadlineTask = nil
        automaticRequestsSuppressed = true
        let requestGeneration = outputNegotiationGeneration
        pendingOutputFormatRequest = PendingOutputFormatRequest(
            target: target,
            origin: .application,
            generation: requestGeneration
        )
        publishOutputFormatStatus(.requesting(target))

        do {
            try await sendPlayerFormatRequest(request)
            armOutputRequestDeadline(generation: requestGeneration)
        } catch {
            if pendingOutputFormatRequest?.generation == requestGeneration {
                automaticRequestsSuppressed = previousAutomaticRequestsSuppressed
                pendingOutputFormatRequest = previousPendingRequest
                if let outputSnapshot {
                    receiveAudioOutputSnapshot(outputSnapshot, sequence: latestOutputSnapshotSequence)
                }
                if let previousPendingRequest {
                    armOutputRequestDeadline(generation: previousPendingRequest.generation)
                }
                publishTruthfulOutputFormatStatus()
            }
            throw error
        }
    }

    /// Send a `stream/request-format` for the artwork role. See
    /// ``requestFormat(player:)`` for the no-active-stream contract.
    func requestFormat(artwork request: ArtworkFormatRequest) async throws {
        try await send(clientMessage: StreamRequestFormatMessage(
            payload: StreamRequestFormatPayload(artwork: request)
        ))
    }

    /// Seed status once the session handshake is complete. The pre-hello snapshot
    /// is already normalized and remains the initial settled route.
    func activateOutputFormatNegotiation() async {
        guard playerRoleActive, outputSampleRatePolicy != nil else { return }
        publishTruthfulOutputFormatStatus()
        if outputSampleRatePolicy == .requireCurrentOutput {
            await evaluateStrictRouteIfNeeded()
        }
    }

    /// Consume one client-lifetime output snapshot without taking ownership of the
    /// capability provider. Diagnostic-only changes update observability immediately,
    /// while protocol action is coalesced solely by normalized sample rate.
    func receiveAudioOutputSnapshot(_ snapshot: AudioOutputSnapshot, sequence: UInt64) {
        guard lifecycle == .running, playerRoleActive,
              sequence >= latestOutputSnapshotSequence
        else { return }
        latestOutputSnapshotSequence = sequence
        outputSnapshot = snapshot
        publishTruthfulOutputFormatStatus()

        let sampleRate = AudioOutputCapabilityService.normalizedSampleRateKey(for: snapshot)
        guard sampleRate != settledOutputSampleRate else {
            outputNegotiationGeneration &+= 1
            outputSettleTask?.cancel()
            outputSettleTask = nil
            return
        }

        outputNegotiationGeneration &+= 1
        let generation = outputNegotiationGeneration
        outputSettleTask?.cancel()
        let interval = outputSettleInterval
        let sleep = outputNegotiationSleep
        outputSettleTask = Task { [weak self] in
            do {
                try await sleep(interval)
            } catch {
                return
            }
            await self?.settleOutputSampleRate(sampleRate, generation: generation)
        }
    }

    func handleOutputFormatStreamStart(_ format: AudioFormatSpec) async -> Bool {
        if outputSampleRatePolicy == .requireCurrentOutput {
            guard let outputRate = settledOutputSampleRate else {
                await failOutputFormat(.routeUnavailable)
                return false
            }
            guard format.sampleRate == outputRate, effectivePlayerFormats?.contains(format) == true else {
                await failOutputFormat(.noMatchingFormat)
                return false
            }
        }

        outputRequestDeadlineTask?.cancel()
        outputRequestDeadlineTask = nil
        if let pending = pendingOutputFormatRequest {
            pendingOutputFormatRequest = nil
            if pending.target != format {
                handledAutomaticSampleRate = settledOutputSampleRate
            }
        }
        publishTruthfulOutputFormatStatus(activeFormat: format)
        await requestAutomaticFormatIfNeeded(sampleRate: settledOutputSampleRate)
        return true
    }

    func resetOutputFormatNegotiationForStreamBoundary() {
        outputNegotiationGeneration &+= 1
        outputSettleTask?.cancel()
        outputSettleTask = nil
        outputRequestDeadlineTask?.cancel()
        outputRequestDeadlineTask = nil
        pendingOutputFormatRequest = nil
        automaticRequestsSuppressed = false
        handledAutomaticSampleRate = nil
        publishTruthfulOutputFormatStatus()
    }

    func stopOutputFormatNegotiation() {
        outputNegotiationGeneration &+= 1
        outputSettleTask?.cancel()
        outputSettleTask = nil
        outputRequestDeadlineTask?.cancel()
        outputRequestDeadlineTask = nil
        pendingOutputFormatRequest = nil
    }

    private func settleOutputSampleRate(_ sampleRate: Int?, generation: UInt64) async {
        guard generation == outputNegotiationGeneration, lifecycle == .running else { return }
        outputSettleTask = nil
        settledOutputSampleRate = sampleRate
        handledAutomaticSampleRate = nil
        if pendingOutputFormatRequest?.origin == .automatic {
            outputRequestDeadlineTask?.cancel()
            outputRequestDeadlineTask = nil
            pendingOutputFormatRequest = nil
        }
        publishTruthfulOutputFormatStatus()

        guard let policy = outputSampleRatePolicy else { return }
        if policy == .requireCurrentOutput {
            await evaluateStrictRouteIfNeeded()
            return
        }
        await requestAutomaticFormatIfNeeded(sampleRate: sampleRate)
    }

    private func requestAutomaticFormatIfNeeded(sampleRate: Int?) async {
        guard outputSampleRatePolicy == .preferCurrentOutput,
              let sampleRate,
              announcedPlayerStream?.format.sampleRate != sampleRate,
              playerStreamActive,
              pendingOutputFormatRequest == nil,
              !automaticRequestsSuppressed,
              handledAutomaticSampleRate != sampleRate,
              let target = effectivePlayerFormats?.first(where: { $0.sampleRate == sampleRate })
        else { return }

        handledAutomaticSampleRate = sampleRate
        outputNegotiationGeneration &+= 1
        let requestGeneration = outputNegotiationGeneration
        pendingOutputFormatRequest = PendingOutputFormatRequest(
            target: target,
            origin: .automatic,
            generation: requestGeneration
        )
        publishOutputFormatStatus(.requesting(target))

        do {
            try await sendPlayerFormatRequest(PlayerFormatRequest(
                codec: target.codec,
                channels: target.channels,
                sampleRate: target.sampleRate,
                bitDepth: target.bitDepth
            ))
            armOutputRequestDeadline(generation: requestGeneration)
        } catch {
            pendingOutputFormatRequest = nil
            publishTruthfulOutputFormatStatus()
        }
    }

    private func evaluateStrictRouteIfNeeded() async {
        guard outputSampleRatePolicy == .requireCurrentOutput else { return }
        guard let rate = settledOutputSampleRate else {
            await failOutputFormat(.routeUnavailable)
            return
        }
        guard effectivePlayerFormats?.contains(where: { $0.sampleRate == rate }) == true else {
            await failOutputFormat(.noMatchingFormat)
            return
        }
        if let active = announcedPlayerStream?.format, active.sampleRate != rate {
            await failOutputFormat(.noMatchingFormat)
        }
    }

    private func failOutputFormat(_ error: OutputFormatError) async {
        guard lifecycle == .running, !shuttingDown else { return }
        if error == .routeUnavailable {
            publishOutputFormatStatus(.outputUnknown)
        } else {
            publishOutputFormatStatus(.noMatchingFormat)
        }
        clientOperationalState = .error
        controlSink.enqueue(.streamError(.outputFormat(error)))
        controlSink.enqueue(.operationalState(.error))
        try? await sendClientStateIfChanged()
        disconnectReason = .outputFormatRejected(error)
        shuttingDown = true
        await transport.disconnect()
    }

    private func armOutputRequestDeadline(generation: UInt64) {
        outputRequestDeadlineTask?.cancel()
        let timeout = outputRequestTimeout
        let sleep = outputNegotiationSleep
        outputRequestDeadlineTask = Task { [weak self] in
            do {
                try await sleep(timeout)
            } catch {
                return
            }
            await self?.outputRequestTimedOut(generation: generation)
        }
    }

    private func outputRequestTimedOut(generation: UInt64) {
        guard pendingOutputFormatRequest?.generation == generation else { return }
        pendingOutputFormatRequest = nil
        outputRequestDeadlineTask = nil
        handledAutomaticSampleRate = settledOutputSampleRate
        publishTruthfulOutputFormatStatus()
    }

    private func matchingEffectiveFormat(for request: PlayerFormatRequest) throws -> AudioFormatSpec {
        guard request.codec != nil || request.channels != nil || request.sampleRate != nil || request.bitDepth != nil else {
            throw OutputFormatError.noMatchingFormat
        }
        guard let format = effectivePlayerFormats?.first(where: { format in
            (request.codec == nil || request.codec == format.codec)
                && (request.channels == nil || request.channels == format.channels)
                && (request.sampleRate == nil || request.sampleRate == format.sampleRate)
                && (request.bitDepth == nil || request.bitDepth == format.bitDepth)
        }) else {
            throw OutputFormatError.noMatchingFormat
        }
        return format
    }

    private func sendPlayerFormatRequest(_ request: PlayerFormatRequest) async throws {
        try await send(clientMessage: StreamRequestFormatMessage(
            payload: StreamRequestFormatPayload(player: request)
        ))
    }

    private func publishTruthfulOutputFormatStatus(activeFormat: AudioFormatSpec? = nil) {
        guard let output = outputSnapshot else { return }
        let state: OutputFormatStatus.State = if let pending = pendingOutputFormatRequest {
            .requesting(pending.target)
        } else if let active = activeFormat ?? announcedPlayerStream?.format {
            if active.sampleRate == output.sampleRate {
                .activeNative(active)
            } else {
                .activeFallback(active)
            }
        } else if let sampleRate = output.sampleRate {
            if let preferred = effectivePlayerFormats?.first(where: { $0.sampleRate == sampleRate }) {
                .preferred(preferred)
            } else {
                .noMatchingFormat
            }
        } else {
            .outputUnknown
        }
        publishOutputFormatStatus(state)
    }

    private func publishOutputFormatStatus(_ state: OutputFormatStatus.State) {
        guard let output = outputSnapshot else { return }
        let status = OutputFormatStatus(output: output, state: state)
        guard status != outputFormatStatus else { return }
        outputFormatStatus = status
        controlSink.enqueue(.outputFormatStatusChanged(status))
    }
}
