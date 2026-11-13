import SwiftUI

struct DashboardRecommendationsView: View {
    @ObservedObject var asr: ASRService
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var installations = SpeechModelInstallationSnapshot.shared
    @ObservedObject private var content = NotchContentState.shared
    @StateObject private var controller: DashboardRecommendationsController
    @Environment(\.theme) private var theme

    init(asr: ASRService) {
        self.asr = asr
        _controller = StateObject(wrappedValue: DashboardRecommendationsController(asr: asr))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !self.controller.recommendations.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Recommendations for your Mac")
                        .font(self.theme.typography.sectionTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    ThemedCard(style: .subtle, padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(self.controller.recommendations) { recommendation in
                                self.card(recommendation)
                                if recommendation.id != self.controller.recommendations.last?.id {
                                    Divider().padding(.horizontal, 20)
                                }
                            }
                        }
                    }
                }
            }
        }
        .task(id: DashboardRecommendationsController.Selection(settings: self.settings)) {
            await self.controller.refresh()
        }
        .onAppear { self.installations.refresh() }
        .onDisappear { self.controller.operation.cancel() }
    }

    private func card(_ recommendation: DashboardModelRecommendation) -> some View {
        let operation = self.controller.operation
        let working = operation.activeID == recommendation.id
        let installed = recommendation.kind == .speech ? self.installations.isInstalled(modelID: recommendation.modelID) : recommendation.installed
        let error = operation.failedID == recommendation.id ? operation.error : nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(recommendation.kind == .speech ? "Speech recognition" : "AI cleanup", systemImage: recommendation.kind == .speech ? "waveform" : "sparkles")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    Text(recommendation.name)
                        .font(self.theme.typography.bodyStrong)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if !working {
                    Button { self.controller.dismiss(recommendation) } label: {
                        Image(systemName: "xmark").font(self.theme.typography.caption)
                    }
                    .fluidGlassAction(circular: true, quiet: true)
                    .disabled(operation.isBusy)
                    .accessibilityLabel("Dismiss \(recommendation.name) recommendation")
                    .help("Hide this recommendation. The model remains available in Settings.")
                }
            }
            Text(recommendation.detail)
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if recommendation.kind == .cleanup {
                Text("Research preview · Review your text before sending. Cleanup may make inaccurate changes.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if working {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: operation.fraction)
                        .progressViewStyle(.linear)
                        .tint(self.theme.palette.accent)
                        .accessibilityLabel("\(recommendation.name) progress")
                    HStack {
                        Text(operation.message).font(self.theme.typography.caption)
                        Spacer(minLength: 8)
                        if let fraction = operation.fraction {
                            Text(fraction, format: .percent.precision(.fractionLength(0)))
                                .font(self.theme.typography.caption).monospacedDigit()
                        }
                    }
                    Button("Cancel") { operation.cancel() }
                        .fluidGlassAction()
                        .disabled(operation.cancelling)
                }
            } else {
                if let error {
                    Text(error).font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Model could not be activated. \(error)")
                }
                if !installed, !recommendation.downloadSize.isEmpty {
                    Text("\(recommendation.downloadSize) download")
                        .font(self.theme.typography.caption).foregroundStyle(.secondary)
                }
                Button {
                    self.controller.use(recommendation)
                } label: {
                    Label(error != nil ? "Try again" : (installed ? "Use model" : "Download & use"), systemImage: installed ? "arrow.right" : "arrow.down")
                }
                .fluidGlassAction(prominent: true)
                .disabled(self.controller.actionsBlocked || self.content.isProcessing || (recommendation.kind == .speech && !self.installations.canUseModelActions))
                .accessibilityLabel("\(installed ? "Use" : "Download and use") \(recommendation.name) for \(recommendation.kind == .speech ? "speech recognition" : "AI cleanup")")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
