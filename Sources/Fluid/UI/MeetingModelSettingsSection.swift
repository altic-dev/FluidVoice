import SwiftUI

struct MeetingModelSettingsSection: View {
    let onModelImported: @MainActor () -> Void
    @Environment(\.theme) private var theme
    @ObservedObject private var store = MeetingDiarizationModelStore.shared
    @State private var showingDetails = false

    var body: some View {
        FluidManagementGroup(title: "Speaker labels") {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                HStack(spacing: self.theme.metrics.spacing.lg) {
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                        Text("Identify each speaker")
                            .font(self.theme.typography.bodyStrong)
                            .foregroundStyle(self.theme.palette.primaryText)
                        self.status
                    }
                    Spacer(minLength: self.theme.metrics.spacing.md)
                    if case .failed = self.store.state {
                        Button("Try again") { self.store.prepareInBackground() }
                            .meetingGlassAction()
                            .disabled(!CPUArchitecture.isAppleSilicon)
                    }
                }
                DisclosureGroup(isExpanded: self.$showingDetails) {
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                        if case let .ready(installed) = self.store.state {
                            Text("Nemotron 3 Diarization · \(ByteCountFormatter.string(fromByteCount: installed.totalByteCount, countStyle: .file))")
                        }
                        Text(CPUArchitecture.isAppleSilicon
                            ? "Downloads once (about 200 MB) and stays on this Mac. Recording works while it downloads; transcription waits for it."
                            : "FluidMeet recording currently requires an Apple silicon Mac.")
                    }
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, self.theme.metrics.spacing.sm)
                } label: {
                    Text("Model details")
                        .meetingHoverFeedback(cornerRadius: self.theme.metrics.corners.sm)
                }
                .font(self.theme.typography.captionStrong)
                .foregroundStyle(self.theme.palette.secondaryText)
            }
        }
        .task { self.store.prepareInBackground() }
        .onChange(of: self.store.state) { _, state in
            if case .ready = state { self.onModelImported() }
        }
    }

    @ViewBuilder private var status: some View {
        switch self.store.state {
        case .idle, .checking:
            HStack(spacing: self.theme.metrics.spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Checking model…")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        case let .downloading(fraction):
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                ProgressView(value: fraction)
                    .frame(maxWidth: 220)
                Text(fraction < 1 ? "Downloading · \(Int(fraction * 100))%" : "Installing…")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .monospacedDigit()
            }
        case .ready:
            Label("Ready · runs after recording", systemImage: "checkmark.circle.fill")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.success)
        case let .failed(message):
            Text(message)
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
