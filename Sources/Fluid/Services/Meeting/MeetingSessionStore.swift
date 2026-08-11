import Foundation

nonisolated protocol MeetingSessionStoring: Sendable {
    func create(_ session: MeetingSession) async throws
    func save(_ session: MeetingSession) async throws
    func load(id: MeetingSessionID) async throws -> MeetingSession?
    func loadAll() async throws -> [MeetingSession]
    func loadRecoverable() async throws -> [MeetingSession]
    func sessionDirectory(for id: MeetingSessionID) async throws -> URL
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
        let url = self.sessionManifestURL(for: id)
        guard self.fileSystem.manager.fileExists(atPath: url.path) else { return nil }
        let session = try self.decodeSession(at: url)
        let reconciled = try self.reconcileTrackManifests(in: session)
        if reconciled != session {
            try self.writeSession(reconciled)
        }
        return reconciled
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
            guard $0.recoveryResolvedAt == nil else { return false }
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
        try self.prepareRootDirectory()
        let directory = self.sessionDirectoryURL(for: id)
        if !self.fileSystem.manager.fileExists(atPath: directory.path) {
            try self.createPrivateDirectory(directory)
            try self.createPrivateDirectory(directory.appendingPathComponent("tracks", isDirectory: true))
        }
        return directory
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

    private func reconcileTrackManifests(in inputSession: MeetingSession) throws -> MeetingSession {
        var session = inputSession
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

            if let index = session.audioTracks.firstIndex(where: { $0.kind == kind }) {
                guard session.audioTracks[index].id == track.id else { continue }
                session.audioTracks[index] = track
            } else {
                session.audioTracks.append(track)
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

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyExists:
            return "A meeting session with this identifier already exists."
        case let .unsupportedSchema(version):
            return "This meeting was created with unsupported schema version \(version)."
        }
    }
}
