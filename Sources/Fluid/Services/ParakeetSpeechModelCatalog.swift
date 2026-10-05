import CryptoKit
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
        var manifestSHA256: String? = nil

        var isEnglishOnly: Bool { self.supportedLanguageCodes == ["en"] }

        var attribution: String {
            switch self.variant {
            case .v2, .v3: "NVIDIA Parakeet"
            case .mini, .pico: "NVIDIA Parakeet · Moondream Parakeet Ultra"
            }
        }

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

        /// Explicit background-only disk inspection. Older compact checkpoints remain
        /// usable, but must not be mistaken for the currently advertised download.
        func installedArchiveSHA256(at directory: URL) -> String? {
            guard self.variant == .mini || self.variant == .pico,
                  let rootAttributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
                  rootAttributes[.type] as? FileAttributeType == .typeDirectory
            else { return nil }
            let marker = directory.appendingPathComponent(ParakeetSpeechModelCatalog.installationRevisionFileName)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: marker.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue == 64,
                  let input = try? FileHandle(forReadingFrom: marker)
            else { return nil }
            defer { try? input.close() }
            guard let bytes = try? input.read(upToCount: 65), bytes.count == 64,
                  bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let hash = String(data: bytes, encoding: .utf8),
                  HuggingFaceModelDownloader.artifactIsComplete(at: directory.appendingPathComponent(self.vocabularyFile), isDirectory: false),
                  self.requiredModelNames.allSatisfy({ name in
                      HuggingFaceModelDownloader.artifactIsComplete(at: directory.appendingPathComponent(name, isDirectory: true), isDirectory: true)
                  })
            else { return nil }
            var enumerationFailed = false
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }) else { return nil }
            var count = 0
            for case let item as URL in enumerator {
                if Task.isCancelled { return nil }
                count += 1
                guard count <= 50_000,
                      let type = (try? FileManager.default.attributesOfItem(atPath: item.path))?[.type] as? FileAttributeType,
                      type == .typeRegular || type == .typeDirectory
                else { return nil }
            }
            return enumerationFailed ? nil : hash
        }

        /// Small bounded identity read for installation snapshots, never UI rendering.
        /// Existing archive markers remain the pronunciation identity across migration.
        func installedManifestSHA256(at directory: URL) -> String? {
            guard self.variant == .mini || self.variant == .pico,
                  (try? FileManager.default.attributesOfItem(atPath: directory.path))?[.type] as? FileAttributeType == .typeDirectory
            else { return nil }
            let file = directory.appendingPathComponent("manifest.json")
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  size > 0, size <= 1_048_576,
                  let input = try? FileHandle(forReadingFrom: file)
            else { return nil }
            defer { try? input.close() }
            guard let data = try? input.read(upToCount: 1_048_577), data.count == size else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
        performanceRatings: .init(speedRating: 5, accuracyRating: 5, speedPercent: 0.99, accuracyPercent: 0.96)
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
        performanceRatings: .init(speedRating: 5, accuracyRating: 5, speedPercent: 0.99, accuracyPercent: 0.92)
    )
    static let mini = Descriptor(
        modelID: "fluid-parakeet-mini",
        variant: .mini,
        folderName: "fluid-parakeet-mini-coreml",
        expectedDownloadBytes: 254_136_320,
        archiveURL: URL(string: "https://models.fluidvoice.app/parakeet/fluid-mini/1.1.1/fluid-parakeet-mini-coreml.tar"),
        archiveSHA256: "7f811554cc670ded812937502f928ae6aad946bbf6e4c2eecd6fcffbe76f4d16",
        requiredModelNames: ParakeetSpeechModelCatalog.splitModelNames,
        vocabularyFile: "parakeet_vocab.json",
        displayName: "Fluid Speech Mini",
        humanReadableName: "Fluid Speech Mini",
        languageSupport: "English Only",
        supportedLanguageCodes: ["en"],
        downloadSize: "~242.4 MiB",
        cardDescription: "Built for speech with background noise.",
        performanceRatings: .init(speedRating: 5, accuracyRating: 5, speedPercent: 0.99, accuracyPercent: 0.95),
        manifestSHA256: "32193c4cec7f5daf92fd617c424e7a157ea8dfcfa832a0db2cfcfa5cb9b674b8"
    )
    static let pico = Descriptor(
        modelID: "fluid-parakeet-pico",
        variant: .pico,
        folderName: "fluid-parakeet-pico-coreml",
        expectedDownloadBytes: 161_208_320,
        archiveURL: URL(string: "https://models.fluidvoice.app/parakeet/fluid-pico/1.1.1/fluid-parakeet-pico-coreml.tar"),
        archiveSHA256: "542f74f639438bf37ff134a7a75daddb50d301deb87696994e11ff272df21512",
        requiredModelNames: ParakeetSpeechModelCatalog.splitModelNames,
        vocabularyFile: "parakeet_vocab.json",
        displayName: "Fluid Speech Pico",
        humanReadableName: "Fluid Speech Pico",
        languageSupport: "English Only",
        supportedLanguageCodes: ["en"],
        downloadSize: "~153.7 MiB",
        cardDescription: "Built for speech with background noise.",
        performanceRatings: .init(speedRating: 5, accuracyRating: 5, speedPercent: 1.0, accuracyPercent: 0.91),
        manifestSHA256: "a87ee649edc18aca6d30f251e75237f48c995448b865ffee35ab343ed3e66121"
    )

    static let descriptors = [ParakeetSpeechModelCatalog.v2, ParakeetSpeechModelCatalog.v3, ParakeetSpeechModelCatalog.mini, ParakeetSpeechModelCatalog.pico]

    static func descriptor(forModelID modelID: String) -> Descriptor? {
        self.descriptors.first { $0.modelID == modelID }
    }

    static func descriptor(forPronunciationModelKey modelKey: String) -> Descriptor? {
        self.descriptors.first { $0.pronunciationModelKey == modelKey }
    }

    /// A candidate for loading an existing checkpoint, never a download instruction.
    /// Callers must verify its hash against the installed marker before loadLocalOnly.
    static func descriptor(forInstalledPronunciationModelKey modelKey: String) -> Descriptor? {
        if modelKey == self.v2.pronunciationModelKey { return self.v2 }
        if modelKey == self.v3.pronunciationModelKey { return self.v3 }
        for source in [self.mini, self.pico] {
            let prefix = source.modelID + ":sha256:"
            guard modelKey.hasPrefix(prefix) else { continue }
            let hash = String(modelKey.dropFirst(prefix.count))
            guard hash.utf8.count == 64,
                  hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { return nil }
            return Descriptor(
                modelID: source.modelID,
                variant: source.variant,
                folderName: source.folderName,
                expectedDownloadBytes: source.expectedDownloadBytes,
                archiveURL: nil,
                archiveSHA256: hash,
                requiredModelNames: source.requiredModelNames,
                vocabularyFile: source.vocabularyFile,
                displayName: source.displayName,
                humanReadableName: source.humanReadableName,
                languageSupport: source.languageSupport,
                supportedLanguageCodes: source.supportedLanguageCodes,
                downloadSize: source.downloadSize,
                cardDescription: source.cardDescription,
                performanceRatings: source.performanceRatings
            )
        }
        return nil
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
