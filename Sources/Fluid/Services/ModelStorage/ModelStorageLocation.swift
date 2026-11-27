import Foundation
import os

/// The user's choice of where downloaded models live. A nil `rootPath` means today's default locations.
nonisolated struct ModelStorageConfiguration: Equatable, Codable {
    var rootPath: String?
    var volumeUUID: String?
    var volumeName: String?
    var bookmark: Data?

    static let defaultLocations = ModelStorageConfiguration()

    var usesCustomRoot: Bool {
        self.rootPath?.isEmpty == false
    }

    /// The chosen folder with symlinks resolved, so model code always receives a real path.
    var resolvedRootURL: URL? {
        guard let rootPath, !rootPath.isEmpty else { return nil }
        let path = URL(fileURLWithPath: rootPath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Builds a configuration for a folder the user picked, including the identity of its volume.
    static func custom(root: URL) -> ModelStorageConfiguration {
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        let values = try? resolved.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey])
        let bookmark = try? resolved.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return ModelStorageConfiguration(
            rootPath: resolved.path,
            volumeUUID: values?.volumeUUIDString,
            volumeName: values?.volumeName,
            bookmark: bookmark
        )
    }
}

nonisolated enum ModelStorageAvailability: Equatable {
    case defaultLocations
    case available(root: URL)
    case driveNotConnected(volumeName: String?, path: String)
    case folderMissing(path: String)
    case accessDenied(path: String)

    var isUsable: Bool {
        switch self {
        case .defaultLocations, .available: return true
        case .driveNotConnected, .folderMissing, .accessDenied: return false
        }
    }

    var error: ModelStorageError? {
        switch self {
        case .defaultLocations, .available: return nil
        case let .driveNotConnected(volumeName, _): return .driveNotConnected(volumeName: volumeName)
        case let .folderMissing(path): return .folderMissing(path: path)
        case let .accessDenied(path): return .accessDenied(path: path)
        }
    }
}

nonisolated enum ModelStorageError: LocalizedError, Equatable {
    case driveNotConnected(volumeName: String?)
    case folderMissing(path: String)
    case accessDenied(path: String)
    case moveInProgress
    case symlinkInTheWay(path: String)

    var errorDescription: String? {
        switch self {
        case let .driveNotConnected(volumeName):
            if let volumeName, !volumeName.isEmpty {
                return "Model drive \"\(volumeName)\" is not connected. Connect it, or choose another model storage location in Settings → Data & Diagnostics."
            }
            return "Model drive is not connected. Connect it, or choose another model storage location in Settings → Data & Diagnostics."
        case let .folderMissing(path):
            return "The model storage folder \(path) no longer exists. Choose another location in Settings → Data & Diagnostics."
        case let .accessDenied(path):
            return "FluidVoice cannot read or write the model storage folder \(path). Check the folder's permissions and Files & Folders access in System Settings."
        case .moveInProgress:
            return "Models are being moved to a new storage location. Try again when the move finishes."
        case let .symlinkInTheWay(path):
            return "\(path) is a broken link. Remove it or point it at an existing folder, then try again."
        }
    }
}

/// How a Cohere-style model folder was chosen.
nonisolated struct ExternalCoreMLResolution: Equatable {
    enum Source: Equatable {
        case explicitOverride, customRoot, defaultLocation
    }

    let directory: URL
    let source: Source

    var isAppManaged: Bool {
        self.source != .explicitOverride
    }
}

/**
 Resolves every model folder. With no custom root it returns exactly today's paths, unresolved,
 so default users keep their compiled-cache hashes. With a custom root it never falls back to a default path.
 */
nonisolated enum ModelStorageLocation {
    enum Keys {
        static let rootPath = "ModelStorageCustomRootPath"
        static let volumeUUID = "ModelStorageCustomRootVolumeUUID"
        static let volumeName = "ModelStorageCustomRootVolumeName"
        static let bookmark = "ModelStorageCustomRootBookmark"
        static let all = [rootPath, volumeUUID, volumeName, bookmark]
    }

    static let speechFolderName = "Speech"
    static let meetingFolderName = "Meeting"
    static let markerFileName = ".fluidvoice-models.json"
    static let whisperFolderName = "WhisperModels"

    private struct State {
        var configuration: ModelStorageConfiguration
        var moveInProgress = false
    }

    private static let state = OSAllocatedUnfairLock(initialState: State(configuration: Self.load(from: .standard)))

    // MARK: - Configuration

    static var configuration: ModelStorageConfiguration {
        self.state.withLock { $0.configuration }
    }

    static var usesCustomRoot: Bool {
        self.configuration.usesCustomRoot
    }

    static var isMoveInProgress: Bool {
        self.state.withLock { $0.moveInProgress }
    }

    static func setMoveInProgress(_ value: Bool) {
        self.state.withLock { $0.moveInProgress = value }
    }

    static func load(from defaults: UserDefaults) -> ModelStorageConfiguration {
        guard let path = defaults.string(forKey: Keys.rootPath), !path.isEmpty else { return .defaultLocations }
        return ModelStorageConfiguration(
            rootPath: path,
            volumeUUID: defaults.string(forKey: Keys.volumeUUID),
            volumeName: defaults.string(forKey: Keys.volumeName),
            bookmark: defaults.data(forKey: Keys.bookmark)
        )
    }

    /// Persists the choice and makes it current. Default users never get these keys written.
    static func apply(_ configuration: ModelStorageConfiguration, defaults: UserDefaults = .standard) {
        if configuration.usesCustomRoot {
            defaults.set(configuration.rootPath, forKey: Keys.rootPath)
            self.setOrRemove(configuration.volumeUUID, forKey: Keys.volumeUUID, in: defaults)
            self.setOrRemove(configuration.volumeName, forKey: Keys.volumeName, in: defaults)
            self.setOrRemove(configuration.bookmark, forKey: Keys.bookmark, in: defaults)
        } else {
            Keys.all.forEach { defaults.removeObject(forKey: $0) }
        }
        self.state.withLock { $0.configuration = configuration }
    }

    static func reload(from defaults: UserDefaults = .standard) {
        let configuration = self.load(from: defaults)
        self.state.withLock { $0.configuration = configuration }
    }

    private static func setOrRemove(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Default locations (today's paths)

    static var defaultCachesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
    }

    static var defaultApplicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    // MARK: - Family folders

    /**
     The folder that holds Whisper, Cohere and Nemotron folders: Caches by default, `<root>/Speech` otherwise.
     Only the root is resolved, so a user's link inside it stays visible to the link-preserving helpers.
     */
    static func speechBaseDirectory(in configuration: ModelStorageConfiguration = Self.configuration) -> URL {
        guard let root = configuration.resolvedRootURL else { return self.defaultCachesDirectory }
        return root.appendingPathComponent(self.speechFolderName, isDirectory: true)
    }

    static func whisperModelsDirectory(in configuration: ModelStorageConfiguration = Self.configuration) -> URL {
        self.speechBaseDirectory(in: configuration).appendingPathComponent(self.whisperFolderName, isDirectory: true)
    }

    /// Cohere and Nemotron folders, named after their repository folder.
    static func coreMLModelDirectory(
        folderName: String,
        in configuration: ModelStorageConfiguration = Self.configuration
    ) -> URL {
        self.speechBaseDirectory(in: configuration).appendingPathComponent(folderName, isDirectory: true)
    }

    /// FluidAudio's "Models" folder, which holds Parakeet, Fluid Speech, Flash, CTC, VAD and diarizer models.
    static func fluidAudioModelsDirectory(in configuration: ModelStorageConfiguration = Self.configuration) -> URL {
        guard let root = configuration.resolvedRootURL else {
            return self.defaultApplicationSupportDirectory
                .appendingPathComponent("FluidAudio", isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
        }
        return root.appendingPathComponent(self.speechFolderName, isDirectory: true)
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// The parent of the FluidAudio models folder, for APIs that append "Models" themselves.
    static func fluidAudioBaseDirectory(in configuration: ModelStorageConfiguration = Self.configuration) -> URL {
        self.fluidAudioModelsDirectory(in: configuration).deletingLastPathComponent()
    }

    static func meetingModelsDirectory(in configuration: ModelStorageConfiguration = Self.configuration) -> URL {
        guard let root = configuration.resolvedRootURL else {
            return self.defaultApplicationSupportDirectory
                .appendingPathComponent("FluidVoice", isDirectory: true)
                .appendingPathComponent("MeetingModels", isDirectory: true)
        }
        return root.appendingPathComponent(self.meetingFolderName, isDirectory: true)
    }

    /**
     Applies the precedence rule: an explicit per-model path wins, then the custom root, then the default.
     A stored path that equals an app-managed folder is not an override, because the app writes it after downloads.
     */
    static func externalCoreMLDirectory(
        folderName: String,
        storedOverridePath: String?,
        in configuration: ModelStorageConfiguration = Self.configuration
    ) -> ExternalCoreMLResolution {
        let managed = self.coreMLModelDirectory(folderName: folderName, in: configuration)
        if let storedOverridePath, !storedOverridePath.isEmpty {
            let stored = URL(fileURLWithPath: storedOverridePath, isDirectory: true)
            if !self.isAppManagedCoreMLDirectory(stored, folderName: folderName, in: configuration) {
                return ExternalCoreMLResolution(directory: stored, source: .explicitOverride)
            }
        }
        return ExternalCoreMLResolution(
            directory: managed,
            source: configuration.usesCustomRoot ? .customRoot : .defaultLocation
        )
    }

    static func isAppManagedCoreMLDirectory(
        _ directory: URL,
        folderName: String,
        in configuration: ModelStorageConfiguration = Self.configuration
    ) -> Bool {
        let candidates = [
            self.defaultCachesDirectory.appendingPathComponent(folderName, isDirectory: true),
            self.coreMLModelDirectory(folderName: folderName, in: configuration),
        ]
        let path = directory.standardizedFileURL.path
        let resolvedPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        return candidates.contains { candidate in
            let candidatePath = candidate.standardizedFileURL.path
            return candidatePath == path || candidatePath == resolvedPath
        }
    }

    /// Always a directory URL, so equal folders compare equal regardless of a trailing slash.
    private static func resolved(_ url: URL) -> URL {
        URL(fileURLWithPath: url.resolvingSymlinksInPath().standardizedFileURL.path, isDirectory: true)
    }

    // MARK: - Availability

    /// Touches the disk, so a slow or sleeping volume can delay the caller.
    static func probe(
        _ configuration: ModelStorageConfiguration = Self.configuration,
        fileManager: FileManager = .default
    ) -> ModelStorageAvailability {
        guard let rootPath = configuration.rootPath, !rootPath.isEmpty else { return .defaultLocations }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let resolvedRoot = self.resolved(root)
            if let expected = configuration.volumeUUID,
               let actual = try? resolvedRoot.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
               expected != actual
            {
                // A same-named folder on another volume, for example a leftover mount point.
                return .driveNotConnected(volumeName: configuration.volumeName, path: rootPath)
            }
            guard fileManager.isReadableFile(atPath: resolvedRoot.path),
                  fileManager.isWritableFile(atPath: resolvedRoot.path)
            else {
                return .accessDenied(path: rootPath)
            }
            return .available(root: resolvedRoot)
        }

        if let relocated = self.relocatedRoot(for: configuration, fileManager: fileManager) {
            return .available(root: relocated)
        }
        if let mountPoint = self.volumeMountPoint(forPath: rootPath),
           !self.isMountedVolume(atPath: mountPoint, fileManager: fileManager)
        {
            return .driveNotConnected(volumeName: configuration.volumeName ?? URL(fileURLWithPath: mountPoint).lastPathComponent, path: rootPath)
        }
        return .folderMissing(path: rootPath)
    }

    /// Finds the folder again after a volume rename, without mounting anything or showing UI.
    private static func relocatedRoot(for configuration: ModelStorageConfiguration, fileManager: FileManager) -> URL? {
        guard let bookmark = configuration.bookmark else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let resolved = self.resolved(url)
        // A folder dragged to the Trash still resolves; following it would send downloads there.
        guard self.unsuitableFolderReason(resolved) == nil else { return nil }
        if let expected = configuration.volumeUUID,
           let actual = try? resolved.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
           expected != actual
        {
            return nil
        }
        return resolved
    }

    /// A leftover folder at the mount point is not the drive itself.
    static func isMountedVolume(atPath mountPoint: String, fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: mountPoint) else { return false }
        let url = URL(fileURLWithPath: mountPoint, isDirectory: true)
        let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume
        return volume?.standardizedFileURL.path == url.standardizedFileURL.path
    }

    /// Explains why a folder must not hold models, or returns nil when it is fine.
    static func unsuitableFolderReason(_ url: URL) -> String? {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
        if path == trash || path.hasPrefix(trash + "/") || path.contains("/.Trashes/") {
            return "Choose a folder outside the Trash."
        }
        let bundle = Bundle.main.bundleURL.standardizedFileURL.path
        if path == bundle || path.hasPrefix(bundle + "/") {
            return "Choose a folder outside the FluidVoice app."
        }
        if path == self.defaultCachesDirectory.standardizedFileURL.path {
            return "Choose a dedicated folder. Files directly in Caches can be removed by cleanup tools."
        }
        return nil
    }

    /// Returns `/Volumes/<name>` for paths on an external volume, and nil for the startup disk.
    static func volumeMountPoint(forPath path: String) -> String? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return nil }
        return "/Volumes/" + components[2]
    }

    /// Throws when the custom root cannot be used, so no caller can fall back to the internal disk.
    static func requireAvailable(fileManager: FileManager = .default) throws {
        if let error = self.probe(self.configuration, fileManager: fileManager).error {
            throw error
        }
    }

    /// Use before downloading, deleting or replacing model files.
    static func requireAvailableForChanges(fileManager: FileManager = .default) throws {
        if self.isMoveInProgress {
            throw ModelStorageError.moveInProgress
        }
        try self.requireAvailable(fileManager: fileManager)
    }

    // MARK: - Symlink-safe file operations

    /**
     Creates a model folder. An existing symlink is followed and kept, a broken one throws,
     and nothing is created under a custom root that is not reachable.
     */
    static func ensureDirectory(at directory: URL, fileManager: FileManager = .default) throws {
        if self.isUnderCustomRoot(directory) {
            try self.requireAvailable(fileManager: fileManager)
        }
        if self.isSymbolicLink(directory, fileManager: fileManager) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ModelStorageError.symlinkInTheWay(path: directory.path)
            }
            return
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Deletes a model folder. Through a symlink it empties the target instead, so the link stays usable.
    static func removeDirectoryPreservingLinks(at directory: URL, fileManager: FileManager = .default) throws {
        guard self.isSymbolicLink(directory, fileManager: fileManager) else {
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
            return
        }
        let target = self.resolved(directory)
        guard target.path != directory.standardizedFileURL.path, fileManager.fileExists(atPath: target.path) else { return }
        for item in try fileManager.contentsOfDirectory(at: target, includingPropertiesForKeys: nil) {
            try fileManager.removeItem(at: item)
        }
    }

    static func isSymbolicLink(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let attributes = try? fileManager.attributesOfItem(atPath: url.standardizedFileURL.path)
        return attributes?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private static func isUnderCustomRoot(_ url: URL) -> Bool {
        guard let root = self.configuration.resolvedRootURL else { return false }
        let path = url.standardizedFileURL.path
        return path == root.path || path.hasPrefix(root.path + "/")
    }

    // MARK: - Display

    static func availableCapacity(at directory: URL) -> Int64? {
        if let capacity = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, capacity >= 0
        {
            return capacity
        }
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    static func volumeName(at directory: URL) -> String? {
        try? directory.resourceValues(forKeys: [.volumeNameKey]).volumeName
    }
}
