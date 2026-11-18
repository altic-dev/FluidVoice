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
        let gap = self.theme.metrics.spacing.lg
        VStack(alignment: .leading, spacing: gap) {
            self.sectionHeading("Your next chapter", subtitle: "\(self.snapshot.totalMilestonesAchieved) of 18 milestones reached")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: gap) {
                    self.wordMilestone.frame(minWidth: 220)
                    self.sessionMilestone.frame(minWidth: 220)
                    self.streakMilestone.frame(minWidth: 220)
                }
                VStack(spacing: gap) {
                    self.wordMilestone
                    self.sessionMilestone
                    self.streakMilestone
                }
            }
            self.sectionHeading("Made for the way you work", subtitle: "Patterns across your saved history")
                .padding(.top, self.theme.metrics.spacing.sm)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: gap) {
                    self.appsCard.frame(minWidth: 280)
                    self.hoursCard.frame(minWidth: 300)
                }
                VStack(spacing: gap) {
                    self.appsCard
                    self.hoursCard
                }
            }
            self.sectionHeading("Personal bests", subtitle: "Your standout moments, so far")
                .padding(.top, self.theme.metrics.spacing.sm)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: gap) {
                    self.longestRecord.frame(minWidth: 220)
                    self.wordsRecord.frame(minWidth: 220)
                    self.sessionsRecord.frame(minWidth: 220)
                }
                VStack(spacing: gap) {
                    self.longestRecord
                    self.wordsRecord
                    self.sessionsRecord
                }
            }
        }
    }

    private func sectionHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fluidText(.groupTitle).foregroundStyle(self.theme.look.text)
            Text(subtitle).fluidText(.label).foregroundStyle(self.theme.look.secondaryText)
        }
    }

    private var wordMilestone: some View {
        self.milestoneCard(
            title: "Words spoken",
            icon: "text.word.spacing",
            value: self.snapshot.totalWords,
            unit: "words",
            milestones: self.snapshot.wordMilestones
        )
    }

    private var sessionMilestone: some View {
        self.milestoneCard(
            title: "Ideas captured",
            icon: "waveform",
            value: self.snapshot.totalTranscriptions,
            unit: "dictations",
            milestones: self.snapshot.transcriptionMilestones
        )
    }

    private var streakMilestone: some View {
        self.milestoneCard(
            title: "Showing up",
            icon: "flame.fill",
            value: self.snapshot.bestStreak,
            unit: "days in your best streak",
            milestones: self.snapshot.streakMilestones
        )
    }

    private func milestoneCard(
        title: String,
        icon: String,
        value: Int,
        unit: String,
        milestones: [(target: Int, achieved: Bool, label: String)]
    ) -> some View {
        let next = milestones.first { !$0.achieved }
        let target = next?.target ?? milestones.last?.target ?? 1
        let fraction = min(1, max(0, Double(value) / Double(target)))
        let look = self.theme.look
        let spacing = self.theme.metrics.spacing
        return FluidSurfaceCard(padding: spacing.xl) {
            VStack(alignment: .leading, spacing: spacing.lg) {
                HStack {
                    Text(title)
                        .fluidText(.rowTitle)
                        .foregroundStyle(look.text)
                    Spacer(minLength: spacing.xs)
                    Text("\(milestones.filter(\.achieved).count)/\(milestones.count)")
                        .fluidText(.label)
                        .foregroundStyle(look.tertiaryText)
                }
                HStack(spacing: spacing.lg) {
                    self.progressRing(fraction: fraction, icon: icon)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(value.formatted())
                            .fluidText(.metric)
                            .foregroundStyle(look.text)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(unit)
                            .fluidText(.label)
                            .foregroundStyle(look.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: spacing.xs) {
                    Text(next.map { "Next stop: \($0.label)" } ?? "Every milestone reached")
                        .fluidText(.rowTitle)
                        .foregroundStyle(look.text)
                    Text(next == nil ? "Look how far your voice has taken you." : "\((target - value).formatted()) to go · \(Int(fraction * 100))% there")
                        .fluidText(.label)
                        .foregroundStyle(look.secondaryText)
                        .lineLimit(2)
                        .frame(minHeight: 30, alignment: .topLeading)
                }
                HStack(spacing: 5) {
                    ForEach(milestones.indices, id: \.self) { index in
                        let milestone = milestones[index]
                        Capsule()
                            .fill(milestone.achieved ? look.data : look.quietFill)
                            .frame(height: 5)
                            .help("\(milestone.label): \(milestone.achieved ? "reached" : "not reached yet")")
                            .accessibilityLabel("\(milestone.label), \(milestone.achieved ? "reached" : "not reached")")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// How close the next milestone is. The symbol says which kind of milestone it is.
    private func progressRing(fraction: Double, icon: String) -> some View {
        let look = self.theme.look
        return ZStack {
            Circle().stroke(look.quietFill, lineWidth: 6)
            Circle().trim(from: 0, to: fraction)
                .stroke(look.data, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: icon)
                .font(.fluidSystem(size: 18, weight: .medium))
                .foregroundStyle(look.secondaryText)
        }
        .frame(width: 58, height: 58)
        .padding(3)
        .accessibilityHidden(true)
    }

    private var appsCard: some View {
        FluidSurfaceCard(padding: self.theme.metrics.spacing.xl) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                self.sectionHeading("Where your words go", subtitle: self.appCaption)
                if self.snapshot.topAppUsage.isEmpty {
                    Text("Dictate into an app to see it here.")
                        .fluidText(.body)
                        .foregroundStyle(self.theme.look.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
                } else {
                    VStack(spacing: self.theme.metrics.spacing.md) {
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
            VStack(spacing: self.theme.metrics.spacing.xs + 2) {
                HStack {
                    Text(name).fluidText(.rowTitle).foregroundStyle(self.theme.look.text).lineLimit(1)
                    Spacer()
                    Text("\(sessions.formatted()) · \(Int((share * 100).rounded()))%")
                        .fluidText(.label)
                        .foregroundStyle(self.theme.look.secondaryText)
                        .monospacedDigit()
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(self.theme.look.quietFill)
                        Capsule().fill(self.theme.look.data)
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
        FluidSurfaceCard(padding: self.theme.metrics.spacing.xl) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                self.sectionHeading("Your golden hour", subtitle: self.hourCaption)
                Chart(Array(self.snapshot.hourlySessions.enumerated()), id: \.offset) { hour, count in
                    BarMark(x: .value("Hour", hour), y: .value("Dictations", count))
                        .foregroundStyle(self.theme.look.data.opacity(count > 0 && count == self.snapshot.hourlySessions.max() ? 1 : 0.35))
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
                FluidHairline()
                HStack(alignment: .top, spacing: self.theme.metrics.spacing.xl) {
                    self.smallMetric(value: "\(self.snapshot.aiEnhancementRate)%", title: "AI enhanced")
                    Spacer(minLength: 0)
                    self.smallMetric(value: "\(self.snapshot.averageWordsPerTranscription)", title: "words per dictation")
                }
                .frame(minHeight: 47, alignment: .top)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func smallMetric(value: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).fluidText(.value).foregroundStyle(self.theme.look.text).monospacedDigit()
            Text(title).fluidText(.label).foregroundStyle(self.theme.look.secondaryText)
        }
    }

    private var longestRecord: some View {
        self.recordCard(
            title: "One thought, fully expressed",
            value: self.snapshot.longestTranscriptionWords,
            unit: "words in a single dictation"
        )
    }

    private var wordsRecord: some View {
        self.recordCard(
            title: "Your biggest day",
            value: self.snapshot.mostWordsInDay,
            unit: "words in one day"
        )
    }

    private var sessionsRecord: some View {
        self.recordCard(
            title: "In the flow",
            value: self.snapshot.mostTranscriptionsInDay,
            unit: "dictations in one day"
        )
    }

    /// One record. The section title already says these are personal bests, so the card doesn't.
    private func recordCard(title: String, value: Int, unit: String) -> some View {
        let look = self.theme.look
        return FluidSurfaceCard(padding: self.theme.metrics.spacing.xl) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                Text(value.formatted())
                    .fluidText(.pageTitle)
                    .foregroundStyle(look.text)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fluidText(.rowTitle).foregroundStyle(look.text)
                    Text(unit).fluidText(.label).foregroundStyle(look.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
