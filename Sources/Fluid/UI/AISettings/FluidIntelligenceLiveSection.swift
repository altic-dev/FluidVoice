import SwiftUI

/// Retains controller ownership; card inspection never selects or loads a model.
struct FluidIntelligenceLiveSection<Management: View>: View {
    @Environment(\.theme) private var theme
    @ObservedObject var controller: PrivateAISettingsController
    let backendID: String
    let isPrimary: Bool
    let isVerified: Bool
    let makePrimary: () -> Void
    @ViewBuilder let management: () -> Management
    @State private var showsManagement = false
    @State private var pendingDeletion: PrivateAIRegisteredModel?
    @State private var showsDeleteConfirmation = false
    @State private var showsVerificationResult = false
    @State private var verificationError: String?
    @State private var verifiedModelName = ""
    @State private var snapshots: [String: ModelFiles] = [:]
    @State private var recommendedModelID: String?

    private struct ModelFiles: Sendable {
        let installed: Bool
        let removable: Bool
    }

    private struct ReadIdentity: Equatable {
        let selectedID: String
        let backendID: String
        let busy: Bool
    }

    private var models: [PrivateAIRegisteredModel] {
        PrivateAIModelRegistry.modelIDs().compactMap { PrivateAIModelRegistry.model(id: $0) }
    }

    private var readIdentity: ReadIdentity {
        ReadIdentity(selectedID: self.controller.privateAISelectedModelID, backendID: self.backendID, busy: self.controller.isBusy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fluid Intelligence").font(self.theme.typography.title).fontWeight(.semibold)
                    Text("Polish your words. Privately, on your Mac.")
                        .font(self.theme.typography.body).foregroundStyle(self.theme.palette.secondaryText)
                }
                Spacer()
                ProviderDefaultButton(isCurrent: self.isPrimary, isEnabled: self.isVerified && !self.controller.isBusy, action: self.makePrimary)
                Button("Manage", systemImage: "slider.horizontal.3") { self.showsManagement = true }
                    .fluidGlassAction()
            }
            FluidIntelligenceModelCarousel(
                models: self.models,
                previewID: self.controller.previewModelID,
                selectedID: self.controller.privateAISelectedModelID,
                recommendedModelID: self.recommendedModelID,
                onBrowse: self.controller.previewModel
            ) { model in
                self.cardControls(model)
            }
        }
        .padding(20)
        .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: AppTheme.Metrics.Showcase.cardRadius))
        .task {
            let recommendation = await Task.detached(priority: .utility) {
                PrivateAIModelRecommendation.currentModelID
            }.value
            guard !Task.isCancelled else { return }
            self.recommendedModelID = recommendation
        }
        .task(id: self.readIdentity) {
            self.snapshots = [:]
            guard !self.controller.isBusy else { return }
            let identity = self.readIdentity
            let models = self.models
            let files = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: models.map { model in
                    (model.id, ModelFiles(
                        installed: PrivateAIIntegrationService.isModelInstalled(model),
                        removable: PrivateAIIntegrationService.canRemoveInstalledModel(model)
                    ))
                })
            }.value
            guard !Task.isCancelled, identity == self.readIdentity else { return }
            self.snapshots = files
            for model in models {
                self.controller.refreshPrivateAIModelUpdateStatus(model)
            }
        }
        .alert("Delete downloaded model?", isPresented: self.$showsDeleteConfirmation, presenting: self.pendingDeletion) { model in
            Button("Cancel", role: .cancel) { self.pendingDeletion = nil }
            Button("Delete model", role: .destructive) {
                self.controller.deletePrivateAIModel(model)
                self.pendingDeletion = nil
            }
        } message: { model in
            Text("This removes \(model.displayName) from your Mac. You’ll need to download it again to use it. Your dictation history and shortcut settings won’t change.")
        }
        .alert(self.verificationError == nil ? "Model verified" : "Verification failed", isPresented: self.$showsVerificationResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(self.verificationError ?? "\(self.verifiedModelName) is ready to use on your Mac.")
        }
        .sheet(isPresented: self.$showsManagement) {
            FluidManagementSheet(title: "Manage Fluid Intelligence", subtitle: "These settings apply to all Fluid Intelligence models.", symbol: "slider.horizontal.3", close: { self.showsManagement = false }) {
                self.management()
                FluidManagementGroup(title: "Storage") {
                    FluidManagementRow(title: "Downloaded models", detail: "View the model files stored on your Mac.") {
                        Button("Open models folder", systemImage: "folder", action: self.controller.revealPrivateAIModelFolder)
                            .fluidGlassAction()
                    }
                }
            }
        }
    }

    private func cardControls(_ model: PrivateAIRegisteredModel) -> some View {
        let files = self.snapshots[model.id]
        let selected = model.id == self.controller.privateAISelectedModelID
        let active = selected && self.isVerified && self.controller.privateAILoadState.isLoaded(model.id)
        let realUpdate = files?.installed == true && self.controller.privateAIModelUpdateStatusByID[model.id]?.state == .updateAvailable
        return VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(self.theme.palette.cardBorder)
            if files?.installed == false, let bytes = model.artifact.byteCount, bytes > 0 {
                Text("Download · ≈\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            if self.controller.privateAILoadState.isDownloading(model.id) {
                Text(PrivateAIModelDownloadProgressText.detailText(for: self.controller.privateAILoadState.downloadProgress(for: model.id)))
                    .font(self.theme.typography.caption).lineLimit(2)
            } else if self.controller.privateAILoadState.isLoading(model.id) {
                Text("Preparing model…").font(self.theme.typography.caption)
            } else if let failure = self.controller.privateAILoadState.failureMessage(for: model.id) {
                Text(failure).font(self.theme.typography.caption).foregroundStyle(.red).lineLimit(2).help(failure)
            }
            HStack(spacing: 8) {
                if active {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(Color.fluidGreen)
                        .frame(minWidth: 76, minHeight: 24)
                        .accessibilityLabel("Active model")
                } else {
                    Button {
                        guard let files else { return }
                        self.controller.previewModel(model.id)
                        self.controller.usePreviewModel(isInstalled: files.installed, onReady: {})
                    } label: {
                        Text(files?.installed == false ? "Download" : "Activate")
                            .font(self.theme.typography.bodyStrong)
                            .frame(minWidth: 76, minHeight: 24)
                    }
                    .fluidGlassAction(prominent: true)
                    .disabled(self.controller.isBusy || files == nil || (files?.installed == false && !model.canDownload))
                }
                Spacer(minLength: 0)
                FluidModelMetrics(modelID: model.id)
                Menu {
                    if realUpdate {
                        Button("Update model") {
                            self.controller.updatePrivateAIModel(model)
                        }
                        .disabled(!selected || self.controller.isBusy)
                    }
                    Button("Verify model") {
                        self.controller.verifyPrivateAIConnection(model, onCompletion: { error in
                            self.verifiedModelName = model.displayName.replacingOccurrences(of: "Fluid-1", with: "Fluid 1")
                            self.verificationError = error
                            self.showsVerificationResult = true
                        })
                    }
                    .disabled(!selected || files?.installed != true || self.controller.isBusy)
                    if !selected {
                        Text("Activate this model to manage it")
                    }
                    Divider()
                    Button("Delete model…", role: .destructive) {
                        self.pendingDeletion = model
                        self.showsDeleteConfirmation = true
                    }
                    .disabled(!selected || files?.removable != true || self.controller.isBusy)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 32, height: 32)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Options for \(model.displayName)")
            }
        }
    }
}
