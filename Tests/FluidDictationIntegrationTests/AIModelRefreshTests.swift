@testable import FluidVoice_Debug
import XCTest

@MainActor
final class AIModelRefreshTests: XCTestCase {
    func testCustomModelsPersistByProvider() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: SettingsStore.customModelsByProviderDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: SettingsStore.customModelsByProviderDefaultsKey)
            } else {
                defaults.removeObject(forKey: SettingsStore.customModelsByProviderDefaultsKey)
            }
        }

        let providerKey = "custom:issue-601-test"
        SettingsStore.shared.customModelsByProvider = [providerKey: ["model/custom:nitro"]]

        XCTAssertEqual(
            SettingsStore.shared.customModelsByProvider[providerKey],
            ["model/custom:nitro"]
        )
    }

    func testEnteringDiscoveredModelSelectsWithoutPersistingAsCustom() {
        XCTAssertEqual(
            AIEnhancementSettingsViewModel.manualModelAddition(
                " model/discovered ",
                visibleModels: ["model/discovered", "model/other"],
                customModels: []
            ),
            AIEnhancementSettingsViewModel.ManualModelAddition(
                modelID: "model/discovered",
                visibleModels: ["model/discovered", "model/other"],
                customModels: []
            )
        )
    }

    func testEnteringNewManualModelPersistsAsCustom() {
        XCTAssertEqual(
            AIEnhancementSettingsViewModel.manualModelAddition(
                " model/custom:nitro ",
                visibleModels: ["model/discovered"],
                customModels: []
            ),
            AIEnhancementSettingsViewModel.ManualModelAddition(
                modelID: "model/custom:nitro",
                visibleModels: ["model/discovered", "model/custom:nitro"],
                customModels: ["model/custom:nitro"]
            )
        )
    }

    func testLegacyCachedAndSavedModelsMigrateBeforeFirstRefresh() {
        XCTAssertEqual(
            AIEnhancementSettingsViewModel.migratedLegacyCustomModels(
                cachedModelsByProvider: [
                    "OpenAI": [" gpt-cached ", "gpt-shared"],
                    "legacy-provider": ["cached-model"],
                ],
                savedModelsByProvider: [
                    "legacy-provider": ["saved-model", "cached-model"],
                ]
            ),
            [
                "openai": ["gpt-cached", "gpt-shared"],
                "custom:legacy-provider": ["cached-model", "saved-model"],
            ]
        )
    }

    func testRefreshDropsSelectedNonCustomModelMissingFromCatalog() {
        let selectedModel = "model/retired"
        let merged = AIModelCatalog.merged(
            discoveredModels: ["model/a"],
            customModels: []
        )

        XCTAssertFalse(merged.contains(selectedModel))
    }

    func testRefreshKeepsSelectedCustomModel() {
        let selectedModel = "model/custom:nitro"
        let merged = AIModelCatalog.merged(
            discoveredModels: ["model/a"],
            customModels: [selectedModel]
        )

        XCTAssertTrue(merged.contains(selectedModel))
    }

    func testAddingExistingModelReturnsNormalizedSelectionWithoutDuplicate() {
        XCTAssertEqual(
            AIModelCatalog.adding(" model/a ", to: ["model/a", "model/b"]),
            AIModelCatalog.Addition(
                modelID: "model/a",
                models: ["model/a", "model/b"]
            )
        )
    }

    func testRefreshDropsBlankModelIDs() {
        XCTAssertEqual(
            AIModelCatalog.merged(
                discoveredModels: ["", " \n "],
                customModels: [" model/custom "]
            ),
            ["model/custom"]
        )
    }
}
