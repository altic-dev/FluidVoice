//
//  LiveTypingController.swift
//  Fluid
//
//  Orchestration for the experimental Live Typing path.
//

import AppKit
import ApplicationServices
import Combine
import Foundation

/// Streams revised partials into the target field, but only while it can prove
/// it still owns the exact range it wrote.
///
/// The controller is intentionally conservative:
/// - it never writes until the focused field's value and selection are readable;
/// - it verifies every write against the field;
/// - it walks Level 1 -> 2 -> 3 on any doubt instead of guessing;
/// - if it ever wrote text it can no longer track, it suppresses the normal
///   paste and leaves the final transcript on the pasteboard rather than risk a
///   duplicate or delete the user's text.
///
/// Default OFF. This path has not been certified against any specific
/// application, so it stays experimental.
@MainActor
final class LiveTypingController: ObservableObject {
    static let shared = LiveTypingController()

    /// Human-readable result of the last session, shown in Settings so the user
    /// can certify which level a given application actually supported.
    @Published private(set) var lastReport: String = "No dictation yet."

    private var session: LiveTypingSession?
    private var target: LiveTypingAXTarget?
    /// Highest level the current session is still allowed to use.
    private(set) var effectiveLevel: LiveTypingLevel = .finalOnly

    private init() {}

    var isStreaming: Bool {
        self.session?.hasWritten == true
    }

    /// Feeds one revised partial. Wired to the existing partial subscription, so
    /// it adds no new ASR work.
    func observePartial(_ rawText: String) {
        guard SettingsStore.shared.liveTypingExperimental else {
            self.reset()
            return
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if self.session == nil {
            self.beginSession()
        }
        guard var session = self.session, let target = self.target else { return }
        guard let value = target.value() else {
            self.downgrade(&session)
            self.session = session
            return
        }

        switch session.partial(text, currentValue: value) {
        case .none:
            session.noteObservedValue(value)
            self.session = session

        case .write(let range, let newText):
            let previous = session.ownedText
            if self.write(range: range, text: newText, target: target) {
                session.noteWrite(newText)
                self.session = session
                return
            }
            // The write did not verify. Try to put the field back exactly as it
            // was; if that also fails, the session can no longer be trusted.
            if !previous.isEmpty {
                let rollback = NSRange(location: range.location, length: (newText as NSString).length)
                _ = target.replace(range: rollback, with: previous)
            }
            DebugLogger.shared.info(
                "Live typing write failed; downgrading from \(session.level)",
                source: "LiveTyping"
            )
            self.downgrade(&session)
            self.session = session

        case .abort(let reason):
            DebugLogger.shared.info(
                "Live typing stopped: \(reason.rawValue)",
                source: "LiveTyping"
            )
            self.reset()
        }
    }

    /// Called just before the normal insertion. Returns true when Live Typing
    /// already owns the text and the caller must not insert it again.
    func consumeFinalDelivery(plainText: String) -> Bool {
        guard var session = self.session, let target = self.target else {
            self.reset()
            return false
        }
        defer { self.reset() }

        guard session.hasWritten else { return false }

        // Focus must still be exactly where the session opened. Writing the final
        // text into a background field (or a different field of the same app)
        // would surprise the user, so the transcript goes to the pasteboard
        // instead of being inserted somewhere they are not looking.
        guard let focused = LiveTypingAXTarget.capture(preferredPID: nil),
              focused.pid == target.pid,
              CFEqual(focused.element, target.element)
        else {
            DebugLogger.shared.info(
                "Live typing focus moved; keeping the transcript on the pasteboard",
                source: "LiveTyping"
            )
            self.preserveToPasteboard(plainText)
            return true
        }

        guard let value = target.value() else {
            self.preserveToPasteboard(plainText)
            return true
        }

        let outcome = session.final(plainText, currentValue: value)
        switch outcome {
        case .fallbackToDelivery:
            return false

        case .nothingToDo:
            self.lastReport += " - final text already in place, no second insertion."
            return true

        case .replace(let range, let text):
            if self.write(range: range, text: text, target: target) {
                session.noteWrite(text)
                self.lastReport += " - final transcript written once."
                return true
            }
            DebugLogger.shared.info(
                "Live typing final replace failed; keeping the transcript on the pasteboard",
                source: "LiveTyping"
            )
            self.preserveToPasteboard(plainText)
            return true

        case .abort(let reason):
            DebugLogger.shared.info(
                "Live typing lost ownership (\(reason.rawValue)); not pasting over the user's edit",
                source: "LiveTyping"
            )
            self.preserveToPasteboard(plainText)
            return true
        }
    }

    func reset() {
        self.session = nil
        self.target = nil
        self.effectiveLevel = .finalOnly
    }

    // MARK: - Private

    private func beginSession() {
        guard let target = LiveTypingAXTarget.capture(preferredPID: nil) else {
            // No readable field: stay at Level 3, which is the behaviour the app
            // has always had.
            self.effectiveLevel = .finalOnly
            self.lastReport = "No focused text field (or Accessibility not granted). Level 3 (final paste)."
            return
        }
        let capabilities = target.capabilities()
        let level = capabilities.predictedLevel
        self.effectiveLevel = level
        self.lastReport = capabilities.summary
        guard level != .finalOnly else {
            self.target = nil
            self.session = nil
            return
        }
        guard let value = target.value(), let selection = target.selection() else {
            self.effectiveLevel = .finalOnly
            self.lastReport += " (value or range became unavailable)"
            self.target = nil
            self.session = nil
            return
        }
        self.target = target
        self.session = LiveTypingSession(
            targetPID: target.pid,
            anchor: selection.location,
            initialValue: value,
            level: level
        )
    }

    /// Level 1 -> 2 -> 3. A downgrade never loses what was already written.
    private func downgrade(_ session: inout LiveTypingSession) {
        switch session.level {
        case .full:
            session.downgrade(to: .committedChunks)
        case .committedChunks:
            session.downgrade(to: .finalOnly)
        case .finalOnly:
            break
        }
        self.effectiveLevel = session.level
    }

    private func write(range: NSRange, text: String, target: LiveTypingAXTarget) -> Bool {
        guard target.replace(range: range, with: text) else { return false }
        // Verify against the field, not against our own bookkeeping.
        return target.substring(
            at: NSRange(location: range.location, length: (text as NSString).length)
        ) == text
    }

    private func preserveToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
