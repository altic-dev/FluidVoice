import Foundation

/// Chooses one post-insertion action for a completed dictation. The delivery
/// service remains responsible for insertion, focus and cancellation checks.
enum DictationSendPolicy {
    enum Action: Equatable {
        case enter
        case spokenSend
    }

    nonisolated static func action(
        automaticEnterEnabled: Bool,
        spokenSendRequested: Bool,
        text: String,
        deliveryEligible: Bool
    ) -> Action? {
        guard deliveryEligible else { return nil }
        // An explicit phrase retains its configured command when both settings
        // are enabled; it never queues a second automatic Enter.
        if spokenSendRequested {
            return .spokenSend
        }
        guard automaticEnterEnabled,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return .enter
    }

    /// Require the exact replacement, rather than merely a posted Paste command.
    nonisolated static func insertionIsConfirmed(before: String?, selection: NSRange?, text: String, after: String?) -> Bool {
        guard let before, let selection, let after,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              selection.location >= 0, selection.length >= 0,
              selection.location <= (before as NSString).length,
              selection.length <= (before as NSString).length - selection.location
        else { return false }
        let expected = (before as NSString).replacingCharacters(in: selection, with: text)
        // A nonempty value at caret zero might be either a placeholder or an
        // existing draft. Never infer emptiness from the pasted result alone.
        return expected != before && expected == after
    }
}
