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
                    self.bullet("A random installation ID, app version, and the operating-system label macOS.")
                    self.bullet("One daily active-use signal after you interact with the app.")
                    self.bullet("Daily totals for Dictation, Command Mode, Edit Mode, and meeting transcription.")
                    self.bullet("Onboarding steps viewed and completed, including skips.")
                    self.bullet("Transcription and AI provider/model identifiers, counted as daily totals.")
                    self.bullet("Model download source, outcome, and download duration.")
                    self.bullet("Daily aggregated insertion timing statistics—including toggle-stop-to-paste-dispatch—split by delivery path and outcome.")

                    self.sectionTitle("We do NOT collect")
                    self.bullet("Any transcription text or audio.")
                    self.bullet("Selected text, rewrite prompts, or AI responses.")
                    self.bullet("Terminal commands or outputs from Command Mode.")
                    self.bullet("Window titles, app names, file names/paths, clipboard contents, or anything you type.")
                    self.bullet("Hardware identifiers, CPU/chip details, target-app identity, or individual insertion timings/events.")

                    self.sectionTitle("How it’s used")
                    self.bullet("To understand feature adoption, insertion performance, onboarding completion, model usage, active installations, and retention without requiring accounts.")

                    self.sectionTitle("Control")
                    self.bullet("You can disable analytics anytime in Settings → Share Anonymous Analytics.")
                    self.bullet("Disabling analytics securely removes all queued and aggregated analytics stored on this Mac.")
                }
                .padding(.vertical, 6)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(self.theme.palette.contentBackground)
    }

    private var contactInfoView: some View {
        Text(self.contactInfoText)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(self.theme.palette.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(self.theme.palette.cardBorder.opacity(0.6), lineWidth: 1)
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
