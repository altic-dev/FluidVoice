import AppKit

/// Exercises the production data provider and coordinator on private pasteboards.
/// Only Cmd+V posting is replaced; no system clipboard or keyboard is touched.
@main
@MainActor
enum PasteReadReceiptReproductionTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String = "Expectation failed", file: StaticString = #filePath, line: UInt = #line) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(file):\(line): \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() async {
        FileHandle.standardOutput.write(Data("RUN: testOwnershipChecksDoNotCreateReceipts\n".utf8))
        await self.testOwnershipChecksDoNotCreateReceipts()
        FileHandle.standardOutput.write(Data("RUN: testReadBeforeObserverIsNotLost\n".utf8))
        await self.testReadBeforeObserverIsNotLost()
        FileHandle.standardOutput.write(Data("RUN: testDelayedConsumerGetsDictation\n".utf8))
        await self.testDelayedConsumerGetsDictation()
        FileHandle.standardOutput.write(Data("RUN: testNormalReadRestoresOriginal\n".utf8))
        await self.testNormalReadRestoresOriginal()
        FileHandle.standardOutput.write(Data("RUN: testTimeoutRetainsTextAndReleasesQueue\n".utf8))
        await self.testTimeoutRetainsTextAndReleasesQueue()
        FileHandle.standardOutput.write(Data("RUN: testExternalCopyWins\n".utf8))
        await self.testExternalCopyWins(afterRead: false)
        FileHandle.standardOutput.write(Data("RUN: testExternalCopyWins\n".utf8))
        await self.testExternalCopyWins(afterRead: true)
        FileHandle.standardOutput.write(Data("RUN: testCancelledTimeoutRestoresOriginal\n".utf8))
        await self.testCancelledTimeoutRestoresOriginal()
        FileHandle.standardOutput.write(Data("RUN: testRepeatedReadsDoNotPostAgain\n".utf8))
        await self.testRepeatedReadsDoNotPostAgain()
        FileHandle.standardOutput.write(Data("RUN: testQueuedDeliveryWaitsForReadAndSettlement\n".utf8))
        await self.testQueuedDeliveryWaitsForReadAndSettlement()
        FileHandle.standardOutput.write(Data("RUN: testStaleReceiptCannotSettleNewDelivery\n".utf8))
        await self.testStaleReceiptCannotSettleNewDelivery()
        FileHandle.standardOutput.write(Data("RUN: testReadReceiptKeepsItsOriginalPipeline\n".utf8))
        await self.testReadReceiptKeepsItsOriginalPipeline()
        print("PASS: 12 paste receipt cases; no real keys or system clipboard used")
    }

    static func board() -> NSPasteboard {
        NSPasteboard(name: .init("fluidvoice.read-receipt-tests.\(UUID().uuidString)"))
    }

    static func waitUntil(_ condition: () -> Bool) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        self.expect(condition(), "Condition did not become true before the bounded deadline")
    }

    static func testOwnershipChecksDoNotCreateReceipts() async {
        let board = self.board()
        defer { board.releaseGlobally() }
        let manager = SystemPasteboardManager(pasteboard: board)
        self.expect(manager.writeTemporaryText("dictation", sessionID: "one"))
        var reads = 0
        self.expect(manager.observeTemporaryTextRead(sessionID: "one") { _ in reads += 1 })
        for _ in 0..<10 {
            self.expect(manager.isOwned(sessionID: "one", expectedText: "dictation"))
            self.expect(!manager.isOwned(sessionID: "one", expectedText: "wrong text"))
            _ = board.types
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        self.expect(reads == 0, "Our own ownership/type checks must not manufacture a read receipt")
        self.expect(board.string(forType: .string) == "dictation")
        await self.waitUntil { reads == 1 }
        _ = board.string(forType: .string)
        try? await Task.sleep(nanoseconds: 20_000_000)
        self.expect(reads == 1)
        print("PASS: ownership checks do not consume the promise; the first actual read notifies once")
    }

    static func testReadBeforeObserverIsNotLost() async {
        let board = self.board()
        defer { board.releaseGlobally() }
        let manager = SystemPasteboardManager(pasteboard: board)
        self.expect(manager.writeTemporaryText("early read", sessionID: "early"))
        self.expect(board.string(forType: .string) == "early read")
        var reads = 0
        self.expect(manager.observeTemporaryTextRead(sessionID: "early") { _ in reads += 1 })
        await self.waitUntil { reads == 1 }
        print("PASS: an immediate consumer read before observer registration is retained")
    }

    static func testDelayedConsumerGetsDictation() async {
        let board = self.board()
        defer { board.releaseGlobally() }
        let manager = SystemPasteboardManager(pasteboard: board)
        self.expect(manager.writeIntentionalText("previous clipboard"))
        let poster = ReceiptTestPoster()
        let coordinator = PasteDeliveryCoordinator(pasteboard: manager, commandPoster: poster)
        let result = await coordinator.deliver("delayed dictation", preserveTranscriptOnClipboard: false)
        self.expect(result == .commandPosted)
        let temporaryRevision = board.changeCount
        try? await Task.sleep(nanoseconds: 800_000_000)
        self.expect(board.changeCount == temporaryRevision, "Must not restore at 500 ms before consumption")
        self.expect(board.string(forType: .string) == "delayed dictation")
        await self.waitUntil { board.changeCount != temporaryRevision }
        self.expect(board.string(forType: .string) == "previous clipboard")
        self.expect(poster.count == 1)
        print("PASS: real 800 ms delayed read receives dictation, then the previous clipboard is restored")
    }

    static func testNormalReadRestoresOriginal() async {
        let board = self.board()
        defer { board.releaseGlobally() }
        let manager = SystemPasteboardManager(pasteboard: board)
        self.expect(manager.writeIntentionalText("original"))
        let coordinator = PasteDeliveryCoordinator(pasteboard: manager, commandPoster: ReceiptTestPoster(), settlementDelayNanoseconds: 30_000_000)
        _ = await coordinator.deliver("normal", preserveTranscriptOnClipboard: false)
        let revision = board.changeCount
        self.expect(board.string(forType: .string) == "normal")
        await self.waitUntil { board.changeCount != revision }
        self.expect(board.string(forType: .string) == "original")
        print("PASS: normal read restores the original clipboard")
    }

    static func testTimeoutRetainsTextAndReleasesQueue() async {
        let board = self.board()
        defer { board.releaseGlobally() }
        let manager = SystemPasteboardManager(pasteboard: board)
        self.expect(manager.writeIntentionalText("original"))
        let poster = ReceiptTestPoster()
        let coordinator = PasteDeliveryCoordinator(pasteboard: manager, commandPoster: poster, settlementDelayNanoseconds: 20_000_000, readTimeoutNanoseconds: 60_000_000)
        _ = await coordinator.deliver("late first", preserveTranscriptOnClipboard: false)
        let revision = board.changeCount
        await self.waitUntil { board.changeCount != revision }
        self.expect(board.string(forType: .string) == "late first", "Timeout must not expose unrelated clipboard content to a late Cmd+V")
        self.expect(board.types?.contains(.init("org.nspasteboard.TransientType")) == false)
        _ = await coordinator.deliver("second", preserveTranscriptOnClipboard: false)
        let nextRevision = board.changeCount
        self.expect(board.string(forType: .string) == "second")
        await self.waitUntil { board.changeCount != nextRevision }
        self.expect(board.string(forType: .string) == "late first")
        self.expect(poster.count == 2)
        print("PASS: timeout retains plain text and releases the queue for the next delivery")
    }

    static func testExternalCopyWins(afterRead: Bool) async {
        let board = self.board()
        defer { board.releaseGlobally() }
        let manager = SystemPasteboardManager(pasteboard: board)
        self.expect(manager.writeIntentionalText("original"))
        let coordinator = PasteDeliveryCoordinator(pasteboard: manager, commandPoster: ReceiptTestPoster(), settlementDelayNanoseconds: 30_000_000, readTimeoutNanoseconds: 60_000_000)
        _ = await coordinator.deliver("dictation", preserveTranscriptOnClipboard: false)
        if afterRead { _ = board.string(forType: .string) }
        board.clearContents()
        self.expect(board.setString("new user copy", forType: .string))
        try? await Task.sleep(nanoseconds: 100_000_000)
        self.expect(board.string(forType: .string) == "new user copy")
        print("PASS: newer user copy wins afterRead=\(afterRead)")
    }

    static func testCancelledTimeoutRestoresOriginal() async {
        let board = self.board()
        defer { board.releaseGlobally() }
        let manager = SystemPasteboardManager(pasteboard: board)
        self.expect(manager.writeIntentionalText("original"))
        let coordinator = PasteDeliveryCoordinator(pasteboard: manager, commandPoster: ReceiptTestPoster(), readTimeoutNanoseconds: 40_000_000)
        var valid = true
        _ = await coordinator.deliver("cancelled", preserveTranscriptOnClipboard: false, isOutputValid: { valid })
        let revision = board.changeCount
        valid = false
        await self.waitUntil { board.changeCount != revision }
        self.expect(board.string(forType: .string) == "original")
        print("PASS: cancelled output is not kept as a timeout backup")
    }

    static func testRepeatedReadsDoNotPostAgain() async {
        let board = self.board()
        defer { board.releaseGlobally() }
        let manager = SystemPasteboardManager(pasteboard: board)
        self.expect(manager.writeIntentionalText("original"))
        let poster = ReceiptTestPoster()
        let coordinator = PasteDeliveryCoordinator(pasteboard: manager, commandPoster: poster, settlementDelayNanoseconds: 10_000_000)
        for index in 0..<20 {
            let text = "dictation \(index)"
            _ = await coordinator.deliver(text, preserveTranscriptOnClipboard: false)
            let revision = board.changeCount
            for _ in 0..<3 {
                self.expect(board.string(forType: .string) == text)
            }
            await self.waitUntil { board.changeCount != revision }
            self.expect(board.string(forType: .string) == "original")
        }
        self.expect(poster.count == 20, "Receipts must never retry or duplicate insertion")
        print("PASS: 20 sequential deliveries restore correctly without duplicate commands")
    }

    static func testQueuedDeliveryWaitsForReadAndSettlement() async {
        let board = self.board()
        defer { board.releaseGlobally() }
        let manager = SystemPasteboardManager(pasteboard: board)
        self.expect(manager.writeIntentionalText("original"))
        let poster = ReceiptTestPoster()
        let coordinator = PasteDeliveryCoordinator(pasteboard: manager, commandPoster: poster, settlementDelayNanoseconds: 20_000_000)
        _ = await coordinator.deliver("first", preserveTranscriptOnClipboard: false)
        var secondResult: TextDeliveryResult?
        let next = Task { @MainActor in
            secondResult = await coordinator.deliver("second", preserveTranscriptOnClipboard: false)
        }
        try? await Task.sleep(nanoseconds: 40_000_000)
        self.expect(poster.count == 1 && secondResult == nil)
        self.expect(board.string(forType: .string) == "first")
        await self.waitUntil { secondResult != nil }
        self.expect(secondResult == .commandPosted && poster.count == 2)
        let revision = board.changeCount
        self.expect(board.string(forType: .string) == "second")
        await self.waitUntil { board.changeCount != revision }
        self.expect(board.string(forType: .string) == "original")
        await next.value
        print("PASS: a queued paste cannot replace the first payload before its read and settlement")
    }

    static func testStaleReceiptCannotSettleNewDelivery() async {
        let board = self.board()
        defer { board.releaseGlobally() }
        let manager = ReceiptObservingPasteboard(board: board)
        self.expect(manager.base.writeIntentionalText("original"))
        // This case checks stale receipts; timeout retention has its own case.
        // Keep the unread lease alive until this test explicitly reads it.
        let coordinator = PasteDeliveryCoordinator(pasteboard: manager, commandPoster: ReceiptTestPoster(), settlementDelayNanoseconds: 10_000_000, readTimeoutNanoseconds: .max)
        _ = await coordinator.deliver("first", preserveTranscriptOnClipboard: false)
        let oldHandler = manager.handlers[0]
        let firstRevision = board.changeCount
        self.expect(board.string(forType: .string) == "first")
        await self.waitUntil { board.changeCount != firstRevision }
        _ = await coordinator.deliver("second", preserveTranscriptOnClipboard: false)
        let secondRevision = board.changeCount
        oldHandler(ProcessInfo.processInfo.systemUptime)
        try? await Task.sleep(nanoseconds: 30_000_000)
        self.expect(board.changeCount == secondRevision, "A stale first receipt must not schedule the next delivery's restoration")
        // A busy CI runner may resume after the old 80 ms timeout. Deliberately
        // delay the reader so timeout behavior cannot masquerade as a stale receipt.
        try? await Task.sleep(nanoseconds: 120_000_000)
        self.expect(board.string(forType: .string) == "second")
        await self.waitUntil { board.changeCount != secondRevision }
        let restored = board.string(forType: .string)
        self.expect(restored == "original", "Current receipt should restore its captured clipboard; got \(String(describing: restored))")
        print("PASS: a late receipt from the previous generation cannot settle the current paste")
    }

    static func testReadReceiptKeepsItsOriginalPipeline() async {
        let board = self.board()
        defer { board.releaseGlobally() }
        let manager = SystemPasteboardManager(pasteboard: board)
        self.expect(manager.writeIntentionalText("original"))
        let coordinator = PasteDeliveryCoordinator(pasteboard: manager, commandPoster: ReceiptTestPoster())
        _ = await DebugLogger.$pipelineID.withValue("receipt-trace") {
            await coordinator.deliver("trace text", preserveTranscriptOnClipboard: false)
        }
        self.expect(DebugLogger.pipelineID == nil)
        // AppKit's reader is outside the request task; its callback must recover
        // the delivery's trace rather than log under whichever task reads it.
        _ = DebugLogger.$pipelineID.withValue("unrelated-reader") { board.string(forType: .string) }
        await self.waitUntil {
            DebugLogger.shared.infoEvents.contains { $0.message.hasPrefix("PASTE_READ ") && $0.pipelineID == "receipt-trace" }
        }
        self.expect(!DebugLogger.shared.infoEvents.contains { $0.message.hasPrefix("PASTE_READ ") && $0.pipelineID == "unrelated-reader" })
        coordinator.runPendingSettlementForTesting()
        self.expect(board.string(forType: .string) == "original")
        print("PASS: a clipboard read outside the request retains its original pipeline ID")
    }
}

@MainActor
private final class ReceiptObservingPasteboard: PasteboardManaging {
    nonisolated deinit {}
    let base: SystemPasteboardManager
    var handlers: [@MainActor @Sendable (TimeInterval) -> Void] = []
    init(board: NSPasteboard) { self.base = SystemPasteboardManager(pasteboard: board) }
    var changeCount: Int { self.base.changeCount }
    func captureSnapshot() -> PasteboardSnapshot? { self.base.captureSnapshot() }
    func writeTemporaryText(_ text: String, sessionID: String) -> Bool { self.base.writeTemporaryText(text, sessionID: sessionID) }
    func writeIntentionalText(_ text: String) -> Bool { self.base.writeIntentionalText(text) }
    func isOwned(sessionID: String, expectedText: String) -> Bool { self.base.isOwned(sessionID: sessionID, expectedText: expectedText) }
    func restore(_ snapshot: PasteboardSnapshot) -> Bool { self.base.restore(snapshot) }
    func restoreTemporarySnapshot(_ snapshot: PasteboardSnapshot, sessionID: String, expectedText: String) -> Bool {
        self.base.restoreTemporarySnapshot(snapshot, sessionID: sessionID, expectedText: expectedText)
    }

    func observeTemporaryTextRead(sessionID: String, onRead: @escaping @MainActor @Sendable (TimeInterval) -> Void) -> Bool {
        self.handlers.append(onRead)
        return self.base.observeTemporaryTextRead(sessionID: sessionID, onRead: onRead)
    }
}

@MainActor
private final class ReceiptTestPoster: PasteCommandPosting {
    nonisolated deinit {}
    var count = 0
    func postGlobalPasteCommand() async -> Bool {
        self.count += 1
        return true
    }
}
