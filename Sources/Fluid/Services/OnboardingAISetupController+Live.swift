import Foundation

extension OnboardingAISetupController {
    static let live: OnboardingAISetupController = .init(dependencies: Dependencies(
        recommend: {
            guard PrivateFeatures.privateAIProvider else { throw PrivateAIUnavailableError() }
            let recommendation = await PrivateAIHardwareRecommendation.current()
            guard let model = PrivateAIModelRegistry.model(id: recommendation.model.rawValue), model.isEnabled else {
                throw PrivateAIUnavailableError()
            }
            let installed = await Task.detached(priority: .utility) {
                PrivateAIIntegrationService.isModelInstalled(model)
            }.value
            guard installed || model.canDownload else { throw PrivateAIUnavailableError() }
            DebugLogger.shared.info("Recommended model=\(model.id) installed=\(installed)", source: "OnboardingAI")
            return Model(id: model.id, name: model.displayName, byteCount: model.artifact.byteCount, installed: installed)
        },
        prepare: { model, report in
            DebugLogger.shared.info("Transfer starting model=\(model.id)", source: "OnboardingAI")
            guard let registered = PrivateAIModelRegistry.model(id: model.id) else { throw PrivateAIUnavailableError() }
            _ = try await PrivateAIIntegrationService.prepareModel(registered) { progress in
                let progress = progress.withFallbackExpectedBytes(model.byteCount)
                await report(Progress(
                    fraction: progress.fractionCompleted,
                    status: PrivateAIModelDownloadProgressText.statusText(for: progress),
                    bytes: PrivateAIModelDownloadProgressText.byteText(for: progress)
                ))
            }
            DebugLogger.shared.info("Transfer complete model=\(model.id)", source: "OnboardingAI")
        },
        load: { model in
            guard let registered = PrivateAIModelRegistry.model(id: model.id) else { throw PrivateAIUnavailableError() }
            let status = try await PrivateAIIntegrationService.shared.loadModel(registered)
            guard status.state == .ready else {
                throw SetupError(message: status.message ?? "The model could not be prepared. Please try again.")
            }
        },
        readPendingDownload: {
            let pending = UserDefaults.standard.bool(forKey: "OnboardingFIPendingDownload")
            DebugLogger.shared.info("Recovery check pending=\(pending)", source: "OnboardingAI")
            return pending
        },
        writePendingDownload: {
            UserDefaults.standard.set($0, forKey: "OnboardingFIPendingDownload")
            UserDefaults.standard.synchronize()
            DebugLogger.shared.info("Persisted pending=\($0)", source: "OnboardingAI")
        }
    ))

    private struct SetupError: LocalizedError {
        let message: String
        var errorDescription: String? { self.message }
    }
}
