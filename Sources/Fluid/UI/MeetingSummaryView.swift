import SwiftUI

struct MeetingSummaryView: View {
    var session: MeetingSession? = nil
    var asrService: ASRService? = nil
    var isQuiescent = true
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            Text("Meeting summaries — coming soon")
                .font(self.theme.typography.bodyStrong)
                .foregroundStyle(self.theme.palette.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text("Temporarily disabled due to summary inaccuracies.")
                .font(self.theme.typography.body)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, self.theme.metrics.spacing.md)
    }
}
