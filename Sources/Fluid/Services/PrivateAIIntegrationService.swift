import Foundation

actor PrivateAIIntegrationService {
    static let shared = PrivateAIIntegrationService()
    private nonisolated let dictationProviderOverride: (any PrivateAIIntegrationProviding)?

    static var selectedModelDefaultsKey: String {
        PrivateAIProviderFeature.shared.selectedModelDefaultsKey
    }

    static var localModelPathDefaultsKey: String {
        PrivateAIProviderFeature.shared.localModelPathDefaultsKey
    }

    struct RuntimeConfiguration: Sendable, Equatable {
        let selectedProviderID: String
        let providerKey: String
        let baseURL: String
        let model: String
        let apiKey: String
        let localModelPath: String?
        let usesStablePromptPrefixKVCache: Bool
        let usesFluid1Boost: Bool
        let contextTokenLimit: Int
    }

    struct AppContext: Sendable, Equatable {
        let appName: String
        let bundleID: String
        let windowTitle: String
        let appVersion: String?
    }

    struct EnhancementResult: Sendable, Equatable {
        let outputText: String
        let backendKind: String?
        let latencyMilliseconds: Int?
        let tokensPerSecond: Double?

        init(
            outputText: String,
            backendKind: String?,
            latencyMilliseconds: Int?,
            tokensPerSecond: Double? = nil
        ) {
            self.outputText = outputText
            self.backendKind = backendKind
            self.latencyMilliseconds = latencyMilliseconds
            self.tokensPerSecond = tokensPerSecond
        }
    }

    struct LoadedModelState: Sendable, Equatable {
        let modelID: String
        let state: PrivateAIRuntimeState
        let message: String?
    }

    private init() {
        self.dictationProviderOverride = nil
    }

    #if DEBUG
    init(testingProvider: any PrivateAIIntegrationProviding) {
        self.dictationProviderOverride = testingProvider
    }
    #endif

    /// Called only inside the meeting residency scope, after other models are suspended.
    static func summarizeMeeting(_ transcript: String, style: String) async throws -> String {
        guard await MeetingModelResidencyCoordinator.shared.phase == .summary else {
            throw MeetingModelResidencyError.staleGrant
        }
        do {
            let output = try await provider.summarizeMeeting(transcript, style: style)
            await Task { await self.provider.unloadCachedRuntime(reason: "meeting summary complete") }.value
            return output
        } catch {
            await Task { await self.provider.unloadCachedRuntime(reason: "meeting summary ended") }.value
            throw error
        }
    }

    private nonisolated static var provider: any PrivateAIIntegrationProviding {
        PrivateAIProviderFeature.shared.isAvailable
            ? PrivateAIProviderRegistry.integration
            : UnavailableAIIntegrationShim.shared
    }

    private nonisolated var dictationProvider: any PrivateAIIntegrationProviding {
        self.dictationProviderOverride ?? Self.provider
    }

    nonisolated static var configuredModelID: String {
        provider.configuredModelID
    }

    nonisolated static var selectedModel: PrivateAIRegisteredModel {
        provider.selectedModel
    }

    nonisolated static var configuredLocalModelPath: String? {
        provider.configuredLocalModelPath
    }

    nonisolated static var modelDirectoryURL: URL {
        provider.modelDirectoryURL
    }

    nonisolated static func expectedLocalModelURL(for model: PrivateAIRegisteredModel) -> URL {
        self.provider.expectedLocalModelURL(for: model)
    }

    nonisolated static func localModelPath(for model: PrivateAIRegisteredModel) -> String? {
        self.provider.localModelPath(for: model)
    }

    // Installation checks walk the model directory. SwiftUI bodies ask several
    // times per frame, so serve a briefly cached answer instead of hitting disk.
    private nonisolated static let installedModelCacheLock = NSLock()
    private nonisolated(unsafe) static var installedModelCache: [String: (installed: Bool, checkedAt: TimeInterval)] = [:]
    private nonisolated static let installedModelCacheLifetime: TimeInterval = 2

    nonisolated static func isModelInstalled(_ model: PrivateAIRegisteredModel) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        self.installedModelCacheLock.lock()
        let cached = self.installedModelCache[model.id]
        self.installedModelCacheLock.unlock()
        if let cached, now - cached.checkedAt < self.installedModelCacheLifetime {
            return cached.installed
        }

        let installed = self.provider.isModelInstalled(model)
        self.installedModelCacheLock.lock()
        self.installedModelCache[model.id] = (installed, now)
        self.installedModelCacheLock.unlock()
        return installed
    }

    nonisolated static func invalidateInstalledModelCache() {
        self.installedModelCacheLock.lock()
        self.installedModelCache.removeAll()
        self.installedModelCacheLock.unlock()
    }

    nonisolated static func canRemoveInstalledModel(_ model: PrivateAIRegisteredModel) -> Bool {
        guard let targetURLs = try? self.validatedModelURLs(self.provider.installedModelURLs(for: model)) else {
            return false
        }
        return !targetURLs.isEmpty
    }

    nonisolated static func hasInactiveInstalledModel(keeping model: PrivateAIRegisteredModel) -> Bool {
        !self.provider.inactiveInstalledModelURLs(keeping: model).isEmpty
    }

    nonisolated static func removeInstalledModel(_ model: PrivateAIRegisteredModel) throws {
        defer { self.invalidateInstalledModelCache() }
        let requestedURLs = self.provider.installedModelURLs(for: model)
        guard !requestedURLs.isEmpty else { return }
        let targetURLs = try self.validatedModelURLs(requestedURLs)
        try self.removeModelFiles(at: targetURLs)
    }

    nonisolated static func removeInactiveInstalledModels(keeping model: PrivateAIRegisteredModel) throws {
        defer { self.invalidateInstalledModelCache() }
        let requestedURLs = self.provider.inactiveInstalledModelURLs(keeping: model)
        guard !requestedURLs.isEmpty else { return }
        let targetURLs = try self.validatedModelURLs(requestedURLs)
        try self.removeModelFiles(at: targetURLs)
    }

    private nonisolated static func validatedModelURLs(_ urls: [URL]) throws -> [URL] {
        guard !urls.isEmpty else { return [] }
        let modelDirectoryURL = self.modelDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let modelDirectoryPath = modelDirectoryURL.path
        // Preserve provider order: model files precede their installation receipt.
        var seen = Set<URL>()
        let targetURLs = urls.map { $0.resolvingSymlinksInPath().standardizedFileURL }
            .filter { seen.insert($0).inserted }
        guard targetURLs.allSatisfy({ $0.path.hasPrefix(modelDirectoryPath + "/") }) else {
            throw PrivateAIModelRemovalError(message: "A model file is not in FluidVoice's model folder.")
        }
        return targetURLs
    }

    private nonisolated static func removeModelFiles(at targetURLs: [URL]) throws {
        let modelDirectoryURL = self.modelDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let fileManager = FileManager.default
        for targetURL in targetURLs where fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }

        let parentDirectories = Set(targetURLs.map { $0.deletingLastPathComponent() })
            .filter { $0 != modelDirectoryURL }
            .sorted { $0.path.count > $1.path.count }
        for directoryURL in parentDirectories {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directoryURL.path),
                  contents.isEmpty
            else { continue }
            try? fileManager.removeItem(at: directoryURL)
        }
    }

    func unloadAndRemoveInstalledModel(_ model: PrivateAIRegisteredModel, reason: String) async throws {
        if await MeetingModelResidencyCoordinator.shared.isExclusive {
            await MeetingModelResidencyCoordinator.shared.vetoRestoration(owner: "fluid")
            throw MeetingModelResidencyError.busy
        }
        try await Self.modelActivity(modelID: model.id) {
            await Self.provider.unloadCachedRuntime(reason: reason)
            try Self.removeInstalledModel(model)
        }
    }

    nonisolated static func prepareModel(
        _ model: PrivateAIRegisteredModel,
        progressHandler: PrivateAIModelDownloadProgressHandler? = nil
    ) async throws -> URL {
        defer { self.invalidateInstalledModelCache() }
        return try await self.modelActivity(modelID: model.id) { try await self.provider.prepareModel(model, progressHandler: progressHandler) }
    }

    nonisolated static func modelUpdateStatus(
        _ model: PrivateAIRegisteredModel
    ) async -> PrivateAIModelUpdateStatus {
        await self.provider.modelUpdateStatus(model)
    }

    nonisolated static func updateModel(
        _ model: PrivateAIRegisteredModel,
        progressHandler: PrivateAIModelDownloadProgressHandler? = nil
    ) async throws -> PrivateAIModelUpdateToken {
        // Installation, verification and commit/rollback are one transaction. Do not let a
        // meeting snapshot the temporary runtime between those settings-controller callbacks.
        let admission = try await MeetingModelResidencyCoordinator.shared.beginOperation(owner: "fluid", modelID: model.id)
        do {
            let token = try await Self.modelActivity(modelID: model.id) { try await self.provider.updateModel(model, progressHandler: progressHandler) }
            await MainActor.run { Self.updateAdmissions[token.id] = admission }
            return token
        } catch {
            await MeetingModelResidencyCoordinator.shared.endOperation(admission)
            throw error
        }
    }

    @MainActor private static var updateAdmissions: [UUID: UUID] = [:]

    nonisolated static func commitModelUpdate(_ token: PrivateAIModelUpdateToken) async {
        guard let admission = await MainActor.run(body: { Self.updateAdmissions.removeValue(forKey: token.id) }) else { return }
        await self.provider.commitModelUpdate(token)
        await MeetingModelResidencyCoordinator.shared.endOperation(admission)
    }

    nonisolated static func rollbackModelUpdate(_ token: PrivateAIModelUpdateToken) async {
        guard let admission = await MainActor.run(body: { Self.updateAdmissions.removeValue(forKey: token.id) }) else { return }
        await self.provider.rollbackModelUpdate(token)
        await MeetingModelResidencyCoordinator.shared.endOperation(admission)
    }

    nonisolated static var isLocalRuntimeConfigured: Bool {
        provider.isLocalRuntimeConfigured
    }

    nonisolated static func shouldHandleDictation(model: String) -> Bool {
        self.provider.shouldHandleDictation(model: model)
    }

    func status(for runtime: RuntimeConfiguration) async -> PrivateAIStatus {
        do { return try await Self.modelActivity { await Self.provider.status(for: runtime) } } catch { return PrivateAIStatus(state: .failed, message: error.localizedDescription) }
    }

    @MainActor
    static func meetingResidencyParticipant() -> MeetingModelParticipant {
        MeetingModelParticipant(
            owner: "fluid",
            snapshot: { try await Self.provider.residencySnapshot() },
            suspend: {
                await Self.idleUnloader.suspendForMeeting()
                await Self.provider.unloadCachedRuntime(reason: "meeting processing")
                await Self.postRuntimeDidChange()
            },
            restore: { model in
                try await Self.modelActivity(modelID: model.id) {
                    try await Self.provider.restoreResidency(model)
                }
            },
            finish: { await Self.idleUnloader.resumeAfterMeeting() }
        )
    }

    private nonisolated static func modelActivity<T: Sendable>(
        modelID: String? = nil, _ work: () async throws -> T
    ) async throws -> T {
        try await MeetingModelResidencyCoordinator.ordinary(owner: "fluid", modelID: modelID ?? self.configuredModelID) {
            try await Self.idleUnloader.tracking(work)
        }
    }

    func loadedModelState() async -> LoadedModelState? {
        await Self.provider.loadedModelState()
    }

    /// Experimental: gives the model's memory back after a quiet period. The
    /// next dictation reloads it while the user is still speaking.
    nonisolated static let idleUnloader = PrivateAIIdleUnloader(
        delay: { await MainActor.run { SettingsStore.shared.privateAIIdleUnloadDelay } },
        isBusy: { await MainActor.run { AppServices.shared.asr.isRunningOrStarting } },
        unload: { await PrivateAIIntegrationService.shared.unloadCachedRuntime(reason: "idle") },
        activityEnded: { await PrivateAIIntegrationService.postRuntimeDidChange() }
    )

    /// Posted whenever the model may have entered or left memory, so Settings can show
    /// "Active" for exactly as long as the model is loaded.
    nonisolated static let runtimeDidChangeNotification = Notification.Name("PrivateAIRuntimeDidChange")

    nonisolated static func postRuntimeDidChange() async {
        await MainActor.run {
            NotificationCenter.default.post(name: Self.runtimeDidChangeNotification, object: nil)
        }
    }

    func loadModel(_ model: PrivateAIRegisteredModel) async throws -> PrivateAIStatus {
        try await Self.modelActivity(modelID: model.id) {
            let status = try await Self.provider.loadModel(model)
            if status.state == .ready { await self.removeInactiveInstalledModels(keeping: model) }
            return status
        }
    }

    func verifyModel(_ model: PrivateAIRegisteredModel) async throws -> PrivateAIStatus {
        try await Self.modelActivity(modelID: model.id) { try await Self.provider.verifyModel(model) }
    }

    func removeInactiveInstalledModels(keeping model: PrivateAIRegisteredModel) async {
        do {
            try Self.removeInactiveInstalledModels(keeping: model)
        } catch {
            await MainActor.run {
                DebugLogger.shared.warning(
                    "Could not remove inactive Fluid Intelligence backend: \(Self.errorMessage(for: error))",
                    source: "PrivateAIProvider"
                )
            }
        }
    }

    private nonisolated static func errorMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription
        {
            return description
        }
        return String(describing: error)
    }

    func prewarmDictation() async {
        guard !Task.isCancelled else { return }
        _ = try? await Self.modelActivity { await Self.provider.prewarmDictation() }
    }

    func unloadCachedRuntime(reason: String = "manual") async {
        let token: UUID
        do {
            guard let admitted = try await MeetingModelResidencyCoordinator.shared.vetoOrBeginOperation(
                owner: "fluid", modelID: Self.configuredModelID, vetoDuringMeeting: reason != "idle"
            ) else { return }
            token = admitted
        } catch { return }
        await Self.provider.unloadCachedRuntime(reason: reason)
        await MeetingModelResidencyCoordinator.shared.endOperation(token)
        await Self.postRuntimeDidChange()
    }

    func shutdownForTermination() async {
        await MeetingModelResidencyCoordinator.shared.beginTermination()
        await Self.provider.shutdownForTermination()
    }

    nonisolated func enhanceDictation(
        _ inputText: String,
        runtime: RuntimeConfiguration,
        context: AppContext
    ) async throws -> EnhancementResult {
        let budget = try Self.validatedDictationBudget(inputText, contextTokenLimit: runtime.contextTokenLimit)
        return try await Self.modelActivity {
            try await self.dictationProvider.enhanceDictation(
                inputText,
                runtime: runtime,
                context: context,
                maxOutputTokens: budget.maxOutputTokens
            )
        }
    }

    nonisolated func enhanceDictation(
        _ inputText: String,
        runtime: RuntimeConfiguration,
        context: AppContext,
        streamHandler: PrivateAIStreamHandler?
    ) async throws -> EnhancementResult {
        let budget = try Self.validatedDictationBudget(inputText, contextTokenLimit: runtime.contextTokenLimit)
        return try await Self.modelActivity {
            try await self.dictationProvider.enhanceDictation(
                inputText,
                runtime: runtime,
                context: context,
                maxOutputTokens: budget.maxOutputTokens,
                streamHandler: streamHandler
            )
        }
    }

    private nonisolated static func validatedDictationBudget(
        _ inputText: String,
        contextTokenLimit: Int
    ) throws -> SettingsStore.PrivateAIDictationTokenBudget {
        let budget = SettingsStore.privateAIDictationTokenBudget(
            forInputText: inputText,
            contextTokenLimit: contextTokenLimit
        )
        guard budget.hasSufficientHeadroom else {
            throw AIProcessingError.dictationExceedsAIContextWindow
        }
        return budget
    }

    func rewrite(
        _ inputText: String,
        systemPrompt: String,
        runtime: RuntimeConfiguration,
        context: AppContext
    ) async throws -> EnhancementResult {
        try await Self.modelActivity {
            try await Self.provider.rewrite(
                inputText,
                systemPrompt: systemPrompt,
                runtime: runtime,
                context: context
            )
        }
    }
}

private struct PrivateAIModelRemovalError: LocalizedError {
    let message: String

    var errorDescription: String? {
        self.message
    }
}

private struct UnavailableAIIntegrationShim: PrivateAIIntegrationProviding {
    static let shared = UnavailableAIIntegrationShim()

    var configuredModelID: String { PrivateAIModelRegistry.defaultModelID }
    var selectedModel: PrivateAIRegisteredModel { PrivateAIModelRegistry.defaultModel }
    var configuredLocalModelPath: String? { nil }
    var modelDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("FluidVoice", isDirectory: true)
            .appendingPathComponent(PrivateAIProviderFeature.shared.modelDirectoryName, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FluidVoice", isDirectory: true)
            .appendingPathComponent(PrivateAIProviderFeature.shared.modelDirectoryName, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    var isLocalRuntimeConfigured: Bool { false }

    func expectedLocalModelURL(for model: PrivateAIRegisteredModel) -> URL {
        PrivateAIModelRegistry.localModelURL(for: model, directoryURL: self.modelDirectoryURL)
    }

    func localModelPath(for _: PrivateAIRegisteredModel) -> String? { nil }
    func isModelInstalled(_: PrivateAIRegisteredModel) -> Bool { false }

    func prepareModel(
        _: PrivateAIRegisteredModel,
        progressHandler _: PrivateAIModelDownloadProgressHandler?
    ) async throws -> URL {
        throw PrivateAIUnavailableError()
    }

    func shouldHandleDictation(model _: String) -> Bool { false }

    func status(for _: PrivateAIIntegrationService.RuntimeConfiguration) async -> PrivateAIStatus {
        PrivateAIStatus(
            state: .unavailable,
            message: PrivateAIUnavailableError().errorDescription
        )
    }

    func loadedModelState() async -> PrivateAIIntegrationService.LoadedModelState? { nil }

    func loadModel(_: PrivateAIRegisteredModel) async throws -> PrivateAIStatus {
        throw PrivateAIUnavailableError()
    }

    func unloadCachedRuntime(reason _: String) async {}

    nonisolated func enhanceDictation(
        _ inputText: String,
        runtime _: PrivateAIIntegrationService.RuntimeConfiguration,
        context _: PrivateAIIntegrationService.AppContext,
        maxOutputTokens _: Int
    ) async throws -> PrivateAIIntegrationService.EnhancementResult {
        PrivateAIIntegrationService.EnhancementResult(
            outputText: inputText,
            backendKind: nil,
            latencyMilliseconds: nil
        )
    }
}
