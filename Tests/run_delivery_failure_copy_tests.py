#!/usr/bin/env python3
"""Exercise production recovery actions with a deterministic clipboard stand-in.

This executes the actual Swift action and controller methods with their delayed work.
Panel and clipboard stand-ins keep the checks independent of the desktop.
It does not verify SwiftUI identity; the signed UI fixture covers presentation reuse.
Use --revision <commit> to check an earlier version of the production methods.
"""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--revision")
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
selected = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
developer = os.environ.get("DEVELOPER_DIR", selected)
if not (Path(developer) / "usr/bin/xcodebuild").is_file():
    raise SystemExit("Set DEVELOPER_DIR to a full installed Xcode.")
os.environ["DEVELOPER_DIR"] = developer


def read_source(name):
    path = f"Sources/Fluid/Views/{name}.swift"
    if args.revision:
        return subprocess.check_output(["git", "show", f"{args.revision}:{path}"], cwd=repo, text=True)
    return (repo / path).read_text()


card = read_source("DeliveryFailureCard")
card_actions = card[card.index("    private func copy() {"):card.rfind("\n}")]
overlay = read_source("DeliveryFailureOverlay")
overlay_action = overlay[overlay.index("    private func copy() {"):overlay.rfind("\n}")]
controller_actions = overlay[overlay.index("    func show(kind:"):overlay.index("    private func createPanel(")]
controller_duration = overlay[overlay.index("    private static let displayDuration:"):overlay.index("    private var panel:")]
swift = r'''
import Foundation
import SwiftUI

enum ClipboardService {
    static var text = "clipboard before test"
    static var calls = 0
    static var fail = false
    static func reset() { text = "clipboard before test"; calls = 0; fail = false }
    static func copyToClipboard(_ text: String) -> Bool {
        calls += 1
        guard !fail else { return false }
        self.text = text
        return true
    }
}
final class Card {
    static let autoDismissDelay: TimeInterval = 10
    var transcript = "first transcript"
    var didCopy = false
    var autoDismissWorkItem: DispatchWorkItem?
    var dismissals = 0
    var onDismiss: () -> Void { { self.dismissals += 1 } }
    CARD_ACTIONS
}
final class Popup {
    var transcript = "first transcript"
    var didCopy = false
    var successes = 0
    var failures = 0
    var kind = DeliveryFailureOverlayController.Kind.deliveryFailed
    var displayDuration: TimeInterval = 10
    var startedAt = Date()
    var onCopied: () -> Void = {}
    var onCopyFailed: () -> Void = {}
    var onDismiss: () -> Void = {}
    init(
        kind: DeliveryFailureOverlayController.Kind = .deliveryFailed,
        transcript: String = "first transcript",
        displayDuration: TimeInterval = 10,
        startedAt: Date = Date(),
        onCopied: (() -> Void)? = nil,
        onCopyFailed: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.kind = kind
        self.transcript = transcript
        self.displayDuration = displayDuration
        self.startedAt = startedAt
        self.onCopied = onCopied ?? { [weak self] in self?.successes += 1 }
        self.onCopyFailed = onCopyFailed ?? { [weak self] in self?.failures += 1 }
        self.onDismiss = onDismiss
    }
    OVERLAY_ACTION
}
typealias DeliveryFailureOverlayView = Popup
struct DeliveryFailureOverlayRoot {
    let generation: UInt64
    let content: Popup
}
final class HostingView {
    var rootView: DeliveryFailureOverlayRoot
    init(rootView: DeliveryFailureOverlayRoot) { self.rootView = rootView }
}
final class Panel {
    var isVisible = false
    var alphaValue = 1.0
    func orderFrontRegardless() { self.isVisible = true }
    func orderOut(_ sender: Any?) { self.isVisible = false }
    func animator() -> Panel { self }
}
struct DebugLogger {
    static let shared = DebugLogger()
    func info(_ message: String, source: String) {}
}
final class DeliveryFailureOverlayController {
    enum Kind { case deliveryFailed }
    CONTROLLER_DURATION
    var panel: Panel?
    var hostingView: HostingView?
    var dismissTask: Task<Void, Never>?
    var generation: UInt64 = 0
    CONTROLLER_ACTIONS
    private func createPanel(rootView: DeliveryFailureOverlayRoot) {
        self.panel = Panel()
        self.hostingView = HostingView(rootView: rootView)
    }
    private func resizeAndPositionPanel() {}
    private func animate(duration: TimeInterval, changes: () -> Void, completion: (() -> Void)? = nil) {
        changes()
        completion?()
    }
}
@main struct Tests {
    static var failures = 0
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { failures += 1; print("FAIL: \(message)") }
    }
    static func main() async throws {
        ClipboardService.reset()
        let card = Card()
        card.copy()
        check(card.didCopy && ClipboardService.text == "first transcript", "Card first copy succeeds")
        ClipboardService.text = "unrelated clipboard content"
        card.copy()
        check(ClipboardService.text == "first transcript" && ClipboardService.calls == 2, "Card allows re-copy after clipboard changes")
        card.transcript = "second transcript"
        card.copy()
        check(ClipboardService.text == "second transcript", "Card copies its current transcript")
        ClipboardService.fail = true
        card.copy()
        check(!card.didCopy, "Card clears success after a failed write")
        check(card.autoDismissWorkItem != nil, "Failed card copy retains a bounded dismiss timer")
        ClipboardService.fail = false
        card.copy()
        check(card.didCopy && ClipboardService.text == "second transcript", "Card can retry after failure")
        card.cancelAutoDismiss()

        ClipboardService.reset()
        ClipboardService.fail = true
        let failedCard = Card()
        failedCard.copy()
        check(!failedCard.didCopy, "Fresh failed card must not say Copied")
        check(ClipboardService.text == "clipboard before test", "Failed card copy must not replace clipboard")
        ClipboardService.fail = false
        failedCard.copy()
        check(failedCard.didCopy, "Fresh failed card remains retryable")
        failedCard.cancelAutoDismiss()

        ClipboardService.reset()
        let disappearingCard = Card()
        disappearingCard.copy()
        let cancelledWork = disappearingCard.autoDismissWorkItem
        disappearingCard.cancelAutoDismiss()
        check(cancelledWork?.isCancelled == true, "Disappearing card cancels copied-dismiss work")

        let changingCard = Card()
        changingCard.copy()
        let oldWork = changingCard.autoDismissWorkItem
        changingCard.didCopy = false
        changingCard.transcript = "new failure"
        changingCard.scheduleAutoDismiss()
        check(oldWork?.isCancelled == true, "Replacing a transcript cancels copied-dismiss work")

        ClipboardService.reset()
        let popup = Popup()
        popup.copy()
        check(popup.didCopy && popup.successes == 1, "Popup first copy succeeds")
        ClipboardService.text = "unrelated clipboard content"
        popup.copy()
        check(ClipboardService.text == "first transcript" && popup.successes == 2, "Popup allows re-copy after clipboard changes")
        popup.transcript = "second transcript"
        popup.copy()
        check(ClipboardService.text == "second transcript", "Popup copies its current transcript")
        let successes = popup.successes
        ClipboardService.fail = true
        popup.copy()
        check(!popup.didCopy && popup.successes == successes, "Failed popup copy neither says Copied nor dismisses")
        ClipboardService.fail = false
        popup.copy()
        check(popup.didCopy && popup.successes == successes + 1, "Popup retry succeeds")

        ClipboardService.reset()
        ClipboardService.fail = true
        let failedPopup = Popup()
        failedPopup.copy()
        check(!failedPopup.didCopy && failedPopup.successes == 0, "Fresh failed popup must not say Copied or dismiss")
        check(ClipboardService.text == "clipboard before test", "Failed popup copy must preserve clipboard")

        // Run the real show/hide methods: a failed re-copy must cancel the earlier short hide.
        ClipboardService.reset()
        let controller = DeliveryFailureOverlayController()
        controller.show(kind: .deliveryFailed, transcript: "retry transcript")
        let firstPresentation = controller.hostingView!.rootView
        firstPresentation.content.copy()
        check(firstPresentation.content.didCopy, "Controller initially reports a successful copy")
        ClipboardService.fail = true
        firstPresentation.content.copy()
        let retryPresentation = controller.hostingView!.rootView
        check(retryPresentation.generation != firstPresentation.generation, "Failed re-copy replaces the pending short hide")
        check(retryPresentation.content.startedAt > firstPresentation.content.startedAt &&
              retryPresentation.content.displayDuration == 10, "Failed copy restores the full ten-second countdown")
        check(retryPresentation.content.transcript == "retry transcript" && !retryPresentation.content.didCopy,
              "Retry keeps the current transcript and clears Copied")
        let retryGeneration = controller.generation
        firstPresentation.content.onCopied()
        firstPresentation.content.onCopyFailed()
        firstPresentation.content.onDismiss()
        check(controller.generation == retryGeneration, "Stale copy, failure and dismiss callbacks leave the retry alone")
        try await Task.sleep(nanoseconds: 1_300_000_000)
        check(controller.panel?.isVisible == true, "Failed re-copy stays visible beyond the old success hide")
        check(disappearingCard.dismissals == 0, "Cancelled copy timer never dismisses after disappearance")
        check(changingCard.dismissals == 0, "Old copy timer never dismisses a replacement transcript")
        changingCard.cancelAutoDismiss()
        ClipboardService.fail = false
        retryPresentation.content.copy()
        check(retryPresentation.content.didCopy && ClipboardService.text == "retry transcript", "Retried controller copy succeeds")
        try await Task.sleep(nanoseconds: 1_100_000_000)
        check(controller.panel?.isVisible == false, "Successful retry still closes the popup")
        let hiddenGeneration = controller.generation
        retryPresentation.content.onCopyFailed()
        check(controller.panel?.isVisible == false && controller.generation == hiddenGeneration,
              "Failure callback cannot reopen an already hidden popup")

        // Failure also resets a nearly expired normal timer, but the retry still has a bounded end.
        controller.show(kind: .deliveryFailed, transcript: "expiry transcript")
        let expiringPresentation = controller.hostingView!.rootView
        try await Task.sleep(nanoseconds: 8_900_000_000)
        ClipboardService.fail = true
        expiringPresentation.content.copy()
        try await Task.sleep(nanoseconds: 2_100_000_000)
        check(controller.panel?.isVisible == true, "Failure near normal expiry gives a fresh retry window")
        try await Task.sleep(nanoseconds: 8_100_000_000)
        for _ in 0..<20 where controller.panel?.isVisible == true {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        check(controller.panel?.isVisible == false, "An unused retry window still expires after ten seconds")
        print("\(assertions) assertions, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
'''
swift = swift.replace("CARD_ACTIONS", card_actions.replace("private func ", "func "))
swift = swift.replace("OVERLAY_ACTION", overlay_action.replace("private func ", "func "))
swift = swift.replace("CONTROLLER_ACTIONS", controller_actions)
swift = swift.replace("CONTROLLER_DURATION", controller_duration)
with tempfile.TemporaryDirectory(prefix="fv-recovery-copy-") as directory:
    root = Path(directory)
    source = root / "Tests.swift"
    binary = root / "tests"
    source.write_text(swift)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
