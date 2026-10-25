import SwiftUI

/// One opt-in for local context. Unsupported models never read it.
struct DictationScreenContextSettings: View {
    @ObservedObject var settings: SettingsStore
    let isBusy: Bool

    @StateObject private var permission = DictationScreenPermissionController()

    var body: some View {
        FluidManagementRow(
            title: "Screen context",
            detail: "Helps Fluid Intelligence spell names using text from the window you dictate into. Stays on this Mac."
        ) {
            Toggle("Screen context", isOn: self.enabledBinding)
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
