import SwiftUI

/// Shows where onboarding downloads go and lets the user pick another folder before the first download.
struct OnboardingModelStorageRow: View {
    let isDisabled: Bool
    @Environment(\.theme) private var theme
    @ObservedObject private var monitor = ModelStorageMonitor.shared
    @StateObject private var flow = ModelStorageChoiceFlow()

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: self.monitor.configuration.usesCustomRoot ? "externaldrive" : "internaldrive")
                    .foregroundStyle(Color.white.opacity(0.62))
                Text("Models are saved to")
                    .foregroundStyle(Color.white.opacity(0.62))
                Text(self.locationText)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 300)
                    .help(self.monitor.displayPath)
                Button(self.flow.isPlanning ? "Checking…" : "Change…") {
                    self.flow.chooseFolder(switchWhenNothingToMove: true)
                }
                .buttonStyle(.plain)
                .foregroundStyle(FluidOnboardingLandingColors.blue)
                .disabled(self.isDisabled || self.flow.isPlanning || self.monitor.isMoving)
                .accessibilityLabel("Change model storage location")
            }
            .font(.fluidSystem(size: 12, weight: .medium))

            if let progress = self.monitor.moveProgress {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(ModelStorageSettingsSection.phaseText(progress))
                        .foregroundStyle(Color.white.opacity(0.62))
                    if self.monitor.canCancelMove {
                        Button("Cancel") { self.monitor.cancelMove() }
                            .buttonStyle(.plain)
                            .foregroundStyle(FluidOnboardingLandingColors.blue)
                            .accessibilityLabel("Cancel moving models")
                    }
                }
                .font(.fluidSystem(size: 12, weight: .medium))
            }
            if let message = self.statusMessage {
                Text(message)
                    .font(.fluidSystem(size: 12, weight: .medium))
                    .foregroundStyle(self.monitor.availability.isUsable ? Color.white.opacity(0.62) : self.theme.palette.warning)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560)
            }
        }
        .task { await self.monitor.refresh() }
        .modelStorageChoiceDialog(self.flow)
    }

    private var locationText: String {
        guard let root = self.monitor.configuration.resolvedRootURL else { return "this Mac (default)" }
        if let volume = self.monitor.volumeName ?? self.monitor.configuration.volumeName {
            return "\(volume) › \(root.lastPathComponent)"
        }
        return root.path
    }

    private var statusMessage: String? {
        self.monitor.availability.problemDescription ?? self.flow.errorMessage ?? self.monitor.lastMoveMessage
    }
}
