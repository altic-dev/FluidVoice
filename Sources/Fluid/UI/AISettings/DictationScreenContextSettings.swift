import AppKit
import SwiftUI

/// Screen settings for a dictation model trained to read the text around the
/// cursor. Shown only while such a model is selected.
struct DictationScreenContextSettings: View {
    @ObservedObject var settings: SettingsStore
    let isBusy: Bool

    @State private var screenRecordingAllowed = CGPreflightScreenCaptureAccess()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            self.scopeRow
            if self.settings.dictationScreenContextScope != .off {
                self.ocrRow
                if self.settings.dictationScreenContextOCREnabled, !self.screenRecordingAllowed {
                    self.permissionRow
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.screenRecordingAllowed = CGPreflightScreenCaptureAccess()
        }
    }

    private var scopeRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Screen words")
                .font(.fluidSystem(.caption))
                .frame(width: 124, alignment: .leading)

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
            .frame(width: 190)

            Text("Words in the window you dictate into help spell names right. Stays on this Mac.")
                .font(.fluidSystem(.caption2))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
    }

    private var ocrRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Read with OCR")
                .font(.fluidSystem(.caption))
                .frame(width: 124, alignment: .leading)

            Toggle("", isOn: self.ocrBinding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(self.isBusy)
                .help("Reads a screenshot of the front window. Needs Screen Recording.")
                .accessibilityLabel("Read with OCR")

            Text("Reads the front window when the app doesn't share its text. Stays on this Mac.")
                .font(.fluidSystem(.caption2))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
    }

    private var permissionRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Color.clear.frame(width: 124, height: 1)

            Image(systemName: "exclamationmark.triangle.fill")
            Text("Screen Recording isn't allowed yet, so OCR is skipped.")
                .lineLimit(2)

            Button("Open Settings") { self.openScreenRecordingSettings() }
                .fluidButton(.compact, size: .small)

            Spacer(minLength: 0)
        }
        .font(.fluidSystem(.caption))
        .foregroundStyle(.orange)
    }

    private var ocrBinding: Binding<Bool> {
        Binding(
            get: { self.settings.dictationScreenContextOCREnabled },
            set: { isOn in
                self.settings.dictationScreenContextOCREnabled = isOn
                // The only place dictation asks for Screen Recording. Turning
                // OCR off leaves the permission to the user.
                if isOn, !CGPreflightScreenCaptureAccess() {
                    _ = CGRequestScreenCaptureAccess()
                }
                self.screenRecordingAllowed = CGPreflightScreenCaptureAccess()
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
            onGranted: { self.screenRecordingAllowed = true }
        )
    }
}
