#if DICTIONARY_EXPERIMENT_STANDALONE
import Foundation

// The real catalog is used for model identity; model files are absent from this fixture.
enum HuggingFaceModelDownloader {
    static func artifactIsComplete(at _: URL, isDirectory _: Bool) -> Bool {
        false
    }
}

// Minimal surrounding types; the matcher, resolver and persistence implementations under test are production sources.
struct ASRWordTiming: Sendable { let text: String; let start: Double; let end: Double }
struct PronunciationEnrollmentCapture { let inspectionID: UUID?; let originalAudioID: UUID?; let values: [Float] }
struct PronunciationDictionaryProfile { let modelKey: String; let label: String; let enrollments: [PronunciationEnrollmentCapture] }
enum PronunciationDictionaryStoreError: Error { case inconsistentEnrollment, staleEvidence }

@main struct DictionaryMatcherExperimentTests {
    static var checks = 0
    static func expect(_ condition: Bool, _ message: String) {
        self.checks += 1
        if !condition { fatalError(message) }
    }

    static func main() async throws {
        let keys = [
            "DictionarySharedFeatureMatcherEnabled",
            "DictionaryTemporalMatcherEnabled",
            "DictionaryNegativeLearningEnabled",
            "DictionaryNegativeComparisonEnabled",
            "DictionaryPronunciationGeneration",
        ]
        let savedPreferences = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, savedPreferences) {
            UserDefaults.standard.set(value, forKey: key)
        } }
        for key in keys {
            UserDefaults.standard.set(true, forKey: key)
        }
        UserDefaults.standard.set(false, forKey: keys[0])
        self.expect(!DictionaryMatcherExperiment.positiveEnabled && !DictionaryMatcherExperiment.needsFrames, "Off overrides legacy matching preferences")
        self.expect(!DictionaryMatcherExperiment.collectNegatives && !DictionaryMatcherExperiment.compareNegatives, "Off disables negative audio learning and comparisons")
        UserDefaults.standard.set(true, forKey: keys[0])
        UserDefaults.standard.set(false, forKey: keys[1])
        self.expect(DictionaryMatcherExperiment.positiveEnabled && DictionaryMatcherExperiment.needsFrames, "On selects fast matching independently of legacy preference")
        let beforeToggle = DictionaryMatcherExperiment.generation
        DictionaryMatcherExperiment.setEnabled(false)
        DictionaryMatcherExperiment.setEnabled(true)
        self.expect(DictionaryMatcherExperiment.generation != beforeToggle, "Rapid off-on invalidates earlier pronunciation work")
        let positive = DictionaryMatchFrames(hiddenSize: 2, values: [1, 0, 1, 0, 1, 0])
        let negative = DictionaryMatchFrames(hiddenSize: 2, values: [0, 1, 0, 1, 0, 1])
        let refs = [positive, positive, positive]
        self.expect(DictionaryExperimentalMatcher.positive(query: positive, references: refs)?.accepted == true, "Accept identical positives")
        self.expect(DictionaryExperimentalMatcher.positive(query: negative, references: refs)?.accepted == false, "Reject a different sequence")
        let contextual = DictionaryMatchFrames(hiddenSize: 2, values: [0.6, 0.8, 0.6, 0.8, 0.6, 0.8])
        let sharedDecision = await DictionaryExperimentalMatcher.compareSharedFeatures(query: contextual, references: refs)
        self.expect(sharedDecision?.accepted == true, "Shared sentence features use their calibrated operating point")
        self.expect(DictionaryExperimentalMatcher.positive(query: contextual, references: refs)?.accepted == false, "Shared thresholds must not loosen isolated-query scoring")
        let weakContext = DictionaryMatchFrames(hiddenSize: 2, values: [0.58, 0.814_616, 0.58, 0.814_616, 0.58, 0.814_616])
        let weakShared = await DictionaryExperimentalMatcher.compareSharedFeatures(query: weakContext, references: refs)
        self.expect(weakShared?.accepted == false, "Shared matching still rejects weak overall similarity")
        let missingShared = await DictionaryExperimentalMatcher.compareSharedFeatures(query: contextual, references: [positive])
        self.expect(missingShared == nil, "Missing reference features must not accept a candidate")
        let contextualChunk = DictionaryMatchFrames(hiddenSize: 2, values: [0.56, 0.828_493, 0.56, 0.828_493, 0.56, 0.828_493])
        let chunkDecision = await DictionaryExperimentalMatcher.compareSharedFeatures(query: contextualChunk, references: refs, chunked: true)
        let shortDecision = await DictionaryExperimentalMatcher.compareSharedFeatures(query: contextualChunk, references: refs)
        self.expect(chunkDecision?.accepted == true && shortDecision?.accepted == false, "Long-window calibration must not loosen the short-recording operating point")
        self.expect(DictionaryExperimentalMatcher.positive(query: positive, references: [positive]) == nil, "Missing enrollments fallback")
        self.expect(DictionaryExperimentalMatcher.metrics(reference: positive, query: .init(hiddenSize: 2, values: [.nan, 0])) == nil, "Reject nonfinite values")
        self.expect(!DictionaryMatchFrames(hiddenSize: 2, values: []).isValid, "Reject empty frames")
        self.expect(!DictionaryMatchFrames(hiddenSize: 2, values: [1, 0, 1]).isValid, "Reject inconsistent dimensions")
        self.expect(!DictionaryMatchFrames(hiddenSize: 1025, values: [Float](repeating: 1, count: 1025)).isValid, "Bound hidden size")
        self.expect(!DictionaryMatchFrames(hiddenSize: 1, values: [Float](repeating: 1, count: 193)).isValid, "Bound duration")
        self.expect(DictionaryExperimentalMatcher.negativeAllows(query: positive, references: refs, negatives: []), "Empty bank is inert")
        self.expect(DictionaryExperimentalMatcher.negativeAllows(query: positive, references: refs, negatives: [positive]), "One correction cannot veto equally strong positives")
        self.expect(!DictionaryExperimentalMatcher.negativeAllows(query: negative, references: refs, negatives: [negative]), "Close negative with margin vetoes")
        self.expect(DictionaryExperimentalMatcher.negativeAllows(query: positive, references: refs, negatives: [negative]), "Unrelated negative is inert")
        let now = Date(), entry = UUID()
        let evidence = DictionaryAcousticEvidence(
            id: UUID(),
            entryID: entry,
            label: "Manimekalai",
            profileKey: "profile",
            modelKey: "parakeet-v2",
            sourceWordRange: 1..<2,
            frames: positive
        )
        // nil selects the default evidence; an empty array tests missing evidence.
        func context(
            _ text: String = "Hello Manimekalai today",
            // nil requests the fixture default; an empty collection tests explicitly missing data.
            // swiftlint:disable:next discouraged_optional_collection
            events: [DictionaryAcousticEvidence]? = nil,
            date: Date? = nil,
            selected: String = "Manimekalai"
        ) -> DictionaryLearningCorrectionContext {
            let alignment = DictionaryLearningAlignment(
                modelKey: "parakeet-v2",
                words: [.init(text: "raw", start: 0, end: 1)],
                acousticOutput: text,
                acousticEvidence: events ?? [evidence]
            )
            guard let recording = DictionaryLearningRecording(alignment: alignment, samples: [0.1, 0.1], now: date ?? now)
            else { preconditionFailure("Missing fixture: recording") }
            return .init(recording: recording, deliveredTextBeforeEdit: text, selectedUTF16Range: (text as NSString).range(of: selected))
        }
        guard let correction = DictionaryNegativeEvidenceResolver.resolve(context: context(), heard: "Manimekalai", corrected: "another", now: now)
        else { preconditionFailure("Missing fixture: correction") }
        self.expect(correction.evidence.id == evidence.id, "Keep exact accepted occurrence")
        self.expect(
            DictionaryNegativeEvidenceResolver.resolve(context: context(), heard: "Manimekalai", corrected: "better Manimekalai", now: now) == nil,
            "Added words never become negatives"
        )
        self.expect(
            DictionaryNegativeEvidenceResolver.resolve(context: context(), heard: "Manimekalai", corrected: "Manimekalais", now: now) == nil,
            "Plural edits never become negatives"
        )
        guard let featureOnly = DictionaryLearningRecording(alignment: context().recording.alignment, samples: [0.1], retainAudio: false, now: now)
        else { preconditionFailure("Missing fixture: featureOnly") }
        self.expect(featureOnly.samples.isEmpty && featureOnly.alignment.acousticEvidence.count == 1, "Negative-only observation does not retain full PCM")
        let punctuated = context("Hello Manimekalai.")
        let punctuationContext = DictionaryLearningCorrectionContext(
            recording: punctuated.recording,
            deliveredTextBeforeEdit: punctuated.deliveredTextBeforeEdit,
            selectedUTF16Range: NSRange(location: 6, length: 12)
        )
        self.expect(
            DictionaryNegativeEvidenceResolver.resolve(context: punctuationContext, heard: "Manimekalai", corrected: "another", now: now) != nil,
            "Sentence punctuation still maps to the exact occurrence"
        )
        self.expect(
            DictionaryNegativeEvidenceResolver.resolve(context: context(), heard: "Manimekalai", corrected: "MANIMEKALAI!", now: now) == nil,
            "Case and punctuation are not negative examples"
        )
        self.expect(DictionaryNegativeEvidenceResolver.resolve(context: context(), heard: "Manimekalai", corrected: "", now: now) == nil, "Deletion is ambiguous")
        self.expect(
            DictionaryNegativeEvidenceResolver.resolve(context: context(events: []), heard: "Manimekalai", corrected: "other", now: now) == nil,
            "No acoustic acceptance means no negative"
        )
        self.expect(
            DictionaryNegativeEvidenceResolver.resolve(context: context("Manimekalai and Manimekalai"), heard: "Manimekalai", corrected: "other", now: now) == nil,
            "Repeated names are ambiguous"
        )
        self.expect(
            DictionaryNegativeEvidenceResolver.resolve(context: context(selected: "Mani"), heard: "Mani", corrected: "other", now: now) == nil,
            "Partial label edit is ambiguous"
        )
        self.expect(
            DictionaryNegativeEvidenceResolver.resolve(context: context(date: now.addingTimeInterval(-121)), heard: "Manimekalai", corrected: "other", now: now) == nil,
            "Expired recording rejected"
        )
        let changed = DictionaryLearningCorrectionContext(
            recording: context().recording,
            deliveredTextBeforeEdit: "Hello Manimekalai tomorrow",
            selectedUTF16Range: NSRange(location: 6, length: 11)
        )
        self.expect(DictionaryNegativeEvidenceResolver.resolve(context: changed, heard: "Manimekalai", corrected: "other", now: now) == nil, "AI rewriting invalidates mapping")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("negative.plist")
        let store = DictionaryNegativeExampleStore(url: url, collectionEnabled: { true })
        let revision = await store.revision()
        try await store.save(correction, expectedRevision: revision)
        try await store.save(correction, expectedRevision: revision)
        let saved = await store.frames(entryID: entry, profileKey: "profile", modelKey: "parakeet-v2")
        self.expect(saved.count == 1, "Duplicate event only saved once")
        let wrongModel = await store.frames(entryID: entry, profileKey: "profile", modelKey: "parakeet-v3")
        self.expect(wrongModel.isEmpty, "Model isolation")
        let retrained = await store.frames(entryID: entry, profileKey: "changed", modelKey: "parakeet-v2")
        self.expect(retrained.isEmpty, "Retraining invalidates old negatives")
        for _ in 0..<10 {
            let e = DictionaryAcousticEvidence(
                id: UUID(),
                entryID: entry,
                label: evidence.label,
                profileKey: "profile",
                modelKey: evidence.modelKey,
                sourceWordRange: 1..<2,
                frames: positive
            )
            try await store.save(.init(evidence: e, correctedText: "other", expiresAt: now.addingTimeInterval(120)), expectedRevision: revision)
        }
        let bounded = await store.frames(entryID: entry, profileKey: "profile", modelKey: "parakeet-v2")
        self.expect(bounded.count == 6, "Per-word bank bounded")
        for _ in 0..<40 {
            let e = DictionaryAcousticEvidence(
                id: UUID(),
                entryID: UUID(),
                label: evidence.label,
                profileKey: "profile",
                modelKey: evidence.modelKey,
                sourceWordRange: 1..<2,
                frames: positive
            )
            try await store.save(.init(evidence: e, correctedText: "other", expiresAt: now.addingTimeInterval(120)), expectedRevision: revision)
        }
        let persisted = try PropertyListDecoder().decode([DictionaryNegativeExampleStore.Example].self, from: Data(contentsOf: url))
        self.expect(persisted.count == 32, "Global bank bounded")
        do {
            try await store.save(.init(evidence: evidence, correctedText: "other", expiresAt: .distantPast), expectedRevision: revision)
            fatalError("Expired confirmation saved")
        } catch { self.checks += 1 }
        let disabled = DictionaryNegativeExampleStore(url: url, collectionEnabled: { false })
        do { try await disabled.save(correction, expectedRevision: await disabled.revision()); fatalError("Disabled collection wrote") } catch { self.checks += 1 }
        try await store.clear()
        do { try await store.save(correction, expectedRevision: revision); fatalError("Stale save survived clear") } catch { self.checks += 1 }
        self.expect(!FileManager.default.fileExists(atPath: url.path), "Clear removes store")
        let invalid = Data("broken".utf8)
        try invalid.write(to: url)
        let corrupt = await store.frames(entryID: entry, profileKey: "profile", modelKey: "parakeet-v2")
        self.expect(corrupt.isEmpty, "Corrupt optional bank cannot veto")
        if CommandLine.arguments.count > 1 { try self.parity(CommandLine.arguments[1]) }
        print("Dictionary experiments: \(self.checks) checks passed")
    }

    static func parity(_ path: String) throws {
        struct Clip: Decodable { let id: String; let word: String; let values: [Float] }
        struct Input: Decodable { let enrollments: [Clip]; let queries: [Clip] }
        struct Decision: Decodable { let id: String; let combinedAccepted: Bool; let meanRelative: Float; let lowerRelative: Float }
        struct Report: Decodable { let decisions: [Decision] }
        let root = URL(fileURLWithPath: path)
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: root.appendingPathComponent("native-input.json")))
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: root.appendingPathComponent("native-report.json")))
        let expected = Dictionary(uniqueKeysWithValues: report.decisions.map { ($0.id, $0) })
        for q in input.queries {
            let refs = input.enrollments.filter { $0.word == q.word }.map { DictionaryMatchFrames(hiddenSize: 1024, values: $0.values) }
            guard let d = DictionaryExperimentalMatcher.positive(query: .init(hiddenSize: 1024, values: q.values), references: refs)
            else { preconditionFailure("Missing fixture: d") }
            guard let e = expected[q.id] else { preconditionFailure("Missing fixture: e") }
            self.expect(d.accepted == e.combinedAccepted, "Production scorer parity \(q.id)")
            self.expect(abs(d.meanRelative - e.meanRelative) < 0.00_001 && abs(d.lowerRelative - e.lowerRelative) < 0.00_001, "Production score tolerance \(q.id)")
        }
    }
}
#endif
