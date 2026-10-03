import Carbon.HIToolbox
import CoreGraphics
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class SpokenSendTests: XCTestCase {
    func testAutomaticEnterDefaultsOffAndBacksUpEnabledChoice() throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "AutomaticEnterEnabled")
        defer {
            if let saved {
                defaults.set(saved, forKey: "AutomaticEnterEnabled")
            } else {
                defaults.removeObject(forKey: "AutomaticEnterEnabled")
            }
        }
        defaults.removeObject(forKey: "AutomaticEnterEnabled")
        let settings = SettingsStore.shared
        XCTAssertFalse(settings.automaticEnterEnabled)
        settings.automaticEnterEnabled = true
        XCTAssertTrue(defaults.bool(forKey: "AutomaticEnterEnabled"))
        let payload = settings.makeBackupPayload()
        let data = try JSONEncoder().encode(payload)
        XCTAssertEqual(try JSONDecoder().decode(SettingsBackupPayload.self, from: data).automaticEnterEnabled, true)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "automaticEnterEnabled")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try JSONDecoder().decode(SettingsBackupPayload.self, from: legacyData).automaticEnterEnabled)
    }

    func testAutomaticEnterSearchFindsDictationSetting() {
        XCTAssertEqual(SettingsSearchIndex.results(for: "Automatically Press Enter").first?.target, .automaticEnter)
        XCTAssertEqual(SettingsSearchTarget.automaticEnter.section, .dictation)
    }

    func testDisabledFeatureLeavesTextUntouched() {
        XCTAssertEqual(
            SpokenSendParser.parse("Hello send it", phrase: "send it", enabled: false),
            SpokenSendParseResult(text: "Hello send it", shouldSend: false)
        )
    }

    func testTerminalPhraseIsRemovedAndArmsSend() {
        XCTAssertEqual(
            SpokenSendParser.parse("Hello there, send it.", phrase: "send it", enabled: true),
            SpokenSendParseResult(text: "Hello there.", shouldSend: true)
        )
    }

    func testCapitalizationAndFullStopDoNotAffectSend() {
        XCTAssertEqual(
            SpokenSendParser.parse("Ready to go, SEND IT.", phrase: "send it", enabled: true),
            SpokenSendParseResult(text: "Ready to go.", shouldSend: true)
        )
    }

    func testNearbyTrailingPunctuationDoesNotAffectSend() {
        XCTAssertEqual(
            SpokenSendParser.parse(#"Ready to go — send it…")]"#, phrase: "send it", enabled: true),
            SpokenSendParseResult(text: "Ready to go.", shouldSend: true)
        )
    }

    func testPhraseInMiddleDoesNotArmSend() {
        XCTAssertEqual(
            SpokenSendParser.parse("Send it when you are ready", phrase: "send it", enabled: true),
            SpokenSendParseResult(text: "Send it when you are ready", shouldSend: false)
        )
    }

    func testTerminalPhraseDoesNotRequireLeadingOrTrailingPunctuation() {
        XCTAssertEqual(
            SpokenSendParser.parse("Ready to go send it", phrase: "send it", enabled: true),
            SpokenSendParseResult(text: "Ready to go.", shouldSend: true)
        )
    }

    func testRepeatedTerminalPhrasesAreAllRemoved() {
        XCTAssertEqual(
            SpokenSendParser.parse("I wanna send it, send it.", phrase: "send it", enabled: true),
            SpokenSendParseResult(text: "I wanna.", shouldSend: true)
        )
        XCTAssertEqual(
            SpokenSendParser.parse("Ready SEND IT send it", phrase: "send it", enabled: true),
            SpokenSendParseResult(text: "Ready.", shouldSend: true)
        )
        XCTAssertEqual(
            SpokenSendParser.parse("send it, send it.", phrase: "send it", enabled: true),
            SpokenSendParseResult(text: "", shouldSend: true)
        )
    }

    func testRepeatedTrailingSeparatorsCollapseToOneSentenceEnding() {
        XCTAssertEqual(
            SpokenSendParser.parse("Ready,,,,; — send it", phrase: "send it", enabled: true),
            SpokenSendParseResult(text: "Ready.", shouldSend: true)
        )
        XCTAssertEqual(
            SpokenSendParser.parse("Ready.,,,;— send it, send it.", phrase: "send it", enabled: true),
            SpokenSendParseResult(text: "Ready.", shouldSend: true)
        )
        XCTAssertEqual(
            SpokenSendParser.parse("Ready?,,, send it", phrase: "send it", enabled: true),
            SpokenSendParseResult(text: "Ready?", shouldSend: true)
        )
    }

    func testFinalQuestionOrExclamationMarkIsPreserved() {
        XCTAssertEqual(
            SpokenSendParser.parse("Are we ready? send it.", phrase: "send it", enabled: true),
            SpokenSendParseResult(text: "Are we ready?", shouldSend: true)
        )
        XCTAssertEqual(
            SpokenSendParser.parse("Ship it! send it.", phrase: "send it", enabled: true),
            SpokenSendParseResult(text: "Ship it!", shouldSend: true)
        )
    }

    func testImmediateStopRequiresChildOption() {
        XCTAssertTrue(
            SpokenSendParser.shouldStopImmediately(
                "Ready, send it.",
                phrase: "send it",
                spokenSendEnabled: true,
                sendImmediatelyEnabled: true
            )
        )
        XCTAssertFalse(
            SpokenSendParser.shouldStopImmediately(
                "Ready, send it.",
                phrase: "send it",
                spokenSendEnabled: true,
                sendImmediatelyEnabled: false
            )
        )
    }

    func testImmediateStopDoesNotTriggerForPhraseInMiddle() {
        XCTAssertFalse(
            SpokenSendParser.shouldStopImmediately(
                "Send it when you are ready",
                phrase: "send it",
                spokenSendEnabled: true,
                sendImmediatelyEnabled: true
            )
        )
    }

    func testTerminalASRRefinementStaysArmed() {
        XCTAssertTrue(
            SpokenSendParser.shouldStopImmediately(
                "Ready, send it",
                phrase: "send it",
                spokenSendEnabled: true,
                sendImmediatelyEnabled: true
            )
        )
        XCTAssertTrue(
            SpokenSendParser.shouldStopImmediately(
                "Ready, SEND IT.",
                phrase: "send it",
                spokenSendEnabled: true,
                sendImmediatelyEnabled: true
            )
        )
        XCTAssertFalse(
            SpokenSendParser.shouldStopImmediately(
                "Ready, send it after I finish this sentence.",
                phrase: "send it",
                spokenSendEnabled: true,
                sendImmediatelyEnabled: true
            )
        )
    }

    func testArmedSendSurvivesNoisyStreamingRefinements() {
        let armed = "Ready to go, send it."
        for noisy in ["Ready to go, sent it.", "Ready to go, send", "Ready to go send it", "Ready to go —", ""] {
            XCTAssertTrue(
                SpokenSendParser.isArmed(noisy, armedText: armed, phrase: "send it", enabled: true),
                "\(noisy) must keep the send armed"
            )
        }
        XCTAssertFalse(
            SpokenSendParser.isArmed("Ready to go, send it to Bob", armedText: armed, phrase: "send it", enabled: true)
        )
        XCTAssertFalse(
            SpokenSendParser.isArmed("Ready to go, sent it.", armedText: nil, phrase: "send it", enabled: true)
        )
        XCTAssertFalse(
            SpokenSendParser.isArmed("Ready to go, send it.", armedText: armed, phrase: "send it", enabled: false)
        )
    }

    func testArmedCountdownCompletesThroughNoisyPartial() {
        XCTAssertTrue(
            SpokenSendParser.canCompleteImmediateStop(
                "Ready, sent it.",
                phrase: "send it",
                spokenSendEnabled: true,
                sendImmediatelyEnabled: true,
                quietDuration: SpokenSendParser.immediateStopRequiredSilenceDuration,
                armedText: "Ready, send it."
            )
        )
        XCTAssertFalse(
            SpokenSendParser.canCompleteImmediateStop(
                "Ready, send it after I finish this sentence.",
                phrase: "send it",
                spokenSendEnabled: true,
                sendImmediatelyEnabled: true,
                quietDuration: SpokenSendParser.immediateStopRequiredSilenceDuration,
                armedText: "Ready, send it."
            )
        )
    }

    func testArmedFinalParseAcceptsNearMissPhrase() {
        XCTAssertEqual(
            SpokenSendParser.parseArmed("Ready to go, sent it.", phrase: "send it", enabled: true, wasArmed: true),
            SpokenSendParseResult(text: "Ready to go.", shouldSend: true)
        )
        XCTAssertEqual(
            SpokenSendParser.parseArmed("Ready to go, Send It", phrase: "send it", enabled: true, wasArmed: false),
            SpokenSendParseResult(text: "Ready to go.", shouldSend: true)
        )
        XCTAssertEqual(
            SpokenSendParser.parseArmed("Ready to go, sent it.", phrase: "send it", enabled: true, wasArmed: false),
            SpokenSendParseResult(text: "Ready to go, sent it.", shouldSend: false)
        )
        XCTAssertEqual(
            SpokenSendParser.parseArmed("Ready to go, send it to Bob", phrase: "send it", enabled: true, wasArmed: true),
            SpokenSendParseResult(text: "Ready to go, send it to Bob", shouldSend: false)
        )
        XCTAssertEqual(
            SpokenSendParser.parseArmed("Please type literal send it.", phrase: "send it", enabled: true, wasArmed: true),
            SpokenSendParseResult(text: "Please type send it", shouldSend: false)
        )
    }

    // MARK: - Adversarial: arming state machine

    private func run(_ partials: [String], phrase: String = "send it", eligible: Bool = true) -> (results: [Bool], state: SpokenSendArmingState) {
        var state = SpokenSendArmingState()
        let results = partials.map { state.update(partial: $0, isEligible: eligible, phrase: phrase) }
        return (results, state)
    }

    func testArmingSurvivesRealisticNoisyStream() {
        let stream = ["Ready", "Ready send", "Ready send it", "Ready sent it.", "Ready send", "Ready, send it.", "Ready, SEND IT"]
        let (results, state) = self.run(stream)
        XCTAssertEqual(results, [false, false, true, true, true, true, true])
        XCTAssertTrue(state.wasArmed)
    }

    func testArmingDisarmsWhenSpeechContinues() {
        let (results, state) = self.run(["Ready send it", "Ready send it to", "Ready send it to Bob"])
        XCTAssertEqual(results, [true, false, false])
        XCTAssertFalse(state.wasArmed)
    }

    func testArmingReArmsAfterContinuation() {
        let (results, state) = self.run(["Ready send it", "Ready send it to Bob", "Ready send it to Bob send it"])
        XCTAssertEqual(results, [true, false, true])
        XCTAssertEqual(state.armedText, "Ready send it to Bob send it")
    }

    func testArmingIsKeptAcrossTheStopPartial() {
        var state = SpokenSendArmingState()
        XCTAssertTrue(state.update(partial: "Ready send it", isEligible: true, phrase: "send it"))
        XCTAssertFalse(state.update(partial: "", isEligible: false, phrase: "send it"))
        XCTAssertTrue(state.wasArmed, "an ineligible partial must not forget the armed send")
        state.reset()
        XCTAssertFalse(state.wasArmed)
    }

    func testArmingNeverStartsFromANearMiss() {
        let (results, state) = self.run(["Ready sent it", "Ready sent it.", "Ready send"])
        XCTAssertEqual(results, [false, false, false])
        XCTAssertFalse(state.wasArmed)
    }

    func testArmingIgnoresPhraseInTheMiddle() {
        let (results, _) = self.run(["send it now please", "send it now please thanks"])
        XCTAssertEqual(results, [false, false])
    }

    func testArmingHoldsThroughPunctuationOnlyRefinements() {
        let (results, _) = self.run(["Ready send it", "Ready — send it …", "Ready, send it. —"])
        XCTAssertEqual(results, [true, true, true])
    }

    func testArmingWithCustomPhraseContainingRegexCharacters() {
        let (results, state) = self.run(["Done. ship it (now)", "Done. ship it (now"], phrase: "ship it (now)")
        XCTAssertEqual(results, [true, true])
        XCTAssertTrue(state.wasArmed)
    }

    func testArmingWithPunctuationOnlyPhraseDoesNotCrash() {
        var state = SpokenSendArmingState()
        _ = state.update(partial: "Hi !!!", isEligible: true, phrase: "!!!")
        _ = SpokenSendParser.parseArmed("Hi !!!", phrase: "!!!", enabled: true, wasArmed: true)
        _ = SpokenSendParser.parseArmed("Hi", phrase: "   ", enabled: true, wasArmed: true)
    }

    func testArmingStaysFastOnVeryLongPartials() {
        let long = Array(repeating: "word", count: 5000).joined(separator: " ") + " send it"
        var state = SpokenSendArmingState()
        let started = Date()
        for _ in 0..<20 {
            XCTAssertTrue(state.update(partial: long, isEligible: true, phrase: "send it"))
            XCTAssertTrue(state.update(partial: long + ".", isEligible: true, phrase: "send it"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    // MARK: - Adversarial: near-miss final parse

    func testNearMissIsRefusedForVeryShortPhrases() {
        XCTAssertEqual(
            SpokenSendParser.parseArmed("The end", phrase: "send", enabled: true, wasArmed: true),
            SpokenSendParseResult(text: "The end", shouldSend: false)
        )
        XCTAssertEqual(
            SpokenSendParser.parseArmed("The send", phrase: "send", enabled: true, wasArmed: true),
            SpokenSendParseResult(text: "The.", shouldSend: true)
        )
    }

    func testNearMissAllowsOneEditForTwoWordPhrase() {
        for tail in ["sent it", "sand it", "send if", "sendit", "Send It"] {
            XCTAssertEqual(
                SpokenSendParser.parseArmed("Ready \(tail)", phrase: "send it", enabled: true, wasArmed: true),
                SpokenSendParseResult(text: "Ready.", shouldSend: true),
                tail
            )
        }
        for tail in ["sending", "send", "sent him", "end it", "spend a bit", "bend it", "tend it"] {
            XCTAssertFalse(
                SpokenSendParser.parseArmed("Ready \(tail)", phrase: "send it", enabled: true, wasArmed: true).shouldSend,
                tail
            )
        }
    }

    func testNearMissRequiresPhraseAtTheVeryEnd() {
        XCTAssertFalse(
            SpokenSendParser.parseArmed("Ready sent it now", phrase: "send it", enabled: true, wasArmed: true).shouldSend
        )
    }

    func testNearMissIsIgnoredWhenDisabledOrNotArmed() {
        XCTAssertFalse(SpokenSendParser.parseArmed("Ready sent it", phrase: "send it", enabled: false, wasArmed: true).shouldSend)
        XCTAssertFalse(SpokenSendParser.parseArmed("Ready sent it", phrase: "send it", enabled: true, wasArmed: false).shouldSend)
    }

    func testNearMissOnEmptyOrShortTextIsSafe() {
        XCTAssertEqual(
            SpokenSendParser.parseArmed("", phrase: "send it", enabled: true, wasArmed: true),
            SpokenSendParseResult(text: "", shouldSend: false)
        )
        XCTAssertEqual(
            SpokenSendParser.parseArmed("it", phrase: "send it", enabled: true, wasArmed: true),
            SpokenSendParseResult(text: "it", shouldSend: false)
        )
    }

    // MARK: - Adversarial: paste key sequence

    func testPasteSequencePressesAndReleasesCommandExplicitly() throws {
        let events = SystemPasteCommandPoster.makePasteEvents()
        XCTAssertEqual(events.count, 4)
        let keyCodes = events.map { CGKeyCode($0.getIntegerValueField(.keyboardEventKeycode)) }
        XCTAssertEqual(keyCodes, [
            CGKeyCode(kVK_Command), TypingService.pasteVirtualKeyCode, TypingService.pasteVirtualKeyCode, CGKeyCode(kVK_Command),
        ])
        // Modifier presses are flagsChanged events, exactly like a physical Command key.
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        XCTAssertTrue(events[0].flags.contains(.maskCommand))
        XCTAssertTrue(events[1].flags.contains(.maskCommand))
        XCTAssertTrue(events[2].flags.contains(.maskCommand))
        XCTAssertFalse(events[3].flags.contains(.maskCommand), "the final event must release Command")
    }

    func testPasteSequenceIsInvisibleToTheHotkeyTap() throws {
        let events = SystemPasteCommandPoster.makePasteEvents()
        XCTAssertEqual(events.count, 4)
        for event in events {
            XCTAssertTrue(GlobalHotkeyManager.isSynthesizedTypingEvent(event))
        }
    }

    // MARK: - Paste read-back after a fast manual send

    func testReadBackStandsDownWhenUserActsAfterPaste() {
        // Return pressed 0.4 s after the paste; the verdict arrives at 1.5 s.
        XCTAssertTrue(PasteVerifier.userActedAfterPaste(secondsSinceLastInput: 1.1, secondsSincePaste: 1.5))
        // Return pressed almost immediately.
        XCTAssertTrue(PasteVerifier.userActedAfterPaste(secondsSinceLastInput: 1.4, secondsSincePaste: 1.5))
    }

    func testReadBackStillReportsWhenNothingHappenedSinceThePaste() {
        // The last input is our own synthesized V at the paste instant.
        XCTAssertFalse(PasteVerifier.userActedAfterPaste(secondsSinceLastInput: 1.5, secondsSincePaste: 1.5))
        XCTAssertFalse(PasteVerifier.userActedAfterPaste(secondsSinceLastInput: 1.48, secondsSincePaste: 1.5))
        // The last input was long before the paste.
        XCTAssertFalse(PasteVerifier.userActedAfterPaste(secondsSinceLastInput: 30, secondsSincePaste: 1.5))
    }

    func testImmediateStopCompletionRequiresTerminalPhraseAndSilence() {
        let arguments = (
            text: "Ready, send it.",
            phrase: "send it",
            spokenSendEnabled: true,
            sendImmediatelyEnabled: true
        )

        XCTAssertFalse(
            SpokenSendParser.canCompleteImmediateStop(
                arguments.text,
                phrase: arguments.phrase,
                spokenSendEnabled: arguments.spokenSendEnabled,
                sendImmediatelyEnabled: arguments.sendImmediatelyEnabled,
                quietDuration: 0
            )
        )
        XCTAssertTrue(
            SpokenSendParser.canCompleteImmediateStop(
                arguments.text,
                phrase: arguments.phrase,
                spokenSendEnabled: arguments.spokenSendEnabled,
                sendImmediatelyEnabled: arguments.sendImmediatelyEnabled,
                quietDuration: SpokenSendParser.immediateStopRequiredSilenceDuration
            )
        )
    }

    func testImmediateStopCompletionCancelsForContinuedSpeech() {
        XCTAssertFalse(
            SpokenSendParser.canCompleteImmediateStop(
                "Ready, send it after I finish this sentence.",
                phrase: "send it",
                spokenSendEnabled: true,
                sendImmediatelyEnabled: true,
                quietDuration: 2
            )
        )
    }

    func testVoiceActivityGraceIgnoresOnlyTheRecognitionTail() {
        let startedAt: TimeInterval = 100
        XCTAssertFalse(
            SpokenSendParser.shouldCancelCountdownForVoiceActivity(
                countdownStartedAt: startedAt,
                voiceActivityAt: startedAt + 0.05
            )
        )
        XCTAssertTrue(
            SpokenSendParser.shouldCancelCountdownForVoiceActivity(
                countdownStartedAt: startedAt,
                voiceActivityAt: startedAt + SpokenSendParser.immediateStopVoiceActivityGraceDuration + 0.001
            )
        )
        XCTAssertFalse(
            SpokenSendParser.isMeaningfulVoiceActivity(
                SpokenSendParser.immediateStopVoiceActivityLevelThreshold.nextDown
            )
        )
        XCTAssertTrue(
            SpokenSendParser.isMeaningfulVoiceActivity(
                SpokenSendParser.immediateStopVoiceActivityLevelThreshold
            )
        )
    }

    func testLiteralEscapeKeepsPhraseWithoutSending() {
        XCTAssertEqual(
            SpokenSendParser.parse("Please type literal send it.", phrase: "send it", enabled: true),
            SpokenSendParseResult(text: "Please type send it", shouldSend: false)
        )
    }

    func testLiteralEscapeBeforeRepeatedCommandKeepsOnePhraseAndSends() {
        XCTAssertEqual(
            SpokenSendParser.parse("Please type literal send it, send it.", phrase: "send it", enabled: true),
            SpokenSendParseResult(text: "Please type send it.", shouldSend: true)
        )
    }

    func testPhraseOnlySubmitsExistingDraftWithoutInsertingCommand() {
        XCTAssertEqual(
            SpokenSendParser.parse("Send it", phrase: "send it", enabled: true),
            SpokenSendParseResult(text: "", shouldSend: true)
        )
    }

    func testCustomPhraseAllowsFlexibleWhitespaceAndCase() {
        XCTAssertEqual(
            SpokenSendParser.parse("Looks good. PLEASE   SUBMIT", phrase: "please submit", enabled: true),
            SpokenSendParseResult(text: "Looks good.", shouldSend: true)
        )
    }

    func testAvailableSendCommandsMapToExpectedFlags() {
        XCTAssertEqual(SettingsStore.SpokenSendKey.enter.eventFlags, [])
        XCTAssertEqual(SettingsStore.SpokenSendKey.shiftEnter.eventFlags, .maskShift)
        XCTAssertEqual(SettingsStore.SpokenSendKey.commandEnter.eventFlags, .maskCommand)
    }

    func testGeneratedSendCommandsAreExcludedFromFluidVoiceHotkeys() throws {
        for key in SettingsStore.SpokenSendKey.allCases {
            let event = try XCTUnwrap(
                CGEvent(
                    keyboardEventSource: nil,
                    virtualKey: 36,
                    keyDown: true
                )
            )
            event.flags = key.eventFlags
            event.setIntegerValueField(
                .eventSourceUserData,
                value: TypingService.synthesizedEventUserData
            )

            XCTAssertTrue(
                GlobalHotkeyManager.isSynthesizedTypingEvent(event),
                "\(key.displayName) must bypass FluidVoice hotkey matching"
            )
        }

        let physicalEvent = try XCTUnwrap(
            CGEvent(
                keyboardEventSource: nil,
                virtualKey: 36,
                keyDown: true
            )
        )
        XCTAssertFalse(GlobalHotkeyManager.isSynthesizedTypingEvent(physicalEvent))
    }

    func testPostInsertionActionRequiresExactNonSecureFocus() {
        XCTAssertTrue(
            TypingService.canDispatchPostInsertionAction(
                preferredTargetPID: 42,
                requiredTargetPID: 42,
                isSecureTextField: false,
                modifiersReleased: true,
                exactFocusIsActive: true
            )
        )
        XCTAssertFalse(
            TypingService.canDispatchPostInsertionAction(
                preferredTargetPID: 42,
                requiredTargetPID: 43,
                isSecureTextField: false,
                modifiersReleased: true,
                exactFocusIsActive: true
            )
        )
        XCTAssertFalse(
            TypingService.canDispatchPostInsertionAction(
                preferredTargetPID: 42,
                requiredTargetPID: 42,
                isSecureTextField: true,
                modifiersReleased: true,
                exactFocusIsActive: true
            )
        )
        XCTAssertFalse(
            TypingService.canDispatchPostInsertionAction(
                preferredTargetPID: 42,
                requiredTargetPID: 42,
                isSecureTextField: false,
                modifiersReleased: false,
                exactFocusIsActive: true
            )
        )
        XCTAssertFalse(
            TypingService.canDispatchPostInsertionAction(
                preferredTargetPID: 42,
                requiredTargetPID: 42,
                isSecureTextField: false,
                modifiersReleased: true,
                exactFocusIsActive: false
            )
        )
    }

    func testDeliveryOutcomesReportInsertionAndSendSeparately() {
        XCTAssertTrue(TypingService.DeliveryOutcome.insertedAndActionDispatched.didInsert)
        XCTAssertTrue(TypingService.DeliveryOutcome.insertedAndActionDispatched.didDispatchAction)
        XCTAssertTrue(TypingService.DeliveryOutcome.actionDispatched.didDispatchAction)
        XCTAssertFalse(TypingService.DeliveryOutcome.actionDispatched.didInsert)
        XCTAssertTrue(TypingService.DeliveryOutcome.insertedActionSuppressed.didInsert)
        XCTAssertFalse(TypingService.DeliveryOutcome.insertedActionSuppressed.didDispatchAction)
        XCTAssertFalse(TypingService.DeliveryOutcome.insertionUnconfirmed.didInsert)
        XCTAssertFalse(TypingService.DeliveryOutcome.insertionUnconfirmed.didDispatchAction)
    }

    func testHeldModifierDoesNotBlockSafeTextInsertionBeforeSendDecision() {
        XCTAssertTrue(
            TypingService.canInsertBeforePostInsertionAction(
                preferredTargetPID: 42,
                requiredTargetPID: 42,
                isSecureTextField: false,
                exactFocusIsActive: true
            )
        )
        XCTAssertFalse(
            TypingService.canInsertBeforePostInsertionAction(
                preferredTargetPID: 42,
                requiredTargetPID: 41,
                isSecureTextField: false,
                exactFocusIsActive: true
            )
        )
        XCTAssertFalse(
            TypingService.canInsertBeforePostInsertionAction(
                preferredTargetPID: 42,
                requiredTargetPID: 42,
                isSecureTextField: true,
                exactFocusIsActive: true
            )
        )
        XCTAssertFalse(
            TypingService.canInsertBeforePostInsertionAction(
                preferredTargetPID: 42,
                requiredTargetPID: 42,
                isSecureTextField: false,
                exactFocusIsActive: false
            )
        )
    }

    func testOverlayIndicatorVisibilityCoversEveryActiveState() {
        XCTAssertFalse(SpokenSendIndicatorState.hidden.isVisible)
        XCTAssertTrue(SpokenSendIndicatorState.detected.isVisible)
        XCTAssertTrue(SpokenSendIndicatorState.countingDown.isVisible)
        XCTAssertTrue(SpokenSendIndicatorState.sending.isVisible)
        XCTAssertTrue(SpokenSendIndicatorState.sent.isVisible)
        XCTAssertTrue(SpokenSendIndicatorState.failed.isVisible)
    }

    @MainActor
    func testSettingsBackupIncludesSpokenSendConfiguration() async throws {
        let settings = SettingsStore.shared
        let originalEnabled = settings.spokenSendEnabled
        let originalImmediate = settings.spokenSendImmediatelyEnabled
        let originalPhrase = settings.spokenSendPhrase
        let originalKey = settings.spokenSendKey
        defer {
            settings.spokenSendEnabled = originalEnabled
            settings.spokenSendImmediatelyEnabled = originalImmediate
            settings.spokenSendPhrase = originalPhrase
            settings.spokenSendKey = originalKey
        }

        settings.spokenSendEnabled = true
        settings.spokenSendImmediatelyEnabled = false
        settings.spokenSendPhrase = "ship it"
        settings.spokenSendKey = .commandEnter

        let document = try await BackupService.shared.makeBackupDocument()
        XCTAssertEqual(document.settings.spokenSendEnabled, true)
        XCTAssertEqual(document.settings.spokenSendImmediatelyEnabled, false)
        XCTAssertEqual(document.settings.spokenSendPhrase, "ship it")
        XCTAssertEqual(document.settings.spokenSendKey, .commandEnter)
    }
}
