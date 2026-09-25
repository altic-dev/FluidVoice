// Existing end-to-end fixture suite is kept together to share its setup and helpers.
// swiftlint:disable file_length
import AppKit
@testable import FluidVoice_Debug
import Foundation
import SwiftUI
#if arch(arm64)
import FluidAudio
#endif
import XCTest

@MainActor
// swiftlint:disable:next type_body_length
final class DictationE2ETests: XCTestCase {
    // Pronunciation features are opt-in in the app; these tests exercise the enabled paths.
    private var priorSharedFeaturesFlag: Any?

    override func setUp() {
        super.setUp()
        self.priorSharedFeaturesFlag = UserDefaults.standard.object(forKey: "DictionarySharedFeatureMatcherEnabled")
        UserDefaults.standard.set(true, forKey: "DictionarySharedFeatureMatcherEnabled")
    }

    override func tearDown() {
        UserDefaults.standard.set(self.priorSharedFeaturesFlag, forKey: "DictionarySharedFeatureMatcherEnabled")
        super.tearDown()
    }

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
    private let rewriteModeLinkedToGlobalKey = "RewriteModeLinkedToGlobal"
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
    private let verifiedPrivateAIModelFingerprintsKey = "VerifiedPrivateAIModelFingerprints"

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

    func testTranscriptionHistoryEntryRoundTripPreservesProcessingTimes() throws {
        let entry = TranscriptionHistoryEntry(
            rawText: "raw",
            processedText: "clean",
            appName: "Notes",
            windowTitle: "Draft",
            wasAIProcessed: true,
            transcriptionDurationMilliseconds: 272,
            parakeetProcessingDurationMilliseconds: 47,
            aiProcessingDurationMilliseconds: 181,
            aiTokensPerSecond: 987.7
        )

        let decoded = try JSONDecoder().decode(
            TranscriptionHistoryEntry.self,
            from: JSONEncoder().encode(entry)
        )

        XCTAssertEqual(decoded.transcriptionDurationMilliseconds, 272)
        XCTAssertEqual(decoded.parakeetProcessingDurationMilliseconds, 47)
        XCTAssertEqual(decoded.aiProcessingDurationMilliseconds, 181)
        XCTAssertEqual(decoded.aiTokensPerSecond, 987.7)
    }

    func testOlderTranscriptionHistoryEntryWithoutProcessingTimesStillDecodes() throws {
        struct LegacyEntry: Encodable {
            let id = UUID()
            let timestamp = Date(timeIntervalSince1970: 1000)
            let rawText = "raw"
            let processedText = "clean"
            let appName = "Notes"
            let windowTitle = "Draft"
            let characterCount = 5
            let wasAIProcessed = true
            let processingModel: String? = "fluid-1"
            let aiProcessingError: String? = nil
            let audio: DictationAudioMetadata? = nil
        }

        let decoded = try JSONDecoder().decode(
            TranscriptionHistoryEntry.self,
            from: JSONEncoder().encode(LegacyEntry())
        )

        XCTAssertNil(decoded.transcriptionDurationMilliseconds)
        XCTAssertNil(decoded.parakeetProcessingDurationMilliseconds)
        XCTAssertNil(decoded.aiProcessingDurationMilliseconds)
        XCTAssertNil(decoded.aiTokensPerSecond)
    }

    func testASRResultKeepsParakeetProcessingTimeSeparate() {
        let parakeet = ASRTranscriptionResult(
            text: "hello",
            parakeetProcessingDurationMilliseconds: 47
        )
        let anotherProvider = ASRTranscriptionResult(text: "hello")

        XCTAssertEqual(parakeet.parakeetProcessingDurationMilliseconds, 47)
        XCTAssertNil(anotherProvider.parakeetProcessingDurationMilliseconds)
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
}

extension DictationE2ETests {
    func testDictionaryPlaygroundRendersWithoutStartingCaptureOrChangingWords() async throws {
        let entries = SettingsStore.shared.customDictionaryEntries
        var actions = 0
        for width in [420.0, 640.0] {
            for scheme in [ColorScheme.dark, .light] {
                let view = DictionaryWordPlayground(word: "FluidVoice", onPracticeMore: { actions += 1 }, busy: .constant(false))
                    .padding(24)
                    .frame(width: width, height: 560, alignment: .top)
                    .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
                    .appTheme(.adaptive(accent: FluidBrandColors.blue, colorScheme: scheme))
                    .environment(\.colorScheme, scheme)
                    .environmentObject(AppServices.shared)
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.orderFrontRegardless()
                try await Task.sleep(for: .milliseconds(200))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "/tmp/dictionary-playground-\(Int(width))-\(scheme).png"))
                window.orderOut(nil)
            }
        }
        XCTAssertEqual(actions, 0)
        XCTAssertEqual(SettingsStore.shared.customDictionaryEntries, entries)
    }

    func testDictionaryRingAudioResponseIsBoundedAndGeometryStaysInsideItsFrame() {
        XCTAssertEqual(DictionaryRingResponse.energy(for: 0), 0)
        XCTAssertEqual(DictionaryRingResponse.energy(for: -1), 0)
        XCTAssertEqual(DictionaryRingResponse.energy(for: .nan), 0)
        XCTAssertEqual(DictionaryRingResponse.energy(for: .infinity), 0)
        XCTAssertEqual(DictionaryRingResponse.energy(for: 2), 1)
        XCTAssertGreaterThan(DictionaryRingResponse.energy(for: 0.7), DictionaryRingResponse.energy(for: 0.1))
        for size in [176.0, 240.0] {
            let frame = CGRect(x: 0, y: 0, width: size, height: size)
            for tick in 0..<32 {
                let phase = Double(tick) / 32 * .pi * 2
                for sheet in 0..<DictionaryRibbon.sheets {
                    for strand in -4...4 {
                        let quiet = DictionaryRibbon(phase: phase, strand: Double(strand), energy: 0, sheet: sheet).path(in: frame)
                        let speech = DictionaryRibbon(phase: phase, strand: Double(strand), energy: 1, sheet: sheet).path(in: frame)
                        XCTAssertNotEqual(quiet, speech)
                        XCTAssertTrue(frame.contains(speech.boundingRect), "Speech motion must not clip")
                    }
                }
            }
        }
    }

    func testDictionaryPlaygroundMatchesWholeWordsWithoutTreatingSimilarWordsAsSuccess() {
        XCTAssertTrue(DictionaryWordTestResult.containsWord("FluidVoice", in: "I use FluidVoice."))
        XCTAssertTrue(DictionaryWordTestResult.containsWord("ChatGPT", in: "Try chatgpt!"))
        XCTAssertTrue(DictionaryWordTestResult.containsWord("C++", in: "I write C++."))
        XCTAssertTrue(DictionaryWordTestResult.containsWord("New York", in: "Visit New York."))
        XCTAssertFalse(DictionaryWordTestResult.containsWord("cat", in: "The category changed."))
        XCTAssertFalse(DictionaryWordTestResult.containsWord("ChatGPT", in: "Chat GPT"))
        XCTAssertFalse(DictionaryWordTestResult.containsWord("", in: "Anything"))
        XCTAssertFalse(DictionaryWordTestResult.containsWord("FluidVoice", in: ""))
    }

    func testDictionaryPlaygroundDoesNotChangeStateWithoutDictionaryCapture() async {
        let asr = ASRService()
        asr.finalText = "Existing output"
        let entries = SettingsStore.shared.customDictionaryEntries
        let result = await asr.stop(forDictionaryTesting: true)
        XCTAssertEqual(result, "")
        XCTAssertEqual(asr.finalText, "Existing output")
        XCTAssertNil(asr.dictionaryCaptureToken)
        XCTAssertEqual(SettingsStore.shared.customDictionaryEntries, entries)
        XCTAssertFalse(asr.isRunning)
    }

    func testDictionaryTrainingRejectsOversizedResponsesButAllowsSplitWordsAndPhrases() {
        XCTAssertTrue(CustomDictionaryTrainingMerge.isOversizedResponse("The word I want you to learn is FluidVoice", intendedReplacement: "FluidVoice"))
        XCTAssertFalse(CustomDictionaryTrainingMerge.isOversizedResponse("you for bee", intendedReplacement: "U4B"))
        XCTAssertFalse(CustomDictionaryTrainingMerge.isOversizedResponse("fluid boys", intendedReplacement: "FluidVoice"))
        XCTAssertFalse(CustomDictionaryTrainingMerge.isOversizedResponse("University of California at Los Angeles", intendedReplacement: "University of California at Los Angeles"))
        XCTAssertFalse(CustomDictionaryTrainingMerge.isOversizedResponse("", intendedReplacement: "FluidVoice"))
    }

    func testDictionaryTrainingNormalizesSamplesAndIgnoresIntendedText() {
        let triggers = CustomDictionaryTrainingMerge.normalizedTriggers(
            from: [" Fluid Voice. ", "FluidVoice", "fluid voice", " "],
            intendedReplacement: "FluidVoice"
        )

        XCTAssertEqual(triggers, ["fluid voice"])
    }

    func testPronunciationTrainingCanSaveAlreadyCorrectWordWithoutInventingMisheardAliases() async throws {
        let untouched = SettingsStore.CustomDictionaryEntry(triggers: ["other phrase"], replacement: "Other")
        let entries = CustomDictionaryTrainingMerge.mergedEntries(
            current: [untouched], replacement: "Barath", triggers: [], savePronunciation: true
        )
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.replacement, "Barath")
        XCTAssertEqual(entry.triggers, ["barath"])
        XCTAssertEqual(entries.last, untouched)

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("Pronunciation-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = PronunciationDictionaryStore(fileURL: fileURL)
        let enrollments = (0..<3).map { _ in
            PronunciationEnrollmentCapture(values: [1, 0], sourceFrameCount: 3, modelKey: "parakeet-v3")
        }
        try await store.upsert(dictionaryEntryID: entry.id, label: entry.replacement, modelKey: "parakeet-v3", enrollments: enrollments)
        let restored = await PronunciationDictionaryStore(fileURL: fileURL).allProfiles()
        XCTAssertEqual(restored.first?.dictionaryEntryID, entry.id)
        XCTAssertEqual(restored.first?.enrollments.count, 3)
        XCTAssertEqual(restored.first?.label, "Barath")
    }

    func testBasicTrainingAlreadyCorrectWordStillDoesNotCreateReplacement() {
        let entry = SettingsStore.CustomDictionaryEntry(triggers: ["other phrase"], replacement: "Other")
        XCTAssertEqual(
            CustomDictionaryTrainingMerge.mergedEntries(current: [entry], replacement: "Barath", triggers: []),
            [entry]
        )
        XCTAssertEqual(
            CustomDictionaryTrainingMerge.mergedEntries(current: [entry], replacement: " ", triggers: [], savePronunciation: true),
            [entry]
        )
    }

    func testPronunciationOnlyRetrainingKeepsExistingIdentityAndCorrections() {
        let entry = SettingsStore.CustomDictionaryEntry(triggers: ["bar at"], replacement: "Barath")
        let entries = CustomDictionaryTrainingMerge.mergedEntries(
            current: [entry], replacement: "Barath", triggers: [], savePronunciation: true
        )
        XCTAssertEqual(entries, [entry])
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
            replacement: " FluidVoice ",
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

    func testDictionaryTrainingPreservesCapitalizationCorrection() {
        let entries = CustomDictionaryTrainingMerge.mergedEntries(
            current: [],
            replacement: "DFlash",
            triggers: ["Dflash"]
        )

        XCTAssertEqual(entries.first?.replacement, "DFlash")
        XCTAssertEqual(entries.first?.triggers, ["dflash"])
    }

    func testDictionaryTrainingUpdatesExistingReplacementCapitalization() {
        let existing = SettingsStore.CustomDictionaryEntry(
            triggers: ["d flash"],
            replacement: "Dflash"
        )

        let entries = CustomDictionaryTrainingMerge.mergedEntries(
            current: [existing],
            replacement: "DFlash",
            triggers: ["Dflash"]
        )

        XCTAssertEqual(entries.first?.id, existing.id)
        XCTAssertEqual(entries.first?.replacement, "DFlash")
        XCTAssertEqual(Set(entries.first?.triggers ?? []), Set(["d flash", "dflash"]))
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

    #if arch(arm64)
    func testLongPronunciationMatchesDeduplicateOverlapAndKeepRepeatedWords() {
        let id = UUID()
        let profile = PronunciationDictionaryProfile(dictionaryEntryID: id, label: "old", modelKey: "v3", hiddenSize: 1, enrollments: [])
        let result = ASRResult(text: "fluid voice and fluid voice", confidence: 1, duration: 120, processingTime: 0, tokenTimings: [
            TokenTiming(token: "▁fluid", tokenId: 1, startTime: 13, endTime: 13.3, confidence: 1),
            TokenTiming(token: "▁voice", tokenId: 2, startTime: 13.3, endTime: 13.6, confidence: 1),
            TokenTiming(token: "▁and", tokenId: 3, startTime: 14, endTime: 14.3, confidence: 1),
            TokenTiming(token: "▁fluid", tokenId: 1, startTime: 110, endTime: 110.3, confidence: 1),
            TokenTiming(token: "▁voice", tokenId: 2, startTime: 110.3, endTime: 110.6, confidence: 1),
        ])
        let hits = [
            PronunciationWindowMatch(prototypeIndex: 0, score: 0.9, frameRange: 162..<170),
            PronunciationWindowMatch(prototypeIndex: 0, score: 0.8, frameRange: 161..<171),
            PronunciationWindowMatch(prototypeIndex: 0, score: 0.9, frameRange: 1375..<1383),
        ]
        XCTAssertEqual(FluidAudioProvider.applyPronunciationMatches(result: result, matches: hits, profiles: [profile], labels: [id: "FluidVoice"]), "FluidVoice and FluidVoice")
        // Deleted dictionary entries and low-confidence hits leave speech untouched.
        XCTAssertEqual(FluidAudioProvider.applyPronunciationMatches(result: result, matches: hits, profiles: [profile], labels: [:]), result.text)
        XCTAssertEqual(
            FluidAudioProvider
                .applyPronunciationMatches(
                    result: result,
                    matches: [PronunciationWindowMatch(prototypeIndex: 0, score: 0.1, frameRange: 162..<170)],
                    profiles: [profile],
                    labels: [id: "FluidVoice"]
                ),
            result.text
        )
        XCTAssertEqual(
            FluidAudioProvider
                .applyPronunciationMatches(
                    result: result,
                    matches: [PronunciationWindowMatch(prototypeIndex: 99, score: 1, frameRange: 162..<170)],
                    profiles: [profile],
                    labels: [id: "FluidVoice"]
                ),
            result.text
        )
    }

    func testPronunciationStreamingTwoMinuteRealAudio() async throws {
        guard let path = ProcessInfo.processInfo.environment["FLUIDVOICE_PRONUNCIATION_AUDIO"] else {
            throw XCTSkip("Set FLUIDVOICE_PRONUNCIATION_AUDIO to the public real-speech fixture")
        }
        let source = try AudioConverter().resampleAudioFile(path: path)
        XCTAssertGreaterThanOrEqual(source.count, 960_000)
        // Repeat a real 60-second recording for a reproducible two-minute repeated-word fixture.
        let minute = Array(source.prefix(960_000))
        let samples = minute + minute
        let id = UUID()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pronunciation-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = PronunciationDictionaryStore(fileURL: file)
        let entry = SettingsStore.CustomDictionaryEntry(id: id, triggers: [], replacement: "TrainedWord")
        let provider = FluidAudioProvider(
            modelOverride: .parakeetTDT,
            configureWordBoosting: false,
            enhancementOptions: FluidAudioProviderEnhancementOptions(experimentalUnifiedFinalEnabled: false, pronunciationMatchingEnabled: true, customDictionaryEntries: [entry]),
            pronunciationStore: store
        )
        try await provider.prepare()
        let training = try await provider.transcribeDictionaryTraining(Array(minute.prefix(32_000)))
        let capture = try XCTUnwrap(training.pronunciationEnrollment)
        try await store.upsert(dictionaryEntryID: id, label: entry.replacement, modelKey: capture.modelKey, enrollments: [capture, capture, capture])
        var fullTimes: [Double] = []
        var stopTimes: [Double] = []
        for run in 0..<4 {
            provider.resetStreamingPreviewCache()
            let batchStart = Date()
            let batch = try await provider.transcribeFinal(samples)
            let batchMs = Date().timeIntervalSince(batchStart) * 1000
            provider.resetStreamingPreviewCache()
            for end in stride(from: 32_000, through: samples.count - 32_000, by: 32_000) {
                if let start = provider.incrementalPreviewDeltaStart(totalSampleCount: end) {
                    _ = try await provider.transcribeStreamingDelta(Array(samples[start..<end]), totalSampleCount: end)
                } else {
                    _ = try await provider.transcribeStreaming(Array(samples.prefix(end)))
                }
            }
            let stop = Date()
            let streamed = try await provider.transcribeFinal(samples)
            let stopMs = Date().timeIntervalSince(stop) * 1000
            XCTAssertEqual(streamed.text, batch.text, "Feed cadence must not change final corrections")
            XCTAssertTrue(streamed.text.contains("TrainedWord"))
            if run > 0 { fullTimes.append(batchMs); stopTimes.append(stopMs) }
        }
        print("PRONUNCIATION_TWO_MINUTE batchMs=\(fullTimes) stopMs=\(stopTimes)")
        // A reset during suspended model work must prevent the old recording from publishing.
        provider.resetStreamingPreviewCache()
        let entered = expectation(description: "Old preview entered")
        let old = Task {
            entered.fulfill()
            return try await provider.transcribeStreaming(samples)
        }
        await fulfillment(of: [entered], timeout: 5)
        provider.resetStreamingPreviewCache()
        do { _ = try await old.value; XCTFail("Stale preview was accepted") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertNil(provider.incrementalPreviewDeltaStart(totalSampleCount: samples.count))
    }
    #endif

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

    func testAutomaticDictionaryCorrectionDetectsCaseOnlyEdit() {
        let before = "Use Dflash today"
        let after = "Use DFlash today"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)

        let candidate = AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        )

        XCTAssertEqual(candidate?.heardText, "Dflash")
        XCTAssertEqual(candidate?.correctedText, "DFlash")
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
        let configuration = DictionarySuggestionPolicyConfig()
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

    func testAutomaticDictionarySuggestionAllowsImmediateDifferentCorrection() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.requiredOccurrences = 1
        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        let first = AutomaticDictionaryCorrectionCandidate(heardText: "Claud", correctedText: "Claude")
        let second = AutomaticDictionaryCorrectionCandidate(heardText: "cloud", correctedText: "Claude")
        let now = Date(timeIntervalSince1970: 3500)

        XCTAssertTrue(policy.shouldShow(first, now: now))
        policy.markShown(first, now: now)
        XCTAssertTrue(policy.shouldShow(second, now: now.addingTimeInterval(30)))
    }

    func testAutomaticDictionarySuggestionStopsAfterSessionIgnoreLimit() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.requiredOccurrences = 1
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
        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        let candidate = AutomaticDictionaryCorrectionCandidate(heardText: "Barad", correctedText: "Barath")
        let now = Date(timeIntervalSince1970: 5000)

        XCTAssertTrue(policy.shouldShow(candidate, now: now))
        policy.record(.accepted, for: candidate, now: now)
        XCTAssertFalse(policy.shouldShow(candidate, now: now.addingTimeInterval(10_000)))
    }

    func testAutomaticDictionarySuggestionDismissalRemainsTemporary() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.requiredOccurrences = 1
        configuration.dismissedPairCooldown = 0
        configuration.maximumSessionIgnores = 10
        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        let candidate = AutomaticDictionaryCorrectionCandidate(heardText: "Barad", correctedText: "Barath")
        let now = Date(timeIntervalSince1970: 6000)

        for index in 0..<4 {
            let date = now.addingTimeInterval(Double(index))
            XCTAssertTrue(policy.shouldShow(candidate, now: date))
            policy.record(.dismissed, for: candidate, now: date)
        }
        XCTAssertTrue(policy.shouldShow(candidate, now: now.addingTimeInterval(10)))
    }

    func testAutomaticDictionarySuggestionCountsDifferentMishearingsForSameCorrection() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        let configuration = DictionarySuggestionPolicyConfig()
        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        let now = Date(timeIntervalSince1970: 7000)

        XCTAssertFalse(policy.shouldShow(
            .init(heardText: "Barad", correctedText: "Barath"),
            requiredOccurrences: 2,
            now: now
        ))
        XCTAssertTrue(policy.shouldShow(
            .init(heardText: "Bharat", correctedText: "Barath"),
            requiredOccurrences: 2,
            now: now.addingTimeInterval(10)
        ))
    }

    func testAutomaticDictionarySuggestionIgnoreOnlySuppressesExactCorrection() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.requiredOccurrences = 1
        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        let ignored = AutomaticDictionaryCorrectionCandidate(heardText: "Barad", correctedText: "Barath")
        let alternative = AutomaticDictionaryCorrectionCandidate(heardText: "Bharat", correctedText: "Barath")
        let now = Date(timeIntervalSince1970: 8000)

        XCTAssertTrue(policy.shouldShow(ignored, now: now))
        policy.record(.ignored, for: ignored, now: now)
        XCTAssertFalse(policy.shouldShow(ignored, now: now.addingTimeInterval(10)))
        XCTAssertTrue(policy.shouldShow(alternative, now: now.addingTimeInterval(20)))
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

        let provider = WhisperProvider(modelDirectory: modelDirectory, modelOverride: .whisperTiny, languageCodeOverride: "en")

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

    func testPromptTestConfigurationUsesDraftProviderInsteadOfGlobalProvider() {
        self.withRestoredDefaults(keys: [self.selectedProviderIDKey, self.verifiedProviderFingerprintsKey]) {
            let settings = SettingsStore.shared
            let baseURL = ModelRepository.shared.defaultBaseURL(for: "ollama")
            settings.selectedProviderID = PrivateAIProviderFeature.shared.providerID
            settings.verifiedProviderFingerprints = [
                "ollama": DictationAIPostProcessingGate.providerFingerprint(baseURL: baseURL, apiKey: "") ?? "",
            ]

            XCTAssertTrue(
                DictationAIPostProcessingGate.isProviderConfigured(
                    providerID: "ollama",
                    model: "draft-model"
                )
            )
            XCTAssertFalse(
                DictationAIPostProcessingGate.isProviderConfigured(
                    providerID: "openai",
                    model: "draft-model"
                )
            )
        }
    }

    func testActivePromptTestTracksDraftProviderChanges() {
        let coordinator = DictationPromptTestCoordinator.shared
        defer { coordinator.deactivate() }
        coordinator.activate(draftPromptText: "Polish", providerID: "ollama", model: "first")

        coordinator.updateDraftConfiguration(providerID: "openai", model: "second")

        XCTAssertEqual(coordinator.draftProviderID, "openai")
        XCTAssertEqual(coordinator.draftModel, "second")
    }

    func testLMStudioCleanupRouteIsIndependentOfFluidIntelligenceProviderState() {
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
            let lmStudioModel = "local-cleanup-model"
            let globalProviderID = PrivateFeatures.privateAIProvider
                ? PrivateAIProviderFeature.shared.providerID
                : "openai"
            settings.selectedProviderID = globalProviderID
            settings.selectedModelByProvider = [
                globalProviderID: PrivateFeatures.privateAIProvider
                    ? PrivateAIIntegrationService.configuredModelID
                    : "gpt-4.1",
                "lmstudio": lmStudioModel,
            ]
            settings.setDictationPromptSelection(.default, for: .primary)
            settings.setDictationPromptConfiguration(
                SettingsStore.DictationPromptConfiguration(
                    providerID: "lmstudio",
                    modelName: lmStudioModel
                ),
                for: .default
            )
            settings.verifiedProviderFingerprints = [:]

            let route = DictationProviderRoute.resolve(settings: settings, dictationSlot: .primary)

            XCTAssertEqual(route.providerID, "lmstudio")
            XCTAssertEqual(route.model, lmStudioModel)
            XCTAssertFalse(route.usesPrivateAI)
            XCTAssertFalse(DictationAIPostProcessingGate.isConfigured(for: .primary))

            settings.verifiedProviderFingerprints = [
                "lmstudio": DictationAIPostProcessingGate.providerFingerprint(
                    baseURL: route.baseURL,
                    apiKey: route.apiKey
                ) ?? "",
            ]

            XCTAssertTrue(DictationAIPostProcessingGate.isConfigured(for: .primary))
            XCTAssertEqual(settings.selectedProviderID, globalProviderID)
        }
    }

    func testExternalCleanupDoesNotInheritFluidIntelligenceProvider() {
        XCTAssertEqual(
            DictationProviderRoute.externalFallbackProviderID(
                from: PrivateAIProviderFeature.shared.providerID
            ),
            ""
        )
        XCTAssertEqual(
            DictationProviderRoute.externalFallbackProviderID(from: "lmstudio"),
            "lmstudio"
        )
    }

    func testResettingDefaultCleanupConfigurationRemovesStaleProviderAndModel() {
        self.withRestoredDefaults(keys: [self.dictationPromptConfigurationsKey]) {
            let settings = SettingsStore.shared
            settings.setDictationPromptConfiguration(
                SettingsStore.DictationPromptConfiguration(
                    shortcut: HotkeyShortcut(keyCode: 3, modifierFlags: [.option]),
                    providerID: "lmstudio",
                    modelName: "removed-model"
                ),
                for: .default
            )

            settings.removeDictationPromptConfiguration(for: .default)

            XCTAssertEqual(
                settings.dictationPromptConfiguration(for: .default),
                SettingsStore.DictationPromptConfiguration()
            )
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

    func testFluidIntelligenceSelectionSupportsAppOverride() {
        XCTAssertTrue(SettingsStore.dictationSelectionSupportsAppOverride(.privateAI))
        XCTAssertTrue(SettingsStore.dictationSelectionSupportsAppOverride(.default))
        XCTAssertFalse(SettingsStore.dictationSelectionSupportsAppOverride(.profile("global")))
        XCTAssertFalse(SettingsStore.dictationSelectionSupportsAppOverride(.off))
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

    func testEditModelResolutionPreservesConfiguredLocalProviderModel() {
        self.withRestoredDefaults(
            keys: [
                self.savedProvidersKey,
                self.availableModelsByProviderKey,
                self.selectedModelByProviderKey,
                self.selectedProviderIDKey,
                self.rewriteModeLinkedToGlobalKey,
            ]
        ) {
            let settings = SettingsStore.shared
            settings.rewriteModeLinkedToGlobal = true
            settings.selectedProviderID = "lmstudio"
            settings.availableModelsByProvider = ["lmstudio": ["local-edit-model"]]
            settings.selectedModelByProvider = ["lmstudio": "local-edit-model"]

            XCTAssertEqual(settings.availableModels(for: "lmstudio", task: .edit), ["local-edit-model"])
            XCTAssertEqual(settings.effectiveRewriteModeProviderID, "lmstudio")
            XCTAssertEqual(settings.effectiveRewriteModeSelectedModel, "local-edit-model")
        }
    }

    func testEditAnalyticsReportsResolvedEditModel() {
        self.withRestoredDefaults(
            keys: [
                self.availableModelsByProviderKey,
                self.rewriteModeLinkedToGlobalKey,
                self.rewriteModeSelectedProviderIDKey,
                self.rewriteModeSelectedModelKey,
            ]
        ) {
            let settings = SettingsStore.shared
            settings.rewriteModeLinkedToGlobal = false
            settings.rewriteModeSelectedProviderID = "ollama"
            settings.availableModelsByProvider = ["ollama": ["edit-model", "other-model"]]
            settings.rewriteModeSelectedModel = "edit-model"

            XCTAssertEqual(settings.effectiveRewriteModeSelectedModel, "edit-model")
            XCTAssertEqual(
                settings.analyticsAIModelDescriptor(for: .edit),
                AnalyticsModelDescriptor(provider: "ollama", model: "edit-model")
            )
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
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .profile(custom.id))

            settings.setDictationPromptSelection(.off)
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .off)

            settings.selectedProviderID = "openai"
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .off)

            settings.setDictationPromptSelection(.profile(custom.id))
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .profile(custom.id))
        }
    }

    func testPrivateAIProviderSelectionDoesNotOverrideCleanupStyle() {
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
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .default)

            settings.setDictationPromptSelection(.profile(custom.id))
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .profile(custom.id))

            settings.setDictationPromptSelection(.off)
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .off)
            XCTAssertEqual(settings.dictationPromptDisplayName(for: .primary, appBundleID: nil), "Basic")

            settings.selectedProviderID = "openai"
            settings.setDictationPromptSelection(.profile(custom.id))
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .profile(custom.id))
        }
    }

    func testPrivateAIVerificationStateDoesNotReplaceExternalCleanupRoute() {
        self.withPromptAndProviderSettingsRestored {
            let settings = SettingsStore.shared
            let privateProviderID = PrivateAIProviderFeature.shared.providerID
            let privateModelID = PrivateAIProviderFeature.shared.defaultModelID
            settings.selectedProviderID = "openai"
            settings.selectedModelByProvider = [
                "openai": "gpt-4.1",
                privateProviderID: privateModelID,
            ]
            settings.verifiedProviderFingerprints = [
                privateProviderID: "private-model-fingerprint",
            ]
            settings.verifiedPrivateAIModelFingerprints = [
                privateModelID: "private-model-fingerprint",
            ]
            settings.setDictationPromptSelection(.default)

            let route = DictationProviderRoute.resolveForPostProcessing(
                settings: settings,
                dictationSlot: .primary
            )

            XCTAssertEqual(settings.selectedProviderID, "openai")
            XCTAssertEqual(route.providerID, "openai")
            XCTAssertEqual(route.model, "gpt-4.1")
        }
    }

    func testOpeningProviderConfigurationDoesNotChangeDefaultProvider() {
        self.withRestoredDefaults(keys: [self.selectedProviderIDKey]) {
            let settings = SettingsStore.shared
            settings.selectedProviderID = "openai"
            let viewModel = AIEnhancementSettingsViewModel(
                settings: settings,
                menuBarManager: MenuBarManager(),
                promptTest: .shared
            )

            viewModel.configureProvider("lmstudio")
            viewModel.saveSavedProviders()
            viewModel.cachedVerifiedProviderItems = [
                .init(id: "openai", name: "OpenAI", isBuiltIn: true),
                .init(id: "lmstudio", name: "LM Studio", isBuiltIn: true),
            ]

            XCTAssertEqual(viewModel.selectedProviderID, "lmstudio")
            XCTAssertEqual(settings.selectedProviderID, "openai")
            XCTAssertEqual(viewModel.defaultVerifiedPromptProviderID(), "openai")

            viewModel.finishConfiguringProvider()
            XCTAssertEqual(viewModel.selectedProviderID, "openai")
            XCTAssertEqual(settings.selectedProviderID, "openai")
        }
    }

    func testLegacyFluidIntelligenceDefaultUsesPrivateRouteOnlyWithoutExplicitConfiguration() {
        let providerID = PrivateAIProviderFeature.shared.providerID

        XCTAssertTrue(
            DictationProviderRoute.shouldUseLegacyPrivateAIRoute(
                selectedProviderID: providerID,
                configuredProviderID: "",
                configuredModel: ""
            )
        )
        XCTAssertFalse(
            DictationProviderRoute.shouldUseLegacyPrivateAIRoute(
                selectedProviderID: providerID,
                configuredProviderID: "lmstudio",
                configuredModel: "local-model"
            )
        )
        XCTAssertTrue(
            DictationProviderRoute.allowsPrivateAIRoute(
                selection: .default,
                selectedProviderID: providerID
            )
        )
        XCTAssertFalse(
            DictationProviderRoute.allowsPrivateAIRoute(
                selection: .profile("external"),
                selectedProviderID: providerID
            )
        )
    }

    func testExplicitExternalStyleDoesNotUseLegacyFluidIntelligenceRoute() {
        self.withPromptAndProviderSettingsRestored {
            let settings = SettingsStore.shared
            let profile = SettingsStore.DictationPromptProfile(
                name: "External",
                prompt: "Polish this",
                mode: .dictate
            )
            settings.dictationPromptProfiles = [profile]
            settings.selectedProviderID = PrivateAIProviderFeature.shared.providerID
            settings.setDictationPromptSelection(.profile(profile.id))

            let route = DictationProviderRoute.resolve(
                settings: settings,
                dictationSlot: .primary
            )

            XCTAssertFalse(route.usesPrivateAI)
            XCTAssertTrue(route.providerID.isEmpty)
        }
    }

    func testAppDefaultOverrideDoesNotUseLegacyFluidIntelligenceRoute() {
        self.withPromptAndProviderSettingsRestored {
            let settings = SettingsStore.shared
            let appBundleID = "com.example.editor"
            settings.appPromptBindings = [
                SettingsStore.AppPromptBinding(
                    mode: .dictate,
                    appBundleID: appBundleID,
                    appName: "Editor",
                    promptID: nil
                ),
            ]
            settings.selectedProviderID = PrivateAIProviderFeature.shared.providerID
            settings.setDictationPromptSelection(.default)

            let route = DictationProviderRoute.resolve(
                settings: settings,
                dictationSlot: .primary,
                appBundleID: appBundleID
            )

            XCTAssertFalse(route.usesPrivateAI)
            XCTAssertTrue(route.providerID.isEmpty)
        }
    }

    func testCreatingAndDeletingProviderDraftPreservesDefaultProvider() {
        self.withProviderSettingsRestored {
            let settings = SettingsStore.shared
            settings.selectedProviderID = "openai"
            let viewModel = AIEnhancementSettingsViewModel(
                settings: settings,
                menuBarManager: MenuBarManager(),
                promptTest: .shared
            )

            XCTAssertNotNil(viewModel.createDraftProvider(named: "Draft"))
            XCTAssertEqual(settings.selectedProviderID, "openai")

            viewModel.deleteCurrentProvider()
            XCTAssertEqual(viewModel.selectedProviderID, "openai")
            XCTAssertEqual(settings.selectedProviderID, "openai")
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

    func testTerminalServiceExecute_largeStdoutIsNotTruncatedAndReturnsQuickly() async {
        // Regression for a pipe-buffer deadlock: execute() used to call
        // waitUntilExit() before draining stdout, so a command writing more than
        // the ~64KB pipe buffer blocked on write() until the 30s timeout fired,
        // returning truncated output with success == false. Draining stdout and
        // stderr concurrently lets the command run to completion. The output
        // is large enough to exceed the pipe buffer but small enough to stay
        // under TerminalService's captured-output cap.
        let service = TerminalService()
        let lineCount = 100_000

        let result = await service.execute(command: "seq 1 \(lineCount)")

        XCTAssertTrue(result.success, "Expected success, got exitCode \(result.exitCode) error \(result.error ?? "nil")")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThan(result.output.utf8.count, 64 * 1024, "Output should exceed the 64KB pipe buffer")
        XCTAssertTrue(result.output.hasSuffix("\(lineCount)"), "Last line should be complete, output was truncated")
        XCTAssertFalse(result.output.contains("truncated after"))
        XCTAssertEqual(result.output.split(separator: "\n").count, lineCount)
        XCTAssertLessThan(result.executionTimeMs, 15000, "Should return promptly, not after the ~30s timeout")
    }

    func testTerminalServiceExecute_largeStderrIsNotTruncated() async throws {
        // The same deadlock applied to stderr; both pipes must be drained concurrently.
        let service = TerminalService()
        let lineCount = 100_000

        let result = await service.execute(command: "seq 1 \(lineCount) 1>&2")

        XCTAssertTrue(result.success, "Expected success, got exitCode \(result.exitCode)")
        let stderr = try XCTUnwrap(result.error)
        XCTAssertGreaterThan(stderr.utf8.count, 64 * 1024, "Stderr should exceed the 64KB pipe buffer")
        XCTAssertTrue(stderr.hasSuffix("\(lineCount)"), "Last stderr line should be complete, output was truncated")
        XCTAssertFalse(stderr.contains("truncated after"))
        XCTAssertLessThan(result.executionTimeMs, 15000, "Should return promptly, not after the ~30s timeout")
    }

    func testTerminalServiceExecute_largeStdoutCaptureIsBoundedAndMarked() async {
        let service = TerminalService()
        let requestedBytes = TerminalService.maxCapturedOutputBytes + (128 * 1024)

        let result = await service.execute(command: "yes stdout | head -c \(requestedBytes)")

        XCTAssertTrue(result.success, "Expected success, got exitCode \(result.exitCode) error \(result.error ?? "nil")")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(
            result.output.contains("[stdout truncated after \(TerminalService.maxCapturedOutputBytes) bytes]"),
            "Expected stdout truncation notice"
        )
        XCTAssertLessThan(
            result.output.utf8.count,
            TerminalService.maxCapturedOutputBytes + 128,
            "Captured stdout should stay close to the configured cap"
        )
        XCTAssertLessThan(result.executionTimeMs, 15000, "Should drain without waiting for timeout")
    }

    func testTerminalServiceExecute_largeStderrCaptureIsBoundedAndMarked() async throws {
        let service = TerminalService()
        let requestedBytes = TerminalService.maxCapturedOutputBytes + (128 * 1024)

        let result = await service.execute(command: "yes stderr | head -c \(requestedBytes) 1>&2")

        XCTAssertTrue(result.success, "Expected success, got exitCode \(result.exitCode)")
        let stderr = try XCTUnwrap(result.error)
        XCTAssertTrue(
            stderr.contains("[stderr truncated after \(TerminalService.maxCapturedOutputBytes) bytes]"),
            "Expected stderr truncation notice"
        )
        XCTAssertLessThan(
            stderr.utf8.count,
            TerminalService.maxCapturedOutputBytes + 128,
            "Captured stderr should stay close to the configured cap"
        )
        XCTAssertLessThan(result.executionTimeMs, 15000, "Should drain without waiting for timeout")
    }

    func testTerminalServiceExecute_multibyteStdoutSplitAtCapKeepsTruncationNotice() async {
        let service = TerminalService()
        let requestedBytes = TerminalService.maxCapturedOutputBytes + 64

        let result = await service.execute(command: "yes é | head -c \(requestedBytes)")

        XCTAssertTrue(result.success, "Expected success, got exitCode \(result.exitCode) error \(result.error ?? "nil")")
        XCTAssertTrue(
            result.output.contains("[stdout truncated after \(TerminalService.maxCapturedOutputBytes) bytes]"),
            "Truncation notice should survive even when the cap splits a UTF-8 scalar"
        )
        XCTAssertLessThan(
            result.output.utf8.count,
            TerminalService.maxCapturedOutputBytes + 128,
            "Captured stdout should stay close to the configured cap"
        )
    }

    func testTerminalServiceExecute_unboundedStdoutTimesOutWithBoundedCapture() async {
        let service = TerminalService()

        let result = await service.execute(command: "yes stdout", timeout: 1)

        XCTAssertFalse(result.success, "Unbounded command should be terminated by timeout")
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(
            result.output.contains("[stdout truncated after \(TerminalService.maxCapturedOutputBytes) bytes]"),
            "Expected stdout truncation notice"
        )
        XCTAssertLessThan(
            result.output.utf8.count,
            TerminalService.maxCapturedOutputBytes + 128,
            "Captured stdout should stay close to the configured cap"
        )
        XCTAssertLessThan(result.executionTimeMs, 5000, "Should return shortly after timeout")
    }

    func testTerminalServiceExecute_unboundedStderrTimesOutWithBoundedCapture() async throws {
        let service = TerminalService()

        let result = await service.execute(command: "yes stderr 1>&2", timeout: 1)

        XCTAssertFalse(result.success, "Unbounded command should be terminated by timeout")
        XCTAssertNotEqual(result.exitCode, 0)
        let stderr = try XCTUnwrap(result.error)
        XCTAssertTrue(
            stderr.contains("[stderr truncated after \(TerminalService.maxCapturedOutputBytes) bytes]"),
            "Expected stderr truncation notice"
        )
        XCTAssertLessThan(
            stderr.utf8.count,
            TerminalService.maxCapturedOutputBytes + 128,
            "Captured stderr should stay close to the configured cap"
        )
        XCTAssertLessThan(result.executionTimeMs, 5000, "Should return shortly after timeout")
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
                self.verifiedPrivateAIModelFingerprintsKey,
                self.privateAISelectedModelIDKey,
            ],
            run: run
        )
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

        let document = try await BackupService.shared.makeBackupDocument()
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

    func testBackupKeepsDeprecatedIndependentVolumeKeyAndDecodesWithoutIt() async throws {
        let document = try await BackupService.shared.makeBackupDocument()
        let encoded = try BackupService.shared.encode(document)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var encodedSettings = try XCTUnwrap(root["settings"] as? [String: Any])
        XCTAssertEqual(encodedSettings["transcriptionSoundIndependentVolume"] as? Bool, false)

        encodedSettings.removeValue(forKey: "transcriptionSoundIndependentVolume")
        root["settings"] = encodedSettings
        let strippedBackup = try BackupService.shared.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertNil(strippedBackup.settings.transcriptionSoundIndependentVolume)
    }
}

@MainActor
final class OverlayFailureStateTests: XCTestCase {
    func testAIFailurePresentationOnlyRunsForPersistedFallbackOutput() {
        XCTAssertTrue(
            DictationAIFailurePresentationPolicy.shouldPresent(
                shouldPersistOutputs: true,
                fallbackReason: "offline"
            )
        )
        XCTAssertFalse(
            DictationAIFailurePresentationPolicy.shouldPresent(
                shouldPersistOutputs: false,
                fallbackReason: "offline"
            ),
            "Onboarding sandbox failures must not create retry UI or system notifications"
        )
        XCTAssertFalse(
            DictationAIFailurePresentationPolicy.shouldPresent(
                shouldPersistOutputs: true,
                fallbackReason: nil
            )
        )
    }

    func testConfigurationFailureNotificationPointsToProviderSetup() {
        let message = DictationAIFailurePresentationPolicy.notificationMessage(
            for: AIProcessingError.missingAPIKey(provider: "OpenAI")
        )

        XCTAssertEqual(message, "API key not set for OpenAI. Open AI Providers to configure a provider.")
    }

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

final class AudioBudgetMeasurementGateTests: XCTestCase {
    func testMeasurementRequiresMatchingRevisionAndBudget() {
        let gate = AudioBudgetMeasurementGate(revision: 7, budgetBytes: 1000)

        XCTAssertTrue(gate.accepts(currentRevision: 7, currentBudgetBytes: 1000))
        XCTAssertFalse(gate.accepts(currentRevision: 8, currentBudgetBytes: 1000))
        XCTAssertFalse(gate.accepts(currentRevision: 7, currentBudgetBytes: 2000))
    }

    func testPendingOrReferencedAudioIsNeverDeletedAsOrphan() {
        XCTAssertFalse(
            DictationAudioHistoryStore.shouldDeleteUnreferencedAudioFile(
                fileName: "pending.wav",
                referencedFileNames: [],
                pendingFileNames: ["pending.wav"]
            )
        )
        XCTAssertFalse(
            DictationAudioHistoryStore.shouldDeleteUnreferencedAudioFile(
                fileName: "saved.wav",
                referencedFileNames: ["saved.wav"],
                pendingFileNames: []
            )
        )
        XCTAssertTrue(
            DictationAudioHistoryStore.shouldDeleteUnreferencedAudioFile(
                fileName: "orphan.wav",
                referencedFileNames: [],
                pendingFileNames: []
            )
        )
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

extension DictationE2ETests {
    func testDictionaryLearningSelectsCorrectRepeatedOccurrence() throws {
        let text = "open flued voice now then open flued voice now"
        let words = text.split(separator: " ").enumerated().map { index, token in
            let start = Double(index < 5 ? index : index + 100)
            return ASRWordTiming(text: String(token), start: start, end: start + 0.4)
        }
        // Sample IDs verify copying/offsets only; this is not a speech recognition fixture.
        let samples = (0..<(120 * 16_000)).map { Float($0) }
        let now = Date(timeIntervalSince1970: 1000)
        let recording = try XCTUnwrap(DictionaryLearningRecording(
            alignment: DictionaryLearningAlignment(modelKey: "parakeet-v3", words: words), samples: samples, now: now
        ))
        let selection = (text as NSString).range(of: "flued voice", options: .backwards)
        let evidence = try DictionaryLearningAlignmentResolver.resolve(
            recording: recording,
            deliveredTextBeforeEdit: text,
            selectedUTF16Range: selection,
            observedText: "flued voice",
            now: now
        )
        XCTAssertEqual(evidence.recordingID, recording.id)
        XCTAssertEqual(evidence.sourceWordRange, 6..<8)
        XCTAssertGreaterThan(evidence.sourceSampleRange.lowerBound, 100 * 16_000)
        XCTAssertLessThanOrEqual(evidence.samples.count, 238_080)
        XCTAssertEqual(evidence.samples.first, samples[evidence.sourceSampleRange.lowerBound])
        XCTAssertEqual(evidence.sourceSampleRange.lowerBound + evidence.focalSampleRange.lowerBound, 106 * 16_000)
        XCTAssertEqual(evidence.sourceSampleRange.lowerBound + evidence.focalSampleRange.upperBound, Int(107.4 * 16_000))
    }

    func testDictionaryLearningPreservesFormattingAndRejectsAmbiguousRewrite() throws {
        let now = Date(timeIntervalSince1970: 1000)
        func receipt(_ text: String) throws -> DictionaryLearningRecording {
            let words = text.split(separator: " ").enumerated().map { index, token in
                ASRWordTiming(text: String(token), start: Double(index), end: Double(index) + 0.5)
            }
            return try XCTUnwrap(DictionaryLearningRecording(
                alignment: DictionaryLearningAlignment(modelKey: "parakeet-v3", words: words),
                samples: [Float](repeating: 0, count: 16_000 * 15),
                now: now
            ))
        }
        let formatted = "Open, FLUED VOICE now."
        let evidence = try DictionaryLearningAlignmentResolver.resolve(
            recording: receipt("open flued voice now"),
            deliveredTextBeforeEdit: formatted,
            selectedUTF16Range: (formatted as NSString).range(of: "FLUED VOICE"),
            observedText: "FLUED VOICE",
            now: now
        )
        XCTAssertEqual(evidence.sourceWordRange, 1..<3)

        let withoutFiller = "please open flued voice now thanks"
        let anchored = try DictionaryLearningAlignmentResolver.resolve(
            recording: receipt("um please open flued voice now thanks"),
            deliveredTextBeforeEdit: withoutFiller,
            selectedUTF16Range: (withoutFiller as NSString).range(of: "flued voice"),
            observedText: "flued voice",
            now: now
        )
        XCTAssertEqual(anchored.sourceWordRange, 3..<5)

        let ambiguous = "please open flued voice now"
        XCTAssertThrowsError(try DictionaryLearningAlignmentResolver.resolve(
            recording: receipt("well open flued voice now and open flued voice now"),
            deliveredTextBeforeEdit: ambiguous,
            selectedUTF16Range: (ambiguous as NSString).range(of: "flued voice"),
            observedText: "flued voice",
            now: now
        )) { XCTAssertEqual($0 as? DictionaryLearningAlignmentError, .ambiguousSource) }
        let rewritten = "please launch flued voice today"
        XCTAssertThrowsError(try DictionaryLearningAlignmentResolver.resolve(
            recording: receipt("open flued voice now"),
            deliveredTextBeforeEdit: rewritten,
            selectedUTF16Range: (rewritten as NSString).range(of: "flued voice"),
            observedText: "flued voice",
            now: now
        )) { XCTAssertEqual($0 as? DictionaryLearningAlignmentError, .ambiguousSource) }
    }

    func testDictionaryLearningRejectsExpiredAndInvalidEvidence() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let words = [ASRWordTiming(text: "hello", start: 0.1, end: 0.5)]
        let recording = try XCTUnwrap(DictionaryLearningRecording(
            alignment: DictionaryLearningAlignment(modelKey: "parakeet-v3", words: words),
            samples: [Float](repeating: 0, count: 16_000),
            now: now
        ))
        XCTAssertThrowsError(try DictionaryLearningAlignmentResolver.resolve(
            recording: recording,
            deliveredTextBeforeEdit: "hello",
            selectedUTF16Range: NSRange(location: 0, length: 5),
            observedText: "hello",
            now: recording.expiresAt
        )) { XCTAssertEqual($0 as? DictionaryLearningAlignmentError, .expired) }
        XCTAssertThrowsError(try DictionaryLearningAlignmentResolver.resolve(
            recording: recording,
            deliveredTextBeforeEdit: "hello",
            selectedUTF16Range: NSRange(location: Int.max, length: 5),
            observedText: "hello",
            now: now
        )) { XCTAssertEqual($0 as? DictionaryLearningAlignmentError, .invalidSelection) }
        let invalid = try XCTUnwrap(DictionaryLearningRecording(
            alignment: DictionaryLearningAlignment(modelKey: "parakeet-v3", words: [ASRWordTiming(text: "hello", start: .nan, end: 0.5)]),
            samples: [Float](repeating: 0, count: 16_000),
            now: now
        ))
        XCTAssertThrowsError(try DictionaryLearningAlignmentResolver.resolve(
            recording: invalid,
            deliveredTextBeforeEdit: "hello",
            selectedUTF16Range: NSRange(location: 0, length: 5),
            observedText: "hello",
            now: now
        )) { XCTAssertEqual($0 as? DictionaryLearningAlignmentError, .invalidTiming) }
    }
}

extension DictationE2ETests {
    func testDictionaryLearningDurabilityIdempotencyAndDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("profiles.json")
        let store = PronunciationDictionaryStore(fileURL: url)
        let entryID = UUID()
        let evidenceID = UUID()
        let evidence = DictionaryLearningAudioEvidence(
            recordingID: UUID(),
            modelKey: "parakeet-v3",
            observedText: "flued voice",
            sourceWordRange: 1..<3,
            sourceSampleRange: 0..<3200,
            focalSampleRange: 1280..<2560,
            samples: Array(repeating: 0, count: 3200)
        )
        let capture = PronunciationEnrollmentCapture(values: [1, 0], sourceFrameCount: 1, modelKey: "parakeet-v3")
        let revision = await store.revision(for: entryID)
        var inserted: [Bool] = []
        for id in [evidenceID, evidenceID, UUID()] {
            try inserted.append(await store.learnOriginalAudio(
                entryID: entryID,
                label: "FluidVoice",
                evidenceID: id,
                evidence: evidence,
                capture: capture,
                expectedRevision: revision
            ))
        }
        XCTAssertEqual(inserted, [true, false, false], "Rollback must know whether this call actually inserted evidence")
        do {
            try await store.learnOriginalAudio(entryID: entryID, label: "ChangedMeaning", evidenceID: UUID(), evidence: evidence, capture: capture, expectedRevision: revision)
            XCTFail("A reused dictionary UUID must not relabel old pronunciation evidence")
        } catch { XCTAssertEqual(error as? PronunciationDictionaryStoreError, .staleEvidence) }
        let conflictingEntry = UUID()
        let conflictingRevision = await store.revision(for: conflictingEntry)
        do {
            try await store.learnOriginalAudio(
                entryID: conflictingEntry,
                label: "AnotherWord",
                evidenceID: evidenceID,
                evidence: evidence,
                capture: capture,
                expectedRevision: conflictingRevision
            )
            XCTFail("An event UUID cannot overwrite another word's audio")
        } catch { XCTAssertEqual(error as? PronunciationDictionaryStoreError, .inconsistentEnrollment) }
        let loaded = await PronunciationDictionaryStore(fileURL: url).allProfiles()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.enrollments.count, 1, "Retrying one recording occurrence must not create multiple examples")
        XCTAssertEqual(loaded.first?.enrollments.first?.observedText, "flued voice")
        XCTAssertEqual(loaded.first?.isEligibleForMatching, true)
        XCTAssertEqual(loaded.first?.enrollments.first?.values, capture.values)
        let audioDirectory = directory.appendingPathComponent("pronunciation-audio")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: audioDirectory.path).count, 1)
        try await store.delete(dictionaryEntryID: entryID)
        let deleted = await store.allProfiles()
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: audioDirectory.path).isEmpty)
        do {
            try await store.learnOriginalAudio(entryID: entryID, label: "FluidVoice", evidenceID: UUID(), evidence: evidence, capture: capture, expectedRevision: revision)
            XCTFail("Late extraction must not resurrect a deleted entry")
        } catch {
            XCTAssertEqual(error as? PronunciationDictionaryStoreError, .staleEvidence)
        }
    }

    func testDictionaryLearningRejectsInvalidCaptureWithoutPartialProfile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PronunciationDictionaryStore(fileURL: directory.appendingPathComponent("profiles.json"))
        let id = UUID()
        let revision = await store.revision(for: id)
        let evidence = DictionaryLearningAudioEvidence(
            recordingID: UUID(),
            modelKey: "parakeet-v3",
            observedText: "test",
            sourceWordRange: 0..<1,
            sourceSampleRange: 0..<1,
            focalSampleRange: 0..<1,
            samples: [0]
        )
        do {
            try await store.learnOriginalAudio(
                entryID: id,
                label: "Test",
                evidenceID: UUID(),
                evidence: evidence,
                capture: PronunciationEnrollmentCapture(values: [.nan], sourceFrameCount: 1, modelKey: "parakeet-v3"),
                expectedRevision: revision
            )
            XCTFail("Non-finite embeddings must never be activated")
        } catch {
            XCTAssertEqual(error as? PronunciationDictionaryStoreError, .inconsistentEnrollment)
        }
        let profiles = await store.allProfiles()
        XCTAssertTrue(profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try await store.replaceAllProfiles([])
        do {
            try await store.learnOriginalAudio(
                entryID: id,
                label: "Test",
                evidenceID: UUID(),
                evidence: evidence,
                capture: PronunciationEnrollmentCapture(values: [1], sourceFrameCount: 1, modelKey: "parakeet-v3"),
                expectedRevision: revision
            )
            XCTFail("Import must invalidate pending original-audio learning")
        } catch { XCTAssertEqual(error as? PronunciationDictionaryStoreError, .staleEvidence) }
    }

    #if arch(arm64)
    func testDictionaryLearningCombinedDecisionAndConflictingLabels() {
        let id = UUID()
        let otherID = UUID()
        let sample = PronunciationEnrollmentCapture(values: [1, 0], sourceFrameCount: 5, modelKey: "parakeet-v3", originalAudioID: UUID(), observedText: "fluid boys")
        let profile = PronunciationDictionaryProfile(dictionaryEntryID: id, label: "FluidVoice", modelKey: "parakeet-v3", hiddenSize: 2, enrollments: [sample])
        XCTAssertTrue(DictionaryPronunciationDecision.accepts(score: 0.75, heardText: "Fluid boys!", profile: profile))
        XCTAssertFalse(DictionaryPronunciationDecision.accepts(score: 0.69, heardText: "fluid boys", profile: profile))
        XCTAssertFalse(DictionaryPronunciationDecision.accepts(score: 0.75, heardText: "other speech", profile: profile))
        XCTAssertTrue(DictionaryPronunciationDecision.accepts(score: 0.9, heardText: "fluid voice", profile: profile))
        XCTAssertFalse(DictionaryPronunciationDecision.accepts(score: .nan, heardText: "fluid boys", profile: profile))
        let result = ASRResult(text: "fluid voice", confidence: 1, duration: 1, processingTime: 0, tokenTimings: [
            TokenTiming(token: "▁fluid", tokenId: 1, startTime: 0, endTime: 0.24, confidence: 1),
            TokenTiming(token: "▁voice", tokenId: 2, startTime: 0.24, endTime: 0.48, confidence: 1),
        ])
        let match = PronunciationWindowMatch(prototypeIndex: 0, score: 0.9, frameRange: 0..<6)
        XCTAssertEqual(FluidAudioProvider.applyPronunciationMatches(result: result, matches: [match], profiles: [profile], labels: [id: "FluidVoice"]), "FluidVoice")
        XCTAssertEqual(FluidAudioProvider.applyPronunciationMatches(result: result, matches: [match], profiles: [profile], labels: [id: "ChangedMeaning"]), result.text)
        var incompatible = profile
        incompatible.enrollments[0].extractorVersion = "another-vector-space"
        XCTAssertFalse(incompatible.isEligibleForMatching)
        let other = PronunciationDictionaryProfile(dictionaryEntryID: otherID, label: "Other", modelKey: "parakeet-v3", hiddenSize: 2, enrollments: [sample])
        let competitor = PronunciationWindowMatch(prototypeIndex: 1, score: 0.88, frameRange: 0..<6)
        XCTAssertEqual(
            FluidAudioProvider.applyPronunciationMatches(result: result, matches: [match, competitor], profiles: [profile, other], labels: [id: "FluidVoice", otherID: "Other"]),
            result.text
        )
    }
    #endif
}

private actor DictionaryLearningTestExtractor {
    var calls = 0
    let started: XCTestExpectation
    let cancelled: XCTestExpectation
    init(started: XCTestExpectation, cancelled: XCTestExpectation) {
        self.started = started
        self.cancelled = cancelled
    }

    func extract(_ evidence: DictionaryLearningAudioEvidence) async throws -> PronunciationEnrollmentCapture {
        self.calls += 1
        if self.calls == 1 {
            self.started.fulfill()
            do { try await Task.sleep(for: .seconds(30)) } catch { self.cancelled.fulfill(); throw error }
        }
        return PronunciationEnrollmentCapture(values: [1, 0], sourceFrameCount: 1, modelKey: evidence.modelKey)
    }
}

extension DictationE2ETests {
    func testDictionaryLearningDefersToDictationAndRetriesOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PronunciationDictionaryStore(fileURL: directory.appendingPathComponent("profiles.json"))
        let entry = SettingsStore.CustomDictionaryEntry(triggers: ["flued"], replacement: "Fluid")
        let evidence = DictionaryLearningAudioEvidence(
            recordingID: UUID(),
            modelKey: "parakeet-v3",
            observedText: "flued",
            sourceWordRange: 0..<1,
            sourceSampleRange: 0..<1280,
            focalSampleRange: 0..<1280,
            samples: Array(repeating: 0, count: 1280)
        )
        let started = self.expectation(description: "Background extraction started")
        let cancelled = self.expectation(description: "Dictation cancelled background work")
        let extractor = DictionaryLearningTestExtractor(started: started, cancelled: cancelled)
        var idle = true
        let service = DictionaryAudioLearningService(store: store, extract: { try await extractor.extract($0) }, canProcess: { idle }, isCurrent: { $0 == entry })
        let eventID = UUID()
        service.learn(entry: entry, evidenceID: eventID, evidence: evidence)
        service.learn(entry: entry, evidenceID: eventID, evidence: evidence)
        await self.fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(service.pendingCount, 1)
        idle = false
        service.cancelForRecording()
        await self.fulfillment(of: [cancelled], timeout: 2)
        let duringDictation = await store.allProfiles()
        XCTAssertTrue(duringDictation.isEmpty)
        idle = true
        service.activityDidEnd()
        for _ in 0..<200 where service.pendingCount > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.pendingCount, 0)
        let profiles = await store.allProfiles()
        XCTAssertEqual(profiles.first?.enrollments.count, 1)
        let calls = await extractor.calls
        XCTAssertEqual(calls, 2)
    }

    func testDictionaryLearningQueueIsBoundedAndExpiresWithoutSaving() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PronunciationDictionaryStore(fileURL: directory.appendingPathComponent("profiles.json"))
        let entry = SettingsStore.CustomDictionaryEntry(triggers: ["flued"], replacement: "Fluid")
        let evidence = DictionaryLearningAudioEvidence(
            recordingID: UUID(),
            modelKey: "parakeet-v3",
            observedText: "flued",
            sourceWordRange: 0..<1,
            sourceSampleRange: 0..<1,
            focalSampleRange: 0..<1,
            samples: [0]
        )
        let service = DictionaryAudioLearningService(
            store: store,
            lifetime: 0.05,
            extract: { _ in
                XCTFail("Busy dictation must not run the background encoder")
                throw CancellationError()
            },
            canProcess: { false },
            isCurrent: { _ in true }
        )
        for _ in 0..<6 {
            service.learn(entry: entry, evidenceID: UUID(), evidence: evidence)
        }
        XCTAssertEqual(service.pendingCount, 4)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(service.pendingCount, 0)
        let profiles = await store.allProfiles()
        XCTAssertTrue(profiles.isEmpty)
    }
}

extension DictationE2ETests {
    #if arch(arm64)
    func testDictionaryLearningRealAudioRoundTrip() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["FLUIDVOICE_PRONUNCIATION_AUDIO"],
              let modelPath = environment["FLUIDAUDIO_PARAKEET_MODEL_DIR"]
        else { throw XCTSkip("Set the public real-speech fixture and local Parakeet model path") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = try Array(AudioConverter().resampleAudioFile(path: path).prefix(160_000))
        let models = try await AsrModels.load(from: URL(fileURLWithPath: modelPath), version: .v3)
        let manager = AsrManager(config: ASRConfig(tdtConfig: TdtConfig(blankId: AsrModelVersion.v3.blankId), encoderHiddenSize: 1024))
        try await manager.initialize(models: models)
        let result = try await manager.transcribe(samples, source: .microphone)
        let words = WordAudioChunkExtractor.words(from: result.tokenTimings ?? [])
        let selected = try XCTUnwrap(words.first { $0.startTime < 2 && $0.endTime - $0.startTime >= 0.24 && $0.text.count >= 5 })
        let alignment = DictionaryLearningAlignment(modelKey: "parakeet-v3", words: words.map { ASRWordTiming(text: $0.text, start: $0.startTime, end: $0.endTime) })
        let recording = try XCTUnwrap(DictionaryLearningRecording(alignment: alignment, samples: samples))
        let delivered = words.map(\.text).joined(separator: " ")
        let evidence = try DictionaryLearningAlignmentResolver.resolve(
            recording: recording,
            deliveredTextBeforeEdit: delivered,
            selectedUTF16Range: (delivered as NSString).range(of: selected.text),
            observedText: selected.text
        )
        let entry = SettingsStore.CustomDictionaryEntry(triggers: [selected.text], replacement: "LearnedTarget")
        let store = PronunciationDictionaryStore(fileURL: directory.appendingPathComponent("profiles.json"))
        let service = DictionaryAudioLearningService(store: store, canProcess: { true }, isCurrent: { $0 == entry })
        let started = ProcessInfo.processInfo.systemUptime
        service.learn(entry: entry, evidenceID: UUID(), evidence: evidence)
        for _ in 0..<1000 where service.pendingCount > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.pendingCount, 0)
        let backgroundWallMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let profiles = await store.allProfiles()
        let profile = try XCTUnwrap(profiles.first)
        let capture = try XCTUnwrap(profile.enrollments.first)
        XCTAssertEqual(capture.observedText, selected.text)
        XCTAssertEqual(capture.sourceRecordingID, recording.id)
        XCTAssertEqual(profile.enrollments.count, 1)
        await manager.setPronunciationCustomizationEnabled(true)
        let replay = try await manager.transcribe(evidence.samples, source: .microphone)
        let captured = await manager.consumePronunciationEncoderFeatures()
        let features = try XCTUnwrap(captured)
        let prototype = PronunciationEmbedding(values: capture.values, sourceFrameCount: capture.sourceFrameCount)
        let matches = PronunciationEmbeddingMatcher.allMatches(prototypes: [prototype], in: features)[0].map {
            PronunciationWindowMatch(prototypeIndex: 0, score: $0.score, frameRange: $0.frameRange)
        }
        let output = FluidAudioProvider.applyPronunciationMatches(result: replay, matches: matches, profiles: profiles, labels: [entry.id: entry.replacement])
        XCTAssertTrue(output.contains("LearnedTarget"), "The saved original example must be usable by the production matcher")
        let provider = FluidAudioProvider(
            modelOverride: .parakeetTDT,
            configureWordBoosting: false,
            enhancementOptions: FluidAudioProviderEnhancementOptions(experimentalUnifiedFinalEnabled: false, pronunciationMatchingEnabled: false, customDictionaryEntries: []),
            pronunciationStore: store
        )
        try await provider.prepare()
        let reuseStart = ProcessInfo.processInfo.systemUptime
        let reused = try await provider.originalAudioEnrollment(evidence)
        XCTAssertEqual(reused?.values, capture.values, "Warm encoder reuse must preserve the exact embedding")
        print("ORIGINAL_AUDIO_ENCODER_REUSE ms=\((ProcessInfo.processInfo.systemUptime - reuseStart) * 1000)")
        let afterReuse = try await provider.transcribeFinal(evidence.samples)
        XCTAssertEqual(afterReuse.text, replay.text, "Background enrollment must not change later transcription")
        print("ORIGINAL_AUDIO_ROUNDTRIP backgroundWallMs=\(backgroundWallMs) samples=\(evidence.samples.count)")
        await manager.cleanup()
    }
    #endif
}

extension DictationE2ETests {
    #if arch(arm64)
    func testDictionaryLearningComplementaryRecoveryWithControlledASRErrors() {
        let id = UUID()
        let capture = PronunciationEnrollmentCapture(values: [1, 0], sourceFrameCount: 6, modelKey: "parakeet-v3", originalAudioID: UUID(), observedText: "fluid boys")
        let profile = PronunciationDictionaryProfile(dictionaryEntryID: id, label: "FluidVoice", modelKey: "parakeet-v3", hiddenSize: 2, enrollments: [capture])
        defer { ASRService.invalidateDictionaryCache() }
        self.withRestoredDefaults(keys: [self.customDictionaryEntriesKey]) {
            SettingsStore.shared.customDictionaryEntries = [.init(id: id, triggers: ["fluid boys"], replacement: "FluidVoice")]
            ASRService.invalidateDictionaryCache()
            // Explicit fault injection checks fallback wiring, not real-speech accuracy.
            for (text, score, expected) in [("fluid boys", Float(0.2), "FluidVoice"), ("fluent voice", Float(0.95), "FluidVoice"), ("other words", Float(0.3), "other words")] {
                let parts = text.split(separator: " ")
                let result = ASRResult(text: text, confidence: 1, duration: 1, processingTime: 0, tokenTimings: [
                    TokenTiming(token: "▁" + parts[0], tokenId: 1, startTime: 0, endTime: 0.24, confidence: 1),
                    TokenTiming(token: "▁" + parts[1], tokenId: 2, startTime: 0.24, endTime: 0.48, confidence: 1),
                ])
                let acoustic = FluidAudioProvider.applyPronunciationMatches(
                    result: result,
                    matches: [PronunciationWindowMatch(prototypeIndex: 0, score: score, frameRange: 0..<6)],
                    profiles: [profile],
                    labels: [id: "FluidVoice"]
                )
                XCTAssertEqual(ASRService.applyCustomDictionary(acoustic), expected)
                if text == "fluid boys" { XCTAssertEqual(acoustic, text, "Text fallback must recover an acoustic miss") }
                if text == "fluent voice" { XCTAssertEqual(ASRService.applyCustomDictionary(text), text, "Audio must recover a text-rule miss") }
            }
        }
    }

    func testDictionaryLearningReconciliationCostAtScale() {
        let wordCount = 1200
        let result = ASRResult(
            text: Array(repeating: "spoken", count: wordCount).joined(separator: " "),
            confidence: 1,
            duration: 600,
            processingTime: 0,
            tokenTimings: (0..<wordCount).map { index in
                TokenTiming(token: "▁spoken", tokenId: 1, startTime: Double(index) * 0.48, endTime: Double(index + 1) * 0.48, confidence: 1)
            }
        )
        for count in [1, 10, 1000] {
            let profiles = (0..<count).map { index in
                PronunciationDictionaryProfile(
                    dictionaryEntryID: UUID(),
                    label: "Target\(index)",
                    modelKey: "parakeet-v3",
                    hiddenSize: 2,
                    enrollments: [PronunciationEnrollmentCapture(values: [1, 0], sourceFrameCount: 6, modelKey: "parakeet-v3", originalAudioID: UUID(), observedText: "spoken")]
                )
            }
            let labels = Dictionary(uniqueKeysWithValues: profiles.map { ($0.dictionaryEntryID, $0.label) })
            let matches = (0..<count).map { PronunciationWindowMatch(prototypeIndex: $0, score: 0.95, frameRange: ($0 * 6)..<(($0 + 1) * 6)) }
            var durations: [Double] = []
            for run in 0..<6 {
                let start = ProcessInfo.processInfo.systemUptime
                let output = FluidAudioProvider.applyPronunciationMatches(result: result, matches: matches, profiles: profiles, labels: labels)
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                XCTAssertTrue(output.contains("Target0"))
                if run > 0 { durations.append(elapsed) }
            }
            print("LEARNING_RECONCILIATION profiles=\(count) audioSeconds=600 meanMs=\(durations.reduce(0, +) / Double(durations.count)) maxMs=\(durations.max() ?? 0)")
        }
    }
    #endif
}

extension DictationE2ETests {
    func testDictionaryCanonicalReplacementDoesNotExpandAgain() {
        defer { ASRService.invalidateDictionaryCache() }
        self.withRestoredDefaults(keys: [self.customDictionaryEntriesKey]) {
            SettingsStore.shared.customDictionaryEntries = [
                .init(triggers: ["fluid"], replacement: "Fluid Voice"),
                .init(triggers: ["api"], replacement: "API Client"),
            ]
            ASRService.invalidateDictionaryCache()
            XCTAssertEqual(ASRService.applyCustomDictionary("Fluid Voice and fluid"), "Fluid Voice and Fluid Voice")
            XCTAssertEqual(ASRService.applyCustomDictionary("API Client, api!"), "API Client, API Client!")
            XCTAssertEqual(ASRService.applyCustomDictionary("fluid voice"), "fluid voice")
            let once = ASRService.applyCustomDictionary("fluid and api")
            XCTAssertEqual(ASRService.applyCustomDictionary(once), once)
        }
    }
}

extension DictationE2ETests {
    func testDictionaryCanonicalProtectionPreservesOtherRulesAndLiteralText() {
        defer { ASRService.invalidateDictionaryCache() }
        self.withRestoredDefaults(keys: [self.customDictionaryEntriesKey]) {
            SettingsStore.shared.customDictionaryEntries = [
                .init(triggers: ["client"], replacement: "API Client"),
                .init(triggers: ["apí"], replacement: "$apí client"),
                .init(triggers: ["plain"], replacement: "PLAIN"),
            ]
            ASRService.invalidateDictionaryCache()
            XCTAssertEqual(ASRService.applyCustomDictionary("API Client; client"), "API Client; API Client")
            XCTAssertEqual(ASRService.applyCustomDictionary("apí!"), "$apí client!")
            XCTAssertEqual(ASRService.applyCustomDictionary("plain"), "PLAIN", "Whole-trigger capitalization still applies")
            XCTAssertEqual(ASRService.applyCustomDictionary("clientele"), "clientele", "Word boundaries remain intact")
        }
    }

    #if arch(arm64)
    func testDictionaryCombinedRecoveryDoesNotOverwriteAcousticOutput() {
        defer { ASRService.invalidateDictionaryCache() }
        self.withRestoredDefaults(keys: [self.customDictionaryEntriesKey]) {
            let entry = SettingsStore.CustomDictionaryEntry(triggers: ["fluid"], replacement: "Fluid Voice")
            SettingsStore.shared.customDictionaryEntries = [entry]
            ASRService.invalidateDictionaryCache()
            let result = ASRResult(text: "fluent voice plus fluid", confidence: 1, duration: 2, processingTime: 0, tokenTimings: [
                TokenTiming(token: "▁fluent", tokenId: 1, startTime: 0, endTime: 0.24, confidence: 1),
                TokenTiming(token: "▁voice", tokenId: 2, startTime: 0.24, endTime: 0.48, confidence: 1),
                TokenTiming(token: "▁plus", tokenId: 3, startTime: 0.8, endTime: 1.0, confidence: 1),
                TokenTiming(token: "▁fluid", tokenId: 4, startTime: 1.2, endTime: 1.5, confidence: 1),
            ])
            let capture = PronunciationEnrollmentCapture(values: [1, 0], sourceFrameCount: 6, modelKey: "parakeet-v3", originalAudioID: UUID(), observedText: "fluid")
            let profile = PronunciationDictionaryProfile(dictionaryEntryID: entry.id, label: entry.replacement, modelKey: capture.modelKey, hiddenSize: 2, enrollments: [capture])
            let audioOnly = FluidAudioProvider.applyPronunciationMatches(
                result: result,
                matches: [PronunciationWindowMatch(prototypeIndex: 0, score: 0.95, frameRange: 0..<6)],
                profiles: [profile],
                labels: [entry.id: entry.replacement]
            )
            let textOnly = ASRService.applyCustomDictionary(result.text)
            let combined = ASRService.applyCustomDictionary(audioOnly)
            XCTAssertEqual(audioOnly, "Fluid Voice plus fluid")
            XCTAssertEqual(textOnly, "fluent voice plus Fluid Voice")
            XCTAssertEqual(combined, "Fluid Voice plus Fluid Voice")
        }
    }
    #endif
}

extension DictationE2ETests {
    #if arch(arm64)
    func testOriginalPronunciationKeepsNewPossessiveEnding() {
        let id = UUID()
        let sample = PronunciationEnrollmentCapture(values: [1, 0], sourceFrameCount: 6, modelKey: "parakeet-v3", originalAudioID: UUID(), observedText: "jensen")
        var profile = PronunciationDictionaryProfile(dictionaryEntryID: id, label: "Jensen", modelKey: sample.modelKey, hiddenSize: 2, enrollments: [sample])
        for spoken in ["Jensen's", "Jensen’s"] {
            let result = ASRResult(text: spoken + " project", confidence: 1, duration: 1, processingTime: 0, tokenTimings: [
                TokenTiming(token: "▁" + spoken, tokenId: 1, startTime: 0, endTime: 0.48, confidence: 1),
                TokenTiming(token: "▁project", tokenId: 2, startTime: 0.6, endTime: 0.9, confidence: 1),
            ])
            XCTAssertEqual(
                FluidAudioProvider
                    .applyPronunciationMatches(result: result, matches: [.init(prototypeIndex: 0, score: 0.8835, frameRange: 0..<6)], profiles: [profile], labels: [id: "Jensen"]),
                result.text
            )
        }
        XCTAssertEqual(DictionaryPronunciationDecision.labelPreservingPossessive("Jensen's", heardText: "Jensen's", profile: profile), "Jensen's")
        XCTAssertEqual(DictionaryPronunciationDecision.labelPreservingPossessive("Jensen", heardText: "Jensen", profile: profile), "Jensen")
        profile.enrollments[0].observedText = "Jensen's"
        XCTAssertEqual(
            DictionaryPronunciationDecision.labelPreservingPossessive("Jensen", heardText: "Jensen's", profile: profile),
            "Jensen",
            "An explicitly taught removal keeps its intended meaning"
        )
    }

    func testApprovedCorrectionLearnsOriginalRealAudioThroughExistingSession() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["FLUIDVOICE_PRONUNCIATION_AUDIO"], let modelPath = environment["FLUIDAUDIO_PARAKEET_MODEL_DIR"] else {
            throw XCTSkip("Set the public speech fixture and Parakeet model paths")
        }
        let defaults = UserDefaults.standard
        let previousAutomatic = SettingsStore.shared.automaticDictionaryLearningEnabled
        let previousPreview = SettingsStore.shared.pronunciationMatchingEnabled
        SettingsStore.shared.automaticDictionaryLearningEnabled = true
        SettingsStore.shared.pronunciationMatchingEnabled = false
        defer {
            SettingsStore.shared.automaticDictionaryLearningEnabled = previousAutomatic
            SettingsStore.shared.pronunciationMatchingEnabled = previousPreview
        }
        let previousEntries = defaults.object(forKey: self.customDictionaryEntriesKey)
        defer {
            if let previousEntries { defaults.set(previousEntries, forKey: self.customDictionaryEntriesKey) } else { defaults.removeObject(forKey: self.customDictionaryEntriesKey) }
            ASRService.invalidateDictionaryCache()
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PronunciationDictionaryStore(fileURL: folder.appendingPathComponent("profiles.json"))
        let fullSamples = try AudioConverter().resampleAudioFile(path: path)
        let samples = Array(fullSamples.prefix(160_000))
        let models = try await AsrModels.load(from: URL(fileURLWithPath: modelPath), version: .v3)
        let manager = AsrManager(config: ASRConfig(tdtConfig: TdtConfig(blankId: AsrModelVersion.v3.blankId), encoderHiddenSize: 1024))
        try await manager.initialize(models: models)
        let transcription = try await manager.transcribe(samples, source: .microphone)
        await manager.cleanup()
        let words = WordAudioChunkExtractor.words(from: transcription.tokenTimings ?? [])
        let word = try XCTUnwrap(words.first { $0.text.count >= 5 && $0.startTime < 2 && $0.endTime - $0.startTime >= 0.24 })
        let delivered = words.map(\.text).joined(separator: " ")
        let oldRange = (delivered as NSString).range(of: word.text)
        let intended = "PersonalName"
        let edited = (delivered as NSString).replacingCharacters(in: oldRange, with: intended)
        var candidate = try XCTUnwrap(AutomaticDictionaryCorrectionDetector.candidate(
            before: delivered,
            after: edited,
            insertedRange: NSRange(location: 0, length: (delivered as NSString).length),
            allowsInsertionAtEnd: true
        ))
        let recording = try XCTUnwrap(DictionaryLearningRecording(
            alignment: .init(modelKey: "parakeet-v3", words: words.map { .init(text: $0.text, start: $0.startTime, end: $0.endTime) }),
            samples: samples
        ))
        candidate.audioEvidence = try DictionaryLearningAlignmentResolver.resolve(
            recording: recording,
            deliveredTextBeforeEdit: delivered,
            selectedUTF16Range: XCTUnwrap(candidate.sourceUTF16Range),
            observedText: candidate.heardText
        )
        let worker = DictionaryAudioLearningService(store: store, canProcess: { true })
        let session = AutomaticDictionaryTrainingSession(candidate: candidate, asr: AppServices.shared.asr, audioLearning: worker)
        let before = await store.allProfiles()
        XCTAssertTrue(before.isEmpty, "Detection alone cannot activate acoustic learning")
        let provider = FluidAudioProvider(modelOverride: .parakeetTDT, configureWordBoosting: false, pronunciationStore: store)
        try await provider.prepare()
        let beforeApproval = try await provider.transcribeFinal(samples)
        XCTAssertFalse(beforeApproval.text.contains(intended))
        session.addOnlyCorrection()
        XCTAssertEqual(session.screen, .success)
        let entry = try XCTUnwrap(SettingsStore.shared.customDictionaryEntries.first { $0.replacement == intended })
        XCTAssertTrue(entry.triggers.contains(candidate.heardText.lowercased()))
        for _ in 0..<1000 where worker.pendingCount > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(worker.pendingCount, 0)
        let learned = await store.allProfiles()
        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(learned.first?.dictionaryEntryID, entry.id)
        XCTAssertEqual(learned.first?.label, intended)
        XCTAssertEqual(learned.first?.enrollments.first?.sourceRecordingID, recording.id)
        XCTAssertEqual(learned.first?.enrollments.first?.observedText, candidate.heardText)
        XCTAssertEqual(learned.first?.enrollments.count, 1)
        provider.resetStreamingPreviewCache()
        let corrected = try await provider.transcribeFinal(samples)
        XCTAssertTrue(corrected.text.contains(intended), "Approved audio must work without the Advanced Preview switch")
        provider.resetStreamingPreviewCache()
        let aligned = try await provider.transcribeWithWordTimings(samples)
        XCTAssertTrue(aligned.result.text.contains(intended))
        provider.resetStreamingPreviewCache()
        _ = try await provider.transcribeStreaming(Array(fullSamples.prefix(320_000)))
        _ = try await provider.transcribeStreaming(fullSamples)
        let longResult = try await provider.transcribeFinal(fullSamples)
        XCTAssertTrue(longResult.text.contains(intended), "Automatic evidence also participates in incremental long dictation")
        SettingsStore.shared.automaticDictionaryLearningEnabled = false
        provider.resetStreamingPreviewCache()
        let disabled = try await provider.transcribeFinal(samples)
        XCTAssertFalse(disabled.text.contains(intended), "Disabling both modes must preserve baseline ASR")
    }

    func testWizardPronunciationOptInRequiresThreeSamplesAndPreservesLegacyPolicy() throws {
        let entry = SettingsStore.CustomDictionaryEntry(triggers: ["fluid"], replacement: "Fluid Voice")
        let capture = PronunciationEnrollmentCapture(values: [1, 0], sourceFrameCount: 6, modelKey: "parakeet-v3")
        var profile = PronunciationDictionaryProfile(
            dictionaryEntryID: entry.id,
            label: entry.replacement,
            modelKey: capture.modelKey,
            hiddenSize: 2,
            enrollments: [capture, capture]
        )
        profile.automaticMatchingEnabled = true
        XCTAssertTrue(FluidAudioProvider.matchingProfiles([profile], entries: [entry], includeManual: false, includeOriginal: false).isEmpty)
        profile.enrollments.append(capture)
        XCTAssertEqual(FluidAudioProvider.matchingProfiles([profile], entries: [entry], includeManual: false, includeOriginal: false).count, 1)
        let restored = try JSONDecoder().decode(PronunciationDictionaryProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(restored.automaticMatchingEnabled, true)
        XCTAssertTrue(FluidAudioProvider.matchingProfiles([profile], entries: [], includeManual: false).isEmpty)
        profile.automaticMatchingEnabled = nil
        XCTAssertTrue(FluidAudioProvider.matchingProfiles([profile], entries: [entry], includeManual: false, includeOriginal: false).isEmpty)
    }

    func testDictionaryAutomaticProfileSelectionPreservesMeaningAndManualOptIn() {
        let entry = SettingsStore.CustomDictionaryEntry(triggers: ["fluid"], replacement: "Fluid Voice")
        let capture = PronunciationEnrollmentCapture(values: [1, 0], sourceFrameCount: 6, modelKey: "parakeet-v3")
        let manual = PronunciationDictionaryProfile(
            dictionaryEntryID: entry.id,
            label: entry.replacement,
            modelKey: capture.modelKey,
            hiddenSize: 2,
            enrollments: [capture, capture, capture]
        )
        XCTAssertTrue(FluidAudioProvider.matchingProfiles([manual], entries: [entry], includeManual: false).isEmpty)
        XCTAssertEqual(FluidAudioProvider.matchingProfiles([manual], entries: [entry], includeManual: true).count, 1)
        var original = manual
        original.enrollments[0].originalAudioID = UUID()
        XCTAssertEqual(FluidAudioProvider.matchingProfiles([original], entries: [entry], includeManual: false).count, 1)
        original.label = "Different Meaning"
        XCTAssertTrue(FluidAudioProvider.matchingProfiles([original], entries: [entry], includeManual: false).isEmpty)
        XCTAssertTrue(FluidAudioProvider.matchingProfiles([original], entries: [entry], includeManual: true).isEmpty)
        XCTAssertTrue(FluidAudioProvider.matchingProfiles([manual], entries: [], includeManual: true).isEmpty)
    }
    #endif
}

extension DictationE2ETests {
    func testDictionaryWalkthroughStatesRenderWithoutCaptureOrPersistence() async throws {
        let entries = SettingsStore.shared.customDictionaryEntries
        var actions = 0
        for (index, state) in [(0, false, false), (1, true, false), (2, false, true), (3, false, false)].enumerated() {
            for width in [520.0, 900.0] {
                let view = DictionaryWordWizard(
                    word: .constant("FluidVoice"),
                    step: state.0 == 3 ? .review : .recording,
                    count: state.0,
                    heard: "",
                    variants: [],
                    busy: state.1 || state.2,
                    recording: state.1,
                    processing: state.2,
                    starting: false,
                    error: index == 0 ? "Couldn’t capture a voice profile. Try again." : nil,
                    voiceSupported: true,
                    alreadyCorrect: false,
                    savedWord: "",
                    onContinue: { actions += 1 },
                    onRecord: { actions += 1 },
                    onSave: { actions += 1 },
                    onBack: { actions += 1 },
                    onNewWord: { actions += 1 },
                    onManual: { actions += 1 },
                    onPracticeMore: { actions += 1 },
                    onRedo: { actions += 1 }
                )
                .padding(24)
                .frame(width: width, height: 950, alignment: .top)
                .appTheme(.adaptive(accent: FluidBrandColors.blue, colorScheme: .light))
                .environmentObject(AppServices.shared)
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 950), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.appearance = NSAppearance(named: .aqua)
                window.orderFrontRegardless()
                try await Task.sleep(for: .milliseconds(200))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "/tmp/dictionary-walkthrough-\(index)-\(Int(width)).png"))
                window.orderOut(nil)
            }
        }
        XCTAssertEqual(actions, 0)
        XCTAssertEqual(SettingsStore.shared.customDictionaryEntries, entries)
    }
}

#if arch(arm64)
extension DictationE2ETests {
    func testWordMatchLevelChangesReplacementWithoutWeakeningOtherWords() {
        let id = UUID(), otherID = UUID()
        let sample = PronunciationEnrollmentCapture(values: [1, 0], sourceFrameCount: 6, modelKey: "parakeet-v3")
        var profile = PronunciationDictionaryProfile(dictionaryEntryID: id, label: "Target", modelKey: "parakeet-v3", hiddenSize: 2, enrollments: [sample, sample, sample])
        let result = ASRResult(
            text: "misheard",
            confidence: 0.8,
            duration: 0.48,
            processingTime: 0.1,
            tokenTimings: [TokenTiming(token: "misheard", tokenId: 1, startTime: 0, endTime: 0.48, confidence: 0.8)]
        )
        let match = PronunciationWindowMatch(prototypeIndex: 0, score: 0.49, frameRange: 0..<6)
        XCTAssertEqual(FluidAudioProvider.applyPronunciationMatches(result: result, matches: [match], profiles: [profile], labels: [id: "Target"]), "misheard")
        profile.matchThreshold = 0.45
        XCTAssertEqual(FluidAudioProvider.applyPronunciationMatches(result: result, matches: [match], profiles: [profile], labels: [id: "Target"]), "Target")
        profile.matchThreshold = 0.8
        XCTAssertEqual(FluidAudioProvider.applyPronunciationMatches(result: result, matches: [match], profiles: [profile], labels: [id: "Target"]), "misheard")
        let other = PronunciationDictionaryProfile(dictionaryEntryID: otherID, label: "Other", modelKey: "parakeet-v3", hiddenSize: 2, enrollments: [sample, sample, sample])
        profile.matchThreshold = 0.45
        let otherMatch = PronunciationWindowMatch(prototypeIndex: 1, score: 0.65, frameRange: 0..<6)
        XCTAssertEqual(
            FluidAudioProvider.applyPronunciationMatches(result: result, matches: [otherMatch], profiles: [profile, other], labels: [id: "Target", otherID: "Other"]),
            "misheard"
        )
    }
}
#endif

#if arch(arm64)
extension DictationE2ETests {
    func testPronunciationMatchesIndividualRecordingsWithoutAveraging() throws {
        let id = UUID()
        let samples = [[Float(1), 0], [0, 1], [-1, 0]].map {
            PronunciationEnrollmentCapture(values: $0, sourceFrameCount: 6, modelKey: "parakeet-v3")
        }
        let profile = PronunciationDictionaryProfile(dictionaryEntryID: id, label: "Target", modelKey: "parakeet-v3", hiddenSize: 2, enrollments: samples)
        let references = DictionaryPronunciationReferences.make(profiles: [profile], hiddenSize: 2)
        XCTAssertEqual(references.count, 3)
        XCTAssertEqual(references.map(\.sampleNumber), [1, 2, 3])
        XCTAssertEqual(references.map { $0.embedding.values }, samples.map(\.values))
        XCTAssertEqual(references.map { $0.embedding.sourceFrameCount }, [6, 6, 6])
        XCTAssertTrue(DictionaryPronunciationReferences.make(profiles: [profile], hiddenSize: 4).isEmpty)
        let features = EncoderFeatureSequence(hiddenSize: 2, frameCount: 6, values: Array(repeating: [Float(1), 0], count: 6).flatMap { $0 })
        let matches = PronunciationEmbeddingMatcher.allMatches(prototypes: references.map(\.embedding), in: features, windowFrameCounts: [[6], [6], [6]])
        XCTAssertEqual(matches[0].first?.score, 1)
        XCTAssertTrue(matches[1].isEmpty && matches[2].isEmpty)
        let averaged = try XCTUnwrap(PronunciationEmbeddingMatcher.prototype(from: references.map(\.embedding)))
        XCTAssertTrue(
            PronunciationEmbeddingMatcher.allMatches(prototypes: [averaged], in: features, windowFrameCounts: [[6]])[0].isEmpty,
            "The old averaged center misses this valid individual example"
        )
        let result = ASRResult(
            text: "misheard",
            confidence: 0.8,
            duration: 0.48,
            processingTime: 0.1,
            tokenTimings: [TokenTiming(token: "misheard", tokenId: 1, startTime: 0, endTime: 0.48, confidence: 0.8)]
        )
        let hits = matches.enumerated().flatMap { index, hits in
            hits.map { PronunciationWindowMatch(prototypeIndex: index, score: $0.score, frameRange: $0.frameRange) }
        }
        XCTAssertEqual(FluidAudioProvider.applyPronunciationMatches(result: result, matches: hits, profiles: references.map(\.profile), labels: [id: "Target"]), "Target")
        let sameWord = hits + [PronunciationWindowMatch(prototypeIndex: 1, score: 0.99, frameRange: 0..<6)]
        XCTAssertEqual(
            FluidAudioProvider.applyPronunciationMatches(result: result, matches: sameWord, profiles: references.map(\.profile), labels: [id: "Target"]),
            "Target",
            "A second recording of the same word is not a competing word"
        )
        let otherID = UUID()
        let competitor = PronunciationDictionaryProfile(dictionaryEntryID: otherID, label: "Other", modelKey: profile.modelKey, hiddenSize: 2, enrollments: samples)
        let competingHits = hits + [PronunciationWindowMatch(prototypeIndex: 3, score: 0.99, frameRange: 0..<6)]
        let competingOutput = FluidAudioProvider.applyPronunciationMatches(
            result: result,
            matches: competingHits,
            profiles: references.map(\.profile) + [competitor],
            labels: [id: "Target", otherID: "Other"]
        )
        XCTAssertEqual(competingOutput, "misheard", "Competing words still require separation")
    }
}
#endif

extension DictationE2ETests {
    #if arch(arm64)
    func testSharedPronunciationFrameSelectionAndInvalidRanges() {
        let features = EncoderFeatureSequence(hiddenSize: 2, frameCount: 4, values: [1, 0, 0, 1, 1, 1, 0.5, 0.5])
        XCTAssertEqual(FluidAudioProvider.sharedPronunciationFrames(features, sampleRange: 1281..<2561)?.values, [0, 1, 1, 1])
        XCTAssertNil(FluidAudioProvider.sharedPronunciationFrames(features, sampleRange: -1..<100))
        XCTAssertNil(FluidAudioProvider.sharedPronunciationFrames(features, sampleRange: 0..<0))
        XCTAssertNil(FluidAudioProvider.sharedPronunciationFrames(features, sampleRange: 9000..<10_000))
    }

    func testSharedFeatureDictionaryCorpusReplay() async throws {
        guard let path = ProcessInfo.processInfo.environment["FLUIDVOICE_SHARED_DICTIONARY_FIXTURE"] else {
            throw XCTSkip("Set FLUIDVOICE_SHARED_DICTIONARY_FIXTURE to the private local regression corpus")
        }
        struct Archive: Decodable { let profiles: [PronunciationDictionaryProfile] }
        struct Job: Decodable { let id: String; let word: String; let path: String; let positive: Bool }
        let root = URL(fileURLWithPath: path)
        let jobs = try JSONDecoder().decode([Job].self, from: Data(contentsOf: root.appendingPathComponent("jobs.json")))
        let keys = [
            "DictionarySharedFeatureMatcherEnabled",
            "DictionaryTemporalMatcherEnabled",
            "DictionaryNegativeLearningEnabled",
            "DictionaryNegativeComparisonEnabled",
            "DictionaryPronunciationDebugCapture",
            "DictionaryEdgeMatchingEnabled",
        ]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) {
            UserDefaults.standard.set(value, forKey: key)
        } }
        for key in keys {
            UserDefaults.standard.set(false, forKey: key)
        }
        UserDefaults.standard.set(true, forKey: keys[0])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shared-dictionary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PronunciationDictionaryStore(fileURL: folder.appendingPathComponent("profiles.json"))
        var entries: [SettingsStore.CustomDictionaryEntry] = []
        for word in Set(jobs.map(\.word)).sorted() {
            let archive = try PropertyListDecoder().decode(Archive.self, from: Data(contentsOf: root.appendingPathComponent(word + ".plist")))
            let profile = try XCTUnwrap(archive.profiles.first)
            var enrollments = profile.enrollments
            for i in enrollments.indices {
                let id = try XCTUnwrap(enrollments[i].inspectionID)
                enrollments[i].pendingInspection = try PropertyListDecoder().decode(
                    DictionaryAudioInspection.self,
                    from: Data(contentsOf: root.appendingPathComponent(id.uuidString + ".plist"))
                )
            }
            try await store.upsert(dictionaryEntryID: profile.dictionaryEntryID, label: word, modelKey: profile.modelKey, enrollments: enrollments)
            entries.append(.init(id: profile.dictionaryEntryID, triggers: [], replacement: word))
        }
        let savedProfiles = await store.allProfiles()
        let existingProfile = try XCTUnwrap(savedProfiles.first)
        do {
            try await store.upsert(
                dictionaryEntryID: existingProfile.dictionaryEntryID,
                label: "MustNotSave",
                modelKey: existingProfile.modelKey,
                enrollments: existingProfile.enrollments,
                canPersist: { false }
            )
            XCTFail("Disabled pending save must fail")
        } catch is CancellationError {}
        let profilesAfterRejectedSave = await store.allProfiles()
        XCTAssertEqual(profilesAfterRejectedSave.map(\.label), savedProfiles.map(\.label), "Rejecting a pending save preserves existing voice profiles")
        let provider = FluidAudioProvider(
            modelOverride: .parakeetTDTv2,
            configureWordBoosting: false,
            enhancementOptions: .init(experimentalUnifiedFinalEnabled: false, pronunciationMatchingEnabled: true, customDictionaryEntries: entries),
            pronunciationStore: store
        )
        DictionaryMatcherExperiment.setEnabled(false)
        try await provider.prepare()
        XCTAssertNil(provider.pronunciationReferencePreparationTask, "Off must not schedule reference encoding")
        XCTAssertFalse(provider.pronunciationReferencesReady)
        let savedEntries = SettingsStore.shared.customDictionaryEntries
        defer { SettingsStore.shared.customDictionaryEntries = savedEntries }
        SettingsStore.shared.customDictionaryEntries = [.init(triggers: ["test replacement key"], replacement: "ReplacementValue")]
        for enabled in [false, true, false] {
            UserDefaults.standard.set(enabled, forKey: keys[0])
            XCTAssertEqual(ASRService.applyCustomDictionary("test replacement key"), "ReplacementValue", "Text rules work across pronunciation toggles")
        }
        // Master off must defeat saved profiles and every legacy audio switch.
        for key in keys {
            UserDefaults.standard.set(true, forKey: key)
        }
        UserDefaults.standard.set(false, forKey: keys[0])
        let probe = try XCTUnwrap(jobs.first { $0.positive })
        let pcm = try Data(contentsOf: URL(fileURLWithPath: probe.path)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let plain = FluidAudioProvider(
            modelOverride: .parakeetTDTv2,
            configureWordBoosting: false,
            enhancementOptions: .init(experimentalUnifiedFinalEnabled: false, pronunciationMatchingEnabled: false, customDictionaryEntries: []),
            pronunciationStore: store
        )
        try await plain.prepare()
        let baseline = try await plain.transcribeFinal(pcm)
        let disabled = try await provider.transcribeFinal(pcm)
        XCTAssertEqual(disabled.text, baseline.text, "Off must preserve ordinary recognition despite saved profiles")
        XCTAssertNil(disabled.dictionaryLearningAlignment, "Off must not retain pronunciation learning alignment")
        do {
            _ = try await provider.transcribeDictionaryTraining(pcm, capturePronunciation: true)
            XCTFail("Off must reject voice enrollment")
        } catch is CancellationError {}
        for key in keys {
            UserDefaults.standard.set(false, forKey: key)
        }
        DictionaryMatcherExperiment.setEnabled(true)
        provider.resetStreamingPreviewCache()
        XCTAssertFalse(provider.pronunciationReferencesReady, "Start with an unwarmed provider")
        let cold = try await provider.transcribeFinal(pcm)
        XCTAssertEqual(cold.text, baseline.text, "Cold cache misses skip acoustic matching instead of encoding references during final matching")
        provider.resetStreamingPreviewCache()
        _ = try await provider.transcribeStreaming(Array(pcm.prefix(32_000)))
        let warmGeneration = DictionaryMatcherExperiment.generation
        if let preparation = provider.pronunciationReferencePreparationTask {
            let finished = expectation(description: "Production pronunciation reference preparation completes")
            let waiter = Task { await preparation.value; finished.fulfill() }
            await fulfillment(of: [finished], timeout: 30)
            waiter.cancel()
        }
        XCTAssertEqual(DictionaryMatcherExperiment.generation, warmGeneration, "Readiness must belong to this master-switch generation")
        XCTAssertTrue(provider.pronunciationReferencesReady, "Accuracy replay requires all production references prepared")
        provider.resetStreamingPreviewCache()
        var falsePositives: [String] = [], falseNegatives: [String] = []
        var longFalsePositives: [String] = [], longFalseNegatives: [String] = []
        for job in jobs {
            let samples = try Data(contentsOf: URL(fileURLWithPath: job.path)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            provider.resetStreamingPreviewCache()
            let result = try await provider.transcribeFinal(samples)
            let accepted = result.text.contains(job.word)
            if accepted, !job.positive { falsePositives.append(job.id) }
            if !accepted, job.positive { falseNegatives.append(job.id) }
            print("SHARED_CORPUS id=\(job.id) positive=\(job.positive) accepted=\(accepted)")
            if job.id == "page" { XCTAssertFalse(accepted, "Page must remain unchanged") }
            do {
                let long = Array(repeating: samples, count: max(3, 480_000 / samples.count + 1)).flatMap { $0 }
                provider.resetStreamingPreviewCache()
                for end in stride(from: 32_000, to: long.count - 16_000, by: 32_000) {
                    if let start = provider.incrementalPreviewDeltaStart(totalSampleCount: end) {
                        _ = try await provider.transcribeStreamingDelta(Array(long[start..<end]), totalSampleCount: end)
                    } else { _ = try await provider.transcribeStreaming(Array(long.prefix(end))) }
                }
                let stop = ProcessInfo.processInfo.systemUptime
                let finalized = try await provider.transcribeFinal(long)
                print("SHARED_LONG id=\(job.id) stopMs=\((ProcessInfo.processInfo.systemUptime - stop) * 1000)")
                let longAccepted = finalized.text.contains(job.word)
                if longAccepted, !job.positive { longFalsePositives.append(job.id) }
                if !longAccepted, job.positive { longFalseNegatives.append(job.id) }
                print("SHARED_LONG_DECISION id=\(job.id) positive=\(job.positive) accepted=\(longAccepted)")
                if job.id == "page" { XCTAssertFalse(longAccepted, "Page must remain rejected in longer recordings") }
            }
        }
        print("SHARED_CORPUS fp=\(falsePositives) fn=\(falseNegatives)")
        print("SHARED_LONG_CORPUS fp=\(longFalsePositives) fn=\(longFalseNegatives)")
        XCTAssertTrue(falseNegatives.isEmpty)
        XCTAssertLessThanOrEqual(falsePositives.count, 3)
        XCTAssertTrue(longFalseNegatives.isEmpty)
        XCTAssertLessThanOrEqual(longFalsePositives.count, 5)
    }
    #endif
}
