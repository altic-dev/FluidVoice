import Combine
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class PrivateAIProviderPromptFormatTests: XCTestCase {
    func testProviderTaskDefaultKeepsDictationAndHidesOtherModes() {
        let provider = TaskDefaultPrivateAIProvider()

        XCTAssertEqual(provider.modelIDs(for: .dictation), ["dictation-model"])
        XCTAssertEqual(provider.modelIDs(for: .edit), [])
        XCTAssertEqual(provider.modelIDs(for: .command), [])
    }

    func testTaskFilteringDoesNotChangeRemoteProviderDefaults() {
        let repository = ModelRepository.shared

        XCTAssertEqual(
            repository.defaultModels(for: "openai", task: .edit),
            repository.defaultModels(for: "openai")
        )
        XCTAssertEqual(
            repository.defaultModels(for: "anthropic", task: .command),
            repository.defaultModels(for: "anthropic")
        )
    }

    func testEligibleTaskModelPreservesAValidNonFirstSelection() {
        let models = ["edit-model-a", "edit-model-b"]

        XCTAssertEqual(
            ModelRepository.eligibleModel(preferred: "edit-model-b", from: models),
            "edit-model-b"
        )
        XCTAssertEqual(
            ModelRepository.eligibleModel(preferred: "dictation-only", from: models),
            "edit-model-a"
        )
    }

    func testModelScopedVerificationIsIndependentFromProviderSelection() {
        self.withRestoredFingerprints { settings in
            settings.verifiedProviderFingerprints = ["private": "model-a-fingerprint"]
            settings.verifiedPrivateAIModelFingerprints = [:]

            XCTAssertFalse(
                PrivateAIProviderPromptFormat.hasStoredVerification(
                    for: "model-b",
                    providerKey: "private",
                    expectedFingerprint: "model-b-fingerprint",
                    settings: settings
                )
            )

            settings.verifiedPrivateAIModelFingerprints = ["model-b": "model-b-fingerprint"]

            XCTAssertTrue(
                PrivateAIProviderPromptFormat.hasStoredVerification(
                    for: "model-b",
                    providerKey: "private",
                    expectedFingerprint: "model-b-fingerprint",
                    settings: settings
                )
            )
            XCTAssertFalse(
                PrivateAIProviderPromptFormat.hasStoredVerification(
                    for: "model-b",
                    providerKey: "private",
                    expectedFingerprint: "stale-fingerprint",
                    settings: settings
                )
            )
        }
    }

    func testLegacyProviderFingerprintRemainsValid() {
        self.withRestoredFingerprints { settings in
            settings.verifiedPrivateAIModelFingerprints = [:]
            settings.verifiedProviderFingerprints = ["private": "legacy-fingerprint"]

            XCTAssertTrue(
                PrivateAIProviderPromptFormat.hasStoredVerification(
                    for: "model-a",
                    providerKey: "private",
                    expectedFingerprint: "legacy-fingerprint",
                    settings: settings
                )
            )
        }
    }

    func testOverlaySnapshotMatchesRoutingAndDoesNotChangeSettings() async {
        let settings = SettingsStore.shared
        let restore = self.saveOverlaySettings(settings)
        defer { restore() }
        let profile = SettingsStore.DictationPromptProfile(id: "snapshot-profile", name: "Work", prompt: "Clean up")
        settings.dictationPromptProfiles = [profile]
        settings.appPromptBindings = [.init(mode: .dictate, appBundleID: "snapshot.editor", appName: "Editor", promptID: profile.id)]
        settings.selectedProviderID = "openai"
        settings.selectedModelByProvider = ["openai": "test-model"]
        settings.dictationPromptConfigurations = [:]
        settings.setDictationPromptConfiguration(.init(providerID: "openai", modelName: "profile-model"), for: .profile(profile.id))
        let selections: [SettingsStore.DictationPromptSelection] = [.off, .default, .privateAI, .profile(profile.id)]
        for selection in selections {
            for scope in [SettingsStore.PromptRoutingScope.allApps, .selectedAppsOnly] {
                settings.dictationPromptRoutingScope = scope
                settings.setDictationPromptSelection(selection, for: .primary)
                settings.setDictationPromptSelection(.off, for: .secondary)
                for app in ["snapshot.editor", "snapshot.other"] {
                    let selectedBefore = settings.selectedDictationPromptID
                    let configurationBefore = settings.dictationPromptConfigurations
                    let input = DictationOverlayPresentationInput(settings: settings, appBundleID: app)
                    let expected = settings.dictationOverlayLabel(for: .primary, appBundleID: app)
                    let result = await Task.detached { input.resolve() }.value
                    XCTAssertEqual(result.primary.label, expected, "\(selection), \(scope), \(app)")
                    XCTAssertEqual(result.secondary.label, "Basic")
                    XCTAssertEqual(result.primary.hasAppOverride, settings.isAppDictationPromptBindingActive(for: .primary, appBundleID: app))
                    XCTAssertEqual(settings.selectedDictationPromptID, selectedBefore)
                    XCTAssertEqual(settings.dictationPromptConfigurations, configurationBefore)
                }
            }
        }
    }

    func testOverlaySnapshotKeepsManualChoiceAndUpdatesAfterAppSwitch() {
        let settings = SettingsStore.shared
        let restore = self.saveOverlaySettings(settings)
        let session = DictationAppSession.shared
        let previousApp = session.appID
        defer {
            restore()
            session.activate(previousApp ?? "snapshot.finished")
        }
        settings.selectedProviderID = "openai"
        settings.selectedModelByProvider = ["openai": "test-model"]
        settings.dictationPromptConfigurations = [:]
        settings.appPromptBindings = []
        settings.dictationPromptRoutingScope = .allApps
        settings.setDictationPromptSelection(.default, for: .primary)
        session.activate("snapshot.editor")
        session.select(.off, slot: .primary, appID: "snapshot.editor")
        let input = DictationOverlayPresentationInput(settings: settings, appBundleID: session.appID)
        XCTAssertEqual(input.primary.unavailable.resolve(verifiedModelID: nil, modelName: { $0 }).label, "Basic")
        session.activate("snapshot.other")
        let next = DictationOverlayPresentationInput(settings: settings, appBundleID: session.appID)
        XCTAssertEqual(next.primary.unavailable.resolve(verifiedModelID: nil, modelName: { $0 }).label, "Default · test-model")
        XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .default)
    }

    func testOverlayAvailabilityFallbackAndModelName() {
        let smart = DictationOverlayPresentationInput.Candidate(
            name: "Smart", builtInLabel: "Smart", hasAppOverride: false, usesSelectedPrivateModel: true, modelID: ""
        )
        let fallback = DictationOverlayPresentationInput.Candidate(
            name: "Default", builtInLabel: "Default", hasAppOverride: false, usesSelectedPrivateModel: false, modelID: ""
        )
        let choices = DictationOverlayPresentationInput.Choices(available: smart, unavailable: fallback)
        XCTAssertEqual(choices.resolve(verifiedModelID: "mini", modelName: { $0.isEmpty ? "" : "Fluid-1 Mini" }).label, "Smart · Mini")
        XCTAssertEqual(choices.resolve(verifiedModelID: nil, modelName: { $0 }).label, "Basic")
        XCTAssertEqual(smart.resolve(verifiedModelID: nil, modelName: { $0 }).label, "Basic")
    }

    func testWarmupRequestRespectsOffExternalPrivateAndAppOverrides() {
        let settings = SettingsStore.shared
        let restore = self.saveOverlaySettings(settings)
        defer { restore() }
        let profile = SettingsStore.DictationPromptProfile(id: "warmup-profile", name: "Work", prompt: "Clean up")
        settings.dictationPromptProfiles = [profile]
        settings.appPromptBindings = []
        settings.dictationPromptRoutingScope = .allApps
        settings.selectedProviderID = "openai"
        settings.dictationPromptConfigurations = [:]
        settings.setDictationPromptConfiguration(.init(providerID: "openai", modelName: "external-model"), for: .default)
        func request(_ slot: SettingsStore.DictationShortcutSlot = .primary, app: String = "warmup.editor") -> PrivateAIProviderPromptFormat.VerificationInput? {
            DictationProviderRoute.privateAIWarmupVerification(settings: settings, slot: slot, appBundleID: app)
        }
        settings.setDictationPromptSelection(.off, for: .primary)
        XCTAssertNil(request())
        settings.setDictationPromptSelection(.default, for: .primary)
        XCTAssertNil(request())
        settings.setDictationPromptSelection(.privateAI, for: .primary)
        XCTAssertNotNil(request())
        settings.setDictationPromptSelection(.off, for: .secondary)
        XCTAssertNil(request(.secondary))

        settings.setDictationPromptConfiguration(.init(providerID: "openai", modelName: "external-model"), for: .profile(profile.id))
        settings.appPromptBindings = [.init(mode: .dictate, appBundleID: "warmup.editor", appName: "Editor", promptID: profile.id)]
        XCTAssertNil(request(), "An external app rule must not warm a private model")
        XCTAssertNotNil(request(app: "warmup.other"))
        settings.setDictationPromptConfiguration(.init(providerID: PrivateAIProviderFeature.shared.providerID, modelName: "private-model"), for: .profile(profile.id))
        XCTAssertNotNil(request(), "A profile using the private provider still needs warmup")
        settings.dictationPromptRoutingScope = .selectedAppsOnly
        XCTAssertNil(request(app: "warmup.other"))
        XCTAssertEqual(settings.selectedDictationPromptID, PrivateAIProviderPromptFormat.promptSelectionID)
    }

    func testOverlayWorkerCoalescesChangesRejectsStaleResultAndNeverRunsOnMain() async {
        let settings = SettingsStore.shared
        let restore = self.saveOverlaySettings(settings)
        defer { restore() }
        settings.setDictationPromptSelection(.off, for: .primary)
        let first = DictationOverlayPresentationInput(settings: settings, appBundleID: nil)
        settings.setDictationPromptSelection(.default, for: .primary)
        let latest = DictationOverlayPresentationInput(settings: settings, appBundleID: nil)
        let entered = expectation(description: "worker entered")
        let finished = expectation(description: "latest value published")
        let gate = OverlayPresentationTestGate()
        let store = DictationOverlayPresentationStore { input in
            XCTAssertFalse(Thread.isMainThread)
            if input == first {
                entered.fulfill()
                await gate.wait()
            }
            let label = input == first ? "stale" : "latest"
            let value = DictationOverlayPresentation(label: label, builtInLabel: nil, hasAppOverride: false)
            return DictationOverlayPresentations(primary: value, secondary: value)
        }
        var published: [String] = []
        let subscription = store.$value.sink { value in
            published.append(value.primary.label)
            if value.primary.label == "latest" { finished.fulfill() }
        }
        store.update(first)
        await fulfillment(of: [entered], timeout: 2)
        for _ in 0..<20 {
            store.update(latest)
        }
        await gate.release()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(published.contains("stale"))
        XCTAssertEqual(published.filter { $0 == "latest" }.count, 1)
        XCTAssertEqual(settings.selectedDictationPromptID, nil)
        withExtendedLifetime(subscription) {}
    }

    private func saveOverlaySettings(_ settings: SettingsStore) -> () -> Void {
        let profiles = settings.dictationPromptProfiles
        let bindings = settings.appPromptBindings
        let primary = settings.selectedDictationPromptID
        let secondary = settings.promptModeSelectedPromptID
        let primaryOff = settings.isDictationPromptOff
        let secondaryOff = settings.isSecondaryDictationPromptOff
        let scope = settings.dictationPromptRoutingScope
        let configurations = settings.dictationPromptConfigurations
        let provider = settings.selectedProviderID
        let models = settings.selectedModelByProvider
        return {
            settings.dictationPromptProfiles = profiles
            settings.appPromptBindings = bindings
            settings.selectedDictationPromptID = primary
            settings.promptModeSelectedPromptID = secondary
            settings.isDictationPromptOff = primaryOff
            settings.isSecondaryDictationPromptOff = secondaryOff
            settings.dictationPromptRoutingScope = scope
            settings.dictationPromptConfigurations = configurations
            settings.selectedProviderID = provider
            settings.selectedModelByProvider = models
        }
    }

    private func withRestoredFingerprints(_ body: (SettingsStore) -> Void) {
        let settings = SettingsStore.shared
        let providerFingerprints = settings.verifiedProviderFingerprints
        let modelFingerprints = settings.verifiedPrivateAIModelFingerprints
        defer {
            settings.verifiedProviderFingerprints = providerFingerprints
            settings.verifiedPrivateAIModelFingerprints = modelFingerprints
        }
        body(settings)
    }
}

private struct TaskDefaultPrivateAIProvider: PrivateAIProviderFeatureProviding {
    let isAvailable = true
    let providerID = "private-test"
    let providerName = "Private Test"
    let promptSelectionID = "private-test"
    let defaultModelID = "dictation-model"
    let selectedModelDefaultsKey = "private-test-model"
    let localModelPathDefaultsKey = "private-test-path"
    let prefixCacheDefaultsKey = "private-test-cache"
    let boostDefaultsKey = "private-test-boost"
    let modelDirectoryName = "PrivateTest"

    func modelIDs() -> [String] { ["dictation-model"] }
    func model(id _: String) -> PrivateAIRegisteredModel? { nil }
    func canonicalModelID(for _: String) -> String? { nil }
    func isKnownModelID(_: String) -> Bool { false }
}

private actor OverlayPresentationTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !self.released else { return }
        await withCheckedContinuation { self.continuation = $0 }
    }

    func release() {
        self.released = true
        self.continuation?.resume()
        self.continuation = nil
    }
}
