import CryptoKit
import Darwin
import Foundation

// Stage C1 of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md` (§4): durable persistence for the
// self-contained result sidecar. Writes are atomic, permission-tightened and read-back-verified
// before a reference is returned; reads re-hash the file and re-check schema, attempt and
// backend identity against that reference. All paths are confined to the session directory —
// the store derives the only legal file name itself, so a reference can never point at scratch
// or checkpoint files, and retention follows the session directory like the plan requires.
//
// The returned reference is what a later Stage C step will embed in the session JSON; no
// `MeetingSession` field exists for it yet, so old sessions are unaffected by this slice.

/// Hash and location of a persisted sidecar. Verification re-hashes file content: a stored
/// digest alone never proves the file is still intact.
nonisolated enum MeetingResultSidecarReferenceSchema {
    static let currentVersion = 1
}

nonisolated struct MeetingResultSidecarReference: Codable, Equatable {
    let formatVersion: Int
    let fileName: String
    let sha256: String
    let byteCount: Int
}

nonisolated enum MeetingResultSidecarStoreError: LocalizedError, Equatable {
    case unsupportedReferenceFormatVersion(found: Int)
    case unexpectedFileName(expected: String, actual: String)
    case pathEscapesSessionDirectory
    case checksumMismatch
    case byteCountMismatch(expected: Int, actual: Int)
    case attemptMismatch(expected: UUID, actual: UUID)
    case backendMismatch(expected: MeetingBackendID, actual: MeetingBackendID)
    case conflictingExistingSidecar(attemptID: UUID)
    case durabilitySyncFailed

    var errorDescription: String? {
        switch self {
        case let .unsupportedReferenceFormatVersion(found):
            return "Meeting result sidecar reference has unsupported format version \(found)."
        case let .unexpectedFileName(expected, actual):
            return "Meeting result sidecar reference names \"\(actual)\"; expected \"\(expected)\"."
        case .pathEscapesSessionDirectory:
            return "Meeting result sidecar path escapes its session directory."
        case .checksumMismatch:
            return "Meeting result sidecar content does not match its recorded SHA-256."
        case let .byteCountMismatch(expected, actual):
            return "Meeting result sidecar is \(actual) bytes; expected \(expected)."
        case let .attemptMismatch(expected, actual):
            return "Meeting result sidecar carries attempt \(actual); expected \(expected)."
        case let .backendMismatch(expected, actual):
            return "Meeting result sidecar carries backend \"\(actual)\"; expected \"\(expected)\"."
        case let .conflictingExistingSidecar(attemptID):
            return "Meeting attempt \(attemptID) already has a different immutable result sidecar."
        case .durabilitySyncFailed:
            return "The meeting result sidecar could not be synchronized to durable storage."
        }
    }
}

nonisolated struct MeetingResultSidecarStore {
    let sessionDirectory: URL

    /// The only file name this store will ever write or read for an attempt.
    static func fileName(for attemptID: UUID) -> String {
        "result-\(attemptID.uuidString).sidecar.json"
    }

    func sidecarURL(for attemptID: UUID) throws -> URL {
        try self.containedURL(fileName: Self.fileName(for: attemptID))
    }

    /// Validates, encodes, atomically writes, then reads back and re-verifies checksum, schema,
    /// attempt and backend before returning the reference a session may durably record.
    @discardableResult
    func write(_ sidecar: MeetingResultSidecar) throws -> MeetingResultSidecarReference {
        try sidecar.validated()

        let encoder = Self.makeEncoder()
        let data = try encoder.encode(sidecar)

        let manager = FileManager.default
        let root = self.sessionDirectory.standardizedFileURL.resolvingSymlinksInPath()
        if !manager.fileExists(atPath: root.path) {
            try manager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }
        // Tighten existing directories too. A temporary transcript may use the process umask for
        // a few instructions before its own chmod, so the parent must already exclude other users.
        try manager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: root.path
        )

        let url = try self.sidecarURL(for: sidecar.attemptID)
        if manager.fileExists(atPath: url.path) {
            return try self.referenceForExistingSidecar(
                sidecar,
                expectedData: data,
                at: url
            )
        }

        let temporaryURL = try self.containedURL(
            fileName: ".\(Self.fileName(for: sidecar.attemptID)).\(UUID().uuidString).tmp"
        )
        defer { try? manager.removeItem(at: temporaryURL) }
        // The unique temporary path prevents partial content from acquiring the stable name.
        // Its enclosing directory is already 0700; chmod it to 0600 before the same-directory
        // move publishes it. A failure before that move leaves no stable transcript file.
        try data.write(to: temporaryURL, options: .withoutOverwriting)
        try manager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: temporaryURL.path
        )
        try Self.synchronizeFile(at: temporaryURL)
        do {
            try manager.moveItem(at: temporaryURL, to: url)
        } catch {
            // A racing writer may have won after the existence check. Same bytes are an
            // idempotent join; different bytes may never replace an already-referenceable result.
            let currentURL = try self.sidecarURL(for: sidecar.attemptID)
            if manager.fileExists(atPath: currentURL.path) {
                return try self.referenceForExistingSidecar(
                    sidecar,
                    expectedData: data,
                    at: currentURL
                )
            }
            throw error
        }
        try Self.synchronizeDirectory(at: root)
        return try self.verifiedReference(for: sidecar, expectedData: data, at: url)
    }

    /// Reads and fully re-verifies a sidecar against its recorded reference and the expected
    /// attempt lineage. Anything that fails verification throws; there is no best-effort read.
    func read(
        expectedAttemptID: UUID,
        expectedBackendID: MeetingBackendID,
        reference: MeetingResultSidecarReference
    ) throws -> MeetingResultSidecar {
        guard reference.formatVersion == MeetingResultSidecarReferenceSchema.currentVersion else {
            throw MeetingResultSidecarStoreError.unsupportedReferenceFormatVersion(
                found: reference.formatVersion
            )
        }
        let expectedFileName = Self.fileName(for: expectedAttemptID)
        guard reference.fileName == expectedFileName else {
            throw MeetingResultSidecarStoreError.unexpectedFileName(
                expected: expectedFileName, actual: reference.fileName
            )
        }

        let url = try self.containedURL(fileName: reference.fileName)
        let data = try Data(contentsOf: url)
        guard data.count == reference.byteCount else {
            throw MeetingResultSidecarStoreError.byteCountMismatch(
                expected: reference.byteCount, actual: data.count
            )
        }
        guard Self.sha256Hex(data) == reference.sha256 else {
            throw MeetingResultSidecarStoreError.checksumMismatch
        }

        let sidecar = try Self.makeDecoder().decode(MeetingResultSidecar.self, from: data)
        try sidecar.validated()
        guard sidecar.attemptID == expectedAttemptID else {
            throw MeetingResultSidecarStoreError.attemptMismatch(
                expected: expectedAttemptID, actual: sidecar.attemptID
            )
        }
        guard sidecar.backendID == expectedBackendID else {
            throw MeetingResultSidecarStoreError.backendMismatch(
                expected: expectedBackendID, actual: sidecar.backendID
            )
        }
        return sidecar
    }

    /// Canonicalize symlinks, then require the result itself and its parent to stay at the exact
    /// canonical session-root path. This is intentionally stronger than the legacy chunk-store
    /// prefix check and rejects both internal and escaping pre-existing result-file symlinks.
    private func containedURL(fileName: String) throws -> URL {
        let root = self.sessionDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let unresolvedURL = root.appendingPathComponent(fileName, isDirectory: false).standardizedFileURL
        let resolvedURL = unresolvedURL.resolvingSymlinksInPath()
        guard !fileName.isEmpty,
              unresolvedURL.deletingLastPathComponent() == root,
              resolvedURL.deletingLastPathComponent() == root,
              resolvedURL == unresolvedURL
        else {
            throw MeetingResultSidecarStoreError.pathEscapesSessionDirectory
        }
        return unresolvedURL
    }

    private func referenceForExistingSidecar(
        _ sidecar: MeetingResultSidecar,
        expectedData: Data,
        at url: URL
    ) throws -> MeetingResultSidecarReference {
        let existingData = try Data(contentsOf: url)
        guard existingData == expectedData else {
            throw MeetingResultSidecarStoreError.conflictingExistingSidecar(
                attemptID: sidecar.attemptID
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
        try Self.synchronizeFile(at: url)
        try Self.synchronizeDirectory(
            at: self.sessionDirectory.standardizedFileURL.resolvingSymlinksInPath()
        )
        return try self.verifiedReference(for: sidecar, expectedData: expectedData, at: url)
    }

    private func verifiedReference(
        for sidecar: MeetingResultSidecar,
        expectedData: Data,
        at url: URL
    ) throws -> MeetingResultSidecarReference {
        let readBack = try Data(contentsOf: url)
        guard readBack == expectedData else {
            throw MeetingResultSidecarStoreError.checksumMismatch
        }
        let decoded = try Self.makeDecoder().decode(MeetingResultSidecar.self, from: readBack)
        try decoded.validated()
        guard decoded.attemptID == sidecar.attemptID else {
            throw MeetingResultSidecarStoreError.attemptMismatch(
                expected: sidecar.attemptID,
                actual: decoded.attemptID
            )
        }
        guard decoded.backendID == sidecar.backendID else {
            throw MeetingResultSidecarStoreError.backendMismatch(
                expected: sidecar.backendID,
                actual: decoded.backendID
            )
        }
        return MeetingResultSidecarReference(
            formatVersion: MeetingResultSidecarReferenceSchema.currentVersion,
            fileName: Self.fileName(for: sidecar.attemptID),
            sha256: Self.sha256Hex(readBack),
            byteCount: readBack.count
        )
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Quarantined evidence must remain durably ledgerable even when the defect itself is NaN or
    /// infinity. Stable string tokens preserve that raw value without turning it into a valid
    /// timestamp; sidecar validation still requires the rejected-invalid-timing disposition.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "+Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "+Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return decoder
    }

    private static func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        do {
            try handle.synchronize()
        } catch {
            throw MeetingResultSidecarStoreError.durabilitySyncFailed
        }
    }

    private static func synchronizeDirectory(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw MeetingResultSidecarStoreError.durabilitySyncFailed
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw MeetingResultSidecarStoreError.durabilitySyncFailed
        }
    }
}
