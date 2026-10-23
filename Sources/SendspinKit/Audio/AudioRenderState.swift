import AudioToolbox
import Foundation

/// Maximum frame size: 8 channels × 4 bytes per sample.
let maxFrameBytes = 8 * MemoryLayout<Int32>.size

/// Mutable render state owned by AudioPlayer's lock. Do not copy: the ring and
/// last-frame storage own allocations that must be released exactly once.
struct AudioRenderState: @unchecked Sendable {
    var pcmRingBuffer: PCMRingBuffer
    var frameSize: Int = 0
    var timestampSpans: PCMTimestampSpans
    var mappingGeneration: UInt64 = 0
    private var renderLocalTime: Int64?
    private var renderLocalRemainder: Int64 = 0
    private var needsPlacement = false
    private var acceptedEnd: PCMTimestampSpan?

    init(pcmRingBuffer: PCMRingBuffer) {
        self.pcmRingBuffer = pcmRingBuffer
        // Reject new PCM before either bounded store would overflow.
        timestampSpans = PCMTimestampSpans(capacity: min(pcmRingBuffer.capacity, 4_096))
    }

    mutating func clearPCM() {
        pcmRingBuffer.reset()
        timestampSpans.reset()
        acceptedEnd = nil
        mappingGeneration &+= 1
        cursorMicroseconds = 0
        cursorRemainder = 0
        renderLocalTime = nil
        renderLocalRemainder = 0
        needsPlacement = false
        reanchorRequested = false
        pendingReanchorServerTime = 0
        resetCorrection()
    }

    private mutating func resetCorrection() {
        correctionSchedule = CorrectionSchedule()
        dropCounter = 0
        insertCounter = 0
        lastFrameValid = false
    }

    @discardableResult
    mutating func enqueuePCM(_ data: Data, serverTimestamp: Int64, localPlayTime _: Int64? = nil, timelineAdjustmentUs: Int64? = nil) -> Int {
        guard frameSize > 0, sampleRate > 0 else { return 0 }
        let frames = min(data.count / frameSize, pcmRingBuffer.availableToWrite / frameSize)
        guard frames > 0 else { return 0 }
        // Reject an unrepresentable source endpoint before writing either bounded store.
        let duration = Int64(frames) * 1_000_000
        let endpoint = serverTimestamp.addingReportingOverflow((duration + Int64(sampleRate) - 1) / Int64(sampleRate))
        guard !endpoint.overflow else { return 0 }
        var span = PCMTimestampSpan(
            frames: frames, serverTime: serverTimestamp, timelineAdjustmentUs: timelineAdjustmentUs,
            generation: mappingGeneration
        )
        let continuous = acceptedEnd.map { PCMTimestampSpans.isContinuous(span, after: $0, sampleRate: sampleRate) } ?? false
        if continuous, let acceptedEnd {
            span.serverTime = acceptedEnd.serverTime
            span.remainder = acceptedEnd.remainder
        }
        guard timestampSpans.canAppend(span, sampleRate: sampleRate) else { return 0 }
        if timestampSpans.first == nil {
            needsPlacement = true
            if !continuous {
                resetCorrection()
            }
        }
        let written = data.withUnsafeBytes { bytes in
            pcmRingBuffer.write(from: bytes.baseAddress!, count: frames * frameSize)
        }
        timestampSpans.append(span, sampleRate: sampleRate)
        acceptedEnd = span
        acceptedEnd?.advance(frames, sampleRate: sampleRate)
        if let first = timestampSpans.first {
            cursorMicroseconds = first.serverTime
            cursorRemainder = first.remainder
        }
        return written
    }

    private mutating func consumeTimestamp(_ frames: Int) {
        guard let end = timestampSpans.consume(frames, sampleRate: sampleRate) else {
            for _ in 0 ..< frames {
                advanceCursor()
            }
            return
        }
        framesConsumed += Int64(frames)
        let next = timestampSpans.first ?? end
        cursorMicroseconds = next.serverTime
        cursorRemainder = next.remainder
        if end.frames == 0, let next = timestampSpans.first,
           !PCMTimestampSpans.isContinuous(next, after: end, sampleRate: sampleRate) {
            needsPlacement = true
            resetCorrection()
        }
    }

    private func waitFrames(_ span: PCMTimestampSpan, remaining: Int) -> Int {
        guard let now = renderLocalTime, let snapshot = timeSnapshot else { return 0 }
        let target = snapshot.localTimeToServer(now.saturatingAdding(outputDelayUs)
            .saturatingSubtracting(span.timelineAdjustmentUs ?? 0))
        let drift = snapshot.useDrift ? snapshot.drift : 0
        let scale = 1 + drift
        guard scale.isFinite, scale > 0 else { return 0 }
        let delta = Double(span.serverTime.saturatingSubtracting(target))
            + Double(span.remainder) / Double(sampleRate)
            - Double(renderLocalRemainder) / Double(sampleRate) * scale
        guard delta > 1 else { return 0 }
        return max(1, Int(min(Double(remaining), ceil(delta * Double(sampleRate) / (1_000_000 * scale)))))
    }

    mutating func trimStalePCM(at localTarget: Int64) {
        var trimmed = false
        while let span = timestampSpans.first, let snapshot = timeSnapshot {
            let target = snapshot.localTimeToServer(localTarget.saturatingAdding(outputDelayUs).saturatingSubtracting(span.timelineAdjustmentUs ?? 0))
            let gap = target.saturatingSubtracting(span.serverTime)
            guard gap > 0 else { break }
            let boundedGap = min(gap, Int64(span.frames) * 1_000_000 / Int64(sampleRate) + 1)
            let numerator = boundedGap * Int64(sampleRate) - span.remainder
            guard numerator > Int64(sampleRate) else { break }
            let frames = min(span.frames, Int((numerator + 999_999) / 1_000_000))
            if !trimmed {
                resetCorrection()
                flowDiagnostics.reanchors += 1
                trimmed = true
            }
            pcmRingBuffer.skip(frames * frameSize)
            flowDiagnostics.clearedFrames += Int64(frames)
            consumeTimestamp(frames)
        }
        needsPlacement = false
    }

    var lastFrameStorage: UnsafeMutableRawBufferPointer =
        .allocate(byteCount: maxFrameBytes, alignment: 8)
    var lastFrameValid: Bool = false

    var correctionSchedule = CorrectionSchedule()
    var dropCounter: UInt32 = 0
    var insertCounter: UInt32 = 0
    var syncPlanner = CorrectionPlanner()
    var timeSnapshot: TimeFilterSnapshot?
    var lastSyncErrorUs: Int64 = 0
    var pendingReanchorServerTime: Int64 = 0
    var reanchorRequested: Bool = false
    var correctionGraceFrames: Int64 = 0

    var cursorMicroseconds: Int64 = 0
    var cursorRemainder: Int64 = 0
    var sampleRate: Int = 0
    var framesConsumed: Int64 = 0
    var deviceLatencyUs: Int64 = 0
    var outputDelayUs: Int64 = 0
    var queueStartAbsoluteUs: Int64 = 0
    var totalFramesEnqueued: Int64 = 0
    var callbackDepth = CallbackDepthTelemetry()
    var lastMeasuredDepthFrames: Int64?
    var startupLateUs: Int64 = 0

    mutating func resetDepthTelemetry() {
        callbackDepth = CallbackDepthTelemetry()
        lastMeasuredDepthFrames = nil
        startupLateUs = 0
    }

    var enqueuedBufferCount: Int64 = 0
    var draining = false
    var drainComplete = false
    var drainTailBuffer: AudioQueueBufferRef?
    var prewarming: Bool = true
    var spinUpUs: Int64 = -1
    var startupPadFrames: Int64 = 0
    var enqueueFailures: Int64 = 0
    var silentBufferCount: Int64 = 0
    var peakOutputLevel: Float = 0
    var startupOffsetUs: Int64?
    var underrunCount: Int64 = 0
    var pcmBytesDropped: Int64 = 0
    var flowDiagnostics = PCMFlowDiagnostics()
    var processCallbackFormat: AudioFormatSpec?

    mutating func advanceCursor() {
        guard sampleRate > 0 else { return }
        let usPerFrame = 1_000_000 / Int64(sampleRate)
        let usRemainder = 1_000_000 % Int64(sampleRate)

        cursorMicroseconds += usPerFrame
        cursorRemainder += usRemainder
        if cursorRemainder >= Int64(sampleRate) {
            cursorRemainder -= Int64(sampleRate)
            cursorMicroseconds += 1
        }
        framesConsumed += 1
    }

    mutating func recordMissingFrames(_ count: Int64) {
        underrunCount += 1
        flowDiagnostics.missingFrames += count
    }

    mutating func deallocateResources() {
        pcmRingBuffer.deallocate()
        timestampSpans.deallocate()
        lastFrameStorage.deallocate()
    }

    mutating func updateCorrectionSchedule(
        localNow: Int64,
        capacity: Int,
        frameSize: Int,
        sampleRate: Int,
        inFlightAtCallback: Int64?
    ) {
        guard cursorMicroseconds > 0, let snapshot = timeSnapshot else { return }
        let queueDepthUs = Int64(audioQueueBufferCount * capacity) * 1_000_000 / Int64(sampleRate * frameSize)
        let pipelineLatencyUs = AudioPlayer.correctionPipelineLatencyUs(
            inFlightFrames: inFlightAtCallback, sampleRate: sampleRate,
            modelledQueueDepthUs: queueDepthUs, deviceLatencyUs: deviceLatencyUs
        )
        let equilibriumServerTime = AudioPlayer.correctionEquilibriumServerTime(
            snapshot: snapshot,
            localNow: localNow,
            pipelineLatencyUs: pipelineLatencyUs,
            outputDelayUs: outputDelayUs
        )
        let targetServerTime = timestampSpans.first.map { span in
            snapshot.localTimeToServer(localNow.saturatingAdding(pipelineLatencyUs)
                .saturatingAdding(outputDelayUs).saturatingSubtracting(span.timelineAdjustmentUs ?? 0))
        } ?? equilibriumServerTime
        let syncErrorUs = targetServerTime.saturatingSubtracting(cursorMicroseconds)
        lastSyncErrorUs = syncErrorUs

        let framesInBuffer = capacity / frameSize
        var graceExpiredThisCallback = false
        if correctionGraceFrames > 0 {
            correctionGraceFrames -= Int64(framesInBuffer)
            if correctionGraceFrames <= 0 {
                // Only consuming source PCM can advance its timestamp or fractional remainder.
                startupOffsetUs = syncErrorUs
                correctionSchedule = CorrectionSchedule()
                dropCounter = 0
                insertCounter = 0
                graceExpiredThisCallback = true
            }
        }

        let newSchedule: CorrectionSchedule = if correctionGraceFrames > 0 || graceExpiredThisCallback {
            CorrectionSchedule()
        } else {
            syncPlanner.plan(
                errorMicroseconds: syncErrorUs,
                sampleRate: UInt32(sampleRate),
                currentlyCorrecting: correctionSchedule.isCorrecting
            )
        }

        renderLocalTime = localNow.saturatingAdding(pipelineLatencyUs)
        renderLocalRemainder = 0
        if newSchedule.reanchor || reanchorRequested {
            resetCorrection()
            trimStalePCM(at: renderLocalTime!)
            reanchorRequested = false
        } else if newSchedule != correctionSchedule {
            let wasActive = correctionSchedule.isCorrecting
            correctionSchedule = newSchedule
            if newSchedule.isCorrecting, !wasActive {
                // Start a new correction only after its full cadence has elapsed.
                dropCounter = newSchedule.dropEveryNFrames
                insertCounter = newSchedule.insertEveryNFrames
            }
        }
    }

    private mutating func advanceRenderTime(_ frames: Int) {
        guard let renderLocalTime else { return }
        let total = renderLocalRemainder + Int64(frames) * 1_000_000
        self.renderLocalTime = renderLocalTime.saturatingAdding(total / Int64(sampleRate))
        renderLocalRemainder = total % Int64(sampleRate)
    }

    mutating func fillFrames(into dest: UnsafeMutablePointer<UInt8>, capacity: Int) -> Int {
        let fs = frameSize
        var outOffset = 0
        var checkEligibility = true
        guard fs > 0 else { return 0 }
        while outOffset + fs <= capacity {
            if needsPlacement, let now = renderLocalTime {
                let before = framesConsumed
                trimStalePCM(at: now)
                if startupOffsetUs == nil {
                    startupLateUs = max(startupLateUs, (framesConsumed - before) * 1_000_000 / Int64(sampleRate))
                }
                needsPlacement = false
            }
            let waiting = checkEligibility ? timestampSpans.first.map {
                waitFrames($0, remaining: (capacity - outOffset) / fs)
            } ?? 0 : 0
            if waiting > 0 {
                let frames = waiting
                if startupOffsetUs == nil {
                    startupPadFrames += Int64(frames)
                }
                memset(dest + outOffset, 0, frames * fs)
                outOffset += frames * fs
                advanceRenderTime(frames)
                resetCorrection()
                continue
            }
            checkEligibility = false
            if correctionSchedule.dropEveryNFrames > 0 {
                dropCounter = dropCounter > 0 ? dropCounter - 1 : 0
                if dropCounter == 0 {
                    dropCounter = correctionSchedule.dropEveryNFrames
                    if pcmRingBuffer.availableToRead >= fs {
                        pcmRingBuffer.skip(fs)
                        flowDiagnostics.correctionDrops += 1
                        let boundary = timestampSpans.first?.frames == 1
                        consumeTimestamp(1)
                        if boundary {
                            checkEligibility = true
                            continue
                        }
                    }
                }
            }

            if correctionSchedule.insertEveryNFrames > 0 {
                insertCounter = insertCounter > 0 ? insertCounter - 1 : 0
                if insertCounter == 0 {
                    insertCounter = correctionSchedule.insertEveryNFrames
                    if lastFrameValid {
                        memcpy(dest + outOffset, lastFrameStorage.baseAddress!, fs)
                    } else {
                        memset(dest + outOffset, 0, fs)
                    }
                    outOffset += fs
                    advanceRenderTime(1)
                    continue
                }
            }

            if pcmRingBuffer.availableToRead >= fs {
                pcmRingBuffer.read(into: dest + outOffset, count: fs)
                memcpy(lastFrameStorage.baseAddress!, dest + outOffset, fs)
                lastFrameValid = true
                checkEligibility = timestampSpans.first?.frames == 1
                consumeTimestamp(1)
                advanceRenderTime(1)
                outOffset += fs
            } else {
                if !prewarming {
                    recordMissingFrames(Int64((capacity - outOffset) / fs))
                }
                break
            }
        }
        return outOffset
    }
}
