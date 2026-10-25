import AppKit
import SwiftUI

/// Experimental context settings. Unsupported models never read this context.
struct DictationScreenContextSettings: View {
    @ObservedObject var settings: SettingsStore
    let isBusy: Bool

    @StateObject private var permission = DictationScreenPermissionController()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            self.scopeRow
            if self.settings.dictationScreenContextScope != .off {
                Divider()
                self.ocrRow
                if self.settings.dictationScreenContextOCREnabled, self.permission.hasChecked {
                    Divider()
                    self.permissionRow
                }
            }
        }
        .task { await self.permission.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await self.permission.refresh() }
        }
    }

    private var scopeRow: some View {
        FluidManagementRow(
            title: "Screen words",
            detail: "Words in the window you dictate into help spell names right. Stays on this Mac."
        ) {
            FluidDropdownPicker(
                "Screen words",
                selectedTitle: self.settings.dictationScreenContextScope.displayName,
                selection: self.$settings.dictationScreenContextScope
            ) {
                ForEach(DictationScreenContextScope.allCases, id: \.self) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .fluidDropdownStyle()
            .labelsHidden()
            .disabled(self.isBusy)
            .frame(width: 200)
        }
    }

    private var ocrRow: some View {
        FluidManagementRow(
            title: "Read with OCR",
            detail: "Uses a screenshot when the app doesn't share enough text. Requires Screen Recording permission."
        ) {
            Toggle("Read with OCR", isOn: self.ocrBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(self.isBusy || self.permission.isRequesting)
                .help("Reads a screenshot of the front window. Needs Screen Recording.")
        }
    }

    private var permissionRow: some View {
        FluidManagementRow(
            title: self.permission.isAllowed ? "Screen Recording allowed" : "Screen Recording permission needed",
            detail: self.permission.isAllowed
                ? "Screenshots are processed on this Mac and aren't saved."
                : "Allow access in macOS to use OCR. Dictation still works without it."
        ) {
            if !self.permission.isAllowed {
                Button("Open System Settings") { self.openScreenRecordingSettings() }
                    .fluidGlassAction()
            }
        }
    }

    private var ocrBinding: Binding<Bool> {
        Binding(
            get: { self.settings.dictationScreenContextOCREnabled },
            set: { isOn in
                self.settings.dictationScreenContextOCREnabled = isOn
                // The only place dictation asks for Screen Recording. Turning
                // OCR off leaves the permission to the user.
                if isOn {
                    Task {
                        await self.permission.requestIfNeeded {
                            self.settings.dictationScreenContextOCREnabled && self.settings.dictationScreenContextScope != .off
                        }
                    }
                }
            }
        )
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        PermissionDragGuideController.shared.present(
            instruction: "Drag \(Bundle.main.fluidAppDisplayName) into the Screen & System Audio Recording list as shown",
            settingsPaneURL: url,
            isGranted: { CGPreflightScreenCaptureAccess() },
            onGranted: { Task { await self.permission.refresh() } }
        )
    }
}
