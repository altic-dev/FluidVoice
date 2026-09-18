import CryptoKit
import Darwin
import Foundation

/// P0b writer-ledger facts. These are intentionally standalone and optional at the session layer:
/// old session JSON never contains them, while the PCM-first writer durably checkpoints each new
/// capture chunk. Legacy AAC sessions continue to decode without these records.
nonisolated struct MeetingAudioChunkLedgerIntent: Codable, Equatable, Sendable {
    var chunkID: MeetingAudioChunkID
    var sequence: Int
    var canonicalStart: MeetingMediaTime
    var producerEpoch: UInt64
    var sourceFormat: MeetingAudioFormat
    var partialRelativeFilePath: String
    var createdAt: Date
}

nonisolated struct MeetingAudioChunkLedgerCheckpoint: Codable, Equatable, Sendable {
    var chunkID: MeetingAudioChunkID
    var expectedFrames: Int64
    var writtenFrames: Int64
    var lastCanonicalPTS: MeetingMediaTime?
    var updatedAt: Date
}

nonisolated enum MeetingAudioChunkLedgerTerminalStatus: Equatable, Sendable {
    case ready
    case failed
    case unknown(String)

    var rawValue: String { switch self { case .ready: return "ready"; case .failed: return "failed"; case let .unknown(raw): return raw } }
    init(rawValue: String) { self = rawValue == "ready" ? .ready : rawValue == "failed" ? .failed : .unknown(rawValue) }
}

nonisolated extension MeetingAudioChunkLedgerTerminalStatus: Codable {
    init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

nonisolated struct MeetingAudioChunkLedgerTerminal: Codable, Equatable, Sendable {
    var chunkID: MeetingAudioChunkID
    var status: MeetingAudioChunkLedgerTerminalStatus
    var updatedAt: Date
    var detail: String?
}

nonisolated enum MeetingAudioChunkLedgerError: Error, Equatable, Sendable {
    case invalidChunkID
    case pathRejected
    case conflictingIntent
    case checkpointRegression
    case incompleteReadyTerminal
    case terminalAlreadyExists
    case durabilityFailure(String)
}

/// A serialized-queue-only ledger store. It does no dispatching or locking itself, and must never
/// be called by a real-time callback. Intent is immutable/no-overwrite; checkpoints are atomic
/// replacements; terminal status is immutable/no-overwrite. Every record is fsynced before its
/// rename and the containing directory is fsynced after publication.
nonisolated final class MeetingAudioChunkLedgerStore: @unchecked Sendable {
    let sessionDirectory: URL
    private let ledgerDirectoryName = "chunk-ledger"

    init(sessionDirectory: URL) { self.sessionDirectory = sessionDirectory.standardizedFileURL }

    func writeIntent(_ intent: MeetingAudioChunkLedgerIntent) throws {
        try validate(intent.partialRelativeFilePath)
        try ensureLedgerDirectory()
        let url = try recordURL(chunkID: intent.chunkID, suffix: "intent")
        try writeImmutable(try encode(intent), to: url, conflict: .conflictingIntent)
    }

    func writeCheckpoint(_ checkpoint: MeetingAudioChunkLedgerCheckpoint, for chunkID: MeetingAudioChunkID) throws {
        guard checkpoint.chunkID == chunkID else { throw MeetingAudioChunkLedgerError.invalidChunkID }
        guard try readIntent(for: chunkID) != nil else {
            throw MeetingAudioChunkLedgerError.durabilityFailure("checkpoint has no intent")
        }
        guard checkpoint.expectedFrames >= 0, checkpoint.writtenFrames >= 0,
              checkpoint.writtenFrames <= checkpoint.expectedFrames
        else {
            throw MeetingAudioChunkLedgerError.durabilityFailure("invalid checkpoint frame totals")
        }
        if let previous = try readCheckpoint(for: chunkID) {
            guard checkpoint.expectedFrames >= previous.expectedFrames,
                  checkpoint.writtenFrames >= previous.writtenFrames,
                  Self.isNondecreasing(previous.lastCanonicalPTS, checkpoint.lastCanonicalPTS)
            else { throw MeetingAudioChunkLedgerError.checkpointRegression }
        }
        try ensureLedgerDirectory()
        try writeReplacing(try encode(checkpoint), to: try recordURL(chunkID: chunkID, suffix: "checkpoint"))
    }

    func writeTerminal(_ terminal: MeetingAudioChunkLedgerTerminal, for chunkID: MeetingAudioChunkID) throws {
        guard terminal.chunkID == chunkID else { throw MeetingAudioChunkLedgerError.invalidChunkID }
        guard try readIntent(for: chunkID) != nil else {
            throw MeetingAudioChunkLedgerError.durabilityFailure("terminal has no intent")
        }
        if terminal.status == .ready {
            guard let checkpoint = try readCheckpoint(for: chunkID),
                  checkpoint.expectedFrames > 0,
                  checkpoint.expectedFrames == checkpoint.writtenFrames
            else { throw MeetingAudioChunkLedgerError.incompleteReadyTerminal }
        }
        try ensureLedgerDirectory()
        try writeImmutable(try encode(terminal), to: try recordURL(chunkID: chunkID, suffix: "terminal"), conflict: .terminalAlreadyExists)
    }

    func readIntent(for chunkID: MeetingAudioChunkID) throws -> MeetingAudioChunkLedgerIntent? { try read(MeetingAudioChunkLedgerIntent.self, at: try recordURL(chunkID: chunkID, suffix: "intent")) }
    func readCheckpoint(for chunkID: MeetingAudioChunkID) throws -> MeetingAudioChunkLedgerCheckpoint? { try read(MeetingAudioChunkLedgerCheckpoint.self, at: try recordURL(chunkID: chunkID, suffix: "checkpoint")) }
    func readTerminal(for chunkID: MeetingAudioChunkID) throws -> MeetingAudioChunkLedgerTerminal? { try read(MeetingAudioChunkLedgerTerminal.self, at: try recordURL(chunkID: chunkID, suffix: "terminal")) }

    private func validate(_ relative: String) throws {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"), !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw MeetingAudioChunkLedgerError.pathRejected }
    }
    private func recordURL(chunkID: UUID, suffix: String) throws -> URL {
        let directory = sessionDirectory.appendingPathComponent(ledgerDirectoryName, isDirectory: true)
        return directory.appendingPathComponent("\(chunkID.uuidString).\(suffix).json")
    }
    private func ensureLedgerDirectory() throws {
        var rootInfo = stat()
        guard lstat(sessionDirectory.path, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR
        else { throw MeetingAudioChunkLedgerError.pathRejected }
        let directory = sessionDirectory.appendingPathComponent(ledgerDirectoryName, isDirectory: true)
        var directoryInfo = stat()
        if lstat(directory.path, &directoryInfo) == 0 {
            guard (directoryInfo.st_mode & S_IFMT) == S_IFDIR else {
                throw MeetingAudioChunkLedgerError.pathRejected
            }
        } else {
            guard errno == ENOENT else { throw MeetingAudioChunkLedgerError.pathRejected }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        }
        guard chmod(directory.path, mode_t(0o700)) == 0 else {
            throw MeetingAudioChunkLedgerError.durabilityFailure("chmod directory")
        }
    }
    private static func isNondecreasing(_ previous: MeetingMediaTime?, _ next: MeetingMediaTime?) -> Bool {
        guard let previous else { return true }
        guard let next else { return false }
        return next.seconds >= previous.seconds
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? { guard FileManager.default.fileExists(atPath: url.path) else { return nil }; let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return try decoder.decode(type, from: Data(contentsOf: url, options: .mappedIfSafe)) }
    private func writeImmutable(_ data: Data, to destination: URL, conflict: MeetingAudioChunkLedgerError) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            guard (try? Data(contentsOf: destination)) == data else { throw conflict }
            return
        }
        try writeTemp(data, destination: destination, exclusive: true, conflict: conflict)
    }
    private func writeReplacing(_ data: Data, to destination: URL) throws { try writeTemp(data, destination: destination, exclusive: false) }
    private func writeTemp(_ data: Data, destination: URL, exclusive: Bool, conflict: MeetingAudioChunkLedgerError? = nil) throws {
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp, options: [])
        guard chmod(temp.path, mode_t(0o600)) == 0 else { try? FileManager.default.removeItem(at: temp); throw MeetingAudioChunkLedgerError.durabilityFailure("chmod") }
        let fd = open(temp.path, O_RDONLY); guard fd >= 0 else { try? FileManager.default.removeItem(at: temp); throw MeetingAudioChunkLedgerError.durabilityFailure("open") }; defer { close(fd) }
        guard fcntl(fd, F_FULLFSYNC) == 0 else { try? FileManager.default.removeItem(at: temp); throw MeetingAudioChunkLedgerError.durabilityFailure("F_FULLFSYNC") }
        let flags = exclusive ? UInt32(RENAME_EXCL) : 0
        guard renameatx_np(AT_FDCWD, temp.path, AT_FDCWD, destination.path, flags) == 0 else { let e = errno; try? FileManager.default.removeItem(at: temp); if exclusive && e == EEXIST { throw conflict ?? .terminalAlreadyExists }; throw MeetingAudioChunkLedgerError.durabilityFailure("rename errno \(e)") }
        let dirFD = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY); guard dirFD >= 0 else { throw MeetingAudioChunkLedgerError.durabilityFailure("open directory") }; defer { close(dirFD) }; guard fsync(dirFD) == 0 else { throw MeetingAudioChunkLedgerError.durabilityFailure("directory fsync") }
    }
}
