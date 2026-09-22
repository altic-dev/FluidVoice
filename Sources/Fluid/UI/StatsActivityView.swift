import Charts
import SwiftUI

/// Charts consume at most 180 cached daily totals; changing the range never reads history.
struct StatsActivityView: View {
    let snapshot: StatsSnapshot
    @Environment(\.theme) private var theme
    @State private var days = 180
    @State private var selectedDate: Date?
    @State private var hoveredDate: Date?
    @State private var hoveredWeekday: String?
    @State private var pinnedWeekday: String?

    private var period: StatsActivityPeriod {
        StatsActivityPeriod(activity: self.snapshot.dailyWordCounts(days: self.days), calendar: .current)
    }

    var body: some View {
        let period = self.period
        VStack(spacing: 16) {
            self.calendarCard(period)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    self.growthCard(period).frame(minWidth: 280)
                    self.rhythmCard(period).frame(minWidth: 240)
                }
                VStack(spacing: 16) {
                    self.growthCard(period)
                    self.rhythmCard(period)
                }
            }
        }
        .onChange(of: self.days) { _, _ in
            self.selectedDate = nil
            self.hoveredDate = nil
            self.hoveredWeekday = nil
            self.pinnedWeekday = nil
        }
        .onExitCommand {
            self.selectedDate = nil
            self.pinnedWeekday = nil
            self.hoveredDate = nil
        }
    }

    private func calendarCard(_ period: StatsActivityPeriod) -> some View {
        ThemedCard(style: .standard, padding: 20, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("A little every day")
                            .font(self.theme.typography.title)
                        Text("Small moments. A growing habit.")
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Menu {
                        Picker("Activity period", selection: self.$days) {
                            Text("30 days").tag(30)
                            Text("60 days").tag(60)
                            Text("3 months").tag(90)
                            Text("6 months").tag(180)
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(self.days == 180 ? "6 months" : (self.days == 90 ? "3 months" : "\(self.days) days"))
                    }
                    .fluidDropdownStyle(fillsWidth: true)
                    .frame(width: 112)
                    .accessibilityLabel("Activity period")
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(period.totalWords.formatted())
                        .font(self.theme.typography.displayTitle)
                        .monospacedDigit()
                    Text("words in \(self.days) days")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                ViewThatFits(in: .horizontal) {
                    if self.days <= 60 {
                        HStack(alignment: .center, spacing: 24) {
                            StatsHeatmapView(period: period).id(self.days)
                                .frame(width: CGFloat(period.weeks.count * 24 + 36))
                            self.dailyChart(period).frame(minWidth: 180)
                            self.periodHighlights(period)
                        }
                    }
                    HStack(alignment: .center, spacing: 20) {
                        StatsHeatmapView(period: period).id(self.days)
                        self.periodHighlights(period)
                    }
                }
                Text("Hover a square for details.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("\(period.activeDays) active days")
                        .font(self.theme.typography.captionStrong)
                    Spacer()
                    Text("Less").font(self.theme.typography.captionSmall)
                    ForEach(0..<5) { level in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(self.cellColor(level))
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                    }
                    Text("More").font(self.theme.typography.captionSmall)
                }
                .foregroundStyle(.secondary)
                if period.totalWords == 0 {
                    Text("Your first dictation lights up a square. Come back to see your progress grow.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func periodHighlights(_ period: StatsActivityPeriod) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            self.periodMetric("Best day", words: period.peakWords)
            self.periodMetric("Per active day", words: period.totalWords / max(1, period.activeDays))
        }
        .frame(width: 100, alignment: .leading)
    }

    private func dailyChart(_ period: StatsActivityPeriod) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.selectedDay(period).map { "\($0.date.formatted(.dateTime.month(.abbreviated).day())) · \($0.words.formatted()) words" } ?? "Day by day · hover to explore")
                .font(self.theme.typography.captionStrong)
                .foregroundStyle(.secondary)
            Chart(period.days) { day in
                BarMark(x: .value("Date", day.date, unit: .day), y: .value("Words", day.words))
                    .foregroundStyle(self.theme.palette.accent.opacity(0.7))
                    .cornerRadius(2)
                    .opacity(self.hoveredDate == nil && self.selectedDate == nil || day.date == (self.hoveredDate ?? self.selectedDate) ? 1 : 0.35)
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
            .chartYAxis(.hidden)
            .statsChartInteraction(onInspect: { x, proxy, pin in self.inspectDate(x, proxy: proxy, pin: pin) }, onExit: { self.hoveredDate = nil })
            .frame(height: 124)
        }
    }

    private func periodMetric(_ title: String, words: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(self.theme.typography.caption)
                .foregroundStyle(.secondary)
            Text(words.formatted())
                .font(self.theme.typography.title)
                .monospacedDigit()
            Text("words")
                .font(self.theme.typography.captionSmall)
                .foregroundStyle(.secondary)
        }
    }

    private func inspectDate(_ x: CGFloat, proxy: ChartProxy, pin: Bool) {
        guard let date: Date = proxy.value(atX: x) else { return }
        let day = Calendar.current.startOfDay(for: date)
        if pin {
            self.selectedDate = self.selectedDate == day ? nil : day
        } else if self.hoveredDate != day {
            self.hoveredDate = day
        }
    }

    private func cellColor(_ level: Int) -> Color {
        level == 0 ? self.theme.palette.primaryText.opacity(0.07) : self.theme.palette.accent.opacity(0.25 + Double(level) * 0.18)
    }

    private func growthCard(_ period: StatsActivityPeriod) -> some View {
        let selected = self.selectedDay(period)
        return ThemedCard(style: .standard, padding: 20, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Words add up").font(self.theme.typography.sectionTitle)
                Text(self.growthCaption(period))
                    .font(self.theme.typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Chart(period.days) { day in
                    AreaMark(x: .value("Date", day.date), y: .value("Words", day.cumulativeWords))
                        .foregroundStyle(LinearGradient(colors: [self.theme.palette.accent.opacity(0.24), self.theme.palette.accent.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Date", day.date), y: .value("Words", day.cumulativeWords))
                        .foregroundStyle(self.theme.palette.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    if selected?.date == day.date {
                        RuleMark(x: .value("Date", day.date))
                            .foregroundStyle(self.theme.palette.secondaryText.opacity(0.4))
                        PointMark(x: .value("Date", day.date), y: .value("Words", day.cumulativeWords))
                            .foregroundStyle(self.theme.palette.accent)
                    }
                }
                .statsChartInteraction(onInspect: { x, proxy, pin in self.inspectDate(x, proxy: proxy, pin: pin) }, onExit: { self.hoveredDate = nil })
                .chartYScale(domain: 0...max(1, period.totalWords))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 150)
                Text("Cumulative words · selected period")
                    .font(self.theme.typography.captionSmall)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func selectedDay(_ period: StatsActivityPeriod) -> StatsActivityPeriod.Day? {
        guard let selectedDate = self.hoveredDate ?? self.selectedDate else { return nil }
        return period.days.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    private func growthCaption(_ period: StatsActivityPeriod) -> String {
        if let day = self.selectedDay(period) {
            return "\(day.date.formatted(.dateTime.month(.abbreviated).day())) · \(day.cumulativeWords.formatted()) words so far"
        }
        return "Hover along the curve · click to pin a day"
    }

    private func weekdayCaption(_ period: StatsActivityPeriod) -> String {
        if let day = period.weekdays.first(where: { $0.label == (self.hoveredWeekday ?? self.pinnedWeekday) }) {
            return "\(day.fullLabel) · \(Int(day.averageWords.rounded()).formatted()) words per day on average"
        }
        return "Hover a bar to discover your weekly rhythm"
    }

    private func rhythmCard(_ period: StatsActivityPeriod) -> some View {
        ThemedCard(style: .standard, padding: 20, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your weekly rhythm").font(self.theme.typography.sectionTitle)
                Text(self.weekdayCaption(period))
                    .font(self.theme.typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Chart(period.weekdays) { day in
                    BarMark(x: .value("Weekday", day.label), y: .value("Average words", day.averageWords))
                        .foregroundStyle(self.theme.palette.accent.opacity(day.averageWords == period.peakWeekdayAverage ? 1 : 0.35))
                        .cornerRadius(4)
                        .opacity(self.hoveredWeekday == nil && self.pinnedWeekday == nil || day.label == (self.hoveredWeekday ?? self.pinnedWeekday) ? 1 : 0.4)
                        .accessibilityLabel(day.fullLabel)
                        .accessibilityValue("\(Int(day.averageWords.rounded())) words per day on average")
                }
                .statsChartInteraction(onInspect: { x, proxy, pin in
                    guard let label: String = proxy.value(atX: x) else { return }
                    if pin {
                        self.pinnedWeekday = self.pinnedWeekday == label ? nil : label
                    } else if self.hoveredWeekday != label {
                        self.hoveredWeekday = label
                    }
                }, onExit: { self.hoveredWeekday = nil })
                .chartYScale(domain: 0...max(1, period.peakWeekdayAverage))
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 150)
                Text("Average words per weekday · includes quiet days")
                    .font(self.theme.typography.captionSmall)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
