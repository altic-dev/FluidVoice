import CoreGraphics
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class SpokenSendTests: XCTestCase {
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
    func testSettingsBackupIncludesSpokenSendConfiguration() async {
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

        let document = await BackupService.shared.makeBackupDocument()
        XCTAssertEqual(document.settings.spokenSendEnabled, true)
        XCTAssertEqual(document.settings.spokenSendImmediatelyEnabled, false)
        XCTAssertEqual(document.settings.spokenSendPhrase, "ship it")
        XCTAssertEqual(document.settings.spokenSendKey, .commandEnter)
    }
}
