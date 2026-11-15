import Foundation

#if arch(arm64)
@preconcurrency import CoreML

/// SenseVoiceSmall (FunAudioLLM) via the CoreML export in `FluidInference/sensevoice-small-coreml`.
///
/// The model is non-autoregressive CTC: one forward pass covers the whole clip in milliseconds,
/// so live preview simply re-transcribes everything recorded so far (`ASRService` drives the
/// cadence via `SpeechModel.streamingPreviewIntervalSeconds`).
@available(macOS 14.0, *)
final class SenseVoiceProvider: TranscriptionProvider {
    let name = "SenseVoice Small"
    var isAvailable: Bool { true }
    private(set) var isReady: Bool = false

    private var engine: SenseVoiceEngine?

    /// Point FluidVoice at an existing model folder instead of downloading, e.g.
    /// `defaults write <bundle-id> SenseVoiceModelDirectory "~/path/sensevoice-small-coreml"`
    /// or the `FLUIDVOICE_SENSEVOICE_MODEL_DIR` environment variable.
    nonisolated static let directoryOverrideDefaultsKey = "SenseVoiceModelDirectory"
    nonisolated static let directoryOverrideEnvironmentKey = "FLUIDVOICE_SENSEVOICE_MODEL_DIR"

    private nonisolated static let repositoryOwner = "FluidInference"
    private nonisolated static let repositoryName = "sensevoice-small-coreml"
    private nonisolated static let repositoryRevision = "main"
    private nonisolated static let folderHint = "sensevoice-small-coreml"
    private static let logSource = "SenseVoice"

    // MARK: - Artifacts

    /// Files of a compiled bundle as published in the repo (no `metadata.json`, so the shared
    /// downloader's `.mlmodelc` directory check cannot be used; list the files explicitly).
    private nonisolated static func bundleFiles(_ bundle: String) -> [String] {
        [
            "\(bundle)/coremldata.bin",
            "\(bundle)/model.mil",
            "\(bundle)/weights/weight.bin",
            "\(bundle)/analytics/coremldata.bin",
        ]
    }

    /// Files a variant needs on disk. `analytics/` is optional for loading, so it is not required
    /// when validating a user-supplied folder.
    private nonisolated static func requiredFiles(for variant: SenseVoiceEncoderVariant) -> [String] {
        let essentials: (String) -> [String] = { bundle in
            ["\(bundle)/coremldata.bin", "\(bundle)/model.mil", "\(bundle)/weights/weight.bin"]
        }
        return essentials(SenseVoiceConstants.preprocessorBundle)
            + essentials(variant.bundleName)
            + [SenseVoiceConstants.vocabularyFile]
    }

    private nonisolated static func downloadItems(for variant: SenseVoiceEncoderVariant) -> [HuggingFaceModelDownloader.ModelItem] {
        (self.bundleFiles(SenseVoiceConstants.preprocessorBundle)
            + self.bundleFiles(variant.bundleName)
            + [SenseVoiceConstants.vocabularyFile, SenseVoiceConstants.configFile])
            .map { .init(path: $0, isDirectory: false) }
    }

    nonisolated static func isComplete(_ variant: SenseVoiceEncoderVariant, at directory: URL) -> Bool {
        self.requiredFiles(for: variant).allSatisfy { relative in
            let url = directory.appendingPathComponent(relative)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0
            else { return false }
            return HuggingFaceModelDownloader.cachedFileIsMarkup(at: url) == false
        }
    }

    nonisolated static var managedDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(self.folderHint, isDirectory: true)
    }

    nonisolated static var overrideDirectory: URL? {
        let raw = ProcessInfo.processInfo.environment[self.directoryOverrideEnvironmentKey]
            ?? UserDefaults.standard.string(forKey: self.directoryOverrideDefaultsKey)
        guard let raw, raw.trimmingCharacters(in: .whitespaces).isEmpty == false else { return nil }
        let path = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Whether this Mac exposes a Neural Engine to CoreML. int8/fp16 encoders are only correct there.
    nonisolated static var hasNeuralEngine: Bool {
        MLModel.availableComputeDevices.contains { device in
            if case .neuralEngine = device { return true }
            return false
        }
    }

    /// Variants to try, best first: int8 (smallest, ANE) → fp16 (ANE) → fp32 (any device).
    nonisolated static var preferredVariants: [SenseVoiceEncoderVariant] {
        self.hasNeuralEngine ? [.int8, .fp16, .fp32] : [.fp32]
    }

    /// The variant to download when nothing usable is cached.
    nonisolated static var downloadVariant: SenseVoiceEncoderVariant {
        self.hasNeuralEngine ? .int8 : .fp32
    }

    /// Installed folder and the variants usable in it, override folder first.
    nonisolated static func installedArtifacts() -> (directory: URL, variants: [SenseVoiceEncoderVariant])? {
        for directory in [self.overrideDirectory, self.managedDirectory].compactMap({ $0 }) {
            let variants = self.preferredVariants.filter { self.isComplete($0, at: directory) }
            if variants.isEmpty == false { return (directory, variants) }
        }
        return nil
    }

    func modelsExistOnDisk() -> Bool {
        Self.installedArtifacts() != nil
    }

    // MARK: - Preparation

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        guard self.isReady == false else { return }

        if let override = Self.overrideDirectory, Self.installedArtifacts()?.directory != override {
            DebugLogger.shared.warning(
                "SenseVoice: override folder \(override.path) has no usable model; falling back to the managed cache",
                source: Self.logSource
            )
        }

        var installed = Self.installedArtifacts()
        if installed == nil {
            installed = try await self.download(progressHandler: progressHandler)
        }
        guard let installed else {
            throw Self.makeError("SenseVoice model files are missing after download.")
        }
        try Task.checkCancellation()

        // First load compiles the encoder for the Neural Engine, which can take a minute or two;
        // later loads hit the system's compiled-model cache and take well under a second.
        progressHandler?(.optimizing)
        let engine = try await Self.loadFirstWorkingEngine(directory: installed.directory, variants: installed.variants)
        try Task.checkCancellation()
        self.engine = engine
        self.isReady = true
        DebugLogger.shared.info(
            "SenseVoice: provider ready [variant=\(engine.variant.rawValue), dir=\(installed.directory.path), ane=\(Self.hasNeuralEngine), chunk=\(Int(engine.maxChunkSeconds))s]",
            source: Self.logSource
        )
    }

    private func download(
        progressHandler: ((ModelPreparationProgress) -> Void)?
    ) async throws -> (directory: URL, variants: [SenseVoiceEncoderVariant])? {
        guard let directory = Self.managedDirectory else {
            throw Self.makeError("Unable to resolve a cache directory for SenseVoice.")
        }
        let variant = Self.downloadVariant
        DebugLogger.shared.info(
            "SenseVoice: downloading \(variant.rawValue) encoder + preprocessor from \(Self.repositoryOwner)/\(Self.repositoryName)",
            source: Self.logSource
        )
        progressHandler?(.preparingDownload)
        let downloader = HuggingFaceModelDownloader(
            owner: Self.repositoryOwner,
            repo: Self.repositoryName,
            revision: Self.repositoryRevision,
            requiredItems: Self.downloadItems(for: variant)
        )
        try await downloader.ensureModelsPresent(at: directory) { progress, _ in
            progressHandler?(.downloading(progress))
        }
        try Task.checkCancellation()
        guard Self.isComplete(variant, at: directory) else {
            throw Self.makeError("SenseVoice download finished but files are incomplete at \(directory.path).")
        }
        return (directory, [variant])
    }

    /// Loads variants in preference order and keeps the first one whose warm-up output is
    /// finite. Warm-up also moves the one-off ANE specialisation cost out of the first dictation.
    private static func loadFirstWorkingEngine(
        directory: URL,
        variants: [SenseVoiceEncoderVariant]
    ) async throws -> SenseVoiceEngine {
        var lastError: Error?
        for variant in variants {
            try Task.checkCancellation()
            let started = Date()
            do {
                let engine = try await Task.detached(priority: .userInitiated) {
                    try SenseVoiceEngine(directory: directory, variant: variant)
                }.value
                // 1 s of faint noise: exercises the smallest bucket without real speech.
                var generator = SystemRandomNumberGenerator()
                let probe = (0..<SenseVoiceConstants.sampleRate).map { _ in Float.random(in: -0.01...0.01, using: &generator) }
                _ = try await engine.transcribe(probe, language: 0)
                DebugLogger.shared.info(
                    "SenseVoice: loaded \(variant.rawValue) encoder in \(String(format: "%.2f", Date().timeIntervalSince(started)))s [buckets=\(await engine.acceptedFrameCounts)]",
                    source: Self.logSource
                )
                return engine
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                DebugLogger.shared.warning(
                    "SenseVoice: \(variant.rawValue) encoder unusable, trying next [error=\(error.localizedDescription)]",
                    source: Self.logSource
                )
            }
        }
        if Self.hasNeuralEngine == false {
            throw Self.makeError(
                "SenseVoice needs the Apple Neural Engine for its int8/fp16 encoder, and no fp32 encoder is installed."
            )
        }
        throw lastError ?? Self.makeError("No usable SenseVoice encoder found.")
    }

    // MARK: - Transcription

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeFinal(samples)
    }

    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        // SenseVoice turns faint noise into a stray syllable ("그."). A recognized preview
        // disables ASRService's short-silence gate on the final pass, so apply the same gate
        // to previews; the final pass stays exactly as for every other engine.
        if SettingsStore.shared.skipSilentRecordingsEnabled,
           ASRService.assessShortAudioSilence(samples).shouldSkipTranscription
        {
            return ASRTranscriptionResult(text: "", confidence: 0)
        }
        return try await self.run(samples, logLevel: .debug)
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.run(samples, logLevel: .info)
    }

    private enum LogLevel { case debug, info }

    private func run(_ samples: [Float], logLevel: LogLevel) async throws -> ASRTranscriptionResult {
        guard let engine = self.engine else {
            throw Self.makeError("SenseVoice is not initialized.")
        }
        let language = SettingsStore.shared.selectedSenseVoiceLanguage
        let started = Date()
        let result = try await engine.transcribe(
            samples,
            language: language.embedIndex,
            textNorm: SenseVoiceConstants.textNormWithITN
        )
        let elapsed = Date().timeIntervalSince(started)
        let message = "SenseVoice: \(logLevel == .info ? "final" : "preview") \(String(format: "%.2f", Double(samples.count) / 16_000))s audio in \(Int(elapsed * 1000))ms [lang=\(language.rawValue), detected=\(result.detectedLanguage ?? "-"), chars=\(result.text.count)]"
        switch logLevel {
        case .debug: DebugLogger.shared.debug(message, source: Self.logSource)
        case .info: DebugLogger.shared.info(message, source: Self.logSource)
        }
        return ASRTranscriptionResult(text: result.text, confidence: result.text.isEmpty ? 0 : 1)
    }

    // MARK: - Cache

    func clearCache() async throws {
        self.isReady = false
        self.engine = nil
        // Only the app-managed cache is ours to delete; never touch an override folder.
        guard let directory = Self.managedDirectory else { return }
        try await Task.detached(priority: .userInitiated) {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }.value
        DebugLogger.shared.info("SenseVoice: cleared managed cache at \(directory.path)", source: Self.logSource)
    }

    private static func makeError(_ description: String) -> NSError {
        NSError(domain: "SenseVoiceProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}

#else

final class SenseVoiceProvider: TranscriptionProvider {
    let name = "SenseVoice Small"
    let isAvailable = false
    let isReady = false

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)? = nil) async throws {
        throw Self.unsupported
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        throw Self.unsupported
    }

    func modelsExistOnDisk() -> Bool { false }

    private static let unsupported = NSError(
        domain: "SenseVoiceProvider",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "SenseVoice requires an Apple Silicon Mac."]
    )
}

#endif
