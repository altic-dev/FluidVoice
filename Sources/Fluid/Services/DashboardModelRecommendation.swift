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
    var languageID: String? = nil
    var id: String {
        "\(self.kind.rawValue):\(self.modelID)"
    }
}

enum DashboardModelRecommendationPolicy {
    /// Pro's languages use Pro or Mini by memory. Other languages use Qwen, or Whisper Large Turbo where a
    /// Mac FLEURS comparison showed Whisper clearly ahead or Qwen lacks the language. Below 8 GB nothing is recommended.
    static func speechModel(memoryBytes: UInt64, language: String?, available: [SettingsStore.SpeechModel]) -> SettingsStore.SpeechModel? {
        guard let language else { return nil }
        let candidates: [SettingsStore.SpeechModel]
        if VoiceEngineLanguageCatalog.parakeetV3LanguageIDs.contains(language) {
            candidates = [.fluidParakeetPro, .fluidParakeetMini]
        } else if VoiceEngineLanguageCatalog.qwenLanguageIDs.contains(language), !self.whisperPreferredLanguageIDs.contains(language) {
            candidates = [.qwen3Asr17B, .whisperLargeTurbo]
        } else if VoiceEngineLanguageCatalog.whisperLanguageCode(for: language) != nil {
            candidates = [.whisperLargeTurbo]
        } else {
            return nil
        }
        return candidates.first { model in
            guard let minimum = self.minimumMemoryGB(for: model), available.contains(model) else { return false }
            return memoryBytes >= UInt64(minimum) * 1024 * 1024 * 1024
        }
    }

    /// Smallest Mac memory each recommendable speech model is suggested for; nil means never suggested.
    static func minimumMemoryGB(for model: SettingsStore.SpeechModel) -> Int? {
        switch model {
        case .fluidParakeetPro: 16
        case .fluidParakeetMini, .qwen3Asr17B, .whisperLargeTurbo: 8
        default: nil
        }
    }

    /// Filipino and Turkish: Whisper Large Turbo clearly beat Qwen3-ASR 1.7B.
    private static let whisperPreferredLanguageIDs: Set<String> = ["tl", "tr"]

    /// A more accurate sibling of the recommended model already covers the user, so suggesting it would be a downgrade.
    private static let strongerSiblings: [SettingsStore.SpeechModel: SettingsStore.SpeechModel] = [
        .fluidParakeetMini: .fluidParakeetPro,
        .whisperLargeTurbo: .whisperLarge,
    ]

    /// Do not infer a language from the UI locale or stale onboarding preferences.
    static func speechLanguage(settings: SettingsStore) -> String? {
        let model = settings.selectedSpeechModel
        if model.parakeetDescriptor != nil || model == .parakeetRealtime { return "en" } // Same 25-language family (or English).
        // Qwen detects the language itself, so a saved Whisper language says nothing about what the user speaks.
        // Automatic 30/99-language routes return nil so they never silently lose language coverage.
        return VoiceEngineLanguageCatalog.boundLanguageID(settings: settings)
    }

    /// Either current cleanup model is a valid choice. A saved ID alone is not activation.
    static func shouldSuggestCleanup(targetID: String, selectedID: String, enabled: Bool, ready: Bool, dismissedID: String?) -> Bool {
        guard targetID != dismissedID else { return false }
        let currentModels: Set = ["fluid-1.1-ripple", "fluid-1.1-splash"]
        let currentChoice = selectedID == targetID || (currentModels.contains(targetID) && currentModels.contains(selectedID))
        return !enabled || !ready || !currentChoice
    }

    static func shouldSuggestSpeech(targetID: String, selectedID: String, dismissedID: String?) -> Bool {
        let stronger = SettingsStore.SpeechModel(rawValue: targetID).flatMap { self.strongerSiblings[$0] }
        return selectedID != stronger?.id && self.shouldShow(targetID: targetID, selectedID: selectedID, dismissedID: dismissedID)
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
    var isBusy: Bool {
        self.activeID != nil
    }

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
