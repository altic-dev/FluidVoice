#if arch(arm64)
import CoreML
import CryptoKit
import FluidAudio
import Foundation

/// Installs the portable Orukeet preview in its own cache. Network access happens only on installation.
nonisolated enum OrukeetModelStore {
    static let revision = "43142dd1897f9ddadcd70173fcb5ff45c08aa951"
    static let archiveSHA256 = "b2a6efc4ed3280c860f29b3e2e2ea242ade14c6482c94f1c8d3e8551d5edb626"
    static let archiveBytes = 466_579_851
    static let components = ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"]
    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orukeet/coreml-baseline-20260915", isDirectory: true)
    }

    static var isInstalled: Bool {
        installed(at: directory)
    }

    static func installed(at directory: URL) -> Bool {
        let stamp = try? String(
            contentsOf: directory.appendingPathComponent(".revision"), encoding: .utf8)
        return stamp == revision
            && components.allSatisfy { name in
                let compiled = directory.appendingPathComponent("\(name).mlmodelc")
                return fileHasContents(compiled.appendingPathComponent("coremldata.bin"))
                    && fileHasContents(compiled.appendingPathComponent("weights/weight.bin"))
            } && fileHasContents(directory.appendingPathComponent("parakeet_vocab.json"))
    }

    private static func fileHasContents(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return false
        }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }

    private struct Manifest: Decodable {
        struct Archive: Decodable {
            let filename: String
            let bytes: Int
            let sha256: String
        }
        let archives: [String: Archive]
    }

    static func prepare(progress: ModelPreparationProgressRelay) async throws -> AsrModels {
        if !isInstalled {
            try await OrukeetInstallation.shared.install(progress: progress)
        }
        try Task.checkCancellation()
        progress.report(.loading)
        return try load(from: directory)
    }

    static func install(progress: ModelPreparationProgressRelay) async throws {
        guard
            let base = URL(string: "https://huggingface.co/oruk/orukeet/resolve/\(revision)/coreml/")
        else {
            throw URLError(.badURL)
        }
        progress.report(.preparingDownload)
        // The NeMo repository's JSON manifest is counted by Hugging Face. It is also
        // consumed here to verify the pinned artifact, never fetched during transcription.
        let (metadata, response) = try await URLSession.shared.data(
            from: base.appendingPathComponent("manifest.json"))
        try validateHTTP(response)
        let manifest = try JSONDecoder().decode(Manifest.self, from: metadata)
        guard let archive = manifest.archives["baseline"],
            archive.filename == "orukeet-r3-coreml-baseline.zip",
            archive.bytes == archiveBytes, archive.sha256 == archiveSHA256
        else { throw CocoaError(.fileReadCorruptFile) }
        try Task.checkCancellation()
        let temporary = try await downloadArchive(
            from: base.appendingPathComponent(archive.filename),
            expectedBytes: archive.bytes, progress: progress)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        progress.report(.optimizing)
        try installArchive(at: temporary, to: directory)
    }

    static func downloadArchive(
        from url: URL, expectedBytes: Int, progress: ModelPreparationProgressRelay
    ) async throws -> URL {
        try Task.checkCancellation()
        progress.report(.downloading(0))
        let (temporary, response) = try await ProgressiveFileDownloader.download(
            from: url, configuration: .default
        ) { written, _ in
            // The verified manifest supplies a total even when a redirect omits Content-Length.
            progress.report(.downloading(Double(written) / Double(expectedBytes)))
        }
        do {
            try validateHTTP(response)
            try Task.checkCancellation()
            return temporary
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Separate from acquisition so the exact installer can be regression-tested with the pinned archive offline.
    static func installArchive(at archive: URL, to destination: URL) throws {
        guard try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize == archiveBytes,
            try checksum(of: archive) == archiveSHA256
        else { throw CocoaError(.fileReadCorruptFile) }
        let files = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".install-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        let unpack = Process()
        unpack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unpack.arguments = ["-x", "-k", archive.path, staging.path]
        try unpack.run()
        unpack.waitUntilExit()
        guard unpack.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        let bundle = staging.appendingPathComponent("orukeet-r3-coreml-baseline", isDirectory: true)
        for name in components {
            try Task.checkCancellation()
            let compiled = try MLModel.compileModel(
                at: bundle.appendingPathComponent("\(name).mlpackage"))
            defer { try? files.removeItem(at: compiled) }
            try files.moveItem(at: compiled, to: bundle.appendingPathComponent("\(name).mlmodelc"))
            try files.removeItem(at: bundle.appendingPathComponent("\(name).mlpackage"))
        }
        // Reject an incompatible vocabulary before making the install visible.
        _ = try vocabulary(in: bundle)
        try revision.write(
            to: bundle.appendingPathComponent(".revision"), atomically: true, encoding: .utf8)
        try Task.checkCancellation()
        try commitInstallation(from: bundle, to: destination)
    }

    /// Keep the previous installation available for rollback if the final rename fails.
    static func commitInstallation(from bundle: URL, to destination: URL) throws {
        let files = FileManager.default
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".previous-\(UUID().uuidString)", isDirectory: true)
        let hadPrevious = files.fileExists(atPath: destination.path)
        if hadPrevious { try files.moveItem(at: destination, to: backup) }
        do {
            try files.moveItem(at: bundle, to: destination)
        } catch {
            if hadPrevious { try files.moveItem(at: backup, to: destination) }
            throw error
        }
        if hadPrevious { try? files.removeItem(at: backup) }
    }

    static func load(from directory: URL) throws -> AsrModels {
        let vocabulary = try vocabulary(in: directory)
        func component(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try MLModel(
                contentsOf: directory.appendingPathComponent("\(name).mlmodelc"),
                configuration: configuration)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        return try AsrModels(
            encoder: component("Encoder", .cpuAndNeuralEngine),
            preprocessor: component("Preprocessor", .cpuOnly),
            decoder: component("Decoder", .cpuAndNeuralEngine),
            joint: component("JointDecisionv3", .cpuAndNeuralEngine),
            configuration: configuration, vocabulary: vocabulary, version: .v3)
    }

    private static func vocabulary(in directory: URL) throws -> [Int: String] {
        let data = try Data(contentsOf: directory.appendingPathComponent("parakeet_vocab.json"))
        let raw = try JSONDecoder().decode([String: String].self, from: data)
        var result: [Int: String] = [:]
        for (key, token) in raw {
            guard let id = Int(key), (0..<8192).contains(id), result[id] == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            result[id] = token
        }
        guard result.count == 8192 else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }

    private static func checksum(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 8 * 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validateHTTP(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }
}

/// Coalesce model preparation so selecting a model during a download cannot start
/// another transfer or replace a directory while the first install is compiling.
private actor OrukeetInstallation {
    static let shared = OrukeetInstallation()
    private var task: Task<Void, Error>?

    func install(progress: ModelPreparationProgressRelay) async throws {
        if let task { return try await task.value }
        guard !OrukeetModelStore.isInstalled else { return }
        let task = Task { try await OrukeetModelStore.install(progress: progress) }
        self.task = task
        defer { self.task = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
#endif
