import Foundation

nonisolated enum HistorySearchRevision {
    /// A restore can hand an existing id different text, and the search index only
    /// replaces a row whose revision rose. Bumping past the restored revision, the
    /// indexed one and the wall clock keeps that true whichever backup the text came
    /// from, including one written before this field existed.
    static func afterRestore(restored: UInt64?, indexed: UInt64?, at date: Date = Date()) -> UInt64 {
        let now = UInt64(max(1, date.timeIntervalSince1970 * 1000))
        let base = max(now, restored ?? 1, indexed ?? 1)
        return base == .max ? .max : base + 1
    }
}
