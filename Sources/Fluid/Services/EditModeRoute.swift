import Foundation

/// Where an Edit Mode request runs. The shortcut and the request ask the same
/// question, so they can't disagree about whether the model is there.
enum EditModeRoute: Equatable {
    /// A cloud or custom provider, picked in AI Settings.
    case provider
    case local(PrivateAIRegisteredModel)
    /// Fluid Intelligence is selected, but its Edit Mode model isn't downloaded.
    case modelMissing
    /// Fluid Intelligence is selected, and this build turns its Edit Mode model off.
    case notOffered
    case unsupportedHardware

    /// Why Edit Mode can't run, or nil when it can.
    var failureMessage: String? {
        switch self {
        case .provider, .local: nil
        case .modelMissing: "Edit Mode needs its model"
        case .notOffered: "Choose an AI provider to use Edit Mode."
        case .unsupportedHardware: "On-device Edit Mode needs Apple Silicon. Choose an AI provider."
        }
    }

    nonisolated static func resolve(
        providerID: String,
        privateProviderID: String?,
        editModel: PrivateAIRegisteredModel?,
        supportsLocalModel: Bool = true,
        isInstalled: (PrivateAIRegisteredModel) -> Bool
    ) -> EditModeRoute {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let privateProviderID, trimmed == privateProviderID else { return .provider }
        guard supportsLocalModel else { return .unsupportedHardware }
        guard let editModel else { return .notOffered }
        return isInstalled(editModel) ? .local(editModel) : .modelMissing
    }

    /// Checks the model folder, so call it off the main thread where it matters.
    nonisolated static func current(providerID: String) -> EditModeRoute {
        self.resolve(
            providerID: providerID,
            privateProviderID: PrivateAIProviderFeature.shared.isAvailable ? PrivateAIProviderFeature.shared.providerID : nil,
            editModel: PrivateAIIntegrationService.editModel,
            supportsLocalModel: CPUArchitecture.isAppleSilicon,
            isInstalled: { PrivateAIIntegrationService.isModelInstalled($0) }
        )
    }
}
