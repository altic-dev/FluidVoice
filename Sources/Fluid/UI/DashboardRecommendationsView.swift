import SwiftUI

struct DashboardRecommendationsView: View {
    @ObservedObject var asr: ASRService
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var installations = SpeechModelInstallationSnapshot.shared
    @ObservedObject private var content = NotchContentState.shared
    @ObservedObject var controller: DashboardRecommendationsController
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !self.controller.recommendations.isEmpty {
                FluidSettingsGroup(title: "Recommendations for your Mac") {
                    ForEach(self.controller.recommendations) { recommendation in
                        FluidSettingsBlock { self.card(recommendation) }
                    }
                }
            }
        }
        .task(id: DashboardRecommendationsController.Selection(settings: self.settings)) {
            await self.controller.refresh()
        }
        .onAppear { self.installations.refresh() }
    }

    private func card(_ recommendation: DashboardModelRecommendation) -> some View {
        let operation = self.controller.operation
        let working = operation.activeID == recommendation.id
        let installed = recommendation.kind == .speech ? self.installations.isInstalled(modelID: recommendation.modelID) : recommendation.installed
        let error = operation.failedID == recommendation.id ? operation.error : nil
        let look = self.theme.look
        let spacing = self.theme.metrics.spacing
        return VStack(alignment: .leading, spacing: spacing.md) {
            HStack(alignment: .top, spacing: spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recommendation.kind == .speech ? "Speech recognition" : "AI cleanup")
                        .fluidText(.label)
                        .foregroundStyle(look.tertiaryText)
                    Text(recommendation.name)
                        .fluidText(.rowTitle)
                        .foregroundStyle(look.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if !working {
                    Button { self.controller.dismiss(recommendation) } label: {
                        Image(systemName: "xmark").font(.fluidSystem(size: 12, weight: .semibold))
                    }
                    .fluidGlassAction(circular: true, quiet: true)
                    .disabled(operation.isBusy)
                    .accessibilityLabel("Dismiss \(recommendation.name) recommendation")
                    .help("Hide this recommendation. The model remains available in Settings.")
                }
            }
            Text(recommendation.detail)
                .fluidText(.body)
                .foregroundStyle(look.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if recommendation.kind == .cleanup {
                Text("Research preview · Review your text before sending. Cleanup may make inaccurate changes.")
                    .fluidText(.label)
                    .foregroundStyle(look.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if working {
                VStack(alignment: .leading, spacing: spacing.sm) {
                    ProgressView(value: operation.fraction)
                        .progressViewStyle(.linear)
                        .tint(look.highlight)
                        .accessibilityLabel("\(recommendation.name) progress")
                    HStack {
                        Text(operation.message)
                        Spacer(minLength: spacing.sm)
                        if let fraction = operation.fraction {
                            Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                        }
                    }
                    .fluidText(.label)
                    .foregroundStyle(look.secondaryText)
                    Button("Cancel") { operation.cancel() }
                        .fluidAction()
                        .disabled(operation.cancelling)
                }
            } else {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .fluidText(.label)
                        .foregroundStyle(look.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Model could not be activated. \(error)")
                }
                HStack(spacing: spacing.md) {
                    Button(error != nil ? "Try again" : (installed ? "Use model" : "Download & use")) {
                        self.controller.use(recommendation)
                    }
                    .fluidAction()
                    .disabled(self.controller.actionsBlocked || self.content.isProcessing || (recommendation.kind == .speech && !self.installations.canUseModelActions))
                    .accessibilityLabel("\(installed ? "Use" : "Download and use") \(recommendation.name) for \(recommendation.kind == .speech ? "speech recognition" : "AI cleanup")")
                    if !installed, !recommendation.downloadSize.isEmpty {
                        Text("\(recommendation.downloadSize) download")
                            .fluidText(.label)
                            .foregroundStyle(look.tertiaryText)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
