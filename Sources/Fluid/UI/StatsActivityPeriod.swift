import Foundation

/// Pure projections of the bounded snapshot. No settings, persistence, or timers.
nonisolated struct StatsActivityPeriod {
    struct Day: Identifiable {
        var id: Date { self.date }
        let date: Date
        let words: Int
        let cumulativeWords: Int
    }

    struct Weekday: Identifiable {
        let id: Int
        let label: String
        let fullLabel: String
        let averageWords: Double
    }

    let days: [Day]
    let weeks: [[Day?]]
    let weekdays: [Weekday]
    let totalWords: Int
    let activeDays: Int
    let peakWords: Int
    let calendar: Calendar

    var peakWeekdayAverage: Double { self.weekdays.map(\.averageWords).max() ?? 0 }
    var strongestWeekday: String? {
        guard self.peakWeekdayAverage > 0 else { return nil }
        return self.weekdays.first { $0.averageWords == self.peakWeekdayAverage }?.fullLabel
    }

    init(activity: [(date: Date, words: Int)], calendar: Calendar) {
        self.calendar = calendar
        var total = 0
        var weekdayWords = Array(repeating: 0, count: 7)
        var weekdayCounts = Array(repeating: 0, count: 7)
        self.days = activity.map { item in
            total += item.words
            let weekday = calendar.component(.weekday, from: item.date) - 1
            weekdayWords[weekday] += item.words
            weekdayCounts[weekday] += 1
            return Day(date: item.date, words: item.words, cumulativeWords: total)
        }
        self.totalWords = total
        self.activeDays = activity.filter { $0.words > 0 }.count
        self.peakWords = activity.map(\.words).max() ?? 0
        self.weekdays = (0..<7).map { offset in
            let index = (calendar.firstWeekday - 1 + offset) % 7
            return Weekday(
                id: index,
                label: calendar.shortWeekdaySymbols[index],
                fullLabel: calendar.weekdaySymbols[index],
                averageWords: weekdayCounts[index] == 0 ? 0 : Double(weekdayWords[index]) / Double(weekdayCounts[index])
            )
        }
        var cells: [Day?] = []
        if let first = activity.first {
            let leading = (calendar.component(.weekday, from: first.date) - calendar.firstWeekday + 7) % 7
            cells = Array(repeating: nil, count: leading)
        }
        cells.append(contentsOf: self.days.map(Optional.some))
        while !cells.count.isMultiple(of: 7) {
            cells.append(nil)
        }
        self.weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<($0 + 7)]) }
    }

    func monthLabel(for column: Int) -> String {
        guard self.weeks.indices.contains(column),
              let firstOfMonth = self.weeks[column].compactMap({ $0 }).first(where: { self.calendar.component(.day, from: $0.date) == 1 })
        else { return "" }
        return self.calendar.shortMonthSymbols[self.calendar.component(.month, from: firstOfMonth.date) - 1]
    }
}

/// Today's targets advance from the live word count, with no persisted goal state.
nonisolated struct StatsDailyMilestone {
    private static let targets = [100, 250, 500, 1000, 2500, 5000, 10_000, 25_000]
    let words: Int

    init(words: Int) { self.words = max(0, words) }

    var nextTarget: Int? { Self.targets.first { $0 > self.words } }
    var reachedTarget: Int? { Self.targets.last { $0 <= self.words } }
    var remaining: Int { self.nextTarget.map { $0 - self.words } ?? 0 }
    var progress: Double { min(1, Double(self.words) / Double(self.nextTarget ?? max(1, self.words))) }
}
