import Foundation

actor PrivateAIIntegrationService {
    static let shared = PrivateAIIntegrationService()

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
    }

    struct LoadedModelState: Sendable, Equatable {
        let modelID: String
        let state: PrivateAIRuntimeState
        let message: String?
    }

    private init() {}

    private nonisolated static var provider: any PrivateAIIntegrationProviding {
        PrivateAIProviderFeature.shared.isAvailable
            ? PrivateAIProviderRegistry.integration
            : UnavailableAIIntegrationShim.shared
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

    nonisolated static func isModelInstalled(_ model: PrivateAIRegisteredModel) -> Bool {
        self.provider.isModelInstalled(model)
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
        let requestedURLs = self.provider.installedModelURLs(for: model)
        guard !requestedURLs.isEmpty else { return }
        let targetURLs = try self.validatedModelURLs(requestedURLs)
        try self.removeModelFiles(at: targetURLs)
    }

    nonisolated static func removeInactiveInstalledModels(keeping model: PrivateAIRegisteredModel) throws {
        let requestedURLs = self.provider.inactiveInstalledModelURLs(keeping: model)
        guard !requestedURLs.isEmpty else { return }
        let targetURLs = try self.validatedModelURLs(requestedURLs)
        try self.removeModelFiles(at: targetURLs)
    }

    private nonisolated static func validatedModelURLs(_ urls: [URL]) throws -> [URL] {
        guard !urls.isEmpty else { return [] }
        let modelDirectoryURL = self.modelDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let modelDirectoryPath = modelDirectoryURL.path
        let targetURLs = Array(Set(urls.map { $0.resolvingSymlinksInPath().standardizedFileURL }))
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
        await self.unloadCachedRuntime(reason: reason)
        try Self.removeInstalledModel(model)
    }

    nonisolated static func prepareModel(
        _ model: PrivateAIRegisteredModel,
        progressHandler: PrivateAIModelDownloadProgressHandler? = nil
    ) async throws -> URL {
        try await self.provider.prepareModel(model, progressHandler: progressHandler)
    }

    nonisolated static var isLocalRuntimeConfigured: Bool {
        provider.isLocalRuntimeConfigured
    }

    nonisolated static func shouldHandleDictation(model: String) -> Bool {
        self.provider.shouldHandleDictation(model: model)
    }

    func status(for runtime: RuntimeConfiguration) async -> PrivateAIStatus {
        await Self.provider.status(for: runtime)
    }

    func loadedModelState() async -> LoadedModelState? {
        await Self.provider.loadedModelState()
    }

    func loadModel(_ model: PrivateAIRegisteredModel) async throws -> PrivateAIStatus {
        let status = try await Self.provider.loadModel(model)
        guard status.state == .ready else { return status }

        await self.removeInactiveInstalledModels(keeping: model)
        return status
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
        await Self.provider.prewarmDictation()
    }

    func unloadCachedRuntime(reason: String = "manual") async {
        await Self.provider.unloadCachedRuntime(reason: reason)
    }

    func shutdownForTermination() async {
        await Self.provider.shutdownForTermination()
    }

    func enhanceDictation(
        _ inputText: String,
        runtime: RuntimeConfiguration,
        context: AppContext
    ) async throws -> EnhancementResult {
        try Self.validateDictationHeadroom(inputText, contextTokenLimit: runtime.contextTokenLimit)
        return try await Self.provider.enhanceDictation(inputText, runtime: runtime, context: context)
    }

    func enhanceDictation(
        _ inputText: String,
        runtime: RuntimeConfiguration,
        context: AppContext,
        streamHandler: PrivateAIStreamHandler?
    ) async throws -> EnhancementResult {
        try Self.validateDictationHeadroom(inputText, contextTokenLimit: runtime.contextTokenLimit)
        return try await Self.provider.enhanceDictation(
            inputText,
            runtime: runtime,
            context: context,
            streamHandler: streamHandler
        )
    }

    private nonisolated static func validateDictationHeadroom(_ inputText: String, contextTokenLimit: Int) throws {
        let budget = SettingsStore.privateAIDictationTokenBudget(
            forInputText: inputText,
            contextTokenLimit: contextTokenLimit
        )
        guard budget.hasSufficientHeadroom else {
            throw AIProcessingError.dictationExceedsAIContextWindow
        }
    }

    func rewrite(
        _ inputText: String,
        systemPrompt: String,
        runtime: RuntimeConfiguration,
        context: AppContext
    ) async throws -> EnhancementResult {
        try await Self.provider.rewrite(
            inputText,
            systemPrompt: systemPrompt,
            runtime: runtime,
            context: context
        )
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

    func enhanceDictation(
        _ inputText: String,
        runtime _: PrivateAIIntegrationService.RuntimeConfiguration,
        context _: PrivateAIIntegrationService.AppContext
    ) async throws -> PrivateAIIntegrationService.EnhancementResult {
        PrivateAIIntegrationService.EnhancementResult(
            outputText: inputText,
            backendKind: nil,
            latencyMilliseconds: nil
        )
    }
}
