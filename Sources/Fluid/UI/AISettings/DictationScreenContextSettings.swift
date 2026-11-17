import SwiftUI

/// One opt-in for local context. Unsupported models never read it.
struct DictationScreenContextSettings: View {
    @Environment(\.theme) private var theme
    @ObservedObject var settings: SettingsStore
    let isBusy: Bool

    @StateObject private var permission: DictationScreenPermissionController
    @State private var permissionRequestTask: Task<Void, Never>?

    init(settings: SettingsStore, isBusy: Bool, permission: DictationScreenPermissionController? = nil) {
        self.settings = settings
        self.isBusy = isBusy
        self._permission = StateObject(wrappedValue: permission ?? DictationScreenPermissionController())
    }

    /// Two rows for a Settings group: the switch, then screen access. The switch row is always
    /// present, so it owns the permission refresh and the request cleanup.
    var body: some View {
        FluidSettingsRow(
            title: "Use my active screen to improve dictation accuracy",
            description: "Off by default. Supported models process screen context on your device. Research preview: review your text before sending; context may cause inaccurate changes."
        ) {
            Toggle("Use my active screen to improve dictation accuracy", isOn: self.enabledBinding)
                .fluidSwitch()
                .disabled(self.isBusy)
        }
        .task { await self.permission.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await self.permission.refresh() }
        }
        .onChange(of: self.isBusy) { _, isBusy in
            if isBusy { self.permissionRequestTask?.cancel() }
        }
        .onDisappear {
            self.permissionRequestTask?.cancel()
        }

        self.permissionRow
    }

    /// The feature switch never requests permission or opens System Settings.
    var enabledBinding: Binding<Bool> {
        Binding(
            get: { self.settings.dictationScreenContextEnabled },
            set: { self.settings.dictationScreenContextEnabled = $0 }
        )
    }

    @ViewBuilder private var permissionRow: some View {
        if !self.permission.hasChecked {
            FluidSettingsRow(title: "Screen access") {
                Text("Checking…")
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.secondaryText)
            }
        } else if self.permission.isAllowed {
            FluidSettingsRow(title: "Screen access") {
                FluidStatusLabel(text: "Allowed")
            }
        } else {
            FluidSettingsRow(
                title: "Screen access",
                description: self.permission.requiresSettings
                    ? "Allow FluidVoice under Screen & System Audio Recording."
                    : "macOS calls this Screen Recording access."
            ) {
                Button(self.permission.requiresSettings ? "Open System Settings" : "Allow screen access") {
                    self.requestScreenAccess()
                }
                .fluidAction()
                .disabled(self.isBusy || self.permission.isRequesting)
            }
        }
    }

    private func requestScreenAccess() {
        guard !self.isBusy, self.permissionRequestTask == nil else { return }
        if self.permission.requiresSettings {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        self.permissionRequestTask = Task {
            defer { self.permissionRequestTask = nil }
            await self.permission.requestIfNeeded { !Task.isCancelled }
        }
    }
}
