#if DEBUG

import Foundation

nonisolated struct MeetingStage05MockAECObservation: Equatable, Sendable {
    let frameIndex: Int
    let epochID: Int
    let reset: Bool
    let adaptationFrozen: Bool
    let resynchronizationBoundary: Bool
    let renderValidCount: Int
    let captureValidCount: Int
    let unknownReasons: [MeetingSynchronizerUnknownReason]
}

nonisolated struct MeetingStage05MockAECSeamResult: Equatable, Sendable {
    /// Synchronized hops returned unchanged; the mock seam never transforms audio.
    let frames: [MeetingSynchronizedFrame]
    /// Ordering contract events only: render strictly precedes capture per eligible hop.
    let events: [MeetingAECDelayContractEvent]
    /// Numeric contract state only; it contains no samples or user-derived metadata.
    let observations: [MeetingStage05MockAECObservation]
    let processedFrameCount: Int
    let frozenFrameCount: Int
    let boundaryCount: Int
    /// False for a failed-open synchronization result; processing is never authorized.
    let authorized: Bool
}

/// Identity/mock AEC seam. It consumes a synchronization result, checks the AEC-facing
/// ordering contract, and returns audio arrays unchanged. It performs no echo
/// cancellation: no resampling, delay, scaling, suppression, synthesis, or replacement.
nonisolated struct MeetingStage05MockAECSeam: Sendable {
    init() {}

    func process(_ result: MeetingSynchronizationResult) -> MeetingStage05MockAECSeamResult {
        let structuralContract = MeetingAECDelayContract(renderLeadSeconds: 0)
        guard !result.failedOpen,
              structuralContract.validates(synchronizedResult: result),
              result.frames.allSatisfy({ frame in
                  !frame.renderSamples.isEmpty
                      && frame.renderSamples.allSatisfy(\.isFinite)
                      && frame.captureSamples.allSatisfy(\.isFinite)
                      && zip(frame.renderSamples, frame.renderValidMask)
                          .allSatisfy { $0.1 || $0.0 == 0 }
                      && zip(frame.captureSamples, frame.captureValidMask)
                          .allSatisfy { $0.1 || $0.0 == 0 }
              }) else {
            return MeetingStage05MockAECSeamResult(
                frames: result.frames, events: [], observations: [], processedFrameCount: 0,
                frozenFrameCount: 0, boundaryCount: 0, authorized: false)
        }
        var events: [MeetingAECDelayContractEvent] = []
        var observations: [MeetingStage05MockAECObservation] = []
        var processed = 0
        var frozen = 0
        var boundaries = 0
        var previousEpoch: Int?
        // A discontinuity can occur partway through an analysis hop. In that case the
        // synchronizer marks that hop as the reset boundary, while the integer epoch ID
        // advances on the following hop. Remember the already-handled boundary for one
        // hop so the delayed epoch label cannot trigger a duplicate reset/freeze.
        var previousBoundaryAwaitedEpochAdvance = false
        for frame in result.frames {
            // Epoch/reset handling precedes any normal processing for the hop.
            let epochChanged = previousEpoch.map { $0 != frame.epochID } ?? false
            let delayedHandledEpochAdvance = epochChanged
                && previousBoundaryAwaitedEpochAdvance
                && !frame.resynchronizationBoundary
            let reset = frame.resynchronizationBoundary
                || (epochChanged && !delayedHandledEpochAdvance)
            if reset {
                boundaries += 1
            }
            previousBoundaryAwaitedEpochAdvance = frame.resynchronizationBoundary && !epochChanged
            previousEpoch = frame.epochID
            let complete = frame.renderValidMask.allSatisfy { $0 }
                && frame.captureValidMask.allSatisfy { $0 }
            let mustFreeze = reset || !complete || frame.adaptationFrozen
            observations.append(MeetingStage05MockAECObservation(
                frameIndex: frame.index, epochID: frame.epochID, reset: reset,
                adaptationFrozen: mustFreeze,
                resynchronizationBoundary: frame.resynchronizationBoundary,
                renderValidCount: frame.renderValidMask.filter { $0 }.count,
                captureValidCount: frame.captureValidMask.filter { $0 }.count,
                unknownReasons: frame.unknownReasons))
            guard !mustFreeze else {
                frozen += 1
                continue
            }
            events.append(MeetingAECDelayContractEvent(frameIndex: frame.index, kind: .render))
            events.append(MeetingAECDelayContractEvent(frameIndex: frame.index, kind: .capture))
            processed += 1
        }
        return MeetingStage05MockAECSeamResult(
            frames: result.frames, events: events, observations: observations,
            processedFrameCount: processed,
            frozenFrameCount: frozen, boundaryCount: boundaries, authorized: true)
    }
}

#endif
