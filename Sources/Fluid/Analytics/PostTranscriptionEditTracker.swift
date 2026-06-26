import AppKit
import Foundation

/// Tracks whether the user immediately edits freshly-typed dictation output (Backspace / Cmd+A).
/// Privacy: stores only low-cardinality metadata; never stores transcript content.
actor PostTranscriptionEditTracker {
    static let shared = PostTranscriptionEditTracker()

    private init() {}

    // MARK: - State

    private struct ActiveWindow {
        let completedAt: Date
        let wordsBucket: String
        let xSeconds: Int
        let aiUsed: Bool
        let aiModel: String?
        let aiProvider: String?
        let mode: String
        let outputMethod: String
    }

    private var active: ActiveWindow?

    // MARK: - Public API

    func markTranscriptionCompleted(
        mode: String,
        outputMethod: String,
        wordsBucket: String,
        aiUsed: Bool,
        aiModel: String?,
        aiProvider: String?
    ) {
        let x = Self.xSeconds(forWordsBucket: wordsBucket)
        guard x > 0 else {
            self.active = nil
            return
        }

        self.active = ActiveWindow(
            completedAt: Date(),
            wordsBucket: wordsBucket,
            xSeconds: x,
            aiUsed: aiUsed,
            aiModel: aiUsed ? aiModel : nil,
            aiProvider: aiUsed ? aiProvider : nil,
            mode: mode,
            outputMethod: outputMethod
        )
    }

    func handleKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) async {
        guard let active else { return }

        let elapsed = Date().timeIntervalSince(active.completedAt)
        if elapsed < 0 || elapsed > Double(active.xSeconds) {
            self.active = nil
            return
        }

        let action: String?
        if keyCode == 51 { // Backspace (delete)
            action = "backspace"
        } else if keyCode == 0, modifiers.contains(.command) { // Cmd + A
            action = "cmd_a"
        } else {
            action = nil
        }

        guard let action else { return }

        var props: [String: Any] = [
            "mode": active.mode,
            "edit_action": action,
            "words_bucket": active.wordsBucket,
            "x_seconds": active.xSeconds,
            "time_since_completion_bucket": AnalyticsBuckets.bucketSeconds(elapsed),
            "ai_used": active.aiUsed,
            "output_method": active.outputMethod,
        ]

        if let model = active.aiModel {
            props["ai_model"] = model
        }
        if let provider = active.aiProvider {
            props["ai_provider"] = provider
        }

        let properties = props
        await MainActor.run {
            AnalyticsService.shared.capture(.postTranscriptionEdit, properties: properties)
        }

        // Single-fire per transcription window.
        self.active = nil
    }

    // MARK: - Window mapping

    private static func xSeconds(forWordsBucket bucket: String) -> Int {
        switch bucket {
        case "0": return 0
        case "1-5": return 2
        case "6-20": return 3
        case "21-50": return 5
        case "51-100": return 8
        case "101-300": return 12
        case "301+": return 15
        default: return 5
        }
    }
}
