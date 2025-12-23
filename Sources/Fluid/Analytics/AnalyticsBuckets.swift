import Foundation

enum AnalyticsBuckets {
    static func wordCount(in text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return trimmed
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
    }

    static func bucketWords(_ count: Int) -> String {
        switch count {
        case ...0: return "0"
        case 1...5: return "1-5"
        case 6...20: return "6-20"
        case 21...50: return "21-50"
        case 51...100: return "51-100"
        case 101...300: return "101-300"
        default: return "301+"
        }
    }

    static func bucketSeconds(_ seconds: Double) -> String {
        switch seconds {
        case ..<0.5: return "<0.5s"
        case 0.5..<2: return "0.5-2s"
        case 2..<5: return "2-5s"
        case 5..<15: return "5-15s"
        case 15..<60: return "15-60s"
        default: return "60s+"
        }
    }

    static func bucketMs(_ ms: Double) -> String {
        switch ms {
        case ..<100: return "<100ms"
        case 100..<300: return "100-300ms"
        case 300..<1000: return "300ms-1s"
        case 1000..<3000: return "1-3s"
        case 3000..<10_000: return "3-10s"
        default: return "10s+"
        }
    }
}
