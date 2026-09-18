import Foundation

// Stage E of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md`: the narrowly scoped runtime
// capability the host injects into the composite backend. The backend owns orchestration —
// epoch order, materialization, unit construction, receipts; the runtime owns exactly two model
// capabilities and nothing else. It cannot see the session store, arbitrary directories or global
// settings: the host binds it to the frozen request before the backend ever runs.
//
// Tests inject a fake implementation of `MeetingParakeetNemotronRunning`; nothing here reads the
// filesystem or touches CoreML by itself.

/// One speaker-active interval from a single Nemotron epoch run, in seconds from that epoch's
/// materialized audio start. Slot indices are Nemotron's own and are meaningful only inside the
/// epoch that produced them.
nonisolated struct MeetingNemotronSpeakerSegment: Equatable, Sendable {
    let slotIndex: Int
    let start: TimeInterval
    let end: TimeInterval
}

/// One fresh Nemotron diarizer state for exactly one analysis epoch.
nonisolated protocol MeetingNemotronDiarizerSession: Sendable {
    /// 16kHz mono epoch audio -> finalized speaker segments. Implementations may block on CoreML
    /// and are always awaited from a background context.
    func diarize(samples: [Float]) async throws -> [MeetingNemotronSpeakerSegment]
}

/// Hands out per-epoch diarizers. Every call must return entirely fresh streaming state; model
/// weights may be shared between instances. Slots never carry across epochs (plan §3).
nonisolated protocol MeetingNemotronDiarizerFactory: Sendable {
    func makeDiarizer(epoch: MeetingAnalysisEpochID) async throws -> any MeetingNemotronDiarizerSession
}

/// The attempt's prepared Parakeet ASR session, valid only inside the meeting preparation scope.
nonisolated protocol MeetingParakeetASRSession: Sendable {
    func transcribeWithTimings(
        _ samples: [Float]
    ) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming])
}

nonisolated struct MeetingNemotronPhaseResult: Sendable {
    var activity: [MeetingBackendSpeakerActivity] = []
    var failures: [MeetingAnalysisEpochID: String] = [:]
}

nonisolated struct MeetingParakeetEpochOutput: Sendable {
    let epochID: MeetingAnalysisEpochID
    let text: String
    let words: [ASRWordTiming]
    let sampleRate: Double
    let sampleCount: Int
    let spanSamples: [MeetingMaterializedSpanSamples]
}

nonisolated struct MeetingParakeetPhaseResult: Sendable {
    var outputs: [MeetingParakeetEpochOutput] = []
    var failures: [MeetingAnalysisEpochID: String] = [:]
}

/// The composite backend's runtime, one per attempt. `withNemotronDiarization` is the only owner
/// of Nemotron residency: weights load before the factory is handed out and are released before
/// it returns. `withPreparedASR` wraps the attempt's single `ASRService.withPreparedMeetingASR`
/// scope. The two phases never overlap, so at most one local meeting model is resident at a time
/// (plan §6 D/E isolation). Concrete phase result types are deliberate: a generic scoped-closure
/// witness across the app/test module boundary is not ABI-stable under MainActor-by-default.
protocol MeetingParakeetNemotronRunning: Sendable {
    nonisolated func withNemotronDiarization(
        artifact: MeetingNemotronModelArtifact,
        _ body: @escaping @Sendable (any MeetingNemotronDiarizerFactory) async throws -> MeetingNemotronPhaseResult
    ) async throws -> MeetingNemotronPhaseResult

    nonisolated func withPreparedASR(
        attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration,
        body: @escaping @Sendable (any MeetingParakeetASRSession) async throws -> MeetingParakeetPhaseResult
    ) async throws -> MeetingParakeetPhaseResult
}
