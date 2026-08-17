import AppKit
import Carbon.HIToolbox
import CoreGraphics
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
    private let dictationPromptRoutingScopeKey = "DictationPromptRoutingScope"
    private let savedProvidersKey = "SavedProviders"
    private let selectedProviderIDKey = "SelectedProviderID"
    private let selectedAIModelKey = "SelectedAIModel"
    private let availableModelsByProviderKey = "AvailableModelsByProvider"
    private let selectedModelByProviderKey = "SelectedModelByProvider"
    private let dictationPromptConfigurationsKey = "DictationPromptConfigurations"
    private let customDictionaryEntriesKey = "CustomDictionaryEntries"
    private let autoConvertPunctuationEnabledKey = "AutoConvertPunctuationEnabled"
    private let literalDictationFormattingEnabledKey = "LiteralDictationFormattingEnabled"
    private let punctuationDictionaryPrefixKey = "PunctuationDictionaryPrefix"
    private let punctuationDictionaryRulesKey = "PunctuationDictionaryRules"
    private let spokenFormattingActionRulesKey = "SpokenFormattingActionRules"
    private let commandModeLinkedToGlobalKey = "CommandModeLinkedToGlobal"
    private let commandModeSelectedProviderIDKey = "CommandModeSelectedProviderID"
    private let commandModeSelectedModelKey = "CommandModeSelectedModel"
    private let rewriteModeSelectedProviderIDKey = "RewriteModeSelectedProviderID"
    private let rewriteModeSelectedModelKey = "RewriteModeSelectedModel"
    private var privateAISelectedModelIDKey: String {
        PrivateAIProviderFeature.shared.selectedModelDefaultsKey
    }

    private var privateAILocalModelPathKey: String {
        PrivateAIProviderFeature.shared.localModelPathDefaultsKey
    }

    private var privateAIPrefixKVCacheEnabledKey: String {
        PrivateAIProviderFeature.shared.prefixCacheDefaultsKey
    }

    private var privateAIBoostEnabledKey: String {
        PrivateAIProviderFeature.shared.boostDefaultsKey
    }

    private let privateAIContextTokenLimitKey = "PrivateAIProviderContextTokenLimit"
    private let privateAIContextDefaultMigratedTo4KKey = "PrivateAIProviderContextDefaultMigratedTo4K"

    private let verifiedProviderFingerprintsKey = "VerifiedProviderFingerprints"

    private var punctuationFormattingDefaultsKeys: [String] {
        [
            self.autoConvertPunctuationEnabledKey,
            self.punctuationDictionaryPrefixKey,
            self.punctuationDictionaryRulesKey,
            self.spokenFormattingActionRulesKey,
        ]
    }

    func testTranscriptionHistoryEntryClipboardTextPrefersProcessedText() {
        let entry = TranscriptionHistoryEntry(
            rawText: " raw transcript ",
            processedText: " processed transcript ",
            appName: "Notes",
            windowTitle: "Draft",
            wasAIProcessed: true
        )

        XCTAssertEqual(entry.clipboardText, "processed transcript")
    }

    func testTranscriptionHistoryEntryClipboardTextFallsBackToRawText() {
        let entry = TranscriptionHistoryEntry(
            rawText: " raw transcript ",
            processedText: "   ",
            appName: "Notes",
            windowTitle: "Draft",
            wasAIProcessed: false
        )

        XCTAssertEqual(entry.clipboardText, "raw transcript")
    }

    func testTranscriptionHistoryEntryClipboardTextSkipsEmptyText() {
        let entry = TranscriptionHistoryEntry(
            rawText: "   ",
            processedText: "   ",
            appName: "Notes",
            windowTitle: "Draft",
            wasAIProcessed: false
        )

        XCTAssertNil(entry.clipboardText)
    }

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

    func testDictionaryTransferDocument_encodesSimpleUserFormat() throws {
        let document = DictionaryTransferDocument(
            replacements: [
                DictionaryTransferReplacement(from: ["fluid voice", "fluid boys"], to: "FluidVoice"),
            ],
            customWords: ["FluidVoice", "GEMBA-E"]
        )

        let data = try DictionaryTransferService.shared.encode(document)
        let json = String(data: data, encoding: .utf8) ?? ""
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let replacements = try XCTUnwrap(root["replacements"] as? [[String: Any]])
        let firstReplacement = try XCTUnwrap(replacements.first)

        XCTAssertEqual(firstReplacement["from"] as? [String], ["fluid voice", "fluid boys"])
        XCTAssertEqual(firstReplacement["to"] as? String, "FluidVoice")
        XCTAssertEqual(root["customWords"] as? [String], ["FluidVoice", "GEMBA-E"])
        XCTAssertFalse(json.contains("\"triggers\""))
        XCTAssertFalse(json.contains("\"replacement\""))
        XCTAssertFalse(json.contains("\"aliases\""))
    }

    func testDictionaryTransferImport_replaceMapsSimpleFormatToStores() throws {
        let document = DictionaryTransferDocument(
            replacements: [
                DictionaryTransferReplacement(from: [" Fluid Voice ", "FLUID BOYS", ""], to: " FluidVoice "),
            ],
            customWords: [" FluidVoice ", "fluidvoice", " Barath "]
        )
        let existingReplacement = SettingsStore.CustomDictionaryEntry(triggers: ["old"], replacement: "Old")
        let existingWord = ParakeetVocabularyStore.VocabularyConfig.Term(text: "OldWord", weight: 13.0)

        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .replace,
            currentReplacements: [existingReplacement],
            currentCustomWords: [existingWord]
        )

        XCTAssertEqual(state.replacements.count, 1)
        XCTAssertEqual(state.replacements.first?.triggers, ["fluid voice", "fluid boys"])
        XCTAssertEqual(state.replacements.first?.replacement, "FluidVoice")
        XCTAssertEqual(state.customWords.map(\.text), ["FluidVoice", "Barath"])
        XCTAssertEqual(state.customWords.map(\.weight), [10.0, 10.0])
        XCTAssertEqual(state.customWords.map(\.aliases), [[], []])
    }

    func testDictionaryTransferImport_mergeDedupesAndMovesDuplicateTriggers() throws {
        let oldReplacement = SettingsStore.CustomDictionaryEntry(
            triggers: ["fluid voice", "old trigger"],
            replacement: "Old"
        )
        let existingReplacement = SettingsStore.CustomDictionaryEntry(
            triggers: ["fluid boys"],
            replacement: "FluidVoice"
        )
        let existingWord = ParakeetVocabularyStore.VocabularyConfig.Term(
            text: "Barath",
            weight: 13.0,
            aliases: ["barath w"]
        )
        let document = DictionaryTransferDocument(
            replacements: [
                DictionaryTransferReplacement(from: ["fluid voice", "fluid boys"], to: "FluidVoice"),
            ],
            customWords: ["barath", "GEMBA-E"]
        )

        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .merge,
            currentReplacements: [oldReplacement, existingReplacement],
            currentCustomWords: [existingWord]
        )

        let fluidVoiceEntry = try XCTUnwrap(state.replacements.first { $0.replacement == "FluidVoice" })
        let oldEntry = try XCTUnwrap(state.replacements.first { $0.replacement == "Old" })
        let barathTerm = try XCTUnwrap(state.customWords.first { $0.text == "Barath" })
        let gembaeTerm = try XCTUnwrap(state.customWords.first { $0.text == "GEMBA-E" })

        XCTAssertEqual(Set(fluidVoiceEntry.triggers), Set(["fluid voice", "fluid boys"]))
        XCTAssertEqual(oldEntry.triggers, ["old trigger"])
        XCTAssertEqual(barathTerm.weight, 13.0)
        XCTAssertEqual(barathTerm.aliases, ["barath w"])
        XCTAssertEqual(gembaeTerm.weight, 10.0)
    }

    func testDictionaryTransferImport_acceptsAppStyleReplacementKeysAndSingleFromValue() throws {
        let json = """
        {
          "replacements": [
            {
              "from": "fluid voice",
              "to": "FluidVoice"
            },
            {
              "triggers": ["gemba e"],
              "replacement": "GEMBA-E"
            }
          ]
        }
        """

        let document = try DictionaryTransferService.shared.decode(Data(json.utf8))
        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .replace,
            currentReplacements: [],
            currentCustomWords: []
        )

        XCTAssertEqual(state.replacements.map(\.triggers), [["fluid voice"], ["gemba e"]])
        XCTAssertEqual(state.replacements.map(\.replacement), ["FluidVoice", "GEMBA-E"])
    }

    func testDictionaryTransferImport_acceptsLocalAPIReplacementItemsResponse() throws {
        let json = """
        {
          "count": 1,
          "items": [
            {
              "triggers": ["fluid voice"],
              "replacement": "FluidVoice"
            }
          ]
        }
        """

        let document = try DictionaryTransferService.shared.decode(Data(json.utf8))
        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .replace,
            currentReplacements: [],
            currentCustomWords: []
        )

        XCTAssertEqual(state.replacements.first?.triggers, ["fluid voice"])
        XCTAssertEqual(state.replacements.first?.replacement, "FluidVoice")
        XCTAssertEqual(state.customWords.count, 0)
    }

    func testDictionaryTransferImportFeedsActualReplacementPath() throws {
        defer { ASRService.invalidateDictionaryCache() }
        let document = DictionaryTransferDocument(
            replacements: [
                DictionaryTransferReplacement(from: ["fluid voice"], to: "FluidVoice"),
            ],
            customWords: []
        )
        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .replace,
            currentReplacements: [],
            currentCustomWords: []
        )

        self.withRestoredDefaults(keys: [self.customDictionaryEntriesKey]) {
            SettingsStore.shared.customDictionaryEntries = state.replacements
            ASRService.invalidateDictionaryCache()

            XCTAssertEqual(
                ASRService.applyCustomDictionary("I use fluid voice daily."),
                "I use FluidVoice daily."
            )
        }
    }

    func testCustomDictionaryReplacementTreatsReplacementTextLiterally() {
        defer { ASRService.invalidateDictionaryCache() }
        let entry = SettingsStore.CustomDictionaryEntry(
            triggers: ["dollar path"],
            replacement: #"$5 \path"#
        )

        self.withRestoredDefaults(keys: [self.customDictionaryEntriesKey]) {
            SettingsStore.shared.customDictionaryEntries = [entry]
            ASRService.invalidateDictionaryCache()

            XCTAssertEqual(
                ASRService.applyCustomDictionary("Use dollar path now."),
                #"Use $5 \path now."#
            )
        }
    }

    func testPronunciationDictionaryLabelsUseLastDuplicateEntry() {
        let id = UUID()
        let labels = FluidAudioProvider.dictionaryLabels(from: [
            SettingsStore.CustomDictionaryEntry(id: id, triggers: ["old"], replacement: "Old"),
            SettingsStore.CustomDictionaryEntry(id: id, triggers: ["new"], replacement: "New"),
        ])

        XCTAssertEqual(labels, [id: "New"])
    }

    func testCustomDictionaryReplacementMatchesPunctuationTriggers() {
        defer { ASRService.invalidateDictionaryCache() }
        let entry = SettingsStore.CustomDictionaryEntry(
            triggers: [",,", ","],
            replacement: ","
        )

        self.withRestoredDefaults(keys: [self.customDictionaryEntriesKey]) {
            SettingsStore.shared.customDictionaryEntries = [entry]
            ASRService.invalidateDictionaryCache()

            XCTAssertEqual(
                ASRService.applyCustomDictionary("Hello,, world."),
                "Hello, world."
            )
            XCTAssertEqual(
                ASRService.applyCustomDictionary("Hello, world."),
                "Hello, world."
            )
        }
    }

    func testSlashCommandFormattingLeavesNonCommandSlashUsageAlone() {
        let text = "Use 1/2 and and/or. Open src slash services. Go to https slash slash example dot com. Slash and burn."

        XCTAssertEqual(
            ASRService.applySlashCommandFormatting(text),
            text
        )
    }

    func testLiteralFormattingCanBeDisabled() {
        self.withRestoredDefaults(keys: [self.literalDictationFormattingEnabledKey]) {
            UserDefaults.standard.removeObject(forKey: self.literalDictationFormattingEnabledKey)
            XCTAssertFalse(SettingsStore.shared.literalDictationFormattingEnabled)

            UserDefaults.standard.set(false, forKey: self.literalDictationFormattingEnabledKey)

            XCTAssertEqual(ASRService.applySlashCommandFormatting("slash compact"), "slash compact")
            XCTAssertEqual(ASRService.applyMentionFormatting("mention Paul"), "mention Paul")
            XCTAssertEqual(
                ASRService.makeDictationLiteralOutputPlan(
                    for: "/compact ",
                    appName: "Codex",
                    bundleID: "com.openai.codex"
                ).plainText,
                "/compact "
            )
        }
    }

    func testMentionFormattingLeavesProseAlone() {
        let text = "I am at the store. Meet me at lunch. I am at Paul. Look at Paul's message."

        XCTAssertEqual(
            ASRService.applyMentionFormatting(text, appName: "Slack", bundleID: "com.tinyspeck.slackmacgap"),
            text
        )
    }

    func testMentionOutputPlanDoesNotAutoConfirmAutocomplete() {
        let plan = ASRService.makeDictationLiteralOutputPlan(
            for: "@Paul can you check this",
            appName: "Slack",
            bundleID: "com.tinyspeck.slackmacgap"
        )

        XCTAssertEqual(plan.steps, [.text("@Paul can you check this")])
        XCTAssertEqual(plan.plainText, "@Paul can you check this")
    }

    func testMentionOutputPlanStaysPlainOutsideMentionApps() {
        let text = "@Paul can you check this"

        XCTAssertEqual(
            ASRService.makeDictationLiteralOutputPlan(
                for: text,
                appName: "Notes",
                bundleID: "com.apple.Notes"
            ).steps,
            [.text(text)]
        )
    }

    func testSpokenPunctuationFormattingRequiresDictionaryPrefix() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting(
                    "Hello literal comma world literal question mark literal open paren yes literal close paren literal quote done literal quote"
                ),
                "Hello, world? (yes) \"done\""
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("Hello comma world question mark"),
                "Hello comma world question mark"
            )
        }
    }

    func testSpokenPunctuationFormattingConvertsCodeAndContactPunctuationWithPrefix() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting(
                    "email literal at the rate example literal dot com literal slash help literal underscore me"
                ),
                "email@example.com/help_me"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting(
                    "email literal at sign example literal dot com",
                    appName: "Codex",
                    bundleID: "com.openai.codex"
                ),
                "email@example.com"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("email at sign example"),
                "email at sign example"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("x literal hyphen ray costs 50 literal percent"),
                "x-ray costs 50%"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("a literal plus b literal equals c"),
                "a + b = c"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("plus equal percent"),
                "plus equal percent"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal plus literal equal 50 literal percent"),
                "+ = 50%"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("plus I need the normal word"),
                "plus I need the normal word"
            )
        }
    }

    func testSpokenPunctuationFormattingKeepsBareDotInProse() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("the polka dot dress"),
                "the polka dot dress"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("example literal dot com"),
                "example.com"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("version 1 literal dot 2"),
                "version 1.2"
            )
        }
    }

    func testSpokenPunctuationFormattingCleansGeneratedCommaNoiseWithPrefix() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal hyphen literal comma literal hyphen literal comma literal hyphen"),
                "---"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("50 literal comma literal percent"),
                "50%"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal open bracket literal comma literal close bracket"),
                "[]"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal open paren literal comma literal close paren"),
                "()"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal question mark literal comma literal exclamation mark"),
                "?!"
            )
        }
    }

    func testSpokenPunctuationFormattingPreservesExistingCommasNearSymbols() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("Thanks, @Sam"),
                "Thanks, @Sam"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("Use C++, now"),
                "Use C++, now"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("-,-,-"),
                "-,-,-"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("50, %"),
                "50, %"
            )
        }
    }

    func testSpokenPunctuationFormattingRespectsSetting() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            UserDefaults.standard.set(false, forKey: self.autoConvertPunctuationEnabledKey)

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("Hello literal comma world literal question mark"),
                "Hello literal comma world literal question mark"
            )
        }
    }

    func testSpokenPunctuationFormattingUsesCustomPrefixAndRules() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            let settings = SettingsStore.shared
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)
            settings.punctuationDictionaryPrefix = "type"
            settings.punctuationDictionaryRules = [
                SettingsStore.PunctuationDictionaryRule(
                    aliases: ["right arrow", "arrow"],
                    symbol: "->"
                ),
            ]

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("type right arrow"),
                "->"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal right arrow"),
                "literal right arrow"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("type comma"),
                "type comma"
            )
        }
    }

    func testSpokenPunctuationFormattingUsesEditedRules() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            let settings = SettingsStore.shared
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)
            settings.punctuationDictionaryRules = [
                SettingsStore.PunctuationDictionaryRule(
                    aliases: ["full stop"],
                    symbol: "."
                ),
            ]

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal full stop"),
                "."
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal period"),
                "literal period"
            )
        }
    }

    func testTerminalLiteralAutocompleteSpacingLeavesNonAutocompleteTextAlone() {
        XCTAssertEqual(
            ASRService.applyTerminalLiteralAutocompleteSpacing(
                "/model ",
                appName: "Notes",
                bundleID: "com.apple.Notes"
            ),
            "/model "
        )
        XCTAssertEqual(
            ASRService.applyTerminalLiteralAutocompleteSpacing(
                "Run /status please ",
                appName: "Codex",
                bundleID: "com.openai.codex"
            ),
            "Run /status please "
        )
        XCTAssertEqual(
            ASRService.applyTerminalLiteralAutocompleteSpacing(
                "@Paul can you check this ",
                appName: "Slack",
                bundleID: "com.tinyspeck.slackmacgap"
            ),
            "@Paul can you check this "
        )
    }

    func testSlashCommandOutputPlanDoesNotAutoConfirmAutocomplete() {
        XCTAssertEqual(
            ASRService.makeDictationLiteralOutputPlan(
                for: "/goal update the plan",
                appName: "Codex",
                bundleID: "com.openai.codex"
            ).steps,
            [.text("/goal update the plan")]
        )
        XCTAssertEqual(
            ASRService.makeDictationLiteralOutputPlan(
                for: "Run /status please",
                appName: "Codex",
                bundleID: "com.openai.codex"
            ).steps,
            [.text("Run /status please")]
        )
    }

    func testDictionaryTrainingNormalizesSamplesAndIgnoresIntendedText() {
        let triggers = CustomDictionaryTrainingMerge.normalizedTriggers(
            from: [" Fluid Voice. ", "FluidVoice", "fluid voice", " "],
            intendedReplacement: "FluidVoice"
        )

        XCTAssertEqual(triggers, ["fluid voice"])
    }

    func testDictionaryTrainingMergeDedupesAndMovesDuplicateTriggers() {
        let oldReplacement = SettingsStore.CustomDictionaryEntry(
            triggers: ["Fluid Voice.", "old trigger"],
            replacement: "Old"
        )
        let existingReplacement = SettingsStore.CustomDictionaryEntry(
            triggers: ["fluid boys"],
            replacement: "FluidVoice"
        )

        let entries = CustomDictionaryTrainingMerge.mergedEntries(
            current: [existingReplacement, oldReplacement],
            replacement: " fluidvoice ",
            triggers: ["Fluid Voice.", "fluid boys", "FluidVoice", ""]
        )

        let fluidVoiceEntry = entries.first { $0.replacement == "FluidVoice" }
        let oldEntry = entries.first { $0.replacement == "Old" }

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.replacement), ["FluidVoice", "Old"])
        XCTAssertEqual(Set(fluidVoiceEntry?.triggers ?? []), Set(["fluid voice", "fluid boys"]))
        XCTAssertEqual(oldEntry?.triggers, ["old trigger"])
    }

    func testDictionaryTrainingNewReplacementPrependsEntry() {
        let existingReplacement = SettingsStore.CustomDictionaryEntry(
            triggers: ["existing trigger"],
            replacement: "Existing"
        )

        let entries = CustomDictionaryTrainingMerge.mergedEntries(
            current: [existingReplacement],
            replacement: "FluidVoice",
            triggers: ["fluid voice"]
        )

        XCTAssertEqual(entries.map(\.replacement), ["FluidVoice", "Existing"])
        XCTAssertEqual(entries.first?.triggers, ["fluid voice"])
    }

    func testManualDictionaryEntryParsesCommaSeparatedVariants() {
        XCTAssertEqual(
            CustomDictionaryManualEntry.normalizedDraftTriggers("fluid voice, fluid boys, fluid voice"),
            ["fluid voice", "fluid boys"]
        )
    }

    func testManualDictionaryEntryPreservesLiteralCommas() {
        XCTAssertEqual(CustomDictionaryManualEntry.normalizedDraftTriggers(","), [","])
        XCTAssertEqual(CustomDictionaryManualEntry.normalizedDraftTriggers(",,"), [",,"])
    }

    func testAutomaticDictionaryCorrectionDetectsEditedWordInsideDictation() {
        let before = "Notes: I met Barad yesterday."
        let after = "Notes: I met Barath yesterday."
        let insertedRange = (before as NSString).range(of: "I met Barad yesterday.")

        let candidate = AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        )

        XCTAssertEqual(candidate?.heardText, "Barad")
        XCTAssertEqual(candidate?.correctedText, "Barath")
    }

    func testAutomaticDictionaryCorrectionDetectsInsertionOnlySpellingFix() {
        let before = "Barat joined the call"
        let after = "Barath joined the call"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)

        let candidate = AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        )

        XCTAssertEqual(candidate?.heardText, "Barat")
        XCTAssertEqual(candidate?.correctedText, "Barath")
    }

    func testAutomaticDictionaryCorrectionDetectsInsertionAtDictationEnd() {
        let before = "Barat"
        let after = "Barath"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)
        let change = AutomaticDictionaryCorrectionDetector.textChange(before: before, after: after)

        XCTAssertNotNil(change)
        if let change {
            XCTAssertTrue(AutomaticDictionaryCorrectionDetector.isWordContinuationAtInsertedRangeEnd(
                change,
                after: after,
                insertedRange: insertedRange
            ))
        }
        let candidate = AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange,
            allowsInsertionAtEnd: true
        )
        XCTAssertEqual(candidate?.heardText, "Barat")
        XCTAssertEqual(candidate?.correctedText, "Barath")
    }

    func testAutomaticDictionaryCorrectionRejectsNewWordAtDictationEnd() {
        let before = "FluidVoice works"
        let after = "FluidVoice works well"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)
        let change = AutomaticDictionaryCorrectionDetector.textChange(before: before, after: after)

        XCTAssertNotNil(change)
        if let change {
            XCTAssertFalse(AutomaticDictionaryCorrectionDetector.isWordContinuationAtInsertedRangeEnd(
                change,
                after: after,
                insertedRange: insertedRange
            ))
        }
    }

    func testPronunciationReplacementPreservesPunctuationAndSpacing() {
        let replacements = [
            FluidAudioProvider.PronunciationTextReplacement(wordRange: 1...1, label: "Barath"),
        ]

        XCTAssertEqual(
            FluidAudioProvider.applyingPronunciationReplacements(
                to: "Hi,  Barad! How are you?",
                wordTexts: ["Hi,", "Barad!", "How", "are", "you?"],
                replacements: replacements
            ),
            "Hi,  Barath! How are you?"
        )
    }

    func testPronunciationStoreRejectsInconsistentEnrollments() async {
        let store = PronunciationDictionaryStore()
        let enrollments = [
            PronunciationEnrollmentCapture(values: [1, 2], sourceFrameCount: 1, modelKey: "model-a"),
            PronunciationEnrollmentCapture(values: [1], sourceFrameCount: 1, modelKey: "model-b"),
        ]

        do {
            try await store.upsert(
                dictionaryEntryID: UUID(),
                label: "Barath",
                modelKey: "model-a",
                enrollments: enrollments
            )
            XCTFail("Expected inconsistent enrollment validation to fail")
        } catch {
            XCTAssertEqual(error as? PronunciationDictionaryStoreError, .inconsistentEnrollment)
        }
    }

    func testPronunciationStoreRetainsPriorEnrollmentsWhenRetrained() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PronunciationStore-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = PronunciationDictionaryStore(fileURL: fileURL)
        let entryID = UUID()

        let initialEnrollments = (0..<8).map { value in
            PronunciationEnrollmentCapture(
                values: [Float(value), Float(value)],
                sourceFrameCount: 1,
                modelKey: "model-a"
            )
        }
        let retrainedEnrollments = (8..<13).map { value in
            PronunciationEnrollmentCapture(
                values: [Float(value), Float(value)],
                sourceFrameCount: 1,
                modelKey: "model-a"
            )
        }

        try await store.upsert(
            dictionaryEntryID: entryID,
            label: "Barath",
            modelKey: "model-a",
            enrollments: initialEnrollments
        )
        try await store.upsert(
            dictionaryEntryID: entryID,
            label: "Barath",
            modelKey: "model-a",
            enrollments: retrainedEnrollments
        )

        let profiles = await store.profiles(modelKey: "model-a")
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.enrollments.compactMap(\.values.first), (3..<13).map { Float($0) })
    }

    func testPronunciationStoreRestoreRejectsMalformedProfiles() async {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PronunciationStore-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = PronunciationDictionaryStore(fileURL: fileURL)
        let malformedProfile = PronunciationDictionaryProfile(
            dictionaryEntryID: UUID(),
            label: "Barath",
            modelKey: "model-a",
            hiddenSize: 2,
            enrollments: [PronunciationEnrollmentCapture(values: [1], sourceFrameCount: 1, modelKey: "model-a")]
        )

        do {
            try await store.replaceAllProfiles([malformedProfile])
            XCTFail("Expected malformed profile validation to fail")
        } catch {
            XCTAssertEqual(error as? PronunciationDictionaryStoreError, .inconsistentEnrollment)
        }
    }

    func testPronunciationProfileEditPolicyDiscardsProfileWhenMeaningChanges() {
        XCTAssertTrue(
            PronunciationProfileEditPolicy.shouldDiscardProfile(
                previousReplacement: "Barath",
                updatedReplacement: "FluidVoice"
            )
        )
        XCTAssertFalse(
            PronunciationProfileEditPolicy.shouldDiscardProfile(
                previousReplacement: "Barath",
                updatedReplacement: "BARATH"
            )
        )
    }

    func testPronunciationMatchingRequiresSupportedAppleSiliconModel() {
        #if arch(arm64)
        XCTAssertTrue(SettingsStore.SpeechModel.parakeetTDT.supportsPronunciationMatching)
        XCTAssertTrue(SettingsStore.SpeechModel.parakeetTDTv2.supportsPronunciationMatching)
        #else
        XCTAssertFalse(SettingsStore.SpeechModel.parakeetTDT.supportsPronunciationMatching)
        XCTAssertFalse(SettingsStore.SpeechModel.parakeetTDTv2.supportsPronunciationMatching)
        #endif
        XCTAssertFalse(SettingsStore.SpeechModel.whisperLargeTurbo.supportsPronunciationMatching)
        XCTAssertFalse(SettingsStore.SpeechModel.cohereTranscribeSixBit.supportsPronunciationMatching)
    }

    func testDictionaryTrainingAudioCursorResetsAfterBufferGenerationChange() {
        var cursor = DictionaryTrainingAudioCursor(generation: 4)
        cursor.consume(1600)
        cursor.synchronize(generation: 4)
        XCTAssertEqual(cursor.sampleOffset, 1600)

        cursor.synchronize(generation: 5)
        XCTAssertEqual(cursor.sampleOffset, 0)
    }

    func testProgressiveDownloaderRetainsFileByMovingIt() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidVoiceDownloadSource-\(UUID().uuidString)")
        try Data([1, 2, 3]).write(to: source)
        let retained = try ProgressiveFileDownloader.retainDownloadedFile(at: source)
        defer { try? FileManager.default.removeItem(at: retained) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: retained), Data([1, 2, 3]))
    }

    func testAutomaticDictionaryCorrectionIgnoresTypingAfterDictation() {
        let before = "FluidVoice works"
        let after = "FluidVoice works well"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)

        XCTAssertNil(AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        ))
    }

    func testAutomaticDictionaryCorrectionAllowsContinuedCorrectionAtRangeEnd() {
        let change = AutomaticDictionaryTextChange(
            oldRange: NSRange(location: 5, length: 0),
            newRange: NSRange(location: 5, length: 1)
        )
        let insertedRange = NSRange(location: 0, length: 5)

        XCTAssertFalse(AutomaticDictionaryCorrectionDetector.isChangeInsideInsertedRange(
            change,
            insertedRange: insertedRange
        ))
        XCTAssertTrue(AutomaticDictionaryCorrectionDetector.isChangeInsideInsertedRange(
            change,
            insertedRange: insertedRange,
            allowsInsertionAtEnd: true
        ))
    }

    func testAutomaticDictionaryCorrectionKeepsWaitingWhileCaretTouchesCorrectedWord() {
        let correctedRange = NSRange(location: 8, length: 6)

        XCTAssertTrue(AutomaticDictionaryCorrectionDetector.selectionTouchesCandidate(
            NSRange(location: 14, length: 0),
            candidateRange: correctedRange
        ))
        XCTAssertFalse(AutomaticDictionaryCorrectionDetector.selectionTouchesCandidate(
            NSRange(location: 15, length: 0),
            candidateRange: correctedRange
        ))
    }

    func testAutomaticDictionaryCorrectionTreatsSpaceAfterWordAsCompletion() {
        let change = AutomaticDictionaryTextChange(
            oldRange: NSRange(location: 6, length: 0),
            newRange: NSRange(location: 6, length: 1)
        )
        let correctedRange = NSRange(location: 0, length: 6)

        XCTAssertFalse(AutomaticDictionaryCorrectionDetector.changeContinuesCandidate(
            change,
            after: "Barath ",
            candidateRange: correctedRange
        ))
        XCTAssertTrue(AutomaticDictionaryCorrectionDetector.changeContinuesCandidate(
            change,
            after: "Baratha",
            candidateRange: correctedRange
        ))
    }

    func testAutomaticDictionaryCorrectionIgnoresEditOutsideDictation() {
        let before = "Title: I met Barad"
        let after = "Heading: I met Barad"
        let insertedRange = (before as NSString).range(of: "I met Barad")

        XCTAssertNil(AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        ))
    }

    func testAutomaticDictionaryCorrectionIgnoresCaseOnlyEdit() {
        let before = "fluidvoice"
        let after = "FluidVoice"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)

        XCTAssertNil(AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        ))
    }

    func testAutomaticDictionaryCorrectionIgnoresPunctuationAndSpacingOnlyEdit() {
        let before = "Use Fluid-Voice today"
        let after = "Use Fluid Voice today"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)

        XCTAssertNil(AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        ))
    }

    func testAutomaticDictionaryCorrectionIgnoresSingleCharacterCorrection() {
        let before = "Choose k today"
        let after = "Choose okay today"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)

        XCTAssertNil(AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        ))
    }

    func testAutomaticDictionarySuggestionRequiresRepeatedCorrection() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.globalCooldown = 0
        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        let candidate = AutomaticDictionaryCorrectionCandidate(heardText: "Barad", correctedText: "Barath")
        let now = Date(timeIntervalSince1970: 1000)

        XCTAssertFalse(policy.shouldShow(candidate, now: now))
        XCTAssertTrue(policy.shouldShow(candidate, now: now.addingTimeInterval(60)))
    }

    func testAutomaticDictionarySuggestionPersistsDismissalCooldown() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.requiredOccurrences = 1
        configuration.globalCooldown = 0
        configuration.dismissedPairCooldown = 100
        let candidate = AutomaticDictionaryCorrectionCandidate(heardText: "Barad", correctedText: "Barath")
        let now = Date(timeIntervalSince1970: 2000)

        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        XCTAssertTrue(policy.shouldShow(candidate, now: now))
        policy.markShown(candidate, now: now)
        policy.record(.dismissed, for: candidate, now: now)

        let restoredPolicy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        XCTAssertFalse(restoredPolicy.shouldShow(candidate, now: now.addingTimeInterval(50)))
        XCTAssertTrue(restoredPolicy.shouldShow(candidate, now: now.addingTimeInterval(101)))
    }

    func testAutomaticDictionarySuggestionAppliesGlobalCooldown() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.requiredOccurrences = 1
        configuration.globalCooldown = 600
        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        let first = AutomaticDictionaryCorrectionCandidate(heardText: "Barad", correctedText: "Barath")
        let second = AutomaticDictionaryCorrectionCandidate(heardText: "Floral Voice", correctedText: "FluidVoice")
        let now = Date(timeIntervalSince1970: 3000)

        XCTAssertTrue(policy.shouldShow(first, now: now))
        policy.markShown(first, now: now)
        XCTAssertFalse(policy.shouldShow(second, now: now.addingTimeInterval(60)))
        XCTAssertTrue(policy.shouldShow(second, now: now.addingTimeInterval(601)))
    }

    func testAutomaticDictionarySuggestionStopsAfterSessionIgnoreLimit() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.requiredOccurrences = 1
        configuration.globalCooldown = 0
        configuration.dismissedPairCooldown = 0
        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        let now = Date(timeIntervalSince1970: 4000)

        for index in 0..<configuration.maximumSessionIgnores {
            let candidate = AutomaticDictionaryCorrectionCandidate(
                heardText: "heard \(index)",
                correctedText: "corrected \(index)"
            )
            XCTAssertTrue(policy.shouldShow(candidate, now: now.addingTimeInterval(Double(index))))
            policy.markShown(candidate, now: now.addingTimeInterval(Double(index)))
            policy.record(.timedOut, for: candidate, now: now.addingTimeInterval(Double(index)))
        }

        let next = AutomaticDictionaryCorrectionCandidate(heardText: "another error", correctedText: "another word")
        XCTAssertFalse(policy.shouldShow(next, now: now.addingTimeInterval(10)))
    }

    func testAutomaticDictionarySuggestionNeverReturnsAfterAcceptance() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.requiredOccurrences = 1
        configuration.globalCooldown = 0
        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        let candidate = AutomaticDictionaryCorrectionCandidate(heardText: "Barad", correctedText: "Barath")
        let now = Date(timeIntervalSince1970: 5000)

        XCTAssertTrue(policy.shouldShow(candidate, now: now))
        policy.record(.accepted, for: candidate, now: now)
        XCTAssertFalse(policy.shouldShow(candidate, now: now.addingTimeInterval(10_000)))
    }

    func testAutomaticDictionarySuggestionStopsAfterPairDismissalLimit() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.requiredOccurrences = 1
        configuration.globalCooldown = 0
        configuration.dismissedPairCooldown = 0
        configuration.maximumSessionIgnores = 10
        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        let candidate = AutomaticDictionaryCorrectionCandidate(heardText: "Barad", correctedText: "Barath")
        let now = Date(timeIntervalSince1970: 6000)

        for index in 0..<configuration.maximumPairDismissals {
            let date = now.addingTimeInterval(Double(index))
            XCTAssertTrue(policy.shouldShow(candidate, now: date))
            policy.record(.dismissed, for: candidate, now: date)
        }
        XCTAssertFalse(policy.shouldShow(candidate, now: now.addingTimeInterval(10)))
    }

    private func makeSuggestionPolicyDefaults() throws -> UserDefaults {
        let suiteName = "AutomaticDictionarySuggestionPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testDictionaryTransferImport_rejectsInvalidReplacementTriggerType() {
        let json = """
        {
          "replacements": [
            {
              "from": 42,
              "to": "FluidVoice"
            }
          ]
        }
        """

        XCTAssertThrowsError(try DictionaryTransferService.shared.decode(Data(json.utf8)))
    }

    func testDictionaryTransferImport_acceptsParakeetVocabularyTermsFile() throws {
        let json = """
        {
          "alpha": 2.8,
          "terms": [
            {
              "text": "FluidVoice",
              "aliases": ["fluid voice"],
              "weight": 13.0
            },
            {
              "text": "GEMBA-E"
            }
          ]
        }
        """

        let document = try DictionaryTransferService.shared.decode(Data(json.utf8))
        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .replace,
            currentReplacements: [],
            currentCustomWords: []
        )

        XCTAssertEqual(state.replacements.count, 0)
        XCTAssertEqual(state.customWords.map(\.text), ["FluidVoice", "GEMBA-E"])
        XCTAssertEqual(state.customWords.map(\.weight), [13.0, 10.0])
        XCTAssertEqual(state.customWords.map(\.aliases), [[], []])
    }

    func testDictionaryTransferImport_acceptsLocalAPICustomWordsResponse() throws {
        let json = """
        {
          "count": 2,
          "items": [
            {
              "text": "FluidVoice",
              "weight": 10.0,
              "aliases": ["fluid voice"]
            },
            {
              "text": "Barath"
            }
          ]
        }
        """

        let document = try DictionaryTransferService.shared.decode(Data(json.utf8))
        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .replace,
            currentReplacements: [],
            currentCustomWords: []
        )

        XCTAssertEqual(state.replacements.count, 0)
        XCTAssertEqual(state.customWords.map(\.text), ["FluidVoice", "Barath"])
        XCTAssertEqual(state.customWords.map(\.weight), [10.0, 10.0])
        XCTAssertEqual(state.customWords.map(\.aliases), [[], []])
    }

    func testDictationEndToEnd_whisperTiny_transcribesFixture() async throws {
        // Arrange
        let modelDirectory = Self.modelDirectoryForRun()
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let provider = WhisperProvider(modelDirectory: modelDirectory, modelOverride: .whisperTiny)

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

    func testWhisperProvider_legacyBinCacheDoesNotCountAsDownloadedOrDeletedByReadinessCheck() throws {
        let modelDirectory = Self.modelDirectoryForRun()
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let legacyURL = modelDirectory.appendingPathComponent("ggml-tiny.bin")
        try Data([0x01, 0x02, 0x03]).write(to: legacyURL)

        let provider = WhisperProvider(modelDirectory: modelDirectory, modelOverride: .whisperTiny)

        XCTAssertFalse(provider.modelsExistOnDisk())
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testWhisperProvider_readinessCheckDoesNotCreateMissingDirectory() {
        let modelDirectory = Self.modelDirectoryForRun()
        let provider = WhisperProvider(modelDirectory: modelDirectory, modelOverride: .whisperTiny)

        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.path))
        XCTAssertFalse(provider.modelsExistOnDisk())
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.path))
    }

    func testWhisperProvider_ggufCacheReadinessDoesNotDeleteLegacyUntilExplicitClear() async throws {
        let modelDirectory = Self.modelDirectoryForRun()
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let model = SettingsStore.SpeechModel.whisperTiny
        let ggufFilename = try XCTUnwrap(model.whisperModelFile)
        let legacyFilename = try XCTUnwrap(model.legacyWhisperModelFile)
        let ggufURL = modelDirectory.appendingPathComponent(ggufFilename)
        let legacyURL = modelDirectory.appendingPathComponent(legacyFilename)
        try Self.createSparseFile(at: ggufURL, size: model.expectedDownloadBytes)
        try Data([0x01, 0x02, 0x03]).write(to: legacyURL)

        let provider = WhisperProvider(modelDirectory: modelDirectory, modelOverride: model)

        XCTAssertTrue(provider.modelsExistOnDisk())
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        try await provider.clearCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath: ggufURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
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

    func testAppleIntelligenceIsNotAvailableAsABuiltInProvider() {
        XCTAssertFalse(ModelRepository.builtInProviderIDs.contains("apple-intelligence"))
        XCTAssertFalse(ModelRepository.shared.builtInProvidersList().contains { $0.id.contains("apple-intelligence") })
    }

    func testRetiredAppleIntelligenceStateIsPurgedWithoutSelectingAFallbackProvider() {
        self.withRestoredDefaults(
            keys: [
                self.selectedProviderIDKey,
                self.selectedAIModelKey,
                self.availableModelsByProviderKey,
                self.selectedModelByProviderKey,
                self.verifiedProviderFingerprintsKey,
                self.commandModeSelectedProviderIDKey,
                self.commandModeSelectedModelKey,
                self.rewriteModeSelectedProviderIDKey,
                self.rewriteModeSelectedModelKey,
                self.dictationPromptConfigurationsKey,
            ]
        ) {
            let settings = SettingsStore.shared
            let shortcut = HotkeyShortcut(keyCode: 1, modifierFlags: [.command])
            settings.selectedProviderID = "apple-intelligence"
            settings.selectedModel = "System Model"
            settings.availableModelsByProvider = ["apple-intelligence": ["System Model"]]
            settings.selectedModelByProvider = ["apple-intelligence": "System Model"]
            settings.verifiedProviderFingerprints = ["apple-intelligence": "apple-intelligence"]
            settings.commandModeSelectedProviderID = "apple-intelligence-disabled"
            settings.commandModeSelectedModel = "System Model"
            settings.rewriteModeSelectedProviderID = "apple-intelligence"
            settings.rewriteModeSelectedModel = "System Model"
            settings.dictationPromptConfigurations = [
                "__default__": SettingsStore.DictationPromptConfiguration(
                    shortcut: shortcut,
                    providerID: "apple-intelligence",
                    modelName: "System Model"
                ),
            ]

            settings.purgeRetiredAppleIntelligenceState()
            settings.purgeRetiredAppleIntelligenceState()

            XCTAssertEqual(settings.selectedProviderID, "")
            XCTAssertNil(settings.selectedModel)
            XCTAssertEqual(settings.commandModeSelectedProviderID, "")
            XCTAssertNil(settings.commandModeSelectedModel)
            XCTAssertEqual(settings.rewriteModeSelectedProviderID, "")
            XCTAssertNil(settings.rewriteModeSelectedModel)
            XCTAssertNil(settings.availableModelsByProvider["apple-intelligence"])
            XCTAssertNil(settings.selectedModelByProvider["apple-intelligence"])
            XCTAssertNil(settings.verifiedProviderFingerprints["apple-intelligence"])
            XCTAssertEqual(settings.dictationPromptConfigurations["__default__"]?.shortcut, shortcut)
            XCTAssertEqual(settings.dictationPromptConfigurations["__default__"]?.providerID, "")
            XCTAssertEqual(settings.dictationPromptConfigurations["__default__"]?.modelName, "")
            XCTAssertFalse(DictationAIPostProcessingGate.isProviderConfigured())
        }
    }

    func testDictationProviderRouteUsesPromptConfigurationWithoutMutatingGlobalSelection() {
        self.withRestoredDefaults(
            keys: [
                self.selectedProviderIDKey,
                self.selectedModelByProviderKey,
                self.verifiedProviderFingerprintsKey,
                self.dictationPromptConfigurationsKey,
                self.dictationPromptOffKey,
                self.selectedDictationPromptIDKey,
            ]
        ) {
            let settings = SettingsStore.shared
            settings.selectedProviderID = "openai"
            settings.selectedModelByProvider = ["openai": "gpt-4.1", "ollama": "test-local-model"]
            settings.verifiedProviderFingerprints = [
                "ollama": DictationAIPostProcessingGate.providerFingerprint(
                    baseURL: ModelRepository.shared.defaultBaseURL(for: "ollama"),
                    apiKey: ""
                ) ?? "",
            ]
            settings.setDictationPromptSelection(.default, for: .primary)
            settings.setDictationPromptConfiguration(
                SettingsStore.DictationPromptConfiguration(
                    providerID: "ollama",
                    modelName: "test-local-model"
                ),
                for: .default
            )

            let route = DictationProviderRoute.resolve(settings: settings, dictationSlot: .primary)

            XCTAssertEqual(route.providerID, "ollama")
            XCTAssertEqual(route.providerKey, "ollama")
            XCTAssertEqual(route.model, "test-local-model")
            XCTAssertEqual(settings.selectedProviderID, "openai")
            XCTAssertEqual(settings.selectedModelByProvider["openai"], "gpt-4.1")

            XCTAssertTrue(DictationAIPostProcessingGate.isConfigured(for: .primary))
            XCTAssertEqual(settings.selectedProviderID, "openai")
        }
    }

    func testDictationProviderRouteReturnsEmptyRouteForUnverifiedPrivateAI() {
        self.withPromptAndProviderSettingsRestored {
            let settings = SettingsStore.shared
            settings.verifiedProviderFingerprints = [:]

            let route = DictationProviderRoute.privateAIRoute(settings: settings)

            XCTAssertEqual(
                route,
                DictationProviderRoute(providerID: "", providerKey: "", baseURL: "", model: "", apiKey: "")
            )
            XCTAssertFalse(route.usesPrivateAI)
        }
    }

    func testDictationProviderRouteUsesAppBoundPromptConfiguration() {
        self.withRestoredDefaults(
            keys: [
                self.dictationPromptProfilesKey,
                self.appPromptBindingsKey,
                self.dictationPromptRoutingScopeKey,
                self.selectedProviderIDKey,
                self.selectedModelByProviderKey,
                self.verifiedProviderFingerprintsKey,
                self.dictationPromptConfigurationsKey,
                self.dictationPromptOffKey,
                self.selectedDictationPromptIDKey,
            ]
        ) {
            let settings = SettingsStore.shared
            let appBundleID = "com.example.editor"
            let profile = SettingsStore.DictationPromptProfile(
                name: "Editor",
                prompt: "Clean up text for this editor.",
                mode: .dictate
            )
            settings.dictationPromptProfiles = [profile]
            settings.appPromptBindings = [
                SettingsStore.AppPromptBinding(
                    mode: .dictate,
                    appBundleID: appBundleID,
                    appName: "Editor",
                    promptID: profile.id
                ),
            ]
            settings.dictationPromptRoutingScope = .allApps
            settings.selectedProviderID = "openai"
            settings.selectedModelByProvider = ["openai": "gpt-4.1", "ollama": "editor-model"]
            settings.verifiedProviderFingerprints = [
                "ollama": DictationAIPostProcessingGate.providerFingerprint(
                    baseURL: ModelRepository.shared.defaultBaseURL(for: "ollama"),
                    apiKey: ""
                ) ?? "",
            ]
            settings.setDictationPromptSelection(.default, for: .primary)
            settings.setDictationPromptConfiguration(
                SettingsStore.DictationPromptConfiguration(
                    providerID: "openai",
                    modelName: "gpt-4.1"
                ),
                for: .default
            )
            settings.setDictationPromptConfiguration(
                SettingsStore.DictationPromptConfiguration(
                    providerID: "ollama",
                    modelName: "editor-model"
                ),
                for: .profile(profile.id)
            )

            let route = DictationProviderRoute.resolve(
                settings: settings,
                dictationSlot: .primary,
                appBundleID: appBundleID
            )

            XCTAssertEqual(route.providerID, "ollama")
            XCTAssertEqual(route.model, "editor-model")
            XCTAssertEqual(settings.selectedProviderID, "openai")
            XCTAssertTrue(DictationAIPostProcessingGate.isConfigured(for: .primary, appBundleID: appBundleID))
        }
    }

    func testPostProcessingRouteUsesGlobalProviderWithoutAppContext() {
        self.withRestoredDefaults(
            keys: [
                self.dictationPromptRoutingScopeKey,
                self.selectedProviderIDKey,
                self.selectedModelByProviderKey,
                self.dictationPromptOffKey,
                self.selectedDictationPromptIDKey,
            ]
        ) {
            let settings = SettingsStore.shared
            settings.dictationPromptRoutingScope = .selectedAppsOnly
            settings.selectedProviderID = "openai"
            settings.selectedModelByProvider = ["openai": "gpt-4.1"]
            settings.setDictationPromptSelection(.default, for: .primary)

            let route = DictationProviderRoute.resolveForPostProcessing(
                settings: settings,
                dictationSlot: .primary
            )

            XCTAssertEqual(route.providerID, "openai")
            XCTAssertEqual(route.model, "gpt-4.1")
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

    func testPrivateAIProviderBoost_defaultsOnAndPersistsToggle() {
        self.withRestoredDefaults(keys: [self.privateAIBoostEnabledKey]) {
            let settings = SettingsStore.shared

            XCTAssertTrue(settings.privateAIBoostEnabled)

            settings.privateAIBoostEnabled = false
            XCTAssertFalse(settings.privateAIBoostEnabled)

            settings.privateAIBoostEnabled = true
            XCTAssertTrue(settings.privateAIBoostEnabled)
        }
    }

    func testPrivateAIProviderContextTokenLimit_defaultsPersistsAndClamps() {
        self.withRestoredDefaults(keys: [self.privateAIContextTokenLimitKey, self.privateAIContextDefaultMigratedTo4KKey]) {
            let settings = SettingsStore.shared
            UserDefaults.standard.removeObject(forKey: self.privateAIContextTokenLimitKey)
            UserDefaults.standard.removeObject(forKey: self.privateAIContextDefaultMigratedTo4KKey)

            XCTAssertEqual(settings.privateAIContextTokenLimit, 4096)

            settings.privateAIContextTokenLimit = 4096
            XCTAssertEqual(settings.privateAIContextTokenLimit, 4096)

            settings.privateAIContextTokenLimit = 1024
            XCTAssertEqual(settings.privateAIContextTokenLimit, 2048)

            settings.privateAIContextTokenLimit = 16_384
            XCTAssertEqual(settings.privateAIContextTokenLimit, 8192)
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

    func testMLXUpgradeOfferOnlyTargetsLegacyAppleSiliconInstalls() {
        let eligible = PrivateAIMLXUpgradeCoordinator.shouldOffer(
            hasPrivateProvider: true,
            isAppleSilicon: true,
            appVersion: "1.6.3",
            backendPreferenceWasSet: false,
            hasLegacyLlamaModel: true,
            hasMLXModel: false,
            offerWasHandled: false
        )
        XCTAssertTrue(eligible)

        XCTAssertFalse(PrivateAIMLXUpgradeCoordinator.shouldOffer(
            hasPrivateProvider: true,
            isAppleSilicon: false,
            appVersion: "1.6.3",
            backendPreferenceWasSet: false,
            hasLegacyLlamaModel: true,
            hasMLXModel: false,
            offerWasHandled: false
        ))
        XCTAssertFalse(PrivateAIMLXUpgradeCoordinator.shouldOffer(
            hasPrivateProvider: true,
            isAppleSilicon: true,
            appVersion: "1.6.3",
            backendPreferenceWasSet: true,
            hasLegacyLlamaModel: true,
            hasMLXModel: false,
            offerWasHandled: false
        ))
        XCTAssertFalse(PrivateAIMLXUpgradeCoordinator.shouldOffer(
            hasPrivateProvider: true,
            isAppleSilicon: true,
            appVersion: "1.6.3",
            backendPreferenceWasSet: false,
            hasLegacyLlamaModel: false,
            hasMLXModel: false,
            offerWasHandled: false
        ))
        XCTAssertFalse(PrivateAIMLXUpgradeCoordinator.shouldOffer(
            hasPrivateProvider: true,
            isAppleSilicon: true,
            appVersion: "1.6.3",
            backendPreferenceWasSet: false,
            hasLegacyLlamaModel: true,
            hasMLXModel: true,
            offerWasHandled: false
        ))
        XCTAssertFalse(PrivateAIMLXUpgradeCoordinator.shouldOffer(
            hasPrivateProvider: true,
            isAppleSilicon: true,
            appVersion: "1.6.3",
            backendPreferenceWasSet: false,
            hasLegacyLlamaModel: true,
            hasMLXModel: false,
            offerWasHandled: true
        ))
        for version in ["1.6.2", "1.6.4", "2.0.0", ""] {
            XCTAssertFalse(PrivateAIMLXUpgradeCoordinator.shouldOffer(
                hasPrivateProvider: true,
                isAppleSilicon: true,
                appVersion: version,
                backendPreferenceWasSet: false,
                hasLegacyLlamaModel: true,
                hasMLXModel: false,
                offerWasHandled: false
            ))
        }
    }

    func testMLXUpgradePreparedOfferIsRevalidatedBeforeResuming() {
        XCTAssertTrue(PrivateAIMLXUpgradeCoordinator.shouldResumePreparedOffer(
            hasPrivateProvider: true,
            isAppleSilicon: true,
            appVersion: "1.6.3",
            backendPreference: .llama,
            hasLegacyLlamaModel: true,
            hasMLXModel: false
        ))

        for state in [
            (true, true, "1.6.3", SettingsStore.PrivateAIBackendPreference.mlx, true, false),
            (true, true, "1.6.3", SettingsStore.PrivateAIBackendPreference.llama, false, false),
            (true, true, "1.6.3", SettingsStore.PrivateAIBackendPreference.llama, true, true),
            (true, true, "1.6.4", SettingsStore.PrivateAIBackendPreference.llama, true, false),
            (true, false, "1.6.3", SettingsStore.PrivateAIBackendPreference.llama, true, false),
            (false, true, "1.6.3", SettingsStore.PrivateAIBackendPreference.llama, true, false),
            (true, true, "1.6.3", nil, true, false),
        ] {
            XCTAssertFalse(PrivateAIMLXUpgradeCoordinator.shouldResumePreparedOffer(
                hasPrivateProvider: state.0,
                isAppleSilicon: state.1,
                appVersion: state.2,
                backendPreference: state.3,
                hasLegacyLlamaModel: state.4,
                hasMLXModel: state.5
            ))
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
        let bom: [UInt8] = [0xef, 0xbb, 0xbf]

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
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data([0xcf, 0xfa, 0xed, 0xfe, 0x07, 0x00])))
        // Leading-NUL binary (e.g. coremldata.bin / weight.bin style payloads).
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data([0x00, 0x00, 0x01, 0x3c, 0x68])))
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
        try Data([0x0a, 0x09, 0x05, 0x00]).write(to: tokenizerURL)

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
        try Data([0x0a, 0x09, 0x05, 0x00]).write(to: tokenizerURL)
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

    private static func createSparseFile(at url: URL, size: Int64) throws {
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
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
                self.verifiedProviderFingerprintsKey,
                self.privateAISelectedModelIDKey,
            ],
            run: run
        )
    }
}

// Shared-primitive coverage for the Write Mode clipboard fallback (issue #259). Kept in an
// extension so these tests do not add to the main `DictationE2ETests` class body, which is
// at the `type_body_length` limit.
extension DictationE2ETests {
    // MARK: - LayoutAwareKeyCode (shared Cmd+C / Cmd+V key-code lookup, issue #259)

    func testLayoutAwareKeyCode_resolvesLatinCharactersOnCurrentLayout() {
        // "c" and "v" exist on every Latin keyboard layout, so the lookup must resolve a real
        // key code rather than returning the fallback. We pass an out-of-band sentinel as the
        // fallback so a successful lookup is provably distinct from the fallback path.
        let sentinel = CGKeyCode(0xFFFF)
        let cKey = LayoutAwareKeyCode.virtualKeyCode(for: "c", qwertyFallback: sentinel)
        let vKey = LayoutAwareKeyCode.virtualKeyCode(for: "v", qwertyFallback: sentinel)

        XCTAssertNotEqual(cKey, sentinel, "Expected to resolve a real key code for \"c\"")
        XCTAssertNotEqual(vKey, sentinel, "Expected to resolve a real key code for \"v\"")
        XCTAssertLessThan(cKey, 128, "Virtual key codes are in 0..<128")
        XCTAssertLessThan(vKey, 128, "Virtual key codes are in 0..<128")
    }

    func testLayoutAwareKeyCode_fallsBackForUnmappableCharacter() {
        // No physical key produces this emoji, so the scan finds nothing and must return the
        // supplied fallback — exercising the layout-unavailable / not-found path deterministically.
        let sentinel = CGKeyCode(0xABCD)
        let result = LayoutAwareKeyCode.virtualKeyCode(for: "🍎", qwertyFallback: sentinel)

        XCTAssertEqual(result, sentinel)
    }

    func testLayoutAwareKeyCode_isDeterministicAcrossCalls() {
        // Re-evaluated on every call (so a runtime layout switch is picked up) but stable for a
        // fixed layout: two back-to-back lookups must agree.
        let first = LayoutAwareKeyCode.virtualKeyCode(for: "v", qwertyFallback: CGKeyCode(kVK_ANSI_V))
        let second = LayoutAwareKeyCode.virtualKeyCode(for: "v", qwertyFallback: CGKeyCode(kVK_ANSI_V))

        XCTAssertEqual(first, second)
    }

    // MARK: - PasteboardSession (shared pasteboard mutual-exclusion guard, issue #259)

    func testPasteboardSession_isFreeInitiallyAndReleases() {
        // Acquiring a free session must succeed immediately; after releasing, the next
        // acquire must succeed again (the signal is balanced, value returns to 1).
        XCTAssertTrue(PasteboardSession.tryBeginExclusive(timeoutMicros: 50_000))
        PasteboardSession.endExclusive()
        XCTAssertTrue(PasteboardSession.tryBeginExclusive(timeoutMicros: 50_000))
        PasteboardSession.endExclusive()
    }

    func testPasteboardSession_blocksWhileHeldThenSucceedsAfterRelease() {
        // Model the real race: a paste path holds the session on a background queue while the
        // (main-thread) selection-read path tries to acquire it. The bounded attempt must FAIL
        // while held, then SUCCEED once the holder releases — proving mutual exclusion and the
        // bounded-wait fallback both work.
        let acquiredByHolder = DispatchSemaphore(value: 0)
        let holderMayRelease = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            PasteboardSession.beginExclusive()
            acquiredByHolder.signal()
            holderMayRelease.wait()
            PasteboardSession.endExclusive()
        }

        // Wait until the background holder owns the session.
        XCTAssertEqual(acquiredByHolder.wait(timeout: .now() + 2.0), .success)

        // While held, a short bounded attempt must time out (not acquire, not hang).
        XCTAssertFalse(
            PasteboardSession.tryBeginExclusive(timeoutMicros: 100_000),
            "Session is held by the background holder; bounded attempt must time out"
        )

        // Release the holder; the session becomes free.
        holderMayRelease.signal()

        // Now an acquire must succeed (poll briefly to absorb the cross-thread handoff).
        var acquired = false
        for _ in 0..<20 where !acquired {
            acquired = PasteboardSession.tryBeginExclusive(timeoutMicros: 100_000)
        }
        XCTAssertTrue(acquired, "Session must be acquirable after the holder releases")
        PasteboardSession.endExclusive()
    }
}

extension DictationE2ETests {
    func testSpokenFormattingActionsUseSharedPrefix() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            let settings = SettingsStore.shared
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)
            settings.punctuationDictionaryPrefix = "literal"
            settings.spokenFormattingActionRules = SettingsStore.defaultSpokenFormattingActionRules

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("First literal next line second"),
                "First\nsecond"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("First literal next paragraph second"),
                "First\n\nsecond"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("one literal tab two"),
                "one\ttwo"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("one   literal space   two"),
                "one two"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("First next line second"),
                "First next line second"
            )
        }
    }

    func testSpokenFormattingActionsRemoveAdjacentGeneratedPeriodsOnly() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            let settings = SettingsStore.shared
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)
            settings.punctuationDictionaryPrefix = "literal"
            settings.spokenFormattingActionRules = SettingsStore.defaultSpokenFormattingActionRules

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("First. literal new line. Second"),
                "First\nSecond"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("First. literal new paragraph. Second"),
                "First\n\nSecond"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("one. literal tab. two"),
                "one\ttwo"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("one. literal space. two"),
                "one two"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("First literal period literal new line Second"),
                "First.\nSecond"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("First literal new line, Second"),
                "First\nSecond"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("First literal new paragraph, Second"),
                "First\n\nSecond"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("First literal new line literal comma Second"),
                "First\n, Second"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("one literal tab, two"),
                "one\t, two"
            )
        }
    }

    func testSpokenFormattingActionsCanBeCustomizedAndUnset() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            let settings = SettingsStore.shared
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)
            settings.spokenFormattingActionRules = [
                SettingsStore.SpokenFormattingActionRule(
                    action: .newLine,
                    aliases: ["drop down"]
                ),
                SettingsStore.SpokenFormattingActionRule(
                    action: .tab,
                    aliases: [],
                    isEnabled: true
                ),
                SettingsStore.SpokenFormattingActionRule(
                    action: .space,
                    aliases: ["little gap"],
                    isEnabled: false
                ),
            ]

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("First literal drop down second"),
                "First\nsecond"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal tab"),
                "literal tab"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal little gap"),
                "literal little gap"
            )
        }
    }

    func testSpokenFormattingActionAliasesRejectPunctuationAndActionConflicts() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            let settings = SettingsStore.shared
            settings.spokenFormattingActionRules = [
                SettingsStore.SpokenFormattingActionRule(
                    action: .newLine,
                    aliases: ["comma", "shared action", "drop down"]
                ),
                SettingsStore.SpokenFormattingActionRule(
                    action: .newParagraph,
                    aliases: ["shared action", "paragraph break"]
                ),
            ]

            let rules = settings.spokenFormattingActionRules
            XCTAssertEqual(rules.first { $0.action == .newLine }?.aliases, ["shared action", "drop down"])
            XCTAssertEqual(rules.first { $0.action == .newParagraph }?.aliases, ["paragraph break"])

            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)
            XCTAssertEqual(ASRService.applySpokenPunctuationFormatting("literal comma"), ",")
            XCTAssertEqual(ASRService.applySpokenPunctuationFormatting("literal shared action"), "\n")
        }
    }

    func testSpokenFormattingActionRulesRoundTripAndLegacyBackupsPreserveCurrentRules() async throws {
        let defaults = UserDefaults.standard
        let originalValue = defaults.object(forKey: self.spokenFormattingActionRulesKey)
        defer {
            if let originalValue {
                defaults.set(originalValue, forKey: self.spokenFormattingActionRulesKey)
            } else {
                defaults.removeObject(forKey: self.spokenFormattingActionRulesKey)
            }
        }

        let settings = SettingsStore.shared
        let backedUpRules = [
            SettingsStore.SpokenFormattingActionRule(
                action: .newLine,
                aliases: ["line break"]
            ),
            SettingsStore.SpokenFormattingActionRule(
                action: .tab,
                aliases: ["indent"],
                isEnabled: false
            ),
        ]
        settings.spokenFormattingActionRules = backedUpRules

        let document = await BackupService.shared.makeBackupDocument()
        let encoded = try BackupService.shared.encode(document)
        let decoded = try BackupService.shared.decode(encoded)
        XCTAssertEqual(decoded.settings.spokenFormattingActionRules, settings.spokenFormattingActionRules)

        settings.spokenFormattingActionRules = SettingsStore.defaultSpokenFormattingActionRules
        settings.restore(from: decoded.settings)
        XCTAssertEqual(settings.spokenFormattingActionRules, decoded.settings.spokenFormattingActionRules)

        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var encodedSettings = try XCTUnwrap(root["settings"] as? [String: Any])
        encodedSettings.removeValue(forKey: "spokenFormattingActionRules")
        root["settings"] = encodedSettings
        let legacyBackup = try BackupService.shared.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertNil(legacyBackup.settings.spokenFormattingActionRules)

        let rulesBeforeLegacyRestore = [
            SettingsStore.SpokenFormattingActionRule(
                action: .newParagraph,
                aliases: ["keep this paragraph"]
            ),
        ]
        settings.spokenFormattingActionRules = rulesBeforeLegacyRestore
        let normalizedRulesBeforeLegacyRestore = settings.spokenFormattingActionRules
        settings.restore(from: legacyBackup.settings)
        XCTAssertEqual(settings.spokenFormattingActionRules, normalizedRulesBeforeLegacyRestore)
    }
}

@MainActor
final class OverlayFailureStateTests: XCTestCase {
    func testCustomNonRetryableMessage() {
        let state = NotchContentState.shared
        defer {
            state.showAIProcessingFailure()
            state.clearAIProcessingFailure()
        }

        state.showAIProcessingFailure(
            message: "Edit Mode cannot be used with Fluid-1",
            canRetry: false
        )

        XCTAssertTrue(state.isAIProcessingFailureVisible)
        XCTAssertEqual(state.aiProcessingFailureMessage, "Edit Mode cannot be used with Fluid-1")
        XCTAssertFalse(state.canRetryAIProcessingFailure)

        state.showAIProcessingFailure()

        XCTAssertEqual(state.aiProcessingFailureMessage, "AI Enhancement failed")
        XCTAssertTrue(state.canRetryAIProcessingFailure)
    }
}

@MainActor
final class SimpleUpdaterTests: XCTestCase {
    func testUpdateOperationGateAllowsOnlyOneActiveInstall() {
        var gate = UpdateOperationGate()

        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.isActive)
        XCTAssertFalse(gate.begin())

        gate.finish()

        XCTAssertFalse(gate.isActive)
        XCTAssertTrue(gate.begin())
    }
}

// MARK: - Write Mode clipboard fallback: coherent observations and the moving restore target

/// Coverage for the defensive restore's settle window (issue #259).
///
/// These drive `TextSelectionService.LateWriteArbiter` directly with constructed observations
/// rather than racing a background writer against the live settle loop. That is deliberate: the
/// arbiter returns an `Outcome` describing which branch it took, so each test asserts both the
/// resulting clipboard state AND that the branch it targets actually executed. A timing-based test
/// can only prove that a queued writer eventually ran, which is how an earlier revision of this fix
/// shipped tests that passed against a broken implementation.
extension DictationE2ETests {
    /// A named pasteboard so these tests never touch the user's real clipboard.
    private func makeClipboardFallbackPasteboard(_ suffix: String) -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("com.FluidApp.app.tests.clipboard-fallback.\(suffix)"))
    }

    private func writeText(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Writes a single item carrying a second representation alongside its text, so a test can tell
    /// a full-snapshot restore apart from one that only round-tripped the plain text.
    private func writeRichItem(text: String, html: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data(text.utf8), forType: .string)
        item.setData(Data(html.utf8), forType: .html)
        pasteboard.writeObjects([item])
    }

    /// Writes one item per element, which is what makes a pasteboard multi-item.
    private func writeItems(texts: [String?], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = texts.map { text -> NSPasteboardItem in
            let item = NSPasteboardItem()
            if let text {
                item.setData(Data(text.utf8), forType: .string)
            } else {
                item.setData(Data([0x01, 0x02]), forType: .png)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private func htmlString(on pasteboard: NSPasteboard) -> String? {
        guard let data = pasteboard.data(forType: .html) else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    private func makeLateWriteArbiter(
        restoreTarget: PasteboardSnapshot,
        baselineChangeCount: Int,
        syntheticCopyText: String?,
        didObserveCopyWrite: Bool,
        restoresRemaining: Int = 3,
        performRestore: ((PasteboardSnapshot, NSPasteboard) -> PasteboardSnapshot.RestoreResult)? = nil
    ) -> TextSelectionService.LateWriteArbiter {
        TextSelectionService.LateWriteArbiter(
            restoreTarget: restoreTarget,
            baselineChangeCount: baselineChangeCount,
            restoresRemaining: restoresRemaining,
            syntheticCopyText: syntheticCopyText,
            didObserveCopyWrite: didObserveCopyWrite,
            performRestore: performRestore
        )
    }

    /// A restore that lands an external write immediately afterwards, reproducing the interleave
    /// where a writer publishes between our restore and any hypothetical post-restore `changeCount`
    /// re-read. The write is deliberately NOT reflected in the restore's own returned generation.
    ///
    /// One-shot: the interfering write happens after the FIRST restore only. The seam is threaded
    /// through both the initial restore and the arbiter's, and a write on every restore would just
    /// re-clobber the clipboard and prove nothing.
    private func restoreThenExternalWrite(
        _ text: String
    ) -> (PasteboardSnapshot, NSPasteboard) -> PasteboardSnapshot.RestoreResult {
        var fired = false
        return { snapshot, pasteboard in
            let result = snapshot.restore(to: pasteboard)
            guard !fired else { return result }
            fired = true
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return result
        }
    }

    /// The moving-target invariant, and the negative control for it: a settled external write
    /// survives a later synthetic restore instead of being reverted to the older clipboard.
    func testLateWriteArbiter_movesTheRestoreTargetOntoASettledExternalWrite() throws {
        let pasteboard = self.makeClipboardFallbackPasteboard("moving-target")
        defer { pasteboard.releaseGlobally() }

        self.writeText("user clipboard", to: pasteboard)
        let preOperation = PasteboardSnapshot.capture(from: pasteboard)
        var arbiter = self.makeLateWriteArbiter(
            restoreTarget: preOperation,
            baselineChangeCount: pasteboard.changeCount,
            syntheticCopyText: "selected text",
            didObserveCopyWrite: true
        )

        // A multi-representation write, so the assertions below prove the FULL snapshot moved
        // rather than only its plain text.
        self.writeRichItem(
            text: "clipboard manager contents",
            html: "<p>clipboard manager contents</p>",
            to: pasteboard
        )
        let external = try XCTUnwrap(PasteboardObservation.capture(from: pasteboard))
        XCTAssertEqual(
            arbiter.handle(external, on: pasteboard),
            .retargeted,
            "A readable write that is not the recorded payload must become the new restore target"
        )

        self.writeText("selected text", to: pasteboard)
        let synthetic = try XCTUnwrap(PasteboardObservation.capture(from: pasteboard))
        XCTAssertEqual(
            arbiter.handle(synthetic, on: pasteboard),
            .restored,
            "A write carrying the recorded synthetic payload must be reverted"
        )

        // NEGATIVE CONTROL. Remove the retarget assignment in `handle` and this reads
        // "user clipboard": the moving target is the only thing keeping the external write alive
        // across the synthetic restore.
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "clipboard manager contents",
            "The restore must revert to the external write, not to the older pre-operation clipboard"
        )
        XCTAssertEqual(
            self.htmlString(on: pasteboard),
            "<p>clipboard manager contents</p>",
            "The moving target must be the full snapshot, not a plain-text reduction of it"
        )
    }

    /// The coherence invariant, and the negative control for it: the branch acts on the observation
    /// it was handed, never on whatever the live pasteboard happens to hold by the time it runs.
    func testLateWriteArbiter_usesTheObservedPayloadAndNotTheLivePasteboard() throws {
        let pasteboard = self.makeClipboardFallbackPasteboard("coherence")
        defer { pasteboard.releaseGlobally() }

        self.writeText("user clipboard", to: pasteboard)
        let preOperation = PasteboardSnapshot.capture(from: pasteboard)
        var arbiter = self.makeLateWriteArbiter(
            restoreTarget: preOperation,
            baselineChangeCount: pasteboard.changeCount,
            syntheticCopyText: "selected text",
            didObserveCopyWrite: true
        )

        self.writeText("external write", to: pasteboard)
        let external = try XCTUnwrap(PasteboardObservation.capture(from: pasteboard))

        // Only now does the synthetic copy land. An implementation that re-read the live pasteboard
        // inside the branch would classify "selected text" here, or capture it as the restore
        // target. A rejected earlier revision of this fix failed at exactly this point.
        self.writeText("selected text", to: pasteboard)

        XCTAssertEqual(
            arbiter.handle(external, on: pasteboard),
            .retargeted,
            "Classification must come from the observation, which carried the external write"
        )

        // Deliberately the arbiter's own entry point rather than a hand-captured observation, so
        // this also pins the OTHER half of the invariant: the baseline recorded by the retarget
        // must be the observed generation, not a live re-read. A baseline taken live would have
        // absorbed the synthetic write's generation as "already handled" and this returns
        // `.unchanged` — the synthetic payload would then sit on the user's clipboard forever.
        XCTAssertEqual(
            arbiter.observeAndHandle(pasteboard),
            .restored,
            "The synthetic write must still be observable, so the retarget's baseline must be the observed generation"
        )
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "external write",
            "The adopted target must be the observed external write, not the live contents"
        )
    }

    /// An unreadable generation must not advance the baseline, because the payload can become
    /// readable inside that same generation with no second change to notice it by.
    func testLateWriteArbiter_keepsTheBaselineOnAnUnreadableGeneration() throws {
        let pasteboard = self.makeClipboardFallbackPasteboard("unsettled")
        defer { pasteboard.releaseGlobally() }

        self.writeText("user clipboard", to: pasteboard)
        let preOperation = PasteboardSnapshot.capture(from: pasteboard)
        var arbiter = self.makeLateWriteArbiter(
            restoreTarget: preOperation,
            baselineChangeCount: pasteboard.changeCount,
            syntheticCopyText: "selected text",
            didObserveCopyWrite: true
        )

        // A writer caught between clearContents() and its payload write.
        pasteboard.clearContents()
        let unreadable = try XCTUnwrap(PasteboardObservation.capture(from: pasteboard))
        XCTAssertNil(unreadable.string, "A cleared pasteboard must produce an unreadable observation")
        XCTAssertEqual(
            arbiter.handle(unreadable, on: pasteboard),
            .unsettled,
            "An unreadable generation must not be classified or adopted"
        )

        // The writer now publishes into that same generation. Only an unadvanced baseline lets the
        // loop see it at all.
        pasteboard.setString("selected text", forType: .string)
        XCTAssertEqual(
            arbiter.observeAndHandle(pasteboard),
            .restored,
            "The re-read of the same generation must find the published payload"
        )
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "user clipboard",
            "The delayed synthetic payload must be reverted to the restore target"
        )
    }

    /// An observation whose generation moves mid-capture must be thrown away rather than used.
    func testPasteboardObservation_discardsAnObservationWhoseGenerationMoved() {
        let pasteboard = self.makeClipboardFallbackPasteboard("torn")
        defer { pasteboard.releaseGlobally() }

        self.writeText("stable text", to: pasteboard)

        var reads = 0
        let torn = PasteboardObservation.capture(from: pasteboard) {
            reads += 1
            // Simulates a write landing between the pre-read and the post-read.
            return reads == 1 ? 100 : 101
        }
        XCTAssertNil(torn, "An observation whose generation moved mid-capture must be discarded")
        XCTAssertEqual(reads, 2, "The generation must be read both before and after the capture")

        let stable = PasteboardObservation.capture(from: pasteboard) { 100 }
        XCTAssertNotNil(stable, "A stable generation must still produce an observation")
        XCTAssertEqual(stable?.changeCount, 100, "The observation must report the generation it bound to")
    }

    /// A capture bound to a triggering generation must refuse a different one, so a poll woken by
    /// one write cannot commit a decision about a later one.
    func testPasteboardObservation_refusesAGenerationOtherThanTheExpectedOne() {
        let pasteboard = self.makeClipboardFallbackPasteboard("expected-generation")
        defer { pasteboard.releaseGlobally() }

        self.writeText("stable text", to: pasteboard)
        let live = pasteboard.changeCount

        XCTAssertNil(
            PasteboardObservation.capture(from: pasteboard, expectedGeneration: live - 1),
            "An observation of a generation other than the triggering one must be discarded"
        )
        XCTAssertNotNil(
            PasteboardObservation.capture(from: pasteboard, expectedGeneration: live),
            "The triggering generation itself must still be observable"
        )
    }

    /// The projection must reproduce `NSPasteboard.stringForType:`, which combines the text of
    /// every item with newlines. A first-item-wins projection would change the selection this
    /// fallback returns AND make two different multi-item clipboards compare equal.
    func testPasteboardSnapshotPlainText_matchesPasteboardLevelTextSemantics() {
        let pasteboard = self.makeClipboardFallbackPasteboard("text-parity")
        defer { pasteboard.releaseGlobally() }

        let fixtures: [(name: String, texts: [String?])] = [
            ("single item", ["only"]),
            ("two items", ["first", "second"]),
            ("three items", ["a", "b", "c"]),
            ("empty first", ["", "second"]),
            ("empty last", ["first", ""]),
            ("non-text between", ["first", nil, "third"]),
            ("no text at all", [nil, nil]),
        ]

        for fixture in fixtures {
            self.writeItems(texts: fixture.texts, to: pasteboard)
            let snapshot = PasteboardSnapshot.capture(from: pasteboard)
            XCTAssertEqual(
                snapshot.plainText,
                pasteboard.string(forType: .string).flatMap { $0.isEmpty ? nil : $0 },
                "Projection must match pasteboard-level text semantics for: \(fixture.name)"
            )
        }
    }

    /// The collision that a first-item-wins projection would create: two clipboards sharing only
    /// their first item must not be classified as the same payload.
    func testLateWriteArbiter_distinguishesMultiItemWritesSharingAFirstItem() throws {
        let pasteboard = self.makeClipboardFallbackPasteboard("multi-item-collision")
        defer { pasteboard.releaseGlobally() }

        self.writeText("user clipboard", to: pasteboard)
        let preOperation = PasteboardSnapshot.capture(from: pasteboard)

        // The synthetic copy was a two-item selection.
        self.writeItems(texts: ["shared", "synthetic"], to: pasteboard)
        let syntheticPayload = try XCTUnwrap(PasteboardSnapshot.capture(from: pasteboard).plainText)
        XCTAssertEqual(syntheticPayload, "shared\nsynthetic")

        var arbiter = self.makeLateWriteArbiter(
            restoreTarget: preOperation,
            baselineChangeCount: pasteboard.changeCount,
            syntheticCopyText: syntheticPayload,
            didObserveCopyWrite: true
        )

        // An unrelated two-item write that merely shares the first item.
        self.writeItems(texts: ["shared", "external"], to: pasteboard)
        let external = try XCTUnwrap(PasteboardObservation.capture(from: pasteboard))
        XCTAssertEqual(
            arbiter.handle(external, on: pasteboard),
            .retargeted,
            "Clipboards differing past their first item must not be classified as the same payload"
        )
    }

    /// ACCEPTED LIMITATION, pinned deliberately. The test is exact string equality, not authorship:
    /// the pasteboard carries no writer provenance, so an external write that happens to carry the
    /// same text as the synthetic copy is indistinguishable from it and is restored over. This
    /// records the behaviour rather than endorsing it.
    func testLateWriteArbiter_restoresOverASameTextExternalWrite_acceptedLimitation() throws {
        let pasteboard = self.makeClipboardFallbackPasteboard("same-text")
        defer { pasteboard.releaseGlobally() }

        self.writeText("user clipboard", to: pasteboard)
        let preOperation = PasteboardSnapshot.capture(from: pasteboard)
        var arbiter = self.makeLateWriteArbiter(
            restoreTarget: preOperation,
            baselineChangeCount: pasteboard.changeCount,
            syntheticCopyText: "selected text",
            didObserveCopyWrite: true
        )

        // Somebody else's write. Its plain text collides with the synthetic payload, but the item
        // is demonstrably NOT the same clipboard: it carries rich text the synthetic copy never
        // had. The classifier compares text, so the difference is invisible to it.
        self.writeRichItem(
            text: "selected text",
            html: "<b>selected text</b>",
            to: pasteboard
        )
        XCTAssertNotNil(self.htmlString(on: pasteboard), "The fixture must be distinguishable")

        let ambiguous = try XCTUnwrap(PasteboardObservation.capture(from: pasteboard))
        XCTAssertEqual(
            arbiter.handle(ambiguous, on: pasteboard),
            .restored,
            "Same-text external writes are indistinguishable from the synthetic copy and are reverted"
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "user clipboard")
        XCTAssertNil(
            self.htmlString(on: pasteboard),
            "The external item's rich text is lost — this is the accepted cost of text-only comparison"
        )
    }

    /// The two halves of the no-recorded-payload rule, which `didObserveCopyWrite` decides.
    func testLateWriteArbiter_appliesTheNoRecordedPayloadPolicy() throws {
        let pasteboard = self.makeClipboardFallbackPasteboard("no-payload")
        defer { pasteboard.releaseGlobally() }

        self.writeText("user clipboard", to: pasteboard)
        let preOperation = PasteboardSnapshot.capture(from: pasteboard)
        let baseline = pasteboard.changeCount

        // Cmd+C timed out: nothing was restored, so a write in this window is taken for the
        // delayed copy. This is a known false-positive path, kept because there is no provenance.
        var timedOut = self.makeLateWriteArbiter(
            restoreTarget: preOperation,
            baselineChangeCount: baseline,
            syntheticCopyText: nil,
            didObserveCopyWrite: false
        )
        self.writeText("delayed selection", to: pasteboard)
        let afterTimeout = try XCTUnwrap(PasteboardObservation.capture(from: pasteboard))
        XCTAssertEqual(
            timedOut.handle(afterTimeout, on: pasteboard),
            .restored,
            "With no recorded payload and no observed copy, a late write is treated as the delayed copy"
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "user clipboard")

        // The copy DID land but carried no readable text (a non-text selection). The target is
        // already back in place, so a further unidentifiable write belongs to somebody else.
        var nonTextSelection = self.makeLateWriteArbiter(
            restoreTarget: preOperation,
            baselineChangeCount: pasteboard.changeCount,
            syntheticCopyText: nil,
            didObserveCopyWrite: true
        )
        self.writeText("somebody else's clipboard", to: pasteboard)
        let external = try XCTUnwrap(PasteboardObservation.capture(from: pasteboard))
        XCTAssertEqual(
            nonTextSelection.handle(external, on: pasteboard),
            .retargeted,
            "With the copy observed but unreadable, a later readable write is somebody else's"
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "somebody else's clipboard")
    }

    /// The restore budget stops the loop rather than letting it fight a repeating writer forever.
    func testLateWriteArbiter_stopsRestoringOnceTheBudgetIsExhausted() throws {
        let pasteboard = self.makeClipboardFallbackPasteboard("budget")
        defer { pasteboard.releaseGlobally() }

        self.writeText("user clipboard", to: pasteboard)
        let preOperation = PasteboardSnapshot.capture(from: pasteboard)
        var arbiter = self.makeLateWriteArbiter(
            restoreTarget: preOperation,
            baselineChangeCount: pasteboard.changeCount,
            syntheticCopyText: "selected text",
            didObserveCopyWrite: true,
            restoresRemaining: 1
        )

        self.writeText("selected text", to: pasteboard)
        let first = try XCTUnwrap(PasteboardObservation.capture(from: pasteboard))
        XCTAssertEqual(arbiter.handle(first, on: pasteboard), .restored)

        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "user clipboard",
            "The first restore must actually have written, not merely reported success"
        )

        self.writeText("selected text", to: pasteboard)
        let generationBeforeExhaustion = pasteboard.changeCount
        let second = try XCTUnwrap(PasteboardObservation.capture(from: pasteboard))
        XCTAssertEqual(
            arbiter.handle(second, on: pasteboard),
            .budgetExhausted,
            "Past the budget the arbiter must stop rather than restore again"
        )
        XCTAssertEqual(
            pasteboard.changeCount,
            generationBeforeExhaustion,
            "An exhausted budget must not write at all, not merely write the same value back"
        )
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "selected text",
            "An exhausted budget leaves the last write in place rather than looping"
        )
    }

    /// The observation's classification payload is a projection of its own snapshot, not a second
    /// read that happens to agree with it.
    func testPasteboardObservation_derivesItsStringFromItsOwnSnapshot() throws {
        let pasteboard = self.makeClipboardFallbackPasteboard("derivation")
        let mirror = self.makeClipboardFallbackPasteboard("derivation-mirror")
        defer {
            pasteboard.releaseGlobally()
            mirror.releaseGlobally()
        }

        self.writeText("selected text", to: pasteboard)
        let observation = try XCTUnwrap(PasteboardObservation.capture(from: pasteboard))
        guard case let .readable(_, snapshot) = observation else {
            return XCTFail("A pasteboard carrying text must produce a readable observation")
        }

        let string = try XCTUnwrap(observation.string)
        XCTAssertEqual(string, "selected text")
        XCTAssertEqual(
            string,
            snapshot.plainText,
            "The classified text must be a projection of the snapshot, not an independent read"
        )
        snapshot.restore(to: mirror)
        XCTAssertEqual(
            mirror.string(forType: .string),
            string,
            "The classified text and the restore target must be the same text"
        )
    }

    /// `restore(to:)` hands back the generation its own write created, so a caller can baseline on
    /// it without re-reading `changeCount`. A re-read is what lets an external write that lands
    /// immediately after the restore be recorded as "already handled" and then overwritten.
    ///
    /// This pins the contract rather than reproducing the race, which cannot be forced
    /// deterministically. The defect is closed by construction: the baseline is now produced inside
    /// the write, so no code path exists between the two.
    func testPasteboardSnapshotRestore_reportsTheGenerationItCreated() throws {
        let pasteboard = self.makeClipboardFallbackPasteboard("restore-generation")
        defer { pasteboard.releaseGlobally() }

        self.writeText("user clipboard", to: pasteboard)
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        self.writeText("selected text", to: pasteboard)
        let restored = snapshot.restore(to: pasteboard)
        let restoredGeneration = restored.generation
        XCTAssertTrue(restored.didRestoreContents, "The pasteboard must have accepted the write")
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "user clipboard",
            "The restore must have put the snapshot back"
        )

        // A writer lands right after our restore — the race the returned generation exists for.
        self.writeText("external write", to: pasteboard)
        XCTAssertLessThan(
            restoredGeneration,
            pasteboard.changeCount,
            "The reported generation must be our own restore's, not a later writer's"
        )

        var arbiter = self.makeLateWriteArbiter(
            restoreTarget: snapshot,
            baselineChangeCount: restoredGeneration,
            syntheticCopyText: "selected text",
            didObserveCopyWrite: true
        )
        XCTAssertEqual(
            arbiter.observeAndHandle(pasteboard),
            .retargeted,
            "A write landing after our restore must still be observed rather than skipped"
        )
    }

    /// A generation with no readable text carries no restore target at all, so it cannot be adopted
    /// by accident and costs no full snapshot on the polls that re-observe it.
    func testPasteboardObservation_treatsANonTextGenerationAsUnreadable() throws {
        let pasteboard = self.makeClipboardFallbackPasteboard("non-text")
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data([0x01, 0x02, 0x03]), forType: .png)
        pasteboard.writeObjects([item])

        let observation = try XCTUnwrap(PasteboardObservation.capture(from: pasteboard))
        guard case .unreadable = observation else {
            return XCTFail("A generation with no readable text must not carry a restore target")
        }
        XCTAssertNil(observation.string)
    }

    /// The payload-settle helper must not return an observation it already has evidence is stale.
    ///
    /// Scope note: with readable observations returning immediately, the removed fallback could only
    /// ever have resurrected an *unreadable* one, so this pins a contract rather than closing a
    /// user-visible defect. It still discriminates — the previous `?? latest` form returns the
    /// earlier observation here where this returns nothing.
    func testReadSettledObservation_returnsNothingWhenTheFinalCaptureIsUnstable() {
        let pasteboard = self.makeClipboardFallbackPasteboard("no-resurrection")
        defer { pasteboard.releaseGlobally() }

        self.writeText("stale text", to: pasteboard)

        // Stable-but-unreadable while the window is open, then unstable at the terminal capture.
        var sawUnreadable = false
        let cutoff = DispatchTime.now() + .microseconds(20_000)
        let settled = TextSelectionService.shared.readSettledObservation(from: pasteboard) {
            guard DispatchTime.now() < cutoff else { return nil }
            sawUnreadable = true
            return .unreadable(changeCount: 7)
        }

        XCTAssertTrue(
            sawUnreadable,
            "The helper must have polled unreadable observations first, otherwise this proves nothing"
        )
        XCTAssertNil(
            settled,
            "An unstable terminal capture must yield no observation, never the earlier stale one"
        )
    }

    /// A capture taken while a foreign writer sits between `clearContents()` and its payload must
    /// not be adopted as the pre-operation restore target.
    ///
    /// That window is internally consistent (the generation does not move when the payload lands),
    /// so the generation guard alone passes it, and the empty snapshot it yields would later be
    /// restored over the writer's content. Fails closed: a scheduler stall makes it fail, never pass.
    func testCaptureStable_waitsOutAWriterCaughtBetweenClearAndPublish() {
        let pasteboard = self.makeClipboardFallbackPasteboard("clear-then-publish")
        defer { pasteboard.releaseGlobally() }

        self.writeText("user clipboard", to: pasteboard)

        // The foreign writer clears, advancing the generation, and publishes shortly after. The
        // publish does NOT advance the generation again.
        pasteboard.clearContents()
        let generationAfterClear = pasteboard.changeCount

        let pasteboardName = pasteboard.name.rawValue
        let didPublish = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.005) {
            NSPasteboard(name: NSPasteboard.Name(pasteboardName))
                .setString("their content", forType: .string)
            didPublish.signal()
        }

        let captured = PasteboardSnapshot.captureStable(from: pasteboard)

        XCTAssertEqual(
            didPublish.wait(timeout: .now() + 1.0),
            .success,
            "The writer must have published, otherwise this test proves nothing"
        )
        XCTAssertEqual(
            pasteboard.changeCount,
            generationAfterClear,
            "The publish must not have advanced the generation, or the premise does not hold"
        )
        XCTAssertEqual(
            captured?.snapshot.plainText,
            "their content",
            "An itemless capture must be re-polled, not adopted as the restore target"
        )
    }

    /// A genuinely empty clipboard is still captured as empty once the bound expires.
    func testCaptureStable_acceptsAGenuinelyEmptyClipboard() {
        let pasteboard = self.makeClipboardFallbackPasteboard("genuinely-empty")
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        let captured = PasteboardSnapshot.captureStable(from: pasteboard)

        XCTAssertNotNil(captured, "An empty clipboard must still produce a capture")
        XCTAssertTrue(
            captured?.snapshot.hasNoCapturedRepresentations ?? false,
            "Waiting out the ambiguity must not turn an empty clipboard into a failure"
        )
    }

    /// A non-text clipboard is returned immediately and is never treated as the ambiguous case.
    func testCaptureStable_returnsANonTextClipboardWithoutWaiting() {
        let pasteboard = self.makeClipboardFallbackPasteboard("non-text-stable")
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data([0x01, 0x02, 0x03]), forType: .png)
        pasteboard.writeObjects([item])

        let captured = PasteboardSnapshot.captureStable(from: pasteboard)
        XCTAssertNotNil(captured)
        XCTAssertFalse(
            captured?.snapshot.hasNoCapturedRepresentations ?? true,
            "A non-text clipboard has items and must be adopted, not waited out"
        )
        XCTAssertNil(captured?.snapshot.plainText, "The fixture is deliberately non-text")
    }

    /// A rejected restore write must be reported as a failure, never as a restore.
    func testLateWriteArbiter_reportsRestoreFailureRatherThanSuccess() throws {
        let pasteboard = self.makeClipboardFallbackPasteboard("restore-failure")
        defer { pasteboard.releaseGlobally() }

        self.writeText("user clipboard", to: pasteboard)
        let preOperation = PasteboardSnapshot.capture(from: pasteboard)

        self.writeText("selected text", to: pasteboard)
        var arbiter = self.makeLateWriteArbiter(
            restoreTarget: preOperation,
            baselineChangeCount: pasteboard.changeCount,
            syntheticCopyText: "selected text",
            didObserveCopyWrite: true,
            performRestore: { _, pasteboard in
                // The clear lands, the write back does not. AppKit surfaces this as a false result.
                PasteboardSnapshot.RestoreResult(
                    generation: pasteboard.clearContents(),
                    didRestoreContents: false
                )
            }
        )

        let synthetic = try XCTUnwrap(PasteboardObservation.capture(from: pasteboard))
        XCTAssertEqual(
            arbiter.handle(synthetic, on: pasteboard),
            .restoreFailed,
            "A rejected write must not be reported as a completed restore"
        )
    }

    /// The settle loop keeps watching after a restore, so the restore budget is real.
    ///
    /// Two matching writes land in sequence; both must be reverted. Stopping after the first would
    /// make `maxLateCopyRestores` dead code.
    func testDefensiveRestore_keepsWatchingAfterARestore() {
        let pasteboard = self.makeClipboardFallbackPasteboard("multi-restore")
        defer { pasteboard.releaseGlobally() }

        self.writeText("user clipboard", to: pasteboard)
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let changeCountBeforeCopy = pasteboard.changeCount

        let pasteboardName = pasteboard.name.rawValue
        let didWriteBoth = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.02) {
            let writer = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
            writer.clearContents()
            writer.setString("late copy", forType: .string)
            Thread.sleep(forTimeInterval: 0.04)
            writer.clearContents()
            writer.setString("late copy", forType: .string)
            didWriteBoth.signal()
        }

        TextSelectionService.shared.restoreClipboardDefensively(
            snapshot,
            to: pasteboard,
            changeCountBeforeCopy: changeCountBeforeCopy,
            didObserveCopyWrite: false,
            syntheticCopyText: "late copy"
        )

        XCTAssertEqual(
            didWriteBoth.wait(timeout: .now() + 1.0),
            .success,
            "Both writes must have run, otherwise this test proves nothing"
        )
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "user clipboard",
            "The loop must keep watching after the first restore and revert the second write too"
        )
    }

    /// The final-edge reconciliation exists and does the work.
    ///
    /// The settle window is set to zero so the poll loop cannot run at all, leaving the final edge as
    /// the only thing that can act. Delete it and a delayed copy that lands after the last poll is
    /// never reverted, which is precisely the edge case it was added for.
    func testDefensiveRestore_finalEdgeReconcilesAWriteTheLoopNeverSaw() {
        let pasteboard = self.makeClipboardFallbackPasteboard("final-edge")
        defer { pasteboard.releaseGlobally() }

        self.writeText("user clipboard", to: pasteboard)
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let changeCountBeforeCopy = pasteboard.changeCount

        // The delayed copy is already on the clipboard before the settle watch begins.
        self.writeText("delayed selection", to: pasteboard)

        TextSelectionService.shared.restoreClipboardDefensively(
            snapshot,
            to: pasteboard,
            changeCountBeforeCopy: changeCountBeforeCopy,
            didObserveCopyWrite: false,
            syntheticCopyText: nil,
            settleWindowMicros: 0
        )

        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "user clipboard",
            "With no polling horizon, only the final-edge reconciliation can revert the delayed copy"
        )
    }

    /// The initial restore must baseline on the generation the restore itself created.
    ///
    /// A post-restore live re-read samples a count an external writer may already have advanced,
    /// recording that generation as handled without ever observing its contents.
    func testDefensiveRestore_initialBaselineComesFromTheRestoreNotALiveReread() {
        let pasteboard = self.makeClipboardFallbackPasteboard("initial-baseline")
        defer { pasteboard.releaseGlobally() }

        self.writeText("user clipboard", to: pasteboard)
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let changeCountBeforeCopy = pasteboard.changeCount

        // The app's delayed copy lands immediately after our restore. Its text matches the recorded
        // payload, so a correctly-baselined loop must still see that generation and revert it.
        TextSelectionService.shared.restoreClipboardDefensively(
            snapshot,
            to: pasteboard,
            changeCountBeforeCopy: changeCountBeforeCopy,
            didObserveCopyWrite: true,
            syntheticCopyText: "late copy",
            settleWindowMicros: 0,
            performRestore: self.restoreThenExternalWrite("late copy")
        )

        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "user clipboard",
            "A write landing right after the restore must still be observed, not swallowed by the baseline"
        )
    }

    /// The arbiter's synthetic branch must baseline on the restore's own generation too.
    func testLateWriteArbiter_syntheticBaselineComesFromTheRestoreNotALiveReread() throws {
        let pasteboard = self.makeClipboardFallbackPasteboard("arbiter-baseline")
        defer { pasteboard.releaseGlobally() }

        self.writeText("user clipboard", to: pasteboard)
        let preOperation = PasteboardSnapshot.capture(from: pasteboard)

        self.writeText("selected text", to: pasteboard)
        var arbiter = self.makeLateWriteArbiter(
            restoreTarget: preOperation,
            baselineChangeCount: pasteboard.changeCount,
            syntheticCopyText: "selected text",
            didObserveCopyWrite: true,
            performRestore: self.restoreThenExternalWrite("external write")
        )

        let synthetic = try XCTUnwrap(PasteboardObservation.capture(from: pasteboard))
        XCTAssertEqual(arbiter.handle(synthetic, on: pasteboard), .restored)

        // The external write landed immediately after that restore. Only a baseline taken from the
        // restore's own generation leaves it observable.
        XCTAssertEqual(
            arbiter.observeAndHandle(pasteboard),
            .retargeted,
            "A write landing right after the restore must still be observed, not recorded as handled"
        )
    }

    /// The settle loop and its final-edge reconciliation actually route through the arbiter.
    ///
    /// Smoke coverage only, and deliberately labelled as such: it shows that *some* production path
    /// observed and reverted a scheduled write. It cannot separate the loop from the final edge —
    /// removing either still leaves schedules under which this passes — so it is not evidence for
    /// final-edge behaviour; `testDefensiveRestore_finalEdgeReconcilesAWriteTheLoopNeverSaw` does
    /// that separately. That both paths call one routine rather than two is established by reading
    /// the code, not by any test.
    func testDefensiveRestore_revertsADelayedSyntheticCopyThroughTheSettleLoop() {
        let pasteboard = self.makeClipboardFallbackPasteboard("settle-loop")
        defer { pasteboard.releaseGlobally() }

        self.writeText("user clipboard", to: pasteboard)
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let changeCountBeforeCopy = pasteboard.changeCount

        // Resolve the pasteboard by name inside the closure rather than capturing the non-Sendable
        // NSPasteboard across the concurrency boundary.
        let pasteboardName = pasteboard.name.rawValue
        let didWrite = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
            let writer = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
            writer.clearContents()
            writer.setString("delayed selection", forType: .string)
            didWrite.signal()
        }

        TextSelectionService.shared.restoreClipboardDefensively(
            snapshot,
            to: pasteboard,
            changeCountBeforeCopy: changeCountBeforeCopy,
            didObserveCopyWrite: false,
            syntheticCopyText: nil
        )

        XCTAssertEqual(
            didWrite.wait(timeout: .now() + 1.0),
            .success,
            "The delayed copy must have run, otherwise this test proves nothing"
        )
        // The user's text alone is not proof: it is also the starting state. Requiring the change
        // count to advance past the delayed write proves a restore actually happened.
        XCTAssertGreaterThan(
            pasteboard.changeCount,
            changeCountBeforeCopy + 1,
            "The delayed write must have been observed and reverted, not merely never seen"
        )
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "user clipboard",
            "A delayed synthetic copy must still be reverted to the user's clipboard"
        )
    }
}

// MARK: - Write Mode selection capture: the empty restore target and the confirmed caret

extension DictationE2ETests {
    /// The standard rich-text copy path must be waited out, not adopted as an empty restore
    /// target.
    ///
    /// `declareTypes(_:owner:)` — a common rich-text declare-then-publish path used by applications
    /// that expose multiple promised pasteboard representations — advances the generation and leaves
    /// ONE item whose every `data(forType:)` is nil until the payload lands. An item-count test sees a
    /// non-empty snapshot, returns immediately, and the later restore puts back nothing.
    /// Fails closed: a scheduler stall makes it fail, never pass.
    func testCaptureStable_waitsOutARichTextCopyThatDeclaredTypesButHasNotPublished() {
        let pasteboard = self.makeClipboardFallbackPasteboard("declared-not-published")
        defer { pasteboard.releaseGlobally() }

        self.writeText("user clipboard", to: pasteboard)

        pasteboard.declareTypes([.rtf, .string], owner: nil)
        let generationAfterDeclare = pasteboard.changeCount

        XCTAssertEqual(
            pasteboard.pasteboardItems?.count,
            1,
            "The premise is one item present, so an item-count gate would call this non-empty"
        )
        XCTAssertNil(
            pasteboard.data(forType: .string),
            "The premise is that no declared representation has produced a value yet"
        )

        let pasteboardName = pasteboard.name.rawValue
        let didPublish = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.005) {
            NSPasteboard(name: NSPasteboard.Name(pasteboardName))
                .setData(Data("their content".utf8), forType: .string)
            didPublish.signal()
        }

        let captured = PasteboardSnapshot.captureStable(from: pasteboard)

        XCTAssertEqual(
            didPublish.wait(timeout: .now() + 1.0),
            .success,
            "The writer must have published, otherwise this test proves nothing"
        )
        XCTAssertEqual(
            pasteboard.changeCount,
            generationAfterDeclare,
            "The publish must not have advanced the generation, or the premise does not hold"
        )
        XCTAssertEqual(
            captured?.snapshot.plainText,
            "their content",
            "A capture with no representations must be re-polled, not adopted as the restore target"
        )
    }

    /// A clipboard whose items produced representations is adopted at once, and this asserts timing
    /// rather than only the value.
    ///
    /// The emptiness gate has three plausible shapes — item count, representations captured, text —
    /// and only a timing assertion tells them apart, because all three return the same snapshot
    /// here and differ solely in whether they burn the settling window first. `emptySettleMicros`
    /// is driven far above its default so a readability gate would be caught by an unmissable
    /// margin. Fails closed: a stall makes it fail, never pass.
    func testCaptureStable_returnsADataBearingClipboardBeforeTheSettlingHorizon() {
        let pasteboard = self.makeClipboardFallbackPasteboard("data-bearing-fast-path")
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data([0x01, 0x02, 0x03]), forType: .png)
        pasteboard.writeObjects([item])

        let horizonMicros: useconds_t = 500_000
        let started = DispatchTime.now()
        let captured = PasteboardSnapshot.captureStable(from: pasteboard, emptySettleMicros: horizonMicros)
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds

        XCTAssertNotNil(captured, "A clipboard with captured representations must still produce a capture")
        XCTAssertNil(captured?.snapshot.plainText, "The fixture is deliberately non-text")
        XCTAssertLessThan(
            elapsedNanos,
            UInt64(horizonMicros) * 1_000 / 4,
            "Captured representations must be adopted at once, never held for the settling horizon"
        )
    }

    /// Only a valid, zero-length range is an affirmative "nothing is selected".
    ///
    /// A `kCFNotFound` location is the element declining to answer, and it must stay
    /// indistinguishable from unavailable or AX-opaque editors stop reaching the clipboard
    /// fallback this whole path exists for.
    func testHasSelectedRange_confirmsNoSelectionOnlyForAValidZeroLengthRange() {
        var caretConfirmed = false
        XCTAssertFalse(TextSelectionService.hasSelectedRange(
            CFRange(location: 3, length: 0),
            confirmedNoSelection: &caretConfirmed
        ))
        XCTAssertTrue(caretConfirmed, "A caret at a valid location with nothing selected is an answer")

        var unavailableConfirmed = false
        XCTAssertFalse(TextSelectionService.hasSelectedRange(
            CFRange(location: kCFNotFound, length: 0),
            confirmedNoSelection: &unavailableConfirmed
        ))
        XCTAssertFalse(
            unavailableConfirmed,
            "kCFNotFound is a refusal to answer and must keep the clipboard fallback reachable"
        )

        var selectionConfirmed = false
        XCTAssertTrue(TextSelectionService.hasSelectedRange(
            CFRange(location: 3, length: 5),
            confirmedNoSelection: &selectionConfirmed
        ))
        XCTAssertFalse(selectionConfirmed, "A real selection is not a confirmed absence of one")

        // A negative length is malformed, not a caret. Only length ZERO is the affirmative answer.
        var negativeLengthConfirmed = false
        XCTAssertFalse(TextSelectionService.hasSelectedRange(
            CFRange(location: 3, length: -1),
            confirmedNoSelection: &negativeLengthConfirmed
        ))
        XCTAssertFalse(negativeLengthConfirmed, "A malformed negative length is not a confirmed caret")
    }

    /// The two sentinels this attribute reports are DIFFERENT VALUES, and only one of them is
    /// `kCFNotFound`.
    ///
    /// `kCFNotFound` is `-1`; `NSNotFound` is `Int.max`. A `kCFNotFound`-only guard reads
    /// `{NSNotFound, 0}` as a caret and suppresses the clipboard fallback for exactly the AX-opaque
    /// editors this path exists to serve; a negative location is the same hole one step over.
    /// Neither value is an index, so neither can be evidence of a caret. Issue #319 is where a
    /// macOS 26 AX report of `{location: NSNotFound, length: 0}` was raised. The premise assertions
    /// below fail loudly if either constant is not what this reasoning assumes.
    func testHasSelectedRange_treatsNSNotFoundAndNegativeLocationsAsUnavailable() {
        XCTAssertEqual(kCFNotFound, -1, "The premise is that the two sentinels are different values")
        XCTAssertEqual(NSNotFound, Int.max, "The premise is that NSNotFound is Int.max, not -1")

        var nsNotFoundConfirmed = false
        XCTAssertFalse(TextSelectionService.hasSelectedRange(
            CFRange(location: NSNotFound, length: 0),
            confirmedNoSelection: &nsNotFoundConfirmed
        ))
        XCTAssertFalse(
            nsNotFoundConfirmed,
            "macOS 26's {NSNotFound, 0} is no valid caret at all and must keep the fallback reachable"
        )

        var negativeLocationConfirmed = false
        XCTAssertFalse(TextSelectionService.hasSelectedRange(
            CFRange(location: -5, length: 0),
            confirmedNoSelection: &negativeLocationConfirmed
        ))
        XCTAssertFalse(negativeLocationConfirmed, "A negative location is not an index, so it is no caret")
    }

    /// Whether the clipboard fallback ran for a given pair of confirmation signals. The subject
    /// here is the FOLD, so the flags are set directly rather than through the range classifier.
    private func clipboardFallbackRuns(systemWideConfirms: Bool, frontmostConfirms: Bool) -> Bool {
        var ran = false
        _ = TextSelectionService.shared.resolveSelection(
            systemWide: { $0 = systemWideConfirms; return nil },
            frontmost: { $0 = frontmostConfirms; return nil },
            clipboardFallback: { ran = true; return "selection read by synthetic copy" }
        )
        return ran
    }

    /// One strategy confirming a caret while the other cannot resolve an element at all must STILL
    /// suppress the fallback.
    ///
    /// The confirmation is element-scoped, so this pins a chosen failure mode rather than a proof.
    /// Falling through here would fire a real Cmd+C, and an editor that treats Cmd+C with a bare
    /// caret as "copy the current line" would hand back text the user never selected for Write Mode
    /// to rewrite. Not engaging matches upstream, which has no clipboard fallback at all.
    func testResolveSelection_suppressesTheClipboardFallbackWhenOnlySystemWideConfirms() {
        XCTAssertFalse(
            self.clipboardFallbackRuns(systemWideConfirms: true, frontmostConfirms: false),
            "A confirmed caret must not fire a synthetic Cmd+C because the other strategy failed"
        )
    }

    /// The other direction. The two strategies obtain their elements differently and are not
    /// interchangeable, so each order needs its own pin.
    func testResolveSelection_suppressesTheClipboardFallbackWhenOnlyFrontmostConfirms() {
        XCTAssertFalse(
            self.clipboardFallbackRuns(systemWideConfirms: false, frontmostConfirms: true),
            "A confirmed caret must not fire a synthetic Cmd+C because the other strategy failed"
        )
    }

    /// The regression, at the decision seam rather than the classifier: an element reporting
    /// macOS 26's `{NSNotFound, 0}` must still reach the clipboard fallback.
    ///
    /// Deliberately fold-agnostic — neither strategy confirms anything, so this asserts the same
    /// thing whether the confirmation fold is `||` or `&&`.
    func testResolveSelection_stillReachesTheClipboardFallbackForANSNotFoundRange() {
        var clipboardFallbackRan = false
        let resolved = TextSelectionService.shared.resolveSelection(
            systemWide: { confirmedNoSelection in
                _ = TextSelectionService.hasSelectedRange(
                    CFRange(location: NSNotFound, length: 0),
                    confirmedNoSelection: &confirmedNoSelection
                )
                return nil
            },
            frontmost: { confirmedNoSelection in
                _ = TextSelectionService.hasSelectedRange(
                    CFRange(location: NSNotFound, length: 0),
                    confirmedNoSelection: &confirmedNoSelection
                )
                return nil
            },
            clipboardFallback: {
                clipboardFallbackRan = true
                return "selection read by synthetic copy"
            }
        )

        XCTAssertTrue(
            clipboardFallbackRan,
            "macOS 26's no-caret sentinel must not suppress the fallback this path exists to provide"
        )
        XCTAssertEqual(resolved, "selection read by synthetic copy")
    }

    /// A confirmed caret suppresses the clipboard fallback.
    ///
    /// Post-change that fallback runs synchronously on the main thread from the hotkey callback:
    /// roughly a 500ms beachball on every no-selection Edit-mode press, a real Cmd+C fired into
    /// the focused app, and a window where a background write gets misclassified.
    func testResolveSelection_suppressesTheClipboardFallbackWhenARangeConfirmsNoSelection() {
        var clipboardFallbackRan = false
        let resolved = TextSelectionService.shared.resolveSelection(
            systemWide: { confirmedNoSelection in
                // Drives the production classifier, not a hand-set flag, so the wiring is covered.
                _ = TextSelectionService.hasSelectedRange(
                    CFRange(location: 3, length: 0),
                    confirmedNoSelection: &confirmedNoSelection
                )
                return nil
            },
            frontmost: { confirmedNoSelection in
                _ = TextSelectionService.hasSelectedRange(
                    CFRange(location: 3, length: 0),
                    confirmedNoSelection: &confirmedNoSelection
                )
                return nil
            },
            clipboardFallback: {
                clipboardFallbackRan = true
                return "the user's clipboard, not their selection"
            }
        )

        XCTAssertFalse(
            clipboardFallbackRan,
            "A confirmed caret must not fire a synthetic Cmd+C into the focused app"
        )
        XCTAssertEqual(resolved, "", "A confirmed empty selection resolves to empty, not to nothing")
    }

    /// The side effect the suppression must not have: strategy 1 confirming an empty selection
    /// must not stop strategy 2 from running.
    ///
    /// The system-wide focused element and the frontmost app's focused element can resolve
    /// differently — that is why both strategies exist — so returning on strategy 1's confirmation
    /// would lose a selection strategy 2 would have found.
    func testResolveSelection_stillRunsTheFrontmostStrategyAfterSystemWideConfirmsNoSelection() {
        var frontmostStrategyRan = false
        var clipboardFallbackRan = false
        let resolved = TextSelectionService.shared.resolveSelection(
            systemWide: { confirmedNoSelection in
                _ = TextSelectionService.hasSelectedRange(
                    CFRange(location: 3, length: 0),
                    confirmedNoSelection: &confirmedNoSelection
                )
                return nil
            },
            frontmost: { _ in
                frontmostStrategyRan = true
                return "selection only the frontmost app could see"
            },
            clipboardFallback: {
                clipboardFallbackRan = true
                return "the user's clipboard, not their selection"
            }
        )

        XCTAssertTrue(
            frontmostStrategyRan,
            "A confirmed caret on the system-wide element must not short-circuit the second strategy"
        )
        XCTAssertEqual(
            resolved,
            "selection only the frontmost app could see",
            "The second strategy's selection must win over the first strategy's confirmed absence"
        )
        XCTAssertFalse(clipboardFallbackRan, "A found selection never needs the clipboard fallback")
    }

    /// The negative control: with no strategy able to tell, the clipboard fallback still runs.
    /// This is the AX-opaque editor case the fallback was built for.
    func testResolveSelection_reachesTheClipboardFallbackWhenNoStrategyCouldTell() {
        var clipboardFallbackRan = false
        let resolved = TextSelectionService.shared.resolveSelection(
            systemWide: { _ in nil },
            frontmost: { _ in nil },
            clipboardFallback: {
                clipboardFallbackRan = true
                return "selection read by synthetic copy"
            }
        )

        XCTAssertTrue(clipboardFallbackRan, "An unreadable accessibility tree must reach the fallback")
        XCTAssertEqual(resolved, "selection read by synthetic copy")
    }
}

// MARK: - Write Mode selection capture: driving getSelectedText(from:) without a focused element

/// These drive the REAL `getSelectedText(from:)` through its injected attribute reader, handing back
/// genuine `AXValue`s minted with `AXValueCreate`. That covers the flag-propagation path — the
/// classifier setting its own local is not enough, the signal has to leave the function through the
/// caller's `inout` — which no test could reach while the only route in was a live focused element.
extension DictationE2ETests {
    /// A stand-in element. The injected reader never dereferences it.
    private var unusedAXElement: AXUIElement { AXUIElementCreateSystemWide() }

    /// A genuine `AXValue` carrying `{location, length}`, exactly what the AX tree hands back.
    private func axRange(_ location: Int, _ length: Int) throws -> CFTypeRef {
        var range = CFRange(location: location, length: length)
        return try XCTUnwrap(AXValueCreate(.cfRange, &range)) as CFTypeRef
    }

    /// Answers the three attributes `getSelectedText(from:)` asks for. The defaults are the
    /// AX-opaque-editor baseline: an empty selected-text answer and nothing else available.
    private func axReader(
        selectedText: (AXError, CFTypeRef?) = (.success, "" as CFTypeRef),
        selectedRange: (AXError, CFTypeRef?) = (.attributeUnsupported, nil),
        fullValue: (AXError, CFTypeRef?) = (.attributeUnsupported, nil)
    ) -> (AXUIElement, CFString) -> (AXError, CFTypeRef?) {
        { _, attribute in
            switch attribute as String {
            case kAXSelectedTextAttribute: return selectedText
            case kAXSelectedTextRangeAttribute: return selectedRange
            default: return fullValue
            }
        }
    }

    /// A collapsed caret must report itself to the CALLER, not just to a local inside the function.
    func testGetSelectedTextFromElement_reportsAConfirmedCaretToItsCaller() throws {
        var confirmedNoSelection = false
        let selected = TextSelectionService.shared.getSelectedText(
            from: self.unusedAXElement,
            confirmedNoSelection: &confirmedNoSelection,
            readAttribute: self.axReader(selectedRange: (.success, try self.axRange(3, 0)))
        )

        XCTAssertNil(selected, "A caret selects nothing, so there is no text to return")
        XCTAssertTrue(
            confirmedNoSelection,
            "The caret signal must reach the caller's flag, not die inside the function"
        )
    }

    /// Every way the range read can fail must leave the caller's flag alone, so the clipboard
    /// fallback stays reachable for the AX-opaque editors it exists to serve.
    func testGetSelectedTextFromElement_leavesTheFlagUntouchedForEveryUnreadableRange() throws {
        var wrongKind = CGPoint(x: 1, y: 2)
        let unreadable: [(String, (AXError, CFTypeRef?))] = [
            ("attribute unavailable", (.attributeUnsupported, nil)),
            ("non-AXValue", (.success, "not an AXValue" as CFTypeRef)),
            ("AXValueGetValue failure", (.success, try XCTUnwrap(AXValueCreate(.cgPoint, &wrongKind)))),
            ("macOS 26 {NSNotFound, 0}", (.success, try self.axRange(NSNotFound, 0)))
        ]

        for (name, selectedRange) in unreadable {
            var confirmedNoSelection = false
            let selected = TextSelectionService.shared.getSelectedText(
                from: self.unusedAXElement,
                confirmedNoSelection: &confirmedNoSelection,
                readAttribute: self.axReader(selectedRange: selectedRange)
            )
            XCTAssertNil(selected, "\(name) yields no selection")
            XCTAssertFalse(confirmedNoSelection, "\(name) is not evidence of a caret")
        }
    }

    /// The success paths, and the bounds rejection that must not be mistaken for a caret.
    func testGetSelectedTextFromElement_extractsInBoundsSelectionsAndRejectsOutOfBoundsOnes() throws {
        var direct = false
        XCTAssertEqual(
            TextSelectionService.shared.getSelectedText(
                from: self.unusedAXElement,
                confirmedNoSelection: &direct,
                readAttribute: self.axReader(selectedText: (.success, "picked" as CFTypeRef))
            ),
            "picked",
            "A non-empty kAXSelectedText answer short-circuits before the range fallback"
        )
        XCTAssertFalse(direct, "A real selection is not a confirmed absence of one")

        var extracted = false
        XCTAssertEqual(
            TextSelectionService.shared.getSelectedText(
                from: self.unusedAXElement,
                confirmedNoSelection: &extracted,
                readAttribute: self.axReader(
                    selectedRange: (.success, try self.axRange(3, 5)),
                    fullValue: (.success, "0123456789" as CFTypeRef)
                )
            ),
            "34567",
            "An in-bounds range is extracted from the element's full value"
        )
        XCTAssertFalse(extracted, "A real selection is not a confirmed absence of one")

        var outOfBounds = false
        XCTAssertNil(
            TextSelectionService.shared.getSelectedText(
                from: self.unusedAXElement,
                confirmedNoSelection: &outOfBounds,
                readAttribute: self.axReader(
                    selectedRange: (.success, try self.axRange(8, 5)),
                    fullValue: (.success, "0123456789" as CFTypeRef)
                )
            ),
            "A range past the end of the value must not be extracted"
        )
        XCTAssertFalse(outOfBounds, "An out-of-bounds range is not a caret")
    }
}
