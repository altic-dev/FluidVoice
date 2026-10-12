import Foundation

struct PronunciationEnrollmentCapture: Codable, Equatable, Sendable {
    let values: [Float]
    let sourceFrameCount: Int
    let modelKey: String
    var originalAudioID: UUID?
    var observedText: String?
    var sourceRecordingID: UUID?
    var sourceFocalRange: Range<Int>?
    var extractorVersion: String?
    var inspectionID: UUID?
    // nil identifies legacy enrollment; an empty vector is invalid.
    // swiftlint:disable:next discouraged_optional_collection
    var edgeEmbedding: [Float]?
    var edgeFrameCount: Int?
    // Only held until the profile save. Large evidence is stored separately on disk.
    var pendingInspection: DictionaryAudioInspection? = nil

    private enum CodingKeys: String, CodingKey {
        case values, sourceFrameCount, modelKey, originalAudioID, observedText
        case sourceRecordingID, sourceFocalRange, extractorVersion, inspectionID, edgeEmbedding, edgeFrameCount
    }
}

struct PronunciationDictionaryProfile: Codable, Equatable, Identifiable, Sendable {
    let dictionaryEntryID: UUID
    var label: String
    let modelKey: String
    let hiddenSize: Int
    var enrollments: [PronunciationEnrollmentCapture]
    var automaticMatchingEnabled: Bool? = nil
    var matchThreshold: Float? = nil

    var hasOriginalAudio: Bool { self.enrollments.contains { $0.originalAudioID != nil } }
    var isEligibleForMatching: Bool {
        (self.enrollments.count >= 3 || self.hasOriginalAudio) && self.enrollments.allSatisfy {
            $0.extractorVersion == nil || $0.extractorVersion == "parakeet-encoder-mean-l2-v1"
        }
    }

    var id: String { "\(self.dictionaryEntryID.uuidString):\(self.modelKey)" }
}

enum PronunciationDictionaryStoreError: LocalizedError, Equatable {
    case inconsistentEnrollment
    case staleEvidence
    case outdatedModelRevision

    var errorDescription: String? {
        switch self {
        case .staleEvidence:
            "The dictionary entry changed before audio learning finished."
        case .inconsistentEnrollment:
            "Pronunciation samples must use the same model and embedding size."
        case .outdatedModelRevision:
            "These pronunciation recordings use an older voice model. Retrain this word by voice. Your custom words and text corrections remain saved."
        }
    }
}

actor PronunciationDictionaryStore {
    static let shared = PronunciationDictionaryStore()

    private struct Document: Codable {
        let version: Int
        var profiles: [PronunciationDictionaryProfile]
    }

    private let fileURL: URL
    private var document: Document?
    private var revisions: [UUID: UUID] = [:]
    private var replacementGeneration = UUID()

    init(fileManager: FileManager = .default) {
        let baseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let appURL = baseURL.appendingPathComponent(
            "FluidVoice",
            isDirectory: true
        )
        self.fileURL = appURL.appendingPathComponent("pronunciation-dictionary-v1.json")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func allProfiles() -> [PronunciationDictionaryProfile] {
        self.loadIfNeeded()
        return self.document?.profiles ?? []
    }

    func profiles(modelKey: String) -> [PronunciationDictionaryProfile] {
        self.loadIfNeeded()
        return self.document?.profiles.filter { $0.modelKey == modelKey } ?? []
    }

    func enrollmentCount(
        dictionaryEntryID: UUID,
        modelKey: String
    ) -> Int {
        self.loadIfNeeded()
        return self.document?.profiles.first {
            $0.dictionaryEntryID == dictionaryEntryID && $0.modelKey == modelKey
        }?.enrollments.count ?? 0
    }

    func upsert(
        dictionaryEntryID: UUID,
        label: String,
        modelKey: String,
        enrollments: [PronunciationEnrollmentCapture],
        automaticMatchingEnabled: Bool = false,
        canPersist: @Sendable () -> Bool = { true }
    ) throws {
        guard canPersist() else { throw CancellationError() }
        guard let first = enrollments.first, !first.values.isEmpty else { return }
        guard enrollments.allSatisfy({ $0.modelKey == modelKey && $0.values.count == first.values.count }) else {
            throw PronunciationDictionaryStoreError.inconsistentEnrollment
        }
        self.loadIfNeeded()
        var profiles = self.document?.profiles ?? []
        let existingIndex = profiles.firstIndex(where: {
            $0.dictionaryEntryID == dictionaryEntryID && $0.modelKey == modelKey
        })
        let existingEnrollments = existingIndex.map { profiles[$0].enrollments } ?? []
        var prepared = enrollments
        var writtenInspectionIDs: [UUID] = []
        do {
            for index in prepared.indices {
                guard canPersist() else { throw CancellationError() }
                guard let evidence = prepared[index].pendingInspection else { continue }
                guard evidence.isValid, evidence.duration <= 15,
                      evidence.frames.allSatisfy({ $0.hiddenSize == first.values.count })
                else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
                let id = UUID()
                let url = self.inspectionURL(id)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                try encoder.encode(evidence).write(to: url, options: .atomic)
                writtenInspectionIDs.append(id)
                prepared[index].inspectionID = id
                prepared[index].pendingInspection = nil
            }
        } catch {
            for id in writtenInspectionIDs {
                try? FileManager.default.removeItem(at: self.inspectionURL(id))
            }
            throw error
        }
        var didPersist = false
        defer {
            if !didPersist {
                for id in writtenInspectionIDs {
                    try? FileManager.default.removeItem(at: self.inspectionURL(id))
                }
            }
        }
        let combinedEnrollments = existingEnrollments + prepared
        guard combinedEnrollments.allSatisfy({
            $0.modelKey == modelKey && $0.values.count == first.values.count
        }) else {
            throw PronunciationDictionaryStoreError.inconsistentEnrollment
        }
        let profile = PronunciationDictionaryProfile(
            dictionaryEntryID: dictionaryEntryID,
            label: label,
            modelKey: modelKey,
            hiddenSize: first.values.count,
            enrollments: Self.retainedEnrollments(combinedEnrollments),
            automaticMatchingEnabled: automaticMatchingEnabled || existingIndex.map { profiles[$0].automaticMatchingEnabled == true } == true,
            matchThreshold: existingIndex.flatMap { profiles[$0].matchThreshold }
        )
        if let index = existingIndex {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        guard canPersist() else { throw CancellationError() }
        try self.persist(Document(
            version: 1,
            profiles: profiles
        ))
        didPersist = true
        let retained = Set(profile.enrollments.compactMap(\.inspectionID))
        for id in writtenInspectionIDs where !retained.contains(id) {
            try? FileManager.default.removeItem(at: self.inspectionURL(id))
        }
    }

    /// Keep trained references when automatically learned examples reach the history limit.
    static func retainedEnrollments(_ captures: [PronunciationEnrollmentCapture]) -> [PronunciationEnrollmentCapture] {
        let protected = Set(captures.indices.filter { captures[$0].originalAudioID == nil }.suffix(3))
        let remaining = captures.indices.filter { !protected.contains($0) }.suffix(10 - protected.count)
        let selected = protected.union(remaining)
        // Manual references first so the matcher can keep its existing calibration.
        return selected.sorted { lhs, rhs in
            let leftManual = captures[lhs].originalAudioID == nil
            let rightManual = captures[rhs].originalAudioID == nil
            return leftManual == rightManual ? lhs < rhs : leftManual
        }.map { captures[$0] }
    }

    /// Validated focal audio for legacy and new automatically learned references.
    func originalAudioSamples(for capture: PronunciationEnrollmentCapture, entryID: UUID) throws -> [Float] {
        guard let id = capture.originalAudioID else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        let url = self.audioURL(id)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 2_000_000 else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        let record = try JSONDecoder().decode(OriginalAudioRecord.self, from: Data(contentsOf: url))
        guard record.version == 1, record.sampleRate == 16_000, record.encoding == "float32-little-endian",
              record.entryID == entryID, record.evidenceID == id, record.modelKey == capture.modelKey,
              record.pcmFloat32.count % MemoryLayout<Float>.size == 0,
              record.pcmFloat32.count <= 238_080 * MemoryLayout<Float>.size
        else {
            throw PronunciationDictionaryStoreError.inconsistentEnrollment
        }
        let samples = record.pcmFloat32.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: MemoryLayout<Float>.size).map { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self) }
        }
        let range = record.focalSampleRange
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= samples.count,
              samples.allSatisfy(\.isFinite) else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        return Array(samples[range])
    }

    /// Reads only the selected example. Legacy profiles explicitly have no evidence.
    func inspection(for id: UUID) throws -> DictionaryAudioInspection {
        let url = self.inspectionURL(id)
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = attributes.fileSize, size <= 24_000_000 else {
            throw PronunciationDictionaryStoreError.inconsistentEnrollment
        }
        let value = try PropertyListDecoder().decode(DictionaryAudioInspection.self, from: Data(contentsOf: url))
        guard value.isValid else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        return value
    }

    private func inspectionURL(_ id: UUID) -> URL {
        self.fileURL.deletingLastPathComponent().appendingPathComponent("pronunciation-inspection", isDirectory: true)
            .appendingPathComponent(id.uuidString).appendingPathExtension("plist")
    }

    /// Updates only this word's matching level; preserves recordings and text rules.
    func setMatchThreshold(_ threshold: Float, dictionaryEntryID: UUID) throws {
        guard threshold.isFinite, (0.4...0.95).contains(threshold) else {
            throw PronunciationDictionaryStoreError.inconsistentEnrollment
        }
        self.loadIfNeeded()
        var profiles = self.document?.profiles ?? []
        guard profiles.contains(where: { $0.dictionaryEntryID == dictionaryEntryID }) else {
            throw PronunciationDictionaryStoreError.staleEvidence
        }
        for index in profiles.indices where profiles[index].dictionaryEntryID == dictionaryEntryID {
            profiles[index].matchThreshold = threshold
        }
        try self.persist(Document(version: 1, profiles: profiles))
    }

    func replaceAllProfiles(_ profiles: [PronunciationDictionaryProfile]) throws {
        guard profiles.allSatisfy({ profile in
            profile.hiddenSize > 0 &&
                !profile.enrollments.isEmpty &&
                profile.enrollments.allSatisfy {
                    $0.modelKey == profile.modelKey && $0.values.count == profile.hiddenSize
                }
        }) else {
            throw PronunciationDictionaryStoreError.inconsistentEnrollment
        }
        try self.persist(Document(
            version: 1,
            profiles: profiles
        ))
        self.replacementGeneration = UUID()
    }

    func updateLabel(
        dictionaryEntryID: UUID,
        label: String
    ) throws {
        self.revisions[dictionaryEntryID] = UUID()
        self.loadIfNeeded()
        var profiles = self.document?.profiles ?? []
        var changed = false
        for index in profiles.indices where profiles[index].dictionaryEntryID == dictionaryEntryID {
            profiles[index].label = label
            changed = true
        }
        if changed {
            try self.persist(Document(
                version: 1,
                profiles: profiles
            ))
        }
    }

    func delete(dictionaryEntryID: UUID) throws {
        self.revisions[dictionaryEntryID] = UUID()
        self.loadIfNeeded()
        var profiles = self.document?.profiles ?? []
        let audioIDs = profiles.filter { $0.dictionaryEntryID == dictionaryEntryID }
            .flatMap(\.enrollments).compactMap(\.originalAudioID)
        profiles.removeAll { $0.dictionaryEntryID == dictionaryEntryID }
        try self.persist(Document(
            version: 1,
            profiles: profiles
        ))
        for id in audioIDs {
            try? FileManager.default.removeItem(at: self.audioURL(id))
        }
    }

    struct Revision: Equatable, Sendable {
        let entry: UUID
        let generation: UUID
    }

    func revision(for entryID: UUID) -> Revision {
        let revision = self.revisions[entryID] ?? UUID()
        self.revisions[entryID] = revision
        return Revision(
            entry: revision,
            generation: self.replacementGeneration
        )
    }

    /// Audio is written first; only the atomic profile write activates it for matching.
    /// An interrupted write can leave an inactive audio file, never a partial active enrollment.
    @discardableResult
    func learnOriginalAudio(
        entryID: UUID,
        label: String,
        evidenceID: UUID,
        evidence: DictionaryLearningAudioEvidence,
        capture: PronunciationEnrollmentCapture,
        expectedRevision: Revision,
        canPersist: @Sendable () -> Bool = { true }
    ) throws -> Bool {
        guard canPersist() else { throw CancellationError() }
        guard self.revision(for: entryID) == expectedRevision else {
            throw PronunciationDictionaryStoreError.staleEvidence
        }
        self.loadIfNeeded()
        guard capture.modelKey == evidence.modelKey, !capture.values.isEmpty,
              capture.values.allSatisfy(\.isFinite), capture.sourceFrameCount > 0,
              !evidence.samples.isEmpty, evidence.samples.count <= 238_080,
              evidence.samples.allSatisfy(\.isFinite),
              evidence.focalSampleRange.lowerBound >= 0,
              evidence.focalSampleRange.upperBound <= evidence.samples.count,
              !evidence.focalSampleRange.isEmpty,
              evidence.sourceSampleRange.lowerBound >= 0,
              evidence.sourceSampleRange.upperBound <= DictionaryLearningRecording.maximumSamples,
              evidence.sourceSampleRange.count == evidence.samples.count
        else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        let focalRange = (evidence.sourceSampleRange.lowerBound + evidence.focalSampleRange.lowerBound)..<(evidence.sourceSampleRange.lowerBound + evidence.focalSampleRange.upperBound)
        for profile in self.document?.profiles ?? [] {
            if profile.dictionaryEntryID == entryID, profile.label.caseInsensitiveCompare(label) != .orderedSame {
                throw PronunciationDictionaryStoreError.staleEvidence
            }
            for prior in profile.enrollments {
                let sameOccurrence = prior.sourceRecordingID == evidence.recordingID && prior.sourceFocalRange == focalRange
                if prior.originalAudioID == evidenceID {
                    guard profile.dictionaryEntryID == entryID, profile.modelKey == capture.modelKey, sameOccurrence else {
                        throw PronunciationDictionaryStoreError.inconsistentEnrollment
                    }
                    return false
                }
                if profile.dictionaryEntryID == entryID, profile.modelKey == capture.modelKey, sameOccurrence { return false }
            }
        }
        let record = OriginalAudioRecord(
            version: 1,
            sampleRate: 16_000,
            encoding: "float32-little-endian",
            entryID: entryID,
            intendedText: label,
            evidenceID: evidenceID,
            recordingID: evidence.recordingID,
            modelKey: evidence.modelKey,
            observedText: evidence.observedText,
            sourceSampleRange: evidence.sourceSampleRange,
            focalSampleRange: evidence.focalSampleRange,
            sourceWordRange: evidence.sourceWordRange,
            pcmFloat32: evidence.samples.withUnsafeBytes { Data($0) }
        )
        let url = self.audioURL(evidenceID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(record).write(
            to: url,
            options: .atomic
        )
        var enrolled = capture
        enrolled.extractorVersion = "parakeet-encoder-mean-l2-v1"
        enrolled.originalAudioID = evidenceID
        enrolled.observedText = evidence.observedText
        enrolled.sourceRecordingID = evidence.recordingID
        enrolled.sourceFocalRange = focalRange
        do {
            try self.upsert(
                dictionaryEntryID: entryID,
                label: label,
                modelKey: capture.modelKey,
                enrollments: [enrolled],
                canPersist: canPersist
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return true
    }

    func removeOriginalAudio(evidenceID: UUID) throws {
        self.loadIfNeeded()
        var profiles = self.document?.profiles ?? []
        for index in profiles.indices {
            profiles[index].enrollments.removeAll { $0.originalAudioID == evidenceID }
        }
        profiles.removeAll { $0.enrollments.isEmpty }
        try self.persist(Document(
            version: 1,
            profiles: profiles
        ))
        try? FileManager.default.removeItem(at: self.audioURL(evidenceID))
    }

    private struct OriginalAudioRecord: Codable {
        let version: Int
        let sampleRate: Int
        let encoding: String
        let entryID: UUID
        let intendedText: String
        let evidenceID: UUID
        let recordingID: UUID
        let modelKey: String
        let observedText: String
        let sourceSampleRange: Range<Int>
        let focalSampleRange: Range<Int>
        let sourceWordRange: Range<Int>
        let pcmFloat32: Data
    }

    private func audioURL(_ id: UUID) -> URL {
        self.fileURL.deletingLastPathComponent().appendingPathComponent(
            "pronunciation-audio",
            isDirectory: true
        )
        .appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func loadIfNeeded() {
        guard self.document == nil else { return }
        guard let data = try? Data(contentsOf: self.fileURL),
              let decoded = try? JSONDecoder().decode(
                  Document.self,
                  from: data
              ),
              decoded.version == 1
        else {
            self.document = Document(
                version: 1,
                profiles: []
            )
            return
        }
        self.document = decoded
        self.removeOrphanedAudio()
        self.removeOrphanedInspections()
    }

    /// A crash before the profile commit leaves an inactive clip; discard it after loading valid metadata.
    private func removeOrphanedAudio() {
        let referenced = Set((self.document?.profiles ?? []).flatMap(\.enrollments).compactMap(\.originalAudioID))
        let directory = self.audioURL(UUID()).deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !referenced.contains(id) else { continue }
            // Another app process may be between its audio write and profile commit.
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate, modified.timeIntervalSinceNow < -60
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func removeOrphanedInspections() {
        let referenced = Set((self.document?.profiles ?? []).flatMap(\.enrollments).compactMap(\.inspectionID))
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: self.inspectionURL(UUID()).deletingLastPathComponent(), includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files where file.pathExtension == "plist" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !referenced.contains(id),
                  let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate, modified.timeIntervalSinceNow < -60
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func persist(_ updated: Document) throws {
        try FileManager.default.createDirectory(
            at: self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(updated).write(
            to: self.fileURL,
            options: .atomic
        )
        let oldIDs = Set((self.document?.profiles ?? []).flatMap(\.enrollments).compactMap(\.originalAudioID))
        let oldInspectionIDs = Set((self.document?.profiles ?? []).flatMap(\.enrollments).compactMap(\.inspectionID))
        let newInspectionIDs = Set(updated.profiles.flatMap(\.enrollments).compactMap(\.inspectionID))
        self.document = updated
        for id in oldInspectionIDs.subtracting(newInspectionIDs) {
            try? FileManager.default.removeItem(at: self.inspectionURL(id))
        }
        let newIDs = Set(updated.profiles.flatMap(\.enrollments).compactMap(\.originalAudioID))
        for id in oldIDs.subtracting(newIDs) {
            try? FileManager.default.removeItem(at: self.audioURL(id))
        }
    }
}
