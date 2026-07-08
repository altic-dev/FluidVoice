import Foundation

#if arch(arm64)
import FluidAudio

@available(macOS 15.0, *)
final class ExternalCoreMLTranscriptionProvider: TranscriptionProvider {
    let name = "External CoreML"

    var isAvailable: Bool { true }
    private(set) var isReady: Bool = false
    var prefersNativeFileTranscription: Bool { true }
    private let streamingPreviewMaxSeconds: Double = 12

    private var cohereManager: CohereTranscribeAsrManager?
    private let modelOverride: SettingsStore.SpeechModel?
    private var loadedManifest: ExternalCoreMLManifestIdentity?
    private var coherePromptTemplate: [Int] = []
    private var cohereLanguageTokenIDs: [SettingsStore.CohereLanguage: Int] = [:]

    init(modelOverride: SettingsStore.SpeechModel? = nil) {
        self.modelOverride = modelOverride
    }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        guard self.isReady == false else { return }

        let model = self.modelOverride ?? SettingsStore.shared.selectedSpeechModel
        DebugLogger.shared.info(
            "ExternalCoreML: prepare requested for model=\(model.rawValue)",
            source: "ExternalCoreML"
        )
        guard let spec = model.externalCoreMLSpec else {
            DebugLogger.shared.error(
                "ExternalCoreML: missing spec for model=\(model.rawValue)",
                source: "ExternalCoreML"
            )
            throw Self.makeError("No external CoreML spec registered for \(model.displayName).")
        }
        guard let directory = Self.artifactsDirectory(for: model, spec: spec) else {
            DebugLogger.shared.error(
                "ExternalCoreML: unable to resolve cache directory for model=\(model.rawValue)",
                source: "ExternalCoreML"
            )
            throw Self.makeError("Unable to resolve a cache directory for \(model.displayName).")
        }

        try await self.ensureArtifactsPresent(
            for: model,
            spec: spec,
            at: directory,
            progressHandler: progressHandler
        )
        try Task.checkCancellation()

        self.loadedManifest = try spec.loadManifest(at: directory)
        try self.loadCoherePromptConfigurationIfNeeded(at: directory, backend: spec.backend)

        switch spec.backend {
        case .cohereTranscribe:
            let manager = CohereTranscribeAsrManager()
            try self.invalidateCompiledCohereCacheIfNeeded(at: directory)
            let computeSummary = [
                String(describing: spec.computeConfiguration.frontend),
                String(describing: spec.computeConfiguration.encoder),
                String(describing: spec.computeConfiguration.crossKV),
                String(describing: spec.computeConfiguration.decoder),
            ].joined(separator: "/")
            DebugLogger.shared.info(
                "ExternalCoreML: loading Cohere models [splitCompute=\(computeSummary), maxAudioSamples=\(self.loadedManifest?.maxAudioSamples ?? 0)]",
                source: "ExternalCoreML"
            )
            progressHandler?(.loading)
            try await manager.loadModels(from: directory, computeConfiguration: spec.computeConfiguration)
            try Task.checkCancellation()
            self.cohereManager = manager
            self.persistCompiledCohereCacheStamp(at: directory)
        }

        try Task.checkCancellation()
        self.isReady = true
        DebugLogger.shared.info(
            "ExternalCoreML: provider ready for model=\(model.rawValue)",
            source: "ExternalCoreML"
        )
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeFinal(samples)
    }

    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        let previewSamples = self.previewSamples(for: samples)
        DebugLogger.shared.debug(
            "ExternalCoreML: streaming preview request [samples=\(samples.count), previewSamples=\(previewSamples.count)]",
            source: "ExternalCoreML"
        )
        guard let manager = self.cohereManager else {
            DebugLogger.shared.error(
                "ExternalCoreML: streaming preview requested before manager initialization",
                source: "ExternalCoreML"
            )
            throw Self.makeError("External CoreML model is not initialized.")
        }

        let promptIDs = self.coherePromptIDsForCurrentLanguage()
        let text = try await manager.transcribe(
            audioSamples: self.paddedSamplesToModelLimit(previewSamples),
            promptIDs: promptIDs.isEmpty ? nil : promptIDs
        )
        return ASRTranscriptionResult(text: text, confidence: 1.0)
    }

    func transcribeFile(at fileURL: URL) async throws -> ASRTranscriptionResult {
        guard let manager = self.cohereManager else {
            DebugLogger.shared.error(
                "ExternalCoreML: file transcription requested before manager initialization",
                source: "ExternalCoreML"
            )
            throw Self.makeError("External CoreML model is not initialized.")
        }

        let startedAt = Date()
        DebugLogger.shared.info(
            "ExternalCoreML: native file transcription start [file=\(fileURL.lastPathComponent)]",
            source: "ExternalCoreML"
        )
        let promptIDs = self.coherePromptIDsForCurrentLanguage()
        let text = try await manager.transcribe(
            audioFileAt: fileURL,
            promptIDs: promptIDs.isEmpty ? nil : promptIDs
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        DebugLogger.shared.info(
            "ExternalCoreML: native file transcription finished in \(String(format: "%.2f", elapsed))s [chars=\(text.count)]",
            source: "ExternalCoreML"
        )
        return ASRTranscriptionResult(text: text, confidence: 1.0)
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard let manager = self.cohereManager else {
            DebugLogger.shared.error(
                "ExternalCoreML: transcribe requested before manager initialization",
                source: "ExternalCoreML"
            )
            throw Self.makeError("External CoreML model is not initialized.")
        }
        let startedAt = Date()
        let sampleRate = Double((self.modelOverride ?? SettingsStore.shared.selectedSpeechModel).externalCoreMLSpec?.expectedSampleRate ?? 16_000)
        let audioSeconds = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        DebugLogger.shared.debug(
            "ExternalCoreML: transcribing \(samples.count) samples [audioSeconds=\(String(format: "%.2f", audioSeconds))]",
            source: "ExternalCoreML"
        )
        let promptIDs = self.coherePromptIDsForCurrentLanguage()
        let text = try await manager.transcribe(
            audioSamples: samples,
            promptIDs: promptIDs.isEmpty ? nil : promptIDs
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        let rtf = audioSeconds > 0 ? elapsed / audioSeconds : 0
        DebugLogger.shared.info(
            "ExternalCoreML: transcription finished in \(String(format: "%.2f", elapsed))s [audioSeconds=\(String(format: "%.2f", audioSeconds)), rtf=\(String(format: "%.2fx", rtf)), chars=\(text.count)]",
            source: "ExternalCoreML"
        )
        return ASRTranscriptionResult(text: text, confidence: 1.0)
    }

    func modelsExistOnDisk() -> Bool {
        let model = self.modelOverride ?? SettingsStore.shared.selectedSpeechModel
        guard let spec = model.externalCoreMLSpec,
              let directory = Self.artifactsDirectory(for: model, spec: spec)
        else {
            return false
        }
        return spec.validatesInstalledArtifacts(at: directory)
    }

    func clearCache() async throws {
        let model = self.modelOverride ?? SettingsStore.shared.selectedSpeechModel
        guard let spec = model.externalCoreMLSpec,
              let directory = Self.artifactsDirectory(for: model, spec: spec)
        else {
            self.isReady = false
            self.cohereManager = nil
            return
        }

        let compiledDirectory = CohereTranscribeAsrModels.compiledArtifactsDirectory(for: directory)

        if FileManager.default.fileExists(atPath: compiledDirectory.path) {
            DebugLogger.shared.info(
                "ExternalCoreML: clearing compiled cache at \(compiledDirectory.path)",
                source: "ExternalCoreML"
            )
            try FileManager.default.removeItem(at: compiledDirectory)
        }

        if FileManager.default.fileExists(atPath: directory.path), spec.isAppManagedArtifactsDirectory(directory) {
            DebugLogger.shared.info(
                "ExternalCoreML: removing downloaded artifacts at \(directory.path)",
                source: "ExternalCoreML"
            )
            try FileManager.default.removeItem(at: directory)
        } else if FileManager.default.fileExists(atPath: directory.path) {
            DebugLogger.shared.warning(
                "ExternalCoreML: skipping deletion for non-managed artifacts directory at \(directory.path)",
                source: "ExternalCoreML"
            )
        }

        self.isReady = false
        self.cohereManager = nil
        self.loadedManifest = nil
        self.coherePromptTemplate = []
        self.cohereLanguageTokenIDs = [:]
        DebugLogger.shared.info(
            "ExternalCoreML: provider reset after cache clear",
            source: "ExternalCoreML"
        )
    }

    private func ensureArtifactsPresent(
        for model: SettingsStore.SpeechModel,
        spec: ExternalCoreMLASRModelSpec,
        at directory: URL,
        progressHandler: ((ModelPreparationProgress) -> Void)?
    ) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let isManagedDirectory = spec.isAppManagedArtifactsDirectory(directory)

        // `validateArtifacts` proves the required entries exist and the manifest JSON decodes, but
        // it does NOT byte-check the `.mlpackage` binaries — a network proxy can have returned an
        // HTML block page (HTTP 200) in place of one, persisting markup as a model file. Re-sniff
        // the present artifacts so such a payload forces the downloader to run (it then deletes +
        // re-fetches the corrupt files via `needsDownload`) instead of being trusted forever. The
        // outdated-bundle-stamp refresh below is preserved and takes precedence: a stamp-stale
        // managed cache is still fully removed even if it is also markup-corrupt, so the bundle
        // is wholly refreshed rather than only the corrupt files re-fetched. See #353.
        if spec.validateArtifacts(at: directory) {
            if isManagedDirectory, spec.artifactBundleStampMatches(at: directory) == false {
                DebugLogger.shared.warning(
                    "ExternalCoreML: refreshing managed artifacts for \(directory.lastPathComponent) due to outdated bundle stamp",
                    source: "ExternalCoreML"
                )
                try FileManager.default.removeItem(at: directory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } else if Self.cachedArtifactsAreMarkupCorrupt(spec: spec, directory: directory) {
                DebugLogger.shared.warning(
                    "ExternalCoreML: cached artifacts for \(directory.lastPathComponent) contain an HTML/markup payload (corrupt); re-downloading",
                    source: "ExternalCoreML"
                )
            } else {
                DebugLogger.shared.info(
                    "ExternalCoreML: artifact validation passed for \(directory.lastPathComponent)",
                    source: "ExternalCoreML"
                )
                return
            }
        }

        if spec.validateArtifacts(at: directory),
           !Self.cachedArtifactsAreMarkupCorrupt(spec: spec, directory: directory)
        {
            DebugLogger.shared.info(
                "ExternalCoreML: artifact validation passed for \(directory.lastPathComponent)",
                source: "ExternalCoreML"
            )
            return
        }

        guard let owner = spec.repositoryOwner, let repo = spec.repositoryName else {
            throw Self.makeError("Missing repository metadata for \(model.displayName).")
        }

        DebugLogger.shared.info(
            "ExternalCoreML: downloading missing artifacts from \(owner)/\(repo)",
            source: "ExternalCoreML"
        )
        progressHandler?(.preparingDownload)

        let downloader = HuggingFaceModelDownloader(
            owner: owner,
            repo: repo,
            revision: spec.repositoryRevision,
            requiredItems: spec.requiredEntries.map { .init(path: $0, isDirectory: $0.hasSuffix(".mlpackage")) }
        )
        try await downloader.ensureModelsPresent(at: directory) { progress, item in
            DebugLogger.shared.debug(
                "ExternalCoreML: download progress \(Int(progress * 100))% [\(item)]",
                source: "ExternalCoreML"
            )
            // The managed-cache stamp below is part of installation truth. Keep the transfer
            // below 100% until structural validation succeeds and that stamp is persisted.
            progressHandler?(.downloading(progress))
        }
        try Task.checkCancellation()

        progressHandler?(.optimizing)
        do {
            try spec.validateArtifactsOrThrow(at: directory)
        } catch {
            throw Self.makeError(error.localizedDescription)
        }

        if isManagedDirectory {
            spec.persistArtifactBundleStamp(at: directory)
        }
        SettingsStore.shared.setExternalCoreMLArtifactsDirectory(directory, for: model)
    }

    private static func artifactsDirectory(
        for model: SettingsStore.SpeechModel,
        spec: ExternalCoreMLASRModelSpec
    ) -> URL? {
        SettingsStore.shared.externalCoreMLArtifactsDirectory(for: model) ?? spec.defaultCacheDirectory
    }

    /// `true` if any required cached artifact is an HTML/markup payload instead of model data — a
    /// corrupt cache a markup-blind `validateArtifacts` check would otherwise trust (#353). Reuses
    /// the downloader's shared byte-sniff; conservative on read errors (never flags on uncertainty).
    private static func cachedArtifactsAreMarkupCorrupt(
        spec: ExternalCoreMLASRModelSpec,
        directory: URL
    ) -> Bool {
        HuggingFaceModelDownloader.cachedPayloadContainsMarkup(
            root: directory,
            relativePaths: spec.requiredEntries
        )
    }

    private static func makeError(_ description: String) -> NSError {
        NSError(
            domain: "ExternalCoreMLTranscriptionProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    private func invalidateCompiledCohereCacheIfNeeded(at directory: URL) throws {
        guard let manifest = self.loadedManifest else { return }

        let compiledDirectory = CohereTranscribeAsrModels.compiledArtifactsDirectory(for: directory)
        guard FileManager.default.fileExists(atPath: compiledDirectory.path) else { return }

        let currentStamp = Self.compiledCohereCacheStamp(for: manifest)
        let stampURL = Self.compiledCohereCacheStampURL(for: directory)
        let previousStamp = try? String(contentsOf: stampURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard previousStamp != currentStamp else { return }

        let reason = previousStamp == nil ? "missing cache stamp" : "manifest changed"
        DebugLogger.shared.warning(
            "ExternalCoreML: clearing stale compiled Cohere cache [reason=\(reason)]",
            source: "ExternalCoreML"
        )
        try FileManager.default.removeItem(at: compiledDirectory)
    }

    private func persistCompiledCohereCacheStamp(at directory: URL) {
        guard let manifest = self.loadedManifest else { return }
        let stampURL = Self.compiledCohereCacheStampURL(for: directory)
        let stamp = Self.compiledCohereCacheStamp(for: manifest)
        try? stamp.write(to: stampURL, atomically: true, encoding: .utf8)
    }

    private static func compiledCohereCacheStampURL(for directory: URL) -> URL {
        directory.appendingPathComponent(".cohere_compiled_cache_stamp", isDirectory: false)
    }

    private static func compiledCohereCacheStamp(for manifest: ExternalCoreMLManifestIdentity) -> String {
        [
            manifest.modelID,
            String(manifest.sampleRate),
            String(manifest.maxAudioSamples),
            String(manifest.maxAudioSeconds),
            String(manifest.overlapSamples ?? 0),
        ].joined(separator: "|")
    }

    private func loadCoherePromptConfigurationIfNeeded(at directory: URL, backend: ExternalCoreMLASRBackend) throws {
        guard backend == .cohereTranscribe else { return }

        let manifestURL = directory.appendingPathComponent("coreml_manifest.json", isDirectory: false)
        let data = try Data(contentsOf: manifestURL)
        guard
            let rawManifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawPromptIDs = rawManifest["prompt_ids"] as? [Any],
            let idToToken = rawManifest["id_to_token"] as? [String]
        else {
            return
        }
        let promptIDs = rawPromptIDs.compactMap { ($0 as? NSNumber)?.intValue }
        guard promptIDs.count == rawPromptIDs.count else { return }

        let tokenToID = Dictionary(uniqueKeysWithValues: idToToken.enumerated().map { ($0.element, $0.offset) })
        self.coherePromptTemplate = promptIDs
        self.cohereLanguageTokenIDs = Dictionary(
            uniqueKeysWithValues: SettingsStore.CohereLanguage.allCases.compactMap { language in
                tokenToID[language.tokenString].map { (language, $0) }
            }
        )
    }

    private func coherePromptIDsForCurrentLanguage() -> [Int] {
        let promptTemplate = self.coherePromptTemplate
        guard promptTemplate.isEmpty == false else { return [] }

        let languageTokenIDs = self.cohereLanguageTokenIDs
        guard languageTokenIDs.isEmpty == false else { return promptTemplate }

        let targetLanguage = SettingsStore.shared.selectedCohereLanguage
        guard let targetTokenID = languageTokenIDs[targetLanguage] else { return promptTemplate }

        let supportedTokenIDs = Set(languageTokenIDs.values)
        return promptTemplate.map { tokenID in
            supportedTokenIDs.contains(tokenID) ? targetTokenID : tokenID
        }
    }

    private func previewSamples(for samples: [Float]) -> [Float] {
        let sampleRate = self.loadedManifest?.sampleRate
            ?? (self.modelOverride ?? SettingsStore.shared.selectedSpeechModel).externalCoreMLSpec?.expectedSampleRate
            ?? 16_000
        let maxPreviewSamples = Int(Double(sampleRate) * self.streamingPreviewMaxSeconds)
        guard samples.count > maxPreviewSamples else { return samples }
        return Array(samples.suffix(maxPreviewSamples))
    }

    private func paddedSamplesToModelLimit(_ samples: [Float]) -> [Float] {
        let maxAudioSamples = self.loadedManifest?.maxAudioSamples ?? samples.count
        guard maxAudioSamples > 0 else { return samples }

        if samples.count == maxAudioSamples {
            return samples
        }

        if samples.count > maxAudioSamples {
            return Array(samples.suffix(maxAudioSamples))
        }

        return samples + Array(repeating: 0, count: maxAudioSamples - samples.count)
    }
}

#else

final class ExternalCoreMLTranscriptionProvider: TranscriptionProvider {
    let name = "External CoreML"
    let isAvailable = false
    let isReady = false

    init(modelOverride: SettingsStore.SpeechModel? = nil) {}

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)? = nil) async throws {
        throw NSError(
            domain: "ExternalCoreMLTranscriptionProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "External CoreML models are only supported on Apple Silicon Macs."]
        )
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        throw NSError(
            domain: "ExternalCoreMLTranscriptionProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "External CoreML models are only supported on Apple Silicon Macs."]
        )
    }
}

#endif
