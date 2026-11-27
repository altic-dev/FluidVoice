import AppKit
import Combine
import Foundation
import os
import SwiftUI
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Publishes whether the model storage location is usable, reacts to drives coming and going, and runs moves.
@MainActor
final class ModelStorageMonitor: ObservableObject {
    static let shared = ModelStorageMonitor()

    enum MoveChoice: Equatable {
        case moveExisting
        case useExisting
    }

    private typealias ProbeResult = (ModelStorageAvailability, Int64?, String?)

    @Published private(set) var configuration: ModelStorageConfiguration
    @Published private(set) var availability: ModelStorageAvailability
    @Published private(set) var freeBytes: Int64?
    @Published private(set) var volumeName: String?
    @Published private(set) var moveProgress: ModelStorageMoveProgress?
    @Published private(set) var lastMoveMessage: String?
    @Published private(set) var leftoverLinks: [String] = []
    @Published private(set) var interruptedMoveNotice: String?
    /// False once the folder switch begins; the switch either completes or rolls back.
    @Published private(set) var canCancelMove = false

    private var started = false
    private var hasProbed = false
    private var observers: [NSObjectProtocol] = []
    private var moveTask: Task<Void, Never>?
    private var meetingModelNeedsRecheck = false
    private var probeGeneration = 0
    private let probeTimeoutNanoseconds: UInt64 = 5_000_000_000

    var isMoving: Bool {
        self.moveTask != nil
    }

    var displayPath: String {
        self.configuration.rootPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Default"
    }

    init() {
        let configuration = ModelStorageLocation.configuration
        self.configuration = configuration
        self.availability = configuration.usesCustomRoot ? .available(root: configuration.resolvedRootURL ?? URL(fileURLWithPath: "/")) : .defaultLocations
    }

    func start() {
        guard !self.started else { return }
        self.started = true
        self.recoverInterruptedMove()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            self.observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            })
        }
        self.observers.append(center.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor in self?.volumeWillUnmount(volume) }
        })
        Task { await self.refresh() }
    }

    private func recoverInterruptedMove() {
        Task {
            let entry = await Task.detached(priority: .utility) { ModelStorageMoveJournal.standard.recoverInterruptedMove() }.value
            guard let entry else { return }
            self.interruptedMoveNotice = entry.phase == .copying
                ? "The last model move did not finish. Your models are still in their original location."
                : "The last model move was interrupted while switching folders. Check that your models show as installed."
        }
    }

    // MARK: - Availability

    /// Probes off the main actor with a deadline, because a sleeping or network volume can block file calls.
    func refresh() async {
        self.probeGeneration &+= 1
        let generation = self.probeGeneration
        let configuration = ModelStorageLocation.configuration
        let timeout = self.probeTimeoutNanoseconds
        let probe = Task.detached(priority: .utility) { Self.measure(configuration) }
        let timedOut: ProbeResult = (
            .driveNotConnected(volumeName: configuration.volumeName, path: configuration.rootPath ?? ""), nil, nil
        )
        // A blocked file call cannot be canceled, so the first of the probe and the deadline wins.
        let (first, didTimeOut) = await withCheckedContinuation { (continuation: CheckedContinuation<(ProbeResult, Bool), Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable ((ProbeResult, Bool)) -> Void = { value in
                let isFirst = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if isFirst { continuation.resume(returning: value) }
            }
            Task.detached { await finish((probe.value, false)) }
            Task.detached {
                try? await Task.sleep(nanoseconds: timeout)
                finish((timedOut, true))
            }
        }
        guard generation == self.probeGeneration else { return }
        await self.apply(first, configuration: configuration)
        guard didTimeOut else { return }
        // A slow drive still answers eventually; that answer replaces the timeout unless a newer probe ran.
        let late = await probe.value
        guard generation == self.probeGeneration else { return }
        await self.apply(late, configuration: configuration)
    }

    private nonisolated static func measure(_ configuration: ModelStorageConfiguration) -> ProbeResult {
        let availability = ModelStorageLocation.probe(configuration)
        let directory: URL? = switch availability {
        case .defaultLocations: ModelStorageLocation.defaultApplicationSupportDirectory
        case let .available(root): root
        default: nil
        }
        return (availability, directory.flatMap(ModelStorageLocation.availableCapacity), directory.flatMap(ModelStorageLocation.volumeName))
    }

    private func apply(_ result: ProbeResult, configuration: ModelStorageConfiguration) async {
        let (availability, free, volume) = result
        if case let .available(root) = availability, let rootPath = configuration.rootPath,
           URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().standardizedFileURL.path != root.path
        {
            // The bookmark found the folder at a new place, for example after a volume rename.
            ModelStorageLocation.apply(.custom(root: root))
            self.lastMoveMessage = "FluidVoice found the model folder at its new location, \((root.path as NSString).abbreviatingWithTildeInPath)."
        }

        let previous = self.availability
        let wasProbed = self.hasProbed
        self.hasProbed = true
        self.configuration = ModelStorageLocation.configuration
        self.availability = availability
        self.freeBytes = free
        self.volumeName = volume
        guard wasProbed, previous.isUsable != availability.isUsable else { return }
        if availability.isUsable {
            DebugLogger.shared.info("ModelStorage: model storage became available", source: "ModelStorage")
            self.recoverInterruptedMove()
            await self.reloadModels()
        } else {
            DebugLogger.shared.warning("ModelStorage: model storage became unavailable", source: "ModelStorage")
            self.releaseModels()
            SpeechModelInstallationSnapshot.shared.refresh()
            if case .ready = MeetingDiarizationModelStore.shared.state { self.meetingModelNeedsRecheck = true }
        }
    }

    private func volumeWillUnmount(_ volume: URL?) {
        guard let volume, let root = self.configuration.resolvedRootURL else { return }
        let volumePath = volume.standardizedFileURL.path
        guard root.path == volumePath || root.path.hasPrefix(volumePath + "/") else { return }
        DebugLogger.shared.info("ModelStorage: releasing models before the model drive unmounts", source: "ModelStorage")
        self.releaseModels()
    }

    /// Drops loaded speech models so the drive can be ejected. They load again on next use.
    func releaseModels() {
        AppServices.shared.existingASR?.resetTranscriptionProvider()
    }

    private func reloadModels() async {
        SpeechModelInstallationSnapshot.shared.refresh()
        PrivateAIIntegrationService.invalidateInstalledModelCache()
        // Only a store that had a model, with that model present now, rechecks; nothing triggers a download.
        if case .ready = MeetingDiarizationModelStore.shared.state { self.meetingModelNeedsRecheck = true }
        if self.meetingModelNeedsRecheck {
            let installed = await Task.detached(priority: .utility) {
                ModelStorageLocation.probe().isUsable
                    && FileManager.default.fileExists(atPath: MeetingNemotronModelLocator.defaultPackageURL().path)
            }.value
            if installed {
                self.meetingModelNeedsRecheck = false
                MeetingDiarizationModelStore.shared.prepareInBackground()
            }
        }
        guard let asr = AppServices.shared.existingASR else { return }
        await asr.checkIfModelsExistAsync()
        guard asr.modelsExistOnDisk else { return }
        do {
            try await asr.ensureAsrReady()
        } catch {
            DebugLogger.shared.error("ModelStorage: reload after storage change failed: \(error)", source: "ModelStorage")
        }
    }

    // MARK: - Changing the location

    static func standardFolders() -> [ModelStorageFolder] {
        var folders = [ModelStorageFolder(name: "Whisper and Qwen", kind: .whisper)]
        let coreMLHints = Set(SettingsStore.SpeechModel.availableModels.compactMap { $0.externalCoreMLSpec?.artifactFolderHint })
        folders += coreMLHints.sorted().map { ModelStorageFolder(name: "Cohere", kind: .coreML(folderName: $0)) }
        folders += [
            ModelStorageFolder(name: "Nemotron 3.5", kind: .coreML(folderName: "nemotron-3.5-asr-offline-6bit-CoreML")),
            ModelStorageFolder(name: "Nemotron 3.5 streaming", kind: .coreML(folderName: "nemotron-3.5-asr-streaming320-int8-CoreML")),
            ModelStorageFolder(name: "Parakeet and Fluid Speech", kind: .fluidAudio),
            ModelStorageFolder(name: "Speaker labels", kind: .meeting),
        ]
        return folders
    }

    /// Measures what a change would move. Runs the disk work off the main actor.
    func plan(for target: ModelStorageConfiguration) async throws -> ModelStorageMovePlan {
        let folders = Self.standardFolders()
        let from = ModelStorageLocation.configuration
        return try await Task.detached(priority: .userInitiated) {
            try ModelStorageMover.makePlan(folders: folders, from: from, to: target)
        }.value
    }

    /// Refuses to start while other model work is running, and never cancels that work itself.
    func blockingActivityMessage() -> String? {
        if let asr = AppServices.shared.existingASR,
           asr.hasActiveModelDownload || asr.hasActiveModelPreparation || asr.deletingModelID != nil
        {
            return "A model is downloading, loading or being deleted. Wait for it to finish, then try again."
        }
        if case .downloading = MeetingDiarizationModelStore.shared.state {
            return "The speaker label model is downloading. Wait for it to finish, then try again."
        }
        return nil
    }

    func start(_ plan: ModelStorageMovePlan, choice: MoveChoice) {
        guard self.moveTask == nil else { return }
        self.leftoverLinks = []
        // The confirmation dialog can stay open for a while, so check again now.
        if let blocked = self.blockingActivityMessage() {
            self.lastMoveMessage = blocked
            return
        }
        self.lastMoveMessage = nil
        ModelStorageLocation.setMoveInProgress(true)
        self.canCancelMove = true
        self.moveProgress = ModelStorageMoveProgress(
            phase: choice == .moveExisting ? .copying : .switching,
            completedBytes: 0,
            totalBytes: choice == .moveExisting ? plan.copyBytes : 0
        )
        let hooks = self.makeHooks()
        self.moveTask = Task { [weak self] in
            let message: String
            var links: [String] = []
            do {
                switch choice {
                case .moveExisting:
                    let summary = try await ModelStorageMover.run(plan, hooks: hooks) { progress in
                        Task { @MainActor in
                            guard let self, self.moveTask != nil else { return }
                            guard progress.phase.order >= (self.moveProgress?.phase.order ?? 0) else { return }
                            self.moveProgress = progress
                        }
                    }
                    message = Self.successMessage(for: summary)
                    links = summary.leftoverLinks
                case .useExisting:
                    try await ModelStorageMover.switchWithoutMoving(from: plan.from, to: plan.to, hooks: hooks)
                    message = "FluidVoice now uses the models in this folder. Nothing was moved or deleted."
                }
            } catch is CancellationError {
                message = "The move was canceled. Your models are still in their original location."
            } catch {
                message = error.localizedDescription
            }
            ModelStorageLocation.setMoveInProgress(false)
            guard let self else { return }
            self.canCancelMove = false
            self.moveTask = nil
            self.moveProgress = nil
            self.lastMoveMessage = message
            self.leftoverLinks = links
            AccessibilityNotification.Announcement(message).post()
            await self.refresh()
            await self.reloadModels()
        }
    }

    func cancelMove() {
        guard self.canCancelMove else { return }
        self.moveTask?.cancel()
    }

    func dismissMessages() {
        self.lastMoveMessage = nil
        self.interruptedMoveNotice = nil
    }

    /// Removes links that the user made to the old folders. Runs only when the user asks for it.
    func removeLeftoverLinks() {
        for path in self.leftoverLinks where ModelStorageLocation.isSymbolicLink(URL(fileURLWithPath: path)) {
            try? FileManager.default.removeItem(atPath: path)
        }
        self.leftoverLinks = []
    }

    private func makeHooks() -> ModelStorageMover.Hooks {
        ModelStorageMover.Hooks(
            beforeSwitch: { @MainActor in
                try await ModelStorageMonitor.waitUntilSpeechIsIdle()
                try Task.checkCancellation()
                ModelStorageMonitor.shared.canCancelMove = false
                ModelStorageMonitor.shared.releaseModels()
            },
            commit: { @MainActor from, to in
                ModelStorageMonitor.commit(from: from, to: to)
            },
            verifyAfterSwitch: { @MainActor in
                await ModelStorageMonitor.verifyInstalledModels()
            }
        )
    }

    private static var installedBeforeSwitch: Set<String> = []

    private static func waitUntilSpeechIsIdle() async throws {
        while self.isModelWorkRunning {
            ModelStorageMonitor.shared.moveProgress = ModelStorageMoveProgress(phase: .waitingForIdle, completedBytes: 0, totalBytes: 0)
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        self.installedBeforeSwitch = try await SpeechModelInstallationSnapshot.scan(SpeechModelInstallationSnapshot.captureProbes())
    }

    /// Covers dictation and every kind of model download or deletion that writes into model folders.
    private static var isModelWorkRunning: Bool {
        if case .downloading = MeetingDiarizationModelStore.shared.state { return true }
        guard let asr = AppServices.shared.existingASR else { return false }
        return asr.isRunning || asr.activeExclusiveActivity != nil || asr.hasActiveModelPreparation
            || asr.hasActiveModelDownload || asr.deletingModelID != nil
    }

    private static func commit(from: ModelStorageConfiguration, to: ModelStorageConfiguration) {
        ModelStorageLocation.apply(to)
        for model in SettingsStore.SpeechModel.availableModels {
            guard let spec = model.externalCoreMLSpec,
                  let stored = SettingsStore.shared.storedExternalCoreMLArtifactsPath(for: model),
                  ModelStorageLocation.isAppManagedCoreMLDirectory(URL(fileURLWithPath: stored, isDirectory: true), folderName: spec.artifactFolderHint, in: from)
            else { continue }
            SettingsStore.shared.setExternalCoreMLArtifactsDirectory(nil, for: model)
        }
        #if canImport(FluidAudio)
        // The compiled cache is named after a hash of the model path; renaming it avoids a slow recompile.
        let hints = Set(SettingsStore.SpeechModel.availableModels.compactMap { $0.externalCoreMLSpec?.artifactFolderHint })
        for hint in hints {
            let old = CohereTranscribeAsrModels.compiledArtifactsDirectory(for: ModelStorageLocation.coreMLModelDirectory(folderName: hint, in: from))
            let new = CohereTranscribeAsrModels.compiledArtifactsDirectory(for: ModelStorageLocation.coreMLModelDirectory(folderName: hint, in: to))
            let manager = FileManager.default
            if old != new, manager.fileExists(atPath: old.path), !manager.fileExists(atPath: new.path) {
                try? manager.moveItem(at: old, to: new)
            }
        }
        #endif
        ModelStorageMonitor.shared.configuration = to
        PrivateAIIntegrationService.invalidateInstalledModelCache()
    }

    private static func verifyInstalledModels() async -> Bool {
        let expected = self.installedBeforeSwitch.subtracting(self.builtInModelIDs)
        guard !expected.isEmpty else { return true }
        let probes = SpeechModelInstallationSnapshot.captureProbes()
        guard let installed = try? await SpeechModelInstallationSnapshot.scan(probes) else { return false }
        let missing = expected.subtracting(installed)
        if !missing.isEmpty {
            DebugLogger.shared.error("ModelStorage: models missing after switch: \(missing.sorted())", source: "ModelStorage")
        }
        return missing.isEmpty
    }

    private static var builtInModelIDs: Set<String> {
        Set(SettingsStore.SpeechModel.availableModels.filter(\.usesAppleLogo).map(\.id))
    }

    private static func successMessage(for summary: ModelStorageMoveSummary) -> String {
        guard summary.movedBytes > 0 || !summary.movedFolders.isEmpty else {
            return "There were no models to move. New downloads will go to this folder."
        }
        var message = "Moved \(ByteCountFormatter.string(fromByteCount: summary.movedBytes, countStyle: .file)) of models."
        if !summary.leftoverPaths.isEmpty {
            message += " Some original files could not be deleted: \(summary.leftoverPaths.joined(separator: ", "))."
        }
        if !summary.changedOriginals.isEmpty {
            message += " These original folders changed during the move and were kept: \(summary.changedOriginals.joined(separator: ", "))."
        }
        return message
    }
}
