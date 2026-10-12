import CryptoKit
import Foundation

/// Canonical iPhone/publisher archive checks, with bounded Mac staging and cancellation checks.
/// Mac publication remains in ParakeetArchiveDownloader so a validated update uses an atomic swap.
nonisolated enum ParakeetArchiveInstaller {
    private static let maximumManifestBytes: Int64 = 1_048_576
    private static let maximumFiles = 50_000
    private static let maximumPayloadBytes: Int64 = 1_073_741_824

    private struct Manifest: Decodable {
        struct File: Decodable {
            let path: String
            let size: Int64
            let sha256: String
        }

        let folderName: String
        let totalSize: Int64
        let files: [File]
    }

    enum InstallError: LocalizedError, Equatable {
        case invalidStaging
        case missingFolder
        case manifestMismatch
        case fileMismatch(String)
        case unlistedFile(String)

        var errorDescription: String? {
            switch self {
            case .invalidStaging: "The model staging folder is not safe to use."
            case .missingFolder: "The downloaded model is incomplete."
            case .manifestMismatch: "The downloaded model is not the expected release."
            case let .fileMismatch(path): "The downloaded model failed verification (\(path))."
            case let .unlistedFile(path): "The downloaded model holds an unexpected file (\(path))."
            }
        }
    }

    /// Unpacks into `staging` and returns the model folder. With a manifest hash, every file is proven against it.
    static func unpack(archive: URL, folderName: String, staging: URL, manifestSHA256: String?) throws -> URL {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        guard staging.isFileURL, self.isComponent(folderName),
              (try? fileManager.attributesOfItem(atPath: staging.path)) == nil,
              try fileManager.attributesOfItem(atPath: staging.deletingLastPathComponent().path)[.type]
              as? FileAttributeType == .typeDirectory
        else { throw InstallError.invalidStaging }
        // Only a new, private staging folder may be unpacked. Never remove a caller's existing cache.
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try TarExtractor.extract(archive: archive, to: staging)

        let extracted = staging.appendingPathComponent(folderName, isDirectory: true)
        guard (try? fileManager.attributesOfItem(atPath: extracted.path)[.type] as? FileAttributeType) == .typeDirectory,
              try fileManager.contentsOfDirectory(atPath: staging.path) == [folderName]
        else { throw InstallError.missingFolder }
        if let manifestSHA256 {
            try self.verify(folder: extracted, folderName: folderName, manifestSHA256: manifestSHA256)
        }
        return extracted
    }

    static func verify(folder: URL, folderName: String, manifestSHA256: String) throws {
        try Task.checkCancellation()
        let manager = FileManager.default
        guard self.isComponent(folderName), self.isSHA256(manifestSHA256),
              (try? manager.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType) == .typeDirectory
        else { throw InstallError.manifestMismatch }
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let attributes = try? manager.attributesOfItem(atPath: manifestURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0, size.int64Value <= maximumManifestBytes,
              try sha256(of: manifestURL) == manifestSHA256,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)),
              manifest.folderName == folderName,
              manifest.files.count <= maximumFiles,
              manifest.totalSize >= 0, manifest.totalSize <= maximumPayloadBytes
        else { throw InstallError.manifestMismatch }

        var total: Int64 = 0
        for file in manifest.files {
            try Task.checkCancellation()
            guard file.size >= 0, file.size <= self.maximumPayloadBytes - total else { throw InstallError.manifestMismatch }
            total += file.size
        }
        guard total == manifest.totalSize else { throw InstallError.manifestMismatch }

        // Check the complete tree before any payload hash; standalone verification must not follow cache links.
        // Relative filenames avoid Foundation's /var versus /private/var URL aliases.
        // Never resolve child links: inspect their actual type before reading any payload.
        var enumerationFailed = false
        guard let enumerator = manager.enumerator(
            at: folder,
            includingPropertiesForKeys: nil,
            options: .producesRelativePathURLs,
            errorHandler: { _, _ in enumerationFailed = true; return false }
        ) else { throw InstallError.manifestMismatch }
        var regularFiles: [String] = []
        var count = 0
        for case let url as URL in enumerator {
            let relativePath = url.relativePath
            try Task.checkCancellation()
            count += 1
            guard count <= self.maximumFiles else { throw InstallError.manifestMismatch }
            let type = try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeDirectory else { throw InstallError.fileMismatch(url.lastPathComponent) }
            if type == .typeRegular { regularFiles.append(relativePath) }
        }

        guard !enumerationFailed else { throw InstallError.manifestMismatch }

        var listed = Set<String>()
        for file in manifest.files {
            try Task.checkCancellation()
            let components = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty, components.allSatisfy({ self.isComponent(String($0)) }),
                  self.isSHA256(file.sha256), listed.insert(file.path).inserted
            else { throw InstallError.fileMismatch(file.path) }
            let url = folder.appendingPathComponent(file.path, isDirectory: false)
            let attributes = try? manager.attributesOfItem(atPath: url.path)
            guard attributes?[.type] as? FileAttributeType == .typeRegular,
                  (attributes?[.size] as? NSNumber)?.int64Value == file.size,
                  try self.sha256(of: url) == file.sha256
            else { throw InstallError.fileMismatch(file.path) }
        }
        for path in regularFiles {
            guard path == "manifest.json" || listed.contains(path) else { throw InstallError.unlistedFile(path) }
        }
    }

    private static func isComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func previousURL(for target: URL) -> URL {
        target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent)-previous", isDirectory: true)
    }

    /// Puts `extracted` at `target`. With `keepPrevious` the model already there is parked, not deleted,
    /// until the new one has proven itself.
    static func swap(extracted: URL, target: URL, keepPrevious: Bool) throws {
        let fileManager = FileManager.default
        let previous = self.previousURL(for: target)
        let hadModel = fileManager.fileExists(atPath: target.path)
        if hadModel {
            if keepPrevious {
                if fileManager.fileExists(atPath: previous.path) {
                    try fileManager.removeItem(at: previous)
                }
                try fileManager.moveItem(at: target, to: previous)
            } else {
                try fileManager.removeItem(at: target)
            }
        }
        do {
            try fileManager.moveItem(at: extracted, to: target)
        } catch {
            if hadModel, keepPrevious {
                try? fileManager.moveItem(at: previous, to: target)
            }
            throw error
        }
    }

    static func hasPrevious(for target: URL) -> Bool {
        FileManager.default.fileExists(atPath: self.previousURL(for: target).path)
    }

    /// Throws away the model at `target` and puts the parked one back.
    static func restorePrevious(for target: URL) throws {
        let fileManager = FileManager.default
        let previous = self.previousURL(for: target)
        guard fileManager.fileExists(atPath: previous.path) else { return }
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.moveItem(at: previous, to: target)
    }

    static func discardPrevious(for target: URL) {
        try? FileManager.default.removeItem(at: self.previousURL(for: target))
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum TarExtractor {
    static func extract(archive: URL, to destination: URL) throws {
        let manager = FileManager.default
        guard (try? manager.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType) == .typeDirectory,
              try manager.contentsOfDirectory(atPath: destination.path).isEmpty,
              let archiveAttributes = try? manager.attributesOfItem(atPath: archive.path),
              archiveAttributes[.type] as? FileAttributeType == .typeRegular,
              let archiveBytes = archiveAttributes[.size] as? NSNumber,
              archiveBytes.int64Value >= 512, archiveBytes.int64Value <= 1_073_741_824
        else { throw Error.truncatedArchive }
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }

        var entryCount = 0
        while true {
            try Task.checkCancellation()
            guard let headerData = try input.read(upToCount: 512), headerData.count == 512 else {
                throw Error.truncatedArchive
            }
            let header = [UInt8](headerData)
            if header.allSatisfy({ $0 == 0 }) {
                return
            }

            entryCount += 1
            guard entryCount <= 50_000,
                  try self.octal(in: header, range: 148..<156) == header.enumerated().reduce(Int64(0), {
                      $0 + Int64((148..<156).contains($1.offset) ? 32 : $1.element)
                  })
            else { throw Error.unsupportedEntry }
            let name = try string(in: header, range: 0..<100)
            let prefix = try string(in: header, range: 345..<500)
            let relativePath = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let output = try safeOutputURL(relativePath: relativePath, destination: destination)
            let size = try octal(in: header, range: 124..<136)
            let type = header[156]
            let offset = try input.offset()
            let padding = (512 - (size % 512)) % 512
            guard size >= 0, offset <= archiveBytes.uint64Value,
                  UInt64(size) <= archiveBytes.uint64Value - offset,
                  UInt64(padding) <= archiveBytes.uint64Value - offset - UInt64(size)
            else { throw Error.truncatedArchive }

            switch type {
            case 0, 48:
                guard (try? manager.attributesOfItem(atPath: output.path)) == nil else { throw Error.unsupportedEntry }
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw Error.cannotCreateFile
                }
                let file = try FileHandle(forWritingTo: output)
                defer { try? file.close() }
                var remaining = size
                while remaining > 0 {
                    try Task.checkCancellation()
                    let count = Int(min(remaining, 1_048_576))
                    guard let data = try input.read(upToCount: count), data.count == count else {
                        throw Error.truncatedArchive
                    }
                    try file.write(contentsOf: data)
                    remaining -= Int64(count)
                }
            case 53:
                guard size == 0 else { throw Error.unsupportedEntry }
                try FileManager.default.createDirectory(
                    at: output,
                    withIntermediateDirectories: true
                )
            case 103, 120:
                // BSD tar emits global/per-file PAX metadata records. Their
                // payload is metadata only; paths remain available in the
                // following ustar header for these model archives.
                let offset = try input.offset()
                try input.seek(toOffset: offset + UInt64(size))
            default:
                throw Error.unsupportedEntry
            }

            try input.seek(toOffset: offset + UInt64(size + padding))
        }
    }

    private static func safeOutputURL(relativePath: String, destination: URL) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            throw Error.unsafePath
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") })
        else {
            throw Error.unsafePath
        }
        return components.reduce(destination) { output, component in
            output.appendingPathComponent(String(component), isDirectory: false)
        }
    }

    private static func string(in bytes: [UInt8], range: Range<Int>) throws -> String {
        guard let value = String(bytes: bytes[range].prefix { $0 != 0 }, encoding: .utf8) else { throw Error.unsafePath }
        return value
    }

    private static func octal(in bytes: [UInt8], range: Range<Int>) throws -> Int64 {
        let raw = try string(in: bytes, range: range).trimmingCharacters(in: .whitespaces)
        guard raw.isEmpty || raw.allSatisfy({ ("0"..."7").contains(String($0)) }),
              let value = Int64(raw.isEmpty ? "0" : raw, radix: 8)
        else {
            throw Error.invalidSize
        }
        return value
    }

    private enum Error: Swift.Error {
        case cannotCreateFile
        case invalidSize
        case truncatedArchive
        case unsafePath
        case unsupportedEntry
    }
}
