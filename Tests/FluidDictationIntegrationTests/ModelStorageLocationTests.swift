import FluidAudio
@testable import FluidVoice_Debug
import Foundation
import XCTest

final class ModelStorageLocationTests: XCTestCase {
    private var temporaryRoot: URL!
    private let cohereFolder = "cohere-transcribe-03-2026-CoreML-6bit"

    override func setUpWithError() throws {
        self.temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStorageLocationTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: self.temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.temporaryRoot)
    }

    private func availableRootPath(_ config: ModelStorageConfiguration) -> String? {
        guard case let .available(root) = ModelStorageLocation.probe(config) else { return nil }
        return root.path
    }

    private func customConfiguration(_ root: URL) -> ModelStorageConfiguration {
        ModelStorageConfiguration(rootPath: root.path)
    }

    // MARK: - Default locations

    func testDefaultLocationsMatchTodaysPathsExactly() {
        let config = ModelStorageConfiguration.defaultLocations
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        XCTAssertEqual(ModelStorageLocation.whisperModelsDirectory(in: config).path, caches.appendingPathComponent("WhisperModels").path)
        XCTAssertEqual(
            ModelStorageLocation.coreMLModelDirectory(folderName: self.cohereFolder, in: config).path,
            caches.appendingPathComponent(self.cohereFolder).path
        )
        XCTAssertEqual(
            ModelStorageLocation.coreMLModelDirectory(folderName: "nemotron-3.5-asr-offline-6bit-CoreML", in: config).path,
            caches.appendingPathComponent("nemotron-3.5-asr-offline-6bit-CoreML").path
        )
        XCTAssertEqual(ModelStorageLocation.fluidAudioModelsDirectory(in: config).path, support.appendingPathComponent("FluidAudio/Models").path)
        XCTAssertEqual(ModelStorageLocation.fluidAudioBaseDirectory(in: config).path, support.appendingPathComponent("FluidAudio").path)
        XCTAssertEqual(ModelStorageLocation.meetingModelsDirectory(in: config).path, support.appendingPathComponent("FluidVoice/MeetingModels").path)
        XCTAssertEqual(ModelStorageLocation.probe(config), .defaultLocations)
    }

    func testDefaultLocationsMatchTheSpeechPackageDefaultsTheAppUsedBefore() {
        let models = ModelStorageLocation.fluidAudioModelsDirectory(in: .defaultLocations)
        XCTAssertEqual(models.appendingPathComponent(ParakeetSpeechModelCatalog.v3.folderName).path, AsrModels.defaultCacheDirectory(for: .v3).path)
        XCTAssertEqual(models.appendingPathComponent(ParakeetSpeechModelCatalog.v2.folderName).path, AsrModels.defaultCacheDirectory(for: .v2).path)
        XCTAssertEqual(models.path, AsrModels.defaultCacheDirectory().deletingLastPathComponent().path)
        XCTAssertEqual(models.appendingPathComponent(CtcModelVariant.ctc110m.repo.folderName).path, CtcModels.defaultCacheDirectory(for: .ctc110m).path)
        XCTAssertEqual(models.path, DiarizerModels.defaultModelsDirectory().deletingLastPathComponent().path)
        XCTAssertEqual(models.path, OfflineDiarizerModels.defaultModelsDirectory().path)
    }

    func testDefaultSpeechBaseIsTheCachesFolderItself() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(ModelStorageLocation.speechBaseDirectory(in: .defaultLocations), caches)
    }

    // MARK: - Custom root

    func testCustomRootUsesDocumentedLayout() {
        let config = self.customConfiguration(self.temporaryRoot)
        let root = self.temporaryRoot.path
        XCTAssertEqual(ModelStorageLocation.whisperModelsDirectory(in: config).path, "\(root)/Speech/WhisperModels")
        XCTAssertEqual(ModelStorageLocation.coreMLModelDirectory(folderName: self.cohereFolder, in: config).path, "\(root)/Speech/\(self.cohereFolder)")
        XCTAssertEqual(ModelStorageLocation.fluidAudioModelsDirectory(in: config).path, "\(root)/Speech/FluidAudio/Models")
        XCTAssertEqual(ModelStorageLocation.fluidAudioBaseDirectory(in: config).path, "\(root)/Speech/FluidAudio")
        XCTAssertEqual(ModelStorageLocation.meetingModelsDirectory(in: config).path, "\(root)/Meeting")
    }

    func testSymlinkedRootResolvesToRealFolder() throws {
        let real = self.temporaryRoot.appendingPathComponent("real", isDirectory: true)
        let link = self.temporaryRoot.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let config = self.customConfiguration(link)
        XCTAssertEqual(ModelStorageLocation.whisperModelsDirectory(in: config).path, "\(real.path)/Speech/WhisperModels")
        XCTAssertEqual(self.availableRootPath(config), real.path)
    }

    func testLinkInsideCustomRootStaysVisibleAndSurvivesDeletion() throws {
        let elsewhere = self.temporaryRoot.appendingPathComponent("elsewhere", isDirectory: true)
        let root = self.temporaryRoot.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data([1]).write(to: elsewhere.appendingPathComponent("model.gguf"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Speech"), withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Speech/WhisperModels")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)

        let directory = ModelStorageLocation.whisperModelsDirectory(in: self.customConfiguration(root))
        XCTAssertEqual(directory.path, link.path)
        try ModelStorageLocation.removeDirectoryPreservingLinks(at: directory)
        XCTAssertTrue(ModelStorageLocation.isSymbolicLink(link))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
        try ModelStorageLocation.ensureDirectory(at: directory)
    }

    // MARK: - Precedence

    func testExplicitOverrideWinsOverCustomRoot() {
        let override = self.temporaryRoot.appendingPathComponent("my-cohere").path
        let resolution = ModelStorageLocation.externalCoreMLDirectory(
            folderName: self.cohereFolder,
            storedOverridePath: override,
            in: self.customConfiguration(self.temporaryRoot)
        )
        XCTAssertEqual(resolution.source, .explicitOverride)
        XCTAssertEqual(resolution.directory.path, override)
        XCTAssertFalse(resolution.isAppManaged)
    }

    func testCustomRootWinsOverDefaultAndStoredManagedPathsAreNotOverrides() {
        let config = self.customConfiguration(self.temporaryRoot)
        let legacy = ModelStorageLocation.defaultCachesDirectory.appendingPathComponent(self.cohereFolder).path
        let managed = ModelStorageLocation.coreMLModelDirectory(folderName: self.cohereFolder, in: config).path
        for stored in [nil, legacy, managed] {
            let resolution = ModelStorageLocation.externalCoreMLDirectory(folderName: self.cohereFolder, storedOverridePath: stored, in: config)
            XCTAssertEqual(resolution.source, .customRoot, "stored path \(stored ?? "nil")")
            XCTAssertEqual(resolution.directory.path, managed)
            XCTAssertTrue(resolution.isAppManaged)
        }
    }

    func testDefaultLocationIsUsedWithoutCustomRoot() {
        let resolution = ModelStorageLocation.externalCoreMLDirectory(
            folderName: self.cohereFolder,
            storedOverridePath: nil,
            in: .defaultLocations
        )
        XCTAssertEqual(resolution.source, .defaultLocation)
        XCTAssertEqual(resolution.directory.path, ModelStorageLocation.defaultCachesDirectory.appendingPathComponent(self.cohereFolder).path)
    }

    func testManagedFolderUnderCustomRootCountsAsAppManaged() {
        let config = self.customConfiguration(self.temporaryRoot)
        let managed = ModelStorageLocation.coreMLModelDirectory(folderName: self.cohereFolder, in: config)
        XCTAssertTrue(ModelStorageLocation.isAppManagedCoreMLDirectory(managed, folderName: self.cohereFolder, in: config))
        XCTAssertFalse(ModelStorageLocation.isAppManagedCoreMLDirectory(
            self.temporaryRoot.appendingPathComponent("other"),
            folderName: self.cohereFolder,
            in: config
        ))
    }

    // MARK: - Availability

    func testMissingVolumeReportsDriveNotConnectedAndNeverDefaultPaths() {
        let volume = "FluidVoiceMissingDrive-\(UUID().uuidString)"
        let config = ModelStorageConfiguration(rootPath: "/Volumes/\(volume)/Models", volumeName: volume)
        XCTAssertEqual(ModelStorageLocation.probe(config), .driveNotConnected(volumeName: volume, path: "/Volumes/\(volume)/Models"))
        XCTAssertEqual(ModelStorageLocation.whisperModelsDirectory(in: config).path, "/Volumes/\(volume)/Models/Speech/WhisperModels")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/Volumes/\(volume)"))
    }

    func testMissingFolderOnMountedVolumeReportsFolderMissing() {
        let missing = self.temporaryRoot.appendingPathComponent("gone").path
        XCTAssertEqual(ModelStorageLocation.probe(ModelStorageConfiguration(rootPath: missing)), .folderMissing(path: missing))
    }

    func testFolderOnWrongVolumeReportsDriveNotConnected() {
        let config = ModelStorageConfiguration(rootPath: self.temporaryRoot.path, volumeUUID: UUID().uuidString, volumeName: "PocketSSD")
        XCTAssertEqual(ModelStorageLocation.probe(config), .driveNotConnected(volumeName: "PocketSSD", path: self.temporaryRoot.path))
    }

    func testCustomConfigurationRecordsVolumeIdentity() {
        let config = ModelStorageConfiguration.custom(root: self.temporaryRoot)
        XCTAssertEqual(config.rootPath, self.temporaryRoot.path)
        XCTAssertNotNil(config.volumeUUID)
        XCTAssertNotNil(config.bookmark)
        XCTAssertEqual(self.availableRootPath(config), self.temporaryRoot.path)
    }

    func testMovedFolderIsFoundAgainThroughBookmark() throws {
        let original = self.temporaryRoot.appendingPathComponent("before", isDirectory: true)
        let renamed = self.temporaryRoot.appendingPathComponent("after", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let config = ModelStorageConfiguration.custom(root: original)
        try FileManager.default.moveItem(at: original, to: renamed)
        XCTAssertEqual(self.availableRootPath(config), renamed.path)
    }

    func testLeftoverFolderAtMountPointIsNotAMountedVolume() {
        XCTAssertFalse(ModelStorageLocation.isMountedVolume(atPath: self.temporaryRoot.path))
        XCTAssertTrue(ModelStorageLocation.isMountedVolume(atPath: "/"))
    }

    func testFoldersInTheTrashAreUnsuitable() {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/Models")
        XCTAssertNotNil(ModelStorageLocation.unsuitableFolderReason(trash))
        XCTAssertNotNil(ModelStorageLocation.unsuitableFolderReason(URL(fileURLWithPath: "/Volumes/Drive/.Trashes/501/Models")))
        XCTAssertNil(ModelStorageLocation.unsuitableFolderReason(self.temporaryRoot))
    }

    func testVolumeMountPointOnlyForExternalVolumes() {
        XCTAssertEqual(ModelStorageLocation.volumeMountPoint(forPath: "/Volumes/PocketSSD/AIModels"), "/Volumes/PocketSSD")
        XCTAssertNil(ModelStorageLocation.volumeMountPoint(forPath: "/Users/someone/Models"))
    }

    // MARK: - Persistence

    func testApplyWritesKeysOnlyForCustomRootAndKeepsThemOutOfDefaults() throws {
        let suiteName = "ModelStorageLocationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let saved = ModelStorageLocation.configuration
        defer { ModelStorageLocation.apply(saved, defaults: defaults) }

        ModelStorageLocation.apply(.custom(root: self.temporaryRoot), defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: ModelStorageLocation.Keys.rootPath), self.temporaryRoot.path)
        XCTAssertEqual(ModelStorageLocation.load(from: defaults).rootPath, self.temporaryRoot.path)

        ModelStorageLocation.apply(.defaultLocations, defaults: defaults)
        for key in ModelStorageLocation.Keys.all {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        XCTAssertEqual(ModelStorageLocation.load(from: defaults), .defaultLocations)
    }

    func testStorageKeysAreNotPartOfSettingsBackup() throws {
        let source = try String(contentsOf: Self.sourceURL("Sources/Fluid/Persistence/BackupService.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("ModelStorage"))
    }

    // MARK: - Symlink-safe helpers

    func testRemovingThroughSymlinkEmptiesTargetAndKeepsLink() throws {
        let target = self.temporaryRoot.appendingPathComponent("target", isDirectory: true)
        let link = self.temporaryRoot.appendingPathComponent("WhisperModels", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data([1]).write(to: target.appendingPathComponent("model.gguf"))
        try Data([2]).write(to: target.appendingPathComponent(".stamp"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try ModelStorageLocation.removeDirectoryPreservingLinks(at: link)

        XCTAssertTrue(ModelStorageLocation.isSymbolicLink(link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    func testRemovingRealFolderDeletesIt() throws {
        let folder = self.temporaryRoot.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ModelStorageLocation.removeDirectoryPreservingLinks(at: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testEnsureDirectoryKeepsValidLinkAndRefusesBrokenLink() throws {
        let target = self.temporaryRoot.appendingPathComponent("target", isDirectory: true)
        let link = self.temporaryRoot.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try ModelStorageLocation.ensureDirectory(at: link)
        XCTAssertTrue(ModelStorageLocation.isSymbolicLink(link))

        try FileManager.default.removeItem(at: target)
        XCTAssertThrowsError(try ModelStorageLocation.ensureDirectory(at: link)) { error in
            XCTAssertEqual(error as? ModelStorageError, .symlinkInTheWay(path: link.path))
        }
        XCTAssertTrue(ModelStorageLocation.isSymbolicLink(link))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    static func sourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }
}

@MainActor
final class ModelStorageSettingsSearchTests: XCTestCase {
    func testModelStorageIsFoundInDataAndDiagnostics() {
        let availability = SettingsSearchAvailability(
            microphoneAuthorized: true,
            accessibilityEnabled: true,
            savesTranscriptionHistory: true,
            savesAudioWithTranscriptionHistory: true,
            overlayAtBottom: true,
            privateAIAvailable: false
        )
        for query in ["model storage", "external drive", "models folder"] {
            let result = SettingsSearchIndex.results(for: query, availability: availability).first { $0.target == .modelStorage }
            XCTAssertEqual(result?.section, .dataAndDiagnostics, query)
        }
    }
}
