import AppKit
import Combine

enum PrivateAIModelLoadState: Equatable {
    case idle
    case downloading(modelID: String, progress: PrivateAIModelDownloadProgress?)
    case loading(modelID: String)
    case loaded(modelID: String, latencyMilliseconds: Int?)
    case failed(modelID: String, message: String)

    func isLoading(_ modelID: String) -> Bool {
        if case .loading(modelID) = self { return true }
        return false
    }

    func isDownloading(_ modelID: String) -> Bool {
        if case .downloading(modelID, _) = self { return true }
        return false
    }

    func isLoaded(_ modelID: String) -> Bool {
        if case .loaded(modelID, _) = self { return true }
        return false
    }

    func latencyMilliseconds(for modelID: String) -> Int? {
        if case let .loaded(loadedModelID, latencyMilliseconds) = self, loadedModelID == modelID {
            return latencyMilliseconds
        }
        return nil
    }

    func failureMessage(for modelID: String) -> String? {
        if case let .failed(failedModelID, message) = self, failedModelID == modelID {
            return message
        }
        return nil
    }

    func downloadProgress(for modelID: String) -> PrivateAIModelDownloadProgress? {
        if case let .downloading(downloadingModelID, progress) = self, downloadingModelID == modelID {
            return progress
        }
        return nil
    }
}

/// Retained FI settings state and actions, shared by the existing page and its controls.
/// The runtime and persistence behavior remains in the existing services and provider view model.
@MainActor
final class PrivateAISettingsController: ObservableObject {
    let viewModel: AIEnhancementSettingsViewModel

    private var settings: SettingsStore { self.viewModel.settings }

    @Published private var session: PrivateAISettingsSession

    var privateAISelectedModelID: String { self.session.selectedModelID }
    var previewModelID: String { self.session.previewModelID }
    var isBusy: Bool { self.session.isBusy || self.viewModel.isTestingConnection }
    @Published var privateAILoadState: PrivateAIModelLoadState = .idle
    @Published var privateAIModelUpdateStatusByID: [String: PrivateAIModelUpdateStatus] = [:]

    init(viewModel: AIEnhancementSettingsViewModel) {
        self.viewModel = viewModel
        self.session = PrivateAISettingsSession(selectedModelID: PrivateAIIntegrationService.configuredModelID)
    }

    /// Carousel arrows/dots call this; no defaults, provider, or runtime writes.
    func previewModel(_ modelID: String) {
        guard let model = PrivateAIModelRegistry.model(id: modelID) else { return }
        self.session.preview(model.id)
    }

    func activatePreviewModel() {
        self.persistPrivateAIModelSelection(self.previewModelID)
    }

    /// Only the explicit Use/Download action enters this path; browsing remains read-only.
    func usePreviewModel(isInstalled: Bool, onReady: @escaping () -> Void) {
        guard !self.isBusy, let model = PrivateAIModelRegistry.model(id: self.previewModelID) else { return }
        self.persistPrivateAIModelSelection(model.id, loadIfInstalled: false)
        if isInstalled {
            self.verifyPrivateAIConnection(model, onReady: onReady)
        } else {
            self.downloadPrivateAIModel(model, onReady: onReady)
        }
    }

    func synchronizeSelection() {
        guard !self.isBusy else { return }
        self.session.select(PrivateAIIntegrationService.configuredModelID)
    }

    private func beginOperation(for modelID: String) -> UUID? {
        guard !self.isBusy, modelID == self.privateAISelectedModelID else { return nil }
        return self.session.begin()
    }

    func refreshPrivateAIProviderModels() {
        guard !self.isBusy else { return }
        let providerKey = self.viewModel.providerKey(for: PrivateAIProviderFeature.shared.providerID)
        let models = PrivateAIModelRegistry.modelIDs()
        let selected = PrivateAIModelRegistry.canonicalModelID(for: self.privateAISelectedModelID) ?? PrivateAIModelRegistry.defaultModel.id

        self.session.select(selected)
        self.viewModel.availableModelsByProvider[providerKey] = models
        self.viewModel.selectedModelByProvider[providerKey] = selected
        self.viewModel.settings.availableModelsByProvider = self.viewModel.availableModelsByProvider
        self.viewModel.settings.selectedModelByProvider = self.viewModel.selectedModelByProvider

        if self.viewModel.selectedProviderID == PrivateAIProviderFeature.shared.providerID {
            self.viewModel.availableModels = models
            self.viewModel.selectedModel = selected
        }

        self.refreshPrivateAILoadState()
        self.refreshPrivateAIModelUpdateStatus(self.selectedPrivateAIModel)
        self.viewModel.refreshProviderItems()
    }

    func refreshPrivateAIModelUpdateStatus(_ model: PrivateAIRegisteredModel) {
        guard !self.session.isBusy else { return }
        let revision = self.session.revision
        Task { @MainActor in
            let status = await PrivateAIIntegrationService.modelUpdateStatus(model)
            guard self.session.acceptsRead(revision) else { return }
            self.privateAIModelUpdateStatusByID[model.id] = status
        }
    }

    func downloadPrivateAIModel(_ model: PrivateAIRegisteredModel, onReady: (() -> Void)? = nil) {
        guard let operation = self.beginOperation(for: model.id) else { return }
        guard model.canDownload else {
            self.session.finish(operation)
            self.privateAILoadState = .failed(modelID: model.id, message: "Download URL is not configured yet.")
            return
        }

        self.privateAILoadState = .downloading(
            modelID: model.id,
            progress: PrivateAIModelDownloadProgress(initialExpectedBytes: model.artifact.byteCount)
        )
        Task { @MainActor in
            defer {
                self.session.finish(operation)
                self.refreshPrivateAIModelUpdateStatus(model)
            }
            do {
                DebugLogger.shared.info(
                    "Private provider download button pressed model=\(model.id)",
                    source: "AISettingsView"
                )
                _ = try await PrivateAIIntegrationService.prepareModel(model) { progress in
                    await MainActor.run {
                        guard self.session.operationID == operation else { return }
                        self.privateAILoadState = .downloading(
                            modelID: model.id,
                            progress: progress.withFallbackExpectedBytes(model.artifact.byteCount)
                        )
                    }
                }
                guard self.privateAISelectedModelID == model.id else { return }
                self.privateAILoadState = .loading(modelID: model.id)
                let start = ContinuousClock.now
                let verified = await self.viewModel.verifyPrivateAIProvider(model: model)
                let latencyMilliseconds = Self.elapsedMilliseconds(since: start)
                guard self.privateAISelectedModelID == model.id else { return }
                if verified {
                    self.privateAILoadState = .loaded(modelID: model.id, latencyMilliseconds: latencyMilliseconds)
                    onReady?()
                } else {
                    let message = self.viewModel.connectionErrorMessage(for: PrivateAIProviderFeature.shared.providerID).isEmpty
                        ? "Model downloaded, but verification failed."
                        : self.viewModel.connectionErrorMessage(for: PrivateAIProviderFeature.shared.providerID)
                    self.privateAILoadState = .failed(modelID: model.id, message: message)
                }
            } catch {
                guard self.privateAISelectedModelID == model.id else { return }
                self.privateAILoadState = .failed(
                    modelID: model.id,
                    message: Self.errorMessage(for: error)
                )
            }
            self.viewModel.refreshProviderItems()
        }
    }

    func updatePrivateAIModel(_ model: PrivateAIRegisteredModel) {
        guard self.privateAIModelUpdateStatusByID[model.id]?.state == .updateAvailable,
              let operation = self.beginOperation(for: model.id)
        else { return }
        let wasPreviouslyVerified = PrivateAIProviderPromptFormat.verifiedModelID(settings: self.settings) == model.id
        self.privateAILoadState = .downloading(
            modelID: model.id,
            progress: PrivateAIModelDownloadProgress(initialExpectedBytes: model.artifact.byteCount)
        )
        Task { @MainActor in
            defer {
                self.session.finish(operation)
                self.refreshPrivateAIModelUpdateStatus(model)
                self.viewModel.refreshProviderItems()
            }
            do {
                var verificationStart = ContinuousClock.now
                let verified = try await PrivateAISettingsUpdateTransaction.run(
                    update: {
                        try await PrivateAIIntegrationService.updateModel(model) { progress in
                            await MainActor.run {
                                guard self.session.operationID == operation else { return }
                                self.privateAILoadState = .downloading(
                                    modelID: model.id,
                                    progress: progress.withFallbackExpectedBytes(model.artifact.byteCount)
                                )
                            }
                        }
                    },
                    verify: {
                        self.privateAILoadState = .loading(modelID: model.id)
                        verificationStart = .now
                        return await self.viewModel.verifyPrivateAIProvider(model: model)
                    },
                    commit: { await PrivateAIIntegrationService.commitModelUpdate($0) },
                    rollback: { await PrivateAIIntegrationService.rollbackModelUpdate($0) }
                )
                if verified {
                    self.privateAILoadState = .loaded(
                        modelID: model.id, latencyMilliseconds: Self.elapsedMilliseconds(since: verificationStart)
                    )
                } else {
                    let detail = self.viewModel.connectionErrorMessage(for: PrivateAIProviderFeature.shared.providerID)
                    if wasPreviouslyVerified {
                        self.viewModel.updateConnectionStatus(.success, for: PrivateAIProviderFeature.shared.providerID)
                    }
                    self.privateAILoadState = .failed(
                        modelID: model.id,
                        message: "The new model failed verification. The previous model is still active. \(detail)"
                    )
                }
            } catch {
                self.privateAILoadState = .failed(
                    modelID: model.id,
                    message: "Update failed. The previous model is still active. \(Self.errorMessage(for: error))"
                )
            }
        }
    }

    /// Explicit callers can request a result; nil means success, otherwise a user-facing failure.
    func verifyPrivateAIConnection(_ model: PrivateAIRegisteredModel, onReady: (() -> Void)? = nil, onCompletion: ((String?) -> Void)? = nil) {
        guard let operation = self.beginOperation(for: model.id) else { return }
        self.privateAILoadState = .loading(modelID: model.id)
        Task { @MainActor in
            defer { self.session.finish(operation) }
            let start = ContinuousClock.now
            let verified = await self.viewModel.verifyPrivateAIProvider(model: model)
            let latencyMilliseconds = Self.elapsedMilliseconds(since: start)
            guard self.privateAISelectedModelID == model.id else { return }
            if verified {
                self.privateAILoadState = .loaded(modelID: model.id, latencyMilliseconds: latencyMilliseconds)
                onReady?()
                onCompletion?(nil)
            } else {
                let message = self.viewModel.connectionErrorMessage(for: PrivateAIProviderFeature.shared.providerID).isEmpty
                    ? "Model verification failed."
                    : self.viewModel.connectionErrorMessage(for: PrivateAIProviderFeature.shared.providerID)
                self.privateAILoadState = .failed(modelID: model.id, message: message)
                onCompletion?(message)
            }
            self.viewModel.refreshProviderItems()
        }
    }

    var selectedPrivateAIModel: PrivateAIRegisteredModel {
        PrivateAIModelRegistry.model(id: self.privateAISelectedModelID) ?? PrivateAIModelRegistry.defaultModel
    }

    func revealPrivateAIModelFolder() {
        let directoryURL = PrivateAIIntegrationService.modelDirectoryURL
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directoryURL)
        } catch {
            DebugLogger.shared.error(
                "Failed to open Private AI Provider models folder: \(error.localizedDescription)",
                source: "AISettingsView"
            )
        }
    }

    func refreshPrivateAILoadState() {
        guard !self.session.isBusy else { return }
        if case .failed = self.privateAILoadState { return }
        let revision = self.session.revision
        Task { @MainActor in
            let loaded = await PrivateAIIntegrationService.shared.loadedModelState()
            guard self.session.acceptsRead(revision) else { return }
            guard let loaded, loaded.state == .ready else {
                self.privateAILoadState = .idle
                return
            }

            self.privateAILoadState = .loaded(modelID: loaded.modelID, latencyMilliseconds: nil)
        }
    }

    func loadPrivateAIModel(_ model: PrivateAIRegisteredModel) {
        guard let operation = self.beginOperation(for: model.id) else { return }
        guard PrivateAIIntegrationService.isModelInstalled(model) else {
            self.session.finish(operation)
            self.privateAILoadState = .failed(modelID: model.id, message: "Model file is not installed.")
            return
        }

        self.privateAILoadState = .loading(modelID: model.id)
        Task { @MainActor in
            defer {
                self.session.finish(operation)
                self.refreshPrivateAIModelUpdateStatus(model)
            }
            do {
                let start = ContinuousClock.now
                let status = try await PrivateAIIntegrationService.shared.loadModel(model)
                let latencyMilliseconds = Self.elapsedMilliseconds(since: start)
                guard self.privateAISelectedModelID == model.id else { return }
                switch status.state {
                case .ready:
                    self.privateAILoadState = .loaded(modelID: model.id, latencyMilliseconds: latencyMilliseconds)
                default:
                    self.privateAILoadState = .failed(
                        modelID: model.id,
                        message: status.message ?? "Model did not report ready."
                    )
                }
            } catch {
                guard self.privateAISelectedModelID == model.id else { return }
                self.privateAILoadState = .failed(
                    modelID: model.id,
                    message: Self.errorMessage(for: error)
                )
            }
            self.viewModel.refreshProviderItems()
        }
    }

    func resetPrivateAIVerification(for model: PrivateAIRegisteredModel) {
        guard let operation = self.beginOperation(for: model.id) else { return }
        self.viewModel.resetVerification(for: PrivateAIProviderFeature.shared.providerID)
        self.privateAILoadState = .idle
        Task { @MainActor in
            defer { self.session.finish(operation) }
            await PrivateAIIntegrationService.shared.unloadCachedRuntime(reason: "Fluid Intelligence verification reset")
            if PrivateAIIntegrationService.isModelInstalled(model) {
                self.privateAILoadState = .idle
            }
            self.viewModel.refreshProviderItems()
        }
    }

    func deletePrivateAIModel(_ model: PrivateAIRegisteredModel) {
        guard let operation = self.beginOperation(for: model.id) else { return }
        guard PrivateAIIntegrationService.canRemoveInstalledModel(model) else {
            self.session.finish(operation)
            return
        }
        self.privateAILoadState = .loading(modelID: model.id)
        Task { @MainActor in
            defer { self.session.finish(operation) }
            do {
                try await PrivateAIIntegrationService.shared.unloadAndRemoveInstalledModel(
                    model,
                    reason: "settings-delete"
                )
                self.viewModel.resetVerification(for: PrivateAIProviderFeature.shared.providerID)
                if self.privateAISelectedModelID == model.id {
                    self.privateAILoadState = .idle
                }
                self.viewModel.refreshProviderItems()
            } catch {
                guard self.privateAISelectedModelID == model.id else { return }
                self.privateAILoadState = .failed(modelID: model.id, message: Self.errorMessage(for: error))
            }
        }
    }

    private static func errorMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription
        {
            return description
        }
        return String(describing: error)
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: ContinuousClock.now)
        return Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    func persistPrivateAIModelSelection(_ value: String, loadIfInstalled: Bool = true) {
        guard let model = PrivateAIModelRegistry.model(id: value), model.id != self.privateAISelectedModelID else { return }
        let providerKey = self.viewModel.providerKey(for: PrivateAIProviderFeature.shared.providerID)
        let models = PrivateAIModelRegistry.modelIDs()

        guard !self.isBusy, self.session.select(model.id) else { return }
        UserDefaults.standard.set(model.id, forKey: PrivateAIIntegrationService.selectedModelDefaultsKey)
        UserDefaults.standard.removeObject(forKey: PrivateAIIntegrationService.localModelPathDefaultsKey)

        self.viewModel.availableModelsByProvider[providerKey] = models
        self.viewModel.selectedModelByProvider[providerKey] = model.id
        self.viewModel.settings.availableModelsByProvider = self.viewModel.availableModelsByProvider
        self.viewModel.settings.selectedModelByProvider = self.viewModel.selectedModelByProvider

        if self.viewModel.selectedProviderID == PrivateAIProviderFeature.shared.providerID {
            self.viewModel.availableModels = models
            self.viewModel.selectedModel = model.id
        }
        self.viewModel.resetVerification(for: PrivateAIProviderFeature.shared.providerID)
        self.refreshPrivateAIModelUpdateStatus(model)
        self.viewModel.refreshProviderItems()
        if loadIfInstalled, PrivateAIIntegrationService.isModelInstalled(model) {
            self.loadPrivateAIModel(model)
        } else {
            self.privateAILoadState = .idle
        }
    }

    func setPrivateAIBackendPreference(_ preference: SettingsStore.PrivateAIBackendPreference) {
        guard self.settings.privateAIBackendPreference != preference else { return }
        guard let operation = self.beginOperation(for: self.privateAISelectedModelID) else { return }
        let modelID = self.privateAISelectedModelID

        self.settings.privateAIBackendPreference = preference
        UserDefaults.standard.removeObject(forKey: PrivateAIIntegrationService.localModelPathDefaultsKey)
        self.privateAILoadState = .idle
        self.viewModel.resetVerification(for: PrivateAIProviderFeature.shared.providerID)

        Task { @MainActor in
            defer { self.session.finish(operation) }
            await PrivateAIIntegrationService.shared.unloadCachedRuntime(
                reason: "Fluid Intelligence backend changed to \(preference.displayName)"
            )
            guard self.privateAISelectedModelID == modelID else { return }
            let model = self.selectedPrivateAIModel
            if PrivateAIIntegrationService.isModelInstalled(model) {
                self.session.finish(operation)
                self.verifyPrivateAIConnection(model)
            } else {
                self.privateAILoadState = .idle
                self.viewModel.refreshProviderItems()
            }
        }
    }

    func setPrefixCacheEnabled(_ enabled: Bool) {
        guard self.settings.privateAIPrefixKVCacheEnabled != enabled else { return }
        guard let operation = self.beginOperation(for: self.privateAISelectedModelID) else { return }
        self.settings.privateAIPrefixKVCacheEnabled = enabled
        self.privateAILoadState = .idle
        Task { @MainActor in
            defer { self.session.finish(operation) }
            await PrivateAIIntegrationService.shared.unloadCachedRuntime(
                reason: enabled ? "prefix cache enabled" : "prefix cache disabled"
            )
            self.viewModel.refreshProviderItems()
        }
    }

    func setBoostEnabled(_ enabled: Bool) {
        guard self.settings.privateAIBoostEnabled != enabled else { return }
        guard let operation = self.beginOperation(for: self.privateAISelectedModelID) else { return }
        self.settings.privateAIBoostEnabled = enabled
        self.privateAILoadState = .idle
        Task { @MainActor in
            defer { self.session.finish(operation) }
            await PrivateAIIntegrationService.shared.unloadCachedRuntime(
                reason: enabled ? "Fluid-1 Boost enabled" : "Fluid-1 Boost disabled"
            )
            self.viewModel.refreshProviderItems()
        }
    }

    func setContextTokenLimit(_ value: Int) {
        let clamped = SettingsStore.clampPrivateAIContextTokenLimit(value)
        guard self.settings.privateAIContextTokenLimit != clamped else { return }
        guard let operation = self.beginOperation(for: self.privateAISelectedModelID) else { return }
        self.settings.privateAIContextTokenLimit = clamped
        self.privateAILoadState = .idle
        Task { @MainActor in
            defer { self.session.finish(operation) }
            await PrivateAIIntegrationService.shared.unloadCachedRuntime(
                reason: "Fluid Intelligence context changed"
            )
            self.viewModel.refreshProviderItems()
        }
    }
}
