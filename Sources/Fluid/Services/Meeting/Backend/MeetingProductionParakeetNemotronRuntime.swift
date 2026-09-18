import Foundation

#if arch(arm64)
    import CoreML
    import FluidAudio
#endif

// Stage E of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md`: the production runtime behind
// `MeetingParakeetNemotronRunning`. It owns exactly two capabilities for one attempt:
//
// - Nemotron diarization: one shared weight load per attempt, one *fresh* `SortformerDiarizer`
//   state per epoch (`initialize(models:)` re-creates streaming state), released before the ASR
//   phase begins — the loaded-set sequence is none -> Nemotron -> drained -> Parakeet -> drained.
// - Parakeet ASR: one `ASRService.withPreparedMeetingASR` scope per attempt, with the heavy body
//   bounced off the main actor so materialization and inference never block the UI.
//
// Parakeet does ASR only; Nemotron does diarization only. Neither capability sees anything beyond
// the request the host froze.

nonisolated enum MeetingParakeetNemotronRuntimeError: LocalizedError, Equatable {
    case unsupportedArchitecture

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            return "The local Parakeet + Nemotron meeting backend requires Apple Silicon."
        }
    }
}

#if arch(arm64)

    /// Shared-weight Nemotron factory: one `SortformerModels` load, fresh streaming state per
    /// epoch. Slots can never merge across epochs because each epoch's diarizer is a new instance.
    private final nonisolated class NemotronDiarizerFactory: MeetingNemotronDiarizerFactory, @unchecked Sendable {
        let config: SortformerConfig
        let models: SortformerModels
        private let lock = NSLock()
        private var created: [SortformerDiarizer] = []

        init(config: SortformerConfig, models: SortformerModels) {
            self.config = config
            self.models = models
        }

        func makeDiarizer(epoch _: MeetingAnalysisEpochID) async throws -> any MeetingNemotronDiarizerSession {
            try Task.checkCancellation()
            let diarizer = SortformerDiarizer(config: self.config)
            diarizer.initialize(models: self.models)
            self.lock.withLock { self.created.append(diarizer) }
            return NemotronDiarizerSession(diarizer: diarizer)
        }

        func cleanup() {
            let diarizers = self.lock.withLock {
                let pending = self.created
                self.created.removeAll()
                return pending
            }
            for diarizer in diarizers {
                diarizer.cleanup()
            }
        }
    }

    private nonisolated struct NemotronDiarizerSession: MeetingNemotronDiarizerSession, @unchecked Sendable {
        // The diarizer is used strictly serially: one epoch, one caller, one call.
        let diarizer: SortformerDiarizer

        func diarize(samples: [Float]) async throws -> [MeetingNemotronSpeakerSegment] {
            try Task.checkCancellation()
            let timeline = try self.diarizer.processComplete(
                samples,
                sourceSampleRate: nil,
                keepingEnrolledSpeakers: false,
                finalizeOnCompletion: true
            )
            try Task.checkCancellation()
            return timeline.speakers
                .sorted { $0.key < $1.key }
                .flatMap { index, speaker in
                    speaker.finalizedSegments.compactMap { segment in
                        guard segment.isFinalized, segment.endTime > segment.startTime else { return nil }
                        return MeetingNemotronSpeakerSegment(
                            slotIndex: index,
                            start: TimeInterval(segment.startTime),
                            end: TimeInterval(segment.endTime)
                        )
                    }
                }
        }
    }

    /// The prepared Parakeet session. Both references are only ever exercised through ASRService's
    /// own main-actor scope and meeting executor, never from the caller's context directly.
    private nonisolated struct PreparedParakeetASRSession: MeetingParakeetASRSession, @unchecked Sendable {
        let asrService: ASRService
        let provider: any TranscriptionProvider

        func transcribeWithTimings(
            _ samples: [Float]
        ) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
            try await self.asrService.transcribeMeetingSamplesWithTimings(samples, provider: self.provider)
        }
    }

    final nonisolated class MeetingParakeetNemotronRuntime: MeetingParakeetNemotronRunning {
        private let asrServiceProvider: @MainActor () -> ASRService
        private let modelLocator: any MeetingNemotronModelLocating

        init(
            asrServiceProvider: @escaping @MainActor () -> ASRService,
            modelLocator: any MeetingNemotronModelLocating
        ) {
            self.asrServiceProvider = asrServiceProvider
            self.modelLocator = modelLocator
        }

        func withNemotronDiarization(
            artifact: MeetingNemotronModelArtifact,
            _ body: @escaping @Sendable (any MeetingNemotronDiarizerFactory) async throws -> MeetingNemotronPhaseResult
        ) async throws -> MeetingNemotronPhaseResult {
            // Recheck at open time: the artifact located at plan/readiness time is validated again
            // before CoreML touches it (plan §5).
            let artifact = try self.modelLocator.recheck(artifact)
            // Reference Nemotron streaming configuration (conversion script cadence, kept exact by
            // the FluidAudio factory; it validates instead of clamping).
            let config = try SortformerConfig.nemotron(
                spkcacheUpdatePeriod: 300,
                spkcacheSilFramesPerSpk: 3,
                predScoreThreshold: 0.25
            )
            let mlConfiguration = MLModelConfiguration()
            mlConfiguration.computeUnits = .cpuAndGPU
            let models = try await SortformerModels.load(
                config: config,
                mainModelPath: artifact.packageURL,
                configuration: mlConfiguration
            )
            let factory = NemotronDiarizerFactory(config: config, models: models)
            do {
                let result = try await body(factory)
                factory.cleanup()
                return result
            } catch {
                factory.cleanup()
                throw error
            }
        }

        func withPreparedASR(
            attemptID: UUID,
            configuration: MeetingFinalProcessingConfiguration,
            body: @escaping @Sendable (any MeetingParakeetASRSession) async throws -> MeetingParakeetPhaseResult
        ) async throws -> MeetingParakeetPhaseResult {
            let asrService = await self.asrServiceProvider()
            return try await asrService.withPreparedMeetingASR(
                attemptID: attemptID,
                configuration: configuration
            ) { provider in
                let session = PreparedParakeetASRSession(asrService: asrService, provider: provider)
                // ASRService runs this scope body on the main actor; the attempt's epoch loop
                // (materialization + model calls) must not live there. Cancellation of the scope
                // cancels this bridging await, which cancels the detached body.
                let work = Task.detached(priority: .userInitiated) { try await body(session) }
                return try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
            }
        }
    }

#else

    /// Non-Apple-Silicon stub: the FluidAudio runtime stack is arm64-only in this app, so the
    /// capability refuses rather than partially working.
    final nonisolated class MeetingParakeetNemotronRuntime: MeetingParakeetNemotronRunning {
        init(
            asrServiceProvider _: @escaping @MainActor () -> ASRService,
            modelLocator _: any MeetingNemotronModelLocating
        ) {}

        func withNemotronDiarization(
            artifact _: MeetingNemotronModelArtifact,
            _: @escaping @Sendable (any MeetingNemotronDiarizerFactory) async throws -> MeetingNemotronPhaseResult
        ) async throws -> MeetingNemotronPhaseResult {
            throw MeetingParakeetNemotronRuntimeError.unsupportedArchitecture
        }

        func withPreparedASR(
            attemptID _: UUID,
            configuration _: MeetingFinalProcessingConfiguration,
            body _: @escaping @Sendable (any MeetingParakeetASRSession) async throws -> MeetingParakeetPhaseResult
        ) async throws -> MeetingParakeetPhaseResult {
            throw MeetingParakeetNemotronRuntimeError.unsupportedArchitecture
        }
    }

#endif
