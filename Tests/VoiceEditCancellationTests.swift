import Foundation

// Production voice processing runs above these boundary doubles.
@MainActor final class DebugLogger {
    static let shared = DebugLogger()
    func info(_: String, source _: String) {}
    func error(_: String, source _: String) {}
}

@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    var copyTranscriptionToClipboard = true
}

enum DeliveryFailure { case targetRestoreFailed }
enum TextDeliveryResult { case delivered, cancelled, recoverableFailure(DeliveryFailure) }

@MainActor final class RewriteDouble {
    var originalText = "original"
    var rewrittenText = ""
    var requests = 0
    var clears = 0
    var respond: CheckedContinuation<Void, Never>?
    func setPromptAppBundleID(_: String) {}
    func processRewriteRequest(_: String) async {
        self.requests += 1
        await withCheckedContinuation { self.respond = $0 }
        self.rewrittenText = "rewrite"
    }

    func clearState() { self.originalText = ""; self.rewrittenText = ""; self.clears += 1 }
}

@MainActor final class MenuDouble {
    var finishes = 0
    func setProcessing(_: Bool) {}
    func finishProcessingAndHideOverlay() async { self.finishes += 1 }
}

@MainActor final class ASRDouble {
    var deliveries = 0
    var writes = 0
    var resume: CheckedContinuation<Void, Never>?
    var failure = false
    func typeTextToActiveField(
        _: String,
        preferredTargetPID _: Int?,
        preserveTranscriptOnClipboard _: Bool,
        isOutputValid: @escaping @MainActor () -> Bool
    ) async -> TextDeliveryResult {
        self.deliveries += 1
        await withCheckedContinuation { self.resume = $0 }
        guard isOutputValid() else { return .cancelled }
        if self.failure { return .recoverableFailure(.targetRestoreFailed) }
        self.writes += 1
        return .delivered
    }
}

@MainActor final class VoiceEditOwner {
    var overlayLifecycleID: UInt64 = 7
    var cancelledOutputLifecycleID: UInt64?
    let rewriteModeService = RewriteDouble()
    let menuBarManager = MenuDouble()
    let asr = ASRDouble()
    var restoreFocus = true
    var focus: CheckedContinuation<Bool, Never>?
    var failures = 0
    var hides = 0
    func resolveTypingTargetPID() -> (pid: Int?, shouldRestoreOriginalFocus: Bool) { (1, self.restoreFocus) }
    func prepareRecordingTargetForDelivery(
        _: String,
        keepBackup _: Bool,
        isOutputValid: @escaping @MainActor () -> Bool
    ) async -> Bool {
        guard isOutputValid() else { return false }
        let result = await withCheckedContinuation { self.focus = $0 }
        return result && isOutputValid()
    }

    func showTextDeliveryFailure(_: DeliveryFailure, transcript _: String) { self.failures += 1 }
    func hideOverlayAfterOutput() { self.hides += 1 }
}

@main enum VoiceEditCancellationTests {
    @MainActor static func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<10_000 {
            if predicate() { return }
            await Task.yield()
        }
        fatalError("Boundary was never reached")
    }

    @MainActor static func main() async {
        let context = (name: "Editor", bundleId: "editor", windowTitle: "Document")
        let before = VoiceEditOwner()
        before.cancelledOutputLifecycleID = 7
        await before.processRewriteWithVoiceInstruction("rewrite", appInfo: context, lifecycleID: 7)
        precondition(before.rewriteModeService.requests == 0)

        // Escape while the model is working: no focus, paste, clipboard, or failure UI.
        let model = VoiceEditOwner()
        let modelTask = Task { await model.processRewriteWithVoiceInstruction("rewrite", appInfo: context, lifecycleID: 7) }
        await waitUntil { model.rewriteModeService.respond != nil }
        model.cancelledOutputLifecycleID = 7
        model.rewriteModeService.respond?.resume()
        await modelTask.value
        precondition(model.focus == nil && model.asr.deliveries == 0 && model.failures == 0 && model.hides == 0)
        precondition(model.rewriteModeService.clears == 1 && model.rewriteModeService.rewrittenText.isEmpty)

        for focusResult in [true, false] {
            let owner = VoiceEditOwner()
            let task = Task { await owner.processRewriteWithVoiceInstruction("rewrite", appInfo: context, lifecycleID: 7) }
            await waitUntil { owner.rewriteModeService.respond != nil }
            owner.rewriteModeService.respond?.resume()
            await self.waitUntil { owner.focus != nil }
            owner.cancelledOutputLifecycleID = 7
            owner.focus?.resume(returning: focusResult)
            await task.value
            precondition(owner.asr.deliveries == 0 && owner.failures == 0 && owner.hides == 0)
            precondition(owner.rewriteModeService.clears == 1)
        }

        // Cancel queued OS delivery, and prove a new request still delivers normally.
        for outcome in ["cancel", "stale", "success", "failure"] {
            let owner = VoiceEditOwner()
            owner.cancelledOutputLifecycleID = 6
            owner.restoreFocus = false
            let task = Task { await owner.processRewriteWithVoiceInstruction("rewrite", appInfo: context, lifecycleID: 7) }
            await waitUntil { owner.rewriteModeService.respond != nil }
            owner.rewriteModeService.respond?.resume()
            await self.waitUntil { owner.asr.resume != nil }
            if outcome == "cancel" { owner.cancelledOutputLifecycleID = 7 }
            if outcome == "stale" { owner.overlayLifecycleID = 8 }
            owner.asr.failure = outcome == "failure"
            owner.asr.resume?.resume()
            await task.value
            precondition(owner.asr.writes == (outcome == "success" ? 1 : 0))
            precondition(owner.hides == (outcome == "success" ? 1 : 0))
            precondition(owner.failures == (outcome == "failure" ? 1 : 0))
            precondition(owner.rewriteModeService.clears == (outcome == "failure" ? 0 : 1))
        }
        print("Voice Edit cancellation: 8 production-path scenarios passed")
    }
}
