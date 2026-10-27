@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class ParakeetSpeechModelCatalogTests: XCTestCase {
    func testManifestIdentityReadIsBoundedAndRejectsLinksWithoutChangingArchiveMarker() throws {
        let descriptor = ParakeetSpeechModelCatalog.mini
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent(ParakeetSpeechModelCatalog.installationRevisionFileName)
        let oldHash = String(repeating: "a", count: 64)
        try Data(oldHash.utf8).write(to: marker)
        let manifest = directory.appendingPathComponent("manifest.json")
        XCTAssertNil(descriptor.installedManifestSHA256(at: directory))
        try Data("{}".utf8).write(to: manifest)
        XCTAssertEqual(descriptor.installedManifestSHA256(at: directory), "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a")
        XCTAssertEqual(try Data(contentsOf: marker), Data(oldHash.utf8))
        try Data(repeating: 0, count: 1_048_577).write(to: manifest)
        XCTAssertNil(descriptor.installedManifestSHA256(at: directory))
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: marker)
        XCTAssertNil(descriptor.installedManifestSHA256(at: directory))
        XCTAssertNil(ParakeetSpeechModelCatalog.v2.installedManifestSHA256(at: directory))
        XCTAssertEqual(try Data(contentsOf: marker), Data(oldHash.utf8))
    }

    func testInstalledCompactRevisionCanBeOlderButMustHaveCompleteRegularArtifacts() throws {
        let descriptor = ParakeetSpeechModelCatalog.mini
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for model in descriptor.requiredModelNames {
            let root = directory.appendingPathComponent(model)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("weights"), withIntermediateDirectories: true)
            for file in ["coremldata.bin", "metadata.json", "weights/weight.bin"] {
                try Data("fixture".utf8).write(to: root.appendingPathComponent(file))
            }
        }
        try Data("{}".utf8).write(to: directory.appendingPathComponent(descriptor.vocabularyFile))
        let oldHash = "12109f89c80b959847ac80ae963714a00af08f029144c3e4a2a8c1641f528a36"
        let marker = directory.appendingPathComponent(ParakeetSpeechModelCatalog.installationRevisionFileName)
        try Data(oldHash.utf8).write(to: marker)
        XCTAssertEqual(descriptor.installedArchiveSHA256(at: directory), oldHash)
        XCTAssertFalse(descriptor.artifactsAreComplete(at: directory), "A usable old checkpoint is not the latest installation")
        let link = directory.appendingPathComponent("unexpected-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: marker)
        XCTAssertNil(descriptor.installedArchiveSHA256(at: directory))
        try FileManager.default.removeItem(at: link)
        for invalid in [String(repeating: "g", count: 64), String(repeating: "a", count: 65), ""] {
            try Data(invalid.utf8).write(to: marker)
            XCTAssertNil(descriptor.installedArchiveSHA256(at: directory))
        }
        try Data(oldHash.utf8).write(to: marker)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("Encoder-1.mlmodelc/weights/weight.bin"))
        XCTAssertNil(descriptor.installedArchiveSHA256(at: directory))
        XCTAssertNil(ParakeetSpeechModelCatalog.v2.installedArchiveSHA256(at: directory))
    }

    func testInstalledPronunciationDescriptorIsOnlyALocalCandidate() throws {
        let oldHash = "12109f89c80b959847ac80ae963714a00af08f029144c3e4a2a8c1641f528a36"
        let key = ParakeetSpeechModelCatalog.mini.modelID + ":sha256:" + oldHash
        let candidate = try XCTUnwrap(ParakeetSpeechModelCatalog.descriptor(forInstalledPronunciationModelKey: key))
        XCTAssertEqual(candidate.pronunciationModelKey, key)
        XCTAssertEqual(candidate.archiveSHA256, oldHash)
        XCTAssertNil(candidate.archiveURL, "An old checkpoint may never be downloaded from the latest archive URL")
        XCTAssertEqual(candidate.requiredModelNames, ParakeetSpeechModelCatalog.mini.requiredModelNames)
        XCTAssertNil(ParakeetSpeechModelCatalog.descriptor(forPronunciationModelKey: key))
        XCTAssertTrue(ParakeetSpeechModelCatalog.isOutdatedCompactPronunciationModelKey(key))
        for invalid in [ParakeetSpeechModelCatalog.mini.modelID, key + "x", "fluid-parakeet-mini:sha256:" + String(repeating: "G", count: 64)] {
            XCTAssertNil(ParakeetSpeechModelCatalog.descriptor(forInstalledPronunciationModelKey: invalid))
        }
        XCTAssertEqual(ParakeetSpeechModelCatalog.descriptor(forInstalledPronunciationModelKey: "parakeet-v2"), ParakeetSpeechModelCatalog.v2)
    }

    func testAllOfflineParakeetVariantsHaveIndependentStableCacheAndPronunciationKeys() throws {
        let descriptors = ParakeetSpeechModelCatalog.descriptors
        XCTAssertEqual(Set(descriptors.map(\.variant)), Set(ParakeetSpeechModelCatalog.Variant.allCases))
        XCTAssertEqual(Set(descriptors.map(\.modelID)).count, 4)
        XCTAssertEqual(Set(descriptors.map(\.folderName)).count, 4)
        XCTAssertEqual(Set(descriptors.map(\.pronunciationModelKey)).count, 4)
        let root = URL(fileURLWithPath: "/fixture/FluidAudio/Models", isDirectory: true)
        for descriptor in descriptors {
            let model = try XCTUnwrap(SettingsStore.SpeechModel(rawValue: descriptor.modelID))
            XCTAssertEqual(model.parakeetDescriptor, descriptor)
            XCTAssertEqual(ParakeetSpeechModelCatalog.descriptor(for: descriptor.variant), descriptor)
            XCTAssertEqual(descriptor.cacheDirectory(in: root).deletingLastPathComponent(), root)
            XCTAssertEqual(descriptor.cacheDirectory(in: root).lastPathComponent, descriptor.folderName)
            XCTAssertEqual(model.expectedDownloadBytes, descriptor.expectedDownloadBytes)
            XCTAssertEqual(model.displayName, descriptor.displayName)
            XCTAssertEqual(model.humanReadableName, descriptor.humanReadableName)
            XCTAssertFalse(model.isWhisperModel)
            XCTAssertEqual(model.provider, .nvidia)
            XCTAssertTrue(model.requiresAppleSilicon)
            XCTAssertEqual(model.requiresMacOS15, model == .fluidParakeetMini || model == .fluidParakeetPico)
            XCTAssertFalse(model.requiresMacOS26)
            XCTAssertNil(model.whisperModelFile)
            XCTAssertNil(model.legacyWhisperModelFile)
            XCTAssertEqual(try JSONDecoder().decode(SettingsStore.SpeechModel.self, from: JSONEncoder().encode(model)), model)
        }
        XCTAssertNil(ParakeetSpeechModelCatalog.descriptor(forModelID: "missing"))
        XCTAssertNil(SettingsStore.SpeechModel.parakeetRealtime.parakeetDescriptor)
        XCTAssertNil(SettingsStore.SpeechModel.whisperBase.parakeetDescriptor)
    }

    func testLegacyV2V3IdentityAndArchitectureDefaultRemainUnchanged() {
        let v2 = ParakeetSpeechModelCatalog.v2
        let v3 = ParakeetSpeechModelCatalog.v3
        XCTAssertEqual(v2.modelID, "parakeet-tdt-v2")
        XCTAssertEqual(v3.modelID, "parakeet-tdt")
        XCTAssertEqual(v2.folderName, "parakeet-tdt-0.6b-v2-coreml")
        XCTAssertEqual(v3.folderName, "parakeet-tdt-0.6b-v3-coreml")
        XCTAssertEqual(v2.pronunciationModelKey, "parakeet-v2")
        XCTAssertEqual(v3.pronunciationModelKey, "parakeet-v3")
        XCTAssertEqual(v2.expectedDownloadBytes, 464_421_712)
        XCTAssertEqual(v3.expectedDownloadBytes, 483_288_717)
        XCTAssertEqual(v2.downloadSize, "~442.9 MiB")
        XCTAssertEqual(v3.downloadSize, "~460.9 MiB")
        XCTAssertEqual(SettingsStore.SpeechModel.parakeetTDTv2.humanReadableName, "Blazing Fast - English")
        XCTAssertEqual(SettingsStore.SpeechModel.parakeetTDT.humanReadableName, "Blazing Fast - Multilingual")
        XCTAssertEqual(SettingsStore.SpeechModel.parakeetTDTv2.accuracyPercent, 0.96)
        XCTAssertEqual(SettingsStore.SpeechModel.parakeetTDT.accuracyPercent, 0.92)
        XCTAssertEqual(SettingsStore.SpeechModel.parakeetTDTv2.speedPercent, 0.99)
        XCTAssertEqual(SettingsStore.SpeechModel.parakeetTDT.speedPercent, 0.99)
        XCTAssertTrue(SettingsStore.SpeechModel.parakeetTDTv2.hasPerformanceRatings)
        XCTAssertTrue(SettingsStore.SpeechModel.parakeetTDT.hasPerformanceRatings)
        for model: SettingsStore.SpeechModel in [.parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .nemotronOffline, .nemotronStreaming] {
            XCTAssertEqual(model.brandName, "NVIDIA")
            XCTAssertEqual(model.brandColorHex, "#76B900")
            XCTAssertEqual(model.provider, .nvidia)
        }
        XCTAssertNil(v2.archiveURL)
        XCTAssertNil(v3.archiveSHA256)
        XCTAssertEqual(Set(v2.requiredModelNames), Set(["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc"]))
        XCTAssertEqual(v2.requiredModelNames, v3.requiredModelNames)
        XCTAssertEqual(v2.supportedLanguageCodes, ["en"])
        XCTAssertEqual(Set(v3.supportedLanguageCodes), Set([
            "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
            "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
        ]))
        XCTAssertEqual(SettingsStore.SpeechModel.defaultModel, CPUArchitecture.isAppleSilicon ? .parakeetTDT : .whisperBase)
    }

    func testHostedSmallVariantsUseExactArchivesAndNoInventedPerformanceRatings() throws {
        let fixtures: [(SettingsStore.SpeechModel, Int64, String, String)] = [
            (.fluidParakeetMini, 254_136_320, "fluid-mini", "7f811554cc670ded812937502f928ae6aad946bbf6e4c2eecd6fcffbe76f4d16"),
            (.fluidParakeetPico, 161_208_320, "fluid-pico", "542f74f639438bf37ff134a7a75daddb50d301deb87696994e11ff272df21512"),
        ]
        for (model, bytes, path, hash) in fixtures {
            let descriptor = try XCTUnwrap(model.parakeetDescriptor)
            XCTAssertEqual(descriptor.expectedDownloadBytes, bytes)
            XCTAssertEqual(descriptor.archiveSHA256, hash)
            XCTAssertEqual(descriptor.archiveURL?.absoluteString, "https://models.fluidvoice.app/parakeet/\(path)/1.1.1/\(descriptor.folderName).tar")
            XCTAssertEqual(descriptor.archiveURL?.scheme, "https")
            XCTAssertEqual(descriptor.supportedLanguageCodes, ["en"])
            XCTAssertTrue(descriptor.isEnglishOnly)
            XCTAssertEqual(model.languageSupport, "English Only")
            XCTAssertEqual(model.brandName, "FluidVoice")
            XCTAssertEqual(model.brandColorHex, "#1A75FF")
            XCTAssertEqual(model.provider, .nvidia, "Product branding must not change the Parakeet backend or family filter")
            XCTAssertFalse(model.usesAppleLogo)
            XCTAssertEqual(model.supportedLanguageCodes, "EN")
            XCTAssertEqual(model.supportedLanguageNames, "English")
            XCTAssertTrue(model.hasPerformanceRatings)
            XCTAssertNotNil(descriptor.performanceRatings)
            XCTAssertEqual(descriptor.attribution, "NVIDIA Parakeet · Moondream Parakeet Ultra")
            XCTAssertEqual(descriptor.creditLine, "Made by FluidVoice, built on NVIDIA Parakeet and Moondream’s Parakeet Ultra.")
            XCTAssertEqual(model.accuracyPercent, model == .fluidParakeetMini ? 0.95 : 0.91)
            XCTAssertEqual(model.speedPercent, model == .fluidParakeetMini ? 0.99 : 1.0)
            XCTAssertTrue(model.supportsPronunciationMatching, "Real split encoders produce compatible 1024-dimensional embeddings")
            XCTAssertTrue(model.supportsCustomVocabulary, "Real CTC110m boosting is verified for both variants")
            XCTAssertEqual(model.streamingPreviewIntervalSeconds, SettingsStore.SpeechModel.parakeetTDTv2.streamingPreviewIntervalSeconds)
            XCTAssertEqual(model.minimumStreamingPreviewSeconds, SettingsStore.SpeechModel.parakeetTDTv2.minimumStreamingPreviewSeconds)
            XCTAssertEqual(SettingsStore.SpeechModel.availableModels.contains(model), CPUArchitecture.isAppleSilicon)
        }
        XCTAssertEqual(SettingsStore.SpeechModel.fluidParakeetMini.humanReadableName, "Fluid Speech Mini")
        XCTAssertEqual(SettingsStore.SpeechModel.fluidParakeetPico.humanReadableName, "Fluid Speech Pico")
    }

    func testSmallVariantsAreOfferedOnlyForEnglishAndDoNotReplaceExistingFirstChoice() {
        let models: [SettingsStore.SpeechModel] = [.parakeetTDTv2, .parakeetRealtime, .parakeetTDT, .fluidParakeetMini, .fluidParakeetPico]
        let english = VoiceEngineLanguageCatalog.routes(forLanguageID: "en", availableModels: models)
        XCTAssertEqual(english.map(\.model), models)
        XCTAssertEqual(english.first?.model, .parakeetTDTv2)
        for route in english where route.model == .fluidParakeetMini || route.model == .fluidParakeetPico {
            XCTAssertEqual(route.binding, .automatic)
            XCTAssertNotNil(route.badgeText)
        }
        for language in VoiceEngineLanguageCatalog.allLanguages(availableModels: models) where language.id != "en" {
            let routes = VoiceEngineLanguageCatalog.routes(for: language, availableModels: models)
            XCTAssertFalse(routes.contains { $0.model == .fluidParakeetMini || $0.model == .fluidParakeetPico })
            XCTAssertEqual(routes.map(\.model), [.parakeetTDT])
        }
        XCTAssertEqual(VoiceEngineLanguageCatalog.allLanguages(availableModels: [.fluidParakeetMini, .fluidParakeetPico]).map(\.id), ["en"])
        XCTAssertTrue(VoiceEngineLanguageCatalog.routes(forLanguageID: "fr", availableModels: [.fluidParakeetMini, .fluidParakeetPico]).isEmpty)
        XCTAssertTrue(VoiceEngineLanguageCatalog.routes(forLanguageID: "missing", availableModels: models).isEmpty)
    }

    func testEnglishOnboardingShowsV2AndMiniWithoutChangingSelectionOrAvailableRoutes() {
        let language = VoiceEngineLanguage(id: "en", displayName: "English", aliases: [], isPopular: true)
        let models: [SettingsStore.SpeechModel] = [.parakeetTDTv2, .parakeetRealtime, .parakeetTDT, .fluidParakeetMini, .fluidParakeetPico, .appleSpeechAnalyzer, .appleSpeech, .whisperBase]
        let available = models.map { VoiceEngineLanguageRoute(language: language, model: $0, binding: .automatic) }
        let selection = SettingsStore.shared.selectedSpeechModel
        let displayed = OnboardingModelRecommendation.defaultRoutes(forLanguageID: "en", from: available)
        XCTAssertEqual(displayed.map(\.model), [.parakeetTDTv2, .fluidParakeetMini])
        XCTAssertEqual(displayed.first, available.first, "The established first recommendation must stay unchanged")
        let displayedIDs = Set(displayed.map(\.id))
        let other = available.filter { !displayedIDs.contains($0.id) }
        XCTAssertEqual(other.map(\.model), [.parakeetRealtime, .parakeetTDT, .fluidParakeetPico, .appleSpeechAnalyzer, .appleSpeech, .whisperBase])
        XCTAssertEqual(available.map(\.model), models)
        XCTAssertEqual(Set((displayed + other).map(\.id)), Set(available.map(\.id)))
        XCTAssertEqual(SettingsStore.shared.selectedSpeechModel, selection)
        XCTAssertEqual(ParakeetSpeechModelCatalog.mini.cardDescription, "Clear dictation in noisy places, at half the size of Blazing Fast. Runs on your Mac.")
        XCTAssertEqual(ParakeetSpeechModelCatalog.pico.cardDescription, "Our smallest model. Light enough for older Macs, and still clear in noisy places.")
    }

    func testOnboardingRecommendationsPreserveUnavailableMiniIntelAndNonEnglishFallbacks() {
        let english = VoiceEngineLanguage(id: "en", displayName: "English", aliases: [], isPopular: true)
        func routes(_ models: [SettingsStore.SpeechModel]) -> [VoiceEngineLanguageRoute] {
            models.map { VoiceEngineLanguageRoute(language: english, model: $0, binding: .automatic) }
        }
        let oldOS = routes([.parakeetTDTv2, .parakeetTDT, .appleSpeech])
        XCTAssertEqual(OnboardingModelRecommendation.defaultRoutes(forLanguageID: "en", from: oldOS).map(\.model), [.parakeetTDTv2, .appleSpeech])
        let intel = routes([.whisperBase, .appleSpeechAnalyzer, .appleSpeech])
        XCTAssertEqual(OnboardingModelRecommendation.defaultRoutes(forLanguageID: "en", from: intel).map(\.model), [.whisperBase, .appleSpeechAnalyzer])
        let appleFirst = routes([.appleSpeech, .whisperBase])
        XCTAssertEqual(OnboardingModelRecommendation.defaultRoutes(forLanguageID: "en", from: appleFirst), [appleFirst[0]], "Do not duplicate the built-in card")
        let withoutV2 = routes([.parakeetTDT, .fluidParakeetMini, .appleSpeech])
        XCTAssertEqual(OnboardingModelRecommendation.defaultRoutes(forLanguageID: "en", from: withoutV2).map(\.model), [.parakeetTDT, .appleSpeech])
        let french = VoiceEngineLanguage(id: "fr", displayName: "French", aliases: [], isPopular: true)
        let frenchRoutes = [.parakeetTDT, SettingsStore.SpeechModel.appleSpeech].map {
            VoiceEngineLanguageRoute(language: french, model: $0, binding: .automatic)
        }
        XCTAssertEqual(OnboardingModelRecommendation.defaultRoutes(forLanguageID: "fr", from: frenchRoutes), [frenchRoutes[0]])
        XCTAssertTrue(OnboardingModelRecommendation.defaultRoutes(forLanguageID: "en", from: []).isEmpty)
        XCTAssertTrue(OnboardingModelRecommendation.defaultRoutes(forLanguageID: "fr", from: []).isEmpty)
        let onlyMini = routes([.fluidParakeetMini])
        XCTAssertEqual(OnboardingModelRecommendation.defaultRoutes(forLanguageID: "en", from: onlyMini), onlyMini)
    }

    func testCatalogReadsPreserveExistingAndNewPersistedSelections() throws {
        let defaults = UserDefaults.standard
        let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let original = defaults.persistentDomain(forName: domain)
        defer {
            if let original {
                defaults.setPersistentDomain(original, forName: domain)
            } else {
                defaults.removePersistentDomain(forName: domain)
            }
        }
        let settings = SettingsStore.shared
        let models: [SettingsStore.SpeechModel] = [.parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .whisperBase]
        for model in models {
            // A direct persisted fixture avoids sending model-switch UI events.
            defaults.set(model.rawValue, forKey: "SelectedSpeechModel")
            let before = defaults.persistentDomain(forName: domain)
            _ = model.parakeetDescriptor
            _ = model.displayName
            _ = model.expectedDownloadBytes
            _ = SettingsStore.SpeechModel.availableModels
            let expected = model.requiresAppleSilicon && !CPUArchitecture.isAppleSilicon ? SettingsStore.SpeechModel.whisperBase : model
            XCTAssertEqual(settings.selectedSpeechModel, expected)
            XCTAssertEqual(defaults.string(forKey: "SelectedSpeechModel"), model.rawValue)
            XCTAssertEqual(defaults.persistentDomain(forName: domain) as NSDictionary?, before as NSDictionary?)
        }
    }

    func testSplitCompletenessRequiresEveryEncoderPartAndVocabularyWithoutBorrowingSiblingCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mini = ParakeetSpeechModelCatalog.mini
        let pico = ParakeetSpeechModelCatalog.pico
        let miniDirectory = mini.cacheDirectory(in: root)
        try self.installFixture(mini, at: miniDirectory)
        XCTAssertTrue(mini.artifactsAreComplete(at: miniDirectory))
        XCTAssertFalse(pico.artifactsAreComplete(at: pico.cacheDirectory(in: root)))
        let encoder = miniDirectory.appendingPathComponent("Encoder-3.mlmodelc", isDirectory: true)
        try FileManager.default.removeItem(at: encoder)
        XCTAssertFalse(mini.artifactsAreComplete(at: miniDirectory))
        try self.installCompiledFixture(at: encoder)
        let vocabulary = miniDirectory.appendingPathComponent(mini.vocabularyFile)
        try Data().write(to: vocabulary)
        XCTAssertFalse(mini.artifactsAreComplete(at: miniDirectory))
        try Data("{}".utf8).write(to: vocabulary)
        XCTAssertTrue(mini.artifactsAreComplete(at: miniDirectory))
        let weights = encoder.appendingPathComponent("weights/weight.bin")
        try Data().write(to: weights)
        XCTAssertFalse(mini.artifactsAreComplete(at: miniDirectory))
    }

    private func installFixture(_ descriptor: ParakeetSpeechModelCatalog.Descriptor, at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent(descriptor.vocabularyFile))
        for name in descriptor.requiredModelNames {
            try self.installCompiledFixture(at: directory.appendingPathComponent(name, isDirectory: true))
        }
        try descriptor.writeInstallationRevision(at: directory)
    }

    private func installCompiledFixture(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("weights", isDirectory: true), withIntermediateDirectories: true)
        try Data([1]).write(to: directory.appendingPathComponent("coremldata.bin"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("metadata.json"))
        try Data([1]).write(to: directory.appendingPathComponent("weights/weight.bin"))
    }
}
