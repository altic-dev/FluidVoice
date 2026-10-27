import Charts
import SwiftUI

/// Lifetime achievements and patterns, derived only from the cached Stats snapshot.
struct StatsHighlightsView: View {
    let snapshot: StatsSnapshot
    @Environment(\.theme) private var theme
    @State private var hoveredApp: String?
    @State private var pinnedApp: String?
    @State private var hoveredHour: Int?
    @State private var pinnedHour: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.sectionHeading("Your next chapter", subtitle: "\(self.snapshot.totalMilestonesAchieved) of 18 milestones reached")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    self.wordMilestone.frame(minWidth: 220)
                    self.sessionMilestone.frame(minWidth: 220)
                    self.streakMilestone.frame(minWidth: 220)
                }
                VStack(spacing: 16) {
                    self.wordMilestone
                    self.sessionMilestone
                    self.streakMilestone
                }
            }
            self.sectionHeading("Made for the way you work", subtitle: "Patterns across your saved history")
                .padding(.top, 8)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    self.appsCard.frame(minWidth: 280)
                    self.hoursCard.frame(minWidth: 300)
                }
                VStack(spacing: 16) {
                    self.appsCard
                    self.hoursCard
                }
            }
            self.sectionHeading("Personal bests", subtitle: "Your standout moments, so far")
                .padding(.top, 8)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    self.longestRecord.frame(minWidth: 220)
                    self.wordsRecord.frame(minWidth: 220)
                    self.sessionsRecord.frame(minWidth: 220)
                }
                VStack(spacing: 16) {
                    self.longestRecord
                    self.wordsRecord
                    self.sessionsRecord
                }
            }
        }
    }

    private func sectionHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(self.theme.typography.sectionTitle)
            Text(subtitle).font(self.theme.typography.caption).foregroundStyle(.secondary)
        }
    }

    private var wordMilestone: some View {
        self.milestoneCard(
            title: "Words spoken",
            icon: "text.word.spacing",
            value: self.snapshot.totalWords,
            unit: "words",
            milestones: self.snapshot.wordMilestones,
            color: self.theme.palette.accent
        )
    }

    private var sessionMilestone: some View {
        self.milestoneCard(
            title: "Ideas captured",
            icon: "waveform",
            value: self.snapshot.totalTranscriptions,
            unit: "dictations",
            milestones: self.snapshot.transcriptionMilestones,
            color: self.theme.palette.success
        )
    }

    private var streakMilestone: some View {
        self.milestoneCard(
            title: "Showing up",
            icon: "flame.fill",
            value: self.snapshot.bestStreak,
            unit: "days in your best streak",
            milestones: self.snapshot.streakMilestones,
            color: self.theme.palette.warning
        )
    }

    private func milestoneCard(
        title: String,
        icon: String,
        value: Int,
        unit: String,
        milestones: [(target: Int, achieved: Bool, label: String)],
        color: Color
    ) -> some View {
        let next = milestones.first { !$0.achieved }
        let target = next?.target ?? milestones.last?.target ?? 1
        let fraction = min(1, max(0, Double(value) / Double(target)))
        return ThemedCard(style: .standard, padding: 20, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(title, systemImage: icon)
                        .font(self.theme.typography.bodySmallStrong)
                    Spacer(minLength: 4)
                    Text("\(milestones.filter(\.achieved).count)/\(milestones.count)")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    self.progressRing(fraction: fraction, color: color, icon: next == nil ? "checkmark" : icon)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(value.formatted())
                            .font(self.theme.typography.title)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(unit)
                            .font(self.theme.typography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(next.map { "Next stop: \($0.label)" } ?? "Every milestone reached")
                        .font(self.theme.typography.bodySmallStrong)
                    Text(next == nil ? "Look how far your voice has taken you." : "\((target - value).formatted()) to go · \(Int(fraction * 100))% there")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(minHeight: 30, alignment: .topLeading)
                }
                HStack(spacing: 5) {
                    ForEach(milestones.indices, id: \.self) { index in
                        let milestone = milestones[index]
                        Capsule()
                            .fill(milestone.achieved ? color : self.theme.palette.primaryText.opacity(0.09))
                            .frame(height: 5)
                            .help("\(milestone.label): \(milestone.achieved ? "reached" : "not reached yet")")
                            .accessibilityLabel("\(milestone.label), \(milestone.achieved ? "reached" : "not reached")")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func progressRing(fraction: Double, color: Color, icon: String) -> some View {
        ZStack {
            Circle().stroke(self.theme.palette.primaryText.opacity(0.08), lineWidth: 6)
            Circle().trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: icon)
                .font(self.theme.typography.titleIcon)
                .foregroundStyle(color)
        }
        .frame(width: 58, height: 58)
        .padding(3)
        .accessibilityHidden(true)
    }

    private var appsCard: some View {
        ThemedCard(style: .standard, padding: 20, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 16) {
                self.sectionHeading("Where your words go", subtitle: self.appCaption)
                if self.snapshot.topAppUsage.isEmpty {
                    Label("Dictate into an app to see it here.", systemImage: "app.dashed")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
                } else {
                    VStack(spacing: 14) {
                        ForEach(self.snapshot.topAppUsage, id: \.name) { app in
                            self.appRow(name: app.name, sessions: app.sessions)
                        }
                    }
                    .frame(minHeight: 220, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func appRow(name: String, sessions: Int) -> some View {
        let share = Double(sessions) / Double(max(1, self.snapshot.totalTranscriptions))
        return Button {
            self.pinnedApp = self.pinnedApp == name ? nil : name
        } label: {
            VStack(spacing: 6) {
                HStack {
                    Text(name).font(self.theme.typography.bodySmallStrong).lineLimit(1)
                    Spacer()
                    Text("\(sessions.formatted()) · \(Int((share * 100).rounded()))%")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(self.theme.palette.primaryText.opacity(0.06))
                        Capsule().fill(self.theme.palette.accent.opacity(0.8))
                            .frame(width: geometry.size.width * share)
                    }
                }
                .frame(height: 6)
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { active in
            if active {
                self.hoveredApp = name
            } else if self.hoveredApp == name {
                self.hoveredApp = nil
            }
        }
        .opacity(self.hoveredApp == nil && self.pinnedApp == nil || name == (self.hoveredApp ?? self.pinnedApp) ? 1 : 0.4)
        .accessibilityElement(children: .combine)
    }

    private var appCaption: String {
        guard let app = self.snapshot.topAppUsage.first(where: { $0.name == (self.hoveredApp ?? self.pinnedApp) }) else {
            return "Hover an app to explore · click to pin"
        }
        return "\(app.name) · \(app.sessions.formatted()) of \(self.snapshot.totalTranscriptions.formatted()) dictations"
    }

    private var hourCaption: String {
        guard let hour = self.hoveredHour ?? self.pinnedHour, self.snapshot.hourlySessions.indices.contains(hour) else {
            return "Hover an hour to explore · click to pin"
        }
        return String(format: "%02d:00–%02d:00", hour, hour + 1) + " · \(self.snapshot.hourlySessions[hour].formatted()) dictations"
    }

    private var hoursCard: some View {
        ThemedCard(style: .standard, padding: 20, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 16) {
                self.sectionHeading("Your golden hour", subtitle: self.hourCaption)
                Chart(Array(self.snapshot.hourlySessions.enumerated()), id: \.offset) { hour, count in
                    BarMark(x: .value("Hour", hour), y: .value("Dictations", count))
                        .foregroundStyle(count > 0 && count == self.snapshot.hourlySessions.max() ? self.theme.palette.warning : self.theme.palette.accent.opacity(0.4))
                        .cornerRadius(3)
                        .opacity(self.hoveredHour == nil && self.pinnedHour == nil || hour == (self.hoveredHour ?? self.pinnedHour) ? 1 : 0.35)
                        .accessibilityLabel("\(hour):00")
                        .accessibilityValue("\(count) dictations")
                }
                .statsChartInteraction(onInspect: { x, proxy, pin in
                    guard let value: Double = proxy.value(atX: x) else { return }
                    let hour = min(23, max(0, Int(value.rounded())))
                    if pin {
                        self.pinnedHour = self.pinnedHour == hour ? nil : hour
                    } else if self.hoveredHour != hour {
                        self.hoveredHour = hour
                    }
                }, onExit: { self.hoveredHour = nil })
                .chartXScale(domain: -1...24)
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18]) { value in
                        AxisValueLabel {
                            if let hour = value.as(Int.self) { Text(String(format: "%02d:00", hour)) }
                        }
                    }
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 140)
                Divider().opacity(0.4)
                HStack(alignment: .top, spacing: 20) {
                    self.smallMetric(value: "\(self.snapshot.aiEnhancementRate)%", title: "AI enhanced", icon: "sparkles")
                    Spacer(minLength: 0)
                    self.smallMetric(value: "\(self.snapshot.averageWordsPerTranscription)", title: "words per dictation", icon: "text.alignleft")
                }
                .frame(minHeight: 47, alignment: .top)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func smallMetric(value: String, title: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(value, systemImage: icon).font(self.theme.typography.bodyStrong)
            Text(title).font(self.theme.typography.caption).foregroundStyle(.secondary)
        }
    }

    private var longestRecord: some View {
        self.recordCard(
            title: "One thought, fully expressed",
            value: self.snapshot.longestTranscriptionWords,
            unit: "words in a single dictation",
            icon: "quote.bubble.fill",
            color: self.theme.palette.accent
        )
    }

    private var wordsRecord: some View {
        self.recordCard(
            title: "Your biggest day",
            value: self.snapshot.mostWordsInDay,
            unit: "words in one day",
            icon: "sun.max.fill",
            color: self.theme.palette.warning
        )
    }

    private var sessionsRecord: some View {
        self.recordCard(
            title: "In the flow",
            value: self.snapshot.mostTranscriptionsInDay,
            unit: "dictations in one day",
            icon: "waveform",
            color: self.theme.palette.success
        )
    }

    private func recordCard(title: String, value: Int, unit: String, icon: String, color: Color) -> some View {
        ThemedCard(style: .standard, padding: 20, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: icon).font(self.theme.typography.titleIcon).foregroundStyle(color)
                    Spacer()
                    Text("PERSONAL BEST").font(self.theme.typography.badge).foregroundStyle(.secondary)
                }
                Text(value.formatted())
                    .font(self.theme.typography.displayTitle)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(self.theme.typography.bodySmallStrong)
                    Text(unit).font(self.theme.typography.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
