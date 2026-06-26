import Combine
import Foundation

/// Coordinates "Prompt Test Mode" for the dictation prompt editor.
/// When active, the global dictation hotkey flow is rerouted to populate test output in the modal
/// instead of typing into other apps.
@MainActor
final class DictationPromptTestCoordinator: ObservableObject {
    static let shared = DictationPromptTestCoordinator()

    @Published private(set) var isActive: Bool = false
    @Published private(set) var draftPromptText: String = ""
    @Published var isProcessing: Bool = false

    @Published var lastTranscriptionText: String = ""
    @Published var lastOutputText: String = ""
    @Published var lastError: String = ""

    private init() {}

    func activate(draftPromptText: String) {
        self.isActive = true
        self.draftPromptText = draftPromptText
        self.isProcessing = false
        self.lastTranscriptionText = ""
        self.lastOutputText = ""
        self.lastError = ""
    }

    func deactivate() {
        self.isActive = false
        self.draftPromptText = ""
        self.isProcessing = false
    }

    func updateDraftPromptText(_ text: String) {
        guard self.isActive else { return }
        self.draftPromptText = text
    }
}
