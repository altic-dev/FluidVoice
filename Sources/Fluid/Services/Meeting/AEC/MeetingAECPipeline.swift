@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Serial-owner AEC3 streaming core. The runtime calls every method on the one shared SCK sample
/// queue, so extraction, joining, bridge calls, reset, and emission ordering cannot overlap.
final nonisolated class MeetingAECPipeline: @unchecked Sendable {
    private var joiner = MeetingAECStreamJoiner()
    private let processor: any MeetingAECProcessing
    let committer: MeetingAECOutputCommitter
    private(set) var stopped = false

    init(
        processor: any MeetingAECProcessing,
        committer: MeetingAECOutputCommitter
    ) {
        self.processor = processor
        self.committer = committer
    }

    func consumeRender(_ sampleBuffer: CMSampleBuffer, stream: MeetingAECStreamToken) {
        guard !self.stopped else { return }
        switch MeetingAECPCMAdapter.extract(sampleBuffer, kind: .render, stream: stream) {
        case let .success(block):
            self.handle(self.joiner.append(block))
        case let .failure(failure):
            self.handleInputFailure(failure, currentRawCapture: nil)
        }
    }

    func consumeCapture(_ sampleBuffer: CMSampleBuffer, stream: MeetingAECStreamToken) {
        guard !self.stopped else {
            self.committer.commitRaw(sampleBuffer, failure: .stopped)
            return
        }
        switch MeetingAECPCMAdapter.extract(sampleBuffer, kind: .capture, stream: stream) {
        case let .success(block):
            self.handle(self.joiner.append(block))
        case let .failure(failure):
            self.handleInputFailure(failure, currentRawCapture: sampleBuffer)
        }
    }

    /// Validates an armed callback without feeding it to a future epoch. The callback remains on
    /// the byte-identical raw path; AEC begins only with subsequent callbacks after both inputs pass.
    /// Returns the precise extraction failure so the armed gate demotes with the real cause.
    static func firstFormatFailure(
        _ sampleBuffer: CMSampleBuffer,
        kind: MeetingAECInputKind,
        stream: MeetingAECStreamToken
    ) -> MeetingAECFailure? {
        if case let .failure(failure) = MeetingAECPCMAdapter.extract(sampleBuffer, kind: kind, stream: stream) {
            return failure
        }
        return nil
    }

    func invalidate(
        reason: MeetingAECFailure,
        boundary: MeetingMicrophoneTranscriptGate.InvalidationBoundary?
    ) {
        guard !self.stopped else { return }
        self.handle(self.joiner.flush(reason: reason))
        self.committer.invalidateForExternalBoundary(boundary)
    }

    func stop(boundary: MeetingMicrophoneTranscriptGate.InvalidationBoundary?) {
        guard !self.stopped else { return }
        self.handle(self.joiner.flush(reason: .stopped))
        self.committer.invalidateForExternalBoundary(boundary)
        self.stopped = true
    }

    private func handleInputFailure(
        _ failure: MeetingAECFailure,
        currentRawCapture: CMSampleBuffer?
    ) {
        self.handle(self.joiner.flush(reason: failure))
        if let currentRawCapture {
            self.committer.commitRaw(currentRawCapture, failure: failure)
        }
    }

    private func handle(_ emissions: [MeetingAECJoinerEmission]) {
        var mayContinueProcessing = true
        for emission in emissions {
            switch emission {
            case let .paired(joined):
                if mayContinueProcessing {
                    mayContinueProcessing = self.process(joined)
                } else {
                    self.commitRaw(joined.capture, failure: .bridgeProcessing)
                }
            case let .bypass(slice, failure):
                guard let raw = MeetingAECPCMAdapter.synthesize(
                    samples: slice.samples,
                    presentationTime: slice.presentationTime
                ) else {
                    self.committer.invalidateForExternalBoundary(nil)
                    continue
                }
                self.committer.commitRaw(raw, failure: failure)
            case .reset:
                self.resetProcessor()
                self.committer.invalidateForExternalBoundary(nil)
            }
        }
    }

    @discardableResult
    private func process(_ joined: MeetingAECJoinedFrame) -> Bool {
        do {
            let result = try self.processor.process(
                render: joined.render.samples,
                capture: joined.capture.samples
            )
            guard let output = MeetingAECPCMAdapter.synthesize(
                samples: result.samples,
                presentationTime: joined.capture.presentationTime
            ) else {
                self.commitRawAndReset(joined.capture, failure: .outputSynthesis)
                return false
            }
            let mayPromote = joined.clockAttested
                && joined.pairedFrameCount > MeetingAECConstants.attestationFrames
            self.committer.commitProcessed(output, mayPromote: mayPromote)
            return true
        } catch let failure as MeetingAECFailure {
            self.commitRawAndReset(joined.capture, failure: failure)
            return false
        } catch {
            self.commitRawAndReset(joined.capture, failure: .bridgeProcessing)
            return false
        }
    }

    private func commitRawAndReset(_ capture: MeetingAECFrame, failure: MeetingAECFailure) {
        self.commitRaw(capture, failure: failure)
        self.joiner = MeetingAECStreamJoiner()
        self.resetProcessor()
    }

    private func commitRaw(_ capture: MeetingAECFrame, failure: MeetingAECFailure) {
        if let raw = MeetingAECPCMAdapter.synthesize(
            samples: capture.samples,
            presentationTime: capture.presentationTime
        ) {
            self.committer.commitRaw(raw, failure: failure)
        } else {
            self.committer.invalidateForExternalBoundary(nil)
        }
    }

    private func resetProcessor() {
        do {
            try self.processor.reset()
        } catch {
            self.stopped = true
            self.committer.failTerminal(.bridgeInitialization)
        }
    }
}
