import Combine
import Foundation

/// Recommendations are invitations, never migrations. IDs come from the shipped catalogs.
struct DashboardModelRecommendation: Identifiable, Equatable {
    enum Kind: String { case speech, cleanup }
    let kind: Kind
    let modelID: String
    let name: String
    let detail: String
    let downloadSize: String
    let installed: Bool
    var id: String { "\(self.kind.rawValue):\(self.modelID)" }
}

enum DashboardModelRecommendationPolicy {
    static func speechModel(memoryBytes: UInt64, language: String?, available: [SettingsStore.SpeechModel]) -> SettingsStore.SpeechModel? {
        guard let language, VoiceEngineLanguageCatalog.parakeetV3LanguageIDs.contains(language) else { return nil }
        let gib: UInt64 = 1024 * 1024 * 1024
        let model: SettingsStore.SpeechModel = memoryBytes >= 16 * gib ? .fluidParakeetPro : .fluidParakeetMini
        guard memoryBytes >= 8 * gib, available.contains(model) else { return nil }
        return model
    }

    /// Do not infer a language from the UI locale or stale onboarding preferences.
    static func speechLanguage(settings: SettingsStore) -> String? {
        let model = settings.selectedSpeechModel
        if model.parakeetDescriptor != nil || model == .parakeetRealtime { return "en" } // Same 25-language family (or English).
        if model.whisperModelFile != nil { return settings.selectedWhisperLanguageCode }
        switch model {
        case .appleSpeech, .appleSpeechAnalyzer:
            return settings.selectedAppleSpeechLocaleIdentifier.split(separator: "-").first.map(String.init)
        case .cohereTranscribeSixBit:
            return settings.selectedCohereLanguage.rawValue
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return settings.selectedNemotronLanguage.rawValue.split(separator: "-").first.map(String.init)
        default:
            return nil // Automatic 30/99-language routes must not silently lose language coverage.
        }
    }

    /// Either current cleanup model is a valid choice. A saved ID alone is not activation.
    static func shouldSuggestCleanup(targetID: String, selectedID: String, enabled: Bool, ready: Bool, dismissedID: String?) -> Bool {
        guard targetID != dismissedID else { return false }
        let currentModels: Set<String> = ["fluid-1.1-ripple", "fluid-1.1-splash"]
        let currentChoice = selectedID == targetID || (currentModels.contains(targetID) && currentModels.contains(selectedID))
        return !enabled || !ready || !currentChoice
    }

    static func shouldSuggestSpeech(targetID: String, selectedID: String, dismissedID: String?) -> Bool {
        // A user already on Pro should not be nudged down to Mini on a smaller Mac.
        selectedID != SettingsStore.SpeechModel.fluidParakeetPro.id && self.shouldShow(targetID: targetID, selectedID: selectedID, dismissedID: dismissedID)
    }

    static func shouldShow(targetID: String, selectedID: String, dismissedID: String?) -> Bool {
        targetID != selectedID && targetID != dismissedID
    }
}

/// One dismissal per category: it survives relaunch, but a genuinely new model can be suggested.
struct DashboardRecommendationDismissals {
    let defaults: UserDefaults
    func modelID(for kind: DashboardModelRecommendation.Kind) -> String? {
        self.defaults.string(forKey: "DashboardRecommendationDismissed.\(kind.rawValue)")
    }

    func dismiss(_ recommendation: DashboardModelRecommendation) {
        self.defaults.set(recommendation.modelID, forKey: "DashboardRecommendationDismissed.\(recommendation.kind.rawValue)")
    }
}

/// Preparation may suspend or fail; selection changes only after success and a fresh intent check.
@MainActor
final class DashboardRecommendationOperation: ObservableObject {
    @Published private(set) var activeID: String?
    @Published private(set) var message = ""
    @Published private(set) var fraction: Double?
    @Published private(set) var error: String?
    @Published private(set) var failedID: String?
    @Published private(set) var cancelling = false
    private var task: Task<Void, Never>?
    var isBusy: Bool { self.activeID != nil }

    func start(
        id: String,
        prepare: @escaping () async throws -> Void,
        isCurrent: @escaping () -> Bool,
        activate: @escaping () async throws -> Void,
        finished: @escaping () -> Void
    ) {
        guard !self.isBusy else { return }
        self.activeID = id
        self.error = nil
        self.failedID = nil
        self.fraction = nil
        self.message = "Preparing…"
        self.cancelling = false
        self.task = Task {
            defer {
                self.activeID = nil
                self.task = nil
                self.cancelling = false
                finished()
            }
            do {
                try await prepare()
                try Task.checkCancellation()
                guard isCurrent() else { throw CancellationError() }
                self.message = "Activating…"
                self.fraction = nil
                try await activate()
            } catch is CancellationError {
                // Cancellation and a newer selection never apply the old intent.
            } catch {
                self.error = error.localizedDescription
                self.failedID = id
            }
        }
    }

    func report(_ message: String, fraction: Double? = nil) {
        guard self.isBusy, !self.cancelling else { return }
        self.message = message
        self.fraction = fraction.map { min(1, max(0, $0)) }
    }

    func cancel() {
        guard self.isBusy else { return }
        self.cancelling = true
        self.message = "Cancelling…"
        self.task?.cancel()
    }
}
