import Foundation
import SQLite3

/// Owned by the history writer's serial queue. One JSON payload per entry, not per history.
final class TranscriptionHistoryDatabase {
    struct Record: Equatable {
        let id: UUID
        let payload: Data
    }

    private let connection: OpaquePointer

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open history."
            if let handle { sqlite3_close(handle) }
            throw NSError(domain: "HistoryDatabase", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
        self.connection = handle
        do {
            try self.execute("PRAGMA busy_timeout=2000")
            try self.execute("PRAGMA journal_mode=WAL")
            try self.execute("PRAGMA synchronous=FULL")
            try self.execute("PRAGMA secure_delete=ON")
            try self.execute("CREATE TABLE IF NOT EXISTS history (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(self.connection) }

    /// Adds legacy entries the database does not have yet. For an id in both, the database copy wins.
    func importLegacy(_ records: [Record]) throws {
        try self.transaction {
            for record in records {
                try self.upsert(record, overwriting: false)
            }
        }
    }

    func read() throws -> [Record] {
        let statement = try self.prepare("SELECT id, payload FROM history")
        defer { sqlite3_finalize(statement) }
        var records: [Record] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return records }
            guard result == SQLITE_ROW,
                  let text = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: text)),
                  let bytes = sqlite3_column_blob(statement, 1)
            else { throw self.error() }
            records.append(Record(id: id, payload: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))))
        }
    }

    func write(upserts: [Record], deletes: [UUID], replacing: Bool) throws {
        try self.transaction {
            if replacing { try self.execute("DELETE FROM history") }
            for id in deletes {
                // UUID's canonical representation contains no SQL metacharacters.
                try self.execute("DELETE FROM history WHERE id='\(id.uuidString)'")
            }
            for record in upserts {
                try self.upsert(record)
            }
        }
    }

    private func upsert(_ record: Record, overwriting: Bool = true) throws {
        let conflict = overwriting ? "REPLACE" : "IGNORE"
        let statement = try self.prepare("INSERT OR \(conflict) INTO history(id,payload) VALUES ('\(record.id.uuidString)',?)")
        defer { sqlite3_finalize(statement) }
        let result = record.payload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard result == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw self.error() }
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

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(self.connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw self.error()
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(self.connection, sql, nil, nil, nil) == SQLITE_OK else { throw self.error() }
    }

    private func error() -> Error {
        NSError(domain: "HistoryDatabase", code: Int(sqlite3_errcode(self.connection)), userInfo: [
            NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(self.connection)),
        ])
    }
}

/// All disk queries and Codable work happen here, including the legacy import.
final class TranscriptionHistoryWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fluid.history.persistence", qos: .utility)
    private var database: TranscriptionHistoryDatabase?
    private var writeError: Error?
    private let defaults: UserDefaults
    private let otherInstallDefaults: [UserDefaults]
    private let url: URL
    private let legacyKey = "TranscriptionHistoryEntries"

    /// `otherInstallDefaults` lists the installs sharing a custom `url`. Release and Debug keep separate
    /// defaults but share the default database and audio folder.
    init(defaults: UserDefaults = .standard, url: URL? = nil, otherInstallDefaults: [UserDefaults] = []) {
        self.defaults = defaults
        self.url = url ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/FluidVoice/TranscriptionHistory.sqlite3")
        self.otherInstallDefaults = url != nil ? otherInstallDefaults : ["com.FluidApp.app", "com.FluidApp.app.debug"]
            .filter { $0 != Bundle.main.bundleIdentifier }
            .compactMap { UserDefaults(suiteName: $0) }
    }

    /// Legacy history left in defaults (unreadable, rewritten during a load, or not yet imported by another
    /// install) is not in the loaded entries.
    var hasUnimportedLegacyHistory: Bool {
        ([self.defaults] + self.otherInstallDefaults).contains { $0.data(forKey: self.legacyKey) != nil }
    }

    func load() async throws -> [TranscriptionHistoryEntry] {
        try await withCheckedThrowingContinuation { continuation in
            self.queue.async {
                do {
                    let database = try self.database ?? TranscriptionHistoryDatabase(url: self.url)
                    self.database = database
                    // The database is shared by every build, while legacy history lives in each
                    // bundle's defaults and older versions write it again after a downgrade.
                    var imported: Data?
                    if let data = self.defaults.data(forKey: self.legacyKey) {
                        do {
                            let legacy = try JSONDecoder().decode([TranscriptionHistoryEntry].self, from: data)
                            try database.importLegacy(legacy.map { try self.record($0) })
                            imported = data
                        } catch let error as DecodingError {
                            // Keep the bytes for recovery, but never let them block saved history.
                            DebugLogger.shared.warning(
                                "Skipped unreadable legacy history (\(data.count) bytes); it was left in place: \(error)",
                                source: "TranscriptionHistoryStore"
                            )
                        }
                    }
                    let entries = try database.read().map {
                        try JSONDecoder().decode(TranscriptionHistoryEntry.self, from: $0.payload)
                    }.sorted { $0.timestamp > $1.timestamp }
                    // The transaction is committed and every payload decoded before retiring legacy storage.
                    // An older app instance may rewrite the key meanwhile, so only retire the bytes that were
                    // imported and leave newer ones for the next load. This narrows the window; it is not
                    // atomic across processes.
                    if let imported, self.defaults.data(forKey: self.legacyKey) == imported {
                        self.defaults.removeObject(forKey: self.legacyKey)
                    }
                    DebugLogger.shared.debug("HISTORY_BENCH loaded entries=\(entries.count) storage=sqlite", source: "TranscriptionHistoryStore")
                    continuation.resume(returning: entries)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func write(
        upserts: [TranscriptionHistoryEntry], deletes: [UUID] = [], replacing: Bool = false,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        self.queue.async {
            let startedAt = ProcessInfo.processInfo.systemUptime
            do {
                guard let database = self.database else {
                    throw NSError(domain: "HistoryDatabase", code: 1, userInfo: [NSLocalizedDescriptionKey: "History is not loaded."])
                }
                let records = try upserts.map { try self.record($0) }
                try database.write(upserts: records, deletes: deletes, replacing: replacing)
                if replacing { self.writeError = nil }
                let finishedAt = ProcessInfo.processInfo.systemUptime
                DebugLogger.shared.debug(
                    "HISTORY_BENCH t=\(finishedAt) background=true upserts=\(upserts.count) deletes=\(deletes.count) " +
                        "replace=\(replacing) bytes=\(records.reduce(0) { $0 + $1.payload.count }) totalMs=\((finishedAt - startedAt) * 1000)",
                    source: "TranscriptionHistoryStore"
                )
                completion(nil)
            } catch {
                self.writeError = error
                completion(error)
            }
        }
    }

    func drain() async -> Error? {
        await withCheckedContinuation { continuation in
            self.queue.async { continuation.resume(returning: self.writeError) }
        }
    }

    private func record(_ entry: TranscriptionHistoryEntry) throws -> TranscriptionHistoryDatabase.Record {
        try TranscriptionHistoryDatabase.Record(id: entry.id, payload: JSONEncoder().encode(entry))
    }
}
