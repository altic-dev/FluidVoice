import CryptoKit
import Foundation

nonisolated struct DictionaryAcousticEvidence: Sendable {
    let id: UUID
    let entryID: UUID
    let label: String
    let profileKey: String
    let modelKey: String
    let sourceWordRange: Range<Int>
    let frames: DictionaryMatchFrames
}

nonisolated struct DictionaryNegativeCorrection: Sendable {
    let evidence: DictionaryAcousticEvidence
    let correctedText: String
    let expiresAt: Date
}

nonisolated enum DictionaryNegativeEvidenceResolver {
    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    /// Only an unchanged delivered utterance and a unique, complete inserted label qualify.
    /// Repeated names, AI rewrites, partial selections, and stale audio are deliberately ignored.
    static func resolve(context: DictionaryLearningCorrectionContext, heard: String, corrected: String, now: Date = Date()) -> DictionaryNegativeCorrection? {
        guard DictionaryCorrectionEditPolicy.allows(heard: heard, corrected: corrected) else { return nil }
        let alignment = context.recording.alignment
        guard now < context.recording.expiresAt, alignment.acousticOutput == context.deliveredTextBeforeEdit,
              !self.normalized(corrected).isEmpty, self.normalized(heard) != self.normalized(corrected) else { return nil }
        let source = context.deliveredTextBeforeEdit as NSString
        let selected = context.selectedUTF16Range
        guard selected.location >= 0, selected.length > 0, selected.location <= source.length,
              selected.length <= source.length - selected.location,
              source.substring(with: selected).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) == heard else { return nil }
        let selectedLabel = source.range(of: heard, range: selected)
        let eligible = alignment.acousticEvidence.filter { evidence in
            guard evidence.label == heard, evidence.frames.isValid else { return false }
            let range = source.range(of: evidence.label)
            guard range == selectedLabel else { return false }
            let after = NSMaxRange(range)
            return source.range(of: evidence.label, range: NSRange(location: after, length: source.length - after)).location == NSNotFound
        }
        guard eligible.count == 1 else { return nil }
        return DictionaryNegativeCorrection(evidence: eligible[0], correctedText: corrected, expiresAt: context.recording.expiresAt)
    }

    static func profileKey(_ profile: PronunciationDictionaryProfile) -> String {
        // Retraining, replacement spelling, model changes, and extraction changes invalidate examples.
        var hash = SHA256()
        hash.update(data: Data((DictionaryMatcherExperiment.version + profile.modelKey + profile.label).utf8))
        for e in profile.enrollments {
            hash.update(data: Data((e.inspectionID?.uuidString ?? e.originalAudioID?.uuidString ?? "").utf8))
            e.values.withUnsafeBytes { hash.update(data: Data($0)) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Separate, removable experimental store; never mutates positive enrollments or dictionary text.
actor DictionaryNegativeExampleStore {
    static let shared = DictionaryNegativeExampleStore()
    struct Example: Codable, Sendable {
        let id: UUID
        let entryID: UUID
        let profileKey: String
        let modelKey: String
        let frames: DictionaryMatchFrames
    }

    private let url: URL
    private var generation = UUID()
    private let collectionEnabled: @Sendable () -> Bool

    init(
        url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidVoice/dictionary-negative-examples-v1.plist"),
        collectionEnabled: @escaping @Sendable () -> Bool = { DictionaryMatcherExperiment.collectNegatives }
    ) {
        self.url = url
        self.collectionEnabled = collectionEnabled
    }

    func revision() -> UUID { self.generation }

    private func read() throws -> [Example] {
        guard FileManager.default.fileExists(atPath: self.url.path) else { return [] }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 32_000_000 else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        let examples = try PropertyListDecoder().decode([Example].self, from: Data(contentsOf: self.url))
        guard examples.count <= 32, examples.allSatisfy({ $0.frames.isValid }) else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        return examples
    }

    func frames(entryID: UUID, profileKey: String, modelKey: String) -> [DictionaryMatchFrames] {
        guard !ParakeetSpeechModelCatalog.isOutdatedCompactPronunciationModelKey(modelKey) else { return [] }
        return ((try? self.read()) ?? []).filter { $0.entryID == entryID && $0.profileKey == profileKey && $0.modelKey == modelKey }.map(\.frames)
    }

    func save(_ correction: DictionaryNegativeCorrection, expectedRevision: UUID) throws {
        guard self.generation == expectedRevision, self.collectionEnabled(), correction.expiresAt > Date() else { throw PronunciationDictionaryStoreError.staleEvidence }
        let e = correction.evidence
        guard e.frames.isValid else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        var all = try read()
        if all.contains(where: { $0.id == e.id }) { return }
        // Six examples per word; 32 globally. Only frame features are persisted, no PCM or transcript.
        all.removeAll { $0.entryID == e.entryID && $0.profileKey != e.profileKey }
        while all.filter({ $0.entryID == e.entryID }).count >= 6 {
            if let index = all.firstIndex(where: { $0.entryID == e.entryID }) { all.remove(at: index) }
        }
        all.append(Example(id: e.id, entryID: e.entryID, profileKey: e.profileKey, modelKey: e.modelKey, frames: e.frames))
        all = Array(all.suffix(32))
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(all)
        guard data.count <= 32_000_000 else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        try FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: self.url, options: .atomic)
    }

    func clear() throws {
        self.generation = UUID()
        if FileManager.default.fileExists(atPath: self.url.path) { try FileManager.default.removeItem(at: self.url) }
    }

    func remove(id: UUID) throws {
        let all = try read().filter { $0.id != id }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(all).write(to: self.url, options: .atomic)
    }
}
