import CryptoKit
import Darwin
import Foundation

/// Installs only the descriptor's hash-pinned archive, without changing model selection.
nonisolated enum ParakeetArchiveDownloader {
    typealias Transport = @Sendable (URL, @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, URLResponse)

    enum DownloadError: LocalizedError {
        case invalidDescriptor, invalidResponse, checksumMismatch, invalidArchive, incompleteModel, targetExists
        case cleanupFailed(URL)

        var errorDescription: String? {
            switch self {
            case .invalidDescriptor: return "This voice model has no valid pinned download."
            case .invalidResponse: return "The model server did not return the expected archive. Please try again."
            case .checksumMismatch: return "The downloaded voice model failed verification. Please try again."
            case .invalidArchive: return "The voice model archive contains invalid or unsafe files."
            case .incompleteModel: return "The voice model archive is incomplete."
            case .targetExists: return "The voice model cache changed during download. Please try again."
            case let .cleanupFailed(url): return "Voice model temporary files could not be removed: \(url.path)"
            }
        }
    }

    static func ensurePresent(
        descriptor: ParakeetSpeechModelCatalog.Descriptor,
        in modelsDirectory: URL,
        progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void = { _ in },
        transport: Transport? = nil
    ) async throws -> URL {
        let task = Task.detached(priority: .utility) {
            try await self.install(descriptor: descriptor, modelsDirectory: modelsDirectory, progressHandler: progressHandler, transport: transport)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func isCleanupFailure(_ error: Error) -> Bool {
        guard let failure = error as? DownloadError else { return false }
        if case .cleanupFailed = failure { return true }
        return false
    }

    private static func download(url: URL, maximumBytes: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        return try await ProgressiveFileDownloader.download(from: url, configuration: configuration, maximumBytes: maximumBytes, onProgress: progress)
    }

    private static func install(
        descriptor: ParakeetSpeechModelCatalog.Descriptor,
        modelsDirectory: URL,
        progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void,
        transport: Transport?
    ) async throws -> URL {
        try Task.checkCancellation()
        guard self.isComponent(descriptor.folderName), self.isComponent(descriptor.vocabularyFile),
              !descriptor.requiredModelNames.isEmpty,
              descriptor.requiredModelNames.allSatisfy(self.isComponent),
              Set(descriptor.requiredModelNames).count == descriptor.requiredModelNames.count,
              modelsDirectory.isFileURL
        else { throw DownloadError.invalidDescriptor }
        let manager = FileManager.default
        let target = descriptor.cacheDirectory(in: modelsDirectory)
        if self.pathExists(modelsDirectory) { try self.requireDirectory(modelsDirectory) }
        if self.artifactsAreComplete(at: target, descriptor: descriptor) {
            progressHandler(.loading)
            return target
        }
        guard let archiveURL = descriptor.archiveURL, archiveURL.scheme == "https", archiveURL.host != nil,
              let checksum = descriptor.archiveSHA256,
              checksum.count == 64, checksum.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              descriptor.expectedDownloadBytes > 0
        else { throw DownloadError.invalidDescriptor }
        try manager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try self.requireDirectory(modelsDirectory)
        guard !self.pathExists(target) else { throw DownloadError.targetExists }
        let stage = modelsDirectory.appendingPathComponent(".\(descriptor.folderName)-\(UUID().uuidString).staging", isDirectory: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var retainedDownload: URL?
        do {
            progressHandler(.preparingDownload)
            let transfer: Transport = transport ?? { url, progress in
                try await self.download(url: url, maximumBytes: descriptor.expectedDownloadBytes, progress: progress)
            }
            let (downloaded, response) = try await transfer(archiveURL) { bytes, _ in
                let bounded = max(0, min(bytes, descriptor.expectedDownloadBytes))
                progressHandler(.downloading(Double(bounded) / Double(descriptor.expectedDownloadBytes)))
            }
            retainedDownload = downloaded
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.scheme == "https",
                  try self.regularFileSize(downloaded) == descriptor.expectedDownloadBytes
            else { throw DownloadError.invalidResponse }
            let archive = stage.appendingPathComponent("archive.tar")
            try manager.moveItem(at: downloaded, to: archive)
            retainedDownload = nil
            guard try self.sha256(archive) == checksum else { throw DownloadError.checksumMismatch }
            progressHandler(.optimizing)
            let extraction = stage.appendingPathComponent("extracted", isDirectory: true)
            try manager.createDirectory(at: extraction, withIntermediateDirectories: false)
            try self.extract(archive: archive, into: extraction, folderName: descriptor.folderName, archiveBytes: descriptor.expectedDownloadBytes)
            let extracted = descriptor.cacheDirectory(in: extraction)
            guard self.artifactsAreComplete(at: extracted, descriptor: descriptor) else { throw DownloadError.incompleteModel }
            try Task.checkCancellation()
            // Both directories are on the cache filesystem; exclusive rename publishes
            // the complete tree at once and cannot overwrite a competing target.
            let result = extracted.withUnsafeFileSystemRepresentation { source in
                target.withUnsafeFileSystemRepresentation { destination in
                    renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, UInt32(RENAME_EXCL))
                }
            }
            guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        } catch {
            let originalError = error
            var cleanupFailure: DownloadError?
            if let retainedDownload {
                do { try manager.removeItem(at: retainedDownload) } catch { cleanupFailure = .cleanupFailed(retainedDownload) }
            }
            do { try manager.removeItem(at: stage) } catch { cleanupFailure = .cleanupFailed(stage) }
            if let cleanupFailure { throw cleanupFailure }
            throw originalError
        }
        do { try manager.removeItem(at: stage) } catch { throw DownloadError.cleanupFailed(stage) }
        progressHandler(.loading)
        return target
    }

    /// Mirrors compiled-artifact readiness while rejecting links anywhere in the tree.
    static func artifactsAreComplete(at directory: URL, descriptor: ParakeetSpeechModelCatalog.Descriptor) -> Bool {
        do {
            try Task.checkCancellation()
            try self.requireDirectory(directory)
            let manager = FileManager.default
            var enumerationFailed = false
            guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }) else { return false }
            var count = 0
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                count += 1
                guard count <= 50_000 else { return false }
                let type = try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
                guard type == .typeDirectory || type == .typeRegular else { return false }
            }
            guard !enumerationFailed else { return false }
            guard try self.regularFileSize(directory.appendingPathComponent(descriptor.vocabularyFile)) > 0 else { return false }
            for name in descriptor.requiredModelNames {
                let model = directory.appendingPathComponent(name, isDirectory: true)
                try self.requireDirectory(model)
                for file in ["coremldata.bin", "metadata.json", "weights/weight.bin"] {
                    guard try self.regularFileSize(model.appendingPathComponent(file)) > 0 else { return false }
                }
            }
            return true
        } catch { return false }
    }

    private static func isComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private static func pathExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func requireDirectory(_ url: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw DownloadError.invalidArchive
        }
    }

    private static func regularFileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, let size = attributes[.size] as? NSNumber else {
            throw DownloadError.invalidArchive
        }
        return size.int64Value
    }

    private static func sha256(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func extract(archive: URL, into destination: URL, folderName: String, archiveBytes: Int64) throws {
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        var entryCount = 0
        while true {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: 512), data.count == 512 else { throw DownloadError.invalidArchive }
            let header = [UInt8](data)
            if header.allSatisfy({ $0 == 0 }) { return }
            entryCount += 1
            guard entryCount <= 50_000,
                  try self.octal(header, range: 148..<156) == header.enumerated().reduce(Int64(0), { $0 + Int64((148..<156).contains($1.offset) ? 32 : $1.element) })
            else { throw DownloadError.invalidArchive }
            let size = try self.octal(header, range: 124..<136)
            let offset = try input.offset()
            let padding = (512 - size % 512) % 512
            guard size >= 0, offset <= UInt64(archiveBytes), UInt64(size + padding) <= UInt64(archiveBytes) - offset else {
                throw DownloadError.invalidArchive
            }
            let type = header[156]
            if type == 103 || type == 120 {
                // Metadata is never interpreted as paths or links. Published archives
                // carry their actual filenames in their following ustar header.
                try input.seek(toOffset: offset + UInt64(size + padding))
                continue
            }
            let name = try self.string(header, range: 0..<100)
            let prefix = try self.string(header, range: 345..<500)
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            guard !path.hasPrefix("/") else { throw DownloadError.invalidArchive }
            var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if components.first == "." { components.removeFirst() }
            guard components.first == folderName, components.allSatisfy(self.isComponent) else { throw DownloadError.invalidArchive }
            let output = components.reduce(destination) { $0.appendingPathComponent($1) }
            switch type {
            case 0, 48:
                guard components.count > 1, !self.pathExists(output) else { throw DownloadError.invalidArchive }
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw DownloadError.invalidArchive }
                let file = try FileHandle(forWritingTo: output)
                defer { try? file.close() }
                var remaining = size
                while remaining > 0 {
                    try Task.checkCancellation()
                    let count = Int(min(remaining, 1_048_576))
                    guard let body = try input.read(upToCount: count), body.count == count else { throw DownloadError.invalidArchive }
                    try file.write(contentsOf: body)
                    remaining -= Int64(body.count)
                }
            case 53:
                guard size == 0 else { throw DownloadError.invalidArchive }
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try self.requireDirectory(output)
            default: throw DownloadError.invalidArchive
            }
            try input.seek(toOffset: offset + UInt64(size + padding))
        }
    }

    private static func string(_ bytes: [UInt8], range: Range<Int>) throws -> String {
        guard let value = String(bytes: bytes[range].prefix { $0 != 0 }, encoding: .utf8) else { throw DownloadError.invalidArchive }
        return value
    }

    private static func octal(_ bytes: [UInt8], range: Range<Int>) throws -> Int64 {
        let text = try self.string(bytes, range: range).trimmingCharacters(in: .whitespaces)
        guard text.isEmpty || text.utf8.allSatisfy({ (48...55).contains($0) }), let value = Int64(text.isEmpty ? "0" : text, radix: 8) else {
            throw DownloadError.invalidArchive
        }
        return value
    }
}
