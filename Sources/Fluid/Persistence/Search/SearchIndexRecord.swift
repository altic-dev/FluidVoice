import Foundation

/// The kinds of content the sidebar search indexes in Zeppelin. Each is one
/// record-only namespace, so results are grouped by kind rather than ranked across
/// kinds: BM25 scores from different namespaces are not comparable.
nonisolated enum SearchIndexKind: String, CaseIterable, Sendable {
    case history = "search-history"
    case transcripts = "search-transcripts"
    case chats = "search-chats"
}

/// One row as the index sees it: identity, a revision that rises when the text
/// changes, and the text itself. The stores build these; the index never reads a
/// store directly.
nonisolated struct SearchIndexRecord: Sendable, Equatable {
    let id: UUID
    /// Compared with what the namespace holds. A higher value re-indexes the row.
    /// Immutable kinds use 1; chats use their update time.
    let revision: UInt64
    let timestamp: Date
    let text: String

    init(id: UUID, revision: UInt64 = 1, timestamp: Date, text: String) {
        self.id = id
        self.revision = revision
        self.timestamp = timestamp
        self.text = text
    }

    /// Joins the searchable fields of a row. Empty fields are dropped so they do not
    /// add blank lines to the text.
    static func joined(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

extension TranscriptionHistoryEntry {
    /// What was pasted, plus where. Raw text is left out: the user remembers what
    /// landed in the document, and `processedText` is that text whether or not AI
    /// cleanup ran.
    var searchRecord: SearchIndexRecord {
        SearchIndexRecord(
            id: self.id,
            timestamp: self.timestamp,
            text: SearchIndexRecord.joined([self.processedText, self.appName, self.windowTitle])
        )
    }
}

extension FileTranscriptionEntry {
    /// `text` only. When diarization ran, `text` is already the speaker segments
    /// joined together, so indexing both would count every word twice.
    var searchRecord: SearchIndexRecord {
        SearchIndexRecord(
            id: self.id,
            timestamp: self.timestamp,
            text: SearchIndexRecord.joined([self.fileName, self.text])
        )
    }
}

extension ChatSession {
    /// One record per session. Message ids are regenerated every time a chat is
    /// reloaded, so they cannot be keys; the session id is stable and the persisted
    /// search revision rises on every save regardless of wall-clock corrections.
    ///
    /// Returns `nil` when the session id is not a UUID, which the store never
    /// produces but a hand-edited defaults file could.
    var searchRecord: SearchIndexRecord? {
        guard let id = UUID(uuidString: self.id) else { return nil }
        var parts = [self.title]
        for message in self.messages {
            parts.append(message.content)
            if let command = message.toolCall?.command {
                parts.append(command)
            }
        }
        return SearchIndexRecord(
            id: id,
            revision: self.searchRevision ?? UInt64(max(1, self.updatedAt.timeIntervalSince1970 * 1000)),
            timestamp: self.updatedAt,
            text: SearchIndexRecord.joined(parts)
        )
    }
}
