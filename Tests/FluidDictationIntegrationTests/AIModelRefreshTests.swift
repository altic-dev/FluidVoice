@testable import FluidVoice_Debug
import XCTest

@MainActor
final class AIModelRefreshTests: XCTestCase {
    private let customModelsByProviderKey = "CustomModelsByProvider"

    func testCustomModelsPersistByProvider() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: self.customModelsByProviderKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: self.customModelsByProviderKey)
            } else {
                defaults.removeObject(forKey: self.customModelsByProviderKey)
            }
        }

        let providerKey = "custom:issue-601-test"
        SettingsStore.shared.customModelsByProvider = [providerKey: ["model/custom:nitro"]]

        XCTAssertEqual(
            SettingsStore.shared.customModelsByProvider[providerKey],
            ["model/custom:nitro"]
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
