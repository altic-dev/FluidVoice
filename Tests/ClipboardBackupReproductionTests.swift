import AppKit

/// Runs the production coordinator and SystemPasteboardManager on a private pasteboard.
/// Only command posting and optional I/O failures are injected; no keys are sent.
/// Assertions cover backup failure recovery and preservation of newer user copies.
@main
@MainActor
enum ClipboardBackupReproductionTests {
    static func main() async {
        var failures = 0
        var cases = 0
        self.testOversizedFileFallback()
        for keepBackup in [false, true] {
            for scenario in Scenario.allCases {
                cases += 1
                let board = NSPasteboard(name: .init("fluidvoice.backup-reproduction.\(UUID().uuidString)"))
                defer { board.releaseGlobally() }
                let manager = InjectedPasteboard(board: board, scenario: scenario)
                precondition(manager.base.writeIntentionalText("old clipboard"))
                let poster = InjectedCommandPoster(succeeds: scenario != .commandFailure && scenario != .externalCopyDuringFailedPost)
                if scenario == .externalCopyDuringFailedPost {
                    poster.onPost = { precondition(manager.base.writeIntentionalText("new user copy")) }
                }
                let coordinator = PasteDeliveryCoordinator(
                    pasteboard: manager,
                    commandPoster: poster,
                    settlementDelayNanoseconds: .max
                )
                let result = await coordinator.deliver("dictated text", preserveTranscriptOnClipboard: keepBackup)
                if scenario == .newerUserCopy {
                    precondition(manager.base.writeIntentionalText("new user copy"))
                }
                coordinator.runPendingSettlementForTesting()

                let expectedResult: TextDeliveryResult = switch scenario {
                case .snapshotFailure: .recoverableFailure(.clipboardSnapshotFailed)
                case .writeFailure, .earlyWriteFailure, .externalCopyDuringFailedWrite: .recoverableFailure(.clipboardWriteFailed)
                case .commandFailure, .externalCopyDuringFailedPost: .recoverableFailure(.pasteCommandFailed)
                case .success, .newerUserCopy: .commandPosted
                }
                let hasNewerCopy = scenario == .newerUserCopy || scenario == .externalCopyDuringFailedPost || scenario == .externalCopyDuringFailedWrite
                let expectedText = hasNewerCopy
                    ? "new user copy" : (keepBackup ? "dictated text" : "old clipboard")
                let expectedPosts = [.snapshotFailure, .writeFailure, .earlyWriteFailure, .externalCopyDuringFailedWrite].contains(scenario) ? 0 : 1
                let actualText = board.string(forType: .string)
                let isTemporary = board.types?.contains(.init("org.nspasteboard.TransientType")) == true
                // Restored old content is deliberately marked transient to avoid duplicate
                // clipboard-manager entries. An enabled transcript backup must be permanent.
                let permanentBackup = !keepBackup || !isTemporary
                let passed = result == expectedResult && actualText == expectedText
                    && poster.postCount == expectedPosts && permanentBackup
                    && manager.intentionalWrites == (keepBackup && !hasNewerCopy ? 1 : 0)
                if !passed { failures += 1 }
                print("\(passed ? "PASS" : "FAIL"): backup=\(keepBackup) scenario=\(scenario.rawValue) result=\(result) clipboard=\(actualText ?? "nil") posts=\(poster.postCount)")
            }
        }
        let preparation = await self.testPreparation()
        cases += preparation.cases
        failures += preparation.failures
        let ordering = await self.testOrdering()
        cases += ordering.cases
        failures += ordering.failures
        print("\(cases - failures)/\(cases) passed; \(failures) backup contract failures. No system clipboard or real paste commands used.")
        exit(failures == 0 ? 0 : 1)
    }

    static func testOversizedFileFallback() {
        for existingText in [nil, "original label"] as [String?] {
            for oversized in [false, true] {
                let board = NSPasteboard(name: .init("fluidvoice.filename-fallback.\(UUID().uuidString)"))
                defer { board.releaseGlobally() }
                let fileURL = URL(fileURLWithPath: "/tmp/Report with spaces.pdf")
                let payloadType = NSPasteboard.PasteboardType("com.fluidvoice.tests.payload")
                let item = NSPasteboardItem()
                precondition(item.setString(fileURL.absoluteString, forType: .fileURL))
                precondition(item.setData(Data(count: oversized ? SystemPasteboardManager.maximumRepresentationBytes + 1 : 16), forType: payloadType))
                if let existingText { precondition(item.setString(existingText, forType: .string)) }
                precondition(board.writeObjects([item]))
                let manager = SystemPasteboardManager(pasteboard: board)
                guard let snapshot = manager.captureSnapshot() else { fatalError("Snapshot missing") }
                precondition(manager.writeTemporaryText("dictated", sessionID: "filename-test"))
                precondition(manager.restore(snapshot))
                precondition(board.string(forType: .fileURL).flatMap(URL.init(string:)) == fileURL)
                precondition(board.string(forType: .string) == (existingText ?? (oversized ? fileURL.lastPathComponent : nil)))
                precondition((board.data(forType: payloadType) == nil) == oversized)
                if oversized { precondition(snapshot.items.first?.portableImage == nil) }
            }
        }
        print("PASS: 4 filename fallback cases; file URLs, existing text and small payloads preserved")
    }

    static func testPreparation() async -> (cases: Int, failures: Int) {
        var failures = 0
        var cases = 0
        for backup in [false, true] {
            for returnToStart in [false, true] {
                for focusedPID: Int32? in [200, nil] {
                    cases += 1
                    let board = NSPasteboard(name: .init("fluidvoice.preparation.\(UUID().uuidString)"))
                    defer { board.releaseGlobally() }
                    let manager = InjectedPasteboard(board: board, scenario: .success)
                    precondition(manager.base.writeIntentionalText("old clipboard"))
                    let originalChangeCount = manager.changeCount
                    let poster = InjectedCommandPoster(succeeds: true)
                    let coordinator = PasteDeliveryCoordinator(pasteboard: manager, commandPoster: poster)
                    let target = DictationTargetPolicy.resolve(
                        returnToStartingField: returnToStart,
                        focusedPID: focusedPID,
                        ownPID: 999,
                        originalPID: 100,
                        originalFieldIsFocused: false
                    )
                    let ready = await coordinator.prepareForDelivery("dictated text", preserveTranscriptOnClipboard: backup) {
                        // Deterministically fail whenever restoration is requested.
                        !target.shouldRestoreOriginalFocus
                    }
                    let expectedCopy = backup && target.shouldRestoreOriginalFocus
                    let passed = ready == !target.shouldRestoreOriginalFocus
                        && board.string(forType: .string) == (expectedCopy ? "dictated text" : "old clipboard")
                        && manager.intentionalWrites == (expectedCopy ? 1 : 0)
                        && poster.postCount == 0
                        && (expectedCopy || manager.changeCount == originalChangeCount)
                    if !passed { failures += 1 }
                    print("\(passed ? "PASS" : "FAIL"): preparation backup=\(backup) returnToStart=\(returnToStart) externalFocus=\(focusedPID != nil)")
                }
            }
        }
        return (cases, failures)
    }

    static func testOrdering() async -> (cases: Int, failures: Int) {
        var failures = 0
        var cases = 0
        for backup in [false, true] {
            for externalCopy in [false, true] {
                cases += 1
                let board = NSPasteboard(name: .init("fluidvoice.queued-backup.\(UUID().uuidString)"))
                defer { board.releaseGlobally() }
                let manager = InjectedPasteboard(board: board, scenario: .success)
                precondition(manager.base.writeIntentionalText("old clipboard"))
                let poster = InjectedCommandPoster(succeeds: true)
                let coordinator = PasteDeliveryCoordinator(pasteboard: manager, commandPoster: poster, settlementDelayNanoseconds: .max)
                _ = await coordinator.deliver("first", preserveTranscriptOnClipboard: false)
                var started = false
                let pending = Task { @MainActor in
                    started = true
                    return await coordinator.copyBackup("second", enabled: backup)
                }
                for _ in 0..<100 where !started {
                    await Task.yield()
                }
                let protectedFirst = board.string(forType: .string) == "first"
                if externalCopy { precondition(manager.base.writeIntentionalText("new user copy")) }
                coordinator.runPendingSettlementForTesting()
                let copied = await pending.value
                let expected = externalCopy ? "new user copy" : (backup ? "second" : "old clipboard")
                let passed = protectedFirst && board.string(forType: .string) == expected
                    && copied == (backup && !externalCopy) && poster.postCount == 1
                    && manager.intentionalWrites == (backup && !externalCopy ? 1 : 0)
                if !passed { failures += 1 }
                print("\(passed ? "PASS" : "FAIL"): queued backup=\(backup) newerUserCopy=\(externalCopy)")
            }
        }
        // A newer dictation or user copy while focus restoration waits must win.
        for newerOutput in ["user copy", "paste", "copy only"] {
            cases += 1
            let board = NSPasteboard(name: .init("fluidvoice.stale-backup.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            let manager = InjectedPasteboard(board: board, scenario: .success)
            precondition(manager.base.writeIntentionalText("old clipboard"))
            let coordinator = PasteDeliveryCoordinator(pasteboard: manager, commandPoster: InjectedCommandPoster(succeeds: true), settlementDelayNanoseconds: .max)
            let ready = await coordinator.prepareForDelivery("stale text", preserveTranscriptOnClipboard: true) {
                if newerOutput == "paste" {
                    _ = await coordinator.deliver("newer text", preserveTranscriptOnClipboard: true)
                    coordinator.runPendingSettlementForTesting()
                } else if newerOutput == "copy only" {
                    _ = await coordinator.copyBackup("newer text", enabled: true)
                } else {
                    precondition(manager.base.writeIntentionalText("newer text"))
                }
                return false
            }
            let passed = !ready && board.string(forType: .string) == "newer text"
            if !passed { failures += 1 }
            print("\(passed ? "PASS" : "FAIL"): stale preparation newerOutput=\(newerOutput)")
        }
        return (cases, failures)
    }
}

private enum Scenario: String, CaseIterable {
    case success, snapshotFailure, writeFailure, earlyWriteFailure, commandFailure, newerUserCopy
    case externalCopyDuringFailedWrite, externalCopyDuringFailedPost
}

@MainActor
private final class InjectedCommandPoster: PasteCommandPosting {
    let succeeds: Bool
    private(set) var postCount = 0
    var onPost: (() -> Void)?

    init(succeeds: Bool) { self.succeeds = succeeds }

    func postGlobalPasteCommand() async -> Bool {
        self.postCount += 1
        self.onPost?()
        return self.succeeds
    }
}

@MainActor
private final class InjectedPasteboard: PasteboardManaging {
    let base: SystemPasteboardManager
    let scenario: Scenario
    var changeCount: Int { self.base.changeCount }
    private(set) var intentionalWrites = 0

    init(board: NSPasteboard, scenario: Scenario) {
        self.base = SystemPasteboardManager(pasteboard: board)
        self.scenario = scenario
    }

    func captureSnapshot() -> PasteboardSnapshot? {
        self.scenario == .snapshotFailure ? nil : self.base.captureSnapshot()
    }

    func writeTemporaryText(_ text: String, sessionID: String) -> Bool {
        if self.scenario == .earlyWriteFailure { return false }
        let written = self.base.writeTemporaryText(text, sessionID: sessionID)
        if self.scenario == .externalCopyDuringFailedWrite {
            precondition(self.base.writeIntentionalText("new user copy"))
            return false
        }
        // Exercise cleanup after a write that touched the clipboard but reports failure.
        return self.scenario == .writeFailure ? false : written
    }

    func writeIntentionalText(_ text: String) -> Bool {
        self.intentionalWrites += 1
        return self.base.writeIntentionalText(text)
    }

    func isOwned(sessionID: String, expectedText: String) -> Bool {
        self.base.isOwned(sessionID: sessionID, expectedText: expectedText)
    }

    func restore(_ snapshot: PasteboardSnapshot) -> Bool { self.base.restore(snapshot) }
    func restoreTemporarySnapshot(_ snapshot: PasteboardSnapshot, sessionID: String, expectedText: String) -> Bool {
        self.base.restoreTemporarySnapshot(snapshot, sessionID: sessionID, expectedText: expectedText)
    }
}
