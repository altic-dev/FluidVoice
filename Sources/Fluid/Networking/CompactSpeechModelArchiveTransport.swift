import Darwin
import Foundation

/// One resumable archive per compact model. All IO and the advisory claim run off main.
nonisolated enum CompactSpeechModelArchiveTransport {
    typealias Progress = @Sendable (Int64, Int64) -> Void
    typealias ChunkTransport = @Sendable (URLRequest, Int64, @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse)
    static let rangeBytes: Int64 = 16 * 1024 * 1024

    enum Failure: LocalizedError, Equatable {
        case invalidDescriptor, invalidRange, alreadyDownloading
        case unsafePartial(URL)

        var errorDescription: String? {
            switch self {
            case .invalidDescriptor: "This compact voice model has no valid pinned download."
            case let .unsafePartial(url): "Voice model download files are unsafe at \(url.path). Remove that file or folder and try again."
            case .invalidRange: "The model server returned an invalid download range. Please try again."
            case .alreadyDownloading: "This voice model is already downloading in another app process. Please try again when it finishes."
            }
        }
    }

    static func download(
        descriptor: ParakeetSpeechModelCatalog.Descriptor,
        in modelsDirectory: URL,
        progress: @escaping Progress,
        transport: ChunkTransport? = nil,
        chunkBytes: Int64 = rangeBytes
    ) async throws -> (URL, URLResponse) {
        let task = Task.detached(priority: .utility) {
            try await self.assemble(descriptor: descriptor, in: modelsDirectory, progress: progress, transport: transport, chunkBytes: chunkBytes)
        }
        return try await withTaskCancellationHandler {
            do { return try await task.value } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                throw error
            }
        } onCancel: { task.cancel() }
    }

    private static func assemble(
        descriptor: ParakeetSpeechModelCatalog.Descriptor,
        in modelsDirectory: URL,
        progress: @escaping Progress,
        transport: ChunkTransport?,
        chunkBytes: Int64
    ) async throws -> (URL, URLResponse) {
        try Task.checkCancellation()
        guard descriptor.variant == .mini || descriptor.variant == .pico,
              descriptor.folderName == ParakeetSpeechModelCatalog.descriptor(for: descriptor.variant).folderName,
              modelsDirectory.isFileURL,
              let url = descriptor.archiveURL, url.scheme == "https", url.host == SpeechModelFeed.host,
              url.port == nil, url.user == nil, url.password == nil,
              let hash = descriptor.archiveSHA256, self.validHash(hash),
              descriptor.expectedDownloadBytes > 0, descriptor.expectedDownloadBytes <= 1_000_000_000,
              chunkBytes > 0, chunkBytes <= self.rangeBytes
        else { throw Failure.invalidDescriptor }
        try self.requireDirectory(modelsDirectory)
        let retainedRoot = modelsDirectory.appendingPathComponent(".compact-downloads", isDirectory: true)
        try self.createOwnedDirectory(retainedRoot)
        let directory = retainedRoot.appendingPathComponent(descriptor.folderName, isDirectory: true)
        try self.createOwnedDirectory(directory)
        let claim = try Claim(directory.appendingPathComponent("claim.lock"))
        defer { claim.close() }
        let marker = directory.appendingPathComponent("release.sha256")
        let partial = directory.appendingPathComponent("archive.partial")
        var completed = try self.preparePartial(partial, marker: marker, hash: hash, total: descriptor.expectedDownloadBytes, chunkBytes: chunkBytes)
        let transfer: ChunkTransport = transport ?? { request, maximumBytes, progress in
            try await ChunkLoader.download(request: request, maximumBytes: maximumBytes, progress: progress)
        }
        progress(completed, descriptor.expectedDownloadBytes)
        while completed < descriptor.expectedDownloadBytes {
            try Task.checkCancellation()
            let start = completed
            let end = min(start + chunkBytes, descriptor.expectedDownloadBytes) - 1
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            var downloaded: URL?
            do {
                let (chunk, response) = try await transfer(request, end - start + 1) { bytes in
                    progress(start + max(0, min(bytes, end - start + 1)), descriptor.expectedDownloadBytes)
                }
                downloaded = chunk
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse,
                      response.statusCode == 206, response.url == url,
                      response.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(end)/\(descriptor.expectedDownloadBytes)",
                      response.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true,
                      try self.fileSize(chunk) == end - start + 1
                else { throw Failure.invalidRange }
                try self.append(chunk: chunk, to: partial, offset: start)
                try Task.checkCancellation()
                completed = end + 1
                try FileManager.default.removeItem(at: chunk)
                downloaded = nil
                progress(completed, descriptor.expectedDownloadBytes)
            } catch {
                // Join transport cancellation before touching its file. Only complete ranges survive.
                if let downloaded { try? FileManager.default.removeItem(at: downloaded) }
                try self.truncate(partial, to: completed)
                throw error
            }
        }
        try Task.checkCancellation()
        // Transfer unique ownership while still holding the claim, so another process
        // cannot resume or replace a completed file the installer is about to consume.
        let ready = FileManager.default.temporaryDirectory.appendingPathComponent("FluidVoiceCompactArchive-\(UUID().uuidString).tar")
        try FileManager.default.moveItem(at: partial, to: ready)
        // This 200 represents an assembled file, not an HTTP range response. The outer
        // installer still verifies its whole size/SHA before any extraction/publication.
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(descriptor.expectedDownloadBytes)]) else {
            try? FileManager.default.removeItem(at: ready)
            throw Failure.invalidRange
        }
        return (ready, response)
    }

    private static func preparePartial(_ partial: URL, marker: URL, hash: String, total: Int64, chunkBytes: Int64) throws -> Int64 {
        let manager = FileManager.default
        let markerSize = try self.optionalFileSize(marker)
        let partialSize = try self.optionalFileSize(partial)
        var sameRelease = false
        if markerSize == 64 {
            let file = try self.openRegular(marker, flags: O_RDONLY)
            defer { try? file.close() }
            let bytes = try file.read(upToCount: 65) ?? Data()
            if let oldHash = String(data: bytes, encoding: .utf8), self.validHash(oldHash) { sameRelease = oldHash == hash }
        }
        if !sameRelease {
            if partialSize != nil { try manager.removeItem(at: partial) }
            if markerSize != nil { try manager.removeItem(at: marker) }
            try Data(hash.utf8).write(to: marker, options: .withoutOverwriting)
        }
        var size = sameRelease ? (partialSize ?? 0) : 0
        if size > total {
            // A crash/corrupted regular partial must have a bounded Retry recovery.
            // The claim and no-link checks restrict repair to this model's owned file.
            try self.truncate(partial, to: 0)
            size = 0
        }
        if try self.optionalFileSize(partial) == nil {
            guard manager.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Failure.unsafePartial(partial) }
        }
        let boundary = size == total ? size : (size / chunkBytes) * chunkBytes
        if boundary != size { try self.truncate(partial, to: boundary) }
        return boundary
    }

    private static func append(chunk: URL, to partial: URL, offset: Int64) throws {
        guard try self.fileSize(partial) == offset else { throw Failure.unsafePartial(partial) }
        let input = try self.openRegular(chunk, flags: O_RDONLY)
        defer { try? input.close() }
        let output = try self.openRegular(partial, flags: O_WRONLY)
        defer { try? output.close() }
        try output.seek(toOffset: UInt64(offset))
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: bytes)
        }
        try output.synchronize()
    }

    private static func truncate(_ partial: URL, to offset: Int64) throws {
        let file = try self.openRegular(partial, flags: O_WRONLY)
        defer { try? file.close() }
        try file.truncate(atOffset: UInt64(offset))
        try file.synchronize()
    }

    private static func openRegular(_ url: URL, flags: Int32) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, flags | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unsafePartial(url) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG, attributes.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw Failure.unsafePartial(url)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        guard let size = try self.optionalFileSize(url) else { throw Failure.unsafePartial(url) }
        return size
    }

    private static func optionalFileSize(_ url: URL) throws -> Int64? {
        var attributes = stat()
        if lstat(url.path, &attributes) != 0 {
            if errno == ENOENT { return nil }
            throw Failure.unsafePartial(url)
        }
        guard attributes.st_mode & S_IFMT == S_IFREG, attributes.st_nlink == 1, attributes.st_size >= 0 else { throw Failure.unsafePartial(url) }
        return attributes.st_size
    }

    private static func requireDirectory(_ url: URL) throws {
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafePartial(url) }
    }

    private static func createOwnedDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0, errno != EEXIST { throw Failure.unsafePartial(url) }
        try self.requireDirectory(url)
    }

    private static func validHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private final class Claim {
        private let descriptor: Int32

        init(_ url: URL) throws {
            let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw Failure.unsafePartial(url) }
            var attributes = stat()
            guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG, attributes.st_nlink == 1 else {
                Darwin.close(descriptor)
                throw Failure.unsafePartial(url)
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(descriptor)
                throw Failure.alreadyDownloading
            }
            self.descriptor = descriptor
        }

        func close() { flock(self.descriptor, LOCK_UN); Darwin.close(self.descriptor) }
    }

    /// Completion joins URLSession's didComplete callback; cancellation never races deletion.
    private final class ChunkLoader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let maximumBytes: Int64
        private let progress: @Sendable (Int64) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
        private var task: URLSessionDownloadTask?
        private var session: URLSession?
        private var result: Result<(URL, URLResponse), Error>?
        private var canceled = false
        private var exceededLimit = false

        init(maximumBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) {
            self.maximumBytes = maximumBytes
            self.progress = progress
        }

        static func download(request: URLRequest, maximumBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse) {
            let loader = ChunkLoader(maximumBytes: maximumBytes, progress: progress)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { loader.start(request, continuation: $0) }
            } onCancel: { loader.cancel() }
        }

        private func start(_ request: URLRequest, continuation: CheckedContinuation<(URL, URLResponse), Error>) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 600
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let task = session.downloadTask(with: request)
            let canceled = self.lock.withLock {
                self.continuation = continuation
                self.session = session
                self.task = task
                return self.canceled
            }
            task.resume()
            if canceled { task.cancel() }
        }

        private func cancel() {
            let task = self.lock.withLock { self.canceled = true; return self.task }
            task?.cancel()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesWritten <= self.maximumBytes, totalBytesExpectedToWrite <= self.maximumBytes else {
                self.lock.withLock { self.exceededLimit = true }
                downloadTask.cancel()
                return
            }
            self.progress(totalBytesWritten)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let result: Result<(URL, URLResponse), Error>
            do {
                guard let response = downloadTask.response, try CompactSpeechModelArchiveTransport.fileSize(location) <= self.maximumBytes else { throw Failure.invalidRange }
                result = try .success((ProgressiveFileDownloader.retainDownloadedFile(at: location), response))
            } catch { result = .failure(error) }
            self.lock.withLock { self.result = result }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (continuation, result, exceededLimit) = self.lock.withLock {
                defer { self.continuation = nil; self.result = nil; self.task = nil; self.session = nil }
                return (self.continuation, self.result, self.exceededLimit)
            }
            session.finishTasksAndInvalidate()
            if let error {
                if case let .success((url, _)) = result { try? FileManager.default.removeItem(at: url) }
                continuation?.resume(throwing: exceededLimit ? URLError(.dataLengthExceedsMaximum) : error)
            } else {
                continuation?.resume(with: result ?? .failure(Failure.invalidRange))
            }
        }
    }
}
