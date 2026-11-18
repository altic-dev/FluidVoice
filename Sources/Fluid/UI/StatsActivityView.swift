import Charts
import SwiftUI

/// Charts consume at most 180 cached daily totals; changing the range never reads history.
/// The pointer state lives in `StatsChartPointer`, which only the charts read, so moving the
/// pointer over a chart redraws that chart and never this view, the calendar or the other cards.
struct StatsActivityView: View {
    let snapshot: StatsSnapshot
    @Environment(\.theme) private var theme
    @State private var days = 180
    @State private var pointer = StatsChartPointer()

    private var period: StatsActivityPeriod {
        StatsActivityPeriod(activity: self.snapshot.dailyWordCounts(days: self.days), calendar: .current)
    }

    var body: some View {
        let period = self.period
        let gap = self.theme.metrics.spacing.lg
        VStack(spacing: gap) {
            self.calendarCard(period)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: gap) {
                    StatsGrowthCard(period: period, pointer: self.pointer).frame(minWidth: 280)
                    StatsRhythmCard(period: period, pointer: self.pointer).frame(minWidth: 240)
                }
                VStack(spacing: gap) {
                    StatsGrowthCard(period: period, pointer: self.pointer)
                    StatsRhythmCard(period: period, pointer: self.pointer)
                }
            }
        }
        .onChange(of: self.days) { _, _ in self.pointer.clear() }
        .onExitCommand { self.pointer.unpin() }
    }

    private func calendarCard(_ period: StatsActivityPeriod) -> some View {
        let look = self.theme.look
        return FluidSurfaceCard(padding: self.theme.metrics.spacing.xl) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A little every day")
                            .fluidText(.itemTitle)
                            .foregroundStyle(look.text)
                        Text("Small moments. A growing habit.")
                            .fluidText(.body)
                            .foregroundStyle(look.secondaryText)
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
                HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.sm) {
                    Text(period.totalWords.formatted())
                        .fluidText(.pageTitle)
                        .foregroundStyle(look.text)
                        .monospacedDigit()
                    Text("words in \(self.days) days")
                        .fluidText(.body)
                        .foregroundStyle(look.secondaryText)
                    Spacer()
                }
                ViewThatFits(in: .horizontal) {
                    if self.days <= 60 {
                        HStack(alignment: .center, spacing: 24) {
                            StatsHeatmapView(period: period).id(self.days)
                                .frame(width: CGFloat(period.weeks.count * 24 + 36))
                            StatsDailyChart(period: period, pointer: self.pointer).frame(minWidth: 180)
                            self.periodHighlights(period)
                        }
                    }
                    HStack(alignment: .center, spacing: 20) {
                        StatsHeatmapView(period: period).id(self.days)
                        self.periodHighlights(period)
                    }
                }
                Text("Hover a square for details.")
                    .fluidText(.label)
                    .foregroundStyle(look.tertiaryText)
                HStack {
                    Text("\(period.activeDays) active days")
                        .foregroundStyle(look.secondaryText)
                    Spacer()
                    Text("Less")
                    ForEach(0..<5) { level in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(StatsHeatmapView.cellColor(level, look: look))
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                    }
                    Text("More")
                }
                .fluidText(.label)
                .foregroundStyle(look.tertiaryText)
                if period.totalWords == 0 {
                    Text("Your first dictation lights up a square. Come back to see your progress grow.")
                        .fluidText(.body)
                        .foregroundStyle(look.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func periodHighlights(_ period: StatsActivityPeriod) -> some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            self.periodMetric("Best day", words: period.peakWords)
            self.periodMetric("Per active day", words: period.totalWords / max(1, period.activeDays))
        }
        .frame(width: 100, alignment: .leading)
    }

    private func periodMetric(_ title: String, words: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .fluidText(.label)
                .foregroundStyle(self.theme.look.secondaryText)
            Text(words.formatted())
                .fluidText(.metric)
                .foregroundStyle(self.theme.look.text)
                .monospacedDigit()
            Text("words")
                .fluidText(.label)
                .foregroundStyle(self.theme.look.tertiaryText)
        }
    }
}

/// Which day or weekday the pointer is on in the activity charts, and which one is pinned.
/// Only the chart views read it. Setters skip unchanged values so a still pointer redraws nothing.
@Observable
final class StatsChartPointer {
    private(set) var hoveredDate: Date?
    private(set) var selectedDate: Date?
    private(set) var hoveredWeekday: String?
    private(set) var pinnedWeekday: String?

    /// The hovered day, else the pinned one.
    var inspectedDate: Date? { self.hoveredDate ?? self.selectedDate }
    /// The hovered weekday, else the pinned one.
    var inspectedWeekday: String? { self.hoveredWeekday ?? self.pinnedWeekday }

    /// Hover (or with `pin`, toggle the pin on) the day under a chart's x position.
    func inspectDate(_ x: CGFloat, proxy: ChartProxy, pin: Bool) {
        guard let date: Date = proxy.value(atX: x) else { return }
        let day = Calendar.current.startOfDay(for: date)
        if pin {
            self.selectedDate = self.selectedDate == day ? nil : day
        } else if self.hoveredDate != day {
            self.hoveredDate = day
        }
    }

    /// Hover (or with `pin`, toggle the pin on) a weekday.
    func inspectWeekday(_ label: String, pin: Bool) {
        if pin {
            self.pinnedWeekday = self.pinnedWeekday == label ? nil : label
        } else if self.hoveredWeekday != label {
            self.hoveredWeekday = label
        }
    }

    func endDateHover() {
        if self.hoveredDate != nil { self.hoveredDate = nil }
    }

    func endWeekdayHover() {
        if self.hoveredWeekday != nil { self.hoveredWeekday = nil }
    }

    /// Escape: drop the pinned day and weekday and the day hover.
    func unpin() {
        if self.selectedDate != nil { self.selectedDate = nil }
        if self.pinnedWeekday != nil { self.pinnedWeekday = nil }
        self.endDateHover()
    }

    /// A new range: forget everything.
    func clear() {
        self.unpin()
        self.endWeekdayHover()
    }

    /// The day nearest the inspected date, if any.
    func inspectedDay(in period: StatsActivityPeriod) -> StatsActivityPeriod.Day? {
        guard let date = self.inspectedDate else { return nil }
        return period.days.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
}

private struct StatsDailyChart: View {
    let period: StatsActivityPeriod
    let pointer: StatsChartPointer
    @Environment(\.theme) private var theme

    var body: some View {
        let inspected = self.pointer.inspectedDate
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            Text(self.pointer.inspectedDay(in: self.period).map { "\($0.date.formatted(.dateTime.month(.abbreviated).day())) · \($0.words.formatted()) words" } ?? "Day by day · hover to explore")
                .fluidText(.label)
                .foregroundStyle(self.theme.look.secondaryText)
            Chart(self.period.days) { day in
                BarMark(x: .value("Date", day.date, unit: .day), y: .value("Words", day.words))
                    .foregroundStyle(self.theme.look.data.opacity(0.7))
                    .cornerRadius(2)
                    .opacity(inspected == nil || day.date == inspected ? 1 : 0.35)
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
            .chartYAxis(.hidden)
            .statsChartInteraction(onInspect: self.pointer.inspectDate, onExit: self.pointer.endDateHover)
            .frame(height: 124)
        }
    }
}

private struct StatsGrowthCard: View {
    let period: StatsActivityPeriod
    let pointer: StatsChartPointer
    @Environment(\.theme) private var theme

    var body: some View {
        let selected = self.pointer.inspectedDay(in: self.period)
        let look = self.theme.look
        FluidSurfaceCard(padding: self.theme.metrics.spacing.xl) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                StatsChartHeading(title: "Words add up", caption: self.caption(selected))
                Chart(self.period.days) { day in
                    AreaMark(x: .value("Date", day.date), y: .value("Words", day.cumulativeWords))
                        .foregroundStyle(look.quietFill)
                    LineMark(x: .value("Date", day.date), y: .value("Words", day.cumulativeWords))
                        .foregroundStyle(look.data)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    if selected?.date == day.date {
                        RuleMark(x: .value("Date", day.date))
                            .foregroundStyle(look.tertiaryText)
                        PointMark(x: .value("Date", day.date), y: .value("Words", day.cumulativeWords))
                            .foregroundStyle(look.data)
                    }
                }
                .statsChartInteraction(onInspect: self.pointer.inspectDate, onExit: self.pointer.endDateHover)
                .chartYScale(domain: 0...max(1, self.period.totalWords))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 150)
                Text("Cumulative words · selected period")
                    .fluidText(.label)
                    .foregroundStyle(look.tertiaryText)
            }
        }
    }

    private func caption(_ day: StatsActivityPeriod.Day?) -> String {
        if let day {
            return "\(day.date.formatted(.dateTime.month(.abbreviated).day())) · \(day.cumulativeWords.formatted()) words so far"
        }
        return "Hover along the curve · click to pin a day"
    }
}

private struct StatsRhythmCard: View {
    let period: StatsActivityPeriod
    let pointer: StatsChartPointer
    @Environment(\.theme) private var theme

    var body: some View {
        let look = self.theme.look
        let inspected = self.pointer.inspectedWeekday
        FluidSurfaceCard(padding: self.theme.metrics.spacing.xl) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                StatsChartHeading(title: "Your weekly rhythm", caption: self.caption(inspected))
                Chart(self.period.weekdays) { day in
                    BarMark(x: .value("Weekday", day.label), y: .value("Average words", day.averageWords))
                        .foregroundStyle(look.data.opacity(day.averageWords == self.period.peakWeekdayAverage ? 1 : 0.35))
                        .cornerRadius(4)
                        .opacity(inspected == nil || day.label == inspected ? 1 : 0.4)
                        .accessibilityLabel(day.fullLabel)
                        .accessibilityValue("\(Int(day.averageWords.rounded())) words per day on average")
                }
                .statsChartInteraction(onInspect: { x, proxy, pin in
                    guard let label: String = proxy.value(atX: x) else { return }
                    self.pointer.inspectWeekday(label, pin: pin)
                }, onExit: self.pointer.endWeekdayHover)
                .chartYScale(domain: 0...max(1, self.period.peakWeekdayAverage))
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 150)
                Text("Average words per weekday · includes quiet days")
                    .fluidText(.label)
                    .foregroundStyle(look.tertiaryText)
            }
        }
    }

    private func caption(_ label: String?) -> String {
        if let day = self.period.weekdays.first(where: { $0.label == label }) {
            return "\(day.fullLabel) · \(Int(day.averageWords.rounded()).formatted()) words per day on average"
        }
        return "Hover a bar to discover your weekly rhythm"
    }
}

/// A chart card's title and the one line under it that follows the pointer.
private struct StatsChartHeading: View {
    let title: String
    let caption: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(self.title)
                .fluidText(.groupTitle)
                .foregroundStyle(self.theme.look.text)
            Text(self.caption)
                .fluidText(.label)
                .foregroundStyle(self.theme.look.secondaryText)
                .lineLimit(1)
        }
    }
}
