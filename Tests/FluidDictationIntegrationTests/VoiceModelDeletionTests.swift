import AppKit
@testable import FluidVoice_Debug
import SwiftUI
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
    var preparationProgressHandler: ((ModelPreparationProgress) -> Void)?

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        self.prepareCalls += 1
        self.preparationProgressHandler = progressHandler
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
    private func makeNoHardwareController(for asr: ASRService) -> DirectCoreAudioLifecycleController {
        DirectCoreAudioLifecycleController(
            packetHandler: asr.recoveryPacketHandlerForTesting,
            inputFactory: { _, _ in throw CocoaError(.fileReadUnknown) },
            fingerprintReader: { _ in throw CocoaError(.fileReadUnknown) },
            installsHardwareListeners: false,
            deviceSnapshotReader: { _ in throw CocoaError(.fileReadUnknown) },
            deviceLivenessReader: { _ in nil },
            deviceResolver: { _ in throw CocoaError(.fileReadUnknown) },
            onFormatInvalidated: { _ in }
        )
    }

    private func withDictationModeSwitchFixture(
        asr: ASRService,
        hasActiveMode: Bool = true,
        body: (ContentView) async throws -> Void
    ) async throws {
        var ready: ContentView?
        let oldMode = NotchContentState.shared.mode
        let oldSlot = NotchContentState.shared.activeDictationShortcutSlot
        let oldPrompt = NotchContentState.shared.isPromptModeActive
        let oldProfileName = NotchContentState.shared.promptModeOverrideProfileName
        let oldProfileID = NotchContentState.shared.promptModeOverrideProfileID
        let oldStopLabel = NotchContentState.shared.stopSnapshotLabel
        let manager = MenuBarManager()
        let view = ContentView.dictationModeSwitchFixture(asr: asr, hasActiveMode: hasActiveMode) { ready = $0 }
            .environmentObject(manager)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 120, height: 80)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            NotchContentState.shared.mode = oldMode
            NotchContentState.shared.activeDictationShortcutSlot = oldSlot
            NotchContentState.shared.isPromptModeActive = oldPrompt
            NotchContentState.shared.promptModeOverrideProfileName = oldProfileName
            NotchContentState.shared.promptModeOverrideProfileID = oldProfileID
            NotchContentState.shared.stopSnapshotLabel = oldStopLabel
        }
        host.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now + .seconds(3)
        while ready == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        manager.setOverlayMode(.edit)
        try await body(XCTUnwrap(ready, "SwiftUI must install the real ContentView state"))
    }

    private func replayPrimaryTap(_ manager: GlobalHotkeyManager) throws {
        for type in [CGEventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 2, keyDown: type == .keyDown))
            event.type = type
            event.flags = [.maskControl, .maskCommand]
            _ = manager.handleKeyEvent(type: type, event: event)
        }
    }

    private func makeModeSwitchHotkeyManager(
        asr: ASRService,
        view: ContentView,
        onSwitch: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) -> GlobalHotkeyManager {
        let manager = GlobalHotkeyManager(
            asrService: asr,
            primaryShortcuts: [HotkeyShortcut(keyCode: 2, modifierFlags: [.control, .command])],
            promptModeShortcut: HotkeyShortcut(keyCode: 60, modifierFlags: []),
            commandModeShortcut: nil,
            rewriteModeShortcut: HotkeyShortcut(keyCode: 58, modifierFlags: []),
            promptModeShortcutEnabled: false,
            commandModeShortcutEnabled: false,
            rewriteModeShortcutEnabled: false,
            dictationModeCallback: {
                onSwitch()
                await view.beginDictationModeSwitchForTesting()?.value
            },
            stopAndProcessCallback: { _ in onStop() },
            isDictateRecordingProvider: { view.dictationModeSwitchStateForTesting.mode == "dictate" },
            isSessionLockedProvider: { false }
        )
        manager.setHotkeyMode(.toggle)
        return manager
    }

    func testRewriteToDictateSwitchPreservesCaptureThenNextTapStops() async throws {
        let settings = SettingsStore.shared
        let selected = settings.selectedSpeechModel
        let primary = settings.dictationPromptSelection(for: .primary)
        let secondary = settings.dictationPromptSelection(for: .secondary)
        let savesHistory = settings.saveTranscriptionHistory
        let asr = ASRService()
        let provider = DeletionFixtureProvider()
        asr.modelProvidersForTesting[selected] = provider
        asr.isAsrReady = true
        asr.finalText = "retained final text"
        let samples: [Float] = [0.12, -0.24, 0.31]
        asr.configureAudioRouteRecoveryForTesting(controller: self.makeNoHardwareController(for: asr), devices: [], initialSamples: samples)
        let lease = try asr.acquireExclusiveActivity(.dictation)
        asr.configureDictationModeSwitchForTesting(ownedLease: lease)
        try await self.withDictationModeSwitchFixture(asr: asr) { view in
            let generation = view.dictationModeSwitchStateForTesting.generation
            var switches = 0
            var stops = 0
            let manager = self.makeModeSwitchHotkeyManager(asr: asr, view: view, onSwitch: { switches += 1 }, onStop: {
                stops += 1
                asr.isRunning = false
                asr.releaseExclusiveActivity(lease)
            })
            asr.errorTitle = "Dictation Unavailable"
            asr.errorMessage = "Wait for the active dictation to finish."
            asr.showError = true
            try self.replayPrimaryTap(manager)
            for _ in 0..<20 {
                await Task.yield()
            }
            XCTAssertEqual(switches, 1)
            XCTAssertEqual(stops, 0)
            XCTAssertEqual(view.dictationModeSwitchStateForTesting.mode, "dictate")
            XCTAssertEqual(view.dictationModeSwitchStateForTesting.slot, .primary)
            XCTAssertEqual(view.dictationModeSwitchStateForTesting.generation, generation)
            XCTAssertEqual(NotchContentState.shared.mode, .dictation)
            XCTAssertFalse(asr.showError, "Only the stale own-capture block should disappear")
            XCTAssertTrue(asr.isRunning)
            XCTAssertTrue(asr.canSwitchOwnedDictationCaptureMode)
            XCTAssertEqual(asr.activeExclusiveActivity, .dictation)
            XCTAssertTrue(asr.audioRouteRecoveryStateForTesting.acceptingPCM)
            XCTAssertEqual(asr.audioRouteRecoveryStateForTesting.samples, samples)
            XCTAssertTrue((asr.fileTranscriptionProvider as? DeletionFixtureProvider) === provider)
            XCTAssertTrue(asr.isAsrReady)
            XCTAssertEqual(asr.finalText, "retained final text")
            XCTAssertEqual(provider.prepareCalls + provider.clearCalls, 0)
            XCTAssertEqual(settings.selectedSpeechModel, selected)
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), primary)
            XCTAssertEqual(settings.dictationPromptSelection(for: .secondary), secondary)
            XCTAssertEqual(settings.saveTranscriptionHistory, savesHistory)
            try self.replayPrimaryTap(manager)
            for _ in 0..<20 {
                await Task.yield()
            }
            XCTAssertEqual(switches, 1, "The next tap must stop, not switch again")
            XCTAssertEqual(stops, 1)
            XCTAssertFalse(asr.isRunning)
            XCTAssertNil(asr.activeExclusiveActivity)
        }
        asr.configureDictationModeSwitchForTesting(ownedLease: nil)
        await asr.finishAudioRouteRecoveryTest()
        asr.releaseExclusiveActivity(lease)
    }

    func testRapidRewriteToDictateDoubleTapSwitchesThenStopsOnce() async throws {
        let asr = ASRService()
        asr.configureAudioRouteRecoveryForTesting(controller: self.makeNoHardwareController(for: asr), devices: [], initialSamples: [0.5])
        let lease = try asr.acquireExclusiveActivity(.dictation)
        asr.configureDictationModeSwitchForTesting(ownedLease: lease)
        try await self.withDictationModeSwitchFixture(asr: asr) { view in
            var switches = 0
            var stops = 0
            let manager = self.makeModeSwitchHotkeyManager(asr: asr, view: view, onSwitch: { switches += 1 }, onStop: {
                stops += 1
                asr.isRunning = false
                asr.releaseExclusiveActivity(lease)
            })
            try self.replayPrimaryTap(manager)
            try self.replayPrimaryTap(manager)
            for _ in 0..<30 {
                await Task.yield()
            }
            XCTAssertEqual(switches, 1)
            XCTAssertEqual(stops, 1)
            XCTAssertEqual(view.dictationModeSwitchStateForTesting.mode, "dictate")
            XCTAssertEqual(asr.audioRouteRecoveryStateForTesting.samples, [0.5])
        }
        asr.configureDictationModeSwitchForTesting(ownedLease: nil)
        await asr.finishAudioRouteRecoveryTest()
        asr.releaseExclusiveActivity(lease)
    }

    func testDictationModeSwitchRejectsForeignAndUnsettledCaptureWithoutWrites() async throws {
        let cases: [(String, ASRExclusiveActivity)] = [
            ("meeting", .meeting), ("file", .fileTranscription), ("API", .localAPI),
            ("model", .modelMaintenance), ("backup", .settingsRestore),
            ("unowned", .dictation), ("mismatch", .dictation), ("stale", .dictation),
            ("starting", .dictation), ("finalizing", .dictation), ("training", .dictation),
            ("draining", .dictation), ("recovering", .dictation),
            ("idle UI", .dictation), ("cancel save", .dictation), ("processing", .dictation)
        ]
        let settings = SettingsStore.shared
        let secondary = settings.dictationPromptSelection(for: .secondary)
        defer { settings.setDictationPromptSelection(secondary, for: .secondary) }
        let attempted: SettingsStore.DictationPromptSelection = secondary == .privateAI ? .off : .privateAI
        for (name, activity) in cases {
            let asr = ASRService()
            let provider = DeletionFixtureProvider()
            asr.modelProvidersForTesting[settings.selectedSpeechModel] = provider
            asr.isAsrReady = true
            asr.configureAudioRouteRecoveryForTesting(controller: self.makeNoHardwareController(for: asr), devices: [], initialSamples: [0.25])
            let lease = try asr.acquireExclusiveActivity(activity)
            let owned = name == "unowned" ? nil : name == "mismatch" ? ASRActivityLease(id: UUID(), activity: .dictation) : lease
            asr.configureDictationModeSwitchForTesting(ownedLease: owned, starting: name == "starting", finalizing: name == "finalizing", dictionaryTraining: name == "training")
            if name == "stale" { asr.releaseExclusiveActivity(lease) }
            let finishDrain = name == "draining" || name == "recovering" ? asr.beginDictationBufferDrainForTesting(recovering: name == "recovering") : nil
            try await self.withDictationModeSwitchFixture(asr: asr, hasActiveMode: name != "idle UI") { view in
                view.blockDictationModeSwitchForTesting(savingCancellation: name == "cancel save", processing: name == "processing")
                let before = view.dictationModeSwitchStateForTesting
                XCTAssertNil(view.beginDictationModeSwitchForTesting(selection: attempted), name)
                XCTAssertEqual(view.dictationModeSwitchStateForTesting.mode, before.mode, name)
                XCTAssertEqual(view.dictationModeSwitchStateForTesting.slot, before.slot, name)
                XCTAssertEqual(view.dictationModeSwitchStateForTesting.generation, before.generation, name)
                XCTAssertEqual(NotchContentState.shared.mode, .edit, name)
                XCTAssertEqual(settings.dictationPromptSelection(for: .secondary), secondary, name)
                XCTAssertEqual(asr.audioRouteRecoveryStateForTesting.samples, [0.25], name)
                XCTAssertTrue(asr.audioRouteRecoveryStateForTesting.acceptingPCM, name)
                XCTAssertTrue((asr.fileTranscriptionProvider as? DeletionFixtureProvider) === provider, name)
                XCTAssertEqual(provider.prepareCalls + provider.clearCalls, 0, name)
            }
            finishDrain?()
            asr.configureDictationModeSwitchForTesting(ownedLease: nil)
            await asr.finishAudioRouteRecoveryTest()
            asr.releaseExclusiveActivity(lease)
        }
    }

    func testOwnedDictationModeSwitchPreservesUnrelatedError() async throws {
        let asr = ASRService()
        asr.configureAudioRouteRecoveryForTesting(controller: self.makeNoHardwareController(for: asr), devices: [], initialSamples: [0.25])
        let lease = try asr.acquireExclusiveActivity(.dictation)
        asr.configureDictationModeSwitchForTesting(ownedLease: lease)
        asr.errorTitle = "Microphone Unavailable"
        asr.errorMessage = "Retained microphone error"
        asr.showError = true
        try await self.withDictationModeSwitchFixture(asr: asr) { view in
            XCTAssertNil(view.beginDictationModeSwitchForTesting())
            XCTAssertEqual(view.dictationModeSwitchStateForTesting.mode, "dictate")
            XCTAssertTrue(asr.showError)
            XCTAssertEqual(asr.errorTitle, "Microphone Unavailable")
            XCTAssertEqual(asr.errorMessage, "Retained microphone error")
        }
        asr.configureDictationModeSwitchForTesting(ownedLease: nil)
        await asr.finishAudioRouteRecoveryTest()
        asr.releaseExclusiveActivity(lease)
    }

    func testBusyBackupAdmissionPreservesCapturedPCMProviderAndActivity() async throws {
        let settings = SettingsStore.shared
        let previous = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = previous }
        settings.selectedSpeechModel = .appleSpeech
        let asr = ASRService()
        let original = DeletionFixtureProvider()
        let replacement = DeletionFixtureProvider()
        asr.modelProvidersForTesting[.appleSpeech] = original
        asr.modelProvidersForTesting[.parakeetTDT] = replacement
        asr.isAsrReady = true
        // Never open an input, query Core Audio, or install real hardware listeners.
        let controller = self.makeNoHardwareController(for: asr)
        let samples: [Float] = [0.12, -0.24, 0.31]
        asr.configureAudioRouteRecoveryForTesting(controller: controller, devices: [], initialSamples: samples)
        let dictation = try asr.acquireExclusiveActivity(.dictation)
        let before = asr.audioRouteRecoveryStateForTesting
        XCTAssertThrowsError(try asr.beginSettingsBackupRestore()) { error in
            guard case ASRActivityError.settingsRestoreUnavailable = error else { return XCTFail("Unexpected admission error: \(error)") }
        }
        XCTAssertEqual(settings.selectedSpeechModel, .appleSpeech)
        XCTAssertTrue((asr.fileTranscriptionProvider as? DeletionFixtureProvider) === original)
        XCTAssertTrue(asr.isAsrReady)
        XCTAssertEqual(asr.activeExclusiveActivity, .dictation)
        let after = asr.audioRouteRecoveryStateForTesting
        XCTAssertTrue(after.acceptingPCM)
        XCTAssertEqual(after.samples, samples)
        XCTAssertEqual(after.pending, before.pending)
        XCTAssertEqual(after.recovering, before.recovering)
        XCTAssertEqual(original.prepareCalls + replacement.prepareCalls, 0)
        XCTAssertEqual(original.clearCalls + replacement.clearCalls, 0)
        await asr.finishAudioRouteRecoveryTest()
        asr.releaseExclusiveActivity(dictation)
        let admitted = try asr.beginSettingsBackupRestore()
        XCTAssertEqual(asr.activeExclusiveActivity, .settingsRestore)
        asr.releaseExclusiveActivity(admitted)
        XCTAssertNil(asr.activeExclusiveActivity)
    }

    func testBackupReservationRejectsNewTranscriptionModelWorkAndPreview() async throws {
        let asr = ASRService()
        let selected = SettingsStore.shared.selectedSpeechModel
        let provider = DeletionFixtureProvider()
        asr.modelProvidersForTesting[selected] = provider
        asr.modelProvidersForTesting[.whisperTiny] = provider
        let reservation = try asr.beginSettingsBackupRestore()
        for activity: ASRExclusiveActivity in [.dictation, .fileTranscription, .localAPI, .meeting, .modelMaintenance] {
            XCTAssertThrowsError(try asr.acquireExclusiveActivity(activity))
        }
        do {
            try await asr.ensureAsrReady()
            XCTFail("Preparation must not enter while a backup is being applied")
        } catch let ASRActivityError.activityInProgress(activity) {
            XCTAssertEqual(activity, .settingsRestore)
        }
        do {
            try await asr.downloadModel(.whisperTiny, progressHandler: nil)
            XCTFail("Download must not enter while a backup is being applied")
        } catch let ASRActivityError.activityInProgress(activity) {
            XCTAssertEqual(activity, .settingsRestore)
        }
        do {
            try await asr.clearModelCache(for: .whisperTiny)
            XCTFail("Deletion must not enter while a backup is being applied")
        } catch {}
        asr.micStatus = .authorized
        await asr.startMicrophonePreview()
        XCTAssertFalse(asr.isMicrophonePreviewActive)
        XCTAssertFalse(asr.hasActiveModelDownload)
        XCTAssertFalse(asr.hasActiveModelPreparation)
        XCTAssertNil(asr.deletingModelID)
        XCTAssertEqual(provider.prepareCalls, 0)
        XCTAssertEqual(provider.clearCalls, 0)
        XCTAssertEqual(SettingsStore.shared.selectedSpeechModel, selected)
        XCTAssertEqual(asr.activeExclusiveActivity, .settingsRestore)
        asr.releaseExclusiveActivity(reservation)
        XCTAssertNil(asr.activeExclusiveActivity)
        let retry = try asr.beginSettingsBackupRestore()
        asr.releaseExclusiveActivity(retry)
    }

    func testSynchronousBackupResetPrecedesQueuedPostImportAdmission() async throws {
        let settings = SettingsStore.shared
        let previous = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = previous }
        settings.selectedSpeechModel = .parakeetTDT
        let asr = ASRService()
        asr.configureAudioRouteRecoveryForTesting(
            controller: self.makeNoHardwareController(for: asr), devices: [], initialSamples: []
        )
        await asr.finishAudioRouteRecoveryTest()
        // Provider construction is metadata-only; no preparation or model load.
        let retired = try XCTUnwrap(asr.fileTranscriptionProvider as? FluidAudioProvider)
        asr.isAsrReady = true
        let reservation = try asr.beginSettingsBackupRestore()
        settings.selectedSpeechModel = .parakeetTDTv2
        // Mirrors the unchanged-idle import tail: synchronous invalidation,
        // UI event/queued caller, then lease release, with no intervening await.
        asr.handleSettingsBackupDidRestore()
        XCTAssertTrue(asr.isAsrReady, "The held reservation defers retirement until release")
        XCTAssertEqual(asr.activeExclusiveActivity, .settingsRestore)
        let queuedCaller = Task { @MainActor in
            XCTAssertFalse(asr.isAsrReady, "A queued caller must never see old ready state after import admission releases")
            XCTAssertFalse((asr.fileTranscriptionProvider as? FluidAudioProvider) === retired, "The old cached provider must be retired before the caller runs")
            do {
                let next = try asr.acquireExclusiveActivity(.dictation)
                asr.releaseExclusiveActivity(next)
            } catch let ASRActivityError.activityInProgress(activity) {
                XCTAssertEqual(activity, .modelMaintenance, "The bounded model reset may still own admission")
            } catch { XCTFail("Unexpected queued admission error: \(error)") }
        }
        asr.releaseExclusiveActivity(reservation)
        XCTAssertFalse(asr.isAsrReady)
        XCTAssertFalse((asr.fileTranscriptionProvider as? FluidAudioProvider) === retired)
        // Cache-existence checks use a fake and never prepare/load actual models.
        let replacement = DeletionFixtureProvider()
        asr.modelProvidersForTesting[.parakeetTDTv2] = replacement
        await queuedCaller.value
        await asr.finishAudioRouteRecoveryTest()
        let deadline = ContinuousClock.now + .seconds(3)
        while asr.activeExclusiveActivity != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNil(asr.activeExclusiveActivity)
        XCTAssertEqual(replacement.prepareCalls, 0)
        XCTAssertEqual(replacement.clearCalls, 0)
        let retry = try asr.beginSettingsBackupRestore()
        asr.releaseExclusiveActivity(retry)
    }

    func testActiveDownloadRejectsBackupWithoutCancellingOrChangingIt() async throws {
        let asr = ASRService()
        let selected = SettingsStore.shared.selectedSpeechModel
        let provider = DeletionFixtureProvider()
        asr.modelProvidersForTesting[.whisperTiny] = provider
        provider.prepareBody = {
            XCTAssertTrue(asr.hasActiveModelDownload)
            XCTAssertThrowsError(try asr.beginSettingsBackupRestore())
            XCTAssertNil(asr.activeExclusiveActivity)
            XCTAssertTrue(asr.hasActiveModelDownload)
            XCTAssertFalse(asr.isCancellingModelDownload)
            XCTAssertEqual(SettingsStore.shared.selectedSpeechModel, selected)
        }
        try await asr.downloadModel(.whisperTiny, progressHandler: nil)
        XCTAssertEqual(provider.prepareCalls, 1)
        XCTAssertEqual(provider.clearCalls, 0)
        provider.prepareBody = nil
        let retry = try asr.beginSettingsBackupRestore()
        asr.releaseExclusiveActivity(retry)
    }

    func testActivePreparationRejectsBackupWithoutCancellingIt() async throws {
        let settings = SettingsStore.shared
        let previous = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = previous }
        settings.selectedSpeechModel = .whisperTiny
        let asr = ASRService()
        let provider = DeletionFixtureProvider()
        asr.modelProvidersForTesting[.whisperTiny] = provider
        provider.prepareBody = {
            XCTAssertTrue(asr.hasActiveModelPreparation)
            XCTAssertThrowsError(try asr.beginSettingsBackupRestore())
            XCTAssertNil(asr.activeExclusiveActivity)
            XCTAssertTrue(asr.hasActiveModelPreparation)
            XCTAssertFalse(asr.isCancellingModelPreparation)
            throw CocoaError(.fileReadUnknown)
        }
        do { try await asr.ensureAsrReady() } catch {}
        XCTAssertEqual(provider.prepareCalls, 1)
        XCTAssertEqual(provider.clearCalls, 0)
        provider.prepareBody = nil
        let retry = try asr.beginSettingsBackupRestore()
        asr.releaseExclusiveActivity(retry)
    }

    func testCompletedProviderResetDoesNotPermanentlyBlockBackupImport() async throws {
        let settings = SettingsStore.shared
        let previous = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = previous }
        settings.selectedSpeechModel = .whisperTiny
        let asr = ASRService()
        let provider = DeletionFixtureProvider()
        asr.modelProvidersForTesting[.whisperTiny] = provider
        asr.resetTranscriptionProvider()
        XCTAssertThrowsError(try asr.beginSettingsBackupRestore())
        let deadline = ContinuousClock.now + .seconds(3)
        while asr.activeExclusiveActivity != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNil(asr.activeExclusiveActivity)
        // Give the independent executor drain its actor turn; no ensureAsrReady
        // call is allowed to hide a stale completed reset handle in this regression.
        var reservation: ASRActivityLease?
        while reservation == nil, ContinuousClock.now < deadline {
            reservation = try? asr.beginSettingsBackupRestore()
            if reservation == nil { try await Task.sleep(for: .milliseconds(1)) }
        }
        let admitted = try XCTUnwrap(reservation)
        asr.releaseExclusiveActivity(admitted)
        XCTAssertEqual(provider.prepareCalls, 0)
        XCTAssertEqual(provider.clearCalls, 0)
        XCTAssertEqual(settings.selectedSpeechModel, .whisperTiny)
    }

    func testCancelledBackupAdmissionNeverAcquiresAnActivity() async throws {
        let asr = ASRService()
        let cancelled = Task { () throws -> ASRActivityLease in
            withUnsafeCurrentTask { $0?.cancel() }
            return try asr.beginSettingsBackupRestore()
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled imports must not reserve activity") }
        catch is CancellationError {}
        XCTAssertNil(asr.activeExclusiveActivity)
        let retry = try asr.beginSettingsBackupRestore()
        asr.releaseExclusiveActivity(retry)
    }

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

    func testCompactLoadCancellationRetainsAtomicallyPublishedModelsAndLegacyPolicy() {
        #if arch(arm64)
        for model: SettingsStore.SpeechModel in [.fluidParakeetMini, .fluidParakeetPico] {
            let provider = FluidAudioProvider(modelOverride: model, configureWordBoosting: false)
            XCTAssertFalse(
                provider.shouldClearCacheAfterCancellation,
                "The hosted downloader owns staging cleanup; cancellation during Core ML loading must retain a verified publication"
            )
            XCTAssertEqual(provider.modelsExistOnDisk(), SpeechModelInstallationSnapshot.shared.isInstalled(modelID: model.id))
        }
        for model: SettingsStore.SpeechModel in [.parakeetTDTv2, .parakeetTDT] {
            XCTAssertTrue(FluidAudioProvider(modelOverride: model, configureWordBoosting: false).shouldClearCacheAfterCancellation)
        }
        #endif
    }
    func testCompactWeightUpdatesRejectEveryForeignActivityWithoutChangingCaptureOrProvider() async throws {
        let selected = SettingsStore.shared.selectedSpeechModel
        for activity: ASRExclusiveActivity in [.dictation, .meeting, .fileTranscription, .localAPI, .settingsRestore, .modelMaintenance] {
            let asr = ASRService()
            let provider = DeletionFixtureProvider()
            asr.modelProvidersForTesting[.fluidParakeetMini] = provider
            asr.isAsrReady = true
            let lease = try asr.acquireExclusiveActivity(activity)
            do {
                try await asr.downloadModel(.fluidParakeetMini, updateWeights: true, progressHandler: nil)
                XCTFail("Updates must not enter while \(activity) owns admission")
            } catch {}
            XCTAssertEqual(asr.activeExclusiveActivity, activity)
            XCTAssertEqual(provider.prepareCalls + provider.clearCalls, 0)
            XCTAssertTrue(provider.isReady)
            XCTAssertTrue(asr.isAsrReady)
            XCTAssertFalse(asr.hasActiveModelDownload)
            XCTAssertEqual(SettingsStore.shared.selectedSpeechModel, selected)
            asr.releaseExclusiveActivity(lease)
        }
    }

    func testCompactWeightUpdatesRejectUnownedCaptureAndPendingDrains() async throws {
        for state in ["running", "starting", "finalizing", "training", "draining", "recovering"] {
            let asr = ASRService()
            let provider = DeletionFixtureProvider()
            asr.modelProvidersForTesting[.fluidParakeetMini] = provider
            asr.isAsrReady = true
            asr.isRunning = state == "running"
            asr.configureDictationModeSwitchForTesting(ownedLease: nil, starting: state == "starting", finalizing: state == "finalizing", dictionaryTraining: state == "training")
            let finish = state == "draining" || state == "recovering" ? asr.beginDictationBufferDrainForTesting(recovering: state == "recovering") : nil
            do {
                try await asr.downloadModel(.fluidParakeetMini, updateWeights: true, progressHandler: nil)
                XCTFail("Updates must not change \(state) audio")
            } catch {}
            XCTAssertEqual(provider.prepareCalls + provider.clearCalls, 0)
            XCTAssertEqual(asr.isRunning, state == "running")
            XCTAssertTrue(asr.isAsrReady)
            XCTAssertNil(asr.activeExclusiveActivity)
            XCTAssertFalse(asr.hasActiveModelDownload)
            finish?()
            asr.isRunning = false
            asr.configureDictationModeSwitchForTesting(ownedLease: nil)
        }
    }

    func testInactiveCompactWeightUpdateReservesAdmissionWithoutChangingActiveSelection() async throws {
        let settings = SettingsStore.shared
        let selected = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = selected }
        settings.selectedSpeechModel = .parakeetTDTv2
        for model: SettingsStore.SpeechModel in [.fluidParakeetMini, .fluidParakeetPico] {
            let asr = ASRService()
            let target = DeletionFixtureProvider()
            let active = DeletionFixtureProvider()
            asr.modelProvidersForTesting[model] = target
            asr.modelProvidersForTesting[.parakeetTDTv2] = active
            asr.isAsrReady = true
            target.prepareBody = {
                XCTAssertEqual(asr.activeExclusiveActivity, .modelMaintenance)
                XCTAssertTrue(asr.hasActiveModelDownload)
                XCTAssertThrowsError(try asr.acquireExclusiveActivity(.dictation))
                XCTAssertThrowsError(try asr.beginSettingsBackupRestore())
                do { try await asr.clearModelCache(for: model); XCTFail("A weight update must block deletion") } catch {}
                do { try await asr.downloadModel(.whisperTiny, progressHandler: nil); XCTFail("A weight update must block competing downloads") } catch {}
            }
            try await asr.downloadModel(model, updateWeights: true, progressHandler: nil)
            XCTAssertEqual(target.prepareCalls, 1)
            XCTAssertEqual(target.clearCalls, 0)
            XCTAssertEqual(active.prepareCalls + active.clearCalls, 0)
            XCTAssertTrue(active.isReady)
            XCTAssertTrue(asr.isAsrReady)
            XCTAssertEqual(settings.selectedSpeechModel, .parakeetTDTv2)
            XCTAssertNil(asr.activeExclusiveActivity)
            XCTAssertFalse(asr.hasActiveModelDownload)
            XCTAssertNil(asr.downloadingModelId)
        }
    }

    func testFailedOrCancelledWeightUpdateKeepsActiveProviderAndNeverClearsPublishedFiles() async throws {
        let settings = SettingsStore.shared
        let selected = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = selected }
        for model: SettingsStore.SpeechModel in [.fluidParakeetMini, .fluidParakeetPico] {
            settings.selectedSpeechModel = model
            for cancelled in [false, true] {
                let asr = ASRService()
                let provider = DeletionFixtureProvider()
                asr.modelProvidersForTesting[model] = provider
                asr.isAsrReady = true
                provider.prepareBody = {
                    if cancelled { throw CancellationError() }
                    throw URLError(.notConnectedToInternet)
                }
                do { try await asr.downloadModel(model, updateWeights: true, progressHandler: nil); XCTFail("Failure must reach the caller") } catch {}
                XCTAssertEqual(provider.prepareCalls, 1)
                XCTAssertEqual(provider.clearCalls, 0, "Explicit update failures never delete old files")
                XCTAssertTrue(provider.isReady)
                XCTAssertTrue(asr.isAsrReady)
                XCTAssertTrue((asr.fileTranscriptionProvider as? DeletionFixtureProvider) === provider)
                XCTAssertEqual(settings.selectedSpeechModel, model)
                XCTAssertNil(asr.activeExclusiveActivity)
                XCTAssertFalse(asr.hasActiveModelDownload)
                XCTAssertFalse(asr.isCancellingModelDownload)
                let retry = try asr.acquireExclusiveActivity(.dictation)
                asr.releaseExclusiveActivity(retry)
            }
        }
    }

    func testOnlyCompactModelsAcceptWeightUpdatesAndCancelledAdmissionHasNoWrites() async throws {
        let asr = ASRService()
        let provider = DeletionFixtureProvider()
        asr.modelProvidersForTesting[.parakeetTDTv2] = provider
        asr.modelProvidersForTesting[.fluidParakeetMini] = provider
        do { try await asr.downloadModel(.parakeetTDTv2, updateWeights: true, progressHandler: nil); XCTFail("Legacy models have no weight-update path") } catch {}
        let task = Task { try await asr.downloadModel(.fluidParakeetMini, updateWeights: true, progressHandler: nil) }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled admission must not begin") } catch is CancellationError {}
        XCTAssertEqual(provider.prepareCalls + provider.clearCalls, 0)
        XCTAssertNil(asr.activeExclusiveActivity)
        XCTAssertFalse(asr.hasActiveModelDownload)
    }

    func testStaleCancelledWeightUpdateProgressCannotReplaceRetryProgress() async throws {
        let settings = SettingsStore.shared
        let selected = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = selected }
        settings.selectedSpeechModel = .parakeetTDTv2
        let asr = ASRService()
        let provider = DeletionFixtureProvider()
        asr.modelProvidersForTesting[.fluidParakeetMini] = provider
        provider.prepareBody = { throw CancellationError() }
        do { try await asr.downloadModel(.fluidParakeetMini, updateWeights: true, progressHandler: nil); XCTFail("First update cancels") } catch is CancellationError {}
        let stale = provider.preparationProgressHandler
        provider.prepareBody = {
            stale?(.downloading(0.97))
            for _ in 0..<4 { await Task.yield() }
            XCTAssertNil(asr.downloadProgress, "An old operation must not update the new progress")
            provider.preparationProgressHandler?(.downloading(0.25))
            for _ in 0..<4 { await Task.yield() }
            XCTAssertEqual(asr.downloadProgress, 0.25)
        }
        try await asr.downloadModel(.fluidParakeetMini, updateWeights: true, progressHandler: nil)
        XCTAssertNil(asr.downloadProgress)
        XCTAssertEqual(provider.clearCalls, 0)
        XCTAssertEqual(settings.selectedSpeechModel, .parakeetTDTv2)
        XCTAssertNil(asr.activeExclusiveActivity)
    }

    func testSuccessfulActiveWeightUpdateInvalidatesProviderOnlyAfterPublication() async throws {
        let settings = SettingsStore.shared
        let selected = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = selected }
        settings.selectedSpeechModel = .fluidParakeetMini
        let asr = ASRService()
        let provider = DeletionFixtureProvider()
        asr.modelProvidersForTesting[.fluidParakeetMini] = provider
        asr.isAsrReady = true
        provider.prepareBody = {
            XCTAssertTrue(asr.isAsrReady, "Keep the old checkpoint ready until replacement commits")
            XCTAssertEqual(asr.activeExclusiveActivity, .modelMaintenance)
        }
        try await asr.downloadModel(.fluidParakeetMini, updateWeights: true, progressHandler: nil)
        XCTAssertFalse(asr.isAsrReady, "The next use must load the replacement checkpoint")
        XCTAssertEqual(settings.selectedSpeechModel, .fluidParakeetMini)
        XCTAssertEqual(provider.clearCalls, 0)
        let deadline = ContinuousClock.now + .seconds(2)
        while asr.activeExclusiveActivity != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNil(asr.activeExclusiveActivity)
        XCTAssertFalse(asr.hasActiveModelDownload)
    }

    func testLateCancellationAfterCommittedWeightUpdateDoesNotDeleteItsFiles() async throws {
        let settings = SettingsStore.shared
        let selected = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = selected }
        settings.selectedSpeechModel = .parakeetTDTv2
        let asr = ASRService()
        let provider = DeletionFixtureProvider()
        asr.modelProvidersForTesting[.fluidParakeetMini] = provider
        // The provider returns only after its atomic publication point.
        provider.prepareBody = { withUnsafeCurrentTask { $0?.cancel() } }
        try await asr.downloadModel(.fluidParakeetMini, updateWeights: true, progressHandler: nil)
        XCTAssertEqual(provider.prepareCalls, 1)
        XCTAssertEqual(provider.clearCalls, 0)
        XCTAssertEqual(settings.selectedSpeechModel, .parakeetTDTv2)
        XCTAssertNil(asr.activeExclusiveActivity)
        XCTAssertFalse(asr.hasActiveModelDownload)
    }

}
