import Foundation

/// Stage A value contract only. No production call site evaluates or persists this evidence.
/// All times are seconds in the original session capture timeline, never display-adjusted time.
nonisolated struct MeetingMicrophoneEvidence: Equatable, Sendable {
    enum UnknownReason: String, Equatable, Sendable {
        case notMeasured, referenceUnavailable, noDelayLock, unscoredCoverage
        case scoredInconclusive, detectorUnavailable, overBudget, staleEpoch
    }

    enum Measurement<Value: Equatable & Sendable>: Equatable, Sendable {
        case unavailable(UnknownReason)
        case measured(Value)
    }

    struct Interval: Equatable, Sendable {
        let start: Double
        let end: Double
        init?(start: Double, end: Double) {
            guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
            self.start = start
            self.end = end
        }
    }

    struct Fraction: Equatable, Sendable {
        let value: Double
        init?(_ value: Double) {
            guard value.isFinite, (0...1).contains(value) else { return nil }
            self.value = value
        }
    }

    enum Observation: Equatable, Sendable {
        /// Multiple turns can share this key; no individual turn can bless the shared centroid.
        case clusterLabel(String)
        case unavailable
    }

    struct Identity: Equatable, Sendable {
        let sessionID: UUID
        let chunkID: UUID
        let turnIndex: Int
        /// Stage B binds epochs to the pipeline's either-track discontinuity boundaries.
        let captureEpoch: UInt64
        let observation: Observation

        init?(sessionID: UUID, chunkID: UUID, turnIndex: Int, captureEpoch: UInt64, observation: Observation) {
            guard turnIndex >= 0 else { return nil }
            if case .clusterLabel(let label) = observation, label.isEmpty { return nil }
            self.sessionID = sessionID
            self.chunkID = chunkID
            self.turnIndex = turnIndex
            self.captureEpoch = captureEpoch
            self.observation = observation
        }

        var turnKey: String { "microphone:\(chunkID.uuidString):\(turnIndex)" }
        var observationKey: String? {
            guard case .clusterLabel(let label) = observation else { return nil }
            return "microphone:\(chunkID.uuidString):\(label)"
        }
    }

    enum PlaybackContext: Equatable, Sendable {
        case scoreablePlayback, verifiedNoPlayback, playbackExpectedButUnscoreable, unknown
    }

    enum SpeechActivity: Equatable, Sendable {
        /// Activity alone may be leaked playback. It cannot establish near-end speech.
        case detected, notDetected
    }

    enum EmbeddingProvenance: Equatable, Sendable {
        case unavailable, sharedClusterCentroid, independentInterval
    }

    struct TemporalDuplicate: Equatable, Sendable {
        enum State: Equatable, Sendable {
            case insufficientEvidence, observing, duplicateCandidate, duplicateSupported
        }
        let state: State
        let identity: Identity
        let interval: Interval
        let supportingWindows: Int
        /// Convention: positive means microphone follows reference. Not a calibrated threshold.
        let microphoneDelaySeconds: Measurement<Double>
        let lagSpreadSeconds: Measurement<Double>
        let coverage: Fraction
    }

    let identity: Identity
    let interval: Interval
    let playback: PlaybackContext
    let signalVerdict: Measurement<TurnEchoVerdict>
    let textEcho: Measurement<Bool>
    let speechActivity: Measurement<SpeechActivity>
    let speechCoverage: Measurement<Fraction>
    /// Missing and measured zero are distinct. This field is not a speech/no-speech gate.
    let rms: Measurement<Double>
    let temporalDuplicate: Measurement<TemporalDuplicate>
    let embedding: EmbeddingProvenance

    /// Compatibility projection only; detailed unknown reasons survive in the evidence itself.
    var legacySignalVerdict: TurnEchoVerdict {
        guard case .measured(let verdict) = signalVerdict else { return .unknown }
        return verdict
    }
}

/// Stage A seam; the only implementation is a test fake. Stage B owns real paired-audio analysis.
nonisolated protocol MeetingPlaybackDuplicateEvidenceSource: Sendable {
    func evidence(for identity: MeetingMicrophoneEvidence.Identity,
                  interval: MeetingMicrophoneEvidence.Interval) -> MeetingMicrophoneEvidence.Measurement<MeetingMicrophoneEvidence.TemporalDuplicate>
}

/// Test-only caller contract: no runtime enablement flag or production invocation in Stage A.
/// Conservative proposals, NOT calibrated admission. No acceptedSpeech/noSupportedSpeech can
/// be inferred from the Stage A activity/echo inputs alone. It cannot hide text or admit profiles.
nonisolated enum MeetingMicrophoneShadowPolicy {
    enum ProposedOutcome: Equatable, Sendable {
        case uncertainCandidate
    }
    enum Reason: Equatable, Sendable {
        case legacyRescueDisagreement, playbackDuplicateCandidate, speechActivityIsNotNearEndProof
        case negativeActivityIsNotSpeechAbsenceProof, insufficientEvidence
        case staleTemporalEvidence, invalidTemporalEvidence, missingPlaybackContext
    }
    struct Evaluation: Equatable, Sendable {
        let outcome: ProposedOutcome = .uncertainCandidate
        let experimental = true
        let reason: Reason
        let identity: MeetingMicrophoneEvidence.Identity
        let interval: MeetingMicrophoneEvidence.Interval
        /// Exposes provenance gaps instead of collapsing them into a generic unknown.
        let signalUnknownReason: MeetingMicrophoneEvidence.UnknownReason?
    }

    static func evaluate(_ evidence: MeetingMicrophoneEvidence) -> Evaluation {
        func result(_ reason: Reason) -> Evaluation {
            let unknown: MeetingMicrophoneEvidence.UnknownReason?
            if case .unavailable(let why) = evidence.signalVerdict { unknown = why } else { unknown = nil }
            return Evaluation(reason: reason, identity: evidence.identity, interval: evidence.interval,
                              signalUnknownReason: unknown)
        }
        if case .measured(let temporal) = evidence.temporalDuplicate {
            guard temporal.identity == evidence.identity,
                  temporal.interval == evidence.interval else { return result(.staleTemporalEvidence) }
            guard temporal.supportingWindows >= 0 else { return result(.invalidTemporalEvidence) }
            if case .measured(let lag) = temporal.microphoneDelaySeconds, !lag.isFinite {
                return result(.invalidTemporalEvidence)
            }
            if case .measured(let spread) = temporal.lagSpreadSeconds, !spread.isFinite || spread < 0 {
                return result(.invalidTemporalEvidence)
            }
            if temporal.state == .duplicateSupported {
                guard temporal.supportingWindows > 0, temporal.coverage.value > 0,
                      case .measured = temporal.microphoneDelaySeconds,
                      case .measured = temporal.lagSpreadSeconds else { return result(.invalidTemporalEvidence) }
                if evidence.playback == .unknown { return result(.missingPlaybackContext) }
                guard evidence.playback == .scoreablePlayback else { return result(.invalidTemporalEvidence) }
            }
        }
        // Explicitly distinguish the intentional future removal of the historical rescue.
        // An uncertain shadow proposal is never applied as a hidden-text decision in Stage A.
        if evidence.signalVerdict == .measured(.residualNotExplained), evidence.textEcho == .measured(true) {
            return result(.legacyRescueDisagreement)
        }
        if evidence.signalVerdict == .measured(.echo) || evidence.textEcho == .measured(true) {
            return result(.playbackDuplicateCandidate)
        }
        if case .measured(let temporal) = evidence.temporalDuplicate, temporal.state == .duplicateSupported {
            return result(.playbackDuplicateCandidate)
        }
        switch evidence.speechActivity {
        case .measured(.detected): return result(.speechActivityIsNotNearEndProof)
        case .measured(.notDetected): return result(.negativeActivityIsNotSpeechAbsenceProof)
        case .unavailable: return result(.insufficientEvidence)
        }
    }
}
