@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
private final class DeletionFixtureProvider: TranscriptionProvider {
    let name = "Deletion fixture"
    let isAvailable = true
    var isReady = true
    var clearCalls = 0
    var prepareCalls = 0
    var cachedFilesExist = false
    var clear: (() async throws -> Void)?
    var prepareBody: (() async throws -> Void)?

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        self.prepareCalls += 1
        try await self.prepareBody?()
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        ASRTranscriptionResult(text: "", confidence: 0)
    }

    func modelsExistOnDisk() -> Bool { self.cachedFilesExist }

    func clearCache() async throws {
        self.clearCalls += 1
        try await self.clear?()
        self.isReady = false
    }
}

@MainActor
final class VoiceModelDeletionTests: XCTestCase {
    func testCancelledDownloadKeepsCleanupFailureAndDoesNotClearPublishedCache() async throws {
        let selected = SettingsStore.shared.selectedSpeechModel
        let retained = FileManager.default.temporaryDirectory.appendingPathComponent("retained-download-stage")
        let asr = ASRService()
        let provider = DeletionFixtureProvider()
        provider.cachedFilesExist = true
        provider.prepareBody = {
            withUnsafeCurrentTask { $0?.cancel() }
            throw ParakeetArchiveDownloader.DownloadError.cleanupFailed(retained)
        }
        asr.modelProvidersForTesting[.fluidParakeetMini] = provider
        do {
            try await asr.downloadModel(.fluidParakeetMini, progressHandler: nil)
            XCTFail("The retained cleanup path must reach the caller")
        } catch let error as ParakeetArchiveDownloader.DownloadError {
            guard case let .cleanupFailed(path) = error else { return XCTFail("Unexpected archive failure") }
            XCTAssertEqual(path, retained)
        }
        XCTAssertEqual(provider.clearCalls, 0)
        XCTAssertEqual(provider.prepareCalls, 1)
        XCTAssertEqual(SettingsStore.shared.selectedSpeechModel, selected)
        XCTAssertFalse(asr.hasActiveModelDownload)
        XCTAssertFalse(asr.isCancellingModelDownload)
        XCTAssertNil(asr.downloadingModelId)
    }

    func testPreparationCleanupFailureSkipsDestructiveRetryEvenWhenCancelled() async throws {
        guard SettingsStore.SpeechModel.availableModels.contains(.fluidParakeetMini) else {
            throw XCTSkip("Compact model preparation requires a supported Mac and macOS version")
        }
        let settings = SettingsStore.shared
        let previous = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = previous }
        settings.selectedSpeechModel = .fluidParakeetMini
        let retained = FileManager.default.temporaryDirectory.appendingPathComponent("retained-preparation-stage")
        for cancelled in [false, true] {
            for cached in [false, true] {
                let asr = ASRService()
                let provider = DeletionFixtureProvider()
                provider.cachedFilesExist = cached
                provider.prepareBody = {
                    if cancelled { withUnsafeCurrentTask { $0?.cancel() } }
                    throw ParakeetArchiveDownloader.DownloadError.cleanupFailed(retained)
                }
                asr.modelProvidersForTesting[.fluidParakeetMini] = provider
                do {
                    try await asr.ensureAsrReady()
                    XCTFail("The retained cleanup path must reach the caller")
                } catch let error as ParakeetArchiveDownloader.DownloadError {
                    guard case let .cleanupFailed(path) = error else { return XCTFail("Unexpected archive failure") }
                    XCTAssertEqual(path, retained)
                }
                XCTAssertEqual(provider.prepareCalls, 1)
                XCTAssertEqual(provider.clearCalls, 0, "A staging failure must preserve published model files")
                XCTAssertFalse(asr.isAsrReady)
                XCTAssertFalse(asr.hasActiveModelPreparation)
                XCTAssertFalse(asr.isCancellingModelPreparation)
                XCTAssertFalse(asr.isDownloadingModel)
                XCTAssertFalse(asr.isLoadingModel)
            }
        }
    }

    func testRestoredCompactSelectionRetiresReadyModelOnlyAfterActiveWorkFinishes() async throws {
        let settings = SettingsStore.shared
        let previous = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = previous }
        for model: SettingsStore.SpeechModel in [.fluidParakeetMini, .fluidParakeetPico] {
            settings.selectedSpeechModel = .parakeetTDT
            let asr = ASRService()
            let old = DeletionFixtureProvider()
            let restored = DeletionFixtureProvider()
            asr.modelProvidersForTesting[.parakeetTDT] = old
            asr.modelProvidersForTesting[model] = restored
            asr.isAsrReady = true
            let lease = try asr.acquireExclusiveActivity(.dictation)
            settings.selectedSpeechModel = model
            asr.handleSettingsBackupDidRestore()
            XCTAssertTrue(asr.isAsrReady, "Restoring settings must not interrupt active dictation")
            XCTAssertEqual(asr.activeExclusiveActivity, .dictation)
            XCTAssertEqual(old.clearCalls, 0)
            XCTAssertEqual(restored.prepareCalls, 0)
            await asr.finishAudioRouteRecoveryTest()
            asr.releaseExclusiveActivity(lease)
            XCTAssertFalse(asr.isAsrReady, "The old ready model must be retired before the next dictation")
            XCTAssertEqual(settings.selectedSpeechModel, model)
            XCTAssertEqual(old.clearCalls, 0, "Restoring settings must retain downloaded files")
            let deadline = Date().addingTimeInterval(2)
            while asr.activeExclusiveActivity != nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertNil(asr.activeExclusiveActivity)
        }
    }

    func testCompactModelDownloadsKeepActiveSelectionAndRejectCompetingDeletion() async throws {
        let settings = SettingsStore.shared
        let previous = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = previous }
        settings.selectedSpeechModel = .parakeetTDT
        for model: SettingsStore.SpeechModel in [.fluidParakeetMini, .fluidParakeetPico] {
            let asr = ASRService()
            let target = DeletionFixtureProvider()
            let active = DeletionFixtureProvider()
            asr.isAsrReady = true
            asr.modelProvidersForTesting[model] = target
            asr.modelProvidersForTesting[.parakeetTDT] = active
            target.prepareBody = {
                XCTAssertEqual(asr.downloadingModelId, model.id)
                XCTAssertEqual(settings.selectedSpeechModel, .parakeetTDT)
                do {
                    try await asr.clearModelCache(for: model)
                    XCTFail("A model being downloaded must not be deleted")
                } catch {}
                XCTAssertTrue(asr.hasActiveModelDownload)
            }
            try await asr.downloadModel(model, progressHandler: nil)
            XCTAssertEqual(target.prepareCalls, 1)
            XCTAssertEqual(active.prepareCalls, 0)
            XCTAssertEqual(active.clearCalls, 0)
            XCTAssertTrue(active.isReady)
            XCTAssertTrue(asr.isAsrReady)
            XCTAssertEqual(settings.selectedSpeechModel, .parakeetTDT)
            XCTAssertFalse(asr.hasActiveModelDownload)
            XCTAssertNil(asr.downloadingModelId)
            target.prepareBody = nil
        }
    }

    func testCompactModelFailedAndCancelledDownloadsReleaseAdmission() async throws {
        let selected = SettingsStore.shared.selectedSpeechModel
        for model: SettingsStore.SpeechModel in [.fluidParakeetMini, .fluidParakeetPico] {
            let asr = ASRService()
            let provider = DeletionFixtureProvider()
            asr.modelProvidersForTesting[model] = provider
            for cancelled in [false, true] {
                provider.prepareBody = {
                    if cancelled { throw CancellationError() }
                    throw URLError(.notConnectedToInternet)
                }
                do {
                    try await asr.downloadModel(model, progressHandler: nil)
                    XCTFail("Failure must reach the caller")
                } catch {}
                XCTAssertEqual(SettingsStore.shared.selectedSpeechModel, selected)
                XCTAssertFalse(asr.hasActiveModelDownload)
                XCTAssertNil(asr.downloadingModelId)
                XCTAssertFalse(asr.isCancellingModelDownload)
            }
            provider.prepareBody = nil
            try await asr.downloadModel(model, progressHandler: nil)
            XCTAssertEqual(provider.prepareCalls, 3)
        }
    }

    func testLegacyNemotronDeletionUsesCanonicalProviderAndInvalidatesOnlyActiveModel() async throws {
        let settings = SettingsStore.shared
        let previous = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = previous }
        for selected: SettingsStore.SpeechModel in [.nemotronStreaming, .whisperBase] {
            settings.selectedSpeechModel = selected
            let isActive = selected == .nemotronStreaming
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let streamingFile = directory.appendingPathComponent("streaming")
            let offlineFile = directory.appendingPathComponent("offline")
            try Data([1]).write(to: streamingFile)
            try Data([2]).write(to: offlineFile)
            let asr = ASRService()
            let canonical = DeletionFixtureProvider()
            let alias = DeletionFixtureProvider()
            let unrelated = DeletionFixtureProvider()
            asr.modelProvidersForTesting[.nemotronStreaming] = canonical
            asr.modelProvidersForTesting[.nemotronStreaming320] = alias
            asr.modelProvidersForTesting[.whisperBase] = unrelated
            asr.isAsrReady = true
            canonical.clear = {
                XCTAssertEqual(asr.deletingModelID, SettingsStore.SpeechModel.nemotronStreaming.id)
                XCTAssertEqual(asr.activeExclusiveActivity, .modelMaintenance)
                XCTAssertEqual(asr.isAsrReady, !isActive, "Invalidate the active model before deleting its files")
                try FileManager.default.removeItem(at: streamingFile)
            }
            try await asr.clearModelCache(for: .nemotronStreaming320)
            // Active deletion starts the existing asynchronous provider reset.
            let resetDeadline = Date().addingTimeInterval(2)
            while asr.activeExclusiveActivity != nil, Date() < resetDeadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertEqual(canonical.clearCalls, 1)
            XCTAssertFalse(canonical.isReady)
            XCTAssertEqual(alias.clearCalls, 0)
            XCTAssertEqual(unrelated.clearCalls, 0)
            XCTAssertTrue(unrelated.isReady)
            XCTAssertEqual(asr.isAsrReady, !isActive)
            XCTAssertEqual(settings.selectedSpeechModel, selected)
            XCTAssertFalse(FileManager.default.fileExists(atPath: streamingFile.path))
            XCTAssertEqual(try Data(contentsOf: offlineFile), Data([2]))
            XCTAssertNil(asr.deletingModelID)
            XCTAssertNil(asr.activeExclusiveActivity)
            canonical.clear = nil
        }
    }

    func testInactiveDeletionRemovesOnlyTargetAndKeepsSelection() async throws {
        let settings = SettingsStore.shared
        let previous = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = previous }
        settings.selectedSpeechModel = .whisperBase
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = try directory.appendingPathComponent(XCTUnwrap(SettingsStore.SpeechModel.whisperTiny.whisperModelFile))
        let sibling = try directory.appendingPathComponent(XCTUnwrap(SettingsStore.SpeechModel.whisperBase.whisperModelFile))
        let targetLegacy = directory.appendingPathComponent("ggml-tiny.bin")
        let siblingLegacy = directory.appendingPathComponent("ggml-base.bin")
        try Data([3]).write(to: targetLegacy)
        try Data([4]).write(to: siblingLegacy)
        try Data([1]).write(to: target)
        try Data([2]).write(to: sibling)
        let active = DeletionFixtureProvider()
        let asr = ASRService()
        asr.isAsrReady = true
        asr.modelProvidersForTesting[.whisperBase] = active
        asr.modelProvidersForTesting[.whisperTiny] = WhisperProvider(modelDirectory: directory, modelOverride: .whisperTiny)
        try await asr.clearModelCache(for: .whisperTiny)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetLegacy.path))
        XCTAssertEqual(try Data(contentsOf: siblingLegacy), Data([4]))
        XCTAssertEqual(try Data(contentsOf: sibling), Data([2]))
        XCTAssertEqual(settings.selectedSpeechModel, .whisperBase)
        XCTAssertTrue(asr.isAsrReady)
        XCTAssertTrue(active.isReady)
        XCTAssertEqual(active.clearCalls, 0)
        XCTAssertNil(asr.deletingModelID)
        XCTAssertNil(asr.activeExclusiveActivity)
        // Repeated deletion is safe and does not remove the sibling.
        try await asr.clearModelCache(for: .whisperTiny)
        XCTAssertEqual(try Data(contentsOf: sibling), Data([2]))
    }

    func testActiveDeletionUsesCurrentProviderAndBlocksCompetingWork() async throws {
        let settings = SettingsStore.shared
        let previous = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = previous }
        settings.selectedSpeechModel = .whisperBase
        let asr = ASRService()
        let provider = DeletionFixtureProvider()
        asr.modelProvidersForTesting[.whisperBase] = provider
        asr.isAsrReady = true
        provider.clear = {
            XCTAssertEqual(asr.deletingModelID, SettingsStore.SpeechModel.whisperBase.id)
            XCTAssertEqual(asr.activeExclusiveActivity, .modelMaintenance)
            XCTAssertFalse(asr.isAsrReady)
            do {
                try await asr.downloadModel(.whisperTiny, progressHandler: nil)
                XCTFail("Download must not start during deletion")
            } catch {}
            do {
                try await asr.ensureAsrReady()
                XCTFail("Preparation must not start during deletion")
            } catch {}
            do {
                try await asr.clearModelCache(for: .whisperTiny)
                XCTFail("A second deletion must not start")
            } catch {}
            XCTAssertFalse(asr.hasActiveModelDownload)
            XCTAssertFalse(asr.hasActiveModelPreparation)
        }
        try await asr.clearModelCache()
        XCTAssertEqual(provider.clearCalls, 1)
        XCTAssertFalse(provider.isReady)
        XCTAssertEqual(provider.prepareCalls, 0)
        XCTAssertFalse(asr.isAsrReady)
        XCTAssertEqual(settings.selectedSpeechModel, .whisperBase)
        XCTAssertNil(asr.deletingModelID)
        provider.clear = nil
    }

    func testFailureAndBusyActivityDoNotChangeSelectionOrLeaveDeletionBlocked() async throws {
        let asr = ASRService()
        let provider = DeletionFixtureProvider()
        let selected = SettingsStore.shared.selectedSpeechModel
        asr.modelProvidersForTesting[.whisperTiny] = provider
        let lease = try asr.acquireExclusiveActivity(.dictation)
        do {
            try await asr.clearModelCache(for: .whisperTiny)
            XCTFail("Deletion must not interrupt dictation")
        } catch {}
        XCTAssertEqual(provider.clearCalls, 0)
        XCTAssertEqual(asr.activeExclusiveActivity, .dictation)
        asr.releaseExclusiveActivity(lease)
        provider.clear = { throw CocoaError(.fileWriteNoPermission) }
        do {
            try await asr.clearModelCache(for: .whisperTiny)
            XCTFail("Deletion failures must reach the caller")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteNoPermission.rawValue)
        }
        XCTAssertEqual(SettingsStore.shared.selectedSpeechModel, selected)
        XCTAssertNil(asr.deletingModelID)
        provider.clear = nil
        try await asr.clearModelCache(for: .whisperTiny)
        XCTAssertEqual(provider.clearCalls, 2)
    }

    func testDownloadInProgressRejectsDeletionWithoutCancellingDownload() async throws {
        let asr = ASRService()
        let provider = DeletionFixtureProvider()
        asr.modelProvidersForTesting[.whisperTiny] = provider
        provider.prepareBody = {
            XCTAssertTrue(asr.hasActiveModelDownload)
            do {
                try await asr.clearModelCache(for: .whisperTiny)
                XCTFail("Deletion must not remove a downloading model")
            } catch {}
            XCTAssertTrue(asr.hasActiveModelDownload)
            XCTAssertFalse(asr.isCancellingModelDownload)
            XCTAssertNil(asr.deletingModelID)
        }
        try await asr.downloadModel(.whisperTiny, progressHandler: nil)
        XCTAssertEqual(provider.prepareCalls, 1)
        XCTAssertEqual(provider.clearCalls, 0)
        XCTAssertFalse(asr.hasActiveModelDownload)
        provider.prepareBody = nil
    }

    func testPreparationInProgressRejectsDeletion() async throws {
        let settings = SettingsStore.shared
        let previous = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = previous }
        settings.selectedSpeechModel = .whisperTiny
        let asr = ASRService()
        let provider = DeletionFixtureProvider()
        asr.modelProvidersForTesting[.whisperTiny] = provider
        provider.prepareBody = {
            XCTAssertTrue(asr.hasActiveModelPreparation)
            do {
                try await asr.clearModelCache(for: .whisperTiny)
                XCTFail("Deletion must not interrupt model preparation")
            } catch {}
            XCTAssertTrue(asr.hasActiveModelPreparation)
            XCTAssertFalse(asr.isCancellingModelPreparation)
            throw CocoaError(.fileReadUnknown)
        }
        do { try await asr.ensureAsrReady() } catch {}
        XCTAssertEqual(provider.prepareCalls, 1)
        XCTAssertEqual(provider.clearCalls, 0)
        XCTAssertFalse(asr.hasActiveModelPreparation)
        provider.prepareBody = nil
    }

    func testCancelledDeletionDoesNotTouchFilesOrLeaveBusyState() async throws {
        let asr = ASRService()
        let provider = DeletionFixtureProvider()
        asr.modelProvidersForTesting[.whisperTiny] = provider
        let task = Task { try await asr.clearModelCache(for: .whisperTiny) }
        task.cancel()
        do {
            try await task.value
            XCTFail("A cancelled request must not delete anything")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(provider.clearCalls, 0)
        XCTAssertNil(asr.deletingModelID)
        XCTAssertNil(asr.activeExclusiveActivity)
    }
}
