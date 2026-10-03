import Foundation

enum OutputFormatStreamStartDecision: Sendable {
    case rejected
    case accepted(AudioFormatTransitionPolicy?)
}

struct PendingOutputFormatRequest: Sendable, Equatable {
    enum Origin: Sendable, Equatable {
        case automatic
        case application
    }

    let target: AudioFormatSpec
    let origin: Origin
    let generation: UInt64
    let routeEpoch: UInt64
}

extension SendspinConnection {
    /// Publish an application-selected player format in the full client/state snapshot.
    /// The server re-evaluates an active stream or remembers the preference for the next one.
    func setPlayerFormatPreference(codec: AudioCodec?, channels: Int?, sampleRate: Int?, bitDepth: Int?) async throws {
        let target = try matchingEffectiveFormat(codec: codec, channels: channels, sampleRate: sampleRate, bitDepth: bitDepth)
        try await applyPlayerFormatPreference(target)
    }

    func applyPlayerFormatPreference(_ target: AudioFormatSpec?) async throws {
        let previousPreference = preferredPlayerFormat
        let previousPending = pendingOutputFormatRequest
        let previousSuppression = automaticRequestsSuppressed
        let previousDeadline = outputRequestDeadlineTask
        if let target {
            outputNegotiationGeneration &+= 1
            pendingOutputFormatRequest = PendingOutputFormatRequest(
                target: target,
                origin: .application,
                generation: outputNegotiationGeneration,
                routeEpoch: outputRouteEpoch
            )
            automaticRequestsSuppressed = true
            outputRequestDeadlineTask?.cancel()
            outputRequestDeadlineTask = nil
        } else {
            pendingOutputFormatRequest = nil
            automaticRequestsSuppressed = false
        }
        preferredPlayerFormat = target
        do {
            try await publishClientState()
        } catch {
            preferredPlayerFormat = previousPreference
            pendingOutputFormatRequest = previousPending
            automaticRequestsSuppressed = previousSuppression
            if let previousPending {
                armOutputRequestDeadline(generation: previousPending.generation)
            } else {
                outputRequestDeadlineTask = nil
                previousDeadline?.cancel()
            }
            publishTruthfulOutputFormatStatus()
            throw error
        }
        if let target {
            publishOutputFormatStatus(.requesting(target))
            armOutputRequestDeadline(generation: outputNegotiationGeneration)
        } else {
            publishTruthfulOutputFormatStatus()
        }
    }

    /// Publish one artwork channel preference in the full client/state snapshot.
    func setArtworkChannelPreference(channel: Int, preference: ArtworkChannelPreference) async throws {
        guard var channels = artworkState?.channels else {
            throw ConfigurationError.artworkStateUnavailable
        }
        guard channels.indices.contains(channel) else {
            throw ConfigurationError.artworkChannelOutOfRange(channel)
        }
        switch preference {
        case .disable:
            channels[channel] = try ArtworkStateChannel(source: .none)
        case let .set(source, format, width, height):
            guard source != .none else {
                throw ConfigurationError.invalidArtworkStateChannel
            }
            channels[channel] = try ArtworkStateChannel(source: source, format: format, width: width, height: height)
        }
        artworkState = try ArtworkStateObject(channels: channels)
        try await publishClientState()
    }

    func setVisualizerPreference(_ preference: VisualizerStateObject) async throws {
        try requireActiveRole(.visualizerV1)
        let previousPreference = visualizerState
        visualizerState = preference
        do {
            try await publishClientState()
        } catch {
            visualizerState = previousPreference
            throw error
        }
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
        let activeSampleRate = announcedPlayerStream?.format.sampleRate
        if playerStreamActive, let activeSampleRate, sampleRate != activeSampleRate {
            outputRouteEpoch &+= 1
            routeInvalidationPending = true
            audioEngine.beginRouteInvalidation()
        }
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

    func handleOutputFormatStreamStart(_ format: AudioFormatSpec) async -> OutputFormatStreamStartDecision {
        if outputSampleRatePolicy == .requireCurrentOutput {
            guard let outputRate = settledOutputSampleRate else {
                await failOutputFormat(.routeUnavailable)
                return .rejected
            }
            guard format.sampleRate == outputRate, effectivePlayerFormats?.contains(format) == true else {
                await failOutputFormat(.noMatchingFormat)
                return .rejected
            }
        }

        outputRequestDeadlineTask?.cancel()
        outputRequestDeadlineTask = nil
        var transitionPolicy: AudioFormatTransitionPolicy?
        if let pending = pendingOutputFormatRequest {
            pendingOutputFormatRequest = nil
            if pending.target != format {
                handledAutomaticSampleRate = settledOutputSampleRate
            }
        }
        if routeInvalidationPending,
           format.sampleRate == outputSnapshot?.sampleRate {
            transitionPolicy = .routeInvalidated
            routeInvalidationPending = false
        }
        publishTruthfulOutputFormatStatus(activeFormat: format)
        await requestAutomaticFormatIfNeeded(sampleRate: settledOutputSampleRate)
        return .accepted(transitionPolicy)
    }

    func resetOutputFormatNegotiationForStreamBoundary() {
        outputNegotiationGeneration &+= 1
        outputSettleTask?.cancel()
        outputSettleTask = nil
        outputRequestDeadlineTask?.cancel()
        outputRequestDeadlineTask = nil
        pendingOutputFormatRequest = nil
        routeInvalidationPending = false
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
            generation: requestGeneration,
            routeEpoch: outputRouteEpoch
        )
        publishOutputFormatStatus(.requesting(target))

        let previousPreference = preferredPlayerFormat
        do {
            preferredPlayerFormat = target
            try await publishClientState()
            armOutputRequestDeadline(generation: requestGeneration)
        } catch {
            preferredPlayerFormat = previousPreference
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
        try? await publishClientState()
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
        if routeInvalidationPending, playerStreamActive, let stream = announcedPlayerStream {
            routeInvalidationPending = false
            playerStartGeneration &+= 1
            playerStartState = .pending(playerStartGeneration)
            audioEngine.enqueueRouteInvalidatedFormatChange(
                format: stream.format, codecHeader: stream.codecHeader, startGeneration: playerStartGeneration
            )
        }
        publishTruthfulOutputFormatStatus()
    }

    private func matchingEffectiveFormat(codec: AudioCodec?, channels: Int?, sampleRate: Int?, bitDepth: Int?) throws -> AudioFormatSpec {
        guard codec != nil || channels != nil || sampleRate != nil || bitDepth != nil else {
            throw OutputFormatError.noMatchingFormat
        }
        guard let format = effectivePlayerFormats?.first(where: { format in
            (codec == nil || codec == format.codec)
                && (channels == nil || channels == format.channels)
                && (sampleRate == nil || sampleRate == format.sampleRate)
                && (format.codec == .opus || bitDepth == nil || bitDepth == format.bitDepth)
        }) else {
            throw OutputFormatError.noMatchingFormat
        }
        return format
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
