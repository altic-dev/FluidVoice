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

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    self.sectionTitle("We collect")
                    self.bullet("App version/build, macOS version, and CPU architecture (arm64 vs Intel).")
                    self.bullet("Feature usage (e.g., dictation/command/write mode usage).")
                    self.bullet("Performance buckets (e.g., latency ranges, duration ranges).")
                    self.bullet("Success/failure flags (e.g., whether transcription produced text).")
                    self.bullet("A random install identifier (not tied to your identity).")

                    self.sectionTitle("We do NOT collect")
                    self.bullet("Any transcription text or audio.")
                    self.bullet("Selected text, rewrite prompts, or AI responses.")
                    self.bullet("Terminal commands or outputs from Command Mode.")
                    self.bullet("Window titles, file names, clipboard contents, or anything you type.")

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
