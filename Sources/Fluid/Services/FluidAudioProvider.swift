import Foundation

/// Rejection of a meeting ASR configuration outside the fixed supported policy.
nonisolated enum MeetingProviderOptionsError: Error, Equatable {
    case unsupportedASRModel(String)
    case unsupportedLanguageCode(String)
    case unsupportedFeature(String)
}

/// Immutable provider options for the opt-in meeting post-processing path. Only the fixed
/// Parakeet TDT v2 handles English; v3 handles its supported multilingual languages.
/// Unsupported model/language combinations and enhancement features are rejected.
nonisolated struct MeetingProviderOptions: Equatable, Sendable {
    let model: SettingsStore.SpeechModel
    let vocabularyBoostingEnabled: Bool
    let pronunciationMatchingEnabled: Bool
    let customDictionaryRewritingEnabled: Bool
    let experimentalUnifiedFinalEnabled: Bool

    static func resolve(
        _ configuration: MeetingFinalProcessingConfiguration
    ) throws -> MeetingProviderOptions {
        guard let model = SettingsStore.SpeechModel(rawValue: configuration.asrModel),
              model == .parakeetTDTv2 || model == .parakeetTDT
        else {
            throw MeetingProviderOptionsError.unsupportedASRModel(configuration.asrModel)
        }
        guard VoiceEngineLanguageCatalog.parakeetV3LanguageIDs.contains(configuration.languageCode),
              model != .parakeetTDTv2 || configuration.languageCode == "en"
        else {
            throw MeetingProviderOptionsError.unsupportedLanguageCode(configuration.languageCode)
        }
        guard !configuration.vocabularyBoostingEnabled else {
            throw MeetingProviderOptionsError.unsupportedFeature("vocabularyBoosting")
        }
        guard !configuration.pronunciationMatchingEnabled else {
            throw MeetingProviderOptionsError.unsupportedFeature("pronunciationMatching")
        }
        guard !configuration.customDictionaryRewritingEnabled else {
            throw MeetingProviderOptionsError.unsupportedFeature("customDictionaryRewriting")
        }
        guard !configuration.experimentalUnifiedFinalEnabled else {
            throw MeetingProviderOptionsError.unsupportedFeature("experimentalUnifiedFinal")
        }
        return MeetingProviderOptions(
            model: model,
            vocabularyBoostingEnabled: false,
            pronunciationMatchingEnabled: false,
            customDictionaryRewritingEnabled: false,
            experimentalUnifiedFinalEnabled: false
        )
    }
}

/// Immutable enhancement options pinned at construction for offline/baseline runs. When
/// provided, these values replace the live `SettingsStore` reads for these enhancements.
/// Full settings isolation also requires an explicit model and disabled vocabulary boosting.
nonisolated struct FluidAudioProviderEnhancementOptions {
    let experimentalUnifiedFinalEnabled: Bool
    let pronunciationMatchingEnabled: Bool
    let customDictionaryEntries: [SettingsStore.CustomDictionaryEntry]
}

#if arch(arm64)
import FluidAudio

/// TranscriptionProvider implementation using FluidAudio (optimized for Apple Silicon)
/// This wraps the existing FluidAudio-based ASR for use on Apple Silicon Macs.
final class FluidAudioProvider: TranscriptionProvider {
    private static let incrementalChunkingThresholdSamples = 240_000
    private static let incrementalAppendBlockSamples = 240_000

    /// Stable admission keeps a ninth word from evicting references used by the next match.
    struct TemporalReferenceCache {
        private var entries: [String: [DictionaryMatchFrames]] = [:]
        private(set) var byteCount = 0
        let byteLimit: Int

        init(byteLimit: Int = 32 * 1024 * 1024) { self.byteLimit = byteLimit }
        // swiftlint:disable:next discouraged_optional_collection
        subscript(key: String) -> [DictionaryMatchFrames]? { self.entries[key] }
        func canFit(_ bytes: Int) -> Bool { bytes >= 0 && bytes <= self.byteLimit - self.byteCount }

        @discardableResult mutating func insert(_ frames: [DictionaryMatchFrames], for key: String) -> Bool {
            if self.entries[key] != nil { return true }
            guard !frames.isEmpty, frames.allSatisfy(\.isValid) else { return false }
            let bytes = frames.reduce(0) { $0 + $1.values.count * MemoryLayout<Float>.size }
            guard self.canFit(bytes) else { return false }
            self.entries[key] = frames
            self.byteCount += bytes
            return true
        }

        mutating func retain(keys: Set<String>) {
            self.entries = self.entries.filter { keys.contains($0.key) }
            self.byteCount = self.entries.values.reduce(0) { total, frames in
                total + frames.reduce(0) { $0 + $1.values.count * MemoryLayout<Float>.size }
            }
        }

        mutating func removeAll() { self.entries.removeAll(); self.byteCount = 0 }
    }

    struct PronunciationTextReplacement {
        let wordRange: ClosedRange<Int>
        let label: String
    }

    struct TemporalMatchKey: Hashable {
        let prototypeIndex: Int
        let frameRange: Range<Int>
    }

    static func dictionaryLabels(
        from entries: [SettingsStore.CustomDictionaryEntry]
    ) -> [UUID: String] {
        Dictionary(
            entries.map { ($0.id, $0.replacement) },
            uniquingKeysWith: { _, last in last }
        )
    }

    let name = "FluidAudio (Apple Silicon Optimized)"

    /// Whether this provider is supported on the current system.
    /// FluidAudio is optimized for Apple Silicon, but may still function on Intel.
    var isAvailable: Bool {
        true
    }

    /// Boosting rescores tokens without moving their timings. Checked up front so a chunk that
    /// cannot be aligned is never transcribed twice.
    var supportsWordTimings: Bool { !self.isWordBoostingActive }

    private var streamingAsrManager: AsrManager?
    private var finalAsrManager: AsrManager?
    private var latestStreamingPreviewText: String = ""
    private var latestStreamingPreviewSampleCount: Int = 0
    private var latestStreamingPreviewFinishedAt: TimeInterval?
    private var incrementalSession: ParakeetIncrementalSession?
    private var incrementalAcceptedSampleCount = 0
    private var recordingGeneration = UUID()
    private var incrementalPronunciationProfiles: [PronunciationDictionaryProfile] = []
    private var automaticPronunciationProfiles: [PronunciationDictionaryProfile] = []
    private var didLoadAutomaticPronunciationProfiles = false

    private var usesIncrementalDictation: Bool {
        self.effectiveExperimentalUnifiedFinalEnabled || self.effectivePronunciationMatchingEnabled
    }

    private(set) var isReady: Bool = false
    private(set) var isWordBoostingActive: Bool = false
    private(set) var boostedVocabularyTermsCount: Int = 0
    private var boostedTermLookup: [String] = []
    private var pronunciationModelKey = ""
    private var edgeReferenceCache: [UUID: PronunciationEmbedding] = [:]
    private var incrementalSharedFeatures = false
    private var incrementalSharedEvidence: [Int: [(Range<Int>, DictionaryAcousticEvidence)]] = [:]
    private var temporalModels: AsrModels?
    private var temporalReferenceCache = TemporalReferenceCache()
    private var temporalWarmTask: Task<Void, Never>?
    private var temporalWarmRequest: (profiles: [PronunciationDictionaryProfile], generation: String)?
    private var pronunciationProfilesToWarm: [PronunciationDictionaryProfile] = []

    /// Optional model override - if set, uses this model instead of the global setting.
    /// Used for downloading specific models without changing the active selection.
    let modelOverride: SettingsStore.SpeechModel?
    private let configureWordBoosting: Bool
    /// Opt-in pinned meeting options. When nil (legacy dictation), enhancement switches and
    /// the custom dictionary are still read live from `SettingsStore` at each call site.
    private let meetingOptions: MeetingProviderOptions?
    /// Explicitly pinned enhancement options for offline/baseline runs. Precedence for each
    /// effective getter: fixed meeting policy, then this, then live `SettingsStore`.
    private let enhancementOptions: FluidAudioProviderEnhancementOptions?
    private let pronunciationStore: PronunciationDictionaryStore

    init(
        modelOverride: SettingsStore.SpeechModel? = nil,
        configureWordBoosting: Bool = true,
        enhancementOptions: FluidAudioProviderEnhancementOptions? = nil,
        pronunciationStore: PronunciationDictionaryStore = .shared
    ) {
        self.modelOverride = modelOverride
        self.configureWordBoosting = configureWordBoosting
        self.meetingOptions = nil
        self.enhancementOptions = enhancementOptions
        self.pronunciationStore = pronunciationStore
    }

    /// Opt-in meeting post-processing provider. The model is pinned immutably and every
    /// dictation enhancement (vocabulary store, pronunciation training/matching, custom
    /// dictionary, experimental unified final) is disabled explicitly rather than read from
    /// live settings. Unsupported configurations are rejected, never silently coerced.
    init(meetingConfiguration configuration: MeetingFinalProcessingConfiguration) throws {
        let options = try MeetingProviderOptions.resolve(configuration)
        self.modelOverride = options.model
        self.configureWordBoosting = false
        self.meetingOptions = options
        self.enhancementOptions = nil
        self.pronunciationStore = .shared
    }

    private var effectiveExperimentalUnifiedFinalEnabled: Bool {
        self.meetingOptions?.experimentalUnifiedFinalEnabled
            ?? self.enhancementOptions?.experimentalUnifiedFinalEnabled
            ?? SettingsStore.shared.experimentalParakeetUnifiedFinalEnabled
    }

    private var resolvedSpeechModel: SettingsStore.SpeechModel {
        let selected = self.modelOverride ?? SettingsStore.shared.selectedSpeechModel
        // Preserve the established fallback for old Qwen selections.
        return selected == .qwen3Asr ? .parakeetTDT : selected
    }

    private var explicitPronunciationMatchingEnabled: Bool {
        self.meetingOptions?.pronunciationMatchingEnabled
            ?? self.enhancementOptions?.pronunciationMatchingEnabled
            ?? true
    }

    private var automaticPronunciationMatchingEnabled: Bool {
        self.meetingOptions == nil && self.enhancementOptions == nil
            && (SettingsStore.shared.automaticDictionaryLearningEnabled
                || self.automaticPronunciationProfiles.contains { $0.automaticMatchingEnabled == true })
    }

    private var effectivePronunciationMatchingEnabled: Bool {
        DictionaryMatcherExperiment.sharedFeaturesEnabled && (self.explicitPronunciationMatchingEnabled
            || (self.automaticPronunciationMatchingEnabled && !self.automaticPronunciationProfiles.isEmpty))
    }

    /// Read the actor-owned store once after capture begins, never on the microphone startup path.
    private func refreshAutomaticPronunciationProfiles(warmReferences: Bool = true) async throws {
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled else {
            self.automaticPronunciationProfiles = []
            return
        }
        guard !self.didLoadAutomaticPronunciationProfiles else { return }
        let generation = self.recordingGeneration
        guard self.meetingOptions == nil, self.enhancementOptions == nil || self.explicitPronunciationMatchingEnabled, !self.effectiveCustomDictionaryEntries.isEmpty else {
            self.automaticPronunciationProfiles = []
            self.didLoadAutomaticPronunciationProfiles = true
            return
        }
        let stored = await self.pronunciationStore.profiles(modelKey: self.pronunciationModelKey)
        try self.requireCurrentRecording(generation)
        self.automaticPronunciationProfiles = Self.matchingProfiles(
            stored,
            entries: self.effectiveCustomDictionaryEntries,
            includeManual: false,
            includeOriginal: SettingsStore.shared.automaticDictionaryLearningEnabled
        )
        self.didLoadAutomaticPronunciationProfiles = true
        let activeProfiles = Self.matchingProfiles(stored, entries: self.effectiveCustomDictionaryEntries, includeManual: self.explicitPronunciationMatchingEnabled)
        let activeKeys = Set(activeProfiles.map(DictionaryNegativeEvidenceResolver.profileKey))
        self.temporalReferenceCache.retain(keys: activeKeys)
        let inspectionIDs = Set(activeProfiles.flatMap(\.enrollments).compactMap(\.inspectionID))
        self.edgeReferenceCache = self.edgeReferenceCache.filter { inspectionIDs.contains($0.key) }
        self.pronunciationProfilesToWarm = activeProfiles
        if warmReferences { self.scheduleTemporalWarmup(activeProfiles) }
    }

    static func matchingProfiles(
        _ stored: [PronunciationDictionaryProfile],
        entries: [SettingsStore.CustomDictionaryEntry], includeManual: Bool, includeOriginal: Bool = true
    ) -> [PronunciationDictionaryProfile] {
        let labels = Self.dictionaryLabels(from: entries)
        return stored.filter { profile in
            guard profile.isEligibleForMatching,
                  includeManual || profile.automaticMatchingEnabled == true || (includeOriginal && profile.hasOriginalAudio),
                  let label = labels[profile.dictionaryEntryID]
            else { return false }
            return !profile.hasOriginalAudio || profile.label.caseInsensitiveCompare(label) == .orderedSame
        }
    }

    private var effectiveCustomDictionaryEntries: [SettingsStore.CustomDictionaryEntry] {
        if let meetingOptions = self.meetingOptions, !meetingOptions.customDictionaryRewritingEnabled {
            return []
        }
        return self.enhancementOptions?.customDictionaryEntries
            ?? SettingsStore.shared.customDictionaryEntries
    }

    #if DEBUG
    func setWordBoostingActiveForTesting(_ active: Bool) {
        self.isWordBoostingActive = active
    }

    /// Read-only snapshot of the actual effective enhancement getters for baseline tests.
    var effectiveEnhancementOptionsForTesting: FluidAudioProviderEnhancementOptions {
        FluidAudioProviderEnhancementOptions(
            experimentalUnifiedFinalEnabled: self.effectiveExperimentalUnifiedFinalEnabled,
            pronunciationMatchingEnabled: self.effectivePronunciationMatchingEnabled,
            customDictionaryEntries: self.effectiveCustomDictionaryEntries
        )
    }
    #endif

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        guard self.isReady == false else { return }

        let selectedModel = self.resolvedSpeechModel
        guard let descriptor = selectedModel.parakeetDescriptor else {
            throw NSError(domain: "FluidAudioProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "Choose a supported Parakeet model."])
        }
        let asrModelVersion = descriptor.asrModelVersion
        let modelVersion = descriptor.variant.rawValue
        self.pronunciationModelKey = descriptor.pronunciationModelKey
        let cacheDirectory = AsrModels.defaultCacheDirectory().deletingLastPathComponent()
        let modelCacheDirectory = AsrModels.defaultCacheDirectory(for: asrModelVersion)
        DebugLogger.shared.info(
            "FluidAudioProvider: Starting model preparation for \(selectedModel.displayName) [version=\(modelVersion)]",
            source: "FluidAudioProvider"
        )
        DebugLogger.shared.debug("FluidAudioProvider: target cache directory=\(cacheDirectory.path)", source: "FluidAudioProvider")
        try Task.checkCancellation()
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: modelCacheDirectory.path),
               !descriptor.artifactsAreComplete(at: modelCacheDirectory)
            {
                try FileManager.default.removeItem(at: modelCacheDirectory)
            }
        }.value
        try Task.checkCancellation()
        let progressRelay = ModelPreparationProgressRelay(progressHandler)
        progressRelay.report(.preparingDownload)
        let fluidAudioProgressHandler: DownloadUtils.ProgressHandler = { progress in
            switch progress.phase {
            case .listing:
                progressRelay.report(.preparingDownload)
            case .downloading:
                // FluidAudio reserves 0.0-0.5 for transfer bytes. Show percent only for that
                // real download phase, not for later Core ML work.
                progressRelay.report(.downloading(progress.fractionCompleted / 0.5))
            case .compiling:
                progressRelay.report(.optimizing)
            }
        }

        let loadStart = Date()
        // Download and load models
        let models: AsrModels
        do {
            if descriptor.archiveURL != nil {
                _ = try await ParakeetArchiveDownloader.ensurePresent(descriptor: descriptor, in: cacheDirectory) { progress in
                    progressRelay.report(progress)
                }
                try Task.checkCancellation()
                progressRelay.report(.loading)
                models = try await AsrModels.loadLocalOnly(from: modelCacheDirectory, version: asrModelVersion)
            } else {
                models = try await AsrModels.downloadAndLoad(
                    version: asrModelVersion,
                    progressHandler: fluidAudioProgressHandler
                )
            }
        } catch {
            // A canceled transfer can still leave files that require user cleanup.
            // Keep that repair path visible instead of reporting an ordinary cancel.
            if ParakeetArchiveDownloader.isCleanupFailure(error) { throw error }
            let nsError = error as NSError
            if Task.isCancelled
                || error is CancellationError
                || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            {
                throw CancellationError()
            }
            throw error
        }
        try Task.checkCancellation()
        DebugLogger.shared.debug(
            "FluidAudioProvider: Models downloadAndLoad returned in \(String(format: "%.2f", Date().timeIntervalSince(loadStart)))s",
            source: "FluidAudioProvider"
        )

        self.temporalModels = models
        // Streaming manager: lightweight, no vocab boosting → avoids CTC/ANE contention
        // that causes intermittent SIGTRAP crashes during streaming inference.
        let streamingManager = AsrManager(config: ASRConfig.default)
        try await streamingManager.initialize(models: models)
        try Task.checkCancellation()
        DebugLogger.shared.debug("FluidAudioProvider: Streaming AsrManager initialized", source: "FluidAudioProvider")

        self.isWordBoostingActive = false
        self.boostedVocabularyTermsCount = 0
        self.boostedTermLookup = []

        // Final manager: separate instance with vocab boosting for end-of-recording rescoring.
        // Shares the same underlying MLModel objects (reference types) so memory overhead
        // is only the decoder state (~100KB).
        let finalManager: AsrManager
        if self.configureWordBoosting, selectedModel.supportsCustomVocabulary {
            do {
                if let vocabBundle = try await ParakeetVocabularyStore.shared.loadTokenizedVocabularyBundle() {
                    DebugLogger.shared.debug(
                        "FluidAudioProvider: Vocabulary bundle loaded with \(vocabBundle.vocabulary.terms.count) terms",
                        source: "FluidAudioProvider"
                    )
                    let boostedManager = AsrManager(config: ASRConfig.default)
                    try await boostedManager.initialize(models: models)
                    try await boostedManager.configureVocabularyBoosting(
                        vocabulary: vocabBundle.vocabulary,
                        ctcModels: vocabBundle.ctcModels
                    )
                    self.isWordBoostingActive = true
                    self.boostedVocabularyTermsCount = vocabBundle.vocabulary.terms.count
                    self.boostedTermLookup = Self.makeBoostedTermLookup(from: vocabBundle.vocabulary.terms)
                    DebugLogger.shared.info(
                        "FluidAudioProvider: Enabled vocabulary boosting with \(self.boostedVocabularyTermsCount) terms (final only)",
                        source: "FluidAudioProvider"
                    )
                    finalManager = boostedManager
                } else {
                    DebugLogger.shared.debug("FluidAudioProvider: No vocabulary boost terms found; using base ASR manager", source: "FluidAudioProvider")
                    finalManager = streamingManager
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                DebugLogger.shared.warning("FluidAudioProvider: Failed to configure vocabulary boosting: \(error)", source: "FluidAudioProvider")
                finalManager = streamingManager
            }
        } else {
            DebugLogger.shared.debug("FluidAudioProvider: Word boosting disabled by configuration", source: "FluidAudioProvider")
            finalManager = streamingManager
        }

        if DictionaryMatcherExperiment.sharedFeaturesEnabled, self.meetingOptions == nil {
            let stored = await self.pronunciationStore.profiles(modelKey: self.pronunciationModelKey)
            let eligible = Self.matchingProfiles(stored, entries: self.effectiveCustomDictionaryEntries, includeManual: self.explicitPronunciationMatchingEnabled)
            self.scheduleTemporalWarmup(eligible)
        }
        self.streamingAsrManager = streamingManager
        self.finalAsrManager = finalManager
        self.latestStreamingPreviewText = ""
        self.latestStreamingPreviewSampleCount = 0
        self.latestStreamingPreviewFinishedAt = nil
        self.recordingGeneration = UUID()
        self.automaticPronunciationProfiles = []
        self.didLoadAutomaticPronunciationProfiles = false
        self.resetIncrementalSession()

        try Task.checkCancellation()
        self.isReady = true
        progressRelay.report(.loading)
        DebugLogger.shared.info(
            "FluidAudioProvider: Models ready [isWordBoostingActive=\(self.isWordBoostingActive), terms=\(self.boostedVocabularyTermsCount)]",
            source: "FluidAudioProvider"
        )
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeFinal(samples)
    }

    func resetStreamingPreviewCache() {
        self.latestStreamingPreviewText = ""
        self.latestStreamingPreviewSampleCount = 0
        self.latestStreamingPreviewFinishedAt = nil
        self.recordingGeneration = UUID()
        self.automaticPronunciationProfiles = []
        self.didLoadAutomaticPronunciationProfiles = false
        self.resetIncrementalSession()
    }

    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard let fullPreviewManager = self.streamingAsrManager else {
            throw NSError(
                domain: "FluidAudioProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "ASR manager not initialized"]
            )
        }

        let generation = self.recordingGeneration
        try await self.refreshAutomaticPronunciationProfiles()
        let startedAt = Date().timeIntervalSince1970
        let result: ASRResult
        if self.usesIncrementalDictation,
           samples.count > Self.incrementalChunkingThresholdSamples,
           let incrementalManager = self.finalAsrManager ?? self.streamingAsrManager
        {
            do {
                result = try await self.transcribeIncrementalPreview(
                    samples,
                    manager: incrementalManager
                )
            } catch {
                if self.recordingGeneration == generation { self.resetIncrementalSession() }
                try self.requireCurrentRecording(generation)
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                DebugLogger.shared.warning(
                    "FluidAudioProvider: Incremental preview failed (\(error.localizedDescription)); using full preview",
                    source: "FluidAudioProvider"
                )
                result = try await fullPreviewManager.transcribe(samples, source: AudioSource.microphone)
            }
        } else {
            if !self.usesIncrementalDictation
                || samples.count < self.incrementalAcceptedSampleCount
            {
                self.resetIncrementalSession()
            }
            result = try await fullPreviewManager.transcribe(samples, source: AudioSource.microphone)
        }
        try self.requireCurrentRecording(generation)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.latestStreamingPreviewText = text
        self.latestStreamingPreviewSampleCount = samples.count
        self.latestStreamingPreviewFinishedAt = Date().timeIntervalSince1970
        let elapsedMs = Int(((Date().timeIntervalSince1970 - startedAt) * 1000).rounded())
        let audioMs = Int((Double(samples.count) / 16_000.0 * 1000).rounded())
        let rtf = audioMs > 0 ? Double(elapsedMs) / Double(audioMs) : 0
        DebugLogger.shared.debug(
            """
            ASR_BENCH provider_streaming_done samples=\(samples.count) audioMs=\(audioMs) \
            elapsedMs=\(elapsedMs) textChars=\(text.trimmingCharacters(in: .whitespacesAndNewlines).count) \
            rtf=\(String(format: "%.3f", rtf))
            """,
            source: "ASRBenchmark"
        )
        return ASRTranscriptionResult(text: result.text, confidence: result.confidence)
    }

    /// Returns the first sample not yet accepted by the active incremental session.
    /// Callers can use this to copy only newly captured PCM instead of the full
    /// growing recording on every live-preview tick.
    func incrementalPreviewDeltaStart(totalSampleCount: Int) -> Int? {
        Self.incrementalPreviewDeltaRange(
            enabled: self.usesIncrementalDictation,
            hasSession: self.incrementalSession != nil,
            acceptedSampleCount: self.incrementalAcceptedSampleCount,
            totalSampleCount: totalSampleCount
        )?.lowerBound
    }

    static func incrementalPreviewDeltaRange(
        enabled: Bool,
        hasSession: Bool,
        acceptedSampleCount: Int,
        totalSampleCount: Int
    ) -> Range<Int>? {
        guard enabled,
              hasSession,
              acceptedSampleCount > self.incrementalChunkingThresholdSamples,
              totalSampleCount > acceptedSampleCount
        else { return nil }
        return acceptedSampleCount..<totalSampleCount
    }

    /// Advances an existing incremental session with only the newly captured PCM.
    /// Any failure invalidates the session; the caller should retry through
    /// `transcribeStreaming(_:)` with the full prefix so normal fallback remains intact.
    func transcribeStreamingDelta(
        _ newSamples: [Float],
        totalSampleCount: Int
    ) async throws -> ASRTranscriptionResult {
        let generation = self.recordingGeneration
        guard let session = self.incrementalSession,
              self.incrementalAcceptedSampleCount + newSamples.count == totalSampleCount
        else {
            self.resetIncrementalSession()
            throw NSError(
                domain: "FluidAudioProvider",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Incremental preview delta no longer matches the recording"]
            )
        }

        let startedAt = Date().timeIntervalSince1970
        do {
            try await session.append(newSamples)
            try self.requireCurrentRecording(generation)
            self.incrementalAcceptedSampleCount = totalSampleCount
            let result = try await session.preview()
            try self.requireCurrentRecording(generation)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.latestStreamingPreviewText = text
            self.latestStreamingPreviewSampleCount = totalSampleCount
            self.latestStreamingPreviewFinishedAt = Date().timeIntervalSince1970
            self.logStreamingBenchmark(
                sampleCount: totalSampleCount,
                text: text,
                startedAt: startedAt,
                inputSampleCount: newSamples.count
            )
            return ASRTranscriptionResult(text: result.text, confidence: result.confidence)
        } catch {
            if self.recordingGeneration == generation { self.resetIncrementalSession() }
            try self.requireCurrentRecording(generation)
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    /// Reuse the loaded unboosted encoder; the library API owns and releases only its prepared handles.
    func originalAudioEnrollment(_ evidence: DictionaryLearningAudioEvidence) async throws -> PronunciationEnrollmentCapture? {
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled, self.isReady, evidence.modelKey == self.pronunciationModelKey,
              let manager = self.streamingAsrManager else { return nil }
        let embedding = try await manager.pronunciationEmbedding(
            audioSamples: evidence.samples,
            focalSampleRange: evidence.focalSampleRange
        )
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled else { return nil }
        return PronunciationEnrollmentCapture(
            values: embedding.values,
            sourceFrameCount: embedding.sourceFrameCount,
            modelKey: evidence.modelKey
        )
    }

    func transcribeDictionaryTraining(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeDictionaryTraining(samples, capturePronunciation: self.explicitPronunciationMatchingEnabled)
    }

    func transcribeDictionaryTraining(_ samples: [Float], capturePronunciation: Bool) async throws -> ASRTranscriptionResult {
        let pronunciationGeneration = DictionaryMatcherExperiment.generation
        guard let manager = self.streamingAsrManager else {
            throw NSError(
                domain: "FluidAudioProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "ASR manager not initialized"]
            )
        }
        let shouldCapture = capturePronunciation && DictionaryMatcherExperiment.sharedFeaturesEnabled
        await manager.setPronunciationCustomizationEnabled(shouldCapture)
        do {
            let result = try await manager.transcribe(samples, source: AudioSource.microphone)
            let features = await manager.consumePronunciationEncoderFeatures()
            await manager.setPronunciationCustomizationEnabled(false)
            let captureIsCurrent = shouldCapture && DictionaryMatcherExperiment.sharedFeaturesEnabled
                && DictionaryMatcherExperiment.generation == pronunciationGeneration
            var capture = captureIsCurrent ? self.makeEnrollment(result: result, features: features, samples: samples) : nil
            if capture != nil, DictionaryPronunciationExperiment.enabled,
               let range = DictionaryPronunciationExperiment.trimmedRange(samples)
            {
                let embedding = try await self.encodeEdge(Array(samples[range]), manager: manager)
                capture?.edgeEmbedding = embedding.values
                capture?.edgeFrameCount = embedding.sourceFrameCount
            }
            if !DictionaryMatcherExperiment.sharedFeaturesEnabled || DictionaryMatcherExperiment.generation != pronunciationGeneration {
                capture = nil
            }
            return ASRTranscriptionResult(text: result.text, confidence: result.confidence, pronunciationEnrollment: capture)
        } catch {
            _ = await manager.consumePronunciationEncoderFeatures()
            await manager.setPronunciationCustomizationEnabled(false)
            throw error
        }
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        let generation = self.recordingGeneration
        try await self.refreshAutomaticPronunciationProfiles(warmReferences: false)
        defer { self.scheduleTemporalWarmup(self.pronunciationProfilesToWarm) }
        defer {
            let resetStartedAt = ProcessInfo.processInfo.systemUptime
            if self.recordingGeneration == generation { self.resetIncrementalSession() }
            let resetFinishedAt = ProcessInfo.processInfo.systemUptime
            DebugLogger.shared.debug(
                "ASR_BENCH t=\(resetFinishedAt) incremental_reset_done elapsedMs=\((resetFinishedAt - resetStartedAt) * 1000)",
                source: "ASRBenchmark"
            )
        }
        guard let manager = self.finalAsrManager ?? self.streamingAsrManager else {
            throw NSError(
                domain: "FluidAudioProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "ASR manager not initialized"]
            )
        }

        if self.usesIncrementalDictation,
           samples.count > Self.incrementalChunkingThresholdSamples,
           self.incrementalSession != nil
        {
            do {
                let startedAt = Date().timeIntervalSince1970
                let result = try await self.transcribeIncrementalFinal(samples)
                try self.requireCurrentRecording(generation)
                self.logFinalBenchmark(
                    samples: samples,
                    text: result.text,
                    startedAt: startedAt,
                    usedFallback: false,
                    source: "incremental"
                )
                return result
            } catch {
                try self.requireCurrentRecording(generation)
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                DebugLogger.shared.warning(
                    "FluidAudioProvider: Incremental final failed (\(error.localizedDescription)); using full final",
                    source: "FluidAudioProvider"
                )
            }
        }

        // If the boosted final manager fails, fall back to the unboosted streaming
        // manager so the user still gets a transcription (just without CTC rescoring).
        do {
            let startedAt = Date().timeIntervalSince1970
            let outcome = try await self.transcribeFinalResult(samples, manager: manager)
            try self.requireCurrentRecording(generation)
            self.logFinalBenchmark(samples: samples, text: outcome.result.text, startedAt: startedAt, usedFallback: false)
            return outcome.result
        } catch {
            try self.requireCurrentRecording(generation)
            guard let fallback = self.streamingAsrManager, fallback !== manager else {
                throw error
            }
            DebugLogger.shared.warning(
                "FluidAudioProvider: Boosted final transcription failed (\(error.localizedDescription)), retrying without vocab boost",
                source: "FluidAudioProvider"
            )
            let startedAt = Date().timeIntervalSince1970
            let outcome = try await self.transcribeFinalResult(samples, manager: fallback)
            try self.requireCurrentRecording(generation)
            self.logFinalBenchmark(samples: samples, text: outcome.result.text, startedAt: startedAt, usedFallback: true)
            return outcome.result
        }
    }

    private func transcribeIncrementalPreview(
        _ samples: [Float],
        manager: AsrManager
    ) async throws -> ASRResult {
        if samples.count < self.incrementalAcceptedSampleCount {
            self.resetIncrementalSession()
        }
        if self.incrementalSession == nil {
            try await self.startIncrementalSession(manager: manager)
        }
        guard let session = self.incrementalSession else {
            throw NSError(
                domain: "FluidAudioProvider",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Incremental ASR session unavailable"]
            )
        }
        if samples.count > self.incrementalAcceptedSampleCount {
            try await self.appendIncrementalSamples(samples, to: session)
        }
        return try await session.preview()
    }

    private func transcribeIncrementalFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard let session = self.incrementalSession,
              samples.count >= self.incrementalAcceptedSampleCount
        else {
            throw NSError(
                domain: "FluidAudioProvider",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Incremental ASR session cannot finalize this recording"]
            )
        }
        let generation = self.recordingGeneration
        let profiles = self.incrementalPronunciationProfiles
        let startedAt = ProcessInfo.processInfo.systemUptime
        let acceptedBeforeFinal = self.incrementalAcceptedSampleCount
        if samples.count > acceptedBeforeFinal {
            try await self.appendIncrementalSamples(samples, to: session)
        }
        let appendFinishedAt = ProcessInfo.processInfo.systemUptime
        let result = try await session.finish(finalAudioSamples: samples)
        try self.requireCurrentRecording(generation)
        var matches = await session.pronunciationMatches
        let originalText = await session.unboostedText
        try self.requireCurrentRecording(generation)
        let eligibleIDs = Set(Self.matchingProfiles(
            profiles,
            entries: self.effectiveCustomDictionaryEntries,
            includeManual: self.explicitPronunciationMatchingEnabled,
            includeOriginal: SettingsStore.shared.automaticDictionaryLearningEnabled
        ).map(\.dictionaryEntryID))
        var acousticEvidence: [DictionaryAcousticEvidence] = []
        var acceptedEvidence: [DictionaryAcousticEvidence] = []
        var temporalMatches: Set<TemporalMatchKey> = []
        if self.incrementalSharedFeatures {
            if !DictionaryMatcherExperiment.sharedFeaturesEnabled { matches.removeAll() }
            let words = WordAudioChunkExtractor.words(from: result.tokenTimings ?? [])
            let wordIndex = WordAudioOverlapIndex(words: words)
            matches = matches.filter { match in
                guard profiles.indices.contains(match.prototypeIndex) else { return false }
                guard DictionaryMatcherExperiment.sharedFeaturesEnabled else { return false }
                temporalMatches.insert(TemporalMatchKey(prototypeIndex: match.prototypeIndex, frameRange: match.frameRange))
                return true
            }
            for (_, items) in self.incrementalSharedEvidence {
                for (frames, item) in items {
                    let indices = wordIndex.substantiallyOverlappingWordIndices(startTime: Double(frames.lowerBound) * 0.08, endTime: Double(frames.upperBound) * 0.08, minimumOverlapRatio: 0)
                    guard let first = indices.first, let last = indices.last else { continue }
                    acousticEvidence.append(DictionaryAcousticEvidence(id: item.id, entryID: item.entryID, label: item.label, profileKey: item.profileKey, modelKey: item.modelKey, sourceWordRange: first..<(last + 1), frames: item.frames))
                }
            }
        } else if let manager = self.finalAsrManager ?? self.streamingAsrManager, originalText == result.text {
            matches = try await self.refineEdgeMatches(matches, profiles: profiles, samples: samples, manager: manager, transcript: result.text, timings: result.tokenTimings ?? [], evidence: &acousticEvidence, temporalMatches: &temporalMatches)
        }
        try self.requireCurrentRecording(generation)
        let text = self.effectivePronunciationMatchingEnabled && originalText == result.text
            ? Self.applyPronunciationMatches(
                result: result,
                matches: matches,
                profiles: profiles,
                labels: Self.dictionaryLabels(from: self.effectiveCustomDictionaryEntries).filter { eligibleIDs.contains($0.key) },
                temporalMatches: temporalMatches,
                onAccepted: { id, label, range in
                    acceptedEvidence += acousticEvidence.filter { $0.entryID == id && $0.label == label && $0.sourceWordRange == range }
                }
            ) : result.text
        let finishFinishedAt = ProcessInfo.processInfo.systemUptime
        DebugLogger.shared.debug(
            "ASR_BENCH incremental_final_split acceptedBefore=\(acceptedBeforeFinal) " +
                "appended=\(samples.count - acceptedBeforeFinal) " +
                "appendMs=\(Self.milliseconds(from: startedAt, to: appendFinishedAt)) " +
                "finishMs=\(Self.milliseconds(from: appendFinishedAt, to: finishFinishedAt))",
            source: "ASRBenchmark"
        )
        var alignment = self.learningAlignment(for: result)
        alignment?.acousticOutput = text
        alignment?.acousticEvidence = acceptedEvidence
        return ASRTranscriptionResult(
            text: text,
            confidence: result.confidence,
            parakeetProcessingDurationMilliseconds: Self.parakeetProcessingMilliseconds(for: result),
            dictionaryLearningAlignment: alignment
        )
    }

    private static func parakeetProcessingMilliseconds(for result: ASRResult) -> Int {
        max(0, Int((result.processingTime * 1000).rounded()))
    }

    private static func milliseconds(from start: TimeInterval, to end: TimeInterval) -> String {
        String(format: "%.1f", (end - start) * 1000)
    }

    private func appendIncrementalSamples(
        _ samples: [Float],
        to session: ParakeetIncrementalSession
    ) async throws {
        let generation = self.recordingGeneration
        var offset = self.incrementalAcceptedSampleCount
        while offset < samples.count {
            let end = min(offset + Self.incrementalAppendBlockSamples, samples.count)
            try await session.append(Array(samples[offset..<end]))
            try self.requireCurrentRecording(generation)
            offset = end
            self.incrementalAcceptedSampleCount = offset
        }
    }

    private func resetIncrementalSession() {
        self.incrementalSession = nil
        self.incrementalAcceptedSampleCount = 0
        self.incrementalPronunciationProfiles = []
        self.incrementalSharedFeatures = false
        self.incrementalSharedEvidence.removeAll()
    }

    private func requireCurrentRecording(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard self.recordingGeneration == generation else { throw CancellationError() }
    }

    private func pronunciationProfiles() async -> [PronunciationDictionaryProfile] {
        guard self.effectivePronunciationMatchingEnabled else { return [] }
        let stored: [PronunciationDictionaryProfile]
        if self.explicitPronunciationMatchingEnabled {
            stored = await self.pronunciationStore.profiles(modelKey: self.pronunciationModelKey)
        } else {
            stored = self.automaticPronunciationProfiles
        }
        return Self.matchingProfiles(
            stored,
            entries: self.effectiveCustomDictionaryEntries,
            includeManual: self.explicitPronunciationMatchingEnabled,
            includeOriginal: SettingsStore.shared.automaticDictionaryLearningEnabled
        )
    }

    private func startIncrementalSession(manager: AsrManager) async throws {
        let generation = self.recordingGeneration
        let profiles = Self.preparedEdgeProfiles(await self.pronunciationProfiles(), cache: self.edgeReferenceCache)
        try self.requireCurrentRecording(generation)
        let references = DictionaryPronunciationReferences.make(profiles: profiles)
        let useSharedFeatures = DictionaryMatcherExperiment.sharedFeaturesEnabled
        let pronunciationGeneration = DictionaryMatcherExperiment.generation
        let refiner: PronunciationChunkRefiner?
        if useSharedFeatures {
            refiner = { [weak self] chunk in
                guard let self else { throw CancellationError() }
                return try await self.refineSharedChunk(chunk, references: references, manager: manager, generation: generation)
            }
        } else {
            refiner = nil
        }
        let session = try await manager.makeIncrementalSession(
            source: .microphone,
            pronunciationPrototypes: references.map(\.embedding),
            pronunciationThreshold: profiles.contains { $0.edgeCalibration != nil } ? 0.25 : DictionaryPronunciationDecision.minimumSearchScore(profiles: profiles),
            pronunciationRefiner: refiner,
            pronunciationEnabled: { DictionaryMatcherExperiment.sharedFeaturesEnabled && DictionaryMatcherExperiment.generation == pronunciationGeneration }
        )
        try self.requireCurrentRecording(generation)
        self.incrementalPronunciationProfiles = references.map(\.profile)
        self.incrementalSession = session
        self.incrementalSharedFeatures = useSharedFeatures
        self.incrementalAcceptedSampleCount = 0
    }

    private func refineSharedChunk(_ chunk: PronunciationChunk, references: [DictionaryPronunciationReferences.Reference], manager: AsrManager, generation: UUID) async throws -> [PronunciationWindowMatch] {
        try self.requireCurrentRecording(generation)
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled else { return [] }
        // Repeat only the cheap vector search with the same candidate windows as short dictation.
        let matches = PronunciationEmbeddingMatcher.allMatches(prototypes: references.map(\.embedding), in: chunk.features, threshold: 0.25, windowFrameCounts: references.map { reference in
            reference.profile.edgeCalibration != nil ? Array(5...32) : PronunciationEmbeddingMatcher.nearbyWindowCounts(around: reference.embedding.sourceFrameCount)
        }).enumerated().flatMap { index, hits in hits.map { PronunciationWindowMatch(prototypeIndex: index, score: $0.score, frameRange: $0.frameRange) } }
        var evidence: [DictionaryAcousticEvidence] = []
        var accepted: Set<TemporalMatchKey> = []
        let refined = try await self.refineEdgeMatches(
            matches,
            profiles: references.map(\.profile),
            samples: chunk.samples,
            manager: manager,
            transcript: chunk.result.text,
            timings: chunk.result.tokenTimings ?? [],
            evidence: &evidence,
            temporalMatches: &accepted,
            features: chunk.features,
            sharedChunk: true
        )
        try self.requireCurrentRecording(generation)
        // Replacing a provisional tail must replace, not accumulate, its learning evidence.
        let offset = chunk.sampleOffset / 1280
        let words = WordAudioChunkExtractor.words(from: chunk.result.tokenTimings ?? [])
        self.incrementalSharedEvidence[chunk.sampleOffset] = evidence.compactMap { item in
            guard let first = item.sourceWordRange.first, let last = item.sourceWordRange.last, words.indices.contains(first), words.indices.contains(last) else { return nil }
            let start = Int(floor(words[first].startTime / 0.08)) + offset
            let end = Int(ceil(words[last].endTime / 0.08)) + offset
            return (start..<end, item)
        }
        // Evidence is optional; bound it independently of recording length.
        if self.incrementalSharedEvidence.count > 8, let first = self.incrementalSharedEvidence.keys.min() { self.incrementalSharedEvidence.removeValue(forKey: first) }
        return refined
    }

    func transcribeWithWordTimings(_ samples: [Float]) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
        try await self.refreshAutomaticPronunciationProfiles(warmReferences: false)
        defer { self.scheduleTemporalWarmup(self.pronunciationProfilesToWarm) }
        guard let manager = self.finalAsrManager ?? self.streamingAsrManager else {
            throw NSError(
                domain: "FluidAudioProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "ASR manager not initialized"]
            )
        }

        let outcome: (result: ASRTranscriptionResult, tokenTimings: [TokenTiming]?, textMayBeCorrected: Bool) // swiftlint:disable:this discouraged_optional_collection
        do {
            let startedAt = Date().timeIntervalSince1970
            outcome = try await self.transcribeFinalResult(samples, manager: manager)
            self.logFinalBenchmark(samples: samples, text: outcome.result.text, startedAt: startedAt, usedFallback: false, source: "meeting")
        } catch {
            guard let fallback = self.streamingAsrManager, fallback !== manager else {
                throw error
            }
            let startedAt = Date().timeIntervalSince1970
            outcome = try await self.transcribeFinalResult(samples, manager: fallback)
            self.logFinalBenchmark(samples: samples, text: outcome.result.text, startedAt: startedAt, usedFallback: true, source: "meeting")
        }

        guard !outcome.textMayBeCorrected, let tokenTimings = outcome.tokenTimings else {
            return (outcome.result, [])
        }
        return (outcome.result, Self.makeWordTimings(from: tokenTimings))
    }

    static func makeWordTimings(from tokenTimings: [TokenTiming]) -> [ASRWordTiming] {
        WordAudioChunkExtractor.words(from: tokenTimings).map {
            ASRWordTiming(text: $0.text, start: $0.startTime, end: $0.endTime)
        }
    }

    private func learningAlignment(for result: ASRResult) -> DictionaryLearningAlignment? {
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled, SettingsStore.shared.automaticDictionaryLearningEnabled || DictionaryMatcherExperiment.collectNegatives, !self.isWordBoostingActive,
              let timings = result.tokenTimings, !timings.isEmpty
        else { return nil }
        return DictionaryLearningAlignment(modelKey: self.pronunciationModelKey, words: Self.makeWordTimings(from: timings))
    }

    private func transcribeFinalResult(
        _ samples: [Float], manager: AsrManager
    ) async throws -> (result: ASRTranscriptionResult, tokenTimings: [TokenTiming]?, textMayBeCorrected: Bool) { // swiftlint:disable:this discouraged_optional_collection
        if self.effectivePronunciationMatchingEnabled, samples.count > Self.incrementalChunkingThresholdSamples {
            self.resetIncrementalSession()
            try await self.startIncrementalSession(manager: manager)
            return try (await self.transcribeIncrementalFinal(samples), nil, true)
        }
        let matchingEnabled = self.effectivePronunciationMatchingEnabled && samples.count <= 16_000 * 15
        let profiles = matchingEnabled ? Self.preparedEdgeProfiles(await self.pronunciationProfiles(), cache: self.edgeReferenceCache) : []
        // Rewritten text leaves timings on the old tokens; realigning would revert corrections.
        let textMayBeCorrected = self.isWordBoostingActive || !profiles.isEmpty
        await manager.setPronunciationCustomizationEnabled(!profiles.isEmpty)
        do {
            let result = try await manager.transcribe(samples, source: AudioSource.microphone)
            let features = await manager.consumePronunciationEncoderFeatures()
            await manager.setPronunciationCustomizationEnabled(false)
            guard DictionaryMatcherExperiment.sharedFeaturesEnabled, let features, !profiles.isEmpty else {
                return (
                    ASRTranscriptionResult(
                        text: result.text,
                        confidence: result.confidence,
                        parakeetProcessingDurationMilliseconds: Self.parakeetProcessingMilliseconds(for: result),
                        dictionaryLearningAlignment: self.learningAlignment(for: result)
                    ),
                    result.tokenTimings,
                    textMayBeCorrected
                )
            }
            let references = DictionaryPronunciationReferences.make(profiles: profiles, hiddenSize: features.hiddenSize)
            let matches = PronunciationEmbeddingMatcher.allMatches(
                prototypes: references.map(\.embedding),
                in: features,
                threshold: references.contains { $0.profile.edgeCalibration != nil } ? 0.25 : DictionaryPronunciationDecision.minimumSearchScore(profiles: profiles),
                windowFrameCounts: references.map { reference in
                    reference.profile.edgeCalibration != nil ? Array(5...32) : PronunciationEmbeddingMatcher.nearbyWindowCounts(around: reference.embedding.sourceFrameCount)
                }
            ).enumerated().flatMap { index, hits in
                hits.map { PronunciationWindowMatch(prototypeIndex: index, score: $0.score, frameRange: $0.frameRange) }
            }
            var acousticEvidence: [DictionaryAcousticEvidence] = []
            var acceptedEvidence: [DictionaryAcousticEvidence] = []
            var temporalMatches: Set<TemporalMatchKey> = []
            let refined = try await self.refineEdgeMatches(
                matches,
                profiles: references.map(\.profile),
                samples: samples,
                manager: manager,
                transcript: result.text,
                timings: result.tokenTimings ?? [],
                evidence: &acousticEvidence,
                temporalMatches: &temporalMatches,
                features: features
            )
            let corrected = Self.applyPronunciationMatches(
                result: result,
                matches: DictionaryMatcherExperiment.sharedFeaturesEnabled ? refined : [],
                profiles: references.map(\.profile),
                labels: Self.dictionaryLabels(from: self.effectiveCustomDictionaryEntries),
                temporalMatches: temporalMatches,
                onAccepted: { id, label, range in
                    acceptedEvidence += acousticEvidence.filter { $0.entryID == id && $0.label == label && $0.sourceWordRange == range }
                }
            )
            var alignment = self.learningAlignment(for: result)
            alignment?.acousticOutput = corrected
            alignment?.acousticEvidence = acceptedEvidence
            return (
                ASRTranscriptionResult(
                    text: corrected,
                    confidence: result.confidence,
                    parakeetProcessingDurationMilliseconds: Self.parakeetProcessingMilliseconds(for: result),
                    dictionaryLearningAlignment: alignment
                ),
                result.tokenTimings,
                textMayBeCorrected
            )
        } catch {
            _ = await manager.consumePronunciationEncoderFeatures()
            await manager.setPronunciationCustomizationEnabled(false)
            throw error
        }
    }

    private func encodeEdge(_ samples: [Float], manager: AsrManager) async throws -> PronunciationEmbedding {
        let end = min(samples.count, max(1, Int((Double(samples.count) / 1280).rounded()) * 1280))
        return try await manager.pronunciationEmbedding(audioSamples: samples, focalSampleRange: 0..<end)
    }

    /// Final matching only reads prepared values. Incomplete legacy profiles wait for background warming.
    static func preparedEdgeProfiles(_ profiles: [PronunciationDictionaryProfile], cache: [UUID: PronunciationEmbedding]) -> [PronunciationDictionaryProfile] {
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled else { return [] }
        return profiles.compactMap { profile in
            if profile.hasOriginalAudio { return profile }
            var prepared = profile
            for index in prepared.enrollments.indices {
                if prepared.enrollments[index].edgeEmbedding != nil { continue }
                guard let id = prepared.enrollments[index].inspectionID, let embedding = cache[id] else { return nil }
                prepared.enrollments[index].edgeEmbedding = embedding.values
                prepared.enrollments[index].edgeFrameCount = embedding.sourceFrameCount
            }
            return prepared.edgeCalibration == nil ? nil : prepared
        }
    }

    private func warmEdgeProfile(_ profile: PronunciationDictionaryProfile, manager: AsrManager, generation: String) async throws {
        guard !profile.hasOriginalAudio else { return }
        for capture in profile.enrollments where capture.edgeEmbedding == nil {
            try Task.checkCancellation()
            guard DictionaryMatcherExperiment.sharedFeaturesEnabled,
                  generation == DictionaryMatcherExperiment.generation,
                  let id = capture.inspectionID else { return }
            if self.edgeReferenceCache[id] != nil { continue }
            guard self.edgeReferenceCache.count < 512 else { return }
            let audio = try await self.pronunciationStore.inspection(for: id)
            guard let range = DictionaryPronunciationExperiment.trimmedRange(Array(audio.samples.prefix(audio.recordedSampleCount))) else { return }
            let embedding = try await self.encodeEdge(Array(audio.samples[range]), manager: manager)
            try Task.checkCancellation()
            guard DictionaryMatcherExperiment.sharedFeaturesEnabled,
                  generation == DictionaryMatcherExperiment.generation else { return }
            self.edgeReferenceCache[id] = embedding
        }
    }

    // Carry both frame decisions and exact accepted evidence through this bounded refinement pass.
    // swiftlint:disable:next function_parameter_count
    private func refineEdgeMatches(
        _ matches: [PronunciationWindowMatch],
        profiles: [PronunciationDictionaryProfile],
        samples: [Float],
        manager: AsrManager,
        transcript: String,
        timings: [TokenTiming],
        evidence: inout [DictionaryAcousticEvidence],
        temporalMatches: inout Set<TemporalMatchKey>,
        features: EncoderFeatureSequence? = nil,
        sharedChunk: Bool = false
    ) async throws -> [PronunciationWindowMatch] {
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled, let features else { return [] }
        let pronunciationGeneration = DictionaryMatcherExperiment.generation
        var output: [PronunciationWindowMatch] = []
        let words = WordAudioChunkExtractor.words(from: timings)
        let wordIndex = WordAudioOverlapIndex(words: words)
        var used: [Int: [Range<Int>]] = [:]
        let compareNegatives = DictionaryMatcherExperiment.compareNegatives
        let collectNegatives = DictionaryMatcherExperiment.collectNegatives
        var sharedComparisons = 0
        let negativeRevision = compareNegatives ? await DictionaryNegativeExampleStore.shared.revision() : nil
        // Bounded experimental reranking: up to three non-overlapping candidates per word, 24 comparisons total.
        for match in matches.sorted(by: { $0.score > $1.score }) {
            try Task.checkCancellation()
            guard DictionaryMatcherExperiment.sharedFeaturesEnabled else { break }
            guard profiles.indices.contains(match.prototypeIndex) else { continue }
            // Score the complete overlapping transcript span, never just the prefix of a split word.
            let indices = wordIndex.substantiallyOverlappingWordIndices(
                startTime: Double(match.frameRange.lowerBound) * 0.08,
                endTime: Double(match.frameRange.upperBound) * 0.08,
                minimumOverlapRatio: 0
            )
            guard let first = indices.first, let last = indices.last else { continue }
            let firstFrame = max(0, Int(floor(words[first].startTime / 0.08)))
            let lastFrame = max(firstFrame + 1, Int(ceil(words[last].endTime / 0.08)))
            let alignedFrames = firstFrame..<lastFrame
            let lower = min(samples.count, firstFrame * 1280)
            let upper = min(samples.count, max(lower, lastFrame * 1280))
            let range = lower..<upper
            guard !range.isEmpty, range.count <= 16_000 * 15,
                  (used[match.prototypeIndex]?.count ?? 0) < 3,
                  !(used[match.prototypeIndex] ?? []).contains(where: { $0.overlaps(range) }),
                  let trimmed = DictionaryPronunciationExperiment.trimmedRange(samples, within: range) else { continue }
            do {
                guard sharedComparisons < 24 else { break }
                used[match.prototypeIndex, default: []].append(range)
                sharedComparisons += 1
                let profile = profiles[match.prototypeIndex]
                let referenceKey = DictionaryNegativeEvidenceResolver.profileKey(profile)
                // Old isolated-query negatives must not be compared with sentence-context queries.
                let evidenceKey = referenceKey + ":shared-features-v1"
                guard let query = Self.sharedPronunciationFrames(features, sampleRange: trimmed),
                      let references = self.temporalReferenceCache[referenceKey] else { continue }
                guard let decision = await DictionaryExperimentalMatcher.compareSharedFeatures(query: query, references: references, chunked: sharedChunk) else { continue }
                guard decision.accepted, DictionaryMatcherExperiment.sharedFeaturesEnabled else { continue }
                if compareNegatives {
                    let negatives = await DictionaryNegativeExampleStore.shared.frames(entryID: profile.dictionaryEntryID, profileKey: evidenceKey, modelKey: profile.modelKey)
                    let allowed = await DictionaryExperimentalMatcher.compareNegative(query: query, references: references, negatives: negatives)
                    if !allowed, DictionaryMatcherExperiment.compareNegatives,
                       await DictionaryNegativeExampleStore.shared.revision() == negativeRevision { continue }
                }
                try Task.checkCancellation()
                guard DictionaryMatcherExperiment.sharedFeaturesEnabled else { continue }
                temporalMatches.insert(TemporalMatchKey(prototypeIndex: match.prototypeIndex, frameRange: alignedFrames))
                output.append(PronunciationWindowMatch(prototypeIndex: match.prototypeIndex, score: decision.meanRelative, frameRange: alignedFrames))
                if collectNegatives, DictionaryMatcherExperiment.collectNegatives {
                    evidence.append(DictionaryAcousticEvidence(id: UUID(), entryID: profile.dictionaryEntryID, label: profile.label, profileKey: evidenceKey, modelKey: profile.modelKey, sourceWordRange: first..<(last + 1), frames: query))
                }
                continue
            }
        }
        return DictionaryMatcherExperiment.sharedFeaturesEnabled && DictionaryMatcherExperiment.generation == pronunciationGeneration ? output : []
    }

    /// Reuse the exact sentence frames covering the selected PCM span; never run inference here.
    static func sharedPronunciationFrames(_ features: EncoderFeatureSequence, sampleRange: Range<Int>) -> DictionaryMatchFrames? {
        guard features.hiddenSize > 0, features.frameCount > 0,
              features.values.count == features.hiddenSize * features.frameCount,
              sampleRange.lowerBound >= 0, !sampleRange.isEmpty else { return nil }
        let first = sampleRange.lowerBound / 1280
        let last = min(features.frameCount, (sampleRange.upperBound + 1279) / 1280)
        guard first < last else { return nil }
        let frames = DictionaryMatchFrames(hiddenSize: features.hiddenSize, values: Array(features.values[(first * features.hiddenSize)..<(last * features.hiddenSize)]))
        return frames.isValid ? frames : nil
    }

    #if DEBUG
    /// Test synchronization observes actual preparation; it never starts inference itself.
    var pronunciationReferencePreparationTask: Task<Void, Never>? { self.temporalWarmTask }
    var pronunciationReferencesReady: Bool {
        !self.pronunciationProfilesToWarm.isEmpty
            && self.pronunciationProfilesToWarm.allSatisfy {
                self.temporalReferenceCache[DictionaryNegativeEvidenceResolver.profileKey($0)] != nil
            }
            && Self.preparedEdgeProfiles(self.pronunciationProfilesToWarm, cache: self.edgeReferenceCache).count == self.pronunciationProfilesToWarm.count
    }
    #endif

    /// Preparation runs independently; a cache miss never adds model inference to final matching.
    private func scheduleTemporalWarmup(_ profiles: [PronunciationDictionaryProfile]) {
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled, !profiles.isEmpty,
              let models = self.temporalModels else { return }
        self.temporalWarmRequest = (profiles, DictionaryMatcherExperiment.generation)
        guard self.temporalWarmTask == nil else { return }
        self.temporalWarmTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { self.temporalWarmTask = nil }
            while let request = self.temporalWarmRequest, !Task.isCancelled {
                self.temporalWarmRequest = nil
                for profile in request.profiles {
                    guard !Task.isCancelled, DictionaryMatcherExperiment.sharedFeaturesEnabled,
                          request.generation == DictionaryMatcherExperiment.generation else { break }
                    let key = DictionaryNegativeEvidenceResolver.profileKey(profile)
                    _ = try? await self.temporalReferences(profile, key: key, models: models)
                    if self.temporalReferenceCache[key] != nil, let manager = self.finalAsrManager ?? self.streamingAsrManager {
                        try? await self.warmEdgeProfile(profile, manager: manager, generation: request.generation)
                    }
                }
            }
        }
    }

    private func temporalReferences(_ profile: PronunciationDictionaryProfile, key: String, models: AsrModels) async throws -> [DictionaryMatchFrames] {
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled else { return [] }
        guard profile.modelKey == self.pronunciationModelKey,
              profile.enrollments.allSatisfy({ $0.modelKey == profile.modelKey })
        else { throw PronunciationDictionaryStoreError.outdatedModelRevision }
        if let cached = self.temporalReferenceCache[key] { return cached }
        guard profile.enrollments.count >= 3 else { return [] }
        // Reserve a worst-case three-reference slot before encoding. Stable admission avoids
        // repeatedly evicting and encoding words when the active dictionary exceeds the budget.
        let reservation = 3 * 192 * 1024 * MemoryLayout<Float>.size
        guard self.temporalReferenceCache.canFit(reservation) else { return [] }
        let pronunciationGeneration = DictionaryMatcherExperiment.generation
        var result: [DictionaryMatchFrames] = []
        for capture in profile.enrollments.prefix(3) {
            try Task.checkCancellation()
            guard DictionaryMatcherExperiment.sharedFeaturesEnabled,
                  pronunciationGeneration == DictionaryMatcherExperiment.generation else { return [] }
            let samples: [Float]
            if let id = capture.inspectionID {
                let audio = try await self.pronunciationStore.inspection(for: id)
                samples = Array(audio.samples.prefix(audio.recordedSampleCount))
            } else if capture.originalAudioID != nil {
                samples = try await self.pronunciationStore.originalAudioSamples(for: capture, entryID: profile.dictionaryEntryID)
            } else { return [] }
            guard let range = DictionaryPronunciationExperiment.trimmedRange(samples) else { return [] }
            try result.append(await DictionaryTemporalEncoder.encode(Array(samples[range]), models: models))
        }
        try Task.checkCancellation()
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled,
              pronunciationGeneration == DictionaryMatcherExperiment.generation else { return [] }
        guard self.temporalReferenceCache.insert(result, for: key) else { return [] }
        return result
    }

    private func makeEnrollment(
        result: ASRResult,
        features: EncoderFeatureSequence?,
        samples: [Float]
    ) -> PronunciationEnrollmentCapture? {
        guard let features,
              let timings = result.tokenTimings,
              let first = timings.first,
              let last = timings.last
        else { return nil }
        let start = max(0, Int(floor(first.startTime / features.frameDuration)))
        let end = min(features.frameCount, Int(ceil(last.endTime / features.frameDuration)))
        guard start < end,
              let embedding = PronunciationEmbeddingMatcher.embedding(from: features, frameRange: start..<end)
        else { return nil }
        var capture = PronunciationEnrollmentCapture(
            values: embedding.values,
            sourceFrameCount: embedding.sourceFrameCount,
            modelKey: self.pronunciationModelKey
        )
        if samples.count <= 16_000 * 15,
           DictionaryPronunciationExperiment.captureEnabled || DictionaryMatcherExperiment.needsFrames
        {
            capture.pendingInspection = DictionaryAudioInspection(
                samples: samples,
                recordedSampleCount: samples.count,
                frames: [.init(offset: 0, frameDuration: features.frameDuration, hiddenSize: features.hiddenSize, values: features.values)],
                words: WordAudioChunkExtractor.words(from: timings).map { .init(text: $0.text, start: $0.startTime, end: $0.endTime) },
                selectedStart: Double(start) * features.frameDuration,
                selectedEnd: Double(end) * features.frameDuration
            )
        }
        return capture
    }

    static func applyPronunciationMatches(
        result: ASRResult,
        matches: [PronunciationWindowMatch],
        profiles: [PronunciationDictionaryProfile],
        labels: [UUID: String],
        temporalMatches: Set<TemporalMatchKey> = [],
        onAccepted: ((UUID, String, Range<Int>) -> Void)? = nil
    ) -> String {
        guard let timings = result.tokenTimings else { return result.text }
        let words = WordAudioChunkExtractor.words(from: timings)
        guard !words.isEmpty else { return result.text }

        let wordIndex = WordAudioOverlapIndex(words: words)

        struct Candidate {
            let entryID: UUID
            let label: String
            let score: Float
            let wordIndices: [Int]
        }
        var candidates: [Candidate] = []
        for match in matches {
            guard match.score.isFinite,
                  profiles.indices.contains(match.prototypeIndex),
                  let label = labels[profiles[match.prototypeIndex].dictionaryEntryID],
                  !match.frameRange.isEmpty, match.frameRange.lowerBound >= 0
            else { continue }
            let startTime = Double(match.frameRange.lowerBound) * 0.08
            let endTime = Double(match.frameRange.upperBound) * 0.08
            let indices = wordIndex.substantiallyOverlappingWordIndices(
                startTime: startTime,
                endTime: endTime
            )
            guard !indices.isEmpty else { continue }
            let profile = profiles[match.prototypeIndex]
            let heard = indices.map { words[$0].text }.joined(separator: " ")
            let temporalAccepted = temporalMatches.contains(TemporalMatchKey(prototypeIndex: match.prototypeIndex, frameRange: match.frameRange))
            guard temporalAccepted || DictionaryPronunciationDecision.accepts(score: match.score, heardText: heard, profile: profile) else { continue }
            var correctedLabel = label
            if profile.hasOriginalAudio {
                guard profile.label.caseInsensitiveCompare(label) == .orderedSame else { continue }
                correctedLabel = DictionaryPronunciationDecision.labelPreservingPossessive(
                    label, heardText: heard, profile: profile
                )
            }
            candidates.append(Candidate(entryID: profile.dictionaryEntryID, label: correctedLabel, score: match.score, wordIndices: indices))
        }

        var leaders: [Int: [(label: String, score: Float)]] = [:]
        let sortedCandidates = candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.wordIndices.first != $1.wordIndices.first { return ($0.wordIndices.first ?? 0) < ($1.wordIndices.first ?? 0) }
            return $0.label < $1.label
        }
        // Only the two strongest distinct labels per word are needed for a confidence margin.
        for candidate in sortedCandidates {
            let label = candidate.label.lowercased()
            for index in candidate.wordIndices {
                var top = leaders[index] ?? []
                if top.count < 2, !top.contains(where: { $0.label == label }) {
                    top.append((label, candidate.score))
                    leaders[index] = top
                }
            }
        }
        var claimed = Set<Int>()
        var accepted: [Candidate] = []
        for candidate in sortedCandidates {
            guard candidate.wordIndices.allSatisfy({ !claimed.contains($0) }) else { continue }
            let label = candidate.label.lowercased()
            let ambiguous = candidate.wordIndices.contains { index in
                (leaders[index] ?? []).contains { $0.label != label && $0.score > candidate.score - 0.05 }
            }
            guard !ambiguous else { continue }
            accepted.append(candidate)
            claimed.formUnion(candidate.wordIndices)
        }
        guard !accepted.isEmpty else { return result.text }

        let replacements = accepted.compactMap { candidate -> PronunciationTextReplacement? in
            guard let first = candidate.wordIndices.first, let last = candidate.wordIndices.last else { return nil }
            let heard = candidate.wordIndices.map { words[$0].text }.joined(separator: " ")
            if DictionaryNegativeEvidenceResolver.normalized(heard) != DictionaryNegativeEvidenceResolver.normalized(candidate.label) {
                onAccepted?(candidate.entryID, candidate.label, first..<(last + 1))
            }
            return PronunciationTextReplacement(wordRange: first...last, label: candidate.label)
        }
        return Self.applyingPronunciationReplacements(
            to: result.text,
            wordTexts: words.map(\.text),
            replacements: replacements
        )
    }

    static func applyingPronunciationReplacements(
        to text: String,
        wordTexts: [String],
        replacements: [PronunciationTextReplacement]
    ) -> String {
        let source = text as NSString
        var searchLocation = 0
        var ranges: [NSRange] = []
        let trimSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

        for wordText in wordTexts {
            let searchableWord = wordText.trimmingCharacters(in: trimSet)
            guard !searchableWord.isEmpty, searchLocation <= source.length else { return text }
            let searchRange = NSRange(location: searchLocation, length: source.length - searchLocation)
            let range = source.range(of: searchableWord, options: .caseInsensitive, range: searchRange)
            guard range.location != NSNotFound else { return text }
            ranges.append(range)
            searchLocation = NSMaxRange(range)
        }

        let edits = replacements.compactMap { replacement -> (NSRange, String)? in
            guard ranges.indices.contains(replacement.wordRange.lowerBound),
                  ranges.indices.contains(replacement.wordRange.upperBound)
            else { return nil }
            let start = ranges[replacement.wordRange.lowerBound].location
            let end = NSMaxRange(ranges[replacement.wordRange.upperBound])
            return (NSRange(location: start, length: end - start), replacement.label)
        }.sorted { $0.0.location > $1.0.location }

        let output = NSMutableString(string: text)
        for (range, label) in edits {
            output.replaceCharacters(in: range, with: label)
        }
        return output as String
    }

    private func logFinalBenchmark(
        samples: [Float],
        text: String,
        startedAt: TimeInterval,
        usedFallback: Bool,
        source: String = "full"
    ) {
        guard DebugLogger.diagnosticsEnabled else { return }
        let elapsedMs = Int(((Date().timeIntervalSince1970 - startedAt) * 1000).rounded())
        let audioMs = Int((Double(samples.count) / 16_000.0 * 1000).rounded())
        let rtf = audioMs > 0 ? Double(elapsedMs) / Double(audioMs) : 0
        DebugLogger.shared.debug(
            """
            ASR_BENCH provider_final_done samples=\(samples.count) audioMs=\(audioMs) \
            elapsedMs=\(elapsedMs) textChars=\(text.trimmingCharacters(in: .whitespacesAndNewlines).count) \
            rtf=\(String(format: "%.3f", rtf)) fallback=\(usedFallback) source=\(source)
            """,
            source: "ASRBenchmark"
        )
    }

    private func logStreamingBenchmark(
        sampleCount: Int,
        text: String,
        startedAt: TimeInterval,
        inputSampleCount: Int
    ) {
        guard DebugLogger.diagnosticsEnabled else { return }
        let elapsedMs = Int(((Date().timeIntervalSince1970 - startedAt) * 1000).rounded())
        let audioMs = Int((Double(sampleCount) / 16_000.0 * 1000).rounded())
        let rtf = audioMs > 0 ? Double(elapsedMs) / Double(audioMs) : 0
        DebugLogger.shared.debug(
            """
            ASR_BENCH provider_streaming_delta_done samples=\(sampleCount) inputSamples=\(inputSampleCount) \
            audioMs=\(audioMs) elapsedMs=\(elapsedMs) textChars=\(text.count) \
            rtf=\(String(format: "%.3f", rtf))
            """,
            source: "ASRBenchmark"
        )
    }

    func modelsExistOnDisk() -> Bool {
        let selectedModel = self.resolvedSpeechModel
        switch selectedModel {
        case .fluidParakeetMini, .fluidParakeetPico:
            return SpeechModelInstallationSnapshot.shared.isInstalled(modelID: selectedModel.id)
        case .parakeetTDT, .parakeetTDTv2:
            return selectedModel.isInstalled
        default:
            return false
        }
    }

    /// Preparation uses a fresh off-main check; synchronous consumers only read
    /// the event-refreshed installation snapshot for hosted compact models.
    func refreshModelsExistOnDiskAsync() async throws -> Bool {
        let model = self.resolvedSpeechModel
        guard let descriptor = model.parakeetDescriptor, descriptor.archiveURL != nil else {
            return self.modelsExistOnDisk()
        }
        let installed = try await SpeechModelInstallationSnapshot.scan([
            .init(modelID: model.id, kind: .parakeet(descriptor)),
        ])
        try Task.checkCancellation()
        return installed.contains(model.id)
    }

    var shouldClearCacheAfterCancellation: Bool {
        // Hosted downloads own their unpublished temporary files. A later load
        // cancellation must retain the verified, atomically published model.
        self.resolvedSpeechModel.parakeetDescriptor?.archiveURL == nil
    }

    func clearCache() async throws {
        let selectedModel = self.resolvedSpeechModel
        self.automaticPronunciationProfiles = []
        self.didLoadAutomaticPronunciationProfiles = false
        self.recordingGeneration = UUID()
        self.resetIncrementalSession()
        self.temporalWarmRequest = nil
        let warmTask = self.temporalWarmTask
        warmTask?.cancel()
        await warmTask?.value
        self.isReady = false
        self.streamingAsrManager = nil
        self.finalAsrManager = nil
        self.temporalModels = nil
        self.pronunciationProfilesToWarm = []
        self.edgeReferenceCache.removeAll()
        self.temporalReferenceCache.removeAll()
        self.isWordBoostingActive = false
        self.boostedVocabularyTermsCount = 0
        self.boostedTermLookup = []

        guard let descriptor = selectedModel.parakeetDescriptor else {
            throw NSError(domain: "FluidAudioProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "Choose a supported Parakeet model."])
        }
        let directory = AsrModels.defaultCacheDirectory(for: descriptor.asrModelVersion)
        try await Task.detached(priority: .userInitiated) {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }.value
        DebugLogger.shared.info("FluidAudioProvider: Deleted cache for \(selectedModel.displayName)", source: "FluidAudioProvider")
    }

    /// Provides direct access to the underlying AsrManager for advanced use cases
    /// (e.g., MeetingTranscriptionService sharing)
    var underlyingManager: AsrManager? {
        return self.streamingAsrManager
    }

    func detectBoostedTerms(in text: String, limit: Int = 2) -> [String] {
        guard self.isWordBoostingActive, !self.boostedTermLookup.isEmpty else { return [] }
        let normalizedText = " \(Self.normalizeForLookup(text)) "
        guard normalizedText.count > 2 else { return [] }

        var hits: [String] = []
        hits.reserveCapacity(min(limit, 2))
        for candidate in self.boostedTermLookup where normalizedText.contains(" \(candidate) ") {
            hits.append(candidate)
            if hits.count >= limit {
                break
            }
        }
        return hits
    }

    private static func makeBoostedTermLookup(from terms: [CustomVocabularyTerm]) -> [String] {
        var unique: Set<String> = []
        unique.reserveCapacity(terms.count * 2)
        for term in terms {
            let normalized = self.normalizeForLookup(term.text)
            if !normalized.isEmpty {
                unique.insert(normalized)
            }
            for alias in term.aliases ?? [] {
                let normalizedAlias = self.normalizeForLookup(alias)
                if !normalizedAlias.isEmpty {
                    unique.insert(normalizedAlias)
                }
            }
        }
        return unique.sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs < rhs
            }
            return lhs.count > rhs.count
        }
    }

    private static func normalizeForLookup(_ text: String) -> String {
        let lowercase = text.lowercased()
        let words = lowercase
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.joined(separator: " ")
    }
}
#else
/// Check-shim for Intel Macs where FluidAudio is not available
final class FluidAudioProvider: TranscriptionProvider {
    let name = "FluidAudio (Apple Silicon ONLY)"
    var isAvailable: Bool { false }
    var isReady: Bool { false }
    private(set) var isWordBoostingActive: Bool = false
    private(set) var boostedVocabularyTermsCount: Int = 0

    init(
        modelOverride: SettingsStore.SpeechModel? = nil,
        configureWordBoosting: Bool = true,
        enhancementOptions: FluidAudioProviderEnhancementOptions? = nil
    ) {
        // Intel stub - parameters ignored
    }

    init(meetingConfiguration configuration: MeetingFinalProcessingConfiguration) throws {
        // Intel stub - validates the meeting policy but never loads FluidAudio models
        _ = try MeetingProviderOptions.resolve(configuration)
    }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        throw NSError(
            domain: "FluidAudioProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "FluidAudio is not supported on Intel Macs"]
        )
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        throw NSError(
            domain: "FluidAudioProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "FluidAudio is not supported on Intel Macs"]
        )
    }

    func detectBoostedTerms(in text: String, limit: Int = 2) -> [String] {
        []
    }

    func resetStreamingPreviewCache() {}
}
#endif
