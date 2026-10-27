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
        ThemedCard(style: .prominent, padding: 28, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 24) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 40) {
                        self.headline.frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
                        self.momentum.frame(width: 240)
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        self.headline
                        self.momentum
                    }
                }
                Divider().opacity(0.35)
                self.nextStep
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 6) {
            if self.words > 0, self.savedMinutes > 0 {
                Text(self.savedTime)
                    .font(.fluidSystem(size: 56, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("back in your day.")
                    .font(self.theme.typography.title)
            } else {
                Text(self.words == 0 ? "Great ideas\nstart with a word." : "Look at you go.")
                    .font(self.theme.typography.displayTitle)
                    .fixedSize(horizontal: false, vertical: true)
                Text(self.words == 0 ? "Make a little space for your next big thought." : "\(self.words.formatted()) words captured, without the typing.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var momentum: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(self.theme.typography.titleIcon)
                    .foregroundStyle(self.theme.palette.warning)
                Text("\(self.streak)")
                    .font(self.theme.typography.displayTitle)
                    .monospacedDigit()
                Text("day streak")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(.secondary)
            }
            Text(self.streak == 0 ? "Your next streak starts with today." : "One day at a time. Look how far you've come.")
                .font(self.theme.typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(Array(self.activity.enumerated()), id: \.element.date) { index, day in
                    StatsStreakDay(
                        date: day.date,
                        words: day.words,
                        tooltipAlignment: index < 2 ? .topLeading : (index > 4 ? .topTrailing : .top)
                    )
                }
            }
        }
    }

    private var nextStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(self.nextTarget.map { "You're \(($0 - self.words).formatted()) words from your next win." } ?? "Look how far your voice has taken you today.")
                .font(.fluidSystem(size: 30, weight: .semibold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                Text(self.nextTarget.map { "\(self.words.formatted()) spoken. Let's make it \($0.formatted())." } ?? "\(self.words.formatted()) words spoken. Keep your ideas coming.")
                    .font(self.theme.typography.statement)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text("\(Int(self.progress * 100))%")
                    .font(self.theme.typography.title)
                    .foregroundStyle(self.theme.palette.accent)
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(self.theme.palette.primaryText.opacity(0.08))
                    Capsule()
                        .fill(self.theme.palette.accent.gradient)
                        .frame(width: geometry.size.width * self.progress)
                }
            }
            .frame(height: 14)
            .accessibilityLabel("Today's word milestone")
            .accessibilityValue("\(Int(self.progress * 100)) percent")
            Label("\(self.sessions.formatted()) dictations", systemImage: "waveform")
                .font(self.theme.typography.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }
}

/// Hover changes only an overlay in this cell, never the streak caption or page layout.
private struct StatsStreakDay: View {
    let date: Date
    let words: Int
    let tooltipAlignment: Alignment
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: self.words > 0 ? "checkmark" : "minus")
                .font(self.theme.typography.badge)
                .foregroundStyle(self.words > 0 ? self.theme.palette.accent : self.theme.palette.secondaryText)
                .frame(width: 24, height: 24)
                .background(self.theme.palette.accent.opacity(self.words > 0 ? 0.15 : 0.04), in: Circle())
            Text(self.date.formatted(.dateTime.weekday(.narrow)))
                .font(self.theme.typography.captionSmall)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .overlay(alignment: self.tooltipAlignment) {
            if self.isHovered {
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .foregroundStyle(.secondary)
                    Text("\(self.words.formatted()) words")
                        .font(self.theme.typography.captionStrong)
                }
                .font(self.theme.typography.caption)
                .padding(10)
                .background(self.theme.palette.elevatedCardBackground, in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm))
                .overlay(RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm).strokeBorder(self.theme.palette.cardBorder))
                .fixedSize()
                .offset(y: -60)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .zIndex(self.isHovered ? 1 : 0)
        .onHover { self.isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(self.date.formatted(date: .complete, time: .omitted)), \(self.words) words")
    }
}
