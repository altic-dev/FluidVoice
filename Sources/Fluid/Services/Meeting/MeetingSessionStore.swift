import CryptoKit
import Darwin
import Foundation

nonisolated protocol MeetingSessionStoring: Sendable {
    func create(_ session: MeetingSession) async throws
    func save(_ session: MeetingSession) async throws
    func load(id: MeetingSessionID) async throws -> MeetingSession?
    func loadAll() async throws -> [MeetingSession]
    func loadRecoverable() async throws -> [MeetingSession]
    func sessionDirectory(for id: MeetingSessionID) async throws -> URL
    func existingSessionDirectory(for id: MeetingSessionID) async throws -> URL?
    func delete(id: MeetingSessionID) async throws
    /// Removes the `tracks/` directory and any processing checkpoint, leaving the manifest and
    /// transcript untouched. Idempotent — missing paths are not an error.
    func deleteAudioFiles(for id: MeetingSessionID) async throws
}

private final nonisolated class MeetingSessionFileSystem: @unchecked Sendable {
    let manager: FileManager

    init(manager: FileManager) {
        self.manager = manager
    }
}

actor MeetingSessionStore: MeetingSessionStoring {
    static let shared = MeetingSessionStore()

    private struct SessionIndex: Codable {
        static let currentSchemaVersion = 1

        var schemaVersion: Int
        var sessionIDs: [MeetingSessionID]
        var updatedAt: Date
    }

    private let fileSystem: MeetingSessionFileSystem
    private let rootDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var tombstonedIDs: Set<MeetingSessionID> = []

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileSystem = MeetingSessionFileSystem(manager: fileManager)
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.rootDirectory = applicationSupport
                .appendingPathComponent("FluidVoice", isDirectory: true)
                .appendingPathComponent("Meetings", isDirectory: true)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func create(_ session: MeetingSession) throws {
        guard !self.tombstonedIDs.contains(session.id) else {
            throw MeetingSessionStoreError.sessionDeleted
        }
        try session.validateForPersistence()
        try self.prepareRootDirectory()
        let directory = self.sessionDirectoryURL(for: session.id)
        guard !self.fileSystem.manager.fileExists(atPath: directory.path) else {
            throw MeetingSessionStoreError.sessionAlreadyExists
        }
        try self.createPrivateDirectory(directory)
        try self.createPrivateDirectory(directory.appendingPathComponent("tracks", isDirectory: true))
        try self.writeSession(session)
        try self.addToIndex(session.id)
    }

    func save(_ session: MeetingSession) throws {
        guard !self.tombstonedIDs.contains(session.id) else {
            throw MeetingSessionStoreError.sessionDeleted
        }
        try session.validateForPersistence()
        try self.prepareRootDirectory()
        let directory = self.sessionDirectoryURL(for: session.id)
        if !self.fileSystem.manager.fileExists(atPath: directory.path) {
            try self.createPrivateDirectory(directory)
            try self.createPrivateDirectory(directory.appendingPathComponent("tracks", isDirectory: true))
        }
        try self.writeSession(session)
        try self.addToIndex(session.id)
    }

    func load(id: MeetingSessionID) throws -> MeetingSession? {
        guard !self.tombstonedIDs.contains(id) else { return nil }
        let url = self.sessionManifestURL(for: id)
        guard self.fileSystem.manager.fileExists(atPath: url.path) else { return nil }
        let session = try self.decodeSession(at: url)
        let reconciled = try self.reconcileTrackManifests(in: session)
        let migrated = self.migrateCanonicalTranscriptTimelineIfNeeded(reconciled)
        if migrated != session {
            try self.writeSession(migrated)
        }
        return migrated
    }

    func loadAll() throws -> [MeetingSession] {
        try self.prepareRootDirectory()
        let indexedIDs = (try? self.readIndex().sessionIDs) ?? []
        let discoveredIDs = try self.discoverSessionIDs()
        let allIDs = Array(Set(indexedIDs).union(discoveredIDs))

        var sessions: [MeetingSession] = []
        sessions.reserveCapacity(allIDs.count)
        for id in allIDs {
            do {
                if let session = try self.load(id: id) {
                    sessions.append(session)
                }
            } catch {
                DebugLogger.shared.error(
                    "Failed to load meeting session \(id): \(error.localizedDescription)",
                    source: "MeetingSessionStore"
                )
            }
        }
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    func loadRecoverable() throws -> [MeetingSession] {
        try self.loadAll().filter {
            guard $0.recoveryResolvedAt == nil, $0.retention.audioDeletedAt == nil else { return false }
            switch $0.state {
            case .preparing, .recording, .recordingDegraded, .stopping, .processing, .interrupted:
                return true
            case .failed:
                return $0.failures.last?.recoverable == true &&
                    $0.endedAt != nil &&
                    $0.audioTracks.contains { track in
                        track.chunks.contains {
                            $0.finalizationState == .finalized && $0.byteCount > 0
                        }
                    }
            case .completed:
                return false
            }
        }
    }

    func sessionDirectory(for id: MeetingSessionID) throws -> URL {
        guard !self.tombstonedIDs.contains(id) else {
            throw MeetingSessionStoreError.sessionDeleted
        }
        try self.prepareRootDirectory()
        let directory = self.sessionDirectoryURL(for: id)
        if !self.fileSystem.manager.fileExists(atPath: directory.path) {
            try self.createPrivateDirectory(directory)
            try self.createPrivateDirectory(directory.appendingPathComponent("tracks", isDirectory: true))
        }
        return directory
    }

    func existingSessionDirectory(for id: MeetingSessionID) throws -> URL? {
        let directory = self.sessionDirectoryURL(for: id)
        return self.fileSystem.manager.fileExists(atPath: directory.path) ? directory : nil
    }

    func delete(id: MeetingSessionID) throws {
        self.tombstonedIDs.insert(id)
        let directory = self.sessionDirectoryURL(for: id)
        if self.fileSystem.manager.fileExists(atPath: directory.path) {
            try self.fileSystem.manager.removeItem(at: directory)
        }
        try self.removeFromIndex(id)
    }

    func deleteAudioFiles(for id: MeetingSessionID) throws {
        let directory = self.sessionDirectoryURL(for: id)
        let tracksURL = directory.appendingPathComponent("tracks", isDirectory: true)
        if self.fileSystem.manager.fileExists(atPath: tracksURL.path) {
            try self.fileSystem.manager.removeItem(at: tracksURL)
        }
        let checkpointURL = directory.appendingPathComponent("checkpoint.json", isDirectory: false)
        if self.fileSystem.manager.fileExists(atPath: checkpointURL.path) {
            try self.fileSystem.manager.removeItem(at: checkpointURL)
        }
    }

    private func writeSession(_ session: MeetingSession) throws {
        let data = try self.encoder.encode(session)
        try self.atomicPrivateWrite(data, to: self.sessionManifestURL(for: session.id))
    }

    private func decodeSession(at url: URL) throws -> MeetingSession {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let session = try self.decoder.decode(MeetingSession.self, from: data)
        try session.validateForPersistence()
        return session
    }

    /// Canonical sessions published before the explicit timeline-domain marker stored product
    /// segment/gap times in absolute host presentation seconds. The immutable sidecar remains in
    /// analysis time and carries the verified presentation origin, so migrate only `session.json`
    /// once and never rewrite the sidecar it references.
    private func migrateCanonicalTranscriptTimelineIfNeeded(
        _ inputSession: MeetingSession
    ) -> MeetingSession {
        guard inputSession.transcriptTimeDomain == nil,
              let reference = inputSession.resultSidecarReference,
              let attempt = inputSession.processingAttempts.last(where: {
                  $0.backendID != nil
                      && MeetingResultSidecarStore.fileName(for: $0.id) == reference.fileName
              }),
              let backendID = attempt.backendID.map({ MeetingBackendID(rawValue: $0) })
        else { return inputSession }

        let directory = self.sessionDirectoryURL(for: inputSession.id)
        let verifiedOrigin: TimeInterval?
        do {
            let sidecar = try MeetingResultSidecarStore(sessionDirectory: directory).read(
                expectedAttemptID: attempt.id,
                expectedBackendID: backendID,
                reference: reference
            )
            verifiedOrigin = sidecar.analysisManifest.presentationOriginSeconds
        } catch {
            verifiedOrigin = nil
            DebugLogger.shared.warning(
                "Could not verify canonical transcript sidecar while migrating timeline for "
                    + "\(inputSession.id): \(error.localizedDescription)",
                source: "MeetingSessionStore"
            )
        }

        let origin = verifiedOrigin ?? inputSession.timebase.firstPresentationTime?.seconds
        guard let origin,
              let migrated = Self.migratingCanonicalTimelineToMeetingRelative(
                  inputSession,
                  presentationOriginSeconds: origin
              )
        else {
            DebugLogger.shared.warning(
                "Canonical transcript timeline for \(inputSession.id) could not be migrated safely.",
                source: "MeetingSessionStore"
            )
            return inputSession
        }
        DebugLogger.shared.info(
            "Migrated canonical transcript timeline to meeting-relative seconds for \(inputSession.id).",
            source: "MeetingSessionStore"
        )
        return migrated
    }

    /// Pure migration seam used by load-time recovery and tests. A negative result beyond the
    /// rounding tolerance means the supplied origin does not describe this transcript, so refuse
    /// the whole migration instead of partially shifting or guessing.
    nonisolated static func migratingCanonicalTimelineToMeetingRelative(
        _ inputSession: MeetingSession,
        presentationOriginSeconds origin: TimeInterval
    ) -> MeetingSession? {
        guard inputSession.transcriptTimeDomain == nil, origin.isFinite, origin >= 0 else {
            return nil
        }
        let tolerance = MeetingAnalysisManifestSchema.mappingToleranceSeconds
        var migrated = inputSession

        for index in migrated.transcriptSegments.indices {
            let start = migrated.transcriptSegments[index].start.seconds - origin
            let end = migrated.transcriptSegments[index].end.seconds - origin
            guard start.isFinite, end.isFinite,
                  start >= -tolerance,
                  end + tolerance >= start,
                  let shiftedStart = Self.mediaTime(
                      seconds: max(0, start),
                      timescale: migrated.transcriptSegments[index].start.timescale
                  ),
                  let shiftedEnd = Self.mediaTime(
                      seconds: max(max(0, start), end),
                      timescale: migrated.transcriptSegments[index].end.timescale
                  )
            else { return nil }
            migrated.transcriptSegments[index].start = shiftedStart
            migrated.transcriptSegments[index].end = shiftedEnd
        }

        if var gaps = migrated.transcriptCoverageGaps {
            for index in gaps.indices {
                let start = gaps[index].start - origin
                let end = gaps[index].end - origin
                guard start.isFinite, end.isFinite,
                      start >= -tolerance,
                      end + tolerance >= start
                else { return nil }
                gaps[index].start = max(0, start)
                gaps[index].end = max(gaps[index].start, end)
            }
            migrated.transcriptCoverageGaps = gaps
        }

        migrated.transcriptTimeDomain = .meetingRelative
        return migrated
    }

    private nonisolated static func mediaTime(
        seconds: TimeInterval,
        timescale: Int32
    ) -> MeetingMediaTime? {
        guard seconds.isFinite, seconds >= 0, timescale > 0 else { return nil }
        let scaled = seconds * Double(timescale)
        guard scaled.isFinite,
              scaled >= Double(Int64.min),
              scaled <= Double(Int64.max)
        else { return nil }
        return MeetingMediaTime(value: Int64(scaled.rounded()), timescale: timescale)
    }

    private func reconcileTrackManifests(in inputSession: MeetingSession) throws -> MeetingSession {
        var session = inputSession

        // Audio was already deleted: never re-import a leftover tracks/ manifest from the crash
        // window between the cleared save and file removal — audioDeletedAt is authoritative.
        guard session.retention.audioDeletedAt == nil else {
            for index in session.audioTracks.indices where !session.audioTracks[index].chunks.isEmpty {
                session.audioTracks[index].chunks = []
            }
            try session.validateForPersistence()
            return session
        }

        let expectedKinds: Set<MeetingAudioTrackKind> = session.mode == .onlineCall
            ? [.applicationAudio, .microphone]
            : [.microphone]
        let sessionDirectory = self.sessionDirectoryURL(for: session.id)

        for kind in expectedKinds {
            let manifestURL = sessionDirectory
                .appendingPathComponent("tracks", isDirectory: true)
                .appendingPathComponent(kind.rawValue, isDirectory: true)
                .appendingPathComponent("track.json", isDirectory: false)
            guard self.fileSystem.manager.fileExists(atPath: manifestURL.path),
                  let data = try? Data(contentsOf: manifestURL, options: .mappedIfSafe),
                  var track = try? self.decoder.decode(MeetingAudioTrack.self, from: data),
                  track.kind == kind
            else { continue }

            track.chunks = track.chunks.map { chunk in
                self.reconcileChunkFile(chunk, sessionDirectory: sessionDirectory)
            }.sorted { $0.sequence < $1.sequence }

            var candidate = session
            if let index = candidate.audioTracks.firstIndex(where: { $0.kind == kind }) {
                guard candidate.audioTracks[index].id == track.id else { continue }
                candidate.audioTracks[index] = track
            } else {
                candidate.audioTracks.append(track)
            }
            candidate.audioTracks.sort { $0.kind.rawValue < $1.kind.rawValue }
            candidate.timebase.firstPresentationTime = candidate.audioTracks
                .flatMap(\.chunks)
                .map(\.presentationStart)
                .min()
            do {
                try candidate.validateForPersistence()
                session = candidate
            } catch {
                // A crash-window track manifest is subordinate to the last valid session snapshot.
                // Never let one malformed track make its sibling audio and recovery state unloadable.
                DebugLogger.shared.warning(
                    "Ignored invalid \(kind.rawValue) track recovery manifest: \(error.localizedDescription)",
                    source: "MeetingSessionStore"
                )
            }
        }

        session.audioTracks.sort { $0.kind.rawValue < $1.kind.rawValue }
        let firstPresentationTime = session.audioTracks
            .flatMap(\.chunks)
            .map(\.presentationStart)
            .min()
        if let firstPresentationTime {
            session.timebase.firstPresentationTime = firstPresentationTime
        }
        try session.validateForPersistence()
        return session
    }

    private func reconcileChunkFile(
        _ inputChunk: MeetingAudioChunk,
        sessionDirectory: URL
    ) -> MeetingAudioChunk {
        // New asset metadata is an explicit one-way boundary. Never apply the legacy
        // size-repair rule to it: a staged/foreign file must not become trusted merely because it
        // exists. Sessions with no new metadata retain the exact historical AAC behavior below.
        if inputChunk.audioSchemaVersion != nil || inputChunk.captureAnalysisAsset != nil || inputChunk.playbackArchiveAsset != nil {
            return self.reconcileNewAssetChunk(inputChunk, sessionDirectory: sessionDirectory)
        }
        guard inputChunk.finalizationState == .finalized else { return inputChunk }
        let fileURL = inputChunk.fileURL(relativeTo: sessionDirectory).standardizedFileURL
        let rootPath = sessionDirectory.standardizedFileURL.path + "/"
        guard fileURL.path.hasPrefix(rootPath),
              self.fileSystem.manager.fileExists(atPath: fileURL.path),
              let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize > 0
        else {
            var failedChunk = inputChunk
            failedChunk.sha256 = ""
            failedChunk.byteCount = 0
            failedChunk.finalizationState = .failed
            return failedChunk
        }
        var reconciled = inputChunk
        reconciled.byteCount = Int64(fileSize)
        return reconciled
    }

    private func reconcileNewAssetChunk(
        _ inputChunk: MeetingAudioChunk,
        sessionDirectory: URL
    ) -> MeetingAudioChunk {
        var failed = inputChunk
        func failCapture(_ chunk: inout MeetingAudioChunk) {
            chunk.sha256 = ""
            chunk.byteCount = 0
            chunk.finalizationState = .failed
            if var asset = chunk.captureAnalysisAsset, asset.presence == .ready { asset.presence = .failed; chunk.captureAnalysisAsset = asset }
        }
        guard let capture = inputChunk.captureAnalysisAsset,
              capture.role == .captureAnalysis,
              capture.presence == .ready,
              capture.validationIssues().isEmpty,
              self.assetMatchesDisk(capture, sessionDirectory: sessionDirectory)
        else {
            failCapture(&failed)
            return failed
        }
        var reconciled = inputChunk
        if var archive = reconciled.playbackArchiveAsset,
           archive.presence == .ready,
           (!archive.validationIssues().isEmpty || !self.assetMatchesDisk(archive, sessionDirectory: sessionDirectory))
        {
            // The archive is derived and optional. Quarantine only it; authoritative PCM remains
            // finalized and retryable for a later archive job.
            archive.presence = .failed
            reconciled.playbackArchiveAsset = archive
        }
        reconciled.byteCount = capture.byteCount
        reconciled.sha256 = capture.sha256 ?? ""
        reconciled.finalizationState = .finalized
        return reconciled
    }

    private func assetMatchesDisk(_ asset: MeetingAudioAsset, sessionDirectory: URL) -> Bool {
        guard let url = self.confinedRegularAssetURL(
            relativePath: asset.relativeFilePath,
            sessionDirectory: sessionDirectory
        ), let attributes = try? self.fileSystem.manager.attributesOfItem(atPath: url.path),
           let size = (attributes[.size] as? NSNumber)?.int64Value,
           size == asset.byteCount,
           size > 0,
           let expectedHash = asset.sha256,
           let hash = self.sha256(of: url),
           hash == expectedHash
        else { return false }
        return true
    }

    /// Lexical confinement plus an lstat walk. A descriptor-relative walk is intentionally outside
    /// this additive foundation; concurrent path replacement remains a documented TOCTOU limit.
    private func confinedRegularAssetURL(relativePath: String, sessionDirectory: URL) -> URL? {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        var current = sessionDirectory.standardizedFileURL
        var rootStat = stat()
        guard lstat(current.path, &rootStat) == 0, (rootStat.st_mode & S_IFMT) != S_IFLNK else { return nil }
        for part in parts {
            current.appendPathComponent(part, isDirectory: false)
            var info = stat()
            guard lstat(current.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else { return nil }
        }
        var final = stat()
        guard lstat(current.path, &final) == 0, (final.st_mode & S_IFMT) == S_IFREG else { return nil }
        return current
    }

    private func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            let data: Data
            do { data = try handle.read(upToCount: 1 << 20) ?? Data() }
            catch { return nil }
            guard !data.isEmpty else { break }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func prepareRootDirectory() throws {
        if !self.fileSystem.manager.fileExists(atPath: self.rootDirectory.path) {
            try self.createPrivateDirectory(self.rootDirectory)
        }
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try self.fileSystem.manager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try self.fileSystem.manager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }

    private func atomicPrivateWrite(_ data: Data, to destination: URL) throws {
        try data.write(to: destination, options: .atomic)
        try self.fileSystem.manager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: destination.path
        )
    }

    private func readIndex() throws -> SessionIndex {
        let url = self.rootDirectory.appendingPathComponent("index.json", isDirectory: false)
        guard self.fileSystem.manager.fileExists(atPath: url.path) else {
            return SessionIndex(
                schemaVersion: SessionIndex.currentSchemaVersion,
                sessionIDs: [],
                updatedAt: Date()
            )
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try self.decoder.decode(SessionIndex.self, from: data)
    }

    private func addToIndex(_ id: MeetingSessionID) throws {
        var index = (try? self.readIndex()) ?? SessionIndex(
            schemaVersion: SessionIndex.currentSchemaVersion,
            sessionIDs: [],
            updatedAt: Date()
        )
        if !index.sessionIDs.contains(id) {
            index.sessionIDs.append(id)
        }
        index.updatedAt = Date()
        let data = try self.encoder.encode(index)
        try self.atomicPrivateWrite(
            data,
            to: self.rootDirectory.appendingPathComponent("index.json", isDirectory: false)
        )
    }

    private func removeFromIndex(_ id: MeetingSessionID) throws {
        var index = (try? self.readIndex()) ?? SessionIndex(
            schemaVersion: SessionIndex.currentSchemaVersion,
            sessionIDs: [],
            updatedAt: Date()
        )
        index.sessionIDs.removeAll { $0 == id }
        index.updatedAt = Date()
        let data = try self.encoder.encode(index)
        try self.atomicPrivateWrite(
            data,
            to: self.rootDirectory.appendingPathComponent("index.json", isDirectory: false)
        )
    }

    private func discoverSessionIDs() throws -> [MeetingSessionID] {
        let urls = try self.fileSystem.manager.contentsOfDirectory(
            at: self.rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            return UUID(uuidString: url.lastPathComponent)
        }
    }

    private func sessionDirectoryURL(for id: MeetingSessionID) -> URL {
        self.rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func sessionManifestURL(for id: MeetingSessionID) -> URL {
        self.sessionDirectoryURL(for: id)
            .appendingPathComponent("session.json", isDirectory: false)
    }
}

enum MeetingSessionStoreError: LocalizedError {
    case sessionAlreadyExists
    case unsupportedSchema(Int)
    case sessionDeleted

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyExists:
            return "A meeting session with this identifier already exists."
        case let .unsupportedSchema(version):
            return "This meeting was created with unsupported schema version \(version)."
        case .sessionDeleted:
            return "This meeting has been deleted."
        }
    }
}
