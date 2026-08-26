import Foundation
import SQLite3

struct AnalyticsOutboxItem {
    let id: String
    let payload: Data
}

enum AnalyticsDatabaseError: Error {
    case open(String)
    case sqlite(String)
    case invalidPayload
}

/// SQLite aggregates and crash-safe upload outbox.
final class AnalyticsDatabase {
    private let connection: OpaquePointer
    private let distinctID: String
    private let appVersion: String
    private let calendar: Calendar
    private let iso8601 = ISO8601DateFormatter()

    init(url: URL, distinctID: String, appVersion: String, calendar: Calendar = .current) throws {
        self.distinctID = distinctID
        self.appVersion = appVersion
        self.calendar = calendar

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let database { sqlite3_close(database) }
            throw AnalyticsDatabaseError.open(message)
        }
        self.connection = database

        do {
            try self.execute("PRAGMA journal_mode=WAL")
            try self.execute("PRAGMA synchronous=FULL")
            try self.execute("PRAGMA secure_delete=ON")
            try self.execute("PRAGMA auto_vacuum=INCREMENTAL")
            try self.execute("PRAGMA busy_timeout=3000")
            try self.createSchema()
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    deinit {
        sqlite3_close(self.connection)
    }

    func recordActivity(_ kind: AnalyticsActivityKind, at date: Date) throws {
        try self.finalizeDays(before: date)
        try self.transaction {
            try self.enqueueActivityIfNeeded(kind, at: date)
        }
    }

    func recordUsage(
        mode: AnalyticsUsageMode,
        transcriptionModel: AnalyticsModelDescriptor?,
        aiModel: AnalyticsModelDescriptor?,
        at date: Date
    ) throws {
        try self.finalizeDays(before: date)
        let day = self.dayString(date)
        try self.transaction {
            try self.upsertDailyUsage(day: day, mode: mode)
            if let transcriptionModel {
                try self.upsertDailyModelUsage(
                    day: day,
                    role: .transcription,
                    mode: mode,
                    descriptor: transcriptionModel
                )
            }
            if let aiModel {
                try self.upsertDailyModelUsage(
                    day: day,
                    role: .aiPostProcessing,
                    mode: mode,
                    descriptor: aiModel
                )
            }
            try self.enqueueActivityIfNeeded(.coreAction, at: date)
        }
    }

    func recordModelUsage(
        role: AnalyticsModelRole,
        mode: AnalyticsUsageMode,
        descriptor: AnalyticsModelDescriptor,
        at date: Date
    ) throws {
        try self.finalizeDays(before: date)
        try self.transaction {
            try self.upsertDailyModelUsage(day: self.dayString(date), role: role, mode: mode, descriptor: descriptor)
            try self.enqueueActivityIfNeeded(.coreAction, at: date)
        }
    }

    func recordInsertionLatency(
        path: AnalyticsInsertionPath,
        outcome: AnalyticsInsertionOutcome,
        requestMilliseconds: Int,
        readyMilliseconds: Int?,
        toggleStopMilliseconds: Int? = nil,
        at date: Date
    ) throws {
        try self.finalizeDays(before: date)
        let requestMilliseconds = max(0, requestMilliseconds)
        let readyMilliseconds = readyMilliseconds.map { max(0, $0) }
        let readyCount = readyMilliseconds == nil ? 0 : 1
        let readyValue = readyMilliseconds ?? 0
        let day = self.dayString(date)

        try self.transaction {
            try self.run(
                "INSERT INTO daily_insertion_latency (" +
                    "day, delivery_path, outcome, request_count, request_total_ms, request_min_ms, request_max_ms, " +
                    "ready_count, ready_total_ms, ready_min_ms, ready_max_ms" +
                    ") VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?) " +
                    "ON CONFLICT(day, delivery_path, outcome) DO UPDATE SET " +
                    "request_count = request_count + 1, " +
                    "request_total_ms = request_total_ms + excluded.request_total_ms, " +
                    "request_min_ms = MIN(request_min_ms, excluded.request_min_ms), " +
                    "request_max_ms = MAX(request_max_ms, excluded.request_max_ms), " +
                    "ready_count = ready_count + excluded.ready_count, " +
                    "ready_total_ms = ready_total_ms + excluded.ready_total_ms, " +
                    "ready_min_ms = CASE " +
                    "WHEN excluded.ready_count = 0 THEN ready_min_ms " +
                    "WHEN ready_count = 0 THEN excluded.ready_min_ms " +
                    "ELSE MIN(ready_min_ms, excluded.ready_min_ms) END, " +
                    "ready_max_ms = CASE " +
                    "WHEN excluded.ready_count = 0 THEN ready_max_ms " +
                    "WHEN ready_count = 0 THEN excluded.ready_max_ms " +
                    "ELSE MAX(ready_max_ms, excluded.ready_max_ms) END",
                bindings: [
                    .text(day), .text(path.rawValue), .text(outcome.rawValue),
                    .integer(requestMilliseconds), .integer(requestMilliseconds), .integer(requestMilliseconds),
                    .integer(readyCount), .integer(readyValue), .integer(readyValue), .integer(readyValue),
                ]
            )

            if let toggleStopMilliseconds,
               outcome == .dispatched,
               path == .clipboard || path == .clipboardFallback
            {
                let milliseconds = max(0, toggleStopMilliseconds)
                try self.run(
                    "INSERT INTO daily_clipboard_toggle_latency " +
                        "(day, delivery_path, sample_count, total_ms, min_ms, max_ms) " +
                        "VALUES (?, ?, 1, ?, ?, ?) " +
                        "ON CONFLICT(day, delivery_path) DO UPDATE SET " +
                        "sample_count = sample_count + 1, " +
                        "total_ms = total_ms + excluded.total_ms, " +
                        "min_ms = MIN(min_ms, excluded.min_ms), " +
                        "max_ms = MAX(max_ms, excluded.max_ms)",
                    bindings: [
                        .text(day), .text(path.rawValue),
                        .integer(milliseconds), .integer(milliseconds), .integer(milliseconds),
                    ]
                )
            }
        }
    }

    func recordOnboardingStarted(origin: AnalyticsOnboardingOrigin, at date: Date) throws {
        try self.finalizeDays(before: date)
        try self.transaction {
            let flowID = try self.activeOnboardingFlow(origin: origin, at: date)
            let key = "onboarding:\(flowID):started"
            if try self.insertDedupeKey(key, date: date) {
                try self.enqueue(.onboardingStarted, at: date, properties: [
                    "flow_id": flowID,
                    "origin": origin.rawValue,
                ])
            }
            try self.enqueueActivityIfNeeded(.app, at: date)
        }
    }

    func recordOnboardingStepViewed(
        _ step: AnalyticsOnboardingStep,
        origin: AnalyticsOnboardingOrigin,
        at date: Date
    ) throws {
        try self.transaction {
            let flowID = try self.activeOnboardingFlow(origin: origin, at: date)
            let key = "onboarding:\(flowID):viewed:\(step.rawValue)"
            guard try self.insertDedupeKey(key, date: date) else { return }
            try self.enqueue(.onboardingStepViewed, at: date, properties: [
                "flow_id": flowID,
                "origin": origin.rawValue,
                "step": step.rawValue,
            ])
        }
    }

    func recordOnboardingStepCompleted(
        _ step: AnalyticsOnboardingStep,
        outcome: AnalyticsOnboardingOutcome,
        origin: AnalyticsOnboardingOrigin,
        completesFlow: Bool,
        at date: Date
    ) throws {
        try self.transaction {
            let flowID = try self.activeOnboardingFlow(origin: origin, at: date)
            let key = "onboarding:\(flowID):completed:\(step.rawValue)"
            if try self.insertDedupeKey(key, date: date) {
                try self.enqueue(.onboardingStepCompleted, at: date, properties: [
                    "flow_id": flowID,
                    "origin": origin.rawValue,
                    "step": step.rawValue,
                    "outcome": outcome.rawValue,
                ])
            }
            if completesFlow {
                let completionKey = "onboarding:\(flowID):flow_completed"
                if try self.insertDedupeKey(completionKey, date: date) {
                    try self.enqueue(.onboardingCompleted, at: date, properties: [
                        "flow_id": flowID,
                        "origin": origin.rawValue,
                    ])
                }
                try self.run(
                    "UPDATE onboarding_flows SET completed = 1 WHERE flow_id = ?",
                    bindings: [.text(flowID)]
                )
            }
        }
    }

    func recordModelDownloadStarted(
        id: String,
        descriptor: AnalyticsModelDescriptor,
        source: AnalyticsModelDownloadSource,
        at date: Date
    ) throws {
        try self.finalizeDays(before: date)
        try self.transaction {
            let finishKey = "download:\(id):finished"
            if try !self.dedupeKeyExists(finishKey),
               try self.insertDedupeKey("download:\(id):started", date: date)
            {
                try self.run(
                    "INSERT OR IGNORE INTO model_download_attempts " +
                        "(download_id, provider, model, source, started_at) VALUES (?, ?, ?, ?, ?)",
                    bindings: [
                        .text(id), .text(descriptor.provider), .text(descriptor.model),
                        .text(source.rawValue), .double(date.timeIntervalSince1970),
                    ]
                )
                try self.enqueue(.modelDownloadStarted, at: date, properties: [
                    "download_id": id,
                    "provider": descriptor.provider,
                    "model": descriptor.model,
                    "source": source.rawValue,
                ])
            }
            try self.enqueueActivityIfNeeded(.coreAction, at: date)
        }
    }

    func recordModelDownloadFinished(
        id: String,
        descriptor: AnalyticsModelDescriptor,
        source: AnalyticsModelDownloadSource,
        outcome: AnalyticsModelDownloadOutcome,
        duration: TimeInterval?,
        at date: Date
    ) throws {
        try self.transaction {
            guard try self.insertDedupeKey("download:\(id):finished", date: date) else { return }
            if try !self.modelDownloadExists(id: id) {
                let inferredStart = duration.map { date.addingTimeInterval(-max(0, $0)) } ?? date
                _ = try self.insertDedupeKey("download:\(id):started", date: inferredStart)
                try self.enqueue(.modelDownloadStarted, at: inferredStart, properties: [
                    "download_id": id,
                    "provider": descriptor.provider,
                    "model": descriptor.model,
                    "source": source.rawValue,
                ])
            }
            var properties: [String: Any] = [
                "download_id": id,
                "provider": descriptor.provider,
                "model": descriptor.model,
                "source": source.rawValue,
                "outcome": outcome.rawValue,
            ]
            if let duration, duration >= 0 {
                properties["duration_seconds"] = (duration * 10).rounded() / 10
            }
            try self.enqueue(.modelDownloadFinished, at: date, properties: properties)
            try self.run("DELETE FROM model_download_attempts WHERE download_id = ?", bindings: [.text(id)])
        }
    }

    func recoverInterruptedModelDownloads(at date: Date) throws {
        let rows = try self.query(
            "SELECT download_id, provider, model, source FROM model_download_attempts",
            bindings: []
        )
        for row in rows {
            guard row.count == 4 else { continue }
            try self.recordModelDownloadFinished(
                id: row[0],
                descriptor: AnalyticsModelDescriptor(provider: row[1], model: row[2]),
                source: AnalyticsModelDownloadSource(rawValue: row[3]) ?? .automatic,
                outcome: .interrupted,
                duration: nil,
                at: date
            )
        }
    }

    func finalizeDays(before date: Date) throws {
        let today = self.dayString(date)
        let usageRows = try self.query(
            "SELECT day, dictation_count, command_count, edit_count, meeting_count " +
                "FROM daily_usage WHERE day < ? ORDER BY day",
            bindings: [.text(today)]
        )
        let modelRows = try self.query(
            "SELECT day, role, mode, provider, model, use_count FROM daily_model_usage " +
                "WHERE day < ? ORDER BY day, role, mode, provider, model",
            bindings: [.text(today)]
        )
        let insertionRows = try self.query(
            "SELECT day, delivery_path, outcome, request_count, request_total_ms, request_min_ms, " +
                "request_max_ms, ready_count, ready_total_ms, ready_min_ms, ready_max_ms " +
                "FROM daily_insertion_latency WHERE day < ? ORDER BY day, delivery_path, outcome",
            bindings: [.text(today)]
        )
        let clipboardToggleRows = try self.query(
            "SELECT day, delivery_path, sample_count, total_ms, min_ms, max_ms " +
                "FROM daily_clipboard_toggle_latency WHERE day < ? ORDER BY day, delivery_path",
            bindings: [.text(today)]
        )

        guard !usageRows.isEmpty || !modelRows.isEmpty || !insertionRows.isEmpty || !clipboardToggleRows.isEmpty
        else { return }
        try self.transaction {
            for row in usageRows where row.count == 5 {
                try self.enqueue(.usageDailySummary, at: date, properties: [
                    "usage_date": row[0],
                    "dictation_count": Int(row[1]) ?? 0,
                    "command_count": Int(row[2]) ?? 0,
                    "edit_count": Int(row[3]) ?? 0,
                    "meeting_count": Int(row[4]) ?? 0,
                ])
            }
            for row in modelRows where row.count == 6 {
                try self.enqueue(.modelUsageDailySummary, at: date, properties: [
                    "usage_date": row[0],
                    "role": row[1],
                    "mode": row[2],
                    "provider": row[3],
                    "model": row[4],
                    "use_count": Int(row[5]) ?? 0,
                ])
            }
            for row in insertionRows where row.count == 11 {
                let requestCount = Int(row[3]) ?? 0
                let requestTotal = Int(row[4]) ?? 0
                let readyCount = Int(row[7]) ?? 0
                let readyTotal = Int(row[8]) ?? 0
                let toggleRow = clipboardToggleRows.first {
                    $0.count == 6 &&
                        row[2] == AnalyticsInsertionOutcome.dispatched.rawValue &&
                        $0[0] == row[0] &&
                        $0[1] == row[1]
                }
                var properties: [String: Any] = [
                    "latency_date": row[0],
                    "delivery_path": row[1],
                    "outcome": row[2],
                    "request_count": requestCount,
                    "request_total_ms": requestTotal,
                    "request_average_ms": Self.average(total: requestTotal, count: requestCount),
                    "request_min_ms": Int(row[5]) ?? 0,
                    "request_max_ms": Int(row[6]) ?? 0,
                    "ready_count": readyCount,
                ]
                if readyCount > 0 {
                    properties["ready_total_ms"] = readyTotal
                    properties["ready_average_ms"] = Self.average(total: readyTotal, count: readyCount)
                    properties["ready_min_ms"] = Int(row[9]) ?? 0
                    properties["ready_max_ms"] = Int(row[10]) ?? 0
                }
                if let toggleRow {
                    let count = Int(toggleRow[2]) ?? 0
                    let total = Int(toggleRow[3]) ?? 0
                    properties["toggle_stop_to_dispatch_count"] = count
                    properties["toggle_stop_to_dispatch_total_ms"] = total
                    properties["toggle_stop_to_dispatch_average_ms"] = Self.average(total: total, count: count)
                    properties["toggle_stop_to_dispatch_min_ms"] = Int(toggleRow[4]) ?? 0
                    properties["toggle_stop_to_dispatch_max_ms"] = Int(toggleRow[5]) ?? 0
                }
                try self.enqueue(.insertionLatencyDailySummary, at: date, properties: properties)
            }
            try self.run("DELETE FROM daily_usage WHERE day < ?", bindings: [.text(today)])
            try self.run("DELETE FROM daily_model_usage WHERE day < ?", bindings: [.text(today)])
            try self.run("DELETE FROM daily_insertion_latency WHERE day < ?", bindings: [.text(today)])
            try self.run("DELETE FROM daily_clipboard_toggle_latency WHERE day < ?", bindings: [.text(today)])
        }
    }

    func readyOutbox(limit: Int, at date: Date) throws -> [AnalyticsOutboxItem] {
        var statement: OpaquePointer?
        try self.prepare(
            "SELECT event_id, payload FROM outbox " +
                "WHERE next_retry_at <= ? ORDER BY created_at LIMIT ?",
            into: &statement
        )
        defer { sqlite3_finalize(statement) }
        try self.bind([.double(date.timeIntervalSince1970), .integer(limit)], to: statement)

        var items: [AnalyticsOutboxItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: idText)
            let byteCount = Int(sqlite3_column_bytes(statement, 1))
            guard let bytes = sqlite3_column_blob(statement, 1), byteCount > 0 else { continue }
            let payload = Data(bytes: bytes, count: byteCount)
            items.append(AnalyticsOutboxItem(id: id, payload: payload))
        }
        return items
    }

    /// Deletes uploaded events and reclaims their SQLite pages.
    func acknowledgeUploaded(ids: [String], at date: Date) throws {
        guard !ids.isEmpty else { return }
        try self.transaction {
            for id in ids {
                try self.run("DELETE FROM outbox WHERE event_id = ?", bindings: [.text(id)])
            }
            let retentionCutoff = date.addingTimeInterval(-45 * 24 * 60 * 60).timeIntervalSince1970
            try self.run("DELETE FROM event_dedupe WHERE created_at < ?", bindings: [.double(retentionCutoff)])
        }
        try self.purgeDeletedPages()
    }

    func retry(ids: [String], at date: Date) throws {
        for id in ids {
            let attempt = try self.integer(
                "SELECT attempt_count FROM outbox WHERE event_id = ?",
                bindings: [.text(id)]
            ) ?? 0
            let nextAttempt = attempt + 1
            let delay = min(pow(2, Double(min(nextAttempt, 10))) * 5, 60 * 60)
            try self.run(
                "UPDATE outbox SET attempt_count = ?, next_retry_at = ? WHERE event_id = ?",
                bindings: [.integer(nextAttempt), .double(date.timeIntervalSince1970 + delay), .text(id)]
            )
        }
    }

    func discardPermanently(ids: [String]) throws {
        try self.transaction {
            for id in ids {
                try self.run("DELETE FROM outbox WHERE event_id = ?", bindings: [.text(id)])
            }
        }
        try self.purgeDeletedPages()
    }

    func purgeAll() throws {
        try self.transaction {
            try self.execute("DELETE FROM outbox")
            try self.execute("DELETE FROM daily_usage")
            try self.execute("DELETE FROM daily_model_usage")
            try self.execute("DELETE FROM daily_insertion_latency")
            try self.execute("DELETE FROM daily_clipboard_toggle_latency")
            try self.execute("DELETE FROM event_dedupe")
            try self.execute("DELETE FROM onboarding_flows")
            try self.execute("DELETE FROM model_download_attempts")
        }
        try self.purgeDeletedPages()
    }

    private func createSchema() throws {
        try self.execute("""
        CREATE TABLE IF NOT EXISTS outbox (
            event_id TEXT PRIMARY KEY,
            event_name TEXT NOT NULL,
            payload BLOB NOT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            next_retry_at REAL NOT NULL DEFAULT 0,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS outbox_ready ON outbox(next_retry_at, created_at);
        CREATE TABLE IF NOT EXISTS daily_usage (
            day TEXT PRIMARY KEY,
            dictation_count INTEGER NOT NULL DEFAULT 0,
            command_count INTEGER NOT NULL DEFAULT 0,
            edit_count INTEGER NOT NULL DEFAULT 0,
            meeting_count INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS daily_model_usage (
            day TEXT NOT NULL,
            role TEXT NOT NULL,
            mode TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            use_count INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(day, role, mode, provider, model)
        );
        CREATE TABLE IF NOT EXISTS daily_insertion_latency (
            day TEXT NOT NULL,
            delivery_path TEXT NOT NULL,
            outcome TEXT NOT NULL,
            request_count INTEGER NOT NULL DEFAULT 0,
            request_total_ms INTEGER NOT NULL DEFAULT 0,
            request_min_ms INTEGER NOT NULL DEFAULT 0,
            request_max_ms INTEGER NOT NULL DEFAULT 0,
            ready_count INTEGER NOT NULL DEFAULT 0,
            ready_total_ms INTEGER NOT NULL DEFAULT 0,
            ready_min_ms INTEGER NOT NULL DEFAULT 0,
            ready_max_ms INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(day, delivery_path, outcome)
        );
        CREATE TABLE IF NOT EXISTS daily_clipboard_toggle_latency (
            day TEXT NOT NULL,
            delivery_path TEXT NOT NULL,
            sample_count INTEGER NOT NULL DEFAULT 0,
            total_ms INTEGER NOT NULL DEFAULT 0,
            min_ms INTEGER NOT NULL DEFAULT 0,
            max_ms INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(day, delivery_path)
        );
        CREATE TABLE IF NOT EXISTS event_dedupe (
            dedupe_key TEXT PRIMARY KEY,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS onboarding_flows (
            flow_id TEXT PRIMARY KEY,
            origin TEXT NOT NULL,
            created_at REAL NOT NULL,
            completed INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS model_download_attempts (
            download_id TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            source TEXT NOT NULL,
            started_at REAL NOT NULL
        );
        """)
    }

    private func enqueue(_ event: AnalyticsEvent, at date: Date, properties: [String: Any]) throws {
        let eventID = UUID().uuidString.lowercased()
        var approvedProperties = properties
        approvedProperties["distinct_id"] = self.distinctID
        approvedProperties["platform"] = "macos"
        approvedProperties["$os"] = "macOS"
        approvedProperties["app_version"] = self.appVersion
        approvedProperties["schema_version"] = 2

        let payload: [String: Any] = [
            "uuid": eventID,
            "event": event.rawValue,
            "timestamp": self.iso8601.string(from: date),
            "properties": approvedProperties,
        ]
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw AnalyticsDatabaseError.invalidPayload
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        try self.run(
            "INSERT INTO outbox (event_id, event_name, payload, created_at) VALUES (?, ?, ?, ?)",
            bindings: [.text(eventID), .text(event.rawValue), .blob(data), .double(date.timeIntervalSince1970)]
        )
    }

    private func enqueueActivityIfNeeded(_ kind: AnalyticsActivityKind, at date: Date) throws {
        let day = self.dayString(date)
        guard try self.insertDedupeKey("activity:\(day)", date: date) else { return }
        try self.enqueue(.activeUser, at: date, properties: [
            "activity_kind": kind.rawValue,
            "activity_date": day,
        ])
    }

    private func upsertDailyUsage(day: String, mode: AnalyticsUsageMode) throws {
        let column: String
        switch mode {
        case .dictation: column = "dictation_count"
        case .command: column = "command_count"
        case .edit: column = "edit_count"
        case .meeting: column = "meeting_count"
        }
        try self.run(
            "INSERT INTO daily_usage (day, \(column)) VALUES (?, 1) " +
                "ON CONFLICT(day) DO UPDATE SET \(column) = \(column) + 1",
            bindings: [.text(day)]
        )
    }

    private func upsertDailyModelUsage(
        day: String,
        role: AnalyticsModelRole,
        mode: AnalyticsUsageMode,
        descriptor: AnalyticsModelDescriptor
    ) throws {
        try self.run(
            "INSERT INTO daily_model_usage (day, role, mode, provider, model, use_count) " +
                "VALUES (?, ?, ?, ?, ?, 1) ON CONFLICT(day, role, mode, provider, model) " +
                "DO UPDATE SET use_count = use_count + 1",
            bindings: [
                .text(day), .text(role.rawValue), .text(mode.rawValue),
                .text(descriptor.provider), .text(descriptor.model),
            ]
        )
    }

    private func activeOnboardingFlow(origin: AnalyticsOnboardingOrigin, at date: Date) throws -> String {
        if let existing = try self.string(
            "SELECT flow_id FROM onboarding_flows WHERE completed = 0 AND origin = ? " +
                "ORDER BY created_at DESC LIMIT 1",
            bindings: [.text(origin.rawValue)]
        ) {
            return existing
        }
        let flowID = UUID().uuidString.lowercased()
        try self.run(
            "INSERT INTO onboarding_flows (flow_id, origin, created_at) VALUES (?, ?, ?)",
            bindings: [.text(flowID), .text(origin.rawValue), .double(date.timeIntervalSince1970)]
        )
        return flowID
    }

    private func insertDedupeKey(_ key: String, date: Date) throws -> Bool {
        try self.run(
            "INSERT OR IGNORE INTO event_dedupe (dedupe_key, created_at) VALUES (?, ?)",
            bindings: [.text(key), .double(date.timeIntervalSince1970)]
        ) > 0
    }

    private func dedupeKeyExists(_ key: String) throws -> Bool {
        try self.integer(
            "SELECT COUNT(*) FROM event_dedupe WHERE dedupe_key = ?",
            bindings: [.text(key)]
        ) == 1
    }

    private func modelDownloadExists(id: String) throws -> Bool {
        try self.integer(
            "SELECT COUNT(*) FROM model_download_attempts WHERE download_id = ?",
            bindings: [.text(id)]
        ) == 1
    }

    private func dayString(_ date: Date) -> String {
        let components = self.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func average(total: Int, count: Int) -> Double {
        guard count > 0 else { return 0 }
        return (Double(total) / Double(count) * 10).rounded() / 10
    }

    private func purgeDeletedPages() throws {
        try self.execute("PRAGMA incremental_vacuum")
        try self.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    private func transaction(_ body: () throws -> Void) throws {
        try self.execute("BEGIN IMMEDIATE")
        do {
            try body()
            try self.execute("COMMIT")
        } catch {
            try? self.execute("ROLLBACK")
            throw error
        }
    }

    @discardableResult
    private func run(_ sql: String, bindings: [SQLiteBinding] = []) throws -> Int {
        var statement: OpaquePointer?
        try self.prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try self.bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw self.lastError() }
        return Int(sqlite3_changes(self.connection))
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(self.connection, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(errorMessage)
            throw AnalyticsDatabaseError.sqlite(message)
        }
    }

    private func query(_ sql: String, bindings: [SQLiteBinding]) throws -> [[String]] {
        var statement: OpaquePointer?
        try self.prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try self.bind(bindings, to: statement)
        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
            })
        }
        return rows
    }

    private func string(_ sql: String, bindings: [SQLiteBinding]) throws -> String? {
        try self.query(sql, bindings: bindings).first?.first
    }

    private func integer(_ sql: String, bindings: [SQLiteBinding]) throws -> Int? {
        try self.string(sql, bindings: bindings).flatMap(Int.init)
    }

    private func prepare(_ sql: String, into statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(self.connection, sql, -1, &statement, nil) == SQLITE_OK else {
            throw self.lastError()
        }
    }

    private func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer?) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case let .text(value):
                result = sqlite3_bind_text(statement, index, value, -1, transient)
            case let .integer(value):
                result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
            case let .double(value):
                result = sqlite3_bind_double(statement, index, value)
            case let .blob(data):
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
                }
            }
            guard result == SQLITE_OK else { throw self.lastError() }
        }
    }

    private func lastError() -> AnalyticsDatabaseError {
        AnalyticsDatabaseError.sqlite(String(cString: sqlite3_errmsg(self.connection)))
    }
}

private enum SQLiteBinding {
    case text(String)
    case integer(Int)
    case double(Double)
    case blob(Data)
}
