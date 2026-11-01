import Foundation
import XCTest

@testable import FluidVoice_Debug

final class EditModeRouteTests: XCTestCase {
    private let model = PrivateAIRegisteredModel(
        displayName: "Edit",
        detail: "",
        isEnabled: true,
        parameterCount: "",
        recommendedMemoryGB: nil,
        artifact: PrivateAIModelArtifact(identifier: "edit-model", filename: "edit-model")
    )

    func testCloudProviderKeepsItsRouteWhateverIsInstalled() {
        for installed in [true, false] {
            let route = EditModeRoute.resolve(
                providerID: "openai",
                privateProviderID: "fluid-1",
                editModel: self.model,
                isInstalled: { _ in installed }
            )
            XCTAssertEqual(route, .provider)
        }
    }

    func testBuildWithoutThePrivateProviderAlwaysUsesTheProvider() {
        let route = EditModeRoute.resolve(
            providerID: "fluid-1",
            privateProviderID: nil,
            editModel: nil,
            isInstalled: { _ in false }
        )
        XCTAssertEqual(route, .provider)
    }

    func testLocalProviderRunsOnTheInstalledEditModel() {
        let route = EditModeRoute.resolve(
            providerID: " fluid-1 ",
            privateProviderID: "fluid-1",
            editModel: self.model,
            isInstalled: { _ in true }
        )
        XCTAssertEqual(route, .local(self.model))
    }

    func testLocalProviderAsksForTheDownloadInsteadOfFetchingIt() {
        var checked = 0
        let route = EditModeRoute.resolve(
            providerID: "fluid-1",
            privateProviderID: "fluid-1",
            editModel: self.model,
            isInstalled: { _ in
                checked += 1
                return false
            }
        )
        XCTAssertEqual(route, .modelMissing)
        XCTAssertEqual(checked, 1)
    }

    func testLocalProviderWithTheModelTurnedOffPointsElsewhere() {
        let route = EditModeRoute.resolve(
            providerID: "fluid-1",
            privateProviderID: "fluid-1",
            editModel: nil,
            isInstalled: { _ in true }
        )
        XCTAssertEqual(route, .notOffered)
        XCTAssertEqual(route.failureMessage, "Choose an AI provider to use Edit Mode.")
    }

    @MainActor
    func testDownloadButtonOnlyLastsForItsOwnFailure() {
        let state = NotchContentState.shared
        defer {
            state.showAIProcessingFailure()
            state.clearAIProcessingFailure()
        }

        state.showAIProcessingFailure(message: "needs model", canRetry: false, downloadAction: {})
        XCTAssertNotNil(state.aiProcessingFailureDownloadAction)

        state.showAIProcessingFailure(message: "other failure", canRetry: false)
        XCTAssertNil(state.aiProcessingFailureDownloadAction)

        state.showAIProcessingFailure(message: "needs model", canRetry: false, downloadAction: {})
        state.clearAIProcessingFailure()
        XCTAssertNil(state.aiProcessingFailureDownloadAction)
    }

    func testOnlyFailuresHaveAMessage() {
        XCTAssertNil(EditModeRoute.provider.failureMessage)
        XCTAssertNil(EditModeRoute.local(self.model).failureMessage)
        XCTAssertNotNil(EditModeRoute.modelMissing.failureMessage)
    }
}
