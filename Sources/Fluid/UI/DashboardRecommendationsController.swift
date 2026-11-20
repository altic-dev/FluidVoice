import Combine
import Foundation

@MainActor
final class DashboardRecommendationsController: ObservableObject {
    struct Selection: Equatable {
        let speech: SettingsStore.SpeechModel
        let language: String?
        let cleanupID: String
        let backend: String
        let prompt: SettingsStore.DictationPromptSelection
        let verification: PrivateAIProviderPromptFormat.VerificationInput
        let usesPrivateAI: Bool

        init(settings: SettingsStore) {
            self.speech = settings.selectedSpeechModel
            self.language = DashboardModelRecommendationPolicy.speechLanguage(settings: settings)
            let stored = UserDefaults.standard.string(forKey: PrivateAIIntegrationService.selectedModelDefaultsKey) ?? PrivateAIModelRegistry.defaultModelID
            self.verification = PrivateAIProviderPromptFormat.VerificationInput(settings: settings)
            let selected = self.verification.selectedModelID ?? stored
            self.cleanupID = PrivateAIModelRegistry.canonicalModelID(for: selected) ?? selected
            self.backend = settings.privateAIBackendPreference.rawValue
            self.prompt = settings.dictationPromptSelection(for: .primary, privateAIAvailable: true)
            self.usesPrivateAI = SettingsStore.DictationShortcutSlot.allCases.contains {
                DictationProviderRoute.privateAIWarmupVerification(settings: settings, slot: $0, appBundleID: nil) != nil
            }
        }
    }

    @Published private(set) var recommendations: [DashboardModelRecommendation] = []
    let operation = DashboardRecommendationOperation()
    private let asr: ASRService
    private let settings = SettingsStore.shared
    private let dismissals = DashboardRecommendationDismissals(defaults: .standard)
    private var observation: AnyCancellable?
    private var lease: ASRActivityLease?
    private var refreshRevision = 0

    init(asr: ASRService) {
        self.asr = asr
        self.observation = self.operation.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    var actionsBlocked: Bool {
        self.operation.isBusy || self.asr.activeExclusiveActivity != nil || self.asr.isRunningOrStarting
            || self.asr.isMicrophonePreviewActive || self.asr.isDictionaryTrainingCaptureActive
            || self.asr.hasActiveModelDownload || self.asr.hasActiveModelPreparation
            || self.asr.isCancellingModelPreparation || self.asr.isCancellingModelDownload || self.asr.deletingModelID != nil
            || NotchContentState.shared.isProcessing || DictationPromptTestCoordinator.shared.isActive
    }

    func refresh() async {
        guard !self.operation.isBusy else { return }
        self.refreshRevision += 1
        let revision = self.refreshRevision
        let selection = Selection(settings: self.settings)
        let hardware = await PrivateAIMacHardware.current()
        guard !Task.isCancelled else { return }
        var result: [DashboardModelRecommendation] = []
        if let model = DashboardModelRecommendationPolicy.speechModel(
            memoryBytes: hardware.memoryBytes, language: selection.language, available: SettingsStore.SpeechModel.availableModels
        ), DashboardModelRecommendationPolicy.shouldSuggestSpeech(targetID: model.id, selectedID: selection.speech.id, dismissedID: self.dismissals.modelID(for: .speech)) {
            result.append(DashboardModelRecommendation(
                kind: .speech,
                modelID: model.id,
                name: model.humanReadableName,
                detail: Self.speechDetail(for: model, languageID: selection.language),
                downloadSize: model.downloadSize,
                installed: false,
                languageID: selection.language
            ))
        }
        if let cleanupID = PrivateAIModelRegistry.recommendedModelID(for: .dictation, on: hardware),
           CPUArchitecture.isAppleSilicon, PrivateAIProviderFeature.shared.isAvailable,
           let model = PrivateAIModelRegistry.model(id: cleanupID), model.isEnabled, model.canDownload,
           hardware.memoryBytes >= UInt64(max(0, model.recommendedMemoryGB ?? 8)) * 1024 * 1024 * 1024
        {
            let (installed, selectedReady) = await Task.detached(priority: .utility) {
                (
                    PrivateAIIntegrationService.isModelInstalled(model, useCache: false),
                    selection.verification.verifiedModelID(recheckInstallation: true) != nil
                )
            }.value
            if DashboardModelRecommendationPolicy.shouldSuggestCleanup(
                targetID: model.id,
                selectedID: selection.cleanupID,
                enabled: selection.usesPrivateAI,
                ready: selectedReady,
                dismissedID: self.dismissals.modelID(for: .cleanup)
            ) {
                result.append(DashboardModelRecommendation(
                    kind: .cleanup,
                    modelID: model.id,
                    name: model.presentation?.shortName ?? model.displayName,
                    detail: model.presentation?.useCase ?? "Polish your words privately on your Mac.",
                    downloadSize: model.artifact.byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "",
                    installed: installed
                ))
            }
        }
        guard !Task.isCancelled, !self.operation.isBusy, revision == self.refreshRevision, selection == Selection(settings: self.settings) else { return }
        self.recommendations = result
    }

    static func speechDetail(for model: SettingsStore.SpeechModel, languageID: String?) -> String {
        switch model {
        case .fluidParakeetPro:
            return "Our most accurate speech model, running privately on your Mac."
        case .fluidParakeetMini:
            return "Accurate on-device dictation with a lighter memory footprint."
        default:
            let language = languageID.flatMap { VoiceEngineLanguageCatalog.language(id: $0)?.displayName }
            let match = language.map { "The best match for \($0) on your Mac." } ?? "A strong match for your language."
            return model.supportsStreaming ? match : "\(match) Your words appear when you stop talking."
        }
    }

    func dismiss(_ recommendation: DashboardModelRecommendation) {
        guard !self.operation.isBusy else { return }
        self.dismissals.dismiss(recommendation)
        self.recommendations.removeAll { $0.id == recommendation.id }
    }

    func use(_ recommendation: DashboardModelRecommendation) {
        guard !self.actionsBlocked, self.recommendations.contains(recommendation) else { return }
        let selection = Selection(settings: self.settings)
        guard recommendation.kind != .speech || selection.language == recommendation.languageID else { return }
        self.operation.start(
            id: recommendation.id,
            prepare: {
                self.lease = try self.asr.acquireExclusiveActivity(.modelMaintenance)
                switch recommendation.kind {
                case .speech:
                    guard let model = SettingsStore.SpeechModel(rawValue: recommendation.modelID) else { throw CancellationError() }
                    if !SpeechModelInstallationSnapshot.shared.isInstalled(modelID: model.id) {
                        self.operation.report("Downloading…")
                        try await self.asr.downloadModel(
                            model,
                            progressHandler: { [weak controller = self] fraction in
                                controller?.operation.report("Downloading…", fraction: fraction)
                            }
                        )
                    }
                case .cleanup:
                    guard let model = PrivateAIModelRegistry.model(id: recommendation.modelID) else { throw CancellationError() }
                    let installed = await Task.detached(priority: .utility) { PrivateAIIntegrationService.isModelInstalled(model, useCache: false) }.value
                    try Task.checkCancellation()
                    if !installed {
                        self.operation.report("Downloading…")
                        _ = try await PrivateAIIntegrationService.prepareModel(model) { [weak self] progress in
                            await MainActor.run { self?.operation.report("Downloading…", fraction: progress.fractionCompleted) }
                        }
                    }
                    try Task.checkCancellation()
                    guard selection == Selection(settings: self.settings) else { throw CancellationError() }
                    self.operation.report("Checking model…")
                    let status = try await PrivateAIIntegrationService.shared.verifyModel(model)
                    guard status.state == .ready else {
                        throw NSError(domain: "DashboardRecommendation", code: 1, userInfo: [NSLocalizedDescriptionKey: status.message ?? "The model could not be activated. Please try again."])
                    }
                }
            },
            isCurrent: { selection == Selection(settings: self.settings) },
            activate: {
                switch recommendation.kind {
                case .speech:
                    guard let model = SettingsStore.SpeechModel(rawValue: recommendation.modelID) else { throw CancellationError() }
                    self.releaseLease()
                    try await Self.activateSpeech(
                        model,
                        languageID: recommendation.languageID,
                        settings: self.settings,
                        reset: { self.asr.resetTranscriptionProvider() },
                        prepare: { try await self.asr.ensureAsrReady(source: .settings) }
                    )
                case .cleanup:
                    DashboardCleanupActivation.commit(modelID: recommendation.modelID, settings: self.settings, defaults: .standard)
                }
            },
            finished: {
                self.releaseLease()
                SpeechModelInstallationSnapshot.shared.refresh()
                Task { await self.refresh() }
            }
        )
    }

    static func activateSpeech(
        _ model: SettingsStore.SpeechModel, languageID: String?, settings: SettingsStore,
        reset: () -> Void, prepare: () async throws -> Void
    ) async throws {
        let previous = settings.selectedSpeechModel
        let previousLanguage = settings.selectedWhisperLanguageCode
        let whisperLanguage = model.isWhisperModel ? languageID.flatMap(VoiceEngineLanguageCatalog.whisperLanguageCode(for:)) : nil
        if let whisperLanguage { settings.selectedWhisperLanguageCode = whisperLanguage }
        settings.selectedSpeechModel = model
        reset()
        do {
            try await prepare()
        } catch {
            if settings.selectedSpeechModel == model {
                if let whisperLanguage, settings.selectedWhisperLanguageCode == whisperLanguage {
                    settings.selectedWhisperLanguageCode = previousLanguage
                }
                settings.selectedSpeechModel = previous
                reset()
            }
            throw error
        }
    }

    private func releaseLease() {
        if let lease { self.asr.releaseExclusiveActivity(lease) }
        self.lease = nil
    }
}

/// Commit only the verified dictation model. Edit Mode, app-specific routes and other shortcuts stay intact.
@MainActor
enum DashboardCleanupActivation {
    static func commit(modelID: String, settings: SettingsStore, defaults: UserDefaults) {
        let provider = PrivateAIProviderFeature.shared.providerID
        let key = ModelRepository.shared.isBuiltIn(provider) ? provider : "custom:\(provider)"
        defaults.set(modelID, forKey: PrivateAIIntegrationService.selectedModelDefaultsKey)
        defaults.removeObject(forKey: PrivateAIIntegrationService.localModelPathDefaultsKey)
        var models = settings.selectedModelByProvider
        models[key] = modelID
        settings.selectedModelByProvider = models
        let fingerprint = PrivateAIProviderFeature.verificationFingerprint(for: modelID)
        var verified = settings.verifiedPrivateAIModelFingerprints
        verified[modelID] = fingerprint
        settings.verifiedPrivateAIModelFingerprints = verified
        var providers = settings.verifiedProviderFingerprints
        providers[key] = fingerprint
        settings.verifiedProviderFingerprints = providers
        settings.setDictationPromptSelection(.privateAI)
    }
}
