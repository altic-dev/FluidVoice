import SwiftUI

struct AnalyticsPrivacyView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Anonymous Analytics")
                        .font(.fluidSystem(size: 18, weight: .semibold))
                    Text("Daily activity and optional detailed analytics")
                        .font(.fluidSystem(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done") { self.dismiss() }
                    .fluidOutlinedButton()
            }

            Divider().opacity(0.4)

            self.contactInfoView

            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    self.sectionTitle("Always collected")
                    self.bullet("A random installation ID, app version, the operating-system label macOS, and basic hardware info.")
                    self.bullet("One active-use signal per local day after you interact with the app, buffered on this Mac and sent weekly.")
                    self.bullet("Beta builds also send one daily aggregate of ASR and Fluid Intelligence timing distributions, including macOS version. No individual timing samples are sent.")

                    self.sectionTitle("When detailed analytics is enabled")
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
                    self.bullet("Hardware serial numbers, other unique device identifiers, target-app identity, or individual transcription and insertion timings/events.")

                    self.sectionTitle("How it’s used")
                    self.bullet("Daily activity measures active installations and retention without requiring accounts.")
                    self.bullet("Optional detailed analytics helps us understand feature adoption, insertion performance, onboarding completion, and model usage.")
                    self.bullet("Beta timing summaries help us compare ASR and Fluid Intelligence speed across Mac hardware and macOS versions.")

                    self.sectionTitle("Control")
                    self.bullet("You can disable detailed analytics anytime in Settings → Share Detailed Anonymous Analytics.")
                    self.bullet("Disabling detailed analytics securely removes its queued and aggregated data from this Mac. Daily activity and beta timing summaries remain enabled.")
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
            .font(.fluidSystem(size: 13))
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
            .font(.fluidSystem(size: 12, weight: .semibold))
            .foregroundStyle(self.theme.palette.accent)
            .padding(.top, 4)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.fluidSystem(size: 13))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }
}
