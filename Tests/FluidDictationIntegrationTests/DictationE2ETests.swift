@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class DictationE2ETests: XCTestCase {
    private let enableTranscriptionSoundsKey = "EnableTranscriptionSounds"
    private let transcriptionStartSoundKey = "TranscriptionStartSound"
    private let dictationPromptProfilesKey = "DictationPromptProfiles"
    private let appPromptBindingsKey = "AppPromptBindings"
    private let selectedDictationPromptIDKey = "SelectedDictationPromptID"
    private let selectedEditPromptIDKey = "SelectedEditPromptID"
    private let dictationPromptOffKey = "DictationPromptOff"
    private let editPromptOffKey = "EditPromptOff"
    private let defaultDictationPromptOverrideKey = "DefaultDictationPromptOverride"
    private let defaultEditPromptOverrideKey = "DefaultEditPromptOverride"
    private let savedProvidersKey = "SavedProviders"
    private let selectedProviderIDKey = "SelectedProviderID"
    private let availableModelsByProviderKey = "AvailableModelsByProvider"
    private let selectedModelByProviderKey = "SelectedModelByProvider"
    private let commandModeLinkedToGlobalKey = "CommandModeLinkedToGlobal"
    private let commandModeSelectedProviderIDKey = "CommandModeSelectedProviderID"
    private let commandModeSelectedModelKey = "CommandModeSelectedModel"
    private var privateAISelectedModelIDKey: String {
        PrivateAIProviderFeature.shared.selectedModelDefaultsKey
    }

    private var privateAILocalModelPathKey: String {
        PrivateAIProviderFeature.shared.localModelPathDefaultsKey
    }

    private var privateAIPrefixKVCacheEnabledKey: String {
        PrivateAIProviderFeature.shared.prefixCacheDefaultsKey
    }

    private let verifiedProviderFingerprintsKey = "VerifiedProviderFingerprints"

    func testTranscriptionStartSound_noneOptionHasNoFile() {
        XCTAssertEqual(SettingsStore.TranscriptionStartSound.none.displayName, "None")
        XCTAssertNil(SettingsStore.TranscriptionStartSound.none.startSoundFileName)
    }

    func testTranscriptionStartSound_legacyDisabledToggleMigratesToNone() {
        self.withRestoredDefaults(keys: [self.enableTranscriptionSoundsKey, self.transcriptionStartSoundKey]) {
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: self.enableTranscriptionSoundsKey)
            defaults.set(SettingsStore.TranscriptionStartSound.fluidSfx1.rawValue, forKey: self.transcriptionStartSoundKey)

            let value = SettingsStore.shared.transcriptionStartSound

            XCTAssertEqual(value, .none)
            XCTAssertNil(defaults.object(forKey: self.enableTranscriptionSoundsKey))
            XCTAssertEqual(defaults.string(forKey: self.transcriptionStartSoundKey), SettingsStore.TranscriptionStartSound.none.rawValue)
        }
    }

    func testTranscriptionStartSound_legacyEnabledToggleKeepsSelectedSound() {
        self.withRestoredDefaults(keys: [self.enableTranscriptionSoundsKey, self.transcriptionStartSoundKey]) {
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: self.enableTranscriptionSoundsKey)
            defaults.set(SettingsStore.TranscriptionStartSound.fluidSfx2.rawValue, forKey: self.transcriptionStartSoundKey)

            let value = SettingsStore.shared.transcriptionStartSound

            XCTAssertEqual(value, .fluidSfx2)
            XCTAssertNil(defaults.object(forKey: self.enableTranscriptionSoundsKey))
            XCTAssertEqual(defaults.string(forKey: self.transcriptionStartSoundKey), SettingsStore.TranscriptionStartSound.fluidSfx2.rawValue)
        }
    }

    func testDictationEndToEnd_whisperTiny_transcribesFixture() async throws {
        // Arrange
        SettingsStore.shared.shareAnonymousAnalytics = false
        SettingsStore.shared.selectedSpeechModel = .whisperTiny

        let modelDirectory = Self.modelDirectoryForRun()
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let provider = WhisperProvider(modelDirectory: modelDirectory)

        // Act
        try await provider.prepare()
        let samples = try AudioFixtureLoader.load16kMonoFloatSamples(named: "dictation_fixture", ext: "wav")
        let result = try await provider.transcribe(samples)

        // Assert
        let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(raw.isEmpty, "Expected non-empty transcription text.")

        let normalized = Self.normalize(raw)
        XCTAssertTrue(normalized.contains("hello"), "Expected transcription to contain 'hello'. Got: \(raw)")
        XCTAssertTrue(normalized.contains("fluid"), "Expected transcription to contain 'fluid'. Got: \(raw)")
        XCTAssertTrue(
            normalized.contains("voice") || normalized.contains("fluidvoice") || normalized.contains("boys"),
            "Expected transcription to contain 'voice' (or a close variant like 'boys'). Got: \(raw)"
        )
    }

    func testAppPromptBinding_profileOverridesModeSelection() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared

            let global = SettingsStore.DictationPromptProfile(
                name: "Global Dictate",
                prompt: "Global dictate prompt",
                mode: .dictate
            )
            let mail = SettingsStore.DictationPromptProfile(
                name: "Mail Dictate",
                prompt: "Mail dictate prompt",
                mode: .dictate
            )

            settings.dictationPromptProfiles = [global, mail]
            settings.selectedDictationPromptID = global.id
            settings.appPromptBindings = [
                SettingsStore.AppPromptBinding(
                    mode: .dictate,
                    appBundleID: "com.apple.mail",
                    appName: "Mail",
                    promptID: mail.id
                ),
            ]

            let mailResolution = settings.promptResolution(for: .dictate, appBundleID: "com.apple.mail")
            XCTAssertEqual(mailResolution.source, .appBindingProfile)
            XCTAssertEqual(mailResolution.profile?.id, mail.id)

            let notesResolution = settings.promptResolution(for: .dictate, appBundleID: "com.apple.notes")
            XCTAssertEqual(notesResolution.source, .selectedProfile)
            XCTAssertEqual(notesResolution.profile?.id, global.id)
        }
    }

    func testAppPromptBinding_defaultFallbackIgnoresGlobalSelection() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared

            let global = SettingsStore.DictationPromptProfile(
                name: "Global Dictate",
                prompt: "Global dictate prompt",
                mode: .dictate
            )

            settings.dictationPromptProfiles = [global]
            settings.selectedDictationPromptID = global.id
            settings.appPromptBindings = [
                SettingsStore.AppPromptBinding(
                    mode: .dictate,
                    appBundleID: "com.apple.mail",
                    appName: "Mail",
                    promptID: nil
                ),
            ]

            let mailResolution = settings.promptResolution(for: .dictate, appBundleID: "com.apple.mail")
            XCTAssertEqual(mailResolution.source, .appBindingDefault)
            XCTAssertNil(mailResolution.profile)
            XCTAssertEqual(
                mailResolution.systemPrompt,
                SettingsStore.defaultSystemPromptText(for: .dictate)
            )

            let otherResolution = settings.promptResolution(for: .dictate, appBundleID: "com.apple.notes")
            XCTAssertEqual(otherResolution.source, .selectedProfile)
            XCTAssertEqual(otherResolution.profile?.id, global.id)
        }
    }

    func testEditPromptOffUsesBuiltInDefaultAndPausesOverrides() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared

            let global = SettingsStore.DictationPromptProfile(
                name: "Global Edit",
                prompt: "Global edit prompt",
                mode: .edit
            )
            let mail = SettingsStore.DictationPromptProfile(
                name: "Mail Edit",
                prompt: "Mail edit prompt",
                mode: .edit
            )

            settings.dictationPromptProfiles = [global, mail]
            settings.selectedEditPromptID = global.id
            settings.defaultEditPromptOverride = "Custom default edit prompt"
            settings.appPromptBindings = [
                SettingsStore.AppPromptBinding(
                    mode: .edit,
                    appBundleID: "com.apple.mail",
                    appName: "Mail",
                    promptID: mail.id
                ),
            ]

            settings.setPromptOff(true, for: .edit)

            let paused = settings.promptResolution(for: .edit, appBundleID: "com.apple.mail")
            XCTAssertEqual(paused.source, .builtInDefault)
            XCTAssertNil(paused.profile)
            XCTAssertNil(paused.appBinding)
            XCTAssertEqual(paused.systemPrompt, SettingsStore.defaultSystemPromptText(for: .edit))

            settings.setSelectedPromptID(global.id, for: .edit)

            XCTAssertFalse(settings.isPromptOff(for: .edit))
            XCTAssertEqual(settings.promptResolution(for: .edit, appBundleID: nil).profile?.id, global.id)
        }
    }

    func testAppPromptBindings_reconcileInvalidPromptAndLegacyMode() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared

            let editProfile = SettingsStore.DictationPromptProfile(
                name: "Edit",
                prompt: "Edit prompt",
                mode: .edit
            )
            settings.dictationPromptProfiles = [editProfile]
            settings.appPromptBindings = [
                SettingsStore.AppPromptBinding(
                    mode: .rewrite,
                    appBundleID: " COM.APPLE.SAFARI ",
                    appName: "Safari",
                    promptID: "missing-profile"
                ),
            ]

            settings.reconcilePromptStateAfterProfileChanges()

            guard let binding = settings.appPromptBindings.first else {
                XCTFail("Expected normalized app prompt binding")
                return
            }

            XCTAssertEqual(binding.mode, .edit)
            XCTAssertEqual(binding.appBundleID, "com.apple.safari")
            XCTAssertNil(binding.promptID)
        }
    }

    func testLegacyBlockedPromptPlaceholderIsRemoved() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared

            let blocked = SettingsStore.DictationPromptProfile(
                name: "Blocked",
                prompt: "Blocked prompt",
                mode: .dictate
            )
            let real = SettingsStore.DictationPromptProfile(
                name: "Keep Me",
                prompt: "Real user prompt",
                mode: .dictate
            )

            settings.dictationPromptProfiles = [blocked, real]
            settings.selectedDictationPromptID = blocked.id
            settings.appPromptBindings = [
                SettingsStore.AppPromptBinding(
                    mode: .dictate,
                    appBundleID: "com.apple.notes",
                    appName: "Notes",
                    promptID: blocked.id
                ),
            ]

            settings.reconcilePromptStateAfterProfileChanges()

            XCTAssertEqual(settings.dictationPromptProfiles.map(\.id), [real.id])
            XCTAssertNil(settings.selectedDictationPromptID)
            XCTAssertEqual(settings.appPromptBindings.first?.promptID, nil)
        }
    }

    func testCustomProviderSettingsRoundTripThroughSettingsStore() {
        self.withProviderSettingsRestored {
            let settings = SettingsStore.shared
            let provider = SettingsStore.SavedProvider(
                id: "custom-provider-test",
                name: "Issue299 Temp",
                baseURL: "http://10.0.0.138:1234/v1",
                models: ["google/gemma-4-e4b"]
            )
            let providerKey = "custom:\(provider.id)"

            settings.savedProviders = [provider]
            settings.availableModelsByProvider = [providerKey: provider.models]
            settings.selectedModelByProvider = [providerKey: provider.models[0]]
            settings.selectedProviderID = provider.id

            XCTAssertEqual(settings.selectedProviderID, provider.id)
            XCTAssertEqual(settings.savedProviders, [provider])
            XCTAssertEqual(settings.availableModelsByProvider[providerKey], provider.models)
            XCTAssertEqual(settings.selectedModelByProvider[providerKey], provider.models[0])
        }
    }

    func testUnavailableSelectedProviderClearsSelection() {
        self.withProviderSettingsRestored {
            let settings = SettingsStore.shared

            settings.savedProviders = []
            settings.selectedProviderID = "removed-provider"

            XCTAssertEqual(settings.selectedProviderID, "")
        }
    }

    func testPrivateAIProviderDictationPromptSelection_allowsOffAndRestoresNonFluidPrompt() {
        self.withPromptAndProviderSettingsRestored {
            let settings = SettingsStore.shared
            let custom = SettingsStore.DictationPromptProfile(
                name: "Custom Dictate",
                prompt: "Use the custom prompt",
                mode: .dictate
            )
            settings.dictationPromptProfiles = [custom]
            settings.selectedModelByProvider = [
                "openai": "gpt-4.1",
                PrivateAIProviderFeature.shared.providerID: PrivateAIProviderFeature.shared.providerID,
            ]
            settings.selectedProviderID = "openai"
            settings.setDictationPromptSelection(.profile(custom.id))

            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .profile(custom.id))

            settings.selectedProviderID = PrivateAIProviderFeature.shared.providerID
            if PrivateFeatures.privateAIProvider {
                XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .privateAI)
            } else {
                XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .profile(custom.id))
            }

            settings.setDictationPromptSelection(.off)
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .off)

            settings.selectedProviderID = "openai"
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .off)

            settings.setDictationPromptSelection(.profile(custom.id))
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .profile(custom.id))
        }
    }

    func testPrivateAIProviderDictationPromptSelection_usesOnlyFluidPromptOrOffWhileSelected() {
        self.withPromptAndProviderSettingsRestored {
            let settings = SettingsStore.shared
            let custom = SettingsStore.DictationPromptProfile(
                name: "Custom Dictate",
                prompt: "Use the custom prompt",
                mode: .dictate
            )
            settings.dictationPromptProfiles = [custom]
            settings.selectedModelByProvider = [
                "openai": "gpt-4.1",
                PrivateAIProviderFeature.shared.providerID: PrivateAIProviderFeature.shared.providerID,
            ]

            settings.selectedProviderID = PrivateAIProviderFeature.shared.providerID
            settings.setDictationPromptSelection(.default)
            XCTAssertEqual(
                settings.dictationPromptSelection(for: .primary),
                PrivateFeatures.privateAIProvider ? .privateAI : .default
            )

            settings.setDictationPromptSelection(.profile(custom.id))
            XCTAssertEqual(
                settings.dictationPromptSelection(for: .primary),
                PrivateFeatures.privateAIProvider ? .privateAI : .profile(custom.id)
            )

            settings.setDictationPromptSelection(.off)
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .off)
            XCTAssertEqual(settings.dictationPromptDisplayName(for: .primary, appBundleID: nil), "Off")

            settings.selectedProviderID = "openai"
            settings.setDictationPromptSelection(.profile(custom.id))
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .profile(custom.id))
        }
    }

    func testPrivateAIProviderPrefixKVCache_defaultsOnAndPersistsToggle() {
        self.withRestoredDefaults(keys: [self.privateAIPrefixKVCacheEnabledKey]) {
            let settings = SettingsStore.shared

            XCTAssertTrue(settings.privateAIPrefixKVCacheEnabled)

            settings.privateAIPrefixKVCacheEnabled = false
            XCTAssertFalse(settings.privateAIPrefixKVCacheEnabled)

            settings.privateAIPrefixKVCacheEnabled = true
            XCTAssertTrue(settings.privateAIPrefixKVCacheEnabled)
        }
    }

    func testPrivateAIProviderLocalRuntimeOnlyHandlesPrivateModels() {
        self.withRestoredDefaults(keys: [self.privateAILocalModelPathKey]) {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("FluidVoice-PrivateAI-\(UUID().uuidString).gguf")
            XCTAssertTrue(FileManager.default.createFile(atPath: tempURL.path, contents: Data(), attributes: nil))
            defer { try? FileManager.default.removeItem(at: tempURL) }

            UserDefaults.standard.set(tempURL.path, forKey: self.privateAILocalModelPathKey)

            XCTAssertEqual(
                PrivateAIIntegrationService.isLocalRuntimeConfigured,
                PrivateFeatures.privateAIProvider
            )
            XCTAssertFalse(PrivateAIIntegrationService.shouldHandleDictation(model: "gpt-4.1"))
            XCTAssertEqual(
                PrivateAIIntegrationService.shouldHandleDictation(model: PrivateAIProviderFeature.shared.providerID),
                PrivateFeatures.privateAIProvider
            )
        }
    }

    func testPrivateAIProviderLocalRuntimeDoesNotConfigureNonFluidProvider() {
        self.withRestoredDefaults(
            keys: [
                self.privateAILocalModelPathKey,
                self.selectedProviderIDKey,
                self.selectedModelByProviderKey,
                self.verifiedProviderFingerprintsKey,
                self.selectedDictationPromptIDKey,
                self.dictationPromptOffKey,
            ]
        ) {
            let settings = SettingsStore.shared
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("FluidVoice-PrivateAI-\(UUID().uuidString).gguf")
            XCTAssertTrue(FileManager.default.createFile(atPath: tempURL.path, contents: Data(), attributes: nil))
            defer { try? FileManager.default.removeItem(at: tempURL) }

            UserDefaults.standard.set(tempURL.path, forKey: self.privateAILocalModelPathKey)
            settings.selectedProviderID = "openai"
            settings.selectedModelByProvider = ["openai": "gpt-4.1"]
            settings.verifiedProviderFingerprints = [:]
            settings.setDictationPromptSelection(.default)

            XCTAssertEqual(
                PrivateAIIntegrationService.isLocalRuntimeConfigured,
                PrivateFeatures.privateAIProvider
            )
            XCTAssertFalse(DictationAIPostProcessingGate.isConfigured(for: .primary, appBundleID: nil))
        }
    }

    func testPrivateAIProviderDoesNotConfigureCommandMode() {
        guard PrivateFeatures.privateAIProvider else { return }

        self.withRestoredDefaults(
            keys: [
                self.selectedProviderIDKey,
                self.commandModeLinkedToGlobalKey,
                self.commandModeSelectedProviderIDKey,
                self.commandModeSelectedModelKey,
            ]
        ) {
            let settings = SettingsStore.shared
            settings.selectedProviderID = PrivateAIProviderFeature.shared.providerID
            settings.commandModeLinkedToGlobal = true
            settings.commandModeSelectedProviderID = PrivateAIProviderFeature.shared.providerID
            settings.commandModeSelectedModel = PrivateAIProviderFeature.shared.providerID

            XCTAssertEqual(settings.effectiveCommandModeProviderID, "")
            XCTAssertTrue(settings.commandModeReadinessIssue?.contains("coming soon") == true)
            XCTAssertFalse(settings.isCommandModeProviderVerified(PrivateAIProviderFeature.shared.providerID))
        }
    }

    func testRollbackBackupsPreferFilenameTimestampOverModificationDate() {
        let firstBackupWithNewestModificationDate = URL(
            fileURLWithPath: "/tmp/FluidVoice-1.5.11-beta.1-100.app"
        )
        let secondBackup = URL(
            fileURLWithPath: "/tmp/FluidVoice-1.5.11-beta.2-150.app"
        )
        let thirdBackup = URL(
            fileURLWithPath: "/tmp/FluidVoice-1.5.11-beta.3-rollback-200.app"
        )
        let fourthBackupWithOldestModificationDate = URL(
            fileURLWithPath: "/tmp/FluidVoice-1.5.11-beta.4-rollback-300.app"
        )
        let modificationDates = [
            firstBackupWithNewestModificationDate: Date(timeIntervalSince1970: 500),
            secondBackup: Date(timeIntervalSince1970: 300),
            thirdBackup: Date(timeIntervalSince1970: 50),
            fourthBackupWithOldestModificationDate: Date(timeIntervalSince1970: 10),
        ]

        let sorted = SimpleUpdater.sortedRollbackBackups(
            [
                firstBackupWithNewestModificationDate,
                secondBackup,
                thirdBackup,
                fourthBackupWithOldestModificationDate,
            ]
        ) { url in
            modificationDates[url]
        }

        XCTAssertEqual(
            sorted,
            [
                fourthBackupWithOldestModificationDate,
                thirdBackup,
                secondBackup,
                firstBackupWithNewestModificationDate,
            ]
        )
    }

    func testRollbackVersionIgnoresCurrentAppVersion() {
        XCTAssertFalse(SimpleUpdater.isRollbackVersion("1.5.11-beta.3", differentFrom: "1.5.11-beta.3"))
        XCTAssertTrue(SimpleUpdater.isRollbackVersion("1.5.11-beta.2", differentFrom: "1.5.11-beta.3"))
        XCTAssertFalse(SimpleUpdater.isRollbackVersion(nil, differentFrom: "1.5.11-beta.3"))
    }

    // MARK: - Model download HTML/markup rejection (#353)

    func testLooksLikeHTML_rejectsMarkupVariants() {
        // A proxy/block page or stand-in markup document must be rejected regardless of
        // which markup token it opens with — not just <!doctype / <html.
        let rejected = [
            "<!DOCTYPE html><html lang=\"en\"><head></head></html>",
            "<html><body>Blocked by corporate proxy</body></html>",
            "<script>window.location='https://proxy'</script>",
            "<head><title>Access Denied</title></head>",
            "<body>Forbidden</body>",
            "<meta http-equiv=\"refresh\" content=\"0\">",
            "<!-- corporate gateway notice -->",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><error>blocked</error>",
            "</html>",
            "<!doctype HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\">",
        ]
        for markup in rejected {
            XCTAssertTrue(
                HuggingFaceModelDownloader.looksLikeHTML(Data(markup.utf8)),
                "Expected markup to be rejected: \(markup)"
            )
        }
    }

    func testLooksLikeHTML_rejectsLeadingWhitespaceAndBOMVariants() {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

        // Leading ASCII whitespace before the markup token.
        XCTAssertTrue(HuggingFaceModelDownloader.looksLikeHTML(Data("   \n\t<!DOCTYPE html>".utf8)))
        XCTAssertTrue(HuggingFaceModelDownloader.looksLikeHTML(Data("\r\n  <html>".utf8)))

        // UTF-8 BOM, then markup.
        XCTAssertTrue(HuggingFaceModelDownloader.looksLikeHTML(Data(bom + Array("<html>".utf8))))

        // BOM, then whitespace, then an XML declaration.
        XCTAssertTrue(
            HuggingFaceModelDownloader.looksLikeHTML(Data(bom + Array("  \n<?xml version=\"1.0\"?>".utf8)))
        )
    }

    func testLooksLikeHTML_acceptsModelArtifacts() {
        // JSON object (vocab / metadata / Manifest) — note the embedded `<pad>` must NOT
        // trip the detector; only a LEADING `<` does.
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data("{\"0\": \"<pad>\", \"1\": \"a\"}".utf8)))
        // JSON array body.
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data("[1, 2, 3]".utf8)))
        // MIL program text (`model.mil`).
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data("program(1.0)\n[buildInfo = ...]".utf8)))
        // Binary CoreML / Mach-O magic prefix.
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data([0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00])))
        // Leading-NUL binary (e.g. coremldata.bin / weight.bin style payloads).
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data([0x00, 0x00, 0x01, 0x3C, 0x68])))
        // Empty payload.
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data()))
        // A stray `<` NOT followed by a markup-ish byte must not be over-rejected.
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data("< not markup".utf8)))
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data("<".utf8)))
    }

    func testValidateDownloadedFile_rejectsHTMLBodyAndAcceptsJSON() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidVoice-ValidateTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // HTML body written without an HTML Content-Type (response: nil) must still be
        // rejected by the byte-sniff path.
        let htmlURL = dir.appendingPathComponent("coremldata.bin")
        try Data("<!DOCTYPE html><html><body>Blocked</body></html>".utf8).write(to: htmlURL)
        XCTAssertThrowsError(
            try HuggingFaceModelDownloader.validateDownloadedFile(
                at: htmlURL,
                response: nil,
                relativePath: "coremldata.bin"
            )
        )

        // A real JSON vocab payload must pass validation.
        let jsonURL = dir.appendingPathComponent("parakeet_v3_vocab.json")
        try Data("{\"0\": \"<pad>\", \"1\": \"the\"}".utf8).write(to: jsonURL)
        XCTAssertNoThrow(
            try HuggingFaceModelDownloader.validateDownloadedFile(
                at: jsonURL,
                response: nil,
                relativePath: "parakeet_v3_vocab.json"
            )
        )
    }

    func testCachedFileIsMarkup_detectsCachedCorruptHTMLAndAcceptsModelData() throws {
        // Guards the #353 cached-file path: a corrupt HTML payload already on disk (cached
        // before download-time validation existed) must be detected so it is re-downloaded,
        // while a real model artifact must not be flagged, and an unreadable path must be
        // treated as valid (never deleted on uncertainty).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidVoice-CachedMarkupTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A cached HTML/proxy page persisted as a model file must be detected as markup.
        let htmlURL = dir.appendingPathComponent("coremldata.bin")
        try Data("<!DOCTYPE html><html><body>Blocked by proxy</body></html>".utf8).write(to: htmlURL)
        XCTAssertTrue(HuggingFaceModelDownloader.cachedFileIsMarkup(at: htmlURL))

        // A real JSON vocab payload must not be flagged.
        let jsonURL = dir.appendingPathComponent("parakeet_v3_vocab.json")
        try Data("{\"0\": \"<pad>\", \"1\": \"the\"}".utf8).write(to: jsonURL)
        XCTAssertFalse(HuggingFaceModelDownloader.cachedFileIsMarkup(at: jsonURL))

        // An unreadable / missing path must be treated as valid (conservative on read error).
        let missingURL = dir.appendingPathComponent("does-not-exist.bin")
        XCTAssertFalse(HuggingFaceModelDownloader.cachedFileIsMarkup(at: missingURL))
    }

    func testCachedPayloadContainsMarkup_detectsCorruptFileInPresentArtifactTree() throws {
        // Guards the #353 provider-PREFLIGHT path: a corrupt HTML payload nested inside a
        // present `.mlpackage` bundle (or a loose required file) must be detected so the preflight
        // re-downloads instead of trusting a file-existence/manifest check, while a valid cached
        // tree must not be flagged, and missing/empty required entries stay conservative.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidVoice-CachedPayloadTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A realistic `.mlpackage` layout: a JSON manifest plus a nested binary weight payload.
        let packageName = "encoder.mlpackage"
        let weightsDir = root.appendingPathComponent(packageName)
            .appendingPathComponent("Data/com.apple.CoreML/weights", isDirectory: true)
        try FileManager.default.createDirectory(at: weightsDir, withIntermediateDirectories: true)
        let manifestURL = root.appendingPathComponent(packageName).appendingPathComponent("Manifest.json")
        try Data("{\"fileFormatVersion\": \"1.0.0\"}".utf8).write(to: manifestURL)
        let weightURL = weightsDir.appendingPathComponent("weight.bin")
        try Data([0x00, 0x01, 0x02, 0x03, 0x04]).write(to: weightURL)

        // A loose required file (e.g. a tokenizer) with real binary content.
        let tokenizerURL = root.appendingPathComponent("tokenizer.model")
        try Data([0x0A, 0x09, 0x05, 0x00]).write(to: tokenizerURL)

        let entries = [packageName, "tokenizer.model"]

        // An all-valid tree must not be flagged.
        XCTAssertFalse(
            HuggingFaceModelDownloader.cachedPayloadContainsMarkup(root: root, relativePaths: entries)
        )

        // A proxy HTML page persisted as a binary INSIDE the package must be detected.
        try Data("<!DOCTYPE html><html><body>Blocked by proxy</body></html>".utf8).write(to: weightURL)
        XCTAssertTrue(
            HuggingFaceModelDownloader.cachedPayloadContainsMarkup(root: root, relativePaths: entries)
        )

        // Restore the binary; corrupt the loose required file instead — must still be detected.
        try Data([0x00, 0x01, 0x02, 0x03, 0x04]).write(to: weightURL)
        try Data("<html><head></head></html>".utf8).write(to: tokenizerURL)
        XCTAssertTrue(
            HuggingFaceModelDownloader.cachedPayloadContainsMarkup(root: root, relativePaths: entries)
        )

        // Missing entries and an empty required directory are conservative: never flagged corrupt
        // on uncertainty (incompleteness is the existence check's concern, not this one's).
        try Data([0x0A, 0x09, 0x05, 0x00]).write(to: tokenizerURL)
        let emptyPackage = root.appendingPathComponent("empty.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyPackage, withIntermediateDirectories: true)
        XCTAssertFalse(
            HuggingFaceModelDownloader.cachedPayloadContainsMarkup(
                root: root,
                relativePaths: ["empty.mlpackage", "does-not-exist.json"]
            )
        )
    }

    private static func modelDirectoryForRun() -> URL {
        // Use a stable path on CI so GitHub Actions cache can speed up runs.
        if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" ||
            ProcessInfo.processInfo.environment["CI"] == "true"
        {
            guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                preconditionFailure("Could not find caches directory")
            }
            return caches.appendingPathComponent("WhisperModels")
        }

        // Local runs: isolate per test execution.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidVoiceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return base.appendingPathComponent("WhisperModels", isDirectory: true)
    }

    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let noPunct = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.punctuationCharacters.contains(scalar) { return " " }
            return Character(scalar)
        }
        return String(noPunct)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func withRestoredDefaults(keys: [String], run: () -> Void) {
        let defaults = UserDefaults.standard
        var snapshot: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) {
                snapshot[key] = value
            }
        }

        defer {
            for key in keys {
                if let previous = snapshot[key] {
                    defaults.set(previous, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        run()
    }

    private func withPromptSettingsRestored(run: () -> Void) {
        self.withRestoredDefaults(
            keys: [
                self.dictationPromptProfilesKey,
                self.appPromptBindingsKey,
                self.selectedDictationPromptIDKey,
                self.selectedEditPromptIDKey,
                self.dictationPromptOffKey,
                self.editPromptOffKey,
                self.defaultDictationPromptOverrideKey,
                self.defaultEditPromptOverrideKey,
            ],
            run: run
        )
    }

    private func withProviderSettingsRestored(run: () -> Void) {
        self.withRestoredDefaults(
            keys: [
                self.savedProvidersKey,
                self.selectedProviderIDKey,
                self.availableModelsByProviderKey,
                self.selectedModelByProviderKey,
            ],
            run: run
        )
    }

    private func withPromptAndProviderSettingsRestored(run: () -> Void) {
        self.withRestoredDefaults(
            keys: [
                self.dictationPromptProfilesKey,
                self.appPromptBindingsKey,
                self.selectedDictationPromptIDKey,
                self.selectedEditPromptIDKey,
                self.dictationPromptOffKey,
                self.editPromptOffKey,
                self.defaultDictationPromptOverrideKey,
                self.defaultEditPromptOverrideKey,
                self.savedProvidersKey,
                self.selectedProviderIDKey,
                self.availableModelsByProviderKey,
                self.selectedModelByProviderKey,
                self.privateAISelectedModelIDKey,
            ],
            run: run
        )
    }
}
