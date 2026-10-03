import Foundation

/// Chooses one post-insertion action for a completed dictation. The delivery
/// service remains responsible for insertion, focus and cancellation checks.
enum DictationSendPolicy {
    enum Action: Equatable {
        case enter
        case spokenSend
    }

    static func action(
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
}
