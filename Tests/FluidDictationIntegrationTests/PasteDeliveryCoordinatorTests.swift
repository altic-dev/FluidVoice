import AppKit
@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class PasteDeliveryCoordinatorTests: XCTestCase {
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

    func testOverlappingDeliveriesRestoreThePreBurstClipboardOnce() async {
        let pasteboard = FakePasteboardManager(text: "before")
        let commandPoster = FakePasteCommandPoster()
        let coordinator = PasteDeliveryCoordinator(
            pasteboard: pasteboard,
            commandPoster: commandPoster,
            settlementDelayNanoseconds: .max
        )

        let firstResult = await coordinator.deliver("first", preserveTranscriptOnClipboard: false)
        let secondResult = await coordinator.deliver("second", preserveTranscriptOnClipboard: false)

        XCTAssertEqual(firstResult, .commandPosted)
        XCTAssertEqual(secondResult, .commandPosted)
        coordinator.runPendingSettlementForTesting()

        XCTAssertEqual(commandPoster.postCount, 2)
        XCTAssertEqual(pasteboard.text, "before")
        XCTAssertEqual(pasteboard.restoreCount, 1)
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
        let secondResult = await secondDelivery.value

        XCTAssertEqual(firstResult, .commandPosted)
        XCTAssertEqual(secondResult, .commandPosted)
        XCTAssertEqual(pasteboard.temporaryWriteCount, 2)
        XCTAssertEqual(commandPoster.postCount, 2)
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

    func testPasteCommandFailureRestoresOriginalClipboardWhenCopyPreferenceIsEnabled() async {
        let pasteboard = FakePasteboardManager(text: "before")
        let coordinator = PasteDeliveryCoordinator(
            pasteboard: pasteboard,
            commandPoster: FakePasteCommandPoster(succeeds: false),
            settlementDelayNanoseconds: .max
        )

        let result = await coordinator.deliver("dictated text", preserveTranscriptOnClipboard: true)

        XCTAssertEqual(result, .recoverableFailure(.pasteCommandFailed))
        XCTAssertEqual(pasteboard.text, "before")
        XCTAssertEqual(pasteboard.restoreCount, 1)
        XCTAssertEqual(pasteboard.intentionalWriteCount, 0)
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

    func testHundredRapidDeliveriesDoNotDropCommands() async {
        let pasteboard = FakePasteboardManager(text: "before")
        let commandPoster = FakePasteCommandPoster()
        let coordinator = PasteDeliveryCoordinator(
            pasteboard: pasteboard,
            commandPoster: commandPoster,
            settlementDelayNanoseconds: .max
        )

        for index in 0..<100 {
            let result = await coordinator.deliver("dictation \(index)", preserveTranscriptOnClipboard: false)
            XCTAssertEqual(result, .commandPosted)
        }
        coordinator.runPendingSettlementForTesting()

        XCTAssertEqual(commandPoster.postCount, 100)
        XCTAssertEqual(pasteboard.text, "before")
        XCTAssertEqual(pasteboard.restoreCount, 1)
    }

    func testClipboardRestorationUsesHalfSecondDelay() {
        XCTAssertEqual(PasteDeliveryCoordinator.defaultSettlementDelayNanoseconds, 500_000_000)
    }

    func testPasteKeyResolverUsesTheKeyThatProducesVInTheActiveLayout() {
        let resolvedKeyCode = KeyboardLayoutKeyCodeResolver.keyCode(
            for: "v",
            qwertyFallback: 0x09
        ) { keyCode in
            keyCode == 0x2a ? "v" : nil
        }

        XCTAssertEqual(resolvedKeyCode, 0x2a)
    }

    func testPasteKeyResolverFallsBackWhenTheLayoutDoesNotExposeV() {
        let resolvedKeyCode = KeyboardLayoutKeyCodeResolver.keyCode(
            for: "v",
            qwertyFallback: 0x09,
            translatedScalar: { _ in nil }
        )

        XCTAssertEqual(resolvedKeyCode, 0x09)
    }

    func testRecoveryActivationNeverRequestsAllWindows() {
        XCTAssertTrue(TypingService.recoveryActivationOptions.contains(.activateIgnoringOtherApps))
        XCTAssertFalse(TypingService.recoveryActivationOptions.contains(.activateAllWindows))
    }

    func testDeliveryFailureStateKeepsTheExactTranscriptForRecovery() {
        let state = NotchContentState.shared
        defer { state.clearTextDeliveryFailure() }

        state.showTextDeliveryFailure(message: "Could not insert", transcript: "exact failed output")

        XCTAssertTrue(state.isTextDeliveryFailureVisible)
        XCTAssertEqual(state.textDeliveryFailureMessage, "Could not insert")
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
    private(set) var text: String
    private(set) var restoreCount = 0
    private(set) var intentionalWriteCount = 0
    private(set) var temporaryWriteCount = 0
    private(set) var isTemporary = false
    private let snapshotSucceeds: Bool
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
        self.temporaryWriteCount += 1
        self.text = text
        self.sessionID = sessionID
        self.isTemporary = true
        return self.temporaryWriteSucceeds
    }

    func writeIntentionalText(_ text: String) -> Bool {
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

    func simulateExternalCopy(_ text: String) {
        self.text = text
        self.sessionID = nil
        self.isTemporary = false
    }
}

@MainActor
private final class FakePasteCommandPoster: PasteCommandPosting {
    private let succeeds: Bool
    private(set) var postCount = 0

    init(succeeds: Bool = true) {
        self.succeeds = succeeds
    }

    func postGlobalPasteCommand() async -> Bool {
        self.postCount += 1
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
