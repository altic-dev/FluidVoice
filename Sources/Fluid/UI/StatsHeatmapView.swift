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
                        .font(self.theme.typography.captionSmall)
                        .foregroundStyle(.secondary)
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
                                .font(self.theme.typography.captionSmall)
                                .foregroundStyle(.secondary)
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
            }
            .frame(height: 160)
        }
    }

    @ViewBuilder
    private func dayCell(_ day: StatsActivityPeriod.Day?, maximum: Int, tooltipAlignment: Alignment) -> some View {
        if let day {
            let level = day.words == 0 ? 0 : max(1, min(4, Int(ceil(Double(day.words) / Double(max(1, maximum)) * 4))))
            let highlighted = self.hoveredDate == day.date
            RoundedRectangle(cornerRadius: 3)
                .fill(self.cellColor(level))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(highlighted ? self.theme.palette.primaryText : .clear, lineWidth: 2)
                }
                .contentShape(Rectangle())
                .overlay(alignment: tooltipAlignment) {
                    if self.hoveredDate == day.date {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(self.labels[day.date]?.shortDate ?? "")
                                .font(self.theme.typography.caption)
                                .foregroundStyle(.secondary)
                            Text(self.labels[day.date]?.words ?? "")
                                .font(self.theme.typography.bodySmallStrong)
                        }
                        .padding(10)
                        .background(self.theme.palette.elevatedCardBackground, in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm))
                        .overlay(RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm).strokeBorder(self.theme.palette.cardBorder))
                        .fixedSize()
                        .offset(y: -62)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .zIndex(self.hoveredDate == day.date ? 1 : 0)
                .onHover { hovering in
                    if hovering {
                        self.hoveredDate = day.date
                    } else if self.hoveredDate == day.date {
                        self.hoveredDate = nil
                    }
                }
                .accessibilityLabel(self.labels[day.date]?.accessible ?? "")
                .accessibilityElement(children: .ignore)

        } else {
            Color.clear.accessibilityHidden(true)
        }
    }

    private func cellColor(_ level: Int) -> Color {
        level == 0 ? self.theme.palette.primaryText.opacity(0.07) : self.theme.palette.accent.opacity(0.25 + Double(level) * 0.18)
    }
}
