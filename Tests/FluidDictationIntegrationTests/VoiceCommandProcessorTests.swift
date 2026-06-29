@testable import FluidVoice_Debug
import XCTest

@MainActor
final class VoiceCommandProcessorTests: XCTestCase {
    private func withVoiceCommandSettingsRestored(_ run: () -> Void) {
        let defaults = UserDefaults.standard
        let keys = ["VoiceCommandsEnabled", "VoiceCommandScratchWordCount"]
        let snapshot = Dictionary(uniqueKeysWithValues: keys.compactMap { k -> (String, Any)? in
            guard let v = defaults.object(forKey: k) else { return nil }
            return (k, v)
        })
        defer {
            for k in keys {
                if let v = snapshot[k] { defaults.set(v, forKey: k) } else { defaults.removeObject(forKey: k) }
            }
        }
        run()
    }

    func testDetect_featureDisabled_returnsOriginalAndNilAction() {
        self.withVoiceCommandSettingsRestored {
            SettingsStore.shared.voiceCommandsEnabled = false
            let result = VoiceCommandProcessor.detect(in: "scratch that", settings: SettingsStore.shared)
            XCTAssertEqual(result.stripped, "scratch that")
            XCTAssertNil(result.action)
        }
    }

    func testDetect_commandOnly_scratchThat_returnsEmptyStrippedAndDeleteAction() {
        self.withVoiceCommandSettingsRestored {
            SettingsStore.shared.voiceCommandsEnabled = true
            let result = VoiceCommandProcessor.detect(in: "scratch that", settings: SettingsStore.shared)
            XCTAssertEqual(result.stripped, "")
            if case .deleteLastWords = result.action {} else {
                XCTFail("expected .deleteLastWords, got \(String(describing: result.action))")
            }
        }
    }

    func testDetect_commandOnly_deleteThat_isSynonymForScratchThat() {
        self.withVoiceCommandSettingsRestored {
            SettingsStore.shared.voiceCommandsEnabled = true
            let result = VoiceCommandProcessor.detect(in: "delete that", settings: SettingsStore.shared)
            if case .deleteLastWords = result.action {} else {
                XCTFail("expected .deleteLastWords, got \(String(describing: result.action))")
            }
        }
    }

    func testDetect_mixed_trailingCommand_stripsCommandFromTranscript() {
        self.withVoiceCommandSettingsRestored {
            SettingsStore.shared.voiceCommandsEnabled = true
            let result = VoiceCommandProcessor.detect(in: "send the report scratch that", settings: SettingsStore.shared)
            XCTAssertEqual(result.stripped, "send the report")
            if case .deleteLastWords = result.action {} else {
                XCTFail("expected .deleteLastWords, got \(String(describing: result.action))")
            }
        }
    }

    func testDetect_midSentence_commandNotFired() {
        self.withVoiceCommandSettingsRestored {
            SettingsStore.shared.voiceCommandsEnabled = true
            let result = VoiceCommandProcessor.detect(in: "scratch that memo please", settings: SettingsStore.shared)
            XCTAssertNil(result.action)
        }
    }

    func testDetect_wordBoundary_capitalizePrefix_doesNotFire() {
        self.withVoiceCommandSettingsRestored {
            SettingsStore.shared.voiceCommandsEnabled = true
            let result = VoiceCommandProcessor.detect(in: "capitalize that letter", settings: SettingsStore.shared)
            XCTAssertNil(result.action)
        }
    }

    func testDetect_asrVariance_punctuatedCommand_normalizes() {
        self.withVoiceCommandSettingsRestored {
            SettingsStore.shared.voiceCommandsEnabled = true
            let result = VoiceCommandProcessor.detect(in: "scratch, that", settings: SettingsStore.shared)
            if case .deleteLastWords = result.action {} else {
                XCTFail("expected .deleteLastWords, got \(String(describing: result.action))")
            }
        }
    }

    func testApply_deleteLastWords_removesOneWord() {
        self.withVoiceCommandSettingsRestored {
            SettingsStore.shared.voiceCommandsEnabled = true
            let result = VoiceCommandProcessor.apply(.deleteLastWords(1), to: "call Monday", settings: SettingsStore.shared)
            XCTAssertEqual(result, "call")
        }
    }

    func testApply_deleteLastWords_oneWordUtterance_returnsEmpty() {
        self.withVoiceCommandSettingsRestored {
            SettingsStore.shared.voiceCommandsEnabled = true
            let result = VoiceCommandProcessor.apply(.deleteLastWords(1), to: "Monday", settings: SettingsStore.shared)
            XCTAssertEqual(result, "")
        }
    }

    func testApply_capitalizeLastWord_uppercasesFirstLetter() {
        self.withVoiceCommandSettingsRestored {
            SettingsStore.shared.voiceCommandsEnabled = true
            let result = VoiceCommandProcessor.apply(.capitalizeLastWord, to: "call monday", settings: SettingsStore.shared)
            XCTAssertEqual(result, "call Monday")
        }
    }

    func testApply_capitalizeLastWord_alreadyCapitalized_unchanged() {
        self.withVoiceCommandSettingsRestored {
            SettingsStore.shared.voiceCommandsEnabled = true
            let result = VoiceCommandProcessor.apply(.capitalizeLastWord, to: "call Monday", settings: SettingsStore.shared)
            XCTAssertEqual(result, "call Monday")
        }
    }

    func testApply_appendAfterLastWord_slash_noSpaceAdded() {
        self.withVoiceCommandSettingsRestored {
            SettingsStore.shared.voiceCommandsEnabled = true
            let result = VoiceCommandProcessor.apply(.appendAfterLastWord("/"), to: "src", settings: SettingsStore.shared)
            XCTAssertEqual(result, "src/")
        }
    }

    func testApply_insertNewline_appendsNewline() {
        self.withVoiceCommandSettingsRestored {
            SettingsStore.shared.voiceCommandsEnabled = true
            let result = VoiceCommandProcessor.apply(.insertNewline, to: "first item", settings: SettingsStore.shared)
            XCTAssertEqual(result, "first item\n")
        }
    }

    func testApply_punctuationOnToken_stripsAndReattaches() {
        self.withVoiceCommandSettingsRestored {
            SettingsStore.shared.voiceCommandsEnabled = true
            let result = VoiceCommandProcessor.apply(.deleteLastWords(1), to: "send the report.", settings: SettingsStore.shared)
            XCTAssertEqual(result, "send the")
        }
    }

    func testApply_scratchWordCount_configurable_deletesTwoWords() {
        self.withVoiceCommandSettingsRestored {
            SettingsStore.shared.voiceCommandsEnabled = true
            SettingsStore.shared.voiceCommandScratchWordCount = 2
            let result = VoiceCommandProcessor.apply(.deleteLastWords(1), to: "one two three", settings: SettingsStore.shared)
            XCTAssertEqual(result, "one")
        }
    }

    func testDetect_commandOnly_capitalizeOnly_returnsCorrectAction() {
        self.withVoiceCommandSettingsRestored {
            SettingsStore.shared.voiceCommandsEnabled = true
            let result = VoiceCommandProcessor.detect(in: "capitalize that", settings: SettingsStore.shared)
            if case .capitalizeLastWord = result.action {} else {
                XCTFail("expected .capitalizeLastWord, got \(String(describing: result.action))")
            }
        }
    }

    func testDetect_commandOnly_slashThat_returnsCorrectAction() {
        self.withVoiceCommandSettingsRestored {
            SettingsStore.shared.voiceCommandsEnabled = true
            let result = VoiceCommandProcessor.detect(in: "slash that", settings: SettingsStore.shared)
            if case .appendAfterLastWord = result.action {} else {
                XCTFail("expected .appendAfterLastWord, got \(String(describing: result.action))")
            }
        }
    }

    func testDetect_commandOnly_newLine_returnsInsertNewlineAction() {
        self.withVoiceCommandSettingsRestored {
            SettingsStore.shared.voiceCommandsEnabled = true
            let result = VoiceCommandProcessor.detect(in: "new line", settings: SettingsStore.shared)
            if case .insertNewline = result.action {} else {
                XCTFail("expected .insertNewline, got \(String(describing: result.action))")
            }
        }
    }

    func testDetect_commandOnly_newParagraph_synonymForNewLine() {
        self.withVoiceCommandSettingsRestored {
            SettingsStore.shared.voiceCommandsEnabled = true
            let result = VoiceCommandProcessor.detect(in: "new paragraph", settings: SettingsStore.shared)
            if case .insertNewline = result.action {} else {
                XCTFail("expected .insertNewline, got \(String(describing: result.action))")
            }
        }
    }
}
