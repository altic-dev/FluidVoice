import Combine
import SwiftUI

/// Edit Mode picks its own model, apart from dictation's. When that is the model on
/// this Mac, this is also where it downloads: nothing downloads when the shortcut is
/// pressed. API users never see the download.
struct EditModeModelSection<ModelControls: View>: View {
    let showsLocalModel: Bool
    @ViewBuilder let modelControls: () -> ModelControls
    @Environment(\.theme) private var theme
    @ObservedObject private var controller = EditModeModelController.shared

    var body: some View {
        FluidManagementGroup(title: "Edit Mode") {
            self.modelControls()
            if self.showsLocalModel, let model = self.controller.model {
                Divider()
                HStack(spacing: self.theme.metrics.spacing.lg) {
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                        Text(ModelDisplayName.forID(model.id))
                            .font(self.theme.typography.bodyStrong)
                            .foregroundStyle(self.theme.palette.primaryText)
                        self.status(for: model)
                    }
                    Spacer(minLength: self.theme.metrics.spacing.md)
                    self.action(for: model)
                }
            }
        }
        .task { await self.controller.refresh() }
    }

    @ViewBuilder private func status(for model: PrivateAIRegisteredModel) -> some View {
        if self.controller.downloading {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                ProgressView(value: self.controller.fraction)
                    .frame(maxWidth: 220)
                Text("Downloading · \(Int(self.controller.fraction * 100))%")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .monospacedDigit()
            }
        } else if let error = self.controller.error {
            Text(error)
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else if self.controller.installed {
            Label("Ready · rewrites selected text on this Mac", systemImage: "checkmark.circle.fill")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.success)
        } else {
            Text("Rewrites selected text when you press the Edit Mode shortcut. Stays on this Mac.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func action(for model: PrivateAIRegisteredModel) -> some View {
        if self.controller.downloading {
            Button("Cancel") { self.controller.cancelDownload() }
                .fluidGlassAction()
        } else if self.controller.installed {
            Button("Remove") { self.controller.remove() }
                .fluidGlassAction()
                .disabled(self.controller.removing)
        } else {
            Button(self.downloadTitle(for: model)) { self.controller.download() }
                .fluidGlassAction(prominent: true)
        }
    }

    private func downloadTitle(for model: PrivateAIRegisteredModel) -> String {
        guard let bytes = model.artifact.byteCount else { return "Download" }
        return "Download · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }
}

@MainActor
final class EditModeModelController: ObservableObject {
    static let shared = EditModeModelController()

    let model = CPUArchitecture.isAppleSilicon && PrivateAIProviderFeature.shared.isAvailable
        ? PrivateAIIntegrationService.editModel
        : nil
    @Published private(set) var installed = false
    @Published private(set) var downloading = false
    @Published private(set) var removing = false
    @Published private(set) var fraction = 0.0
    @Published private(set) var error: String?
    private var operation: Task<Void, Never>?

    func refresh() async {
        guard let model else { return }
        self.installed = await Task.detached(priority: .utility) {
            PrivateAIIntegrationService.isModelInstalled(model, useCache: false)
        }.value
    }

    func download() {
        guard let model, !self.downloading else { return }
        self.downloading = true
        self.fraction = 0
        self.error = nil
        self.operation = Task { [weak self] in
            defer {
                self?.downloading = false
                self?.operation = nil
            }
            do {
                _ = try await PrivateAIIntegrationService.prepareModel(model) { [weak self] progress in
                    guard let expected = progress.totalBytesExpected, expected > 0 else { return }
                    let fraction = min(1, Double(progress.totalBytesWritten) / Double(expected))
                    await self?.receive(fraction: fraction)
                }
                await self?.refresh()
            } catch is CancellationError {
                self?.error = nil
            } catch {
                self?.error = Task.isCancelled ? nil : error.localizedDescription
            }
        }
    }

    func cancelDownload() {
        self.operation?.cancel()
    }

    func remove() {
        guard let model, !self.removing else { return }
        self.removing = true
        self.error = nil
        Task { [weak self] in
            defer { self?.removing = false }
            do {
                try await PrivateAIIntegrationService.shared.unloadAndRemoveInstalledModel(model, reason: "Edit Mode model removed")
            } catch {
                self?.error = error.localizedDescription
            }
            await self?.refresh()
        }
    }

    private func receive(fraction: Double) {
        self.fraction = fraction
    }
}
