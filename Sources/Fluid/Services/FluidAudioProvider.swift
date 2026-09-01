import Foundation
#if arch(arm64)
import FluidAudio

/// TranscriptionProvider implementation using FluidAudio (optimized for Apple Silicon)
/// This wraps the existing FluidAudio-based ASR for use on Apple Silicon Macs.
final class FluidAudioProvider: TranscriptionProvider {
    private static let incrementalChunkingThresholdSamples = 240_000
    private static let incrementalAppendBlockSamples = 240_000

    struct PronunciationTextReplacement {
        let wordRange: ClosedRange<Int>
        let label: String
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

    private var streamingAsrManager: AsrManager?
    private var finalAsrManager: AsrManager?
    private var latestStreamingPreviewText: String = ""
    private var latestStreamingPreviewSampleCount: Int = 0
    private var latestStreamingPreviewFinishedAt: TimeInterval?
    private var incrementalSession: ParakeetIncrementalSession?
    private var incrementalAcceptedSampleCount = 0
    private(set) var isReady: Bool = false
    private(set) var isWordBoostingActive: Bool = false
    private(set) var boostedVocabularyTermsCount: Int = 0
    private var boostedTermLookup: [String] = []
    private var pronunciationModelKey = ""

    /// Optional model override - if set, uses this model instead of the global setting.
    /// Used for downloading specific models without changing the active selection.
    var modelOverride: SettingsStore.SpeechModel?
    private let configureWordBoosting: Bool
    init(modelOverride: SettingsStore.SpeechModel? = nil, configureWordBoosting: Bool = true) {
        self.modelOverride = modelOverride
        self.configureWordBoosting = configureWordBoosting
    }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        guard self.isReady == false else { return }

        let selectedModel = self.modelOverride ?? SettingsStore.shared.selectedSpeechModel
        let asrModelVersion: AsrModelVersion = selectedModel == .parakeetTDTv2 ? .v2 : .v3
        let modelVersion = selectedModel == .parakeetTDTv2 ? "v2" : "v3"
        self.pronunciationModelKey = "parakeet-\(modelVersion)"
        let cacheDirectory = AsrModels.defaultCacheDirectory().deletingLastPathComponent()
        let modelCacheDirectory = AsrModels.defaultCacheDirectory(for: asrModelVersion)
        DebugLogger.shared.info(
            "FluidAudioProvider: Starting model preparation for \(selectedModel.displayName) [version=\(modelVersion)]",
            source: "FluidAudioProvider"
        )
        DebugLogger.shared.debug("FluidAudioProvider: target cache directory=\(cacheDirectory.path)", source: "FluidAudioProvider")
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: modelCacheDirectory.path), !self.modelsExistOnDisk() {
            DebugLogger.shared.warning(
                "FluidAudioProvider: removing incomplete \(modelVersion) cache before download",
                source: "FluidAudioProvider"
            )
            try FileManager.default.removeItem(at: modelCacheDirectory)
        }
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
            models = try await AsrModels.downloadAndLoad(
                version: asrModelVersion,
                progressHandler: fluidAudioProgressHandler
            )
        } catch {
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
        if self.configureWordBoosting {
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

        self.streamingAsrManager = streamingManager
        self.finalAsrManager = finalManager
        self.latestStreamingPreviewText = ""
        self.latestStreamingPreviewSampleCount = 0
        self.latestStreamingPreviewFinishedAt = nil
        self.incrementalSession = nil
        self.incrementalAcceptedSampleCount = 0

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
        self.incrementalSession = nil
        self.incrementalAcceptedSampleCount = 0
    }

    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard let fullPreviewManager = self.streamingAsrManager else {
            throw NSError(
                domain: "FluidAudioProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "ASR manager not initialized"]
            )
        }

        let startedAt = Date().timeIntervalSince1970
        let result: ASRResult
        if SettingsStore.shared.experimentalParakeetUnifiedFinalEnabled,
           samples.count > Self.incrementalChunkingThresholdSamples,
           let incrementalManager = self.finalAsrManager ?? self.streamingAsrManager
        {
            do {
                result = try await self.transcribeIncrementalPreview(
                    samples,
                    manager: incrementalManager
                )
            } catch {
                self.resetIncrementalSession()
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
            if !SettingsStore.shared.experimentalParakeetUnifiedFinalEnabled
                || samples.count < self.incrementalAcceptedSampleCount
            {
                self.resetIncrementalSession()
            }
            result = try await fullPreviewManager.transcribe(samples, source: AudioSource.microphone)
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.latestStreamingPreviewText = text
        self.latestStreamingPreviewSampleCount = samples.count
        self.latestStreamingPreviewFinishedAt = Date().timeIntervalSince1970
        let elapsedMs = Int(((Date().timeIntervalSince1970 - startedAt) * 1000).rounded())
        let audioMs = Int((Double(samples.count) / 16_000.0 * 1000).rounded())
        let rtf = audioMs > 0 ? Double(elapsedMs) / Double(audioMs) : 0
        DebugLogger.shared.info(
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
            enabled: SettingsStore.shared.experimentalParakeetUnifiedFinalEnabled,
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
            self.incrementalAcceptedSampleCount = totalSampleCount
            let result = try await session.preview()
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
            self.resetIncrementalSession()
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    func transcribeDictionaryTraining(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard let manager = self.streamingAsrManager else {
            throw NSError(
                domain: "FluidAudioProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "ASR manager not initialized"]
            )
        }
        let shouldCapture = SettingsStore.shared.pronunciationMatchingEnabled
        await manager.setPronunciationCustomizationEnabled(shouldCapture)
        do {
            let result = try await manager.transcribe(samples, source: AudioSource.microphone)
            let features = await manager.consumePronunciationEncoderFeatures()
            await manager.setPronunciationCustomizationEnabled(false)
            return ASRTranscriptionResult(
                text: result.text,
                confidence: result.confidence,
                pronunciationEnrollment: shouldCapture
                    ? self.makeEnrollment(result: result, features: features)
                    : nil
            )
        } catch {
            _ = await manager.consumePronunciationEncoderFeatures()
            await manager.setPronunciationCustomizationEnabled(false)
            throw error
        }
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        defer { self.resetIncrementalSession() }
        guard let manager = self.finalAsrManager ?? self.streamingAsrManager else {
            throw NSError(
                domain: "FluidAudioProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "ASR manager not initialized"]
            )
        }

        if SettingsStore.shared.experimentalParakeetUnifiedFinalEnabled,
           samples.count > Self.incrementalChunkingThresholdSamples,
           self.incrementalSession != nil
        {
            do {
                let startedAt = Date().timeIntervalSince1970
                let result = try await self.transcribeIncrementalFinal(samples)
                self.logFinalBenchmark(
                    samples: samples,
                    text: result.text,
                    startedAt: startedAt,
                    usedFallback: false
                )
                return result
            } catch {
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
            let result = try await self.transcribeFinalResult(samples, manager: manager)
            self.logFinalBenchmark(samples: samples, text: result.text, startedAt: startedAt, usedFallback: false)
            return result
        } catch {
            guard let fallback = self.streamingAsrManager, fallback !== manager else {
                throw error
            }
            DebugLogger.shared.warning(
                "FluidAudioProvider: Boosted final transcription failed (\(error.localizedDescription)), retrying without vocab boost",
                source: "FluidAudioProvider"
            )
            let startedAt = Date().timeIntervalSince1970
            let result = try await self.transcribeFinalResult(samples, manager: fallback)
            self.logFinalBenchmark(samples: samples, text: result.text, startedAt: startedAt, usedFallback: true)
            return result
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
            self.incrementalSession = try await manager.makeIncrementalSession(source: .microphone)
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
        if samples.count > self.incrementalAcceptedSampleCount {
            try await self.appendIncrementalSamples(samples, to: session)
        }
        let result = try await session.finish(finalAudioSamples: samples)
        let reusedWindows = await session.finalizedWindowCount
        DebugLogger.shared.info(
            "FluidAudioProvider: Incremental final reused \(reusedWindows) stable Parakeet windows",
            source: "FluidAudioProvider"
        )
        return ASRTranscriptionResult(text: result.text, confidence: result.confidence)
    }

    private func appendIncrementalSamples(
        _ samples: [Float],
        to session: ParakeetIncrementalSession
    ) async throws {
        var offset = self.incrementalAcceptedSampleCount
        while offset < samples.count {
            let end = min(offset + Self.incrementalAppendBlockSamples, samples.count)
            try await session.append(Array(samples[offset..<end]))
            offset = end
            self.incrementalAcceptedSampleCount = offset
        }
    }

    private func resetIncrementalSession() {
        self.incrementalSession = nil
        self.incrementalAcceptedSampleCount = 0
    }

    private func transcribeFinalResult(_ samples: [Float], manager: AsrManager) async throws -> ASRTranscriptionResult {
        let matchingEnabled = SettingsStore.shared.pronunciationMatchingEnabled && samples.count <= 16_000 * 15
        let dictionaryLabels = Self.dictionaryLabels(
            from: SettingsStore.shared.customDictionaryEntries
        )
        let profiles: [PronunciationDictionaryProfile]
        if matchingEnabled {
            let storedProfiles = await PronunciationDictionaryStore.shared.profiles(
                modelKey: self.pronunciationModelKey
            )
            profiles = storedProfiles.compactMap { storedProfile in
                guard storedProfile.enrollments.count >= 3,
                      let currentLabel = dictionaryLabels[storedProfile.dictionaryEntryID]
                else { return nil }
                var profile = storedProfile
                profile.label = currentLabel
                return profile
            }
        } else {
            profiles = []
        }
        await manager.setPronunciationCustomizationEnabled(!profiles.isEmpty)
        do {
            let result = try await manager.transcribe(samples, source: AudioSource.microphone)
            let features = await manager.consumePronunciationEncoderFeatures()
            await manager.setPronunciationCustomizationEnabled(false)
            guard let features, !profiles.isEmpty else {
                return ASRTranscriptionResult(text: result.text, confidence: result.confidence)
            }
            let startedAt = Date().timeIntervalSince1970
            let corrected = self.applyPronunciationMatches(result: result, features: features, profiles: profiles)
            let elapsedMs = Int(((Date().timeIntervalSince1970 - startedAt) * 1000).rounded())
            DebugLogger.shared.info(
                "PRONUNCIATION_MATCH profiles=\(profiles.count) elapsedMs=\(elapsedMs) changed=\(corrected != result.text)",
                source: "PronunciationMatching"
            )
            return ASRTranscriptionResult(text: corrected, confidence: result.confidence)
        } catch {
            _ = await manager.consumePronunciationEncoderFeatures()
            await manager.setPronunciationCustomizationEnabled(false)
            throw error
        }
    }

    private func makeEnrollment(
        result: ASRResult,
        features: EncoderFeatureSequence?
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
        return PronunciationEnrollmentCapture(
            values: embedding.values,
            sourceFrameCount: embedding.sourceFrameCount,
            modelKey: self.pronunciationModelKey
        )
    }

    private func applyPronunciationMatches(
        result: ASRResult,
        features: EncoderFeatureSequence,
        profiles: [PronunciationDictionaryProfile]
    ) -> String {
        guard let timings = result.tokenTimings else { return result.text }
        let words = WordAudioChunkExtractor.words(from: timings)
        guard !words.isEmpty else { return result.text }

        let usableProfiles = profiles.compactMap { profile -> (PronunciationDictionaryProfile, PronunciationEmbedding)? in
            let embeddings = profile.enrollments.map {
                PronunciationEmbedding(values: $0.values, sourceFrameCount: $0.sourceFrameCount)
            }
            guard profile.hiddenSize == features.hiddenSize,
                  let prototype = PronunciationEmbeddingMatcher.prototype(from: embeddings)
            else { return nil }
            return (profile, prototype)
        }
        let matches = PronunciationEmbeddingMatcher.bestMatches(
            prototypes: usableProfiles.map { $0.1 },
            in: features
        )

        struct Candidate {
            let label: String
            let score: Float
            let wordIndices: [Int]
        }
        var candidates: [Candidate] = []
        for (index, match) in matches.enumerated() {
            guard let match, match.score >= PronunciationCustomizationDefaults.acceptanceThreshold else { continue }
            let startTime = Double(match.frameRange.lowerBound) * features.frameDuration
            let endTime = Double(match.frameRange.upperBound) * features.frameDuration
            let indices = WordAudioChunkExtractor.substantiallyOverlappingWordIndices(
                in: words,
                startTime: startTime,
                endTime: endTime
            )
            guard !indices.isEmpty else { continue }
            candidates.append(Candidate(label: usableProfiles[index].0.label, score: match.score, wordIndices: indices))
        }

        var claimed = Set<Int>()
        var accepted: [Candidate] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            guard candidate.wordIndices.allSatisfy({ !claimed.contains($0) }) else { continue }
            accepted.append(candidate)
            claimed.formUnion(candidate.wordIndices)
            DebugLogger.shared.info(
                "PRONUNCIATION_HIT score=\(String(format: "%.3f", candidate.score)) words=\(candidate.wordIndices)",
                source: "PronunciationMatching"
            )
        }
        guard !accepted.isEmpty else { return result.text }

        let replacements = accepted.compactMap { candidate -> PronunciationTextReplacement? in
            guard let first = candidate.wordIndices.first, let last = candidate.wordIndices.last else { return nil }
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
        let elapsedMs = Int(((Date().timeIntervalSince1970 - startedAt) * 1000).rounded())
        let audioMs = Int((Double(samples.count) / 16_000.0 * 1000).rounded())
        let rtf = audioMs > 0 ? Double(elapsedMs) / Double(audioMs) : 0
        DebugLogger.shared.info(
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
        let elapsedMs = Int(((Date().timeIntervalSince1970 - startedAt) * 1000).rounded())
        let audioMs = Int((Double(sampleCount) / 16_000.0 * 1000).rounded())
        let rtf = audioMs > 0 ? Double(elapsedMs) / Double(audioMs) : 0
        DebugLogger.shared.info(
            """
            ASR_BENCH provider_streaming_delta_done samples=\(sampleCount) inputSamples=\(inputSampleCount) \
            audioMs=\(audioMs) elapsedMs=\(elapsedMs) textChars=\(text.count) \
            rtf=\(String(format: "%.3f", rtf))
            """,
            source: "ASRBenchmark"
        )
    }

    func modelsExistOnDisk() -> Bool {
        let selectedModel = self.modelOverride ?? SettingsStore.shared.selectedSpeechModel
        switch selectedModel {
        case .parakeetTDT, .parakeetTDTv2:
            return selectedModel.isInstalled
        default:
            return false
        }
    }

    func clearCache() async throws {
        self.resetIncrementalSession()
        let baseCacheDir = AsrModels.defaultCacheDirectory().deletingLastPathComponent()
        let selectedModel = self.modelOverride ?? SettingsStore.shared.selectedSpeechModel
        DebugLogger.shared.info(
            "FluidAudioProvider: clearCache called for \(selectedModel.displayName)",
            source: "FluidAudioProvider"
        )

        let start = Date()
        if selectedModel == .parakeetTDTv2 {
            // Clear v2 cache only
            let v2CacheDir = baseCacheDir.appendingPathComponent("parakeet-tdt-0.6b-v2-coreml")
            if FileManager.default.fileExists(atPath: v2CacheDir.path) {
                try FileManager.default.removeItem(at: v2CacheDir)
                DebugLogger.shared.info("FluidAudioProvider: Deleted Parakeet v2 cache", source: "FluidAudioProvider")
            }
        } else {
            // Clear v3 cache only (default)
            let v3CacheDir = baseCacheDir.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")
            if FileManager.default.fileExists(atPath: v3CacheDir.path) {
                try FileManager.default.removeItem(at: v3CacheDir)
                DebugLogger.shared.info("FluidAudioProvider: Deleted Parakeet v3 cache", source: "FluidAudioProvider")
            }
        }

        DebugLogger.shared.debug(
            "FluidAudioProvider: clearCache completed in \(String(format: "%.3f", Date().timeIntervalSince(start)))s",
            source: "FluidAudioProvider"
        )

        self.isReady = false
        self.streamingAsrManager = nil
        self.finalAsrManager = nil
        self.isWordBoostingActive = false
        self.boostedVocabularyTermsCount = 0
        self.boostedTermLookup = []
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

    init(modelOverride: SettingsStore.SpeechModel? = nil, configureWordBoosting: Bool = true) {
        // Intel stub - parameter ignored
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
