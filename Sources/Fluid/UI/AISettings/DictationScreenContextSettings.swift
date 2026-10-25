import SwiftUI

/// One opt-in for local context. Unsupported models never read it.
struct DictationScreenContextSettings: View {
    @ObservedObject var settings: SettingsStore
    let isBusy: Bool

    @StateObject private var permission = DictationScreenPermissionController()

    var body: some View {
        FluidManagementRow(
            title: "Use my active screen to improve dictation accuracy",
            detail: "Supported model: Fluid-1.1 Splash. Everything is processed on your device."
        ) {
            Toggle("Use my active screen to improve dictation accuracy", isOn: self.enabledBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(self.isBusy || self.permission.isRequesting)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { self.settings.dictationScreenContextEnabled },
            set: { isOn in
                self.settings.dictationScreenContextEnabled = isOn
                if isOn {
                    Task {
                        await self.permission.requestIfNeeded {
                            self.settings.dictationScreenContextEnabled
                        }
                    }
                }
            }
        )
    }
}
