import CoreML
import Foundation
#if arch(arm64)
import FluidAudio
#endif

/// A robust downloader for Hugging Face models with progress tracking and error handling.
/// Supports downloading entire model repositories with proper file structure preservation.
/// Can be configured to use different model repositories for flexibility.
final class HuggingFaceModelDownloader {
    struct HFEntry: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }

    struct ModelItem {
        let path: String
        let isDirectory: Bool
    }

    // Configure your optimized repository here
    // These can be customized for different model repositories
    private let owner: String
    private let repo: String
    private let revision: String
    private let requiredItemsList: [ModelItem]

    private var baseApiURL: URL
    private var baseResolveURL: URL

    /// Initialize with default model repository settings
    init() {
        self.owner = "FluidInference"
        self.repo = "parakeet-tdt-0.6b-v3-coreml"
        self.revision = "main"
        self.requiredItemsList = [
            ModelItem(path: "MelEncoder.mlmodelc", isDirectory: true),
            ModelItem(path: "Decoder.mlmodelc", isDirectory: true),
            ModelItem(path: "JointDecision.mlmodelc", isDirectory: true),
            ModelItem(path: "parakeet_v3_vocab.json", isDirectory: false),
        ]
        guard var apiBase = URL(string: "https://huggingface.co/api/models/") else {
            preconditionFailure("Invalid base Hugging Face API URL")
        }
        apiBase.appendPathComponent(self.owner)
        apiBase.appendPathComponent(self.repo)
        apiBase.appendPathComponent("tree")
        apiBase.appendPathComponent(self.revision)
        self.baseApiURL = apiBase

        guard var resolveBase = URL(string: "https://huggingface.co/") else {
            preconditionFailure("Invalid base Hugging Face resolve URL")
        }
        resolveBase.appendPathComponent(self.owner)
        resolveBase.appendPathComponent(self.repo)
        resolveBase.appendPathComponent("resolve")
        resolveBase.appendPathComponent(self.revision)
        self.baseResolveURL = resolveBase
    }

    /// Initialize with custom model repository settings
    /// - Parameters:
    ///   - owner: Hugging Face username or organization
    ///   - repo: Repository name containing the models
    ///   - revision: Branch or commit hash (default: "main")
    init(owner: String, repo: String, revision: String = "main", requiredItems: [ModelItem] = []) {
        self.owner = owner
        self.repo = repo
        self.revision = revision
        self.requiredItemsList = requiredItems.isEmpty
            ? [
                ModelItem(path: "MelEncoder.mlmodelc", isDirectory: true),
                ModelItem(path: "Decoder.mlmodelc", isDirectory: true),
                ModelItem(path: "JointDecision.mlmodelc", isDirectory: true),
                ModelItem(path: "parakeet_v3_vocab.json", isDirectory: false),
            ]
            : requiredItems
        guard var apiBase = URL(string: "https://huggingface.co/api/models/") else {
            preconditionFailure("Invalid base Hugging Face API URL")
        }
        apiBase.appendPathComponent(owner)
        apiBase.appendPathComponent(repo)
        apiBase.appendPathComponent("tree")
        apiBase.appendPathComponent(revision)
        self.baseApiURL = apiBase

        guard var resolveBase = URL(string: "https://huggingface.co/") else {
            preconditionFailure("Invalid base Hugging Face resolve URL")
        }
        resolveBase.appendPathComponent(owner)
        resolveBase.appendPathComponent(repo)
        resolveBase.appendPathComponent("resolve")
        resolveBase.appendPathComponent(revision)
        self.baseResolveURL = resolveBase
    }

    func ensureModelsPresent(at targetRoot: URL, onProgress: ((Double, String) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        onProgress?(0.0, "")

        // Build list of files to download (flatten directories via HF API tree)
        var pendingFiles: [String] = []
        var listedSizeByPath: [String: Int64] = [:]
        for item in self.requiredItems() {
            try Task.checkCancellation()
            if item.isDirectory {
                let files = try await listFilesRecursively(relativePath: item.path)
                for entry in files {
                    let rel = entry.path
                    if let size = entry.size, size >= 0 {
                        listedSizeByPath[rel] = size
                    }
                    let dest = targetRoot.appendingPathComponent(rel)
                    if self.needsDownload(relativePath: rel, at: dest, expectedBytes: entry.size) {
                        pendingFiles.append(rel)
                    }
                }
            } else {
                let dest = targetRoot.appendingPathComponent(item.path)
                let expectedBytes = try await self.headExpectedLength(relativePath: item.path)
                if expectedBytes > 0 {
                    listedSizeByPath[item.path] = expectedBytes
                }
                if self.needsDownload(
                    relativePath: item.path,
                    at: dest,
                    expectedBytes: expectedBytes > 0 ? expectedBytes : nil
                ) {
                    pendingFiles.append(item.path)
                }
            }
        }

        // If nothing to download, say so clearly
        if pendingFiles.isEmpty {
            guard Self.artifactsAreComplete(root: targetRoot, items: self.requiredItems()) else {
                throw NSError(
                    domain: "HF",
                    code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "Cached model artifacts are incomplete. Please try again."]
                )
            }
            DebugLogger.shared.info("[ModelDL] All required model files are already present. Nothing to download.", source: "ModelDownloader")
            try Task.checkCancellation()
            onProgress?(1.0, "")
            return
        }

        // Compute total bytes (best-effort) for determinate progress
        var sizeByPath: [String: Int64] = [:]
        var totalBytes: Int64 = 0
        for rel in pendingFiles {
            try Task.checkCancellation()
            let expected: Int64
            if let listedSize = listedSizeByPath[rel] {
                expected = listedSize
            } else {
                expected = try await self.headExpectedLength(relativePath: rel)
            }
            sizeByPath[rel] = expected
            if expected > 0 { totalBytes += expected }
        }

        let totalHuman = Self.formatBytes(totalBytes)
        DebugLogger.shared.info("[ModelDL] Files to download: \(pendingFiles.count), total size: \(totalHuman)", source: "ModelDownloader")

        var downloadedBytes: Int64 = 0
        // Never synthesize progress from file count: model artifacts vary from bytes to
        // gigabytes. Report byte progress for known-size files and hold steady for unknown-size
        // files until the validated bundle can truthfully report completion.
        let maximumIncompleteProgress = 0.999

        for (idx, rel) in pendingFiles.enumerated() {
            try Task.checkCancellation()
            DebugLogger.shared.info("[ModelDL] (\(idx + 1)/\(pendingFiles.count)) Downloading: \(rel)", source: "ModelDownloader")
            let completedBytesBeforeFile = downloadedBytes
            try await self.downloadFile(relativePath: rel, to: targetRoot.appendingPathComponent(rel)) { perFilePct in
                let expected = sizeByPath[rel] ?? 0
                if expected > 0, totalBytes > 0 {
                    let overallBase = Double(completedBytesBeforeFile) / Double(totalBytes)
                    let combined = min(
                        maximumIncompleteProgress,
                        overallBase + (perFilePct * Double(expected)) / Double(totalBytes)
                    )
                    onProgress?(combined, rel)
                    DebugLogger.shared.debug(String(format: "[ModelDL] File progress: %.1f%% (%@)", perFilePct * 100.0, rel), source: "ModelDownloader")
                    DebugLogger.shared.debug(String(format: "[ModelDL] Overall progress: %.1f%%", combined * 100.0), source: "ModelDownloader")
                }
            }
            try Task.checkCancellation()
            let expectedFileBytes = sizeByPath[rel] ?? 0
            if expectedFileBytes > 0 {
                let destination = targetRoot.appendingPathComponent(rel)
                let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
                let actualBytes = (attributes?[.size] as? NSNumber)?.int64Value
                guard actualBytes == expectedFileBytes else {
                    try? FileManager.default.removeItem(at: destination)
                    throw NSError(
                        domain: "HF",
                        code: -5,
                        userInfo: [NSLocalizedDescriptionKey: "Downloaded file size mismatch for \(rel). Please try again."]
                    )
                }
            }
            if expectedFileBytes > 0, totalBytes > 0 {
                downloadedBytes += expectedFileBytes
                let pct = min(maximumIncompleteProgress, Double(downloadedBytes) / Double(totalBytes))
                onProgress?(pct, rel)
                DebugLogger.shared.info(String(format: "[ModelDL] Overall progress: %.1f%% (\(Self.formatBytes(downloadedBytes))/\(Self.formatBytes(totalBytes)))", pct * 100.0), source: "ModelDownloader")
            }
        }

        guard Self.artifactsAreComplete(root: targetRoot, items: self.requiredItems()) else {
            throw NSError(
                domain: "HF",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Downloaded model artifacts are incomplete. Please try again."]
            )
        }
        try Task.checkCancellation()
        onProgress?(1.0, "")
    }

    private func requiredItems() -> [ModelItem] {
        self.requiredItemsList
    }

    /// Decides whether `relativePath` needs to be (re)downloaded into `destination`.
    ///
    /// A file is pending when it is missing, OR when it is present but its cached content
    /// looks like an HTML/markup payload — a corrupt artifact cached before download-time
    /// content validation existed (see #353). `fileExists` alone would leave such a payload
    /// stuck forever, because `downloadFile` (and its validator) only runs for pending files.
    /// A present markup file is deleted here so a clean copy is fetched; on a read error the
    /// file is left in place and treated as valid, so we never delete on uncertainty.
    private func needsDownload(relativePath: String, at destination: URL, expectedBytes: Int64? = nil) -> Bool {
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return true
        }
        if let expectedBytes, expectedBytes >= 0,
           let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
           let localSize = attributes[.size] as? NSNumber,
           localSize.int64Value != expectedBytes
        {
            try? FileManager.default.removeItem(at: destination)
            return true
        }
        guard !Self.artifactIsComplete(at: destination, isDirectory: false) else { return false }
        let reason = Self.cachedFileIsMarkup(at: destination)
            ? "an HTML/markup page, not model data"
            : "empty or not a regular file"
        DebugLogger.shared.warning(
            "[ModelDL] Cached file is \(reason); deleting to re-download: \(relativePath)",
            source: "ModelDownloader"
        )
        do {
            try FileManager.default.removeItem(at: destination)
        } catch {
            DebugLogger.shared.error(
                "[ModelDL] Failed to delete corrupt cached file \(relativePath): \(error.localizedDescription)",
                source: "ModelDownloader"
            )
        }
        return true
    }

    private func downloadDirectory(relativePath: String, to destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // Download entire directory by enumerating all files
        let files = try await listFilesRecursively(relativePath: relativePath)
        for entry in files {
            let rel = entry.path
            let dest = destination.deletingLastPathComponent().appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await self.downloadFile(relativePath: rel, to: dest)
        }
    }

    private func downloadFile(relativePath: String, to destination: URL, perFileProgress: ((Double) -> Void)? = nil) async throws {
        let fileURL = self.baseResolveURL.appendingPathComponent(relativePath)

        let delegate = DownloadProgressDelegate { totalBytesWritten, totalBytesExpected in
            guard totalBytesExpected > 0 else { return }
            perFileProgress?(min(1.0, Double(totalBytesWritten) / Double(totalBytesExpected)))
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var temporaryURL: URL?
        do {
            let result = try await withTaskCancellationHandler {
                try await session.download(from: fileURL)
            } onCancel: {
                session.invalidateAndCancel()
            }
            temporaryURL = result.0
            let response = result.1

            try Task.checkCancellation()
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NSError(domain: "HF", code: http.statusCode)
            }

            // Reject HTML error/block pages (e.g. a corporate proxy returning its
            // notification page with HTTP 200) before persisting them as a model
            // file, otherwise a corrupt payload is cached permanently. See #353.
            try Self.validateDownloadedFile(at: result.0, response: response, relativePath: relativePath)
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: result.0, to: destination)
            temporaryURL = nil
        } catch {
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            session.invalidateAndCancel()
            if Task.isCancelled || Self.isCancellationError(error) {
                throw CancellationError()
            }
            throw error
        }
    }

    static func artifactsAreComplete(root: URL, items: [ModelItem]) -> Bool {
        items.allSatisfy { item in
            Self.artifactIsComplete(
                at: root.appendingPathComponent(item.path, isDirectory: item.isDirectory),
                isDirectory: item.isDirectory
            )
        }
    }

    static func artifactIsComplete(at url: URL, isDirectory: Bool) -> Bool {
        guard isDirectory else { return self.fileHasContents(at: url) }

        if url.pathExtension == "mlpackage" {
            let manifestURL = url.appendingPathComponent("Manifest.json")
            guard
                Self.fileHasContents(at: manifestURL),
                let data = try? Data(contentsOf: manifestURL),
                let manifestObject = try? JSONSerialization.jsonObject(with: data),
                let manifest = manifestObject as? [String: Any],
                let entries = manifest["itemInfoEntries"] as? [String: [String: Any]],
                !entries.isEmpty
            else {
                return false
            }

            return entries.values.allSatisfy { entry in
                guard let relativePath = entry["path"] as? String else { return false }
                let artifact = url
                    .appendingPathComponent("Data", isDirectory: true)
                    .appendingPathComponent(relativePath)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: artifact.path, isDirectory: &isDirectory) else {
                    return false
                }
                return Self.artifactIsComplete(at: artifact, isDirectory: isDirectory.boolValue)
            }
        }
        if url.pathExtension == "mlmodelc" {
            // `model.mil` and `metadata.json` are descriptive and absent from some valid
            // compiled bundles (the Flash preprocessor omits `model.mil`; the SenseVoice
            // export omits `metadata.json`). Load-critical truth is the compiled index plus
            // weights, so require only those two.
            return self.fileHasContents(at: url.appendingPathComponent("coremldata.bin"))
                && self.fileHasContents(
                    at: url
                        .appendingPathComponent("weights", isDirectory: true)
                        .appendingPathComponent("weight.bin")
                )
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        for case let fileURL as URL in enumerator where Self.fileHasContents(at: fileURL) {
            return true
        }
        return false
    }

    private static func fileHasContents(at url: URL) -> Bool {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let type = attributes[.type] as? FileAttributeType,
            type == .typeRegular,
            let size = attributes[.size] as? NSNumber
        else {
            return false
        }
        return size.int64Value > 0 && !Self.cachedFileIsMarkup(at: url)
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    // MARK: - Content Validation

    /// Validates a freshly-downloaded artifact before it is persisted as a model file.
    ///
    /// A network proxy / secure web gateway can return an HTML (or XML) block page with
    /// HTTP 200 in place of the real file. Persisting that markup (e.g. as `coremldata.bin`)
    /// permanently caches a corrupt model. We reject any payload that looks like HTML/XML
    /// markup — by its `Content-Type` or by its leading bytes — since no model artifact
    /// (CoreML binary, JSON vocab, `.mil`) is a markup document. See issue #353.
    static func validateDownloadedFile(at fileURL: URL, response: URLResponse?, relativePath: String) throws {
        if let expectedBytes = response?.expectedContentLength, expectedBytes > 0 {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard
                let actualBytes = attributes[.size] as? NSNumber,
                actualBytes.int64Value == expectedBytes
            else {
                throw NSError(
                    domain: "HF",
                    code: -5,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Could not download \(relativePath): the received file size did not match the server response.",
                    ]
                )
            }
        }

        if let http = response as? HTTPURLResponse,
           let contentType = http.value(forHTTPHeaderField: "Content-Type")
        {
            let lowered = contentType.lowercased()
            if lowered.contains("text/html") || lowered.contains("text/xml") || lowered.contains("application/xml") {
                throw Self.invalidContentError(
                    relativePath: relativePath,
                    detail: "the server returned a markup page (Content-Type: \(contentType))"
                )
            }
        }

        // Sniff the leading bytes in case markup was returned without a markup Content-Type.
        // Read a small prefix only — model files can be gigabytes.
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 512)) ?? Data()
        if Self.looksLikeHTML(prefix) {
            throw Self.invalidContentError(
                relativePath: relativePath,
                detail: "the downloaded file is an HTML/markup document, not the expected model data"
            )
        }
    }

    /// Returns `true` if a file already on disk is an HTML/markup payload rather than real
    /// model data — a corrupt artifact cached before download-time validation existed (#353).
    ///
    /// This is the cached-file analog of `validateDownloadedFile`'s byte-sniff: it reuses the
    /// same `looksLikeHTML` check on a small leading prefix (model files can be gigabytes, so
    /// only 512 bytes are read). There is no `URLResponse` for a cached file, so only the
    /// content is inspected, not a `Content-Type`. Returns `false` (treat as valid) on any
    /// read error, so an unreadable file is never deleted on uncertainty.
    static func cachedFileIsMarkup(at fileURL: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return false
        }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 512)) ?? Data()
        return Self.looksLikeHTML(prefix)
    }

    /// Returns `true` if any cached payload under `relativePaths` (each resolved against `root`)
    /// is an HTML/markup document rather than real model data — the cached-*tree* analog of
    /// `cachedFileIsMarkup`, intended for a provider preflight to call before trusting a present
    /// cache and skipping the downloader. The downloader itself already re-validates each file via
    /// `needsDownload`, but a preflight that returns on file-existence alone never reaches it, so a
    /// corrupt-but-present cache would slip through (see #353).
    ///
    /// Each relative path may be a regular file or a directory (e.g. a `.mlpackage` bundle).
    /// Directories are scanned recursively and every regular file inside is byte-sniffed with
    /// `cachedFileIsMarkup`, reusing the single `looksLikeHTML` detector — there is no second
    /// markup heuristic. Conservative on uncertainty, mirroring `cachedFileIsMarkup`: a path that
    /// does not exist, a file that cannot be read, or a directory that cannot be enumerated is
    /// skipped (treated as non-markup), so a valid cache is never reported corrupt. An empty
    /// required directory therefore yields `false` here — its incompleteness is the existence
    /// check's concern, not this markup check's.
    static func cachedPayloadContainsMarkup(root: URL, relativePaths: [String]) -> Bool {
        let fileManager = FileManager.default
        for relativePath in relativePaths {
            let url = root.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }
            if isDirectory.boolValue {
                guard let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }
                for case let fileURL as URL in enumerator {
                    let isRegularFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                    guard isRegularFile else { continue }
                    if Self.cachedFileIsMarkup(at: fileURL) {
                        return true
                    }
                }
            } else if Self.cachedFileIsMarkup(at: url) {
                return true
            }
        }
        return false
    }

    /// Returns `true` if `data` begins with an HTML / XML markup marker, ignoring a leading
    /// UTF-8 BOM and ASCII whitespace.
    ///
    /// No artifact this downloader fetches legitimately begins with `<`: CoreML compiled
    /// `.mlmodelc` / `.mlpackage` payloads are binary (`coremldata.bin`, `weights/weight.bin`,
    /// `model.mlmodel` protobuf) or JSON (`metadata.json`, `Manifest.json`) starting with
    /// `{` / `[`; the MIL program text (`model.mil`) starts with `program`; the vocab JSON
    /// starts with `{`; and `tokenizer.model` is a SentencePiece binary. So any payload that,
    /// after BOM + whitespace stripping, starts with `<` followed by a markup-ish byte is a
    /// proxy/block page or a markup document standing in for the real file — reject it. This
    /// catches `<!doctype`, `<html`, `<head>`, `<body>`, `<script>`, `<meta>`, comments
    /// (`<!-- -->`) and XML / `<?xml` declarations, not just the two prefixes we used to
    /// match. See issue #353.
    static func looksLikeHTML(_ data: Data) -> Bool {
        var bytes = [UInt8](data.prefix(512))
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) {
            bytes.removeFirst(3)
        }
        while let first = bytes.first,
              first == 0x20 || first == 0x09 || first == 0x0a || first == 0x0d
        {
            bytes.removeFirst()
        }
        // Must begin with `<` (0x3C)…
        guard bytes.first == 0x3c, bytes.count >= 2 else {
            return false
        }
        // …immediately followed by a markup-ish byte: an ASCII letter (a tag such as
        // `<html`), `!` (0x21 — `<!doctype`, `<!--`), `?` (0x3F — `<?xml`), or `/` (0x2F —
        // a stray closing tag). Requiring this second byte avoids over-rejecting a
        // hypothetical text artifact that merely contains a stray `<` not followed by markup.
        let second = bytes[1]
        let isAsciiLetter = (second >= 0x41 && second <= 0x5a) || (second >= 0x61 && second <= 0x7a)
        return isAsciiLetter || second == 0x21 || second == 0x3f || second == 0x2f
    }

    private static func invalidContentError(relativePath: String, detail: String) -> NSError {
        NSError(domain: "HF", code: -3, userInfo: [
            NSLocalizedDescriptionKey:
                "Could not download \(relativePath): \(detail). A network proxy or firewall may be blocking model downloads.",
        ])
    }

    private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let onProgress: (Int64, Int64) -> Void

        init(onProgress: @escaping (Int64, Int64) -> Void) {
            self.onProgress = onProgress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The async URLSession API owns completion; this delegate only reports bytes.
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            self.onProgress(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    private func headExpectedLength(relativePath: String) async throws -> Int64 {
        try Task.checkCancellation()
        let fileURL = self.baseResolveURL.appendingPathComponent(relativePath)
        var req = URLRequest(url: fileURL)
        req.httpMethod = "HEAD"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            try Task.checkCancellation()
            guard let http = resp as? HTTPURLResponse, http.statusCode < 400 else {
                return 0
            }
            return http.expectedContentLength
        } catch {
            if Task.isCancelled || Self.isCancellationError(error) {
                throw CancellationError()
            }
            return 0
        }
    }

    private func listFilesRecursively(relativePath: String) async throws -> [HFEntry] {
        try Task.checkCancellation()
        let listingURL = self.baseApiURL
            .appendingPathComponent(relativePath)
        guard var comps = URLComponents(url: listingURL, resolvingAgainstBaseURL: false) else {
            throw NSError(domain: "HF", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid listing URL components"])
        }
        comps.queryItems = [URLQueryItem(name: "recursive", value: "1")]

        guard let url = comps.url else {
            throw NSError(domain: "HF", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid listing URL"])
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        try Task.checkCancellation()
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw NSError(domain: "HF", code: http.statusCode)
        }

        let decoder = JSONDecoder()
        let entries = try decoder.decode([HFEntry].self, from: data)

        return entries
            .filter { $0.type == "file" }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let kb: Double = 1024
        let mb = kb * 1024
        let gb = mb * 1024
        let b = Double(bytes)
        if b >= gb { return String(format: "%.2f GB", b / gb) }
        if b >= mb { return String(format: "%.2f MB", b / mb) }
        if b >= kb { return String(format: "%.2f KB", b / kb) }
        return "\(bytes) B"
    }
}

#if arch(arm64)
extension HuggingFaceModelDownloader {
    /// Load ASR models directly from disk using unified v3 model names
    func loadLocalAsrModels(from repoDirectory: URL) async throws -> AsrModels {
        let config = AsrModels.defaultConfiguration()
        let fm = FileManager.default

        // Try to load with new naming convention first (Preprocessor + Encoder)
        let preprocessorUrl = repoDirectory.appendingPathComponent("Preprocessor.mlmodelc")
        let encoderUrl = repoDirectory.appendingPathComponent("Encoder.mlmodelc")
        let decUrl = repoDirectory.appendingPathComponent("Decoder.mlmodelc")
        let jointUrl = repoDirectory.appendingPathComponent("JointDecision.mlmodelc")

        DebugLogger.shared.info("[ModelDL] Loading v3 models from: \(repoDirectory.path)", source: "ModelDownloader")
        DebugLogger.shared.debug("[ModelDL] Preprocessor path: \(preprocessorUrl.path)", source: "ModelDownloader")
        DebugLogger.shared.debug("[ModelDL] Encoder path: \(encoderUrl.path)", source: "ModelDownloader")
        DebugLogger.shared.debug("[ModelDL] Decoder path: \(decUrl.path)", source: "ModelDownloader")
        DebugLogger.shared.debug("[ModelDL] JointDecision path: \(jointUrl.path)", source: "ModelDownloader")

        // Check if new structure exists
        let hasNewStructure = fm.fileExists(atPath: preprocessorUrl.path) && fm.fileExists(atPath: encoderUrl.path)

        let encoder: MLModel
        let preprocessor: MLModel?

        if hasNewStructure {
            // Load with new structure (separate Preprocessor and Encoder)
            DebugLogger.shared.info("[ModelDL] Loading with new model structure (Preprocessor + Encoder)", source: "ModelDownloader")
            preprocessor = try MLModel(contentsOf: preprocessorUrl, configuration: config)
            encoder = try MLModel(contentsOf: encoderUrl, configuration: config)
        } else {
            // Fallback: Try old structure (MelEncoder)
            let melEncUrl = repoDirectory.appendingPathComponent("MelEncoder.mlmodelc")
            DebugLogger.shared.info("[ModelDL] New structure not found, trying legacy MelEncoder", source: "ModelDownloader")
            DebugLogger.shared.debug("[ModelDL] MelEncoder path: \(melEncUrl.path)", source: "ModelDownloader")
            DebugLogger.shared.debug("[ModelDL] MelEncoder exists: \(fm.fileExists(atPath: melEncUrl.path))", source: "ModelDownloader")

            if fm.fileExists(atPath: melEncUrl.path) {
                encoder = try MLModel(contentsOf: melEncUrl, configuration: config)
                preprocessor = nil
                DebugLogger.shared.info("[ModelDL] Using MelEncoder (legacy mode)", source: "ModelDownloader")
            } else {
                throw NSError(domain: "ModelDL", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Neither new model structure (Preprocessor + Encoder) nor legacy structure (MelEncoder) found",
                ])
            }
        }

        // Load decoder and joint (same for both structures)
        let decoder = try MLModel(contentsOf: decUrl, configuration: config)
        let joint = try MLModel(contentsOf: jointUrl, configuration: config)

        // Load vocabulary (JSON: {"0": "<pad>", ...}) from repo root
        let vocabPath = repoDirectory.deletingLastPathComponent().appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")
            .appendingPathComponent("parakeet_v3_vocab.json")
        guard fm.fileExists(atPath: vocabPath.path) else {
            throw NSError(
                domain: "ModelDL",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Vocabulary file not found at \(vocabPath.path)"]
            )
        }
        let vocabData = try Data(contentsOf: vocabPath)
        let raw = try JSONSerialization.jsonObject(with: vocabData) as? [String: String] ?? [:]
        var vocabulary: [Int: String] = [:]
        vocabulary.reserveCapacity(raw.count)
        for (k, v) in raw {
            if let idx = Int(k) { vocabulary[idx] = v }
        }

        DebugLogger.shared.debug("[ModelDL] Creating AsrModels", source: "ModelDownloader")

        // For v2 models without separate preprocessor, use encoder as preprocessor
        // For v3 models, use the separate preprocessor
        let finalPreprocessor = preprocessor ?? encoder

        return AsrModels(
            encoder: encoder,
            preprocessor: finalPreprocessor,
            decoder: decoder,
            joint: joint,
            configuration: config,
            vocabulary: vocabulary,
            version: preprocessor != nil ? .v3 : .v2
        )
    }
}
#endif
