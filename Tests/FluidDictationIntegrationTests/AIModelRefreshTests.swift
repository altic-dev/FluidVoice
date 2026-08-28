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
        let previousAvailableModels = SettingsStore.shared.availableModels
        let previousAvailableModelsByProvider = SettingsStore.shared.availableModelsByProvider
        let previousLegacyCandidates = SettingsStore.shared.legacyModelCandidatesByProvider
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: SettingsStore.customModelsByProviderDefaultsKey)
            } else {
                defaults.removeObject(forKey: SettingsStore.customModelsByProviderDefaultsKey)
            }
            SettingsStore.shared.availableModels = previousAvailableModels
            SettingsStore.shared.availableModelsByProvider = previousAvailableModelsByProvider
            SettingsStore.shared.legacyModelCandidatesByProvider = previousLegacyCandidates
        }

        SettingsStore.shared.customModelsByProvider = ["openai": ["stale-local-model"]]
        SettingsStore.shared.availableModels = ["stale-local-model"]
        SettingsStore.shared.availableModelsByProvider = ["openai": ["gpt-default", "stale-local-model"]]
        SettingsStore.shared.legacyModelCandidatesByProvider = ["openai": ["stale-local-model"]]
        SettingsStore.shared.prepareLegacyModelCatalogRestore(savedProviders: [])

        XCTAssertFalse(SettingsStore.shared.hasStoredCustomModelsByProvider)
        XCTAssertTrue(SettingsStore.shared.customModelsByProvider.isEmpty)
        XCTAssertTrue(SettingsStore.shared.availableModels.isEmpty)
        XCTAssertTrue(SettingsStore.shared.availableModelsByProvider.isEmpty)
        XCTAssertTrue(SettingsStore.shared.legacyModelCandidatesByProvider.isEmpty)
    }

    func testRestoringLegacyBackupRehydratesSavedProviderCatalog() {
        let defaults = UserDefaults.standard
        let previousCustomModels = defaults.object(
            forKey: SettingsStore.customModelsByProviderDefaultsKey
        )
        let previousLegacyCandidates = defaults.object(
            forKey: SettingsStore.legacyModelCandidatesDefaultsKey
        )
        let previousAvailableModels = SettingsStore.shared.availableModels
        let previousAvailableModelsByProvider = SettingsStore.shared.availableModelsByProvider
        defer {
            if let previousCustomModels {
                defaults.set(
                    previousCustomModels,
                    forKey: SettingsStore.customModelsByProviderDefaultsKey
                )
            } else {
                defaults.removeObject(forKey: SettingsStore.customModelsByProviderDefaultsKey)
            }
            if let previousLegacyCandidates {
                defaults.set(
                    previousLegacyCandidates,
                    forKey: SettingsStore.legacyModelCandidatesDefaultsKey
                )
            } else {
                defaults.removeObject(forKey: SettingsStore.legacyModelCandidatesDefaultsKey)
            }
            SettingsStore.shared.availableModels = previousAvailableModels
            SettingsStore.shared.availableModelsByProvider = previousAvailableModelsByProvider
        }

        SettingsStore.shared.availableModelsByProvider = ["custom:provider-id": ["stale-model"]]
        SettingsStore.shared.prepareLegacyModelCatalogRestore(
            savedProviders: [
                SettingsStore.SavedProvider(
                    id: "provider-id",
                    name: "Provider",
                    baseURL: "https://example.com",
                    models: ["provider-model"]
                ),
            ]
        )

        XCTAssertEqual(
            SettingsStore.shared.availableModelsByProvider["custom:provider-id"],
            ["provider-model"]
        )
    }

    func testBackupMigratesLegacyManualModelsBeforeSettingsLoad() {
        let defaults = UserDefaults.standard
        let previousCustomModels = defaults.object(
            forKey: SettingsStore.customModelsByProviderDefaultsKey
        )
        let previousAvailableModelsByProvider = SettingsStore.shared.availableModelsByProvider
        let previousSavedProviders = SettingsStore.shared.savedProviders
        defer {
            if let previousCustomModels {
                defaults.set(
                    previousCustomModels,
                    forKey: SettingsStore.customModelsByProviderDefaultsKey
                )
            } else {
                defaults.removeObject(forKey: SettingsStore.customModelsByProviderDefaultsKey)
            }
            SettingsStore.shared.availableModelsByProvider = previousAvailableModelsByProvider
            SettingsStore.shared.savedProviders = previousSavedProviders
        }

        SettingsStore.shared.clearStoredCustomModelsByProvider()
        SettingsStore.shared.availableModelsByProvider = [
            "openai": ["gpt-a", "gpt-z", "custom-mid"],
        ]
        SettingsStore.shared.savedProviders = [
            SettingsStore.SavedProvider(
                id: "provider-id",
                name: "Provider",
                baseURL: "https://example.com",
                models: ["model-a", "model-z", "manual-provider"]
            ),
        ]

        let payload = SettingsStore.shared.makeBackupPayload()

        XCTAssertEqual(payload.customModelsByProvider?["openai"], ["custom-mid"])
        XCTAssertEqual(
            payload.customModelsByProvider?["custom:provider-id"],
            ["manual-provider"]
        )
    }

    func testRestoringCustomModelsRehydratesAvailableCatalog() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: SettingsStore.customModelsByProviderDefaultsKey)
        let previousAvailableModels = SettingsStore.shared.availableModels
        let previousAvailableModelsByProvider = SettingsStore.shared.availableModelsByProvider
        let previousLegacyCandidates = SettingsStore.shared.legacyModelCandidatesByProvider
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: SettingsStore.customModelsByProviderDefaultsKey)
            } else {
                defaults.removeObject(forKey: SettingsStore.customModelsByProviderDefaultsKey)
            }
            SettingsStore.shared.availableModels = previousAvailableModels
            SettingsStore.shared.availableModelsByProvider = previousAvailableModelsByProvider
            SettingsStore.shared.legacyModelCandidatesByProvider = previousLegacyCandidates
        }

        SettingsStore.shared.availableModelsByProvider = [:]
        SettingsStore.shared.restoreModelCatalogState(
            customModelsByProvider: [
                "openai": ["gpt-custom"],
                "custom:provider-id": ["provider-custom"],
            ],
            savedProviders: [
                SettingsStore.SavedProvider(
                    id: "provider-id",
                    name: "Provider",
                    baseURL: "https://example.com",
                    models: ["provider-discovered"]
                ),
            ]
        )

        XCTAssertEqual(SettingsStore.shared.customModelsByProvider["openai"], ["gpt-custom"])
        XCTAssertEqual(
            SettingsStore.shared.availableModelsByProvider["openai"],
            AIModelCatalog.normalized(
                ModelRepository.shared.defaultModels(for: "openai") + ["gpt-custom"]
            )
        )
        XCTAssertEqual(
            SettingsStore.shared.availableModelsByProvider["custom:provider-id"],
            ["provider-discovered", "provider-custom"]
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

    func testLegacyCandidateReconciliationReplacesCandidateSubset() {
        XCTAssertEqual(
            AIEnhancementSettingsViewModel.customModelsAfterReconcilingLegacyCandidates(
                customModels: ["official-model", "new-manual-model", "legacy-only-model"],
                legacyCandidates: ["official-model", "legacy-only-model"],
                discoveredModels: ["official-model"]
            ),
            ["new-manual-model", "legacy-only-model"]
        )
        XCTAssertEqual(
            AIEnhancementSettingsViewModel.customModelsAfterReconcilingLegacyCandidates(
                customModels: ["official-model"],
                legacyCandidates: ["official-model"],
                discoveredModels: ["official-model"]
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

    func testDeletingCustomModelRemovesOnlyManualCatalogEntries() {
        XCTAssertEqual(
            AIEnhancementSettingsViewModel.manualModelDeletion(
                "model/custom",
                visibleModels: ["model/discovered", "model/custom"],
                customModels: ["model/custom"],
                fallbackModels: ["model/fallback"]
            ),
            AIEnhancementSettingsViewModel.ManualModelDeletion(
                visibleModels: ["model/discovered"],
                customModels: [],
                selectedModel: "model/discovered"
            )
        )
        XCTAssertNil(
            AIEnhancementSettingsViewModel.manualModelDeletion(
                "model/discovered",
                visibleModels: ["model/discovered", "model/custom"],
                customModels: ["model/custom"],
                fallbackModels: ["model/fallback"]
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
