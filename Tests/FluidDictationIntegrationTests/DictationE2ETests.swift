import Foundation
import XCTest

@testable import FluidVoice_Debug

@MainActor
final class DictationE2ETests: XCTestCase {
    private let enableTranscriptionSoundsKey = "EnableTranscriptionSounds"
    private let transcriptionStartSoundKey = "TranscriptionStartSound"
    private let dictationPromptProfilesKey = "DictationPromptProfiles"
    private let appPromptBindingsKey = "AppPromptBindings"
    private let selectedDictationPromptIDKey = "SelectedDictationPromptID"
    private let selectedEditPromptIDKey = "SelectedEditPromptID"
    private let defaultDictationPromptOverrideKey = "DefaultDictationPromptOverride"
    private let defaultEditPromptOverrideKey = "DefaultEditPromptOverride"
    private let savedProvidersKey = "SavedProviders"
    private let selectedProviderIDKey = "SelectedProviderID"
    private let availableModelsByProviderKey = "AvailableModelsByProvider"
    private let selectedModelByProviderKey = "SelectedModelByProvider"
    private let customDictionaryEntriesKey = "CustomDictionaryEntries"
    private let autoLearnCustomDictionaryEnabledKey = "AutoLearnCustomDictionaryEnabled"
    private let autoLearnCustomDictionarySuggestionsKey = "AutoLearnCustomDictionarySuggestions"

    func testTranscriptionStartSound_noneOptionHasNoFile() {
        XCTAssertEqual(SettingsStore.TranscriptionStartSound.none.displayName, "None")
        XCTAssertNil(SettingsStore.TranscriptionStartSound.none.soundFileName)
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

    func testCorrectionDiffEngineCapturesCaseOnlyAcronymCorrection() {
        let candidates = CorrectionDiffEngine.findCorrectionCandidates(
            original: "yaml sample",
            edited: "YAML sample"
        )

        XCTAssertEqual(candidates, [
            CorrectionDiffEngine.Candidate(original: "yaml", replacement: "YAML"),
        ])
    }

    func testCorrectionDiffEngineCapturesCaseOnlyProductNameCorrection() {
        let candidates = CorrectionDiffEngine.findCorrectionCandidates(
            original: "fluidvoice test",
            edited: "FluidVoice test"
        )

        XCTAssertEqual(candidates, [
            CorrectionDiffEngine.Candidate(original: "fluidvoice", replacement: "FluidVoice"),
        ])
    }

    func testCorrectionDiffEnginePreservesAddedTechnicalEdgePunctuation() {
        XCTAssertEqual(
            CorrectionDiffEngine.findCorrectionCandidates(
                original: "Use net here.",
                edited: "Use .NET here."
            ),
            [CorrectionDiffEngine.Candidate(original: "net", replacement: ".NET")]
        )
        XCTAssertEqual(
            CorrectionDiffEngine.findCorrectionCandidates(
                original: "Use c here.",
                edited: "Use C++ here."
            ),
            [CorrectionDiffEngine.Candidate(original: "c", replacement: "C++")]
        )
        XCTAssertEqual(
            CorrectionDiffEngine.findCorrectionCandidates(
                original: "Use sharp here.",
                edited: "Use C# here."
            ),
            [CorrectionDiffEngine.Candidate(original: "sharp", replacement: "C#")]
        )
        XCTAssertEqual(
            CorrectionDiffEngine.findCorrectionCandidates(
                original: "Use five percent here.",
                edited: "Use 5% here."
            ),
            [CorrectionDiffEngine.Candidate(original: "five percent", replacement: "5%")]
        )
    }

    func testCorrectionDiffEngineStripsSentencePunctuationAroundTechnicalTokens() {
        let candidates = CorrectionDiffEngine.findCorrectionCandidates(
            original: "Please use node.js, here.",
            edited: "Please use Node.js, here."
        )

        XCTAssertEqual(candidates, [
            CorrectionDiffEngine.Candidate(original: "node.js", replacement: "Node.js"),
        ])
    }

    func testAutoLearnObservationPreservesPunctuationInTrigger() {
        self.withRestoredDefaults(
            keys: [
                self.customDictionaryEntriesKey,
                self.autoLearnCustomDictionarySuggestionsKey,
            ]
        ) {
            SettingsStore.shared.customDictionaryEntries = []
            SettingsStore.shared.autoLearnCustomDictionarySuggestions = []

            AutoLearnDictionaryService.shared.recordObservationForTesting(
                original: "node.js",
                replacement: "Node.js"
            )

            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.originalText, "node.js")
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.replacement, "Node.js")
        }
    }

    func testCustomDictionaryMatchesPunctuationEdgeTriggers() {
        self.withRestoredDefaults(keys: [self.customDictionaryEntriesKey]) {
            SettingsStore.shared.customDictionaryEntries = [
                SettingsStore.CustomDictionaryEntry(triggers: [".net"], replacement: ".NET"),
                SettingsStore.CustomDictionaryEntry(triggers: ["c++"], replacement: "C++"),
                SettingsStore.CustomDictionaryEntry(triggers: ["node.js"], replacement: "Node.js"),
            ]
            ASRService.invalidateDictionaryCache()

            let text = "I use c++ with .net and node.js, not objc++ or planet."
            let result = ASRService.applyCustomDictionary(text)

            XCTAssertEqual(
                result,
                "I use C++ with .NET and Node.js, not objc++ or planet."
            )
        }
    }

    func testCustomDictionaryEscapesReplacementTemplates() {
        self.withRestoredDefaults(keys: [self.customDictionaryEntriesKey]) {
            SettingsStore.shared.customDictionaryEntries = [
                SettingsStore.CustomDictionaryEntry(triggers: ["five dollars"], replacement: "$5"),
                SettingsStore.CustomDictionaryEntry(triggers: ["tools path"], replacement: #"C:\Tools"#),
            ]
            ASRService.invalidateDictionaryCache()

            let text = "Pay five dollars and open tools path."
            let result = ASRService.applyCustomDictionary(text)

            XCTAssertEqual(
                result,
                #"Pay $5 and open C:\Tools."#
            )
        }
    }

    func testAutoLearnTracksPunctuationOnlyTechnicalCorrection() {
        self.withRestoredDefaults(keys: [self.customDictionaryEntriesKey]) {
            SettingsStore.shared.customDictionaryEntries = []

            XCTAssertTrue(
                AutoLearnDictionaryService.shared.shouldTrackForTesting(
                    original: "k8s-io",
                    replacement: "k8s.io"
                )
            )
        }
    }

    func testAutoLearnTracksSimpleTitleCaseCorrectionAsOrdinarySuggestion() {
        self.withRestoredDefaults(keys: [self.customDictionaryEntriesKey]) {
            SettingsStore.shared.customDictionaryEntries = []

            XCTAssertTrue(
                AutoLearnDictionaryService.shared.shouldTrackForTesting(
                    original: "obsidian",
                    replacement: "Obsidian"
                )
            )
            XCTAssertFalse(
                AutoLearnDictionaryService.shared.isHighSignalReplacement("Obsidian")
            )
            XCTAssertEqual(
                AutoLearnDictionaryService.shared.displayThreshold(forReplacement: "Obsidian"),
                AutoLearnDictionaryService.shared.minimumSuggestionOccurrences
            )
            XCTAssertTrue(
                AutoLearnDictionaryService.shared.shouldTrackForTesting(
                    original: "works",
                    replacement: "Works"
                )
            )
            XCTAssertFalse(
                AutoLearnDictionaryService.shared.isHighSignalReplacement("Works")
            )
        }
    }

    func testAutoLearnTreatsAcronymAndCamelCaseCorrectionsAsHighSignal() {
        XCTAssertTrue(
            AutoLearnDictionaryService.shared.isHighSignalReplacement("YAML")
        )
        XCTAssertEqual(
            AutoLearnDictionaryService.shared.displayThreshold(forReplacement: "YAML"),
            1
        )
        XCTAssertTrue(
            AutoLearnDictionaryService.shared.isHighSignalReplacement("FluidVoice")
        )
        XCTAssertTrue(
            AutoLearnDictionaryService.shared.isHighSignalReplacement("Please use FluidVoice")
        )
        XCTAssertFalse(
            AutoLearnDictionaryService.shared.isHighSignalReplacement("Works")
        )
    }

    func testAutoLearnDoesNotTreatTrailingCapitalFragmentAsHighSignal() {
        XCTAssertFalse(
            AutoLearnDictionaryService.shared.isHighSignalReplacement("agree W")
        )
        XCTAssertEqual(
            AutoLearnDictionaryService.shared.displayThreshold(forReplacement: "agree W"),
            AutoLearnDictionaryService.shared.minimumSuggestionOccurrences
        )
    }

    func testAutoLearnOnlyRecordsCorrectionsFromInsertedText() {
        self.withRestoredDefaults(
            keys: [
                self.customDictionaryEntriesKey,
                self.autoLearnCustomDictionarySuggestionsKey,
            ]
        ) {
            SettingsStore.shared.customDictionaryEntries = []
            SettingsStore.shared.autoLearnCustomDictionarySuggestions = []

            AutoLearnDictionaryService.shared.recordCorrectionsForTesting(
                insertedText: "New obsidian note.",
                baselineText: "Old patten. New obsidian note.",
                currentText: "Old Pattern. New obsidian note."
            )

            XCTAssertTrue(SettingsStore.shared.autoLearnCustomDictionarySuggestions.isEmpty)

            AutoLearnDictionaryService.shared.recordCorrectionsForTesting(
                insertedText: "New obsidian note.",
                baselineText: "Old patten. New obsidian note.",
                currentText: "Old patten. New Obsidian note."
            )

            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.count, 1)
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.originalText, "obsidian")
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.replacement, "Obsidian")
        }
    }

    func testAutoLearnUsesScopedDiffForUniqueInsertionInLongDocument() {
        self.withRestoredDefaults(
            keys: [
                self.customDictionaryEntriesKey,
                self.autoLearnCustomDictionarySuggestionsKey,
            ]
        ) {
            SettingsStore.shared.customDictionaryEntries = []
            SettingsStore.shared.autoLearnCustomDictionarySuggestions = []

            let prefix = (0..<520).map { "prefix\($0)" }.joined(separator: " ")
            let suffix = (0..<520).map { "suffix\($0)" }.joined(separator: " ")
            let insertedText = "Please use zeta flow here"
            let baselineText = "\(prefix) \(insertedText) \(suffix)"
            let currentText = "\(prefix) Please use ZetaFlow here \(suffix)"

            AutoLearnDictionaryService.shared.recordCorrectionsForTesting(
                insertedText: insertedText,
                baselineText: baselineText,
                currentText: currentText
            )

            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.count, 1)
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.originalText, "zeta flow")
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.replacement, "ZetaFlow")
        }
    }

    func testAutoLearnSkipsScopedDiffWhenInsertedTextOccurrenceIsAmbiguous() {
        self.withRestoredDefaults(
            keys: [
                self.customDictionaryEntriesKey,
                self.autoLearnCustomDictionarySuggestionsKey,
            ]
        ) {
            SettingsStore.shared.customDictionaryEntries = []
            SettingsStore.shared.autoLearnCustomDictionarySuggestions = []

            let prefix = (0..<520).map { "prefix\($0)" }.joined(separator: " ")
            let suffix = (0..<520).map { "suffix\($0)" }.joined(separator: " ")
            let insertedText = "Please use zeta flow here"
            let baselineText = "\(insertedText) \(prefix) \(insertedText) \(suffix)"
            let currentText = "\(insertedText) \(prefix) Please use ZetaFlow here \(suffix)"

            AutoLearnDictionaryService.shared.recordCorrectionsForTesting(
                insertedText: insertedText,
                baselineText: baselineText,
                currentText: currentText
            )

            XCTAssertTrue(SettingsStore.shared.autoLearnCustomDictionarySuggestions.isEmpty)
        }
    }

    func testAutoLearnCountsRepeatedSessionCorrectionsWithoutDoubleCounting() {
        self.withRestoredDefaults(
            keys: [
                self.customDictionaryEntriesKey,
                self.autoLearnCustomDictionaryEnabledKey,
                self.autoLearnCustomDictionarySuggestionsKey,
            ]
        ) {
            SettingsStore.shared.customDictionaryEntries = []
            SettingsStore.shared.autoLearnCustomDictionaryEnabled = true
            SettingsStore.shared.autoLearnCustomDictionarySuggestions = []

            let baselineText = """
            I wrote an obsidian note
            I wrote an obsidian note.
            I wrote an obsidian note
            """
            let currentText = """
            I wrote an Obsidian note
            I wrote an Obsidian note.
            I wrote an Obsidian note
            """

            AutoLearnDictionaryService.shared.recordCorrectionsDuringSessionForTesting(
                insertedText: baselineText,
                baselineText: baselineText,
                currentText: currentText,
                processingPasses: 2
            )

            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.count, 1)
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.originalText, "obsidian")
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.replacement, "Obsidian")
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.occurrences, 3)
        }
    }

    func testAutoLearnCountsRepeatedMultiTokenCorrectionsInSingleSession() {
        self.withRestoredDefaults(
            keys: [
                self.customDictionaryEntriesKey,
                self.autoLearnCustomDictionaryEnabledKey,
                self.autoLearnCustomDictionarySuggestionsKey,
            ]
        ) {
            SettingsStore.shared.customDictionaryEntries = []
            SettingsStore.shared.autoLearnCustomDictionaryEnabled = true
            SettingsStore.shared.autoLearnCustomDictionarySuggestions = []

            let baselineText = """
            Please use beta flow here
            Please use beta flow here
            """
            let currentText = """
            Please use BetaFlow here
            Please use BetaFlow here
            """

            AutoLearnDictionaryService.shared.recordCorrectionsDuringSessionForTesting(
                insertedText: baselineText,
                baselineText: baselineText,
                currentText: currentText,
                processingPasses: 2
            )

            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.count, 1)
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.originalText, "beta flow")
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.replacement, "BetaFlow")
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.occurrences, 2)
        }
    }

    func testAutoLearnCountsSequentialCorrectionsWhenTargetAppReactivatesDuringMonitor() {
        self.withRestoredDefaults(
            keys: [
                self.customDictionaryEntriesKey,
                self.autoLearnCustomDictionaryEnabledKey,
                self.autoLearnCustomDictionarySuggestionsKey,
            ]
        ) {
            SettingsStore.shared.customDictionaryEntries = []
            SettingsStore.shared.autoLearnCustomDictionaryEnabled = true
            SettingsStore.shared.autoLearnCustomDictionarySuggestions = []

            let monitoredPID: pid_t = 12_345
            AutoLearnDictionaryService.shared.beginSyntheticMonitoringForTesting(
                insertedText: "Please use beta flow here",
                baselineText: "Please use beta flow here",
                monitoredPID: monitoredPID
            )
            AutoLearnDictionaryService.shared.updateSyntheticCurrentTextForTesting("Please use BetaFlow here")

            AutoLearnDictionaryService.shared.beginSyntheticMonitoringForTesting(
                insertedText: "Please use beta flow here",
                baselineText: """
                Please use BetaFlow here
                Please use beta flow here
                """,
                monitoredPID: monitoredPID
            )
            AutoLearnDictionaryService.shared.handleActivatedApplicationForTesting(pid: monitoredPID)
            AutoLearnDictionaryService.shared.updateSyntheticCurrentTextForTesting(
                """
                Please use BetaFlow here
                Please use BetaFlow here
                """
            )
            AutoLearnDictionaryService.shared.finalizeForTesting()

            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.count, 1)
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.originalText, "beta flow")
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.replacement, "BetaFlow")
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.occurrences, 2)
        }
    }

    func testAutoLearnPrefersTargetPIDForHelperElementActivation() {
        let targetPID: pid_t = 12_345
        let helperElementPID: pid_t = 54_321

        XCTAssertEqual(
            AutoLearnDictionaryService.shared.monitoringActivationPIDForTesting(
                elementPID: helperElementPID,
                targetPID: targetPID
            ),
            targetPID
        )
        XCTAssertEqual(
            AutoLearnDictionaryService.shared.monitoringActivationPIDForTesting(
                elementPID: helperElementPID,
                targetPID: nil
            ),
            helperElementPID
        )
    }

    func testAutoLearnDismissedOrdinarySuggestionReappearsAfterFreshEvidence() {
        self.withRestoredDefaults(
            keys: [
                self.customDictionaryEntriesKey,
                self.autoLearnCustomDictionarySuggestionsKey,
            ]
        ) {
            SettingsStore.shared.customDictionaryEntries = []
            SettingsStore.shared.autoLearnCustomDictionarySuggestions = [
                SettingsStore.AutoLearnSuggestion(
                    originalText: "obsidian",
                    replacement: "Obsidian",
                    occurrences: 2,
                    status: .dismissed
                ),
            ]

            AutoLearnDictionaryService.shared.recordObservationForTesting(original: "obsidian", replacement: "Obsidian")

            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.status, .dismissed)
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.dismissedAtOccurrenceCount, 2)
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.occurrences, 3)

            AutoLearnDictionaryService.shared.recordObservationForTesting(original: "obsidian", replacement: "Obsidian")

            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.status, .pending)
            XCTAssertNil(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.dismissedAtOccurrenceCount)
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.occurrences, 4)
        }
    }

    func testAutoLearnEventFallbackInfersHighSignalSelectionReplacement() {
        self.withRestoredDefaults(
            keys: [
                self.customDictionaryEntriesKey,
                self.autoLearnCustomDictionaryEnabledKey,
                self.autoLearnCustomDictionarySuggestionsKey,
            ]
        ) {
            SettingsStore.shared.customDictionaryEntries = []
            SettingsStore.shared.autoLearnCustomDictionaryEnabled = true
            SettingsStore.shared.autoLearnCustomDictionarySuggestions = []

            AutoLearnDictionaryService.shared.recordEventFallbackReplacementForTesting(
                insertedText: "Please use signal flow here",
                typedReplacement: "SignalFlow"
            )

            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.count, 1)
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.originalText, "signal flow")
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.replacement, "SignalFlow")
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.occurrences, 1)
        }
    }

    func testAutoLearnEventFallbackIncrementsExistingSuggestion() {
        self.withRestoredDefaults(
            keys: [
                self.customDictionaryEntriesKey,
                self.autoLearnCustomDictionaryEnabledKey,
                self.autoLearnCustomDictionarySuggestionsKey,
            ]
        ) {
            SettingsStore.shared.customDictionaryEntries = []
            SettingsStore.shared.autoLearnCustomDictionaryEnabled = true
            SettingsStore.shared.autoLearnCustomDictionarySuggestions = [
                SettingsStore.AutoLearnSuggestion(
                    originalText: "signal flow",
                    replacement: "SignalFlow",
                    occurrences: 4,
                    lastObservedAt: Date(),
                    status: .pending
                ),
            ]

            AutoLearnDictionaryService.shared.recordEventFallbackReplacementForTesting(
                insertedText: "Please use signal flow here",
                typedReplacement: "SignalFlow"
            )

            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.count, 1)
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.occurrences, 5)
        }
    }

    func testAutoLearnEventFallbackFlushesPendingTypedRun() {
        self.withRestoredDefaults(
            keys: [
                self.customDictionaryEntriesKey,
                self.autoLearnCustomDictionaryEnabledKey,
                self.autoLearnCustomDictionarySuggestionsKey,
            ]
        ) {
            SettingsStore.shared.customDictionaryEntries = []
            SettingsStore.shared.autoLearnCustomDictionaryEnabled = true
            SettingsStore.shared.autoLearnCustomDictionarySuggestions = []

            AutoLearnDictionaryService.shared.beginEventFallbackSessionForTesting(
                insertedText: "Please use signal flow here"
            )
            defer { AutoLearnDictionaryService.shared.stopMonitoring() }

            AutoLearnDictionaryService.shared.setEventFallbackTypedRunForTesting("SignalFlow")
            AutoLearnDictionaryService.shared.flushEventFallbackTypedRunForTesting()

            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.count, 1)
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.originalText, "signal flow")
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.replacement, "SignalFlow")
        }
    }

    func testAutoLearnEventFallbackSkipsOrdinaryTitleCaseTyping() {
        self.withRestoredDefaults(
            keys: [
                self.customDictionaryEntriesKey,
                self.autoLearnCustomDictionaryEnabledKey,
                self.autoLearnCustomDictionarySuggestionsKey,
            ]
        ) {
            SettingsStore.shared.customDictionaryEntries = []
            SettingsStore.shared.autoLearnCustomDictionaryEnabled = true
            SettingsStore.shared.autoLearnCustomDictionarySuggestions = []

            AutoLearnDictionaryService.shared.recordEventFallbackReplacementForTesting(
                insertedText: "I wrote an obsidian note",
                typedReplacement: "Obsidian"
            )

            XCTAssertTrue(SettingsStore.shared.autoLearnCustomDictionarySuggestions.isEmpty)
        }
    }

    func testAutoLearnEventFallbackSkipsUnrelatedHighSignalTyping() {
        self.withRestoredDefaults(
            keys: [
                self.customDictionaryEntriesKey,
                self.autoLearnCustomDictionaryEnabledKey,
                self.autoLearnCustomDictionarySuggestionsKey,
            ]
        ) {
            SettingsStore.shared.customDictionaryEntries = []
            SettingsStore.shared.autoLearnCustomDictionaryEnabled = true
            SettingsStore.shared.autoLearnCustomDictionarySuggestions = []

            AutoLearnDictionaryService.shared.recordEventFallbackReplacementForTesting(
                insertedText: "Please use alpha path here",
                typedReplacement: "SignalFlow"
            )

            XCTAssertTrue(SettingsStore.shared.autoLearnCustomDictionarySuggestions.isEmpty)
        }
    }

    func testAutoLearnDismissedHighSignalSuggestionReappearsAfterOneFreshObservation() {
        self.withRestoredDefaults(
            keys: [
                self.customDictionaryEntriesKey,
                self.autoLearnCustomDictionarySuggestionsKey,
            ]
        ) {
            SettingsStore.shared.customDictionaryEntries = []
            SettingsStore.shared.autoLearnCustomDictionarySuggestions = [
                SettingsStore.AutoLearnSuggestion(
                    originalText: "yaml",
                    replacement: "YAML",
                    occurrences: 1,
                    status: .dismissed,
                    dismissedAtOccurrenceCount: 1
                ),
            ]

            AutoLearnDictionaryService.shared.recordObservationForTesting(original: "yaml", replacement: "YAML")

            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.status, .pending)
            XCTAssertNil(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.dismissedAtOccurrenceCount)
            XCTAssertEqual(SettingsStore.shared.autoLearnCustomDictionarySuggestions.first?.occurrences, 2)
        }
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
        let collapsed = String(noPunct)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return collapsed
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
        let keys = [
            self.dictationPromptProfilesKey,
            self.appPromptBindingsKey,
            self.selectedDictationPromptIDKey,
            self.selectedEditPromptIDKey,
            self.defaultDictationPromptOverrideKey,
            self.defaultEditPromptOverrideKey,
        ]
        self.withRestoredDefaults(keys: keys) {
            let defaults = UserDefaults.standard
            keys.forEach { defaults.removeObject(forKey: $0) }
            run()
        }
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
}
