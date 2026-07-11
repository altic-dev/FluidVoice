import Foundation

#if arch(arm64)
@preconcurrency import CoreML

/// TranscriptionProvider for SenseVoiceSmall (FunASR) — a non-autoregressive
/// multilingual ASR model with strong Cantonese accuracy, running on the Apple
/// Neural Engine via CoreML.
///
/// The 3-stage CoreML pipeline + greedy-CTC decode is vendored from
/// FluidInference/FluidAudio (Apache-2.0), adapted to FluidVoice's own
/// `HuggingFaceModelDownloader` and settings because the pinned FluidAudio fork
/// does not include the SenseVoice module. Model artifacts come from
/// `FluidInference/sensevoice-small-coreml` (int8 encoder variant).
///
/// See: https://github.com/FluidInference/FluidAudio (ASR/SenseVoice)
final class SenseVoiceProvider: TranscriptionProvider {
    let name = "SenseVoice Small"
    var isAvailable: Bool { true }
    private(set) var isReady: Bool = false

    // MARK: - Repository / artifacts (int8 encoder)

    private let repositoryOwner = "FluidInference"
    private let repositoryName = "sensevoice-small-coreml"
    private let repositoryRevision = "main"

    static let preprocessorFile = "SenseVoicePreprocessor.mlmodelc"
    static let encoderFile = "SenseVoiceSmall_int8.mlmodelc"
    static let vocabularyFile = "vocab.json"
    static let requiredItems: [HuggingFaceModelDownloader.ModelItem] = [
        .init(path: preprocessorFile, isDirectory: true),
        .init(path: encoderFile, isDirectory: true),
        .init(path: vocabularyFile, isDirectory: false),
    ]
    private static var requiredRelativePaths: [String] {
        self.requiredItems.map { $0.path }
    }

    private var engine: SenseVoiceEngine?

    // MARK: - Long-audio chunking (samples @ 16 kHz)

    /// Hard cap per encoder pass. The int8 encoder tops out at 1800 LFR frames
    /// (~960 samples/frame ≈ 108 s); staying at 100 s keeps a safety margin below
    /// the truncation clamp in `SenseVoiceEngine.runEncoder`.
    private static let maxChunkSamples = 1_600_000
    /// Never emit a chunk shorter than this (1 s), so a silence-seek can't collapse.
    private static let minChunkSamples = 16_000
    /// How far back from the hard cap to hunt for a quiet cut point (2 s).
    private static let boundarySearchRadiusSamples = 32_000
    private static let boundaryAnalysisWindowSamples = 1_280
    private static let boundaryAnalysisStrideSamples = 320

    /// Optional model override (unused today — SenseVoice has a single variant —
    /// but kept for parity with the other providers' download plumbing).
    var modelOverride: SettingsStore.SpeechModel?
    init(modelOverride: SettingsStore.SpeechModel? = nil) {
        self.modelOverride = modelOverride
    }

    static func cacheDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("sensevoice-small-coreml", isDirectory: true)
    }

    static func artifactsAreComplete(at directory: URL) -> Bool {
        HuggingFaceModelDownloader.artifactsAreComplete(root: directory, items: self.requiredItems)
    }

    func modelsExistOnDisk() -> Bool {
        guard let dir = Self.cacheDirectory() else { return false }
        return Self.artifactsAreComplete(at: dir)
    }

    // MARK: - Preparation

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        guard self.isReady == false else { return }
        guard let dir = Self.cacheDirectory() else {
            throw Self.makeError("Unable to resolve a cache directory for \(self.name).")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Re-sniff present artifacts: a proxy can cache an HTML block page (HTTP 200) in
        // place of a model file, so a file-existence check alone would trust a corrupt
        // cache forever. Force a re-download when that happens (see #353).
        let modelsPresent = self.modelsExistOnDisk()
        let cachedArtifactsCorrupt = modelsPresent
            && HuggingFaceModelDownloader.cachedPayloadContainsMarkup(
                root: dir, relativePaths: Self.requiredRelativePaths)

        if modelsPresent, !cachedArtifactsCorrupt {
            DebugLogger.shared.info(
                "SenseVoice: artifacts present at \(dir.path); skipping download",
                source: "SenseVoice"
            )
        } else {
            if cachedArtifactsCorrupt {
                DebugLogger.shared.warning(
                    "SenseVoice: cached artifacts at \(dir.path) contain an HTML/markup payload (corrupt); re-downloading",
                    source: "SenseVoice"
                )
            }
            DebugLogger.shared.info(
                "SenseVoice: artifacts missing; downloading from \(self.repositoryOwner)/\(self.repositoryName)",
                source: "SenseVoice"
            )
            progressHandler?(.preparingDownload)
            let downloader = HuggingFaceModelDownloader(
                owner: self.repositoryOwner,
                repo: self.repositoryName,
                revision: self.repositoryRevision,
                requiredItems: Self.requiredItems
            )
            try await downloader.ensureModelsPresent(at: dir) { progress, _ in
                progressHandler?(.downloading(progress))
            }
            try Task.checkCancellation()
            guard self.modelsExistOnDisk() else {
                throw Self.makeError("SenseVoice artifacts incomplete after download at \(dir.path).")
            }
        }

        progressHandler?(.optimizing)
        try Task.checkCancellation()
        let engine = try SenseVoiceEngine(
            directory: dir,
            preprocessorName: Self.preprocessorFile,
            encoderName: Self.encoderFile,
            vocabularyFile: Self.vocabularyFile
        )
        try Task.checkCancellation()
        self.engine = engine
        self.isReady = true
        progressHandler?(.loading)
        DebugLogger.shared.info("SenseVoice: provider ready", source: "SenseVoice")
    }

    // MARK: - Transcription

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard let engine = self.engine else {
            throw Self.makeError("SenseVoice provider is not ready.")
        }
        guard samples.isEmpty == false else {
            return ASRTranscriptionResult(text: "", confidence: 0)
        }

        let language = SettingsStore.shared.senseVoiceLanguage.embedIndex
        let startedAt = Date().timeIntervalSince1970

        let text: String
        if samples.count <= Self.maxChunkSamples {
            text = try await engine.transcribe(audio: samples, language: language)
        } else {
            // SenseVoice is non-streaming with a fixed max input; split long audio at
            // quiet points and stitch the pieces so nothing past ~108 s is dropped.
            text = try await self.transcribeChunked(samples, language: language, engine: engine)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.logBenchmark(samples: samples, text: trimmed, startedAt: startedAt)
        return ASRTranscriptionResult(text: text, confidence: trimmed.isEmpty ? 0 : 1)
    }

    /// Transcribe audio longer than one encoder pass by cutting it into
    /// silence-aligned chunks (≤ `maxChunkSamples`) and joining the results.
    private func transcribeChunked(
        _ samples: [Float], language: Int32, engine: SenseVoiceEngine
    ) async throws -> String {
        var pieces: [String] = []
        var offset = 0
        while offset < samples.count {
            try Task.checkCancellation()
            let end = Self.chunkEnd(in: samples, offset: offset)
            let chunk = Array(samples[offset..<end])
            let piece = try await engine.transcribe(audio: chunk, language: language)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if piece.isEmpty == false {
                pieces.append(piece)
            }
            offset = end
        }
        return pieces.joined(separator: " ")
    }

    /// End index (exclusive) of the chunk starting at `offset`. For a non-final
    /// chunk it seeks the quietest sample near the hard cap so cuts land in silence
    /// rather than mid-syllable; the search never runs past the cap, so every chunk
    /// stays within the encoder's limit.
    private static func chunkEnd(in samples: [Float], offset: Int) -> Int {
        let maxEnd = min(offset + self.maxChunkSamples, samples.count)
        guard maxEnd < samples.count else { return samples.count }

        let lowerBound = max(offset + self.minChunkSamples, maxEnd - self.boundarySearchRadiusSamples)
        guard lowerBound < maxEnd else { return maxEnd }
        return self.quietestBoundary(in: samples, lowerBound: lowerBound, upperBound: maxEnd) ?? maxEnd
    }

    /// The sample offset in `[lowerBound, upperBound]` with the lowest local energy,
    /// nudged toward `upperBound` to prefer longer chunks on ties.
    private static func quietestBoundary(in samples: [Float], lowerBound: Int, upperBound: Int) -> Int? {
        let halfWindow = max(1, self.boundaryAnalysisWindowSamples / 2)
        let stride = max(1, self.boundaryAnalysisStrideSamples)
        var bestBoundary: Int?
        var bestScore = Float.greatestFiniteMagnitude
        var boundary = lowerBound

        while boundary <= upperBound {
            let windowStart = max(0, boundary - halfWindow)
            let windowEnd = min(samples.count, boundary + halfWindow)
            var energy: Float = 0
            for index in windowStart..<windowEnd {
                energy += abs(samples[index])
            }
            let sampleCount = max(1, windowEnd - windowStart)
            let distancePenalty = Float(upperBound - boundary)
                / Float(max(1, self.boundarySearchRadiusSamples)) * 0.0001
            let score = energy / Float(sampleCount) + distancePenalty
            if score < bestScore {
                bestScore = score
                bestBoundary = boundary
            }
            boundary += stride
        }
        return bestBoundary
    }

    func clearCache() async throws {
        if let dir = Self.cacheDirectory(), FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        self.engine = nil
        self.isReady = false
    }

    // MARK: - Helpers

    private func logBenchmark(samples: [Float], text: String, startedAt: TimeInterval) {
        let elapsedMs = Int(((Date().timeIntervalSince1970 - startedAt) * 1000).rounded())
        let audioMs = Int((Double(samples.count) / 16_000.0 * 1000).rounded())
        let rtf = audioMs > 0 ? Double(elapsedMs) / Double(audioMs) : 0
        DebugLogger.shared.info(
            """
            ASR_BENCH provider_final_done model=sensevoice samples=\(samples.count) audioMs=\(audioMs) \
            elapsedMs=\(elapsedMs) textChars=\(text.count) rtf=\(String(format: "%.3f", rtf))
            """,
            source: "ASRBenchmark"
        )
    }

    private static func makeError(_ description: String) -> NSError {
        NSError(domain: "SenseVoiceProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}

// MARK: - SenseVoice CoreML engine

/// Actor that owns the loaded CoreML models and runs the SenseVoiceSmall pipeline
/// off the main thread. Pipeline (vendored from FluidInference/FluidAudio):
///   waveform → [Preprocessor fp32/CPU] → 560-d LFR features → pad to the smallest
///   enumerated bucket → [encoder+CTC int8/ANE] → greedy CTC decode (drop blank 0,
///   collapse repeats) → SentencePiece detokenize → strip `<|...|>` meta tags.
actor SenseVoiceEngine {
    /// Configuration constants mirroring the `FluidInference/sensevoice-small-coreml` conversion.
    private enum Config {
        static let featureDim = 560
        static let buckets = [128, 256, 512, 1024, 1800]
        static let numQueryTokens = 4
        static let blankId = 0
        static let defaultTextNorm: Int32 = 15  // woitn (no inverse text-norm)
        static let waveformScale: Float = 32_768.0
        static let sentencePieceWordBoundary = "\u{2581}"  // "▁"
        static var maxFrames: Int { buckets.last ?? 1800 }
        static func pickBucket(forFrames frames: Int) -> Int {
            for b in buckets where b >= frames { return b }
            return buckets.last ?? 1800
        }
    }

    private let preprocessor: MLModel
    private let encoder: MLModel
    private let vocabulary: [Int: String]

    init(directory: URL, preprocessorName: String, encoderName: String, vocabularyFile: String) throws {
        // Preprocessor must run fp32 on CPU (power-spectrum/log exceed fp16 range,
        // and its big identity convs fail ANE compile). The int8 encoder runs on ANE.
        let cpuConfig = MLModelConfiguration()
        cpuConfig.computeUnits = .cpuOnly
        let aneConfig = MLModelConfiguration()
        aneConfig.computeUnits = .cpuAndNeuralEngine

        self.preprocessor = try MLModel(
            contentsOf: directory.appendingPathComponent(preprocessorName), configuration: cpuConfig)
        self.encoder = try MLModel(
            contentsOf: directory.appendingPathComponent(encoderName), configuration: aneConfig)
        self.vocabulary = try Self.loadVocabulary(
            from: directory.appendingPathComponent(vocabularyFile))
    }

    /// Transcribe 16 kHz mono float samples (in [-1, 1]) for the given language embed index.
    func transcribe(audio: [Float], language: Int32) throws -> String {
        let features = try self.runPreprocessor(audio: audio)
        let (logits, validFrames) = try self.runEncoder(features: features, language: language)
        return self.decode(logits: logits, validFrames: validFrames)
    }

    // MARK: - Pipeline

    private func runPreprocessor(audio: [Float]) throws -> MLMultiArray {
        let n = audio.count
        let waveform = try MLMultiArray(shape: [1, n as NSNumber], dataType: .float32)
        let wptr = waveform.dataPointer.assumingMemoryBound(to: Float32.self)
        let scale = Config.waveformScale
        for i in 0..<n { wptr[i] = audio[i] * scale }

        let input = try MLDictionaryFeatureProvider(
            dictionary: ["waveform": MLFeatureValue(multiArray: waveform)])
        let out = try self.preprocessor.prediction(from: input)
        guard let features = out.featureValue(for: "features")?.multiArrayValue else {
            throw Self.makeError("SenseVoice preprocessor produced no `features`")
        }
        return features
    }

    private func runEncoder(features: MLMultiArray, language: Int32) throws -> (MLMultiArray, Int) {
        let dim = Config.featureDim
        var t = features.shape[1].intValue
        // Clamp to the largest enumerated bucket (~108 s). Longer audio is truncated;
        // callers needing full coverage should chunk before this point.
        if t > Config.maxFrames {
            t = Config.maxFrames
        }
        let bucket = Config.pickBucket(forFrames: t)

        // Zero-padded [1, bucket, 560] with the first T feature frames copied in.
        let speech = try MLMultiArray(shape: [1, bucket as NSNumber, dim as NSNumber], dataType: .float32)
        let sptr = speech.dataPointer.assumingMemoryBound(to: Float32.self)
        memset(sptr, 0, bucket * dim * MemoryLayout<Float32>.size)
        let count = t * dim
        if features.dataType == .float32 {
            memcpy(sptr, features.dataPointer, count * MemoryLayout<Float32>.size)
        } else {
            for i in 0..<count { sptr[i] = features[i].floatValue }
        }

        let lengths = try MLMultiArray(shape: [1], dataType: .int32)
        lengths[0] = NSNumber(value: t)
        let lang = try MLMultiArray(shape: [1], dataType: .int32)
        lang[0] = NSNumber(value: language)
        let tn = try MLMultiArray(shape: [1], dataType: .int32)
        tn[0] = NSNumber(value: Config.defaultTextNorm)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "speech": MLFeatureValue(multiArray: speech),
            "speech_lengths": MLFeatureValue(multiArray: lengths),
            "language": MLFeatureValue(multiArray: lang),
            "textnorm": MLFeatureValue(multiArray: tn),
        ])
        let out = try self.encoder.prediction(from: input)
        guard let logits = out.featureValue(for: "ctc_logits")?.multiArrayValue else {
            throw Self.makeError("SenseVoice encoder produced no `ctc_logits`")
        }
        return (logits, Config.numQueryTokens + t)
    }

    /// Greedy CTC over the first `validFrames` (drop blank 0, collapse repeats),
    /// detokenize, then strip the leading `<|lang|><|emo|><|event|><|itn|>` tags.
    private func decode(logits: MLMultiArray, validFrames: Int) -> String {
        let vocab = logits.shape[2].intValue
        let frames = min(validFrames, logits.shape[1].intValue)
        var ids: [Int] = []
        var prev = -1

        func appendArgmax(frameBase: (Int) -> Float) {
            var best = 0
            var bestVal = frameBase(0)
            for v in 1..<vocab {
                let x = frameBase(v)
                if x > bestVal {
                    bestVal = x
                    best = v
                }
            }
            if best != Config.blankId && best != prev { ids.append(best) }
            prev = best
        }

        if logits.dataType == .float32 {
            let p = logits.dataPointer.assumingMemoryBound(to: Float32.self)
            for t in 0..<frames {
                let base = t * vocab
                appendArgmax { p[base + $0] }
            }
        } else {
            for t in 0..<frames {
                appendArgmax { logits[[0, t as NSNumber, $0 as NSNumber]].floatValue }
            }
        }

        let raw = ids.compactMap { self.vocabulary[$0] }
            .joined()
            .replacingOccurrences(of: Config.sentencePieceWordBoundary, with: " ")
        return raw
            .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Loading

    private static func loadVocabulary(from url: URL) throws -> [Int: String] {
        let data = try Data(contentsOf: url)
        // Canonical format: JSON array ["<unk>", "<s>", ...].
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            var v: [Int: String] = [:]
            v.reserveCapacity(arr.count)
            for (i, tok) in arr.enumerated() { v[i] = tok }
            return v
        }
        // Fallback: {"0": "<unk>", ...} dictionary.
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            var v: [Int: String] = [:]
            v.reserveCapacity(dict.count)
            for (k, tok) in dict { if let i = Int(k) { v[i] = tok } }
            return v
        }
        throw Self.makeError("Failed to parse \(url.lastPathComponent) (expected array or dict)")
    }

    private static func makeError(_ description: String) -> NSError {
        NSError(domain: "SenseVoiceEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}

#else

/// Intel stub — SenseVoice's int8 encoder targets the Apple Neural Engine.
final class SenseVoiceProvider: TranscriptionProvider {
    let name = "SenseVoice Small (Apple Silicon ONLY)"
    var isAvailable: Bool { false }
    private(set) var isReady: Bool = false

    init(modelOverride: SettingsStore.SpeechModel? = nil) {}

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        throw NSError(
            domain: "SenseVoiceProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "SenseVoice requires Apple Silicon."]
        )
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        throw NSError(
            domain: "SenseVoiceProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "SenseVoice requires Apple Silicon."]
        )
    }

    func modelsExistOnDisk() -> Bool { false }
}

#endif
