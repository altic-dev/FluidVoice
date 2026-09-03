import Foundation

typealias PrivateAIStreamHandler = @Sendable (String) -> Void

struct PrivateAIModelArtifact: Sendable, Codable, Hashable {
    var identifier: String
    var filename: String
    var downloadURL: URL?
    var sha256: String?
    var byteCount: Int64?
    var version: String?
}

struct PrivateAIModelDownloadProgress: Sendable, Equatable {
    var bytesWritten: Int64
    var totalBytesWritten: Int64
    var totalBytesExpected: Int64?

    init(bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpected: Int64?) {
        self.bytesWritten = bytesWritten
        self.totalBytesWritten = totalBytesWritten
        self.totalBytesExpected = totalBytesExpected
    }

    init(initialExpectedBytes: Int64?) {
        self.init(
            bytesWritten: 0,
            totalBytesWritten: 0,
            totalBytesExpected: initialExpectedBytes.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    var hasWrittenBytes: Bool {
        self.totalBytesWritten > 0
    }

    var fractionCompleted: Double? {
        guard self.hasWrittenBytes else { return nil }
        guard let totalBytesExpected, totalBytesExpected > 0 else { return nil }
        return min(1, max(0, Double(self.totalBytesWritten) / Double(totalBytesExpected)))
    }

    /// All expected bytes have been written. The download itself is done; the
    /// provider is now validating (SHA-256) and moving the file into place.
    var isComplete: Bool {
        guard let totalBytesExpected, totalBytesExpected > 0 else { return false }
        return self.totalBytesWritten >= totalBytesExpected
    }

    func withFallbackExpectedBytes(_ byteCount: Int64?) -> PrivateAIModelDownloadProgress {
        guard self.totalBytesExpected == nil,
              let byteCount,
              byteCount > 0
        else {
            return self
        }

        return PrivateAIModelDownloadProgress(
            bytesWritten: self.bytesWritten,
            totalBytesWritten: self.totalBytesWritten,
            totalBytesExpected: byteCount
        )
    }
}

enum PrivateAIModelDownloadProgressText {
    static func buttonTitle(for progress: PrivateAIModelDownloadProgress?) -> String {
        if progress?.isComplete == true { return "Verifying" }
        guard let fraction = progress?.fractionCompleted else { return "Downloading" }
        return "Downloading \(Int(fraction * 100))%"
    }

    static func statusText(for progress: PrivateAIModelDownloadProgress?) -> String {
        guard let progress else {
            return "Starting download. This can take a few minutes."
        }
        if progress.isComplete {
            return "Verifying download. This can take a moment."
        }
        guard progress.hasWrittenBytes else {
            return "Downloading. This can take a few minutes."
        }
        guard let fraction = progress.fractionCompleted else {
            return "Downloading. This can take a few minutes."
        }
        return "Downloading \(Int(fraction * 100))%. This can take a few minutes."
    }

    static func byteText(for progress: PrivateAIModelDownloadProgress?) -> String? {
        guard let progress else { return nil }

        if progress.isComplete {
            return "\(Self.byteCountText(progress.totalBytesWritten)) downloaded"
        }

        guard progress.hasWrittenBytes else {
            guard let expected = progress.totalBytesExpected, expected > 0 else { return nil }
            return "\(Self.byteCountText(expected)) download"
        }

        let written = Self.byteCountText(progress.totalBytesWritten)
        guard let expected = progress.totalBytesExpected, expected > 0 else {
            return "\(written) downloaded"
        }

        return "\(written) of \(Self.byteCountText(expected))"
    }

    static func detailText(for progress: PrivateAIModelDownloadProgress?) -> String {
        guard let progress else { return "Starting download..." }
        if progress.isComplete {
            return "Verifying download..."
        }
        guard let byteText = Self.byteText(for: progress) else { return "Downloading..." }
        guard progress.hasWrittenBytes else { return byteText }
        guard let fraction = progress.fractionCompleted else { return byteText }
        return "\(byteText) (\(Int(fraction * 100))%)"
    }

    private static func byteCountText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

typealias PrivateAIModelDownloadProgressHandler = @Sendable (PrivateAIModelDownloadProgress) async -> Void

enum PrivateAIModelUpdateState: String, Sendable, Codable, Equatable {
    case unavailable
    case notInstalled
    case current
    case updateAvailable
}

struct PrivateAIModelUpdateStatus: Sendable, Codable, Equatable {
    var state: PrivateAIModelUpdateState
    var installedVersion: String?
    var availableVersion: String?
}

struct PrivateAIModelUpdateToken: Sendable, Hashable {
    let id: UUID
}

struct PrivateAIRegisteredModel: Sendable, Codable, Hashable, Identifiable {
    var id: String { self.artifact.identifier }
    var displayName: String
    var detail: String
    var isEnabled: Bool
    var parameterCount: String
    var recommendedMemoryGB: Int?
    var artifact: PrivateAIModelArtifact

    var canDownload: Bool {
        self.artifact.downloadURL != nil && self.artifact.sha256?.isEmpty == false
    }
}

enum PrivateAIModelTask: String, Sendable, Codable, Hashable {
    case dictation
    case edit
    case command
}

enum PrivateAIRuntimeState: String, Sendable, Codable, Hashable {
    case unavailable
    case missingModel
    case configured
    case loading
    case ready
    case failed
}

struct PrivateAIStatus: Sendable, Codable, Equatable {
    var state: PrivateAIRuntimeState
    var message: String?
}

struct PrivateAIUnavailableError: LocalizedError {
    var errorDescription: String? {
        "Private AI provider is not available in this build."
    }
}

protocol PrivateAIProviderFeatureProviding: Sendable {
    var isAvailable: Bool { get }
    var providerID: String { get }
    var providerName: String { get }
    var promptSelectionID: String { get }
    var defaultModelID: String { get }
    var selectedModelDefaultsKey: String { get }
    var localModelPathDefaultsKey: String { get }
    var prefixCacheDefaultsKey: String { get }
    var boostDefaultsKey: String { get }
    var modelDirectoryName: String { get }

    func selectedModelDefaultsKey(for task: PrivateAIModelTask) -> String
    func modelIDs() -> [String]
    func modelIDs(for task: PrivateAIModelTask) -> [String]
    func model(id: String) -> PrivateAIRegisteredModel?
    func canonicalModelID(for value: String) -> String?
    func isKnownModelID(_ value: String) -> Bool
    func matches(model: String) -> Bool
    func localModelURL(for model: PrivateAIRegisteredModel, directoryURL: URL) -> URL
}

extension PrivateAIProviderFeatureProviding {
    func selectedModelDefaultsKey(for _: PrivateAIModelTask) -> String {
        self.selectedModelDefaultsKey
    }

    func modelIDs(for task: PrivateAIModelTask) -> [String] {
        task == .dictation ? self.modelIDs() : []
    }

    func matches(model: String) -> Bool {
        guard self.isAvailable else { return false }

        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if self.isKnownModelID(normalized) {
            return true
        }

        let normalizedProviderID = self.providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalizedProviderID.isEmpty && normalized == normalizedProviderID
    }

    func localModelURL(for model: PrivateAIRegisteredModel, directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(model.artifact.filename)
    }
}

protocol PrivateAIIntegrationProviding: Sendable {
    var configuredModelID: String { get }
    var selectedModel: PrivateAIRegisteredModel { get }
    var configuredLocalModelPath: String? { get }
    var modelDirectoryURL: URL { get }
    var isLocalRuntimeConfigured: Bool { get }

    func expectedLocalModelURL(for model: PrivateAIRegisteredModel) -> URL
    func localModelPath(for model: PrivateAIRegisteredModel) -> String?
    func isModelInstalled(_ model: PrivateAIRegisteredModel) -> Bool
    func installedModelURLs(for model: PrivateAIRegisteredModel) -> [URL]
    func inactiveInstalledModelURLs(keeping model: PrivateAIRegisteredModel) -> [URL]
    func prepareModel(
        _ model: PrivateAIRegisteredModel,
        progressHandler: PrivateAIModelDownloadProgressHandler?
    ) async throws -> URL
    func modelUpdateStatus(_ model: PrivateAIRegisteredModel) async -> PrivateAIModelUpdateStatus
    func updateModel(
        _ model: PrivateAIRegisteredModel,
        progressHandler: PrivateAIModelDownloadProgressHandler?
    ) async throws -> PrivateAIModelUpdateToken
    func commitModelUpdate(_ token: PrivateAIModelUpdateToken) async
    func rollbackModelUpdate(_ token: PrivateAIModelUpdateToken) async
    func shouldHandleDictation(model: String) -> Bool
    func status(for runtime: PrivateAIIntegrationService.RuntimeConfiguration) async -> PrivateAIStatus
    func loadedModelState() async -> PrivateAIIntegrationService.LoadedModelState?
    func loadModel(_ model: PrivateAIRegisteredModel) async throws -> PrivateAIStatus
    func verifyModel(_ model: PrivateAIRegisteredModel) async throws -> PrivateAIStatus
    func prewarmDictation() async
    func unloadCachedRuntime(reason: String) async
    func shutdownForTermination() async
    func enhanceDictation(
        _ inputText: String,
        runtime: PrivateAIIntegrationService.RuntimeConfiguration,
        context: PrivateAIIntegrationService.AppContext
    ) async throws -> PrivateAIIntegrationService.EnhancementResult
    func enhanceDictation(
        _ inputText: String,
        runtime: PrivateAIIntegrationService.RuntimeConfiguration,
        context: PrivateAIIntegrationService.AppContext,
        streamHandler: PrivateAIStreamHandler?
    ) async throws -> PrivateAIIntegrationService.EnhancementResult
    func rewrite(
        _ inputText: String,
        systemPrompt: String,
        runtime: PrivateAIIntegrationService.RuntimeConfiguration,
        context: PrivateAIIntegrationService.AppContext
    ) async throws -> PrivateAIIntegrationService.EnhancementResult
}

extension PrivateAIIntegrationProviding {
    func verifyModel(_ model: PrivateAIRegisteredModel) async throws -> PrivateAIStatus {
        try await self.loadModel(model)
    }

    func installedModelURLs(for model: PrivateAIRegisteredModel) -> [URL] {
        guard let path = self.localModelPath(for: model) else { return [] }
        return [URL(fileURLWithPath: path)]
    }

    func inactiveInstalledModelURLs(keeping _: PrivateAIRegisteredModel) -> [URL] { [] }

    func prepareModel(_ model: PrivateAIRegisteredModel) async throws -> URL {
        try await self.prepareModel(model, progressHandler: nil)
    }

    func modelUpdateStatus(_: PrivateAIRegisteredModel) async -> PrivateAIModelUpdateStatus {
        PrivateAIModelUpdateStatus(state: .unavailable)
    }

    func updateModel(
        _: PrivateAIRegisteredModel,
        progressHandler _: PrivateAIModelDownloadProgressHandler?
    ) async throws -> PrivateAIModelUpdateToken {
        throw PrivateAIUnavailableError()
    }

    func commitModelUpdate(_: PrivateAIModelUpdateToken) async {}
    func rollbackModelUpdate(_: PrivateAIModelUpdateToken) async {}

    /// Best-effort, no-op by default. Backends that support prefix priming
    /// (the local FluidIntelligence bridge) override this to load and prime the
    /// dictation runtime ahead of the first request.
    func prewarmDictation() async {}

    func shutdownForTermination() async {
        await self.unloadCachedRuntime(reason: "termination")
    }

    func enhanceDictation(
        _ inputText: String,
        runtime: PrivateAIIntegrationService.RuntimeConfiguration,
        context: PrivateAIIntegrationService.AppContext,
        streamHandler _: PrivateAIStreamHandler?
    ) async throws -> PrivateAIIntegrationService.EnhancementResult {
        try await self.enhanceDictation(inputText, runtime: runtime, context: context)
    }

    func rewrite(
        _: String,
        systemPrompt _: String,
        runtime _: PrivateAIIntegrationService.RuntimeConfiguration,
        context _: PrivateAIIntegrationService.AppContext
    ) async throws -> PrivateAIIntegrationService.EnhancementResult {
        throw PrivateAIUnavailableError()
    }
}

enum PrivateAIProviderRegistry {
    nonisolated(unsafe) static var feature: any PrivateAIProviderFeatureProviding = UnavailablePrivateAIProviderFeature()
    nonisolated(unsafe) static var integration: any PrivateAIIntegrationProviding = UnavailablePrivateAIIntegrationProvider()
}

private enum PrivateAIProviderBootstrap {
    static let installOnce: Void = {
        #if PRIVATE_AI_PROVIDER
        PrivateAIProviderBridge.install()
        #endif
    }()

    static func installIfAvailable() {
        _ = self.installOnce
    }
}

enum PrivateAIProviderFeature {
    nonisolated static var shared: any PrivateAIProviderFeatureProviding {
        PrivateAIProviderBootstrap.installIfAvailable()
        return PrivateAIProviderRegistry.feature
    }

    nonisolated static var displayName: String {
        let name = self.shared.providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Private AI Provider" : name
    }

    nonisolated static func verificationFingerprint(for modelID: String) -> String {
        let backendPreference = UserDefaults.standard.string(forKey: SettingsStore.privateAIBackendPreferenceDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedBackendPreference: String
        if let backendPreference,
           !backendPreference.isEmpty,
           let preference = SettingsStore.PrivateAIBackendPreference(rawValue: backendPreference)
        {
            normalizedBackendPreference = preference == .auto
                ? SettingsStore.PrivateAIBackendPreference.systemDefault.rawValue
                : preference.rawValue
        } else {
            // Keep fingerprint in sync with SettingsStore.privateAIBackendPreference default.
            normalizedBackendPreference = SettingsStore.PrivateAIBackendPreference.systemDefault.rawValue
        }
        return "private-ai-provider|\(modelID)|backend:\(normalizedBackendPreference)"
    }
}

enum PrivateFeatures {
    static var privateAIProvider: Bool {
        PrivateAIProviderFeature.shared.isAvailable
    }
}

enum PrivateAIModelRegistry {
    nonisolated static var defaultModelID: String {
        PrivateAIProviderFeature.shared.defaultModelID
    }

    nonisolated static var defaultModel: PrivateAIRegisteredModel {
        if let model = model(id: defaultModelID) {
            return model
        }
        return PrivateAIRegisteredModel.unavailable
    }

    nonisolated static func model(id: String) -> PrivateAIRegisteredModel? {
        PrivateAIProviderFeature.shared.model(id: id)
    }

    nonisolated static func canonicalModelID(for value: String) -> String? {
        PrivateAIProviderFeature.shared.canonicalModelID(for: value)
    }

    nonisolated static func modelIDs(includeDisabled _: Bool = false) -> [String] {
        PrivateAIProviderFeature.shared.modelIDs()
    }

    nonisolated static func modelIDs(for task: PrivateAIModelTask) -> [String] {
        PrivateAIProviderFeature.shared.modelIDs(for: task)
    }

    nonisolated static func localModelURL(for model: PrivateAIRegisteredModel, directoryURL: URL) -> URL {
        PrivateAIProviderFeature.shared.localModelURL(for: model, directoryURL: directoryURL)
    }
}

extension PrivateAIRegisteredModel {
    static let unavailable = PrivateAIRegisteredModel(
        displayName: "",
        detail: "",
        isEnabled: false,
        parameterCount: "",
        recommendedMemoryGB: nil,
        artifact: PrivateAIModelArtifact(
            identifier: "",
            filename: "",
            downloadURL: nil,
            sha256: nil,
            byteCount: nil,
            version: nil
        )
    )
}

private struct UnavailablePrivateAIProviderFeature: PrivateAIProviderFeatureProviding {
    let isAvailable = false
    let providerID = "__private_ai_provider__"
    let providerName = ""
    let promptSelectionID = "__PRIVATE_AI_PROVIDER__"
    let defaultModelID = ""
    let selectedModelDefaultsKey = "PrivateAIProviderSelectedModelID"
    let localModelPathDefaultsKey = "PrivateAIProviderLocalModelPath"
    let prefixCacheDefaultsKey = "PrivateAIProviderPrefixKVCacheEnabled"
    let boostDefaultsKey = "PrivateAIProviderBoostEnabled"
    let modelDirectoryName = "PrivateAIProvider"

    func modelIDs() -> [String] { [] }
    func model(id _: String) -> PrivateAIRegisteredModel? { nil }
    func canonicalModelID(for _: String) -> String? { nil }
    func isKnownModelID(_: String) -> Bool { false }
}

private struct UnavailablePrivateAIIntegrationProvider: PrivateAIIntegrationProviding {
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
