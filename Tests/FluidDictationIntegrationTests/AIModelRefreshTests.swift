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

    func testRestoringLegacyBackupClearsStoredCustomModels() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: SettingsStore.customModelsByProviderDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: SettingsStore.customModelsByProviderDefaultsKey)
            } else {
                defaults.removeObject(forKey: SettingsStore.customModelsByProviderDefaultsKey)
            }
        }

        SettingsStore.shared.customModelsByProvider = ["openai": ["stale-local-model"]]
        SettingsStore.shared.restoreCustomModelsByProvider(nil)

        XCTAssertFalse(SettingsStore.shared.hasStoredCustomModelsByProvider)
        XCTAssertTrue(SettingsStore.shared.customModelsByProvider.isEmpty)
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

    func testLegacyAppendedModelsMigrateWithoutPromotingSortedCatalogs() {
        XCTAssertEqual(
            AIEnhancementSettingsViewModel.migratedLegacyCustomModels(
                cachedModelsByProvider: [
                    "OpenAI": ["gpt-a", "gpt-z", " custom-mid "],
                    "sorted-provider": ["model-a", "model-b", "model-c"],
                ],
                savedModelsByProvider: [
                    "legacy-provider": ["model-a", "model-z", "manual-a", "manual-b"],
                ]
            ),
            [
                "openai": ["custom-mid"],
                "custom:legacy-provider": ["manual-a", "manual-b"],
            ]
        )
    }

    func testLegacyModelsReconcileAgainstFirstFreshCatalog() {
        XCTAssertEqual(
            AIEnhancementSettingsViewModel.reconciledLegacyCustomModels(
                legacyModels: ["gpt-4.1", "gpt-5-custom"],
                discoveredModels: ["gpt-4.1"]
            ),
            ["gpt-5-custom"]
        )
        XCTAssertEqual(
            AIEnhancementSettingsViewModel.reconciledLegacyCustomModels(
                legacyModels: ["model-a", "model-b", "model-c"],
                discoveredModels: ["model-a", "model-b", "model-c"]
            ),
            []
        )
    }

    func testLegacyCandidatesExcludeSortedDiscoveryOnlyCatalogs() {
        XCTAssertEqual(
            AIEnhancementSettingsViewModel.legacyModelCandidates(
                cachedModelsByProvider: [
                    "openai": ["gpt-a", "gpt-b", "gpt-retired"],
                    "groq": ["model-a", "model-z", "manual-model"],
                ],
                savedModelsByProvider: [:]
            ),
            ["groq": ["manual-model"]]
        )
    }

    func testCustomModelsMergeWithBuiltInDefaultsWhenCacheIsMissing() {
        let defaultModels = ModelRepository.shared.defaultModels(for: "openai")
        XCTAssertFalse(defaultModels.isEmpty)

        XCTAssertEqual(
            AIEnhancementSettingsViewModel.modelsByMergingCustomModels(
                [],
                customModels: ["gpt-custom"],
                providerKey: "openai",
                useDefaultModels: true
            ),
            AIModelCatalog.normalized(defaultModels + ["gpt-custom"])
        )
    }

    func testManualAdditionStartsWithBuiltInDefaultsWhenCacheIsMissing() {
        let defaultModels = ModelRepository.shared.defaultModels(for: "openai")
        let visibleModels = AIEnhancementSettingsViewModel.visibleModelsForManualAddition(
            [],
            providerKey: "openai"
        )

        XCTAssertEqual(visibleModels, AIModelCatalog.normalized(defaultModels))
        XCTAssertEqual(
            AIEnhancementSettingsViewModel.manualModelAddition(
                "gpt-custom",
                visibleModels: visibleModels,
                customModels: []
            )?.visibleModels,
            AIModelCatalog.normalized(defaultModels + ["gpt-custom"])
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
