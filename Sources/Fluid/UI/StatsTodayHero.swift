import SwiftUI

struct StatsTodayHero: View {
    let words: Int
    let sessions: Int
    let savedMinutes: Double
    let streak: Int
    let activity: [(date: Date, words: Int)]
    @Environment(\.theme) private var theme

    private var milestone: StatsDailyMilestone { StatsDailyMilestone(words: self.words) }
    private var nextTarget: Int? { self.milestone.nextTarget }
    private var progress: Double { self.milestone.progress }
    private var savedTime: String {
        if self.savedMinutes < 1 { return "< 1 min" }
        if self.savedMinutes < 60 { return "\(Int(self.savedMinutes)) min" }
        return "\(Int(self.savedMinutes) / 60)h \(Int(self.savedMinutes) % 60)m"
    }

    var body: some View {
        let spacing = self.theme.metrics.spacing
        FluidSurfaceCard(padding: spacing.xxl, leads: true) {
            VStack(alignment: .leading, spacing: spacing.xl) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 40) {
                        self.headline.frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
                        self.momentum.frame(width: 240)
                    }
                    VStack(alignment: .leading, spacing: spacing.xl) {
                        self.headline
                        self.momentum
                    }
                }
                FluidHairline()
                self.nextStep
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headline: some View {
        let look = self.theme.look
        return VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
            if self.words > 0, self.savedMinutes > 0 {
                Text(self.savedTime)
                    .fluidText(.pageTitle)
                    .foregroundStyle(look.text)
                    .monospacedDigit()
                Text("back in your day.")
                    .fluidText(.subtitle)
                    .foregroundStyle(look.secondaryText)
            } else {
                Text(self.words == 0 ? "Great ideas\nstart with a word." : "Look at you go.")
                    .fluidText(.pageTitle)
                    .foregroundStyle(look.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(self.words == 0 ? "Make a little space for your next big thought." : "\(self.words.formatted()) words captured, without the typing.")
                    .fluidText(.subtitle)
                    .foregroundStyle(look.secondaryText)
            }
        }
    }

    private var momentum: some View {
        let look = self.theme.look
        return VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.xs + 2) {
                Text("\(self.streak)")
                    .fluidText(.detailTitle)
                    .foregroundStyle(look.text)
                    .monospacedDigit()
                Text("day streak")
                    .fluidText(.body)
                    .foregroundStyle(look.secondaryText)
            }
            Text(self.streak == 0 ? "Your next streak starts with today." : "One day at a time. Look how far you've come.")
                .fluidText(.label)
                .foregroundStyle(look.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: self.theme.metrics.spacing.sm) {
                ForEach(Array(self.activity.enumerated()), id: \.element.date) { index, day in
                    StatsStreakDay(
                        date: day.date,
                        words: day.words,
                        ink: look.aura.color(at: Double(index) / Double(max(1, self.activity.count - 1))),
                        tooltipAlignment: index < 2 ? .topLeading : (index > 4 ? .topTrailing : .top)
                    )
                }
            }
        }
    }

    private var nextStep: some View {
        let look = self.theme.look
        return VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            Text(self.nextTarget.map { "You're \(($0 - self.words).formatted()) words from your next win." } ?? "Look how far your voice has taken you today.")
                .fluidText(.detailTitle)
                .foregroundStyle(look.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                Text(self.nextTarget.map { "\(self.words.formatted()) spoken. Let's make it \($0.formatted())." } ?? "\(self.words.formatted()) words spoken. Keep your ideas coming.")
                    .fluidText(.body)
                    .foregroundStyle(look.secondaryText)
                Spacer(minLength: self.theme.metrics.spacing.md)
                Text("\(Int(self.progress * 100))%")
                    .fluidText(.value)
                    .foregroundStyle(look.text)
                    .monospacedDigit()
            }
            FluidAuraBar(fraction: self.progress)
                .accessibilityLabel("Today's word milestone")
                .accessibilityValue("\(Int(self.progress * 100)) percent")
            Text("\(self.sessions.formatted()) dictations")
                .fluidText(.label)
                .foregroundStyle(look.tertiaryText)
        }
    }
}

/// Hover changes only an overlay in this cell, never the streak caption or page layout.
private struct StatsStreakDay: View {
    let date: Date
    let words: Int
    /// This day's color along the week.
    let ink: Color
    let tooltipAlignment: Alignment
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        let look = self.theme.look
        VStack(spacing: self.theme.metrics.spacing.xs + 2) {
            // A filled circle marks a day you dictated; an empty one a quiet day.
            Circle()
                .fill(self.words > 0 ? self.ink : look.quietFill)
                .frame(width: 12, height: 12)
                .frame(width: 24, height: 24)
            Text(self.date.formatted(.dateTime.weekday(.narrow)))
                .fluidText(.label)
                .foregroundStyle(look.tertiaryText)
        }
        .contentShape(Rectangle())
        .overlay(alignment: self.tooltipAlignment) {
            if self.isHovered {
                StatsTooltip(title: self.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), value: "\(self.words.formatted()) words")
                    .offset(y: -60)
            }
        }
        .zIndex(self.isHovered ? 1 : 0)
        .onHover { self.isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(self.date.formatted(date: .complete, time: .omitted)), \(self.words) words")
    }
}

/// The small label that follows the pointer over a chart square or day: what it is, then its value.
struct StatsTooltip: View {
    @Environment(\.theme) private var theme
    let title: String
    let value: String

    var body: some View {
        let look = self.theme.look
        let shape = RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
            Text(self.title)
                .fluidText(.label)
                .foregroundStyle(look.secondaryText)
            Text(self.value)
                .fluidText(.rowTitle)
                .foregroundStyle(look.text)
        }
        .padding(self.theme.metrics.spacing.sm + 2)
        .background(look.sheet, in: shape)
        .overlay(shape.strokeBorder(look.edge))
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
