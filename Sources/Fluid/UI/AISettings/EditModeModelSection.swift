import Combine
import SwiftUI

/// The model on this Mac that Edit Mode runs on. This row is where it downloads:
/// nothing downloads when the shortcut is pressed, and API users never see it.
struct EditModeLocalModelRow: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var controller = EditModeModelController.shared

    var body: some View {
        if let model = self.controller.model {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Model")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.theme.palette.primaryText)
                    self.status(for: model)
                }
                Spacer(minLength: 0)
                HStack(spacing: self.theme.metrics.spacing.md) {
                    Text(ModelDisplayName.forID(model.id))
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    self.action(for: model)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .task { await self.controller.refresh() }
        }
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
            Text("Downloaded · On this Mac")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        } else {
            Text("A one-time download. It stays on this Mac.")
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

/// Edit Mode's opt-in and its optional screenshot fallback have separate controls.
struct EditModeScreenContextSettings: View {
    @ObservedObject var settings: SettingsStore
    @StateObject private var permission: DictationScreenPermissionController
    @State private var permissionRequestTask: Task<Void, Never>?

    init(settings: SettingsStore, permission: DictationScreenPermissionController? = nil) {
        self.settings = settings
        self._permission = StateObject(wrappedValue: permission ?? DictationScreenPermissionController())
    }

    var body: some View {
        FluidManagementRow(
            title: "Read my screen",
            detail: "Uses app text, with screen capture as a fallback. Everything stays on this Mac."
        ) {
            HStack(spacing: 12) {
                if self.settings.editModeReadsScreen, self.permission.hasChecked, !self.permission.isAllowed {
                    Button(self.permission.requiresSettings ? "Open System Settings" : "Allow Screen Capture") {
                        self.requestScreenAccess()
                    }
                    .fluidGlassAction()
                    .disabled(self.permission.isRequesting)
                }
                Toggle("Read my screen", isOn: self.enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
        .task { await self.permission.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await self.permission.refresh() }
        }
        .onChange(of: self.settings.editModeReadsScreen) { _, enabled in
            if !enabled { self.permissionRequestTask?.cancel() }
        }
        .onDisappear { self.permissionRequestTask?.cancel() }
    }

    /// Changing the feature preference never prompts or changes dictation's context setting.
    var enabledBinding: Binding<Bool> {
        Binding(
            get: { self.settings.editModeReadsScreen },
            set: { self.settings.editModeReadsScreen = $0 }
        )
    }

    private func requestScreenAccess() {
        guard self.settings.editModeReadsScreen, self.permissionRequestTask == nil else { return }
        if self.permission.requiresSettings {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        self.permissionRequestTask = Task {
            defer { self.permissionRequestTask = nil }
            await self.permission.requestIfNeeded { self.settings.editModeReadsScreen && !Task.isCancelled }
        }
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
