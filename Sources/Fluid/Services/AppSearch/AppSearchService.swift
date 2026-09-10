import Combine
import Foundation
import ZeppelinEmbed

/// The sections a search result can belong to, in the order groups are shown.
nonisolated enum AppSearchKind: CaseIterable, Sendable {
    case history, transcripts, chats, dictionary, prompts, vocabulary, punctuation, settings

    var title: String {
        switch self {
        case .history: "History"
        case .transcripts: "Transcripts"
        case .chats: "Chats"
        case .dictionary: "Dictionary"
        case .prompts: "Prompts"
        case .vocabulary: "Vocabulary"
        case .punctuation: "Punctuation"
        case .settings: "Settings"
        }
    }
}

nonisolated struct AppSearchHit: Identifiable, Equatable, Sendable {
    /// What to open when the row is chosen.
    enum Target: Hashable, Sendable {
        case history(UUID)
        case transcript(UUID)
        case chat(String)
        case dictionaryEntry(UUID)
        case prompt(String)
        case vocabulary(String)
        case punctuation(UUID)
        case settings(SettingsSearchTarget)
    }

    let kind: AppSearchKind
    let target: Target
    let title: String
    let snippet: AttributedString
    let date: Date?

    var id: Target {
        self.target
    }
}

nonisolated struct AppSearchGroup: Identifiable, Equatable, Sendable {
    let kind: AppSearchKind
    let hits: [AppSearchHit]

    var id: AppSearchKind {
        self.kind
    }
}

/// Turns the sidebar query into grouped results.
///
/// The big three kinds are asked of the Zeppelin index; the short lists are matched
/// in memory. Groups are the ranking: a BM25 score from one namespace means nothing
/// next to one from another, so hits are never merged across kinds.
@MainActor
final class AppSearchService: ObservableObject {
    static let shared = AppSearchService()

    /// Hits fetched per indexed kind. The UI shows a few and offers the rest.
    static let limit = 50
    static let debounce: Duration = .milliseconds(80)

    @Published var query = "" {
        didSet {
            if self.query != oldValue {
                self.schedule()
            }
        }
    }

    @Published private(set) var groups: [AppSearchGroup] = []

    private let index: SearchIndex
    private var task: Task<Void, Never>?
    private var token: ZeppelinCancellationToken?

    init(index: SearchIndex = .shared) {
        self.index = index
    }

    /// Re-runs the current query. Called when the index changes under it.
    func refresh() {
        self.schedule()
    }

    private func schedule() {
        self.task?.cancel()
        if let token = self.token {
            self.token = nil
            Task { try? await token.cancel() }
        }
        let query = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            self.groups = []
            return
        }
        self.groups = []
        self.task = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            let groups = await self.search(query)
            // A newer keystroke cancelled this task while it was waiting on the
            // index; its answer would overwrite a fresher one.
            guard !Task.isCancelled else { return }
            self.groups = groups
        }
    }

    func search(_ query: String) async -> [AppSearchGroup] {
        let token = try? await ZeppelinCancellationToken.create()
        self.token = token

        async let history = self.hits(.history, query, token)
        async let transcripts = self.hits(.transcripts, query, token)
        async let chats = self.hits(.chats, query, token)
        let indexed = await [
            self.historyGroup(history, query),
            self.transcriptGroup(transcripts, query),
            self.chatGroup(chats, query),
        ]
        let inMemory = [
            self.dictionaryGroup(query),
            self.promptGroup(query),
            self.vocabularyGroup(query),
            self.punctuationGroup(query),
            self.settingsGroup(query),
        ]
        return (indexed + inMemory).filter { !$0.hits.isEmpty }
    }

    private func hits(
        _ kind: SearchIndexKind,
        _ query: String,
        _ token: ZeppelinCancellationToken?
    ) async -> [SearchIndex.Hit] {
        do {
            return try await self.index.query(kind, text: query, limit: Self.limit, cancellationToken: token)
        } catch {
            if !Task.isCancelled {
                DebugLogger.shared.warning("Search \(kind.rawValue) failed: \(error)", source: "AppSearch")
            }
            return []
        }
    }

    // MARK: - Indexed kinds

    /// Score first, newest breaks ties. Rows the store no longer has are dropped.
    nonisolated static func ranked<Row>(
        _ hits: [SearchIndex.Hit],
        rows: [UUID: Row],
        date: (Row) -> Date,
        hit: (Row) -> AppSearchHit
    ) -> [AppSearchHit] {
        hits
            .compactMap { found in rows[found.id].map { (score: found.score, row: $0) } }
            .sorted { lhs, rhs in
                lhs.score == rhs.score ? date(lhs.row) > date(rhs.row) : lhs.score > rhs.score
            }
            .map { hit($0.row) }
    }

    private func historyGroup(_ hits: [SearchIndex.Hit], _ query: String) -> AppSearchGroup {
        let rows = Dictionary(TranscriptionHistoryStore.shared.entries.map { ($0.id, $0) }) { first, _ in first }
        return AppSearchGroup(kind: .history, hits: Self.ranked(hits, rows: rows, date: \.timestamp) { entry in
            AppSearchHit(
                kind: .history,
                target: .history(entry.id),
                title: Self.firstLine(entry.processedText),
                snippet: AppSearchSnippet.make(entry.searchRecord.text, query: query),
                date: entry.timestamp
            )
        })
    }

    private func transcriptGroup(_ hits: [SearchIndex.Hit], _ query: String) -> AppSearchGroup {
        let rows = Dictionary(FileTranscriptionHistoryStore.shared.entries.map { ($0.id, $0) }) { first, _ in first }
        return AppSearchGroup(kind: .transcripts, hits: Self.ranked(hits, rows: rows, date: \.timestamp) { entry in
            AppSearchHit(
                kind: .transcripts,
                target: .transcript(entry.id),
                title: entry.fileName,
                snippet: AppSearchSnippet.make(entry.text, query: query),
                date: entry.timestamp
            )
        })
    }

    private func chatGroup(_ hits: [SearchIndex.Hit], _ query: String) -> AppSearchGroup {
        let rows = Dictionary(
            ChatHistoryStore.shared.sessions.compactMap { session in UUID(uuidString: session.id).map { ($0, session) } }
        ) { first, _ in first }
        return AppSearchGroup(kind: .chats, hits: Self.ranked(hits, rows: rows, date: \.updatedAt) { session in
            AppSearchHit(
                kind: .chats,
                target: .chat(session.id),
                title: session.title,
                snippet: AppSearchSnippet.make(session.searchRecord?.text ?? session.title, query: query),
                date: session.updatedAt
            )
        })
    }

    // MARK: - In-memory kinds

    /// Every query word appears somewhere in the row, case-insensitively. The last
    /// word matches by prefix here for free, because `contains` does.
    nonisolated static func matches(_ query: String, _ fields: [String]) -> Bool {
        let haystack = fields.joined(separator: "\n")
        return AppSearchSnippet.words(in: query).allSatisfy {
            haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private func dictionaryGroup(_ query: String) -> AppSearchGroup {
        let hits = SettingsStore.shared.customDictionaryEntries
            .filter { Self.matches(query, $0.triggers + [$0.replacement]) }
            .map { entry in
                AppSearchHit(
                    kind: .dictionary,
                    target: .dictionaryEntry(entry.id),
                    title: entry.replacement,
                    snippet: AppSearchSnippet.make(entry.triggers.joined(separator: ", "), query: query),
                    date: nil
                )
            }
        return AppSearchGroup(kind: .dictionary, hits: hits)
    }

    private func promptGroup(_ query: String) -> AppSearchGroup {
        let hits = SettingsStore.shared.dictationPromptProfiles
            .filter { Self.matches(query, [$0.name, $0.prompt]) }
            .map { profile in
                AppSearchHit(
                    kind: .prompts,
                    target: .prompt(profile.id),
                    title: profile.name,
                    snippet: AppSearchSnippet.make(profile.prompt, query: query),
                    date: profile.updatedAt
                )
            }
        return AppSearchGroup(kind: .prompts, hits: hits)
    }

    private func vocabularyGroup(_ query: String) -> AppSearchGroup {
        let terms = (try? ParakeetVocabularyStore.shared.loadUserBoostTerms()) ?? []
        let hits = terms
            .filter { Self.matches(query, [$0.text] + $0.aliases) }
            .map { term in
                AppSearchHit(
                    kind: .vocabulary,
                    target: .vocabulary(term.text),
                    title: term.text,
                    snippet: AppSearchSnippet.make(term.aliases.joined(separator: ", "), query: query),
                    date: nil
                )
            }
        return AppSearchGroup(kind: .vocabulary, hits: hits)
    }

    private func punctuationGroup(_ query: String) -> AppSearchGroup {
        let hits = SettingsStore.shared.punctuationDictionaryRules
            .filter { Self.matches(query, $0.aliases + [$0.symbol]) }
            .map { rule in
                AppSearchHit(
                    kind: .punctuation,
                    target: .punctuation(rule.id),
                    title: rule.symbol,
                    snippet: AppSearchSnippet.make(rule.aliases.joined(separator: ", "), query: query),
                    date: nil
                )
            }
        return AppSearchGroup(kind: .punctuation, hits: hits)
    }

    private func settingsGroup(_ query: String) -> AppSearchGroup {
        let hits = SettingsSearchIndex.results(for: query, availability: .current).map { result in
            AppSearchHit(
                kind: .settings,
                target: .settings(result.target),
                title: SettingsSearchIndex.title(for: result.target),
                snippet: AttributedString(result.section.title),
                date: nil
            )
        }
        return AppSearchGroup(kind: .settings, hits: hits)
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }
}
