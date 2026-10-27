import AppKit
import Combine
import Foundation

nonisolated struct DictationOverlayPresentation: Equatable, Sendable {
    var label: String
    var builtInLabel: String?
    var hasAppOverride: Bool

    static let pending = Self(label: "Dictation", builtInLabel: nil, hasAppOverride: false)
}

nonisolated struct DictationOverlayPresentationInput: Equatable, Sendable {
    struct Candidate: Equatable, Sendable {
        var name: String
        var builtInLabel: String?
        var hasAppOverride: Bool
        var usesSelectedPrivateModel: Bool
        var modelID: String

        func resolve(verifiedModelID: String?, modelName: (String) -> String) -> DictationOverlayPresentation {
            let modelID = self.usesSelectedPrivateModel ? (verifiedModelID ?? "") : self.modelID
            let model = modelName(modelID).replacingOccurrences(of: "Fluid-1 ", with: "")
            return DictationOverlayPresentation(
                label: model.isEmpty ? "Basic" : "\(self.name) · \(model)",
                builtInLabel: self.builtInLabel,
                hasAppOverride: self.hasAppOverride
            )
        }
    }

    struct Choices: Equatable, Sendable {
        let available: Candidate
        let unavailable: Candidate

        func resolve(verifiedModelID: String?, modelName: (String) -> String) -> DictationOverlayPresentation {
            (verifiedModelID == nil ? self.unavailable : self.available)
                .resolve(verifiedModelID: verifiedModelID, modelName: modelName)
        }
    }

    let verification: PrivateAIProviderPromptFormat.VerificationInput
    let primary: Choices
    let secondary: Choices

    @MainActor
    init(settings: SettingsStore, appBundleID: String?) {
        self.verification = .init(settings: settings)
        self.primary = Self.choices(settings: settings, slot: .primary, appBundleID: appBundleID)
        self.secondary = Self.choices(settings: settings, slot: .secondary, appBundleID: appBundleID)
    }

    @MainActor
    private static func choices(settings: SettingsStore, slot: SettingsStore.DictationShortcutSlot, appBundleID: String?) -> Choices {
        Choices(
            available: self.candidate(settings: settings, slot: slot, appBundleID: appBundleID, available: true),
            unavailable: self.candidate(settings: settings, slot: slot, appBundleID: appBundleID, available: false)
        )
    }

    @MainActor
    private static func candidate(settings: SettingsStore, slot: SettingsStore.DictationShortcutSlot, appBundleID: String?, available: Bool) -> Candidate {
        let selection = settings.resolvedDictationPromptSelection(for: slot, appBundleID: appBundleID, privateAIAvailable: available)
        let appOverride = settings.isAppDictationPromptBindingActive(for: slot, appBundleID: appBundleID, privateAIAvailable: available)
        let builtInLabel: String?
        switch selection {
        case .off: builtInLabel = "Basic"
        case .privateAI: builtInLabel = appOverride ? nil : SettingsStore.DictationModeLabels.smart
        case .default:
            builtInLabel = settings.resolvedDictationPromptProfile(for: slot, appBundleID: appBundleID, privateAIAvailable: available) == nil
                ? SettingsStore.DictationModeLabels.externalDefault : nil
        case .profile: builtInLabel = nil
        }
        let choice = DictationProviderRoute.modelChoice(settings: settings, selection: selection, appBundleID: appBundleID)
        let modelID: String
        if case let .provider(provider, configuredModel) = choice {
            modelID = DictationProviderRoute.modelID(settings: settings, providerID: provider, configuredModel: configuredModel)
        } else {
            modelID = ""
        }
        return Candidate(
            name: settings.dictationPromptDisplayName(for: slot, appBundleID: appBundleID, privateAIAvailable: available),
            builtInLabel: builtInLabel,
            hasAppOverride: appOverride,
            usesSelectedPrivateModel: choice == .privateAI,
            modelID: modelID
        )
    }

    func resolve() -> DictationOverlayPresentations {
        let verifiedModelID = self.verification.verifiedModelID(recheckInstallation: true)
        let modelName: (String) -> String = { id in
            guard !id.isEmpty else { return "" }
            return PrivateAIModelRegistry.model(id: id)?.displayName ?? id
        }
        return DictationOverlayPresentations(
            primary: self.primary.resolve(verifiedModelID: verifiedModelID, modelName: modelName),
            secondary: self.secondary.resolve(verifiedModelID: verifiedModelID, modelName: modelName)
        )
    }
}

nonisolated struct DictationOverlayPresentations: Equatable, Sendable {
    var primary: DictationOverlayPresentation
    var secondary: DictationOverlayPresentation

    static let pending = Self(primary: .pending, secondary: .pending)
}

/// One worker and one pending snapshot, regardless of how many settings events arrive.
/// Rendering reads strings only; it cannot trigger model, disk, or Keychain queries.
@MainActor
final class DictationOverlayPresentationStore: ObservableObject {
    static let shared = DictationOverlayPresentationStore()
    @Published private(set) var value = DictationOverlayPresentations.pending
    private var subscriptions = Set<AnyCancellable>()
    private var refreshQueued = false
    private var forceRefreshQueued = false
    private var revision: UInt64 = 0
    private var requestedInput: DictationOverlayPresentationInput?
    private var worker: Task<Void, Never>?
    private let resolve: @Sendable (DictationOverlayPresentationInput) async -> DictationOverlayPresentations

    init(resolve: @escaping @Sendable (DictationOverlayPresentationInput) async -> DictationOverlayPresentations = { $0.resolve() }) {
        self.resolve = resolve
    }

    func start() {
        guard self.subscriptions.isEmpty else { return }
        SettingsStore.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.scheduleRefresh() }
            .store(in: &self.subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &self.subscriptions)
        for name in [PrivateAIIntegrationService.installedModelsDidChangeNotification, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.scheduleRefresh(force: true) }
                .store(in: &self.subscriptions)
        }
        self.scheduleRefresh(force: true)
    }

    private func scheduleRefresh(force: Bool = false) {
        self.forceRefreshQueued = self.forceRefreshQueued || force
        guard !self.refreshQueued else { return }
        self.refreshQueued = true
        // Read after objectWillChange's originating setter finishes.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            let force = self.forceRefreshQueued
            self.forceRefreshQueued = false
            self.update(.init(settings: .shared, appBundleID: DictationAppSession.shared.appID), force: force)
        }
    }

    func update(_ input: DictationOverlayPresentationInput, force: Bool = false) {
        guard force || input != self.requestedInput else { return }
        self.requestedInput = input
        self.revision &+= 1
        guard self.worker == nil else { return }
        self.worker = Task { [weak self] in
            guard let self else { return }
            while let input = self.requestedInput {
                let revision = self.revision
                let resolve = self.resolve
                let result = await Task.detached(priority: .utility) { await resolve(input) }.value
                // Model removal, a prompt edit, or a new target app supersedes this result.
                guard revision == self.revision else { continue }
                if self.value != result { self.value = result }
                break
            }
            self.worker = nil
        }
    }
}
