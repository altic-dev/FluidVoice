import Foundation

/// Versioned, length-framed key/value encoding so arbitrary string fields cannot collide on
/// delimiters (`asr=a@b,lang=c` vs `asr=a,lang=b@c`). Values stay human-readable; no hashing.
/// Strings are canonicalized to precomposed form because Swift `==` treats canonically
/// equivalent Unicode as equal while raw UTF8 lengths differ.
nonisolated enum MeetingConfigFingerprintEncoding {
    static let version = 1

    static func encode(_ pairs: [(key: String, value: String)]) -> String {
        let framed = pairs.map { pair in
            let key = pair.key.precomposedStringWithCanonicalMapping
            let value = pair.value.precomposedStringWithCanonicalMapping
            return "\(key.utf8.count):\(key)=\(value.utf8.count):\(value)"
        }
        return (["v\(Self.version)"] + framed).joined(separator: ";")
    }
}

/// Inert value snapshot of meeting post-processing ASR configuration. No runtime path reads this
/// yet; P1 wiring will build it once per run so pipeline actors stop reading `SettingsStore.shared`
/// mid-flight.
nonisolated struct MeetingFinalProcessingConfiguration: Equatable, Sendable {
    static let defaultASRModel = "parakeet-tdt-v2"
    static let defaultLanguageCode = "en"
    /// Mirrors `MeetingProcessingPipeline.pipelineVersion`; that class is `@MainActor`, so a
    /// MainActor test guards this literal against drift instead of referencing it here.
    static let defaultPipelineVersion = 10

    let asrModel: String
    let languageCode: String
    let vocabularyBoostingEnabled: Bool
    let pronunciationMatchingEnabled: Bool
    let customDictionaryRewritingEnabled: Bool
    let experimentalUnifiedFinalEnabled: Bool
    let diarizationFingerprint: String
    let pipelineVersion: Int

    init(
        asrModel: String = Self.defaultASRModel,
        languageCode: String = Self.defaultLanguageCode,
        vocabularyBoostingEnabled: Bool = false,
        pronunciationMatchingEnabled: Bool = false,
        customDictionaryRewritingEnabled: Bool = false,
        experimentalUnifiedFinalEnabled: Bool = false,
        diarizationFingerprint: String = MeetingProcessingCheckpoint.currentDiarizationFingerprint,
        pipelineVersion: Int = Self.defaultPipelineVersion
    ) {
        self.asrModel = asrModel
        self.languageCode = languageCode
        self.vocabularyBoostingEnabled = vocabularyBoostingEnabled
        self.pronunciationMatchingEnabled = pronunciationMatchingEnabled
        self.customDictionaryRewritingEnabled = customDictionaryRewritingEnabled
        self.experimentalUnifiedFinalEnabled = experimentalUnifiedFinalEnabled
        self.diarizationFingerprint = diarizationFingerprint
        self.pipelineVersion = pipelineVersion
    }

    /// Identity of this inert configuration snapshot only. It does not by itself prove the runtime
    /// enforced these options; resumability may rely on it only once processing fully applies them.
    var identityFingerprint: String {
        MeetingConfigFingerprintEncoding.encode([
            ("asr", self.asrModel),
            ("lang", self.languageCode),
            ("vocabBoost", String(self.vocabularyBoostingEnabled)),
            ("pronunciationMatch", String(self.pronunciationMatchingEnabled)),
            ("dictionaryRewrite", String(self.customDictionaryRewritingEnabled)),
            ("unifiedFinal", String(self.experimentalUnifiedFinalEnabled)),
            ("diarizer", self.diarizationFingerprint),
            ("pipeline", String(self.pipelineVersion)),
        ])
    }
}

/// Inert value snapshot of live-caption ASR configuration. Live captions do no diarization.
nonisolated struct MeetingLiveCaptionsConfiguration: Equatable, Sendable {
    static let defaultModelRepositoryID = "FluidInference/parakeet-realtime-eou-120m-coreml"
    static let defaultModelVariant = "160ms"
    /// Branch selected by the current loader; source pins no resolved HF commit, so this is the
    /// loader default, not a revision pin.
    static let defaultModelRevision = "main"
    static let defaultChunkSizeMilliseconds = 160
    static let defaultLanguageCode = "en"

    let modelRepositoryID: String
    let modelVariant: String
    let modelRevision: String
    let chunkSizeMilliseconds: Int
    let languageCode: String

    init(
        modelRepositoryID: String = Self.defaultModelRepositoryID,
        modelVariant: String = Self.defaultModelVariant,
        modelRevision: String = Self.defaultModelRevision,
        chunkSizeMilliseconds: Int = Self.defaultChunkSizeMilliseconds,
        languageCode: String = Self.defaultLanguageCode
    ) {
        self.modelRepositoryID = modelRepositoryID
        self.modelVariant = modelVariant
        self.modelRevision = modelRevision
        self.chunkSizeMilliseconds = chunkSizeMilliseconds
        self.languageCode = languageCode
    }

    var identityFingerprint: String {
        MeetingConfigFingerprintEncoding.encode([
            ("modelRepo", self.modelRepositoryID),
            ("modelVariant", self.modelVariant),
            ("revision", self.modelRevision),
            ("revisionState", "unresolved"),
            ("chunkMs", String(self.chunkSizeMilliseconds)),
            ("lang", self.languageCode),
            ("diarizer", "none"),
        ])
    }
}
