#if arch(arm64)
import FluidAudio
#endif
import Foundation

/// Existing correction UI owns approval. This service owns only the optional background evidence.
@MainActor
final class DictionaryAudioLearningService {
    static let shared = DictionaryAudioLearningService()
    typealias Extractor = @Sendable (DictionaryLearningAudioEvidence) async throws -> PronunciationEnrollmentCapture

    private struct Request {
        let entry: SettingsStore.CustomDictionaryEntry
        let evidenceID: UUID
        let evidence: DictionaryLearningAudioEvidence
        let expiresAt: Date
        let pronunciationGeneration: String
    }

    private let store: PronunciationDictionaryStore
    private let extract: Extractor
    private let lifetime: TimeInterval
    private let canProcess: @MainActor () -> Bool
    private let isCurrent: @MainActor (SettingsStore.CustomDictionaryEntry) -> Bool
    private var queue: [Request] = []
    private var task: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    var pendingCount: Int { self.queue.count }

    init(
        store: PronunciationDictionaryStore = .shared,
        lifetime: TimeInterval = 120,
        extract: @escaping Extractor = { evidence in
            try await AppServices.shared.asr.originalAudioEnrollment(evidence)
        },
        canProcess: @escaping @MainActor () -> Bool = {
            DictionaryMatcherExperiment.sharedFeaturesEnabled && SettingsStore.shared.automaticDictionaryLearningEnabled && AppServices.shared.asr.activeExclusiveActivity == nil
        },
        isCurrent: @escaping @MainActor (SettingsStore.CustomDictionaryEntry) -> Bool = {
            DictionaryMatcherExperiment.sharedFeaturesEnabled && SettingsStore.shared.customDictionaryEntries.contains($0)
        }
    ) {
        self.store = store
        self.lifetime = min(120, max(0, lifetime))
        self.extract = extract
        self.canProcess = canProcess
        self.isCurrent = isCurrent
    }

    /// Cancel encoder work immediately when audio activity starts. Retry the same bounded request when it ends.
    func cancelForRecording() { self.task?.cancel() }
    func activityDidEnd() { self.drain() }

    func learn(
        entry: SettingsStore.CustomDictionaryEntry,
        evidenceID: UUID,
        evidence: DictionaryLearningAudioEvidence
    ) {
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled else { return }
        guard !evidence.samples.isEmpty, evidence.samples.count <= 238_080 else { return }
        guard !self.queue.contains(where: { $0.evidenceID == evidenceID }) else { return }
        self.pruneExpired()
        // Four short clips bound queued PCM to less than 4 MB. The text correction is already independent.
        guard self.queue.count < 4 else {
            DebugLogger.shared.warning(
                "Audio learning queue full; text correction retained",
                source: "DictionaryLearning"
            )
            return
        }
        self.queue.append(Request(
            entry: entry,
            evidenceID: evidenceID,
            evidence: evidence,
            expiresAt: Date().addingTimeInterval(self.lifetime),
            pronunciationGeneration: DictionaryMatcherExperiment.generation
        ))
        self.drain()
        self.scheduleExpiry()
    }

    private func drain() {
        self.pruneExpired()
        guard self.task == nil, self.canProcess(), let request = self.queue.first else { return }
        self.task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            var retry = false
            defer {
                if !retry { self.queue.removeAll { $0.evidenceID == request.evidenceID } }
                self.task = nil
                self.drain()
                self.scheduleExpiry()
            }
            guard self.isCurrent(request.entry), request.pronunciationGeneration == DictionaryMatcherExperiment.generation else { return }
            do {
                let revision = await self.store.revision(for: request.entry.id)
                let capture = try await self.extract(request.evidence)
                try Task.checkCancellation()
                guard request.expiresAt > Date(), self.isCurrent(request.entry) else { return }
                let inserted = try await self.store.learnOriginalAudio(
                    entryID: request.entry.id,
                    label: request.entry.replacement,
                    evidenceID: request.evidenceID,
                    evidence: request.evidence,
                    capture: capture,
                    expectedRevision: revision,
                    canPersist: { DictionaryMatcherExperiment.sharedFeaturesEnabled && request.pronunciationGeneration == DictionaryMatcherExperiment.generation }
                )
                // An edit can happen while awaiting the store actor. Roll back only this event.
                if Task.isCancelled || !self.isCurrent(request.entry) {
                    if inserted { try await self.store.removeOriginalAudio(evidenceID: request.evidenceID) }
                    retry = Task.isCancelled && request.expiresAt > Date()
                    return
                }
                DebugLogger.shared.info(
                    "Original pronunciation evidence saved",
                    source: "DictionaryLearning"
                )
            } catch is CancellationError {
                retry = request.expiresAt > Date()
            } catch {
                DebugLogger.shared.warning(
                    "Original pronunciation evidence was not saved: \(error.localizedDescription)",
                    source: "DictionaryLearning"
                )
            }
        }
    }

    private func pruneExpired() {
        if let first = self.queue.first, first.expiresAt <= Date() { self.task?.cancel() }
        self.queue.removeAll { $0.expiresAt <= Date() }
    }

    private func scheduleExpiry() {
        self.expiryTask?.cancel()
        guard let expiry = self.queue.map(\.expiresAt).min() else { self.expiryTask = nil; return }
        let delay = max(0, expiry.timeIntervalSinceNow)
        self.expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.pruneExpired()
            self?.drain()
            self?.scheduleExpiry()
        }
    }
}

actor OriginalAudioEmbeddingExtractor {
    @concurrent static func extract(_ evidence: DictionaryLearningAudioEvidence) async throws -> PronunciationEnrollmentCapture {
        try Task.checkCancellation()
        #if arch(arm64)
        guard let descriptor = ParakeetSpeechModelCatalog.descriptor(forInstalledPronunciationModelKey: evidence.modelKey) else {
            if ParakeetSpeechModelCatalog.isOutdatedCompactPronunciationModelKey(evidence.modelKey) {
                throw PronunciationDictionaryStoreError.outdatedModelRevision
            }
            throw PronunciationDictionaryStoreError.inconsistentEnrollment
        }
        let version = descriptor.asrModelVersion
        let directory = AsrModels.defaultCacheDirectory(for: version)
        guard descriptor.installationRevisionMatches(at: directory),
              descriptor.variant == .v2 || descriptor.variant == .v3 || descriptor.installedArchiveSHA256(at: directory) == descriptor.archiveSHA256
        else {
            throw PronunciationDictionaryStoreError.outdatedModelRevision
        }
        let models = try await AsrModels.loadLocalOnly(
            from: directory,
            version: version
        )
        try Task.checkCancellation()
        guard descriptor.installationRevisionMatches(at: directory) else {
            throw PronunciationDictionaryStoreError.outdatedModelRevision
        }
        try Task.checkCancellation()
        let manager = AsrManager(config: ASRConfig(
            tdtConfig: TdtConfig(blankId: version.blankId),
            encoderHiddenSize: version.encoderHiddenSize
        ))
        do {
            try await manager.initialize(models: models)
            let embedding = try await manager.pronunciationEmbedding(
                audioSamples: evidence.samples,
                focalSampleRange: evidence.focalSampleRange
            )
            await manager.cleanup()
            try Task.checkCancellation()
            return PronunciationEnrollmentCapture(
                values: embedding.values,
                sourceFrameCount: embedding.sourceFrameCount,
                modelKey: evidence.modelKey
            )
        } catch {
            await manager.cleanup()
            throw error
        }
        #else
        throw PronunciationDictionaryStoreError.inconsistentEnrollment
        #endif
    }
}
