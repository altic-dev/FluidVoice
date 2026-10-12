import AppKit
@testable import FluidVoice_Debug
import Foundation
import SwiftUI
import XCTest

/// The query side of the sidebar search.
@MainActor
final class AppSearchServiceTests: XCTestCase {
    func testSearchCategoryExpansionIsIndependentAndReversible() {
        let history = (0..<12).map { index in
            AppSearchHit(kind: .history, target: .history(UUID()), title: "History \(index)", snippet: "", date: nil)
        }
        let transcripts = (0..<8).map { index in
            AppSearchHit(kind: .transcripts, target: .transcript(UUID()), title: "Transcript \(index)", snippet: "", date: nil)
        }
        let groups = [AppSearchGroup(kind: .history, hits: history), AppSearchGroup(kind: .transcripts, hits: transcripts)]
        XCTAssertEqual(AppSearchResultsView.visibleHits(groups, expanded: []), Array(history.prefix(5)) + Array(transcripts.prefix(5)))
        XCTAssertEqual(AppSearchResultsView.visibleHits(groups, expanded: [.history]), history + Array(transcripts.prefix(5)))
        XCTAssertEqual(AppSearchResultsView.visibleHits(groups, expanded: [.history, .transcripts]), history + transcripts)
        // Collapsing History must not collapse Transcripts or reorder their results.
        XCTAssertEqual(AppSearchResultsView.visibleHits(groups, expanded: [.transcripts]), Array(history.prefix(5)) + transcripts)
        XCTAssertEqual(groups[0].hits, history)
        XCTAssertEqual(groups[1].hits, transcripts)
        XCTAssertTrue(AppSearchResultsView.visibleHits([], expanded: [.history]).isEmpty)
    }

    private struct Row {
        let id: UUID
        let date: Date
    }

    // MARK: - Ranking

    func testHitsAreOrderedByScoreThenNewestAndUnknownRowsAreDropped() {
        let old = Row(id: UUID(), date: Date(timeIntervalSince1970: 100))
        let new = Row(id: UUID(), date: Date(timeIntervalSince1970: 200))
        let best = Row(id: UUID(), date: Date(timeIntervalSince1970: 0))
        let rows = Dictionary(uniqueKeysWithValues: [old, new, best].map { ($0.id, $0) })
        let hits = [
            SearchIndex.Hit(id: old.id, score: 1),
            SearchIndex.Hit(id: UUID(), score: 9),
            SearchIndex.Hit(id: new.id, score: 1),
            SearchIndex.Hit(id: best.id, score: 2),
        ]

        let ordered = AppSearchService.ranked(hits, rows: rows, date: \.date) { row in
            AppSearchHit(kind: .history, target: .history(row.id), title: "", snippet: "", date: row.date)
        }

        XCTAssertEqual(ordered.map(\.target), [.history(best.id), .history(new.id), .history(old.id)])
    }

    // MARK: - Stale results

    /// Two keystrokes in quick succession: only the second one's answer may land.
    func testANewerQueryReplacesOneStillDebouncing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSearchServiceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AppSearchService(index: SearchIndex(root: FluidZeppelinRoot(root: root)))

        service.query = "launch at startup"
        service.query = "accent color"
        try await self.waitUntil { !service.isSearching && !service.groups.isEmpty }

        let settings = try XCTUnwrap(service.groups.first { $0.kind == .settings })
        XCTAssertTrue(settings.hits.contains { $0.target == .settings(.accentColor) })
        XCTAssertFalse(settings.hits.contains { $0.target == .settings(.launchAtStartup) })

        service.query = "   "
        XCTAssertTrue(service.groups.isEmpty)
    }

    func testChangingQueryImmediatelyInvalidatesPublishedResults() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSearchServiceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AppSearchService(index: SearchIndex(root: FluidZeppelinRoot(root: root)))

        service.query = "launch at startup"
        try await self.waitUntil { !service.isSearching && !service.groups.isEmpty }
        XCTAssertFalse(service.groups.isEmpty)

        service.query = "accent color"

        XCTAssertTrue(service.groups.isEmpty)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard await condition() else {
            XCTFail("A bounded app-search condition did not complete")
            throw AppSearchPreparationGate.Failure.unavailable
        }
    }

    private static func queryGroup(_ query: String) -> [AppSearchGroup] {
        [AppSearchGroup(kind: .settings, hits: [AppSearchHit(
            kind: .settings,
            target: .settings(query == "old" ? .launchAtStartup : .accentColor),
            title: query,
            snippet: "",
            date: nil
        )])]
    }

    func testFirstQueryWaitsForPreparationAndShowsPendingState() async throws {
        let gate = AppSearchPreparationGate()
        var queried: [String] = []
        let service = AppSearchService(prepareIndex: { try await gate.wait() }, performSearch: { query in
            queried.append(query)
            return Self.queryGroup(query)
        })
        service.query = "old"
        do {
            try await self.waitUntil { await gate.hasStarted() }
            XCTAssertTrue(service.isSearching)
            XCTAssertTrue(service.groups.isEmpty)
            XCTAssertNil(service.searchError)
            XCTAssertTrue(queried.isEmpty, "A lexical query cannot run before authoritative snapshots are ready")
            await gate.release()
            try await self.waitUntil { !service.isSearching }
            XCTAssertEqual(queried, ["old"])
            XCTAssertEqual(service.groups, Self.queryGroup("old"))
            XCTAssertNil(service.searchError)
        } catch {
            service.query = ""
            await gate.release()
            throw error
        }
        service.query = ""
    }

    func testFailedPreparationShowsRetryableErrorAndDoesNotRunTheQuery() async throws {
        let gate = AppSearchPreparationGate()
        var queried: [String] = []
        let service = AppSearchService(prepareIndex: { try await gate.wait() }, performSearch: { query in
            queried.append(query)
            return Self.queryGroup(query)
        })
        service.query = "new"
        do {
            try await self.waitUntil { await gate.hasStarted() }
            await gate.release(failing: true)
            try await self.waitUntil { !service.isSearching }
            XCTAssertTrue(service.groups.isEmpty)
            XCTAssertNotNil(service.searchError)
            XCTAssertTrue(queried.isEmpty)
            await gate.release(failing: false)
            service.refresh()
            XCTAssertTrue(service.isSearching)
            XCTAssertNil(service.searchError)
            try await self.waitUntil { !service.isSearching }
            XCTAssertEqual(queried, ["new"])
            XCTAssertEqual(service.groups, Self.queryGroup("new"))
            XCTAssertNil(service.searchError)
        } catch {
            service.query = ""
            await gate.release()
            throw error
        }
        service.query = ""
    }

    func testOnlyExplicitRetryReloadsFailedPreparationAndStoppedRetryDoesNothing() async throws {
        let center = NotificationCenter()
        var preparationCalls = 0
        var retryCalls = 0
        var canPrepare = false
        var queried: [String] = []
        let service = AppSearchService(
            prepareIndex: {
                preparationCalls += 1
                if !canPrepare { throw AppSearchPreparationGate.Failure.unavailable }
            },
            retryPreparation: {
                retryCalls += 1
                canPrepare = true
            },
            performSearch: { query in
                queried.append(query)
                return Self.queryGroup(query)
            },
            notificationCenter: center
        )
        defer { service.stop() }
        service.query = "old"
        try await self.waitUntil { !service.isSearching }
        XCTAssertNotNil(service.searchError)
        service.query = "new"
        try await self.waitUntil { !service.isSearching }
        service.refresh()
        try await self.waitUntil { !service.isSearching }
        center.post(name: .parakeetVocabularyDidChange, object: nil)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        try await self.waitUntil { !service.isSearching }
        XCTAssertEqual(preparationCalls, 4)
        XCTAssertEqual(retryCalls, 0, "Typing, refresh, and cache invalidation must not reload source history")
        XCTAssertNotNil(service.searchError)
        XCTAssertTrue(queried.isEmpty)

        service.retry()
        XCTAssertEqual(retryCalls, 1)
        XCTAssertTrue(service.isSearching)
        XCTAssertNil(service.searchError)
        try await self.waitUntil { !service.isSearching }
        XCTAssertEqual(service.groups, Self.queryGroup("new"))
        XCTAssertEqual(queried, ["new"])
        XCTAssertEqual(preparationCalls, 5)
        XCTAssertNil(service.searchError)

        service.stop()
        service.retry()
        service.query = "after stop"
        service.refresh()
        center.post(name: .parakeetVocabularyDidChange, object: nil)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(retryCalls, 1)
        XCTAssertEqual(preparationCalls, 5)
        XCTAssertEqual(queried, ["new"])
        XCTAssertTrue(service.groups.isEmpty)
        XCTAssertFalse(service.isSearching)
        XCTAssertNil(service.searchError)
    }

    func testOlderInFlightQueryCannotReplaceNewerResultsWhenItCompletesLate() async throws {
        let gate = AppSearchQueryGate(blockedQueries: ["old"])
        let service = AppSearchService(performSearch: { query in
            await gate.run(query)
            return Self.queryGroup(query)
        })
        service.query = "old"
        do {
            try await self.waitUntil { await gate.calls().contains("old") }
            service.query = "new"
            try await self.waitUntil { !service.isSearching && service.groups == Self.queryGroup("new") }
            await gate.release("old")
            try await self.waitUntil { await gate.finished().contains("old") }
            // The completion is delivered through the real schedule task; give
            // that main-actor continuation a turn before checking non-effects.
            await Task.yield()
            XCTAssertEqual(service.groups, Self.queryGroup("new"))
            XCTAssertFalse(service.isSearching)
            XCTAssertNil(service.searchError)
        } catch {
            service.query = ""
            await gate.release("old")
            throw error
        }
        service.query = ""
    }

    func testClearingQueryWhileSearchIsInFlightCannotRepublishLateResults() async throws {
        let gate = AppSearchQueryGate(blockedQueries: ["old"])
        let service = AppSearchService(performSearch: { query in
            await gate.run(query)
            return Self.queryGroup(query)
        })
        service.query = "old"
        do {
            try await self.waitUntil { await gate.calls().contains("old") }
            service.query = "   "
            XCTAssertTrue(service.groups.isEmpty)
            XCTAssertFalse(service.isSearching)
            XCTAssertNil(service.searchError)
            await gate.release("old")
            try await self.waitUntil { await gate.finished().contains("old") }
            await Task.yield()
            XCTAssertTrue(service.groups.isEmpty)
            XCTAssertFalse(service.isSearching)
            XCTAssertNil(service.searchError)
        } catch {
            service.query = ""
            await gate.release("old")
            throw error
        }
    }

    func testStoppingSearchRejectsLateResultsAndAllLaterQueries() async throws {
        let gate = AppSearchQueryGate(blockedQueries: ["old"])
        var preparationCalls = 0
        let service = AppSearchService(prepareIndex: { preparationCalls += 1 }, performSearch: { query in
            await gate.run(query)
            return Self.queryGroup(query)
        })
        service.query = "old"
        do {
            try await self.waitUntil { await gate.calls().contains("old") }
            XCTAssertEqual(preparationCalls, 1)
            service.stop()
            XCTAssertTrue(service.groups.isEmpty)
            XCTAssertFalse(service.isSearching)
            XCTAssertNil(service.searchError)
            await gate.release("old")
            try await self.waitUntil { await gate.finished().contains("old") }
            service.query = "new"
            service.refresh()
            let direct = await service.search("direct after stop")
            XCTAssertTrue(direct.isEmpty)
            // Beyond the real 80 ms debounce, any incorrectly restarted task
            // would reach the runner and be visible in this gate's call list.
            try await Task.sleep(for: .milliseconds(120))
            let calls = await gate.calls()
            XCTAssertEqual(calls, ["old"])
            XCTAssertEqual(preparationCalls, 1)
            XCTAssertTrue(service.groups.isEmpty)
            XCTAssertFalse(service.isSearching)
            XCTAssertNil(service.searchError)
        } catch {
            service.stop()
            await gate.release("old")
            throw error
        }
    }

    private func withVocabularyProbe(failingReads: Set<Int> = [], _ body: (AppSearchService, AppSearchVocabularyProbe, NotificationCenter) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppSearchVocabularyTests-\(UUID().uuidString)", isDirectory: true)
        let database = FluidZeppelinRoot(root: directory)
        let loader = AppSearchVocabularyProbe(failingReads: failingReads)
        let center = NotificationCenter()
        let service = AppSearchService(index: SearchIndex(root: database), readVocabulary: { try await loader.read() }, notificationCenter: center)
        do {
            try await body(service, loader, center)
        } catch {
            service.stop()
            await loader.releaseAll()
            await database.closeAll()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        service.stop()
        await loader.releaseAll()
        await database.closeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    private static func vocabularyTargets(_ groups: [AppSearchGroup]) -> [AppSearchHit.Target] {
        groups.first { $0.kind == .vocabulary }?.hits.map(\.target) ?? []
    }

    func testTransientVocabularyReadFailureRetriesThenCachesSuccessfulLoad() async throws {
        try await self.withVocabularyProbe(failingReads: [0]) { service, loader, _ in
            let term = ParakeetVocabularyStore.VocabularyConfig.Term(text: "fvsearchvocabfixture alpha", weight: 2, aliases: ["fvsearchaliasfixture"])
            await loader.setTerms([term])
            let failed = await service.search("fvsearchvocabfixture")
            XCTAssertTrue(Self.vocabularyTargets(failed).isEmpty)
            let retry = await service.search("fvsearchaliasfixture")
            XCTAssertEqual(Self.vocabularyTargets(retry), [.vocabulary(term.text)])
            let cached = await service.search("fvsearchvocabfixture")
            XCTAssertEqual(Self.vocabularyTargets(cached), [.vocabulary(term.text)])
            let reads = await loader.readCount()
            XCTAssertEqual(reads, 2, "Only a successful read may become the reusable immutable snapshot")
        }
    }

    func testSuccessfulEmptyVocabularyLoadIsCachedUntilAnActualChange() async throws {
        try await self.withVocabularyProbe { service, loader, _ in
            let first = await service.search("fvsearchvocabfixture")
            XCTAssertTrue(Self.vocabularyTargets(first).isEmpty)
            await loader.setTerms([.init(text: "fvsearchvocabfixture unpublished", weight: 2)])
            let cached = await service.search("fvsearchvocabfixture")
            XCTAssertTrue(Self.vocabularyTargets(cached).isEmpty, "Changing the fixture without an event must not trigger disk rereads")
            let reads = await loader.readCount()
            XCTAssertEqual(reads, 1)
        }
    }

    func testVocabularyChangeInvalidatesOnlyTheSuccessfulSearchSnapshot() async throws {
        try await self.withVocabularyProbe { service, loader, center in
            let first = ParakeetVocabularyStore.VocabularyConfig.Term(text: "fvsearchvocabfixture alpha", weight: 2)
            let updated = ParakeetVocabularyStore.VocabularyConfig.Term(text: "fvsearchvocabfixture beta", weight: 2)
            await loader.setTerms([first])
            service.query = "fvsearchvocabfixture"
            try await self.waitUntil { !service.isSearching && Self.vocabularyTargets(service.groups) == [.vocabulary(first.text)] }
            await loader.setTerms([updated])
            // Private center: global vocabulary events also retire ASR models.
            // This fixture must never notify those unrelated production consumers.
            center.post(name: .parakeetVocabularyDidChange, object: nil)
            try await self.waitUntil { !service.isSearching && Self.vocabularyTargets(service.groups) == [.vocabulary(updated.text)] }
            service.refresh()
            try await self.waitUntil { !service.isSearching && Self.vocabularyTargets(service.groups) == [.vocabulary(updated.text)] }
            let reads = await loader.readCount()
            XCTAssertEqual(reads, 2, "One real change invalidates the snapshot once; later keystrokes reuse it")
        }
    }

    func testLateVocabularyLoadCannotReplaceTheSnapshotFromANewerChange() async throws {
        try await self.withVocabularyProbe { service, loader, center in
            let first = ParakeetVocabularyStore.VocabularyConfig.Term(text: "fvsearchvocabfixture stale", weight: 2)
            let updated = ParakeetVocabularyStore.VocabularyConfig.Term(text: "fvsearchvocabfixture latest", weight: 2)
            await loader.setTerms([first])
            await loader.gateRead(0)
            let old = Task { await service.search("fvsearchvocabfixture") }
            do {
                try await self.waitUntil { await loader.readCount() == 1 }
                await loader.setTerms([updated])
                center.post(name: .parakeetVocabularyDidChange, object: nil)
                // The event uses receive(on: .main). This FIFO barrier drains
                // that delivery without a sleep or a global notification.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.async { continuation.resume() }
                }
                let latest = await service.search("fvsearchvocabfixture")
                XCTAssertEqual(Self.vocabularyTargets(latest), [.vocabulary(updated.text)])
                await loader.releaseRead(0)
                _ = await old.value
                let cached = await service.search("fvsearchvocabfixture")
                XCTAssertEqual(Self.vocabularyTargets(cached), [.vocabulary(updated.text)], "The older loader result must not poison the newly cached generation")
                let reads = await loader.readCount()
                XCTAssertEqual(reads, 2)
            } catch {
                await loader.releaseAll()
                _ = await old.value
                throw error
            }
        }
    }

    func testFileTranscriptRevealIgnoresOtherSearchDestinations() {
        let id = UUID()

        XCTAssertEqual(FileTranscriptionSearchReveal.transcriptID(.transcript(id)), id)
        XCTAssertNil(FileTranscriptionSearchReveal.transcriptID(.history(id)))
        XCTAssertNil(FileTranscriptionSearchReveal.transcriptID(.dictionaryEntry(id)))
        XCTAssertNil(FileTranscriptionSearchReveal.transcriptID(nil))
    }

    // MARK: - Snippets

    func testSnippetMarksEveryQueryWordIncludingByPrefix() {
        let snippet = AppSearchSnippet.make("Two meetings today.\nOne Meeting tomorrow.", query: "meeting")
        let marked = snippet.runs
            .filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(snippet[$0.range].characters) }

        XCTAssertEqual(String(snippet.characters), "Two meetings today. One Meeting tomorrow.")
        XCTAssertEqual(marked, ["meeting", "Meeting"])
    }

    func testSnippetWindowsAroundTheFirstMatchWithEllipses() {
        let filler = String(repeating: "word ", count: 60)
        let snippet = String(AppSearchSnippet.make(filler + "harbour lights " + filler, query: "harbour").characters)

        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertTrue(snippet.contains("harbour lights"))
        XCTAssertLessThan(snippet.count, AppSearchSnippet.window + 4)
    }

    func testSnippetWithNoMatchStartsAtTheBeginning() {
        let snippet = String(AppSearchSnippet.make("short text", query: "zzz").characters)
        XCTAssertEqual(snippet, "short text")
    }

    func testInMemoryMatchRequiresEveryWord() {
        XCTAssertTrue(AppSearchService.matches("acc col", ["Accent Color"]))
        XCTAssertFalse(AppSearchService.matches("accent blue", ["Accent Color"]))
        XCTAssertTrue(AppSearchService.matches("cafe", ["café"]))
    }
}

private actor AppSearchPreparationGate {
    enum Failure: Error { case unavailable }
    private var started = false
    private var released = false
    private var failing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hasStarted() -> Bool { self.started }

    func wait() async throws {
        self.started = true
        if !self.released { await withCheckedContinuation { self.waiters.append($0) } }
        if self.failing { throw Failure.unavailable }
    }

    func release(failing: Bool = false) {
        self.failing = failing
        self.released = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor AppSearchQueryGate {
    private let blockedQueries: Set<String>
    private var released: Set<String> = []
    private var entered: [String] = []
    private var completed: [String] = []
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

    init(blockedQueries: Set<String>) { self.blockedQueries = blockedQueries }
    func calls() -> [String] { self.entered }
    func finished() -> [String] { self.completed }

    func run(_ query: String) async {
        self.entered.append(query)
        if self.blockedQueries.contains(query), !self.released.contains(query) {
            await withCheckedContinuation { self.waiters[query] = $0 }
        }
        self.completed.append(query)
    }

    func release(_ query: String) {
        self.released.insert(query)
        self.waiters.removeValue(forKey: query)?.resume()
    }
}

private actor AppSearchVocabularyProbe {
    private var terms: [ParakeetVocabularyStore.VocabularyConfig.Term] = []
    private var reads = 0
    private let failingReads: Set<Int>
    private var gatedReads: Set<Int> = []
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    init(failingReads: Set<Int> = []) { self.failingReads = failingReads }
    func setTerms(_ terms: [ParakeetVocabularyStore.VocabularyConfig.Term]) { self.terms = terms }
    func readCount() -> Int { self.reads }
    func gateRead(_ number: Int) { self.gatedReads.insert(number) }

    func read() async throws -> [ParakeetVocabularyStore.VocabularyConfig.Term] {
        let number = self.reads
        self.reads += 1
        let snapshot = self.terms
        if self.gatedReads.contains(number) { await withCheckedContinuation { self.waiters[number] = $0 } }
        if self.failingReads.contains(number) { throw AppSearchPreparationGate.Failure.unavailable }
        return snapshot
    }

    func releaseRead(_ number: Int) { self.waiters.removeValue(forKey: number)?.resume() }
    func releaseAll() {
        self.gatedReads.removeAll()
        let waiters = self.waiters.values
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

extension AppSearchServiceTests {
    /// App-hosted rendering proof only. No installed-app interaction, preference
    /// or history writes, model preparation, global events, or microphone use.
    func testOptInNativeSearchSidebarStatesAtCompactWidth() async throws {
        guard let path = ProcessInfo.processInfo.environment["FLUIDVOICE_SEARCH_UI_PROOF"], !path.isEmpty else {
            throw XCTSkip("Supply an external output directory for the native search sidebar proof")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        guard output.path != repository.path, !output.path.hasPrefix(repository.path + "/") else {
            XCTFail("Native proof images must be saved outside the repository")
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let privateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SearchUIProof-\(UUID().uuidString)", isDirectory: true)
        let database = FluidZeppelinRoot(root: privateDirectory)
        let index = SearchIndex(root: database)
        let center = NotificationCenter()
        let gate = AppSearchPreparationGate()
        let loading = AppSearchService(index: index, prepareIndex: { try await gate.wait() }, performSearch: { _ in [] }, notificationCenter: center)
        let error = AppSearchService(index: index, prepareIndex: { throw AppSearchPreparationGate.Failure.unavailable }, performSearch: { _ in [] }, notificationCenter: center)
        let empty = AppSearchService(index: index, performSearch: { _ in [] }, notificationCenter: center)
        let results = AppSearchService(index: index, performSearch: { _ in Self.nativeProofGroups }, notificationCenter: center)
        let services = [loading, error, empty, results]
        do {
            for service in services {
                service.query = "meeting"
            }
            try await self.waitUntil { await gate.hasStarted() }
            try await self.waitUntil { !error.isSearching && !empty.isSearching && !results.isSearching }
            XCTAssertTrue(loading.isSearching)
            XCTAssertNotNil(error.searchError)
            XCTAssertTrue(empty.groups.isEmpty)
            XCTAssertEqual(results.groups, Self.nativeProofGroups)
            let states = [("searching", loading), ("preparation-error", error), ("empty", empty), ("results", results)]
            for scheme in [ColorScheme.dark, .light] {
                let appearance = scheme == .dark ? "dark" : "light"
                for (name, service) in states {
                    try await self.captureNativeSearchProof(service, scheme: scheme, destination: output.appendingPathComponent("search-\(name)-\(appearance).png"))
                }
            }
        } catch {
            for service in services {
                service.stop()
            }
            await gate.release()
            await database.closeAll()
            try? FileManager.default.removeItem(at: privateDirectory)
            throw error
        }
        for service in services {
            service.stop()
        }
        await gate.release()
        await database.closeAll()
        try? FileManager.default.removeItem(at: privateDirectory)
        print("Native search sidebar proof: \(output.path) (app-hosted fixtures, 260px, dark/light)")
    }

    private static var nativeProofGroups: [AppSearchGroup] {
        let histories = (1...8).map { number in
            let id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(number)))
            return AppSearchHit(kind: .history, target: .history(id), title: "Meeting notes \(number)", snippet: "Reviewed the project update and the next steps for the team.", date: nil)
        }
        let settings = AppSearchHit(kind: .settings, target: .settings(.accentColor), title: "Accent color", snippet: "Choose the appearance of FluidVoice.", date: nil)
        return [AppSearchGroup(kind: .history, hits: histories), AppSearchGroup(kind: .settings, hits: [settings])]
    }

    private func captureNativeSearchProof(_ service: AppSearchService, scheme: ColorScheme, destination: URL) async throws {
        let size = NSSize(width: 260, height: 520)
        let theme = AppTheme.adaptive(accent: FluidBrandColors.blue, colorScheme: scheme)
        let content = AppSearchResultsView(service: service, cursor: .constant(nil), expanded: .constant([]), open: { _ in })
            .frame(width: size.width, height: size.height)
            .appTheme(theme)
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.title = "Search sidebar proof"
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(160))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertEqual(host.bounds.width, 260)
        XCTAssertGreaterThan(png.count, 100)
        try png.write(to: destination)
    }
}
