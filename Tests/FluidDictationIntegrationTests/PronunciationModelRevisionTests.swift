@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class PronunciationModelRevisionTests: XCTestCase {
    func testCurrentCompactKeysIncludeFullPinnedHashAndLegacyKeysStayExact() throws {
        XCTAssertEqual(ParakeetSpeechModelCatalog.v2.pronunciationModelKey, "parakeet-v2")
        XCTAssertEqual(ParakeetSpeechModelCatalog.v3.pronunciationModelKey, "parakeet-v3")
        for descriptor in [ParakeetSpeechModelCatalog.mini, ParakeetSpeechModelCatalog.pico] {
            let hash = try XCTUnwrap(descriptor.archiveSHA256)
            XCTAssertEqual(descriptor.pronunciationModelKey, descriptor.modelID + ":sha256:" + hash)
            XCTAssertEqual(ParakeetSpeechModelCatalog.descriptor(forPronunciationModelKey: descriptor.pronunciationModelKey), descriptor)
            XCTAssertNil(ParakeetSpeechModelCatalog.descriptor(forPronunciationModelKey: descriptor.modelID))
            XCTAssertTrue(ParakeetSpeechModelCatalog.isOutdatedCompactPronunciationModelKey(descriptor.modelID))
            let old = descriptor.modelID + ":sha256:" + String(repeating: "0", count: 64)
            XCTAssertNil(ParakeetSpeechModelCatalog.descriptor(forPronunciationModelKey: old))
            XCTAssertTrue(ParakeetSpeechModelCatalog.isOutdatedCompactPronunciationModelKey(old))
            XCTAssertFalse(ParakeetSpeechModelCatalog.isOutdatedCompactPronunciationModelKey(descriptor.pronunciationModelKey))
        }
        XCTAssertEqual(ParakeetSpeechModelCatalog.descriptor(forPronunciationModelKey: "parakeet-v2"), ParakeetSpeechModelCatalog.v2)
        XCTAssertEqual(ParakeetSpeechModelCatalog.descriptor(forPronunciationModelKey: "parakeet-v3"), ParakeetSpeechModelCatalog.v3)
        XCTAssertFalse(ParakeetSpeechModelCatalog.isOutdatedCompactPronunciationModelKey("parakeet-v3"))
    }

    func testRetrainingKeepsOriginalStoredProfileAndTextEntryWithoutReusingOldVectors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PronunciationDictionaryStore(fileURL: directory.appendingPathComponent("profiles.json"))
        let descriptor = ParakeetSpeechModelCatalog.mini
        let entry = SettingsStore.CustomDictionaryEntry(triggers: ["fluid boys"], replacement: "FluidVoice")
        let originalEntry = entry
        let old = Self.profile(entryID: entry.id, key: descriptor.modelID)
        try await store.upsert(dictionaryEntryID: entry.id, label: old.label, modelKey: old.modelKey, enrollments: old.enrollments)
        let original = await store.allProfiles()
        let currentBeforeRetraining = await store.profiles(modelKey: descriptor.pronunciationModelKey)
        XCTAssertTrue(currentBeforeRetraining.isEmpty)
        #if arch(arm64)
        XCTAssertTrue(DictionaryPronunciationReferences.make(profiles: original).isEmpty)
        #endif
        let current = Self.profile(entryID: entry.id, key: descriptor.pronunciationModelKey)
        try await store.upsert(dictionaryEntryID: entry.id, label: current.label, modelKey: current.modelKey, enrollments: current.enrollments)
        let all = await store.allProfiles()
        let stillSaved = all.filter { $0.modelKey == old.modelKey }
        XCTAssertEqual(stillSaved, original)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(entry, originalEntry, "Revision checks must not change basic text corrections")
        let compatible = await store.profiles(modelKey: descriptor.pronunciationModelKey)
        XCTAssertEqual(compatible.count, 1)
        XCTAssertEqual(compatible[0].enrollments.map(\.modelKey), Array(repeating: descriptor.pronunciationModelKey, count: 3))
        #if arch(arm64)
        XCTAssertEqual(DictionaryPronunciationReferences.make(profiles: all).count, 3)
        for key in ["parakeet-v2", "parakeet-v3"] {
            XCTAssertEqual(DictionaryPronunciationReferences.make(profiles: [Self.profile(entryID: entry.id, key: key)]).count, 3)
        }
        #endif
    }

    func testFamilySelectionPrefersExactEligibleProfileAndPreservesStorage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("profiles.json")
        let store = PronunciationDictionaryStore(fileURL: url)
        let id = UUID()
        let target = ParakeetSpeechModelCatalog.mini.pronunciationModelKey
        let source = Self.profile(entryID: id, key: "parakeet-v2")
        try await store.upsert(dictionaryEntryID: id, label: source.label, modelKey: source.modelKey, enrollments: source.enrollments)
        let before = try Data(contentsOf: url)
        let shared = await store.sharedProfiles(modelKey: target, hiddenSize: source.hiddenSize)
        XCTAssertEqual(shared.map(\.modelKey), [source.modelKey])
        XCTAssertEqual(shared.first?.enrollments, source.enrollments)
        XCTAssertEqual(try Data(contentsOf: url), before, "Family reads never relabel or rewrite enrollment data")
        let incompatible = await store.sharedProfiles(modelKey: target, hiddenSize: source.hiddenSize + 1)
        XCTAssertTrue(incompatible.isEmpty)
        let unrelated = await store.sharedProfiles(modelKey: "whisper", hiddenSize: source.hiddenSize)
        XCTAssertTrue(unrelated.isEmpty)
        let exact = Self.profile(entryID: id, key: target)
        var incomplete = exact
        incomplete.enrollments = Array(exact.enrollments.prefix(1))
        XCTAssertEqual(PronunciationDictionaryStore.selectSharedProfiles([source, incomplete], modelKey: target, hiddenSize: 2), [source])
        for ordered in [[source, exact], [exact, source]] {
            XCTAssertEqual(PronunciationDictionaryStore.selectSharedProfiles(ordered, modelKey: target, hiddenSize: 2), [exact])
        }
        let keys = ParakeetSpeechModelCatalog.descriptors.map(\.pronunciationModelKey)
        for sourceKey in keys {
            for targetKey in keys {
                XCTAssertTrue(ParakeetSpeechModelCatalog.sharesPronunciationFamily(sourceKey, with: targetKey))
            }
        }
        for invalid in ["", "whisper", "parakeet-v4", "fluid-parakeet-mini:sha256:bad"] {
            XCTAssertFalse(ParakeetSpeechModelCatalog.sharesPronunciationFamily(invalid, with: target))
        }
    }

    func testOldNegativeFramesAreInactiveAndRemainStoredWithoutAReadMutation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("negative.plist")
        let store = DictionaryNegativeExampleStore(url: url, collectionEnabled: { true })
        let id = UUID()
        let oldKey = ParakeetSpeechModelCatalog.mini.modelID
        let currentKey = ParakeetSpeechModelCatalog.mini.pronunciationModelKey
        let frames = DictionaryMatchFrames(hiddenSize: 2, values: [1, 0, 1, 0])
        let evidence = DictionaryAcousticEvidence(id: UUID(), entryID: id, label: "FluidVoice", profileKey: "fixture", modelKey: oldKey, sourceWordRange: 0..<1, frames: frames)
        let revision = await store.revision()
        try await store.save(.init(evidence: evidence, correctedText: "different", expiresAt: Date().addingTimeInterval(60)), expectedRevision: revision)
        let before = try Data(contentsOf: url)
        let inactive = await store.frames(entryID: id, profileKey: "fixture", modelKey: oldKey)
        let current = await store.frames(entryID: id, profileKey: "fixture", modelKey: currentKey)
        XCTAssertTrue(inactive.isEmpty)
        XCTAssertTrue(current.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), before)
        let saved = try PropertyListDecoder().decode([DictionaryNegativeExampleStore.Example].self, from: before)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].modelKey, oldKey)
        for key in [currentKey, "parakeet-v2", "parakeet-v3"] {
            let currentID = UUID()
            let currentEvidence = DictionaryAcousticEvidence(id: UUID(), entryID: currentID, label: "Current", profileKey: "current-fixture", modelKey: key, sourceWordRange: 0..<1, frames: frames)
            try await store.save(.init(evidence: currentEvidence, correctedText: "different", expiresAt: Date().addingTimeInterval(60)), expectedRevision: revision)
            let compatible = await store.frames(entryID: currentID, profileKey: "current-fixture", modelKey: key)
            XCTAssertEqual(compatible, [frames], "Current and legacy checkpoints must still use their own negative frames")
        }
        let after = try PropertyListDecoder().decode([DictionaryNegativeExampleStore.Example].self, from: Data(contentsOf: url))
        XCTAssertTrue(after.contains { $0.modelKey == oldKey }, "Reading inactive negatives must not silently erase them")
    }

    func testNoticeAndReplayAskToRetrainOnlyAffectedActiveWords() throws {
        let descriptor = ParakeetSpeechModelCatalog.mini
        let id = UUID()
        let old = Self.profile(entryID: id, key: descriptor.modelID)
        let current = Self.profile(entryID: id, key: descriptor.pronunciationModelKey)
        let notice = DictionaryPronunciationRevisionPolicy.notice(profiles: [old], descriptor: descriptor, entryIDs: [id])
        XCTAssertNil(notice, "Parakeet family recordings remain available after a model update")
        XCTAssertNil(DictionaryPronunciationRevisionPolicy.notice(profiles: [old, current], descriptor: descriptor, entryIDs: [id]))
        XCTAssertNil(DictionaryPronunciationRevisionPolicy.notice(profiles: [old], descriptor: descriptor, entryIDs: []))
        XCTAssertNil(DictionaryPronunciationRevisionPolicy.notice(profiles: [old], descriptor: ParakeetSpeechModelCatalog.pico, entryIDs: [id]))
        XCTAssertNil(DictionaryPronunciationRevisionPolicy.notice(profiles: [old], descriptor: ParakeetSpeechModelCatalog.v3, entryIDs: [id]))
        XCTAssertThrowsError(try DictionaryMatchPlayground.targetProfile(from: [old], target: "fluidvoice")) { error in
            XCTAssertEqual(error as? PronunciationDictionaryStoreError, .outdatedModelRevision)
            XCTAssertTrue(error.localizedDescription.contains("Retrain this word"))
        }
        XCTAssertEqual(try DictionaryMatchPlayground.targetProfile(from: [old, current], target: "fluidvoice"), current)
    }

    #if arch(arm64)
    func testProfileCannotMixEnrollmentVectorsFromDifferentRevisions() {
        let current = ParakeetSpeechModelCatalog.mini.pronunciationModelKey
        var profile = Self.profile(entryID: UUID(), key: current)
        profile.enrollments[0] = PronunciationEnrollmentCapture(values: [1, 0], sourceFrameCount: 6, modelKey: ParakeetSpeechModelCatalog.mini.modelID)
        XCTAssertTrue(DictionaryPronunciationReferences.make(profiles: [profile]).isEmpty)
    }

    func testOldOriginalAudioEvidenceIsRejectedBeforeAnyModelLoad() async throws {
        let evidence = DictionaryLearningAudioEvidence(
            recordingID: UUID(),
            modelKey: ParakeetSpeechModelCatalog.mini.modelID,
            observedText: "fluid boys",
            sourceWordRange: 0..<1,
            sourceSampleRange: 0..<1,
            focalSampleRange: 0..<1,
            samples: [0.1]
        )
        do {
            _ = try await OriginalAudioEmbeddingExtractor.extract(evidence)
            XCTFail("Old revision evidence must never load the current encoder")
        } catch let error as PronunciationDictionaryStoreError {
            XCTAssertEqual(error, .outdatedModelRevision)
        }
    }
    #endif

    #if arch(arm64)
    func testExplicitMatchingSharesParakeetFamilyWithoutMixingStoredEnrollments() {
        let descriptor = ParakeetSpeechModelCatalog.mini
        let oldKey = descriptor.modelID + ":sha256:" + String(repeating: "a", count: 64)
        let old = Self.profile(entryID: UUID(), key: oldKey)
        let latest = Self.profile(entryID: UUID(), key: descriptor.pronunciationModelKey)
        XCTAssertTrue(DictionaryPronunciationReferences.make(profiles: [old]).isEmpty)
        let oldReferences = DictionaryPronunciationReferences.make(profiles: [old, latest], compatibleModelKey: oldKey)
        XCTAssertEqual(oldReferences.count, 6)
        XCTAssertEqual(Set(oldReferences.map { $0.profile.modelKey }), [oldKey, descriptor.pronunciationModelKey])
        let latestReferences = DictionaryPronunciationReferences.make(profiles: [old, latest], compatibleModelKey: descriptor.pronunciationModelKey)
        XCTAssertEqual(latestReferences.count, 6)
        var mixed = old
        mixed.enrollments[0] = latest.enrollments[0]
        XCTAssertTrue(DictionaryPronunciationReferences.make(profiles: [mixed], compatibleModelKey: oldKey).isEmpty)
        let unversioned = Self.profile(entryID: UUID(), key: descriptor.modelID)
        XCTAssertEqual(DictionaryPronunciationReferences.make(profiles: [unversioned], compatibleModelKey: descriptor.modelID).count, 3)
    }

    func testNormalProviderPreparationKeepsCompleteOldWeightsAndTheirActualPronunciationKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for model: SettingsStore.SpeechModel in [.fluidParakeetMini, .fluidParakeetPico] {
            let descriptor = try XCTUnwrap(model.parakeetDescriptor)
            let installed = descriptor.cacheDirectory(in: root)
            try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
            let oldHash = String(repeating: "a", count: 64)
            try Data(oldHash.utf8).write(to: installed.appendingPathComponent(ParakeetSpeechModelCatalog.installationRevisionFileName))
            try Data("{}".utf8).write(to: installed.appendingPathComponent(descriptor.vocabularyFile))
            for name in descriptor.requiredModelNames {
                let folder = installed.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: folder.appendingPathComponent("weights"), withIntermediateDirectories: true)
                for file in ["coremldata.bin", "metadata.json", "weights/weight.bin"] {
                    try Data("fixture".utf8).write(to: folder.appendingPathComponent(file))
                }
            }
            XCTAssertEqual(descriptor.installedArchiveSHA256(at: installed), oldHash)
            let provider = FluidAudioProvider(modelOverride: model, configureWordBoosting: false)
            provider.modelCacheRootForTesting = root
            do {
                try await ASRService().prepareProviderRecoveryForTesting(provider, modelsAlreadyCached: true)
                XCTFail("Dummy Core ML files must fail locally without deleting old weights for recovery")
            } catch {}
            XCTAssertEqual(provider.pronunciationModelKeyForTesting, descriptor.modelID + ":sha256:" + oldHash)
            XCTAssertEqual(descriptor.installedArchiveSHA256(at: installed), oldHash, "Normal loading must never erase an older complete download")
            XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent(descriptor.vocabularyFile)), Data("{}".utf8))
        }
    }
    #endif

    private static func profile(entryID: UUID, key: String) -> PronunciationDictionaryProfile {
        let captures = Array(repeating: PronunciationEnrollmentCapture(values: [1, 0], sourceFrameCount: 6, modelKey: key), count: 3)
        return PronunciationDictionaryProfile(dictionaryEntryID: entryID, label: "FluidVoice", modelKey: key, hiddenSize: 2, enrollments: captures)
    }
}
