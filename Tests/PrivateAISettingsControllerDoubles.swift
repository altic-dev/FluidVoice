import Foundation

// Test-only adapters. Compile the actual controller against these, never against user preferences,
// Keychain, downloads or inference. The normal app build separately checks the real adapters.
struct PrivateAIModelDownloadProgress: Equatable, Sendable {
    init(initialExpectedBytes: Int?) {}
    func withFallbackExpectedBytes(_ bytes: Int?) -> Self { self }
}

struct PrivateAIRegisteredModel: Sendable {
    let id: String
    var canDownload = true
    var artifact: Artifact { Artifact() }
    struct Artifact { var byteCount: Int? = 10 }
}

struct PrivateAIModelUpdateStatus {
    enum State { case current, updateAvailable }
    var state: State
}

struct PrivateAIModelUpdateToken: Sendable { let id = UUID() }
struct PrivateAIStatus { enum State { case ready, failed }; var state: State; var message: String? }
enum PrivateAIModelRegistry {
    static let defaultModel = PrivateAIRegisteredModel(id: "mini")
    static func model(id: String) -> PrivateAIRegisteredModel? {
        self.modelIDs().contains(id) ? PrivateAIRegisteredModel(id: id) : nil
    }

    static func modelIDs() -> [String] { ["mini", "pico"] }
    static func canonicalModelID(for id: String) -> String? { self.model(id: id)?.id }
}

struct PrivateAIProviderFeature { static let shared = Self(); let providerID = "fi" }
enum PrivateAIProviderPromptFormat {
    static func verifiedModelID(settings: SettingsStore) -> String? { "mini" }
}

final class SettingsStore {
    enum PrivateAIBackendPreference { case auto, mlx; var displayName: String { "test" } }
    var privateAIBackendPreference: PrivateAIBackendPreference = .auto
    var privateAIPrefixKVCacheEnabled = false
    var privateAIBoostEnabled = false
    var privateAIContextTokenLimit = 1024
    var selectedModelByProvider = ["external": "external-model"]
    var availableModelsByProvider = ["external": ["external-model"]]
    static func clampPrivateAIContextTokenLimit(_ value: Int) -> Int { max(1, value) }
}

@MainActor
final class UserDefaults {
    static let standard = UserDefaults()
    var writes = 0
    func set(_ value: String, forKey key: String) { self.writes += 1 }
    func removeObject(forKey key: String) { self.writes += 1 }
}

@MainActor
final class AIEnhancementSettingsViewModel {
    enum ConnectionStatus { case success }
    let settings = SettingsStore()
    var selectedProviderID = "external"
    var availableModelsByProvider = ["external": ["external-model"]]
    var selectedModelByProvider = ["external": "external-model"]
    var availableModels = ["external-model"]
    var selectedModel = "external-model"
    var isTestingConnection = false
    var verificationCount = 0
    var resetCount = 0
    var verified = true
    var verificationMessage = "test failure"
    var smartSelectionCount = 0
    var smartSelected = false
    var routesDictationThroughPrivateAI: Bool { self.smartSelected }
    func turnOffPrivateAIDictationSlots() { self.smartSelected = false }
    func selectPrivateAIPromptIfAvailable() {
        guard self.verified else { return }
        self.smartSelectionCount += 1
        self.smartSelected = true
    }

    func providerKey(for id: String) -> String { id }
    func refreshProviderItems() {}
    func connectionErrorMessage(for id: String) -> String { self.verificationMessage }
    func resetVerification(for id: String) { self.resetCount += 1 }
    func updateConnectionStatus(_ status: ConnectionStatus, for id: String) {}
    func verifyPrivateAIProvider(model: PrivateAIRegisteredModel) async -> Bool {
        self.verificationCount += 1
        return self.verified
    }
}

struct DebugLogger {
    static let shared = Self()
    func info(_ message: String, source: String) {}
    func error(_ message: String, source: String) {}
}

@MainActor
final class PrivateAIIntegrationService {
    struct LoadedModelState { var state: PrivateAIStatus.State; var modelID: String }
    static let shared = PrivateAIIntegrationService()
    static let runtimeDidChangeNotification = Notification.Name("TestPrivateAIRuntimeDidChange")
    static var configuredModelID = "mini"
    static let selectedModelDefaultsKey = "test-selection"
    static let localModelPathDefaultsKey = "test-path"
    static let modelDirectoryURL = URL(fileURLWithPath: "/tmp/test-not-used")
    static var installed = false
    static var downloads = 0
    static var loads = 0
    static var commits = 0
    static var rollbacks = 0
    static var removals = 0
    static var failDownload = false
    static var lastProgress: (@Sendable (PrivateAIModelDownloadProgress) async -> Void)?
    static var readContinuation: CheckedContinuation<LoadedModelState?, Never>?
    static var suspendRead = false
    static var loadContinuation: CheckedContinuation<PrivateAIStatus, Never>?
    static var suspendLoad = false
    static func isModelInstalled(_ model: PrivateAIRegisteredModel) -> Bool { self.installed }
    static func canRemoveInstalledModel(_ model: PrivateAIRegisteredModel) -> Bool { self.installed }
    static func modelUpdateStatus(_ model: PrivateAIRegisteredModel) async -> PrivateAIModelUpdateStatus { .init(state: .current) }
    static func prepareModel(
        _ model: PrivateAIRegisteredModel,
        progressHandler: (@Sendable (PrivateAIModelDownloadProgress) async -> Void)? = nil
    ) async throws -> URL {
        self.downloads += 1
        self.lastProgress = progressHandler
        if self.failDownload { throw PrivateAISettingsBoundaryTests.Failure.expected }
        await progressHandler?(.init(initialExpectedBytes: 10))
        return self.modelDirectoryURL
    }

    static func updateModel(
        _ model: PrivateAIRegisteredModel,
        progressHandler: (@Sendable (PrivateAIModelDownloadProgress) async -> Void)? = nil
    ) async throws -> PrivateAIModelUpdateToken {
        _ = try await self.prepareModel(model, progressHandler: progressHandler)
        return .init()
    }

    static func commitModelUpdate(_ token: PrivateAIModelUpdateToken) async { self.commits += 1 }
    static func rollbackModelUpdate(_ token: PrivateAIModelUpdateToken) async { self.rollbacks += 1 }
    func loadedModelState() async -> LoadedModelState? {
        if Self.suspendRead { return await withCheckedContinuation { Self.readContinuation = $0 } }
        return nil
    }

    func loadModel(_ model: PrivateAIRegisteredModel) async throws -> PrivateAIStatus {
        Self.loads += 1
        if Self.suspendLoad { return await withCheckedContinuation { Self.loadContinuation = $0 } }
        return .init(state: .ready)
    }

    func unloadCachedRuntime(reason: String) async {}
    func unloadAndRemoveInstalledModel(_ model: PrivateAIRegisteredModel, reason: String) async throws { Self.removals += 1 }
}

@MainActor
enum PrivateAIControllerChecks {
    static func eventually(_ predicate: () -> Bool) async {
        for _ in 0..<10_000 {
            if predicate() { return }
            await Task.yield()
        }
        preconditionFailure("Controlled task did not reach expected state")
    }

    static func run(check: (Bool, String) -> Void) async {
        let vm = AIEnhancementSettingsViewModel()
        let controller = PrivateAISettingsController(viewModel: vm)
        for _ in 0..<50 {
            controller.previewModel("pico"); controller.previewModel("mini")
        }
        controller.previewModel("pico")
        controller.previewModel("invalid")
        check(controller.previewModelID == "pico" && controller.privateAISelectedModelID == "mini", "Controller preview remains separate and rejects invalid IDs")
        check(UserDefaults.standard.writes == 0 && vm.resetCount == 0, "Preview makes no persistence/verification writes")
        check(PrivateAIIntegrationService.loads == 0 && PrivateAIIntegrationService.downloads == 0, "Preview does not load/download")
        controller.activatePreviewModel()
        check(controller.privateAISelectedModelID == "pico" && UserDefaults.standard.writes == 2, "Explicit activation persists through existing path")
        check(vm.selectedProviderID == "external" && vm.selectedModel == "external-model", "FI selection must not change external editor/global provider")
        check(vm.settings.selectedModelByProvider["external"] == "external-model", "FI selection preserves external saved model")

        let writesBeforeCardRead = UserDefaults.standard.writes
        controller.refreshPrivateAIModelUpdateStatus(PrivateAIRegisteredModel(id: "mini"))
        await self.eventually { controller.privateAIModelUpdateStatusByID["mini"] != nil }
        check(controller.privateAIModelUpdateStatusByID["mini"]?.state == .current, "Inactive card receives its own update status")
        check(controller.privateAISelectedModelID == "pico" && UserDefaults.standard.writes == writesBeforeCardRead, "Card update read never selects or persists another model")
        let verificationBeforeInactiveAction = vm.verificationCount
        controller.verifyPrivateAIConnection(PrivateAIRegisteredModel(id: "mini"))
        check(!controller.isBusy && vm.verificationCount == verificationBeforeInactiveAction, "Inactive maintenance cannot run against the selected runtime")

        PrivateAIIntegrationService.failDownload = true
        let pico = PrivateAIRegisteredModel(id: "pico")
        controller.downloadPrivateAIModel(pico)
        controller.downloadPrivateAIModel(pico)
        controller.persistPrivateAIModelSelection("mini")
        check(controller.isBusy && controller.privateAISelectedModelID == "pico", "Busy controller rejects duplicate action/model switching")
        await self.eventually { !controller.isBusy }
        check(PrivateAIIntegrationService.downloads == 1 && vm.verificationCount == 0, "Failed download never verifies and only starts once")
        check(controller.privateAILoadState.failureMessage(for: "pico") != nil, "Failure is visible and releases busy state")
        PrivateAIIntegrationService.failDownload = false
        controller.downloadPrivateAIModel(pico)
        await self.eventually { !controller.isBusy }
        check(controller.privateAILoadState.isLoaded("pico") && vm.verificationCount == 1, "Download retry verifies and completes")
        await PrivateAIIntegrationService.lastProgress?(.init(initialExpectedBytes: 10))
        check(controller.privateAILoadState.isLoaded("pico"), "Late progress from finished download cannot replace ready state")

        controller.privateAIModelUpdateStatusByID["pico"] = .init(state: .updateAvailable)
        vm.verified = false
        controller.updatePrivateAIModel(pico)
        await self.eventually { !controller.isBusy }
        check(PrivateAIIntegrationService.rollbacks == 1 && PrivateAIIntegrationService.commits == 0, "Real controller update path rolls back failed verification")
        check(controller.privateAILoadState.failureMessage(for: "pico") != nil, "Update verification failure remains visible")
        check(
            controller.privateAILoadState.failureMessage(for: "pico")?.contains("test failure") == true,
            "Update error includes provider-specific detail, not literal interpolation"
        )

        let writesBeforeNoop = UserDefaults.standard.writes
        let previewBeforeUpcoming = controller.previewModelID
        let selectionBeforeUpcoming = controller.privateAISelectedModelID
        for upcoming in PrivateAIUpcomingModel.allCases {
            controller.previewModel(upcoming.id)
            controller.persistPrivateAIModelSelection(upcoming.id)
            check(PrivateAIModelRegistry.model(id: upcoming.id) == nil, "Coming-soon previews are not runtime models")
        }
        check(
            controller.previewModelID == previewBeforeUpcoming && controller.privateAISelectedModelID == selectionBeforeUpcoming,
            "Coming-soon identifiers cannot alter runtime selection"
        )
        check(UserDefaults.standard.writes == writesBeforeNoop, "Coming-soon identifiers never persist")
        controller.persistPrivateAIModelSelection("invalid")
        controller.persistPrivateAIModelSelection("pico")
        check(UserDefaults.standard.writes == writesBeforeNoop, "Invalid/redundant selection must not persist or reset verification")
        controller.downloadPrivateAIModel(.init(id: "pico", canDownload: false))
        check(!controller.isBusy, "Missing download configuration releases operation slot")
        controller.deletePrivateAIModel(pico)
        check(!controller.isBusy, "Non-removable model deletion releases operation slot")
        PrivateAIIntegrationService.installed = true
        controller.deletePrivateAIModel(.init(id: "mini"))
        check(!controller.isBusy && PrivateAIIntegrationService.removals == 0, "Stale deletion confirmation cannot delete another selection")
        let writesBeforeDeletion = UserDefaults.standard.writes
        controller.deletePrivateAIModel(pico)
        controller.deletePrivateAIModel(pico)
        await self.eventually { !controller.isBusy }
        check(PrivateAIIntegrationService.removals == 1 && controller.privateAILoadState == .idle, "Confirmed deletion runs once and returns to idle")
        check(UserDefaults.standard.writes == writesBeforeDeletion && vm.selectedProviderID == "external", "Deletion does not change model selection or shortcut provider")
        PrivateAIIntegrationService.installed = false

        PrivateAIIntegrationService.suspendRead = true
        controller.privateAILoadState = .idle
        controller.refreshPrivateAILoadState()
        await self.eventually { PrivateAIIntegrationService.readContinuation != nil }
        PrivateAIIntegrationService.installed = true
        PrivateAIIntegrationService.suspendLoad = true
        controller.loadPrivateAIModel(pico)
        await self.eventually { PrivateAIIntegrationService.loadContinuation != nil }
        PrivateAIIntegrationService.readContinuation?.resume(returning: nil)
        PrivateAIIntegrationService.readContinuation = nil
        for _ in 0..<20 {
            await Task.yield()
        }
        check(controller.privateAILoadState.isLoading("pico") && controller.isBusy, "Late idle read cannot erase a newer load")
        controller.previewModel("mini")
        controller.activatePreviewModel()
        check(controller.privateAISelectedModelID == "pico" && controller.previewModelID == "mini", "Pending load permits preview but not activation")
        PrivateAIIntegrationService.loadContinuation?.resume(returning: .init(state: .ready))
        PrivateAIIntegrationService.loadContinuation = nil
        await self.eventually { !controller.isBusy }
        check(controller.privateAILoadState.isLoaded("pico"), "Load completion stays attached to activated model, not preview")
        var activations = 0
        vm.verified = false
        controller.usePreviewModel(isInstalled: true) { activations += 1 }
        controller.usePreviewModel(isInstalled: true) { activations += 1 }
        await self.eventually { !controller.isBusy }
        check(activations == 0 && vm.smartSelectionCount == 0, "Failed activation must not switch shortcut routing")
        controller.refreshPrivateAILoadState()
        for _ in 0..<20 {
            await Task.yield()
        }
        check(controller.privateAILoadState.failureMessage(for: "mini") != nil, "Passive runtime refresh preserves failed activation")
        vm.verified = true
        controller.usePreviewModel(isInstalled: true) { activations += 1 }
        await self.eventually { !controller.isBusy }
        check(activations == 1 && controller.privateAILoadState.isLoaded("mini"), "Explicit activation calls routing once after successful verification")
        check(vm.smartSelected && vm.smartSelectionCount == 1, "Successful explicit activation selects Smart once")
        check(vm.selectedProviderID == "external" && vm.selectedModel == "external-model", "Activation preserves external editor configuration")
        vm.smartSelected = false // User manually chooses Basic after activation.
        controller.synchronizeSelection()
        check(!vm.smartSelected, "Reopening settings preserves manually selected Basic")
        var completionCount = 0
        var reportedError: String?
        let writesBeforeVerification = UserDefaults.standard.writes
        controller.verifyPrivateAIConnection(.init(id: "mini"), onCompletion: { error in
            completionCount += 1
            reportedError = error
        })
        controller.verifyPrivateAIConnection(.init(id: "mini"), onCompletion: { _ in completionCount += 100 })
        await self.eventually { !controller.isBusy }
        check(completionCount == 1 && reportedError == nil, "Manual verification reports success once; duplicate clicks do not report")
        check(!vm.smartSelected && vm.smartSelectionCount == 1, "Verification preserves manually selected Basic")
        vm.verified = false
        controller.verifyPrivateAIConnection(.init(id: "mini"), onCompletion: { error in
            completionCount += 1
            reportedError = error
        })
        await self.eventually { !controller.isBusy }
        check(completionCount == 2 && reportedError?.contains("test failure") == true, "Manual verification reports the actual failure")
        controller.verifyPrivateAIConnection(.init(id: "pico"), onCompletion: { _ in completionCount += 100 })
        check(completionCount == 2 && UserDefaults.standard.writes == writesBeforeVerification, "Inactive verification has no result or persistence side effects")
        vm.verified = true
        controller.usePreviewModel(isInstalled: true) {}
        await self.eventually { !controller.isBusy }
        check(vm.smartSelected && vm.smartSelectionCount == 2, "Another explicit activation switches Basic back to Smart")
        vm.verified = false
        vm.verificationMessage = "Missing local model: model.safetensors."
        let resetsBeforeMissing = vm.resetCount
        let downloadsBeforeMissing = PrivateAIIntegrationService.downloads
        let removalsBeforeMissing = PrivateAIIntegrationService.removals
        controller.verifyPrivateAIConnection(.init(id: "mini"), onCompletion: { reportedError = $0 })
        await self.eventually { !controller.isBusy }
        check(controller.privateAILoadState.needsDownload("mini"), "Missing weights becomes a recoverable download state")
        check(!controller.privateAILoadState.needsDownload("pico"), "Recovery belongs only to the affected model")
        check(controller.privateAILoadState.failureMessage(for: "mini") == nil, "Missing files do not display a raw failure")
        check(reportedError == "Model files are missing. Download again to repair.", "Explicit verification explains recovery")
        check(vm.resetCount == resetsBeforeMissing + 1, "Missing files clear stale verification")
        check(PrivateAIIntegrationService.downloads == downloadsBeforeMissing, "Recovery never silently starts a download")
        check(PrivateAIIntegrationService.removals == removalsBeforeMissing, "Recovery never deletes model files")
        vm.verificationMessage = PrivateAIModelLoadState.missingModelMessage
        controller.verifyPrivateAIConnection(.init(id: "mini"), onCompletion: { reportedError = $0 })
        await self.eventually { !controller.isBusy }
        check(controller.privateAILoadState.needsDownload("mini"), "Missing installation during Verify uses the same recovery as Load")
        check(reportedError == "Model files are missing. Download again to repair.", "Missing installation explains recovery")
        check(vm.resetCount == resetsBeforeMissing + 2, "Missing installation clears stale verification")
        check(
            PrivateAIIntegrationService.downloads == downloadsBeforeMissing && PrivateAIIntegrationService.removals == removalsBeforeMissing,
            "Verification recovery does not download or remove files"
        )
        controller.refreshPrivateAILoadState()
        check(controller.privateAILoadState.needsDownload("mini"), "Passive refresh retains recovery state")
        vm.verified = true
        controller.usePreviewModel(isInstalled: false) {}
        await self.eventually { !controller.isBusy }
        check(controller.privateAILoadState.isLoaded("mini"), "Explicit repair verifies and clears recovery state")
        check(PrivateAIIntegrationService.downloads == downloadsBeforeMissing + 1, "Repair uses the existing download path once")
        for message in ["Network connection lost", "Not enough disk space", "Model checksum mismatch", "Failed to load local model: model.safetensors."] {
            check(
                PrivateAIModelLoadState.failure(modelID: "mini", message: message).failureMessage(for: "mini") == message,
                "Non-missing failures retain their actual diagnostic"
            )
        }
    }
}
