import SwiftUI

/// One opt-in for local context. Unsupported models never read it.
struct DictationScreenContextSettings: View {
    @ObservedObject var settings: SettingsStore
    let isBusy: Bool

    @StateObject private var permission = DictationScreenPermissionController()

    var body: some View {
        FluidManagementRow(
            title: "Use screen text",
            detail: "Helps FluidVoice make your dictation more accurate. Processed entirely on your device."
        ) {
            Toggle("Use screen text", isOn: self.enabledBinding)
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
