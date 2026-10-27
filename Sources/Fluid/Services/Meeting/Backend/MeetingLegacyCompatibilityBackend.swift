import Foundation

/// Explicit temporary compatibility path (plan §6: "A may wrap the existing final times as an
/// explicit temporary compatibility path").
///
/// It runs the unchanged in-pipeline workflow — the same `SpeakerDiarizationService` passes, echo
/// policy, near-field gate, "You" election, checkpoint read/write, segment IDs and timestamps — by
/// calling the executor the pipeline injects. It deliberately produces no
/// `MeetingFinalTranscriptEvidence`: mapping the legacy result onto canonical text units requires
/// the analysis manifest and assembler that belong to Stage C, and inventing that mapping now would
/// fabricate per-word timing and provenance the legacy path never computed.
@MainActor
final class MeetingLegacyCompatibilityBackend: MeetingTranscriptionBackend {
    static let descriptor = MeetingBackendDescriptor(
        id: .legacyCompatibility,
        version: "1",
        execution: .local,
        supportedLanguageCodes: ["en"],
        supportedTrackKinds: Set(MeetingAudioTrackKind.allCases),
        // Legacy output is already-merged turn text. It carries no word-level final units, so it
        // must never be read as word precision.
        supportedFinalPrecisions: [.utterance],
        resultContract: .legacyResult,
        knownLimits: [
            "Returns the existing MeetingProcessingResult directly; it emits no canonical final text-unit evidence.",
            "Per-word timings, coverage receipts and a disposition ledger are not produced.",
            "Speaker identity keeps the existing prototype-based local-speaker election unchanged.",
        ]
    )

    var descriptor: MeetingBackendDescriptor {
        Self.descriptor
    }

    private let legacyExecutor: MeetingLegacyBackendExecutor

    init(legacyExecutor: @escaping MeetingLegacyBackendExecutor) {
        self.legacyExecutor = legacyExecutor
    }

    func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
        guard self.descriptor.supportedLanguageCodes.contains(request.session.languageCode) else {
            throw MeetingBackendError.unsupportedLanguage(
                backend: self.descriptor.id,
                languageCode: request.session.languageCode
            )
        }
        let plan = MeetingBackendPlan(request: request, descriptor: self.descriptor)
        guard !plan.trackKindsByID.isEmpty else {
            throw MeetingBackendError.unsupportedTrackTopology(backend: self.descriptor.id)
        }
        return plan
    }

    func execute(
        plan: MeetingBackendPlan,
        manifest: MeetingAnalysisManifest?,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void
    ) async throws -> MeetingBackendOutcome {
        // The legacy contract receives no manifest: the existing in-pipeline workflow keeps its
        // own timing and mapping, and a second mapper would double-apply the de-drift correction.
        try .legacyCompatibility(await self.legacyExecutor(plan.request, progress))
    }
}
