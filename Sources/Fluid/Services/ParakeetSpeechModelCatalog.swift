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
        enum InstallationRevisionError: Error { case invalidChecksum }
        let modelID: String
        let variant: Variant
        let folderName: String
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

        /// Encoder vectors are compatible only with the checkpoint that produced them.
        /// Legacy v2/v3 keep their established persisted keys byte for byte.
        var pronunciationModelKey: String {
            switch self.variant {
            case .v2: "parakeet-v2"
            case .v3: "parakeet-v3"
            case .mini, .pico: "\(self.modelID):sha256:\(self.archiveSHA256 ?? "unavailable")"
            }
        }

        /// The caller supplies its existing cache root; appending a folder does no IO.
        func cacheDirectory(in modelsDirectory: URL) -> URL {
            modelsDirectory.appendingPathComponent(self.folderName, isDirectory: true)
        }

        /// Explicit filesystem validation for download/preparation work. This is
        /// separate from descriptor lookup; callers should run it off the main actor.
        func artifactsAreComplete(at directory: URL) -> Bool {
            guard self.installationRevisionMatches(at: directory) else { return false }
            guard HuggingFaceModelDownloader.artifactIsComplete(
                at: directory.appendingPathComponent(self.vocabularyFile), isDirectory: false
            ) else { return false }
            return self.requiredModelNames.allSatisfy { name in
                HuggingFaceModelDownloader.artifactIsComplete(
                    at: directory.appendingPathComponent(name, isDirectory: true), isDirectory: true
                )
            }
        }

        /// Compact model folders are stable across releases; their exact installed
        /// archive revision must match before an existing cache may skip download.
        func installationRevisionMatches(at directory: URL) -> Bool {
            guard self.variant == .mini || self.variant == .pico else { return true }
            guard let hash = self.archiveSHA256, hash.count == 64,
                  hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { return false }
            let marker = directory.appendingPathComponent(ParakeetSpeechModelCatalog.installationRevisionFileName)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: marker.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue == 64,
                  let input = try? FileHandle(forReadingFrom: marker)
            else { return false }
            defer { try? input.close() }
            return (try? input.read(upToCount: 65)) == Data(hash.utf8)
        }

        /// Only the downloader calls this on its validated, unpublished stage.
        /// Exclusive creation rejects any marker supplied by the archive itself.
        func writeInstallationRevision(at directory: URL) throws {
            guard self.variant == .mini || self.variant == .pico else { return }
            guard let hash = self.archiveSHA256, hash.count == 64,
                  hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw InstallationRevisionError.invalidChecksum }
            try Data(hash.utf8).write(
                to: directory.appendingPathComponent(ParakeetSpeechModelCatalog.installationRevisionFileName),
                options: .withoutOverwriting
            )
        }
    }

    static let installationRevisionFileName = ".fluidvoice-archive-sha256"
    static let standardModelNames = ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc"]
    static let splitModelNames = [
        "Preprocessor.mlmodelc", "Encoder-1.mlmodelc", "Encoder-2.mlmodelc",
        "Encoder-3.mlmodelc", "Encoder-4.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc",
    ]

    static let v2 = Descriptor(
        modelID: "parakeet-tdt-v2",
        variant: .v2,
        folderName: "parakeet-tdt-0.6b-v2-coreml",
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
        cardDescription: "In-house model by FluidVoice, with improved recognition amid background speech.",
        performanceRatings: nil
    )
    static let pico = Descriptor(
        modelID: "fluid-parakeet-pico",
        variant: .pico,
        folderName: "fluid-parakeet-pico-coreml",
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

    static func descriptor(forPronunciationModelKey modelKey: String) -> Descriptor? {
        self.descriptors.first { $0.pronunciationModelKey == modelKey }
    }

    static func isOutdatedCompactPronunciationModelKey(_ modelKey: String) -> Bool {
        [self.mini, self.pico].contains { descriptor in
            (modelKey == descriptor.modelID || modelKey.hasPrefix(descriptor.modelID + ":sha256:"))
                && modelKey != descriptor.pronunciationModelKey
        }
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
