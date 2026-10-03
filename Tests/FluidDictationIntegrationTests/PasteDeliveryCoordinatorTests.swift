import AppKit
@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class PasteDeliveryCoordinatorTests: XCTestCase {
    func testCancelledFocusPreparationDoesNotCopyBackup() async {
        let pasteboard = FakePasteboardManager(text: "before")
        let poster = FakePasteCommandPoster()
        let coordinator = PasteDeliveryCoordinator(pasteboard: pasteboard, commandPoster: poster, settlementDelayNanoseconds: .max)
        var valid = true
        var resumeFocus: CheckedContinuation<Bool, Never>?
        let preparation = Task { @MainActor in
            await coordinator.prepareForDelivery("cancelled", preserveTranscriptOnClipboard: true, isOutputValid: { valid }) {
                await withCheckedContinuation { resumeFocus = $0 }
            }
        }
        await self.waitUntil { resumeFocus != nil }
        valid = false
        resumeFocus?.resume(returning: false)
        let ready = await preparation.value
        XCTAssertFalse(ready)
        XCTAssertEqual(pasteboard.text, "before")
        XCTAssertEqual(pasteboard.intentionalWriteCount, 0)
        XCTAssertEqual(poster.postCount, 0)
        let next = await coordinator.deliver("next", preserveTranscriptOnClipboard: false)
        XCTAssertEqual(next, .commandPosted)
        coordinator.runPendingSettlementForTesting()
        XCTAssertEqual(pasteboard.text, "before")
    }

    func testCancelledQueuedBackupDoesNotWriteAndReleasesSlot() async {
        let pasteboard = FakePasteboardManager(text: "before")
        let poster = FakePasteCommandPoster()
        let coordinator = PasteDeliveryCoordinator(pasteboard: pasteboard, commandPoster: poster, settlementDelayNanoseconds: .max)
        _ = await coordinator.deliver("first", preserveTranscriptOnClipboard: false)
        var valid = true
        var queued = false
        let backup = Task { @MainActor in
            queued = true
            return await coordinator.copyBackup("cancelled", enabled: true, isOutputValid: { valid })
        }
        await self.waitUntil { queued }
        valid = false
        coordinator.runPendingSettlementForTesting()
        let copied = await backup.value
        XCTAssertFalse(copied)
        XCTAssertEqual(pasteboard.text, "before")
        XCTAssertEqual(pasteboard.intentionalWriteCount, 0)
        XCTAssertEqual(pasteboard.temporaryWriteCount, 1)
        let next = await coordinator.deliver("next", preserveTranscriptOnClipboard: false)
        XCTAssertEqual(next, .commandPosted)
        XCTAssertEqual(poster.postCount, 2)
        coordinator.runPendingSettlementForTesting()
    }

    func testCancelledQueuedPasteDoesNotWriteOrPostAndNextDeliveryWorks() async {
        let pasteboard = FakePasteboardManager(text: "before")
        let poster = FakePasteCommandPoster()
        let coordinator = PasteDeliveryCoordinator(pasteboard: pasteboard, commandPoster: poster, settlementDelayNanoseconds: .max)
        _ = await coordinator.deliver("first", preserveTranscriptOnClipboard: false)
        var valid = true
        var queued = false
        let delivery = Task { @MainActor in
            queued = true
            return await coordinator.deliver("cancelled", preserveTranscriptOnClipboard: true, isOutputValid: { valid })
        }
        await self.waitUntil { queued }
        valid = false
        coordinator.runPendingSettlementForTesting()
        let result = await delivery.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(pasteboard.text, "before")
        XCTAssertEqual(pasteboard.temporaryWriteCount, 1)
        XCTAssertEqual(pasteboard.intentionalWriteCount, 0)
        XCTAssertEqual(poster.postCount, 1)
        let next = await coordinator.deliver("next", preserveTranscriptOnClipboard: false)
        XCTAssertEqual(next, .commandPosted)
        XCTAssertEqual(poster.postCount, 2)
        coordinator.runPendingSettlementForTesting()
    }

    func testCancelledPostedPasteRestoresInsteadOfKeepingTranscript() async {
        let pasteboard = FakePasteboardManager(text: "before")
        let coordinator = PasteDeliveryCoordinator(pasteboard: pasteboard, commandPoster: FakePasteCommandPoster(), settlementDelayNanoseconds: .max)
        var valid = true
        let result = await coordinator.deliver("posted", preserveTranscriptOnClipboard: true, isOutputValid: { valid })
        XCTAssertEqual(result, .commandPosted)
        valid = false
        coordinator.runPendingSettlementForTesting()
        XCTAssertEqual(pasteboard.text, "before")
        XCTAssertEqual(pasteboard.intentionalWriteCount, 0)
        XCTAssertEqual(pasteboard.restoreCount, 1)
    }

    func testPasteCheckAlertsDefaultOffAndRoundTripThroughBackup() {
        let settings = SettingsStore.shared
        let original = settings.showPasteCheckAlerts
        defer { settings.showPasteCheckAlerts = original }

        UserDefaults.standard.removeObject(forKey: "ShowPasteCheckAlerts")
        XCTAssertFalse(settings.showPasteCheckAlerts)

        settings.showPasteCheckAlerts = true
        XCTAssertTrue(settings.showPasteCheckAlerts)
        XCTAssertEqual(settings.makeBackupPayload().showPasteCheckAlerts, true)
    }

    func testDeliveryPostsImmediatelyAndRestoresOriginalClipboard() async {
        let pasteboard = FakePasteboardManager(text: "before")
        let commandPoster = FakePasteCommandPoster()
        let coordinator = PasteDeliveryCoordinator(
            pasteboard: pasteboard,
            commandPoster: commandPoster,
            settlementDelayNanoseconds: .max
        )

        let result = await coordinator.deliver("dictated text", preserveTranscriptOnClipboard: false)

        XCTAssertEqual(result, .commandPosted)
        XCTAssertEqual(commandPoster.postCount, 1)
        XCTAssertEqual(pasteboard.text, "dictated text")

        coordinator.runPendingSettlementForTesting()

        XCTAssertEqual(pasteboard.text, "before")
        XCTAssertEqual(pasteboard.restoreCount, 1)
    }

    func testQueuedDeliveryKeepsFirstPayloadUntilConsumptionWindowEnds() async {
        let pasteboard = FakePasteboardManager(text: "before")
        let commandPoster = FakePasteCommandPoster()
        let coordinator = PasteDeliveryCoordinator(
            pasteboard: pasteboard,
            commandPoster: commandPoster,
            settlementDelayNanoseconds: .max
        )

        let firstResult = await coordinator.deliver("first", preserveTranscriptOnClipboard: false)
        var secondStarted = false
        let secondDelivery = Task { @MainActor in
            secondStarted = true
            return await coordinator.deliver("second", preserveTranscriptOnClipboard: false)
        }
        await self.waitUntil { secondStarted }

        XCTAssertEqual(firstResult, .commandPosted)
        XCTAssertEqual(commandPoster.postCount, 1)
        XCTAssertEqual(pasteboard.text, "first")
        var consumedTexts = [pasteboard.text]
        coordinator.runPendingSettlementForTesting()

        let secondResult = await secondDelivery.value
        XCTAssertEqual(secondResult, .commandPosted)
        consumedTexts.append(pasteboard.text)
        coordinator.runPendingSettlementForTesting()

        XCTAssertEqual(consumedTexts, ["first", "second"])
        XCTAssertEqual(commandPoster.postCount, 2)
        XCTAssertEqual(pasteboard.text, "before")
        XCTAssertEqual(pasteboard.restoreCount, 2)
    }

    func testOverlappingDeliveriesDoNotReplaceClipboardDuringActivePasteCommand() async {
        let pasteboard = FakePasteboardManager(text: "before")
        let commandPoster = SuspendingFakePasteCommandPoster()
        let coordinator = PasteDeliveryCoordinator(
            pasteboard: pasteboard,
            commandPoster: commandPoster,
            settlementDelayNanoseconds: .max
        )

        let firstDelivery = Task { @MainActor in
            await coordinator.deliver("first", preserveTranscriptOnClipboard: false)
        }
        await self.waitUntil { commandPoster.firstPostIsSuspended }

        let secondDelivery = Task { @MainActor in
            await coordinator.deliver("second", preserveTranscriptOnClipboard: false)
        }
        await Task.yield()

        XCTAssertEqual(pasteboard.text, "first")
        XCTAssertEqual(pasteboard.temporaryWriteCount, 1)
        XCTAssertEqual(commandPoster.postCount, 1)

        commandPoster.resumeFirstPost()
        let firstResult = await firstDelivery.value
        XCTAssertEqual(pasteboard.text, "first")
        XCTAssertEqual(commandPoster.postCount, 1)
        coordinator.runPendingSettlementForTesting()
        let secondResult = await secondDelivery.value

        XCTAssertEqual(firstResult, .commandPosted)
        XCTAssertEqual(secondResult, .commandPosted)
        XCTAssertEqual(pasteboard.temporaryWriteCount, 2)
        XCTAssertEqual(commandPoster.postCount, 2)
        coordinator.runPendingSettlementForTesting()
    }

    func testExternalClipboardChangeIsNeverOverwritten() async {
        let pasteboard = FakePasteboardManager(text: "before")
        let coordinator = PasteDeliveryCoordinator(
            pasteboard: pasteboard,
            commandPoster: FakePasteCommandPoster(),
            settlementDelayNanoseconds: .max
        )

        let result = await coordinator.deliver("dictated text", preserveTranscriptOnClipboard: false)

        XCTAssertEqual(result, .commandPosted)
        pasteboard.simulateExternalCopy("user copy")
        coordinator.runPendingSettlementForTesting()

        XCTAssertEqual(pasteboard.text, "user copy")
        XCTAssertEqual(pasteboard.restoreCount, 0)
    }

    func testCopyTranscriptPreferenceKeepsTranscriptOnClipboard() async {
        let pasteboard = FakePasteboardManager(text: "before")
        let coordinator = PasteDeliveryCoordinator(
            pasteboard: pasteboard,
            commandPoster: FakePasteCommandPoster(),
            settlementDelayNanoseconds: .max
        )

        let result = await coordinator.deliver("dictated text", preserveTranscriptOnClipboard: true)

        XCTAssertEqual(result, .commandPosted)
        XCTAssertTrue(pasteboard.isTemporary)

        coordinator.runPendingSettlementForTesting()

        XCTAssertEqual(pasteboard.text, "dictated text")
        XCTAssertEqual(pasteboard.restoreCount, 0)
        XCTAssertEqual(pasteboard.intentionalWriteCount, 1)
        XCTAssertFalse(pasteboard.isTemporary)
    }

    func testExternalClipboardChangeWinsOverCopyTranscriptPreference() async {
        let pasteboard = FakePasteboardManager(text: "before")
        let coordinator = PasteDeliveryCoordinator(
            pasteboard: pasteboard,
            commandPoster: FakePasteCommandPoster(),
            settlementDelayNanoseconds: .max
        )

        let result = await coordinator.deliver("dictated text", preserveTranscriptOnClipboard: true)

        XCTAssertEqual(result, .commandPosted)
        pasteboard.simulateExternalCopy("user copy")
        coordinator.runPendingSettlementForTesting()

        XCTAssertEqual(pasteboard.text, "user copy")
        XCTAssertEqual(pasteboard.intentionalWriteCount, 0)
    }

    func testPasteCommandFailureRestoresOriginalClipboardForRecovery() async {
        let pasteboard = FakePasteboardManager(text: "before")
        let commandPoster = FakePasteCommandPoster(succeeds: false)
        let coordinator = PasteDeliveryCoordinator(
            pasteboard: pasteboard,
            commandPoster: commandPoster,
            settlementDelayNanoseconds: .max
        )

        let result = await coordinator.deliver("dictated text", preserveTranscriptOnClipboard: false)
        coordinator.runPendingSettlementForTesting()

        XCTAssertEqual(result, .recoverableFailure(.pasteCommandFailed))
        XCTAssertEqual(pasteboard.text, "before")
        XCTAssertEqual(pasteboard.restoreCount, 1)
        XCTAssertFalse(pasteboard.isTemporary)
    }

    func testPasteCommandFailureKeepsTranscriptWhenCopyPreferenceIsEnabled() async {
        let pasteboard = FakePasteboardManager(text: "before")
        let coordinator = PasteDeliveryCoordinator(
            pasteboard: pasteboard,
            commandPoster: FakePasteCommandPoster(succeeds: false),
            settlementDelayNanoseconds: .max
        )

        let result = await coordinator.deliver("dictated text", preserveTranscriptOnClipboard: true)

        XCTAssertEqual(result, .recoverableFailure(.pasteCommandFailed))
        XCTAssertEqual(pasteboard.text, "dictated text")
        XCTAssertEqual(pasteboard.restoreCount, 0)
        XCTAssertEqual(pasteboard.intentionalWriteCount, 1)
    }

    func testIncompleteSnapshotDoesNotTouchClipboardOrPostPasteCommand() async {
        let pasteboard = FakePasteboardManager(text: "before", snapshotSucceeds: false)
        let commandPoster = FakePasteCommandPoster()
        let coordinator = PasteDeliveryCoordinator(
            pasteboard: pasteboard,
            commandPoster: commandPoster,
            settlementDelayNanoseconds: .max
        )

        let result = await coordinator.deliver("dictated text", preserveTranscriptOnClipboard: false)

        XCTAssertEqual(result, .recoverableFailure(.clipboardSnapshotFailed))
        XCTAssertEqual(pasteboard.text, "before")
        XCTAssertEqual(pasteboard.temporaryWriteCount, 0)
        XCTAssertEqual(commandPoster.postCount, 0)
    }

    func testTemporaryWriteFailureRestoresOriginalClipboard() async {
        let pasteboard = FakePasteboardManager(text: "before", temporaryWriteSucceeds: false)
        let commandPoster = FakePasteCommandPoster()
        let coordinator = PasteDeliveryCoordinator(
            pasteboard: pasteboard,
            commandPoster: commandPoster,
            settlementDelayNanoseconds: .max
        )

        let result = await coordinator.deliver("dictated text", preserveTranscriptOnClipboard: false)

        XCTAssertEqual(result, .recoverableFailure(.clipboardWriteFailed))
        XCTAssertEqual(pasteboard.text, "before")
        XCTAssertEqual(pasteboard.restoreCount, 1)
        XCTAssertEqual(commandPoster.postCount, 0)
    }

    func testExternalCopyDuringFailedWriteIsPreserved() async {
        let pasteboard = FakePasteboardManager(text: "before", temporaryWriteSucceeds: false)
        pasteboard.onTemporaryWrite = { pasteboard.simulateExternalCopy("new user copy") }
        let commandPoster = FakePasteCommandPoster()
        let coordinator = PasteDeliveryCoordinator(
            pasteboard: pasteboard,
            commandPoster: commandPoster,
            settlementDelayNanoseconds: .max
        )

        let result = await coordinator.deliver("dictated text", preserveTranscriptOnClipboard: false)

        XCTAssertEqual(result, .recoverableFailure(.clipboardWriteFailed))
        XCTAssertEqual(pasteboard.text, "new user copy")
        XCTAssertEqual(pasteboard.restoreCount, 0)
        XCTAssertEqual(commandPoster.postCount, 0)
        pasteboard.onTemporaryWrite = nil
    }

    func testExternalCopyDuringFailedPostIsPreserved() async {
        let pasteboard = FakePasteboardManager(text: "before")
        let commandPoster = FakePasteCommandPoster(succeeds: false)
        commandPoster.onPost = { pasteboard.simulateExternalCopy("new user copy") }
        let coordinator = PasteDeliveryCoordinator(
            pasteboard: pasteboard,
            commandPoster: commandPoster,
            settlementDelayNanoseconds: .max
        )

        let result = await coordinator.deliver("dictated text", preserveTranscriptOnClipboard: false)

        XCTAssertEqual(result, .recoverableFailure(.pasteCommandFailed))
        XCTAssertEqual(pasteboard.text, "new user copy")
        XCTAssertEqual(pasteboard.restoreCount, 0)
    }

    func testSnapshotFailureReleasesSlotForNextDelivery() async {
        let pasteboard = FakePasteboardManager(text: "before", snapshotSucceeds: false)
        let coordinator = PasteDeliveryCoordinator(
            pasteboard: pasteboard,
            commandPoster: FakePasteCommandPoster(),
            settlementDelayNanoseconds: .max
        )
        let firstResult = await coordinator.deliver("first", preserveTranscriptOnClipboard: false)
        XCTAssertEqual(firstResult, .recoverableFailure(.clipboardSnapshotFailed))
        pasteboard.snapshotSucceeds = true
        var nextResult: TextDeliveryResult?
        let nextDelivery = Task { @MainActor in
            nextResult = await coordinator.deliver("second", preserveTranscriptOnClipboard: false)
        }
        await self.waitUntil { nextResult != nil }
        XCTAssertEqual(nextResult, .commandPosted)
        XCTAssertEqual(pasteboard.text, "second")
        coordinator.runPendingSettlementForTesting()
        nextDelivery.cancel()
    }

    func testSettlementAfterExternalCopyReleasesQueuedDelivery() async {
        let pasteboard = FakePasteboardManager(text: "before")
        let coordinator = PasteDeliveryCoordinator(
            pasteboard: pasteboard,
            commandPoster: FakePasteCommandPoster(),
            settlementDelayNanoseconds: .max
        )
        let firstResult = await coordinator.deliver("first", preserveTranscriptOnClipboard: false)
        XCTAssertEqual(firstResult, .commandPosted)
        var nextResult: TextDeliveryResult?
        var nextStarted = false
        let nextDelivery = Task { @MainActor in
            nextStarted = true
            nextResult = await coordinator.deliver("second", preserveTranscriptOnClipboard: false)
        }
        await self.waitUntil { nextStarted }
        pasteboard.simulateExternalCopy("new user copy")
        coordinator.runPendingSettlementForTesting()
        XCTAssertEqual(pasteboard.text, "new user copy")
        XCTAssertEqual(pasteboard.restoreCount, 0)
        await self.waitUntil { nextResult != nil }
        XCTAssertEqual(nextResult, .commandPosted)
        XCTAssertEqual(pasteboard.text, "second")
        coordinator.runPendingSettlementForTesting()
        XCTAssertEqual(pasteboard.text, "new user copy")
        nextDelivery.cancel()
    }

    func testHundredDeliveriesPreserveEveryPayloadThroughConsumptionWindow() async {
        let pasteboard = FakePasteboardManager(text: "before")
        let commandPoster = FakePasteCommandPoster()
        let coordinator = PasteDeliveryCoordinator(
            pasteboard: pasteboard,
            commandPoster: commandPoster,
            settlementDelayNanoseconds: .max
        )

        var consumedTexts: [String] = []
        for index in 0..<100 {
            let result = await coordinator.deliver("dictation \(index)", preserveTranscriptOnClipboard: false)
            XCTAssertEqual(result, .commandPosted)
            consumedTexts.append(pasteboard.text)
            coordinator.runPendingSettlementForTesting()
        }

        XCTAssertEqual(consumedTexts, (0..<100).map { "dictation \($0)" })
        XCTAssertEqual(commandPoster.postCount, 100)
        XCTAssertEqual(pasteboard.text, "before")
        XCTAssertEqual(pasteboard.restoreCount, 100)
    }

    func testProductionSettlementTimerReleasesQueuedDelivery() async {
        let pasteboard = FakePasteboardManager(text: "before")
        let coordinator = PasteDeliveryCoordinator(
            pasteboard: pasteboard,
            commandPoster: FakePasteCommandPoster()
        )
        let firstResult = await coordinator.deliver("first", preserveTranscriptOnClipboard: false)
        XCTAssertEqual(firstResult, .commandPosted)
        let firstPostedAt = ProcessInfo.processInfo.systemUptime
        var secondPostedAt: TimeInterval?
        let secondDelivery = Task { @MainActor in
            _ = await coordinator.deliver("second", preserveTranscriptOnClipboard: false)
            secondPostedAt = ProcessInfo.processInfo.systemUptime
        }
        // Bounded wait also catches a slot that never releases after settlement.
        for _ in 0..<200 where secondPostedAt == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(secondPostedAt)
        if let secondPostedAt {
            XCTAssertGreaterThanOrEqual(secondPostedAt - firstPostedAt, 0.45)
            XCTAssertEqual(pasteboard.text, "second")
        }
        coordinator.runPendingSettlementForTesting()
        secondDelivery.cancel()
    }

    func testClipboardRestorationUsesHalfSecondDelay() {
        XCTAssertEqual(PasteDeliveryCoordinator.defaultSettlementDelayNanoseconds, 500_000_000)
    }

    func testEveryDeliveryFailureExceptEmptyTextIsVisible() {
        XCTAssertEqual(TextDeliveryFailure.accessibilityNotTrusted.userFacingMessage, "Enable Accessibility to insert text")
        XCTAssertNil(TextDeliveryFailure.emptyText.userFacingMessage)
        XCTAssertNil(DeliveryFailureOverlayController.Kind(failure: .emptyText))
        let visibleFailures: [TextDeliveryFailure] = [
            .accessibilityNotTrusted, .noEditableTarget, .pasteNotLanded, .insertionUnconfirmed,
            .clipboardSnapshotFailed, .clipboardWriteFailed,
            .pasteCommandFailed, .targetUnavailable, .targetRestoreFailed,
        ]
        for failure in visibleFailures {
            XCTAssertNotNil(failure.userFacingMessage, "Silent failure: \(failure)")
            XCTAssertNotNil(DeliveryFailureOverlayController.Kind(failure: failure), "No card for: \(failure)")
        }
        XCTAssertEqual(DeliveryFailureOverlayController.Kind(failure: .accessibilityNotTrusted)?.offersAccessibilitySettings, true)
        XCTAssertEqual(DeliveryFailureOverlayController.Kind(failure: .pasteCommandFailed), .deliveryFailed)
    }

    func testHiddenOverlayFailuresUseTheTransientCard() {
        // The no-AI fast path hides the dictation overlay before delivery, so
        // a failure found afterwards must surface on the transient card.
        XCTAssertTrue(MenuBarManager.usesTransientFailureCard(kind: .deliveryFailed, overlayVisible: false))
        XCTAssertTrue(MenuBarManager.usesTransientFailureCard(kind: .pasteNotLanded, overlayVisible: false))
        XCTAssertTrue(MenuBarManager.usesTransientFailureCard(kind: .accessibilityNotTrusted, overlayVisible: true))
        XCTAssertTrue(MenuBarManager.usesTransientFailureCard(kind: .noEditableTarget, overlayVisible: true))
        XCTAssertFalse(MenuBarManager.usesTransientFailureCard(kind: .deliveryFailed, overlayVisible: true))
    }

    func testLaterFailureReplacesPriorErrorAndRetainsTranscript() {
        let state = NotchContentState.shared
        defer { state.clearTextDeliveryFailure() }
        state.recordTextDeliveryFailure(.accessibilityNotTrusted, transcript: "earlier")
        state.recordTextDeliveryFailure(.clipboardSnapshotFailed, transcript: "retained output")
        XCTAssertTrue(state.isTextDeliveryFailureVisible)
        XCTAssertEqual(state.textDeliveryFailure, .clipboardSnapshotFailed)
        XCTAssertEqual(state.textDeliveryFailureMessage, "Oops, text wasn't inserted")
        XCTAssertEqual(state.textDeliveryFailureTranscript, "retained output")
    }

    func testPasteNotLandedVerdictWaitsAtLeastOneAndAHalfSeconds() {
        // A slow app that applies Cmd+V late must never draw a failure card.
        XCTAssertGreaterThanOrEqual(PasteVerifier.totalDecisionDelay, 1.5)
        XCTAssertEqual(PasteVerifier.finalCheckDelay, 1.0)
    }

    func testAccessibilityMessagingTimeoutIsBounded() {
        // Well under the ~6 s system default so a hung target app cannot
        // stall the main thread and the keyboard tap for that long.
        XCTAssertEqual(AccessibilityMessagingTimeout.seconds, 2)
        XCTAssertLessThan(AccessibilityMessagingTimeout.seconds, 6)
    }

    func testRecoveryActivationNeverRequestsAllWindows() {
        XCTAssertTrue(TypingService.recoveryActivationOptions.contains(.activateIgnoringOtherApps))
        XCTAssertFalse(TypingService.recoveryActivationOptions.contains(.activateAllWindows))
    }

    func testDeliveryFailureStateKeepsTheExactTranscriptForRecovery() {
        let state = NotchContentState.shared
        defer { state.clearTextDeliveryFailure() }

        state.recordTextDeliveryFailure(.accessibilityNotTrusted, transcript: "exact failed output")

        XCTAssertTrue(state.isTextDeliveryFailureVisible)
        XCTAssertEqual(state.textDeliveryFailureMessage, "Enable Accessibility to insert text")
        XCTAssertEqual(state.textDeliveryFailureTranscript, "exact failed output")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

final class TextInsertionModeMigrationTests: XCTestCase {
    private let modeKey = "TextInsertionMode"
    private let migrationKey = "TextInsertionModeMigratedToReliablePasteV1"

    func testMigrationOverridesExistingDirectModeOnce() throws {
        let defaults = try self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: self.name) }
        defaults.set(SettingsStore.TextInsertionMode.standard.rawValue, forKey: self.modeKey)

        SettingsStore.migrateTextInsertionModeToReliablePasteIfNeeded(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: self.modeKey), SettingsStore.TextInsertionMode.reliablePaste.rawValue)
        XCTAssertTrue(defaults.bool(forKey: self.migrationKey))

        defaults.set(SettingsStore.TextInsertionMode.standard.rawValue, forKey: self.modeKey)
        SettingsStore.migrateTextInsertionModeToReliablePasteIfNeeded(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: self.modeKey), SettingsStore.TextInsertionMode.standard.rawValue)
    }

    func testMigrationDefaultsUnsetModeToReliablePaste() throws {
        let defaults = try self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: self.name) }

        SettingsStore.migrateTextInsertionModeToReliablePasteIfNeeded(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: self.modeKey), SettingsStore.TextInsertionMode.reliablePaste.rawValue)
        XCTAssertTrue(defaults.bool(forKey: self.migrationKey))
    }

    func testRecommendedModeAppearsFirst() {
        XCTAssertEqual(SettingsStore.TextInsertionMode.allCases.first, .reliablePaste)
        XCTAssertEqual(SettingsStore.TextInsertionMode.reliablePaste.displayName, "Clipboard Paste (Recommended)")
        XCTAssertEqual(SettingsStore.TextInsertionMode.standard.displayName, "Direct Paste")
    }

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: self.name))
        defaults.removePersistentDomain(forName: self.name)
        return defaults
    }
}

@MainActor
private final class FakePasteboardManager: PasteboardManaging {
    private(set) var changeCount = 0
    private(set) var text: String
    private(set) var restoreCount = 0
    private(set) var intentionalWriteCount = 0
    private(set) var temporaryWriteCount = 0
    private(set) var isTemporary = false
    var snapshotSucceeds: Bool
    var onTemporaryWrite: (() -> Void)?
    private let temporaryWriteSucceeds: Bool
    private var sessionID: String?

    init(
        text: String,
        snapshotSucceeds: Bool = true,
        temporaryWriteSucceeds: Bool = true
    ) {
        self.text = text
        self.snapshotSucceeds = snapshotSucceeds
        self.temporaryWriteSucceeds = temporaryWriteSucceeds
    }

    func captureSnapshot() -> PasteboardSnapshot? {
        guard self.snapshotSucceeds else { return nil }
        return PasteboardSnapshot(items: [
            .init(representations: [
                .init(type: .string, data: Data(self.text.utf8)),
            ]),
        ])
    }

    func writeTemporaryText(_ text: String, sessionID: String) -> Bool {
        self.changeCount += 1
        self.temporaryWriteCount += 1
        self.text = text
        self.sessionID = sessionID
        self.isTemporary = true
        self.onTemporaryWrite?()
        return self.temporaryWriteSucceeds
    }

    func writeIntentionalText(_ text: String) -> Bool {
        self.changeCount += 1
        self.intentionalWriteCount += 1
        self.text = text
        self.sessionID = nil
        self.isTemporary = false
        return true
    }

    func isOwned(sessionID: String, expectedText: String) -> Bool {
        self.sessionID == sessionID && self.text == expectedText
    }

    func restore(_ snapshot: PasteboardSnapshot) -> Bool {
        self.changeCount += 1
        self.restoreCount += 1
        self.sessionID = nil
        self.isTemporary = false
        guard let data = snapshot.items.first?.representations.first(where: { $0.type == .string })?.data,
              let restoredText = String(data: data, encoding: .utf8)
        else {
            self.text = ""
            return snapshot.items.isEmpty
        }
        self.text = restoredText
        return true
    }

    func restoreTemporarySnapshot(
        _ snapshot: PasteboardSnapshot,
        sessionID: String,
        expectedText: String
    ) -> Bool {
        guard self.isOwned(sessionID: sessionID, expectedText: expectedText) else { return false }
        return self.restore(snapshot)
    }

    func simulateExternalCopy(_ text: String) {
        self.changeCount += 1
        self.text = text
        self.sessionID = nil
        self.isTemporary = false
    }
}

@MainActor
private final class FakePasteCommandPoster: PasteCommandPosting {
    private let succeeds: Bool
    private(set) var postCount = 0
    var onPost: (() -> Void)?

    init(succeeds: Bool = true) {
        self.succeeds = succeeds
    }

    func postGlobalPasteCommand() async -> Bool {
        self.postCount += 1
        self.onPost?()
        return self.succeeds
    }
}

@MainActor
private final class SuspendingFakePasteCommandPoster: PasteCommandPosting {
    private(set) var postCount = 0
    private(set) var firstPostIsSuspended = false
    private var firstPostContinuation: CheckedContinuation<Void, Never>?

    func postGlobalPasteCommand() async -> Bool {
        self.postCount += 1
        guard self.postCount == 1 else { return true }

        self.firstPostIsSuspended = true
        await withCheckedContinuation { continuation in
            self.firstPostContinuation = continuation
        }
        return true
    }

    func resumeFirstPost() {
        let continuation = self.firstPostContinuation
        self.firstPostContinuation = nil
        continuation?.resume()
    }
}
