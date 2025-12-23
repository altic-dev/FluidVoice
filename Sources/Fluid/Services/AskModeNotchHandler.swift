import Foundation
import SwiftUI

// MARK: - Ask Mode Notch Output Handler

/// Handles Ask Mode output by displaying in the notch UI
/// This is the default output handler, but the architecture supports
/// adding overlay, popup, or other renderers later
@MainActor
final class AskModeNotchHandler: AskModeOutputHandler {
    static let shared = AskModeNotchHandler()

    private init() {}

    // MARK: - AskModeOutputHandler Protocol

    func onQuestionSubmitted(_ question: String, context: AskModeContext) {
        // Add user message to notch conversation
        let displayQuestion: String
        if !context.isEmpty, let textPreview = context.textContent?.prefix(50) {
            displayQuestion = "[\(textPreview)...] \(question)"
        } else {
            displayQuestion = question
        }

        NotchContentState.shared.addAskMessage(role: .user, content: displayQuestion)
    }

    func onProcessingStarted() {
        NotchContentState.shared.setAskProcessing(true)
    }

    func onContentChunk(_ chunk: String) {
        // Update streaming text in real-time
        NotchContentState.shared.updateAskStreamingText(
            NotchContentState.shared.askStreamingText + chunk
        )
    }

    func onThinkingChunk(_ chunk: String) {
        // Could show thinking in notch if desired, but for now we skip it
        // to keep the UI clean
    }

    func onProcessingCompleted(answer: String, thinking: String?) {
        // Clear streaming and add final message
        NotchContentState.shared.updateAskStreamingText("")
        NotchContentState.shared.addAskMessage(role: .assistant, content: answer)
        NotchContentState.shared.setAskProcessing(false)

        // Show the result in the expanded notch (which now supports Ask Mode tabs)
        NotchOverlayManager.shared.showExpandedCommandOutput(mode: .ask)
    }

    func onError(_ error: Error) {
        NotchContentState.shared.updateAskStreamingText("")
        NotchContentState.shared.addAskMessage(role: .assistant, content: "Error: \(error.localizedDescription)")
        NotchContentState.shared.setAskProcessing(false)
    }

    func onClear() {
        NotchContentState.shared.clearAskOutput()
    }
}
