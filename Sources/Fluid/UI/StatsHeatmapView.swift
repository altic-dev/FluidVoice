import SwiftUI

/// Owns its pointer state. Hover never invalidates the parent or any Swift Charts view.
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
            VStack(spacing: 4) {
                Color.clear.frame(height: 16)
                ForEach(0..<7) { row in
                    Text(row.isMultiple(of: 2) ? calendar.shortWeekdaySymbols[(calendar.firstWeekday - 1 + row) % 7] : "")
                        .fluidText(.label)
                        .foregroundStyle(self.theme.look.tertiaryText)
                        .frame(width: 30, height: 16)
                }
            }
            .frame(width: 30)
            GeometryReader { geometry in
                let width = max(2, min(26, (geometry.size.width - CGFloat(max(0, columns.count - 1)) * 4) / CGFloat(max(1, columns.count))))
                HStack(alignment: .top, spacing: 4) {
                    ForEach(columns.indices, id: \.self) { column in
                        VStack(spacing: 4) {
                            Text(period.monthLabel(for: column))
                                .fluidText(.label)
                                .foregroundStyle(self.theme.look.tertiaryText)
                                .fixedSize()
                                .frame(width: width, height: 16, alignment: .leading)
                            ForEach(0..<7) { row in
                                self.dayCell(
                                    columns[column][row],
                                    maximum: period.peakWords,
                                    tooltipAlignment: column < 3 ? .topLeading : (column >= columns.count - 3 ? .topTrailing : .top)
                                )
                                .frame(width: width, height: 16)
                            }
                        }
                        .zIndex(columns[column].contains { $0?.date == self.hoveredDate } ? 1 : 0)
                    }
                }
                // One hover region replaces a tracking region on every day.
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        self.updateHover(at: location, columns: columns, cellWidth: width)
                    case .ended:
                        self.hoveredDate = nil
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

    /// Empty days use the track; busier days use darker steps of the data ink. The legend uses the same steps.
    static func cellColor(_ level: Int, look: AppTheme.Look) -> Color {
        level == 0 ? look.quietFill : look.data.opacity(0.1 + Double(level) * 0.225)
    }
}
