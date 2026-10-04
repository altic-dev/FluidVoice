import Foundation

/// Immutable metadata shared by model selection, cache ownership and ASR routing.
/// Resolving a descriptor performs no hardware, network or filesystem queries.
nonisolated enum ParakeetSpeechModelCatalog {
    enum Variant: String, CaseIterable, Sendable {
        case v2, v3, mini, pico
    }

    struct PerformanceRatings: Equatable, Sendable {
        let speedRating: Int
        let accuracyRating: Int
        let speedPercent: Double
        let accuracyPercent: Double
    }

    struct Descriptor: Equatable, Sendable {
        let modelID: String
        let variant: Variant
        let folderName: String
        let pronunciationModelKey: String
        let expectedDownloadBytes: Int64
        let archiveURL: URL?
        let archiveSHA256: String?
        let requiredModelNames: [String]
        let vocabularyFile: String
        let displayName: String
        let humanReadableName: String
        let languageSupport: String
        let supportedLanguageCodes: [String]
        let downloadSize: String
        let cardDescription: String
        let performanceRatings: PerformanceRatings?

        var isEnglishOnly: Bool { self.supportedLanguageCodes == ["en"] }

        /// The caller supplies its existing cache root; appending a folder does no IO.
        func cacheDirectory(in modelsDirectory: URL) -> URL {
            modelsDirectory.appendingPathComponent(self.folderName, isDirectory: true)
        }

        /// Explicit filesystem validation for download/preparation work. This is
        /// separate from descriptor lookup; callers should run it off the main actor.
        func artifactsAreComplete(at directory: URL) -> Bool {
            guard HuggingFaceModelDownloader.artifactIsComplete(
                at: directory.appendingPathComponent(self.vocabularyFile), isDirectory: false
            ) else { return false }
            return self.requiredModelNames.allSatisfy { name in
                HuggingFaceModelDownloader.artifactIsComplete(
                    at: directory.appendingPathComponent(name, isDirectory: true), isDirectory: true
                )
            }
        }
    }

    static let standardModelNames = ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc"]
    static let splitModelNames = [
        "Preprocessor.mlmodelc", "Encoder-1.mlmodelc", "Encoder-2.mlmodelc",
        "Encoder-3.mlmodelc", "Encoder-4.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc",
    ]

    static let v2 = Descriptor(
        modelID: "parakeet-tdt-v2",
        variant: .v2,
        folderName: "parakeet-tdt-0.6b-v2-coreml",
        pronunciationModelKey: "parakeet-v2",
        expectedDownloadBytes: 464_421_712,
        archiveURL: nil,
        archiveSHA256: nil,
        requiredModelNames: ParakeetSpeechModelCatalog.standardModelNames,
        vocabularyFile: "parakeet_vocab.json",
        displayName: "Parakeet TDT v2 (English Only)",
        humanReadableName: "Blazing Fast - English",
        languageSupport: "English Only (Higher Accuracy)",
        supportedLanguageCodes: ["en"],
        downloadSize: "~442.9 MiB",
        cardDescription: "Optimized for English accuracy and fastest transcription.",
        performanceRatings: .init(speedRating: 5, accuracyRating: 5, speedPercent: 1.0, accuracyPercent: 0.96)
    )
    static let v3 = Descriptor(
        modelID: "parakeet-tdt",
        variant: .v3,
        folderName: "parakeet-tdt-0.6b-v3-coreml",
        pronunciationModelKey: "parakeet-v3",
        expectedDownloadBytes: 483_288_717,
        archiveURL: nil,
        archiveSHA256: nil,
        requiredModelNames: ParakeetSpeechModelCatalog.standardModelNames,
        vocabularyFile: "parakeet_vocab.json",
        displayName: "Parakeet TDT v3 (Multilingual)",
        humanReadableName: "Blazing Fast - Multilingual",
        languageSupport: "25 Languages",
        supportedLanguageCodes: [
            "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
            "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
        ],
        downloadSize: "~460.9 MiB",
        cardDescription: "Fast multilingual transcription. Supports Bulgarian, Croatian, Czech, Danish, " +
            "Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian, Italian, " +
            "Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Russian, Slovak, " +
            "Slovenian, Spanish, Swedish, and Ukrainian.",
        performanceRatings: .init(speedRating: 5, accuracyRating: 5, speedPercent: 1.0, accuracyPercent: 0.92)
    )
    static let mini = Descriptor(
        modelID: "fluid-parakeet-mini",
        variant: .mini,
        folderName: "fluid-parakeet-mini-coreml",
        pronunciationModelKey: "fluid-parakeet-mini",
        expectedDownloadBytes: 254_126_592,
        archiveURL: URL(string: "https://models.fluidvoice.app/parakeet/fluid-mini/1.0.0/fluid-parakeet-mini-coreml.tar"),
        archiveSHA256: "12109f89c80b959847ac80ae963714a00af08f029144c3e4a2a8c1641f528a36",
        requiredModelNames: ParakeetSpeechModelCatalog.splitModelNames,
        vocabularyFile: "parakeet_vocab.json",
        displayName: "Blazing Fast Mini",
        humanReadableName: "Blazing Fast Mini",
        languageSupport: "English Only",
        supportedLanguageCodes: ["en"],
        downloadSize: "~242.4 MiB",
        cardDescription: "English-only local transcription with a smaller model download.",
        performanceRatings: nil
    )
    static let pico = Descriptor(
        modelID: "fluid-parakeet-pico",
        variant: .pico,
        folderName: "fluid-parakeet-pico-coreml",
        pronunciationModelKey: "fluid-parakeet-pico",
        expectedDownloadBytes: 161_201_152,
        archiveURL: URL(string: "https://models.fluidvoice.app/parakeet/fluid-pico/1.0.0/fluid-parakeet-pico-coreml.tar"),
        archiveSHA256: "afcdd76d4aba0328c97c858ee5c4c227ab5e23cc6885de5299d009c3671fe5d6",
        requiredModelNames: ParakeetSpeechModelCatalog.splitModelNames,
        vocabularyFile: "parakeet_vocab.json",
        displayName: "Blazing Fast Pico",
        humanReadableName: "Blazing Fast Pico",
        languageSupport: "English Only",
        supportedLanguageCodes: ["en"],
        downloadSize: "~153.7 MiB",
        cardDescription: "English-only local transcription with the smallest Parakeet model download.",
        performanceRatings: nil
    )

    static let descriptors = [ParakeetSpeechModelCatalog.v2, ParakeetSpeechModelCatalog.v3, ParakeetSpeechModelCatalog.mini, ParakeetSpeechModelCatalog.pico]

    static func descriptor(forModelID modelID: String) -> Descriptor? {
        self.descriptors.first { $0.modelID == modelID }
    }

    static func descriptor(for variant: Variant) -> Descriptor {
        switch variant {
        case .v2: self.v2
        case .v3: self.v3
        case .mini: self.mini
        case .pico: self.pico
        }
    }
}
