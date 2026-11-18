import SwiftUI

/// Owns its pointer state. Hover never invalidates the parent or any Swift Charts view. One hover
/// region covers the whole grid and works out the square under the pointer, so scrolling past the
/// grid hit-tests one region instead of one per day.
struct StatsHeatmapView: View {
    let period: StatsActivityPeriod
    private let labels: [Date: DayLabels]

    private struct DayLabels {
        let shortDate: String
        let accessible: String
        let words: String
    }

    init(period: StatsActivityPeriod) {
        self.period = period
        // Format once when the data/range changes, never while moving between squares.
        self.labels = Dictionary(uniqueKeysWithValues: period.days.map { day in
            (day.date, DayLabels(
                shortDate: day.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                accessible: "\(day.date.formatted(date: .complete, time: .omitted)), \(day.words) words",
                words: "\(day.words.formatted()) words"
            ))
        })
    }

    @Environment(\.theme) private var theme
    @State private var hoveredDate: Date?

    var body: some View {
        self.heatmap(self.period)
            .onDisappear { self.hoveredDate = nil }
    }

    private func heatmap(_ period: StatsActivityPeriod) -> some View {
        let calendar = Calendar.current
        let columns = period.weeks
        return HStack(alignment: .top, spacing: 6) {
            VStack(spacing: Self.gap) {
                Color.clear.frame(height: Self.cellHeight)
                ForEach(0..<7) { row in
                    Text(row.isMultiple(of: 2) ? calendar.shortWeekdaySymbols[(calendar.firstWeekday - 1 + row) % 7] : "")
                        .fluidText(.label)
                        .foregroundStyle(self.theme.look.tertiaryText)
                        .frame(width: 30, height: Self.cellHeight)
                }
            }
            .frame(width: 30)
            GeometryReader { geometry in
                let width = max(2, min(26, (geometry.size.width - CGFloat(max(0, columns.count - 1)) * Self.gap) / CGFloat(max(1, columns.count))))
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(columns.indices, id: \.self) { column in
                        VStack(spacing: Self.gap) {
                            Text(period.monthLabel(for: column))
                                .fluidText(.label)
                                .foregroundStyle(self.theme.look.tertiaryText)
                                .fixedSize()
                                .frame(width: width, height: Self.cellHeight, alignment: .leading)
                            ForEach(0..<7) { row in
                                self.dayCell(
                                    columns[column][row],
                                    maximum: period.peakWords,
                                    tooltipAlignment: column < 3 ? .topLeading : (column >= columns.count - 3 ? .topTrailing : .top)
                                )
                                .frame(width: width, height: Self.cellHeight)
                            }
                        }
                        .zIndex(columns[column].contains { $0?.date == self.hoveredDate } ? 1 : 0)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        self.hover(self.day(at: location, cellWidth: width, columns: columns)?.date)
                    case .ended:
                        self.hover(nil)
                    }
                }
            }
            .frame(height: 160)
        }
    }

    private func updateHover(at location: CGPoint, columns: [[StatsActivityPeriod.Day?]], cellWidth: CGFloat) {
        let columnStep = cellWidth + 4
        let rowStep: CGFloat = 20
        let y = location.y - rowStep
        let column = Int((location.x / columnStep).rounded(.down))
        let row = Int((y / rowStep).rounded(.down))
        let isInsideCell = location.x.truncatingRemainder(dividingBy: columnStep) < cellWidth
            && y.truncatingRemainder(dividingBy: rowStep) < 16
        let date = isInsideCell && y >= 0 && columns.indices.contains(column) && columns[column].indices.contains(row)
            ? columns[column][row]?.date
            : nil
        if self.hoveredDate != date { self.hoveredDate = date }
    }

    @ViewBuilder
    private func dayCell(_ day: StatsActivityPeriod.Day?, maximum: Int, tooltipAlignment: Alignment) -> some View {
        if let day {
            let level = day.words == 0 ? 0 : max(1, min(4, Int(ceil(Double(day.words) / Double(max(1, maximum)) * 4))))
            let highlighted = self.hoveredDate == day.date
            RoundedRectangle(cornerRadius: 3)
                .fill(Self.cellColor(level, look: self.theme.look))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(highlighted ? self.theme.look.text : .clear, lineWidth: 2)
                }
                .overlay(alignment: tooltipAlignment) {
                    if self.hoveredDate == day.date {
                        StatsTooltip(title: self.labels[day.date]?.shortDate ?? "", value: self.labels[day.date]?.words ?? "")
                            .offset(y: -62)
                    }
                }
                .zIndex(self.hoveredDate == day.date ? 1 : 0)
                .accessibilityLabel(self.labels[day.date]?.accessible ?? "")
                .accessibilityElement(children: .ignore)

        } else {
            Color.clear.accessibilityHidden(true)
        }
    }

    /// Space between squares, a square's height (also the month and weekday label rows), and
    /// the distance from one row's top to the next.
    private static let gap: CGFloat = 4
    private static let cellHeight: CGFloat = 16
    private static let rowPitch: CGFloat = cellHeight + gap

    /// The day under a point in the grid. The gaps belong to the square before them, so moving
    /// across the grid never flickers to "nothing hovered".
    private func day(at location: CGPoint, cellWidth: CGFloat, columns: [[StatsActivityPeriod.Day?]]) -> StatsActivityPeriod.Day? {
        let column = Int(location.x / (cellWidth + Self.gap))
        let row = Int((location.y - Self.rowPitch) / Self.rowPitch)
        guard location.y >= Self.rowPitch, columns.indices.contains(column), (0..<7).contains(row) else { return nil }
        return columns[column][row]
    }

    private func hover(_ date: Date?) {
        if self.hoveredDate != date { self.hoveredDate = date }
    }

    /// Empty days use the track; busier days use darker steps of the data ink. The legend uses the same steps.
    static func cellColor(_ level: Int, look: AppTheme.Look) -> Color {
        level == 0 ? look.quietFill : look.data.opacity(0.1 + Double(level) * 0.225)
    }
}
