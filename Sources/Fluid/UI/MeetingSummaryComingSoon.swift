import SwiftUI

/// A feature preview, never a fabricated summary of the selected meeting.
struct MeetingSummaryComingSoon: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            Text("Coming soon")
                .fluidText(.label)
                .foregroundStyle(self.theme.look.secondaryText)
                .padding(.horizontal, self.theme.metrics.spacing.sm)
                .padding(.vertical, self.theme.metrics.spacing.xs)
                .background(self.theme.look.text.opacity(0.06), in: Capsule())

            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                Text("Your meeting, summed up.")
                    .font(.system(.title, design: .serif).weight(.medium))
                    .foregroundStyle(self.theme.look.text)
                    .accessibilityAddTraits(.isHeader)
                Text("The recap, the decisions, and the follow-ups—without rereading the transcript.")
                    .fluidText(.body)
                    .foregroundStyle(self.theme.look.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                self.feature("text.alignleft", title: "Catch up quickly", detail: "Get a short recap or a detailed summary of the discussion.")
                FluidHairline()
                self.feature("checkmark.circle", title: "See what was decided", detail: "Find the key decisions and outcomes in one place.")
                FluidHairline()
                self.feature("checklist", title: "Know what happens next", detail: "See action items and who owns them, when mentioned.")
            }
            .padding(self.theme.metrics.spacing.xl)
            .background(self.theme.look.text.opacity(0.025), in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg))

            Label("Private, on-device summaries · English", systemImage: "lock")
                .fluidText(.label)
                .foregroundStyle(self.theme.look.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, self.theme.metrics.spacing.md)
    }

    private func feature(_ icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: self.theme.metrics.spacing.lg) {
            Image(systemName: icon)
                .fluidText(.rowTitle)
                .foregroundStyle(self.theme.look.secondaryText)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                Text(title)
                    .fluidText(.rowTitle)
                    .foregroundStyle(self.theme.look.text)
                Text(detail)
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
