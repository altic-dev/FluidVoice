import Combine
import Foundation

/// Coordinates "Prompt Test Mode" for the dictation prompt editor.
/// When active, the global dictation hotkey flow is rerouted to populate test output in the modal
/// instead of typing into other apps.
@MainActor
final class DictationPromptTestCoordinator: ObservableObject {
    // Explicitly nonisolated: on macOS 15.4+ the synthesized main-actor deinit can abort until the OS runtime has the fix (swiftlang/swift#88036).
    nonisolated deinit {}

    static let shared = DictationPromptTestCoordinator()

    @Published private(set) var isActive: Bool = false
    private(set) var sessionID = UUID()
    @Published private(set) var draftPromptText: String = ""
    @Published private(set) var draftProviderID: String = ""
    @Published private(set) var draftModel: String = ""
    private(set) var usesBuiltInPrompt = false
    @Published var isProcessing: Bool = false

    @Published var lastTranscriptionText: String = ""
    @Published var lastOutputText: String = ""
    @Published var lastError: String = ""

    init() {}

    func acceptsResult(for sessionID: UUID) -> Bool {
        self.isActive && self.sessionID == sessionID
    }

    func activate(draftPromptText: String, providerID: String, model: String, usesBuiltInPrompt: Bool = false) {
        self.sessionID = UUID()
        self.isActive = true
        self.draftPromptText = draftPromptText
        self.draftProviderID = providerID
        self.draftModel = model
        self.usesBuiltInPrompt = usesBuiltInPrompt
        self.isProcessing = false
        self.lastTranscriptionText = ""
        self.lastOutputText = ""
        self.lastError = ""
    }

    func deactivate() {
        self.sessionID = UUID()
        self.isActive = false
        self.draftPromptText = ""
        self.draftProviderID = ""
        self.draftModel = ""
        self.usesBuiltInPrompt = false
        self.isProcessing = false
    }

    func updateDraftPromptText(_ text: String) {
        guard self.isActive else { return }
        self.draftPromptText = text
    }

    func updateDraftConfiguration(providerID: String, model: String) {
        guard self.isActive else { return }
        self.draftProviderID = providerID
        self.draftModel = model
    }
}
