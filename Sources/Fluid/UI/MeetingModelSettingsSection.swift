import AppKit
import SwiftUI

struct MeetingModelSettingsSection: View {
    let onModelImported: @MainActor () -> Void
    @Environment(\.theme) private var theme
    @State private var installed: MeetingNemotronModelArtifact?
    @State private var isBusy = true
    @State private var message: String?
    @State private var showingDetails = false

    var body: some View {
        FluidManagementGroup(title: "Speaker labels") {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                HStack(spacing: self.theme.metrics.spacing.lg) {
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                        Text("Identify each speaker")
                            .font(self.theme.typography.bodyStrong)
                            .foregroundStyle(self.theme.palette.primaryText)
                        if self.isBusy {
                            HStack(spacing: self.theme.metrics.spacing.sm) {
                                ProgressView().controlSize(.small)
                                Text("Checking model…")
                                    .font(self.theme.typography.caption)
                                    .foregroundStyle(self.theme.palette.secondaryText)
                            }
                        } else if self.installed != nil {
                            Label("Ready · runs after recording", systemImage: "checkmark.circle.fill")
                                .font(self.theme.typography.caption)
                                .foregroundStyle(self.theme.palette.success)
                        } else {
                            Text(CPUArchitecture.isAppleSilicon ? "Import a model to get started." : "Apple silicon required.")
                                .font(self.theme.typography.caption)
                                .foregroundStyle(self.theme.palette.secondaryText)
                        }
                    }
                    Spacer(minLength: self.theme.metrics.spacing.md)
                    Button(self.installed == nil ? "Import model…" : "Replace…", action: self.choosePackage)
                        .meetingGlassAction()
                        .disabled(self.isBusy || !CPUArchitecture.isAppleSilicon)
                }
                DisclosureGroup(isExpanded: self.$showingDetails) {
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                        if let installed {
                            Text("Nemotron FP16 · \(ByteCountFormatter.string(fromByteCount: installed.totalByteCount, countStyle: .file))")
                        }
                        Text(CPUArchitecture.isAppleSilicon
                            ? "Choose the supplied .mlpackage. A copy stays on this Mac and is ready after restarting."
                            : "FluidMeet recording currently requires an Apple silicon Mac.")
                        Text("Model changes are applied immediately, even if you cancel these settings. Importing a model does not start recording.")
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
                if let message {
                    Text(message).font(self.theme.typography.caption).foregroundStyle(self.theme.palette.warning)
                }
            }
        }
        .task {
            let result = await Task.detached(priority: .utility) {
                try? MeetingModelInstaller.validate(MeetingNemotronModelLocator().resolvedPackageURL())
            }.value
            self.installed = result
            self.isBusy = false
        }
    }

    private func choosePackage() {
        guard MeetingNemotronModelLocator().resolvedPackageURL().standardizedFileURL
            == MeetingNemotronModelLocator.defaultPackageURL().standardizedFileURL
        else {
            self.message = "A development model path is active. Remove that override and restart FluidVoice before importing."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Load speaker separation model"
        panel.message = "Choose nemotron_diar_fp16.mlpackage from the beta model download."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        // CoreML package types are not registered on every beta tester's Mac.
        // Let the installer validate the selection instead of greying out valid packages.
        panel.begin { response in
            guard response == .OK, let source = panel.url else { return }
            self.isBusy = true
            self.message = nil
            Task {
                do {
                    self.installed = try await Task.detached(priority: .utility) {
                        try MeetingModelInstaller.install(from: source)
                    }.value
                    // This task outlives the sheet. Refresh only model readiness, even if
                    // the user saved or cancelled settings while the copy was running.
                    self.onModelImported()
                } catch {
                    self.message = error.localizedDescription
                }
                self.isBusy = false
            }
        }
    }
}
