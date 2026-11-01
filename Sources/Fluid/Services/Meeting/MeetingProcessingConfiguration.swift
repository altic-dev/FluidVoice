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

/// Immutable value snapshot of meeting post-processing ASR configuration. The pipeline builds it
/// once per attempt and the meeting preparation owner constructs a fixed provider from it, so an
/// active run never follows later dictation-setting changes.
nonisolated struct MeetingFinalProcessingConfiguration: Equatable, Sendable {
    static let defaultASRModel = "parakeet-tdt-v2"
    static let defaultLanguageCode = "en"
    /// One shared immutable version keeps frozen requests and saved attempts consistent.
    static let defaultPipelineVersion = MeetingProcessingPipeline.pipelineVersion

    let asrModel: String
    let languageCode: String
    let vocabularyBoostingEnabled: Bool
    let pronunciationMatchingEnabled: Bool
    let customDictionaryRewritingEnabled: Bool
    let experimentalUnifiedFinalEnabled: Bool
    let diarizationFingerprint: String
    let pipelineVersion: Int

    init(
        asrModel: String? = nil,
        preferredASRModel: SettingsStore.SpeechModel? = nil,
        languageCode: String = Self.defaultLanguageCode,
        vocabularyBoostingEnabled: Bool = false,
        pronunciationMatchingEnabled: Bool = false,
        customDictionaryRewritingEnabled: Bool = false,
        experimentalUnifiedFinalEnabled: Bool = false,
        diarizationFingerprint: String = MeetingProcessingCheckpoint.currentDiarizationFingerprint,
        pipelineVersion: Int = Self.defaultPipelineVersion
    ) {
        self.asrModel = asrModel ?? MeetingProviderOptions.preferredModel(for: languageCode, selected: preferredASRModel).rawValue
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

/// Languages a finished meeting can be transcribed in again. Final meeting transcription uses the
/// multilingual Parakeet model, so the choice is that model's language set, not the dictation model
/// currently selected for live typing.
enum MeetingRetranscriptionLanguage {
    static func canonicalCode(_ raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VoiceEngineLanguageCatalog.parakeetV3LanguageIDs.contains(code) else { return nil }
        return code
    }

    static var choices: [VoiceEngineLanguage] {
        VoiceEngineLanguageCatalog.allLanguages(availableModels: [.parakeetTDT])
    }

    static func displayName(for languageCode: String) -> String {
        self.choices.first { $0.id == languageCode }?.displayName ?? languageCode
    }

    /// A same-language run replaces nothing and, if it fails, hides the transcript that is already there.
    static func canRetranscribe(selection: String, currentLanguageCode: String) -> Bool {
        guard let code = canonicalCode(selection) else { return false }
        return code != currentLanguageCode
    }

    /// The language an empty meeting should try again. Use the latest attempt that recorded a
    /// language, pending or failed. A later recovery attempt with no language must not hide that
    /// request, and an older failure must not replace a newer one.
    static func failedAttemptLanguage(for session: MeetingSession) -> String? {
        guard session.transcriptSegments.isEmpty,
              let language = session.processingAttempts.last(where: { $0.languageCode != nil })?.languageCode,
              canRetranscribe(selection: language, currentLanguageCode: session.languageCode)
        else { return nil }
        return Self.canonicalCode(language)
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
