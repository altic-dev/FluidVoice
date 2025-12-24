import SwiftUI

struct AnalyticsPrivacyView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Anonymous Analytics")
                        .font(.system(size: 18, weight: .semibold))
                    Text("What FluidVoice collects when analytics is enabled")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done") { self.dismiss() }
                    .buttonStyle(.bordered)
            }

            Divider().opacity(0.4)

            self.contactInfoView

            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    self.sectionTitle("We collect")
                    self.bullet("Basic app/device info (app version, macOS version, etc.)")
                    self.bullet("Which features were used (for example: dictation, Command Mode etc.)")
                    self.bullet("Approximate ranges only (not exact values), such as duration or word count.")
                    self.bullet("Whether something worked and high-level error info.")

                    self.sectionTitle("We do NOT collect")
                    self.bullet("Any transcription text or audio.")
                    self.bullet("Selected text, rewrite prompts, or AI responses.")
                    self.bullet("Terminal commands or outputs from Command Mode.")
                    self.bullet("Window titles, app names, file names/paths, clipboard contents, or anything you type.")

                    self.sectionTitle("How it’s used")
                    self.bullet("To understand which features are being used and where reliability/performance can be improved.")
                    self.bullet("To measure product health (e.g., active devices, retention) without requiring accounts.")

                    self.sectionTitle("Control")
                    self.bullet("You can disable analytics anytime in Settings → Share Anonymous Analytics.")
                }
                .padding(.vertical, 6)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(self.theme.palette.cardBackground.opacity(0.2))
    }

    private var contactInfoView: some View {
        Text(self.contactInfoText)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(self.theme.palette.accent.opacity(0.3), lineWidth: 1)
            )
    }

    private var contactInfoText: AttributedString {
        var text = AttributedString(
            "If you have any concerns we would love to hear about it, please email alticdev@gmail.com or file an issue in our GitHub."
        )

        if let emailRange = text.range(of: "alticdev@gmail.com") {
            text[emailRange].link = URL(string: "mailto:alticdev@gmail.com")
            text[emailRange].foregroundColor = self.theme.palette.accent
        }

        if let githubRange = text.range(of: "GitHub") {
            text[githubRange].link = URL(string: "https://github.com/altic-dev/FluidVoice")
            text[githubRange].foregroundColor = self.theme.palette.accent
        }

        return text
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(self.theme.palette.accent)
            .padding(.top, 4)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }
}
