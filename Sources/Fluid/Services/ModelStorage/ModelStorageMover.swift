import CryptoKit
import Foundation

/// One model folder that moves as a unit between storage locations.
nonisolated struct ModelStorageFolder: Equatable {
    enum Kind: Equatable {
        case whisper
        case coreML(folderName: String)
        case fluidAudio
        /// One subfolder of the FluidAudio models folder, so other contents there move separately.
        case fluidAudioModel(name: String)
        case meeting
    }

    let name: String
    let kind: Kind

    func url(in configuration: ModelStorageConfiguration) -> URL {
        switch self.kind {
        case .whisper: return ModelStorageLocation.whisperModelsDirectory(in: configuration)
        case let .coreML(folderName): return ModelStorageLocation.coreMLModelDirectory(folderName: folderName, in: configuration)
        case .fluidAudio: return ModelStorageLocation.fluidAudioModelsDirectory(in: configuration)
        case let .fluidAudioModel(name):
            return ModelStorageLocation.fluidAudioModelsDirectory(in: configuration).appendingPathComponent(name, isDirectory: true)
        case .meeting: return ModelStorageLocation.meetingModelsDirectory(in: configuration)
        }
    }

    /// The path as laid out, before symlinks inside a custom root are resolved, so a user's link can be reported.
    func configuredURL(in configuration: ModelStorageConfiguration) -> URL {
        guard let root = configuration.resolvedRootURL else { return self.url(in: configuration) }
        let relativePath = switch self.kind {
        case .whisper: "\(ModelStorageLocation.speechFolderName)/\(ModelStorageLocation.whisperFolderName)"
        case let .coreML(folderName): "\(ModelStorageLocation.speechFolderName)/\(folderName)"
        case .fluidAudio: "\(ModelStorageLocation.speechFolderName)/FluidAudio/Models"
        case let .fluidAudioModel(name): "\(ModelStorageLocation.speechFolderName)/FluidAudio/Models/\(name)"
        case .meeting: ModelStorageLocation.meetingFolderName
        }
        return root.appendingPathComponent(relativePath, isDirectory: true)
    }
}

nonisolated struct ModelStorageMoveItem: Equatable {
    let folder: ModelStorageFolder
    /// The configured path, which may be a user's symlink.
    let source: URL
    /// The real folder that holds the files.
    let resolvedSource: URL
    let destination: URL
    let byteCount: Int64
    let sameVolume: Bool

    var sourceIsSymlink: Bool {
        self.source.standardizedFileURL.path != self.resolvedSource.path
    }
}

nonisolated struct ModelStorageMovePlan: Equatable {
    let from: ModelStorageConfiguration
    let to: ModelStorageConfiguration
    let items: [ModelStorageMoveItem]
    /// Folders already present at the destination. They are used as they are, and their originals stay.
    let alreadyAtDestination: [ModelStorageFolder]
    let requiredBytes: Int64
    let availableBytes: Int64?

    var totalBytes: Int64 {
        self.items.reduce(0) { $0 + $1.byteCount }
    }

    var copyBytes: Int64 {
        self.items.filter { !$0.sameVolume }.reduce(0) { $0 + $1.byteCount }
    }

    var hasEnoughSpace: Bool {
        guard self.requiredBytes > 0 else { return true }
        guard let availableBytes else { return false }
        return availableBytes >= self.requiredBytes
    }

    var destinationHasModels: Bool {
        !self.alreadyAtDestination.isEmpty
    }
}

nonisolated struct ModelStorageMoveProgress: Equatable {
    enum Phase: Equatable {
        case copying, verifying, waitingForIdle, switching, cleaningUp

        /// Phases only move forward, so a late progress report can be recognized and dropped.
        var order: Int {
            switch self {
            case .copying: 0
            case .verifying: 1
            case .waitingForIdle: 2
            case .switching: 3
            case .cleaningUp: 4
            }
        }
    }

    var phase: Phase
    var completedBytes: Int64
    var totalBytes: Int64

    var fraction: Double {
        guard self.totalBytes > 0 else { return 0 }
        return min(1, Double(self.completedBytes) / Double(self.totalBytes))
    }
}

nonisolated struct ModelStorageMoveSummary: Equatable {
    var movedBytes: Int64 = 0
    var movedFolders: [String] = []
    /// Originals that could not be deleted after a verified move.
    var leftoverPaths: [String] = []
    /// User symlinks that now point at a folder the move emptied or removed.
    var leftoverLinks: [String] = []
    /// Originals kept because files were added or removed after they were copied.
    var changedOriginals: [String] = []
}

nonisolated enum ModelStorageMoveError: LocalizedError, Equatable {
    case insufficientSpace(required: Int64, available: Int64?)
    case nestedFolders(source: String, destination: String)
    case verificationFailed(path: String)
    case modelsMissingAfterSwitch
    case switchFailed(String)
    case rollbackIncomplete(paths: [String])

    var errorDescription: String? {
        switch self {
        case let .insufficientSpace(required, available):
            let needed = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let free = available.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "an unknown amount"
            return "The new location needs \(needed) of free space, but only \(free) is available. Nothing was moved."
        case let .nestedFolders(source, destination):
            return "\(destination) is inside \(source), or the other way around. Choose a folder outside your current model folders."
        case let .verificationFailed(path):
            return "A copied file did not match its original (\(path)). Nothing was changed, and your models are still in their original location."
        case .modelsMissingAfterSwitch:
            return "Some models were not found after the move, so FluidVoice switched back. Your models are still in their original location."
        case let .switchFailed(reason):
            return "The move could not be completed (\(reason)). FluidVoice switched back, and your models are still in their original location."
        case let .rollbackIncomplete(paths):
            return "The move failed and some folders could not be moved back: \(paths.joined(separator: ", ")). Reconnect the drive if it was removed, then move these folders back by hand."
        }
    }
}

/// Copies, verifies and switches model folders. Originals are deleted only after the new location is confirmed.
nonisolated enum ModelStorageMover {
    struct Hooks {
        /// Waits until no model is in use and unloads loaded models.
        var beforeSwitch: @Sendable () async throws -> Void = {}
        /// Makes a configuration current, including dependent state such as compiled caches.
        var commit: @Sendable (_ from: ModelStorageConfiguration, _ to: ModelStorageConfiguration) async -> Void = { _, to in
            ModelStorageLocation.apply(to)
        }

        /// Confirms that every model that was installed before is still found.
        var verifyAfterSwitch: @Sendable () async -> Bool = { true }
    }

    static let stagingPrefix = ".fluidvoice-staging-"
    static let headroomBytes: Int64 = 512 * 1024 * 1024
    private static let chunkSize = 4 * 1024 * 1024

    // MARK: - Planning

    static func makePlan(
        folders: [ModelStorageFolder],
        from: ModelStorageConfiguration,
        to: ModelStorageConfiguration,
        fileManager: FileManager = .default
    ) throws -> ModelStorageMovePlan {
        var items: [ModelStorageMoveItem] = []
        var alreadyThere: [ModelStorageFolder] = []
        for folder in self.expand(folders, from: from, to: to, fileManager: fileManager) {
            let source = folder.configuredURL(in: from)
            let destination = folder.url(in: to)
            let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
            let resolvedDestination = destination.resolvingSymlinksInPath().standardizedFileURL

            if ModelStorageLocation.isSymbolicLink(destination, fileManager: fileManager),
               !fileManager.fileExists(atPath: destination.path)
            {
                throw ModelStorageError.symlinkInTheWay(path: destination.path)
            }
            if self.directoryHasContent(resolvedDestination, fileManager: fileManager) {
                if resolvedDestination.path != resolvedSource.path {
                    alreadyThere.append(folder)
                }
                continue
            }
            guard self.directoryHasContent(resolvedSource, fileManager: fileManager) else { continue }
            if self.isSameOrInside(resolvedDestination, resolvedSource) || self.isSameOrInside(resolvedSource, resolvedDestination) {
                throw ModelStorageMoveError.nestedFolders(source: resolvedSource.path, destination: resolvedDestination.path)
            }
            let sameVolume = self.volumeIdentifier(resolvedSource) != nil
                && self.volumeIdentifier(resolvedSource) == self.volumeIdentifier(self.nearestExistingAncestor(of: resolvedDestination, fileManager: fileManager))
            try items.append(ModelStorageMoveItem(
                folder: folder,
                source: source,
                resolvedSource: resolvedSource,
                destination: resolvedDestination,
                byteCount: self.byteCount(of: resolvedSource, fileManager: fileManager),
                sameVolume: sameVolume
            ))
        }

        let copyBytes = items.filter { !$0.sameVolume }.reduce(Int64(0)) { $0 + $1.byteCount }
        let destinationRoot = to.resolvedRootURL ?? ModelStorageLocation.defaultApplicationSupportDirectory
        let capacityProbe = self.nearestExistingAncestor(of: destinationRoot, fileManager: fileManager)
        return ModelStorageMovePlan(
            from: from,
            to: to,
            items: items,
            alreadyAtDestination: alreadyThere,
            requiredBytes: copyBytes > 0 ? copyBytes + self.headroomBytes : 0,
            availableBytes: ModelStorageLocation.availableCapacity(at: capacityProbe)
        )
    }

    /// Splits the FluidAudio folder into its subfolders, so a partly filled destination is merged, not skipped.
    private static func expand(
        _ folders: [ModelStorageFolder],
        from: ModelStorageConfiguration,
        to: ModelStorageConfiguration,
        fileManager: FileManager
    ) -> [ModelStorageFolder] {
        folders.flatMap { folder -> [ModelStorageFolder] in
            guard folder.kind == .fluidAudio else { return [folder] }
            let roots = [folder.configuredURL(in: from), folder.url(in: to)].map { $0.resolvingSymlinksInPath() }
            let names = Set(roots.flatMap { (try? fileManager.contentsOfDirectory(atPath: $0.path)) ?? [] })
                .filter { !self.isIgnoredEntry($0) }
            return names.sorted().map { ModelStorageFolder(name: folder.name, kind: .fluidAudioModel(name: $0)) }
        }
    }

    // MARK: - Running

    /// Runs a move off the caller's actor. Cancel the surrounding task to stop it; cancellation works until the switch begins.
    @concurrent static func run(
        _ plan: ModelStorageMovePlan,
        journal: ModelStorageMoveJournal = .standard,
        fileManager: FileManager = .default,
        hooks: Hooks = Hooks(),
        progress: @escaping @Sendable (ModelStorageMoveProgress) -> Void = { _ in }
    ) async throws -> ModelStorageMoveSummary {
        guard plan.hasEnoughSpace else {
            throw ModelStorageMoveError.insufficientSpace(required: plan.requiredBytes, available: plan.availableBytes)
        }
        let id = UUID().uuidString
        let copies = plan.items.filter { !$0.sameVolume }
        let staging = Dictionary(uniqueKeysWithValues: copies.map { item in
            (
                item.destination.path,
                item.destination.deletingLastPathComponent()
                    .appendingPathComponent("\(self.stagingPrefix)\(id)-\(item.destination.lastPathComponent)", isDirectory: true)
            )
        })
        let entry = { (phase: ModelStorageMoveJournal.Entry.Phase) in
            ModelStorageMoveJournal.Entry(id: id, from: plan.from, to: plan.to, phase: phase, stagingPaths: staging.values.map(\.path))
        }
        try journal.write(entry(.copying))

        var report = ModelStorageMoveProgress(phase: .copying, completedBytes: 0, totalBytes: plan.copyBytes)
        var hashes: [String: [String: SHA256.Digest]] = [:]
        do {
            for item in copies {
                guard let target = staging[item.destination.path] else { continue }
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                hashes[item.destination.path] = try self.copyTree(from: item.resolvedSource, to: target, fileManager: fileManager) { bytes in
                    report.completedBytes += bytes
                    progress(report)
                }
            }

            report = ModelStorageMoveProgress(phase: .verifying, completedBytes: 0, totalBytes: plan.copyBytes)
            progress(report)
            for item in copies {
                guard let target = staging[item.destination.path], let expected = hashes[item.destination.path] else { continue }
                try self.verifyTree(at: target, expected: expected, fileManager: fileManager) { bytes in
                    report.completedBytes += bytes
                    progress(report)
                }
            }
            try Task.checkCancellation()

            progress(ModelStorageMoveProgress(phase: .waitingForIdle, completedBytes: 0, totalBytes: 0))
            try await hooks.beforeSwitch()
            try Task.checkCancellation()
        } catch {
            self.abandon(Array(staging.values), entry: entry(.copying), journal: journal, fileManager: fileManager)
            throw error
        }

        // The switch is short and is not cancelable: it completes or rolls back.
        progress(ModelStorageMoveProgress(phase: .switching, completedBytes: 0, totalBytes: 0))
        try? journal.write(entry(.switching))
        var completed: [(item: ModelStorageMoveItem, movedFrom: URL)] = []
        do {
            for item in plan.items {
                let origin = item.sameVolume ? item.resolvedSource : (staging[item.destination.path] ?? item.resolvedSource)
                try fileManager.createDirectory(at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                // The plan only targets missing or empty folders; check again, since it may be minutes old.
                if fileManager.fileExists(atPath: item.destination.path),
                   !ModelStorageLocation.isSymbolicLink(item.destination, fileManager: fileManager)
                {
                    let entries = try fileManager.contentsOfDirectory(atPath: item.destination.path).filter { !self.isIgnoredEntry($0) }
                    guard entries.isEmpty else {
                        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: item.destination.path])
                    }
                    try fileManager.removeItem(at: item.destination)
                }
                try fileManager.moveItem(at: origin, to: item.destination)
                completed.append((item, origin))
            }
        } catch {
            let stuck = self.rollBack(completed, fileManager: fileManager)
            self.abandon(Array(staging.values), entry: entry(.switching), journal: journal, fileManager: fileManager)
            guard stuck.isEmpty else { throw ModelStorageMoveError.rollbackIncomplete(paths: stuck) }
            throw ModelStorageMoveError.switchFailed(error.localizedDescription)
        }

        if plan.to.usesCustomRoot {
            self.writeMarker(in: plan.to, fileManager: fileManager)
        }
        await hooks.commit(plan.from, plan.to)
        guard await hooks.verifyAfterSwitch() else {
            await hooks.commit(plan.to, plan.from)
            let stuck = self.rollBack(completed, fileManager: fileManager)
            self.abandon(Array(staging.values), entry: entry(.switching), journal: journal, fileManager: fileManager)
            guard stuck.isEmpty else { throw ModelStorageMoveError.rollbackIncomplete(paths: stuck) }
            throw ModelStorageMoveError.modelsMissingAfterSwitch
        }

        progress(ModelStorageMoveProgress(phase: .cleaningUp, completedBytes: 0, totalBytes: 0))
        var summary = ModelStorageMoveSummary()
        for item in plan.items {
            summary.movedBytes += item.byteCount
            summary.movedFolders.append(item.folder.name)
            if !item.sameVolume {
                let copied = Set((hashes[item.destination.path] ?? [:]).keys.filter { !self.isIgnoredEntry(($0 as NSString).lastPathComponent) })
                guard (try? self.regularFiles(in: item.resolvedSource, fileManager: fileManager)) == copied else {
                    // Something wrote to the original after the copy; keep it rather than lose those files.
                    summary.changedOriginals.append(item.resolvedSource.path)
                    continue
                }
                do {
                    try fileManager.removeItem(at: item.resolvedSource)
                } catch {
                    summary.leftoverPaths.append(item.resolvedSource.path)
                }
            }
            if item.sourceIsSymlink {
                summary.leftoverLinks.append(item.source.path)
            }
        }
        journal.remove()
        return summary
    }

    /// Switches to a location without moving files, for "use models already there" and "start empty".
    static func switchWithoutMoving(
        from: ModelStorageConfiguration,
        to: ModelStorageConfiguration,
        fileManager: FileManager = .default,
        hooks: Hooks = Hooks()
    ) async throws {
        try await hooks.beforeSwitch()
        if to.usesCustomRoot {
            self.writeMarker(in: to, fileManager: fileManager)
        }
        await hooks.commit(from, to)
    }

    /// Returns the folders that could not be moved back.
    private static func rollBack(_ completed: [(item: ModelStorageMoveItem, movedFrom: URL)], fileManager: FileManager) -> [String] {
        var stuck: [String] = []
        for entry in completed.reversed() {
            do {
                try fileManager.moveItem(at: entry.item.destination, to: entry.movedFrom)
            } catch {
                stuck.append(entry.item.destination.path)
            }
        }
        return stuck
    }

    /// Removes staging folders and keeps the journal for any that remain, so a later launch can finish the job.
    private static func abandon(
        _ urls: [URL],
        entry: ModelStorageMoveJournal.Entry,
        journal: ModelStorageMoveJournal,
        fileManager: FileManager
    ) {
        var remaining: [String] = []
        for url in urls {
            if fileManager.fileExists(atPath: url.path) {
                if (try? fileManager.removeItem(at: url)) == nil { remaining.append(url.path) }
            } else if let mountPoint = ModelStorageLocation.volumeMountPoint(forPath: url.path), !fileManager.fileExists(atPath: mountPoint) {
                remaining.append(url.path)
            }
        }
        if remaining.isEmpty {
            journal.remove()
        } else {
            try? journal.write(.init(id: entry.id, from: entry.from, to: entry.to, phase: entry.phase, stagingPaths: remaining))
        }
    }

    private static func writeMarker(in configuration: ModelStorageConfiguration, fileManager: FileManager) {
        guard let root = configuration.resolvedRootURL else { return }
        let marker = root.appendingPathComponent(ModelStorageLocation.markerFileName, isDirectory: false)
        guard !fileManager.fileExists(atPath: marker.path) else { return }
        let body = #"{"layoutVersion":1}"#
        try? body.write(to: marker, atomically: true, encoding: .utf8)
    }

    // MARK: - Copy and verify

    /// Copies a folder without following symlinks, keeping permissions and modification times.
    static func copyTree(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default,
        progress: (Int64) -> Void = { _ in }
    ) throws -> [String: SHA256.Digest] {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        var hashes: [String: SHA256.Digest] = [:]
        var directories: [(relative: String, attributes: [FileAttributeKey: Any])] = try [("", fileManager.attributesOfItem(atPath: source.path))]
        let relativePaths = try fileManager.subpathsOfDirectory(atPath: source.path).sorted()
        for relative in relativePaths {
            try Task.checkCancellation()
            let sourcePath = source.appendingPathComponent(relative).path
            let destinationURL = destination.appendingPathComponent(relative)
            let attributes = try fileManager.attributesOfItem(atPath: sourcePath)
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory?:
                try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                directories.append((relative, attributes))
            case .typeSymbolicLink?:
                let target = try fileManager.destinationOfSymbolicLink(atPath: sourcePath)
                try fileManager.createSymbolicLink(atPath: destinationURL.path, withDestinationPath: target)
            case .typeRegular?:
                hashes[relative] = try self.copyFile(at: URL(fileURLWithPath: sourcePath), to: destinationURL, fileManager: fileManager, progress: progress)
                try self.restoreAttributes(attributes, at: destinationURL.path, fileManager: fileManager)
            default:
                continue
            }
        }
        // Children change a folder's time, so folders are stamped last and deepest first.
        for directory in directories.sorted(by: { $0.relative.count > $1.relative.count }) {
            let path = directory.relative.isEmpty ? destination.path : destination.appendingPathComponent(directory.relative).path
            try self.restoreAttributes(directory.attributes, at: path, fileManager: fileManager)
        }
        return hashes
    }

    static func verifyTree(
        at directory: URL,
        expected: [String: SHA256.Digest],
        fileManager: FileManager = .default,
        progress: (Int64) -> Void = { _ in }
    ) throws {
        let regularFiles = try self.regularFiles(in: directory, fileManager: fileManager)
        guard regularFiles == Set(expected.keys.filter { !self.isIgnoredEntry(($0 as NSString).lastPathComponent) }) else {
            throw ModelStorageMoveError.verificationFailed(path: directory.path)
        }
        for relative in regularFiles.sorted() {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(relative)
            guard try self.hashFile(at: url, progress: progress) == expected[relative] else {
                throw ModelStorageMoveError.verificationFailed(path: url.path)
            }
        }
    }

    private static func copyFile(
        at source: URL,
        to destination: URL,
        fileManager: FileManager,
        progress: (Int64) -> Void
    ) throws -> SHA256.Digest {
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try reader.read(upToCount: self.chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            try writer.write(contentsOf: chunk)
            progress(Int64(chunk.count))
        }
        try writer.synchronize()
        return hasher.finalize()
    }

    private static func hashFile(at url: URL, progress: (Int64) -> Void) throws -> SHA256.Digest {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try reader.read(upToCount: self.chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            progress(Int64(chunk.count))
        }
        return hasher.finalize()
    }

    /// Times must survive for the compiled-cache names; permissions are best effort, since exFAT cannot store them.
    private static func restoreAttributes(_ attributes: [FileAttributeKey: Any], at path: String, fileManager: FileManager) throws {
        if let date = attributes[.modificationDate] {
            try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }
        if let permissions = attributes[.posixPermissions] {
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        }
    }

    /// Regular files by relative path, without Finder and extended-attribute sidecar files.
    static func regularFiles(in directory: URL, fileManager: FileManager = .default) throws -> Set<String> {
        try Set(fileManager.subpathsOfDirectory(atPath: directory.path).filter { relative in
            guard !self.isIgnoredEntry((relative as NSString).lastPathComponent) else { return false }
            let attributes = try? fileManager.attributesOfItem(atPath: directory.appendingPathComponent(relative).path)
            return attributes?[.type] as? FileAttributeType == .typeRegular
        })
    }

    static func isIgnoredEntry(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._")
    }

    // MARK: - Helpers

    static func byteCount(of directory: URL, fileManager: FileManager = .default) throws -> Int64 {
        var total: Int64 = 0
        for relative in try fileManager.subpathsOfDirectory(atPath: directory.path) {
            let attributes = try fileManager.attributesOfItem(atPath: directory.appendingPathComponent(relative).path)
            if attributes[.type] as? FileAttributeType == .typeRegular {
                total += (attributes[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return total
    }

    private static func directoryHasContent(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        // An unreadable folder counts as occupied, so it is never treated as an empty destination.
        guard let entries = try? fileManager.contentsOfDirectory(atPath: url.path) else { return true }
        return entries.contains { !self.isIgnoredEntry($0) }
    }

    private static func isSameOrInside(_ url: URL, _ container: URL) -> Bool {
        url.path == container.path || url.path.hasPrefix(container.path + "/")
    }

    private static func nearestExistingAncestor(of url: URL, fileManager: FileManager) -> URL {
        var candidate = url
        while !fileManager.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
            candidate = candidate.deletingLastPathComponent()
        }
        return candidate
    }

    private static func volumeIdentifier(_ url: URL) -> String? {
        guard let identifier = try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else { return nil }
        return String(describing: identifier)
    }
}

/// Records a move in progress, so the next launch can clean up after a crash or a quit.
nonisolated struct ModelStorageMoveJournal {
    struct Entry: Codable, Equatable {
        enum Phase: String, Codable { case copying, switching }
        let id: String
        let from: ModelStorageConfiguration
        let to: ModelStorageConfiguration
        let phase: Phase
        let stagingPaths: [String]
    }

    let url: URL

    static var standard: ModelStorageMoveJournal {
        ModelStorageMoveJournal(
            url: ModelStorageLocation.defaultApplicationSupportDirectory
                .appendingPathComponent("FluidVoice", isDirectory: true)
                .appendingPathComponent("model-storage-move.json", isDirectory: false)
        )
    }

    func write(_ entry: Entry) throws {
        try FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: self.url, options: .atomic)
    }

    func read() -> Entry? {
        guard let data = try? Data(contentsOf: self.url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.url)
    }

    /// Removes staging folders that are reachable and keeps the journal for those that are not.
    func recoverInterruptedMove(fileManager: FileManager = .default) -> Entry? {
        guard let entry = self.read() else { return nil }
        var unreachable: [String] = []
        // Only folders this move created are deleted, whatever the journal file says.
        for path in entry.stagingPaths where (path as NSString).lastPathComponent.hasPrefix("\(ModelStorageMover.stagingPrefix)\(entry.id)-") {
            if fileManager.fileExists(atPath: path) {
                if (try? fileManager.removeItem(atPath: path)) == nil {
                    unreachable.append(path)
                }
            } else if let mountPoint = ModelStorageLocation.volumeMountPoint(forPath: path), !fileManager.fileExists(atPath: mountPoint) {
                unreachable.append(path)
            }
        }
        if unreachable.isEmpty {
            self.remove()
        } else {
            try? self.write(.init(id: entry.id, from: entry.from, to: entry.to, phase: entry.phase, stagingPaths: unreachable))
        }
        return entry
    }
}
