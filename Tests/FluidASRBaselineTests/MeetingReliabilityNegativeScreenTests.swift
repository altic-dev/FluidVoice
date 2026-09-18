import CoreML
import Foundation
import Security
import XCTest
#if arch(arm64)
import FluidAudio
#endif

/// Diagnostic, not an accuracy gate: nonempty ASR output is measured, never asserted away.
/// Synthetic input only; no fixture audio, devices, downloader, or production pipeline used.
@MainActor
final class MeetingReliabilityNegativeScreenTests: XCTestCase {
    func testSyntheticNoiseIsDeterministicBoundedAndNonzero() {
        let a = ReliabilitySyntheticInput.samples(count: 16_000, noise: true, seed: 42)
        XCTAssertEqual(a, ReliabilitySyntheticInput.samples(count: 16_000, noise: true, seed: 42))
        XCTAssertNotEqual(a, ReliabilitySyntheticInput.samples(count: 16_000, noise: true, seed: 43))
        XCTAssertTrue(a.allSatisfy { $0.isFinite && abs($0) <= 0.001 })
        XCTAssertGreaterThan(a.reduce(0.0) { $0 + Double($1 * $1) }, 0)
        XCTAssertEqual(ReliabilitySyntheticInput.samples(count: 100, noise: false, seed: 42), [Float](repeating: 0, count: 100))
    }

    func testOutputCountingAndExposureAccounting() {
        XCTAssertEqual(ReliabilitySyntheticInput.wordCount(" \n\t"), 0)
        XCTAssertEqual(ReliabilitySyntheticInput.wordCount("Okay,  I\nget it."), 4)
        XCTAssertEqual(ReliabilitySyntheticInput.segmentLengths(totalSeconds: 61, segmentSeconds: 60), [60, 1])
        XCTAssertEqual(ReliabilitySyntheticInput.segmentLengths(totalSeconds: 600, segmentSeconds: 3).reduce(0, +), 600)
    }

    func testCanonicalArtifactRelativePathHandlesTemporaryDirectoryAliases() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("model", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let child = root.appendingPathComponent("weight.bin")
        try Data([0]).write(to: child)
        let alias = fixture.appendingPathComponent("alias", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertEqual(try ReliabilitySyntheticInput.relativeArtifactPath(child, under: alias), "weight.bin")
        XCTAssertThrowsError(try ReliabilitySyntheticInput.relativeArtifactPath(fixture.appendingPathComponent("outside"), under: root))
    }

    func testSyntheticSilenceAndLowNoiseNegativeScreen() async throws {
        guard ProcessInfo.processInfo.environment["FLUID_RELIABILITY_NEGATIVE_SCREEN"] == "1" else {
            throw XCTSkip("opt-in: FLUID_RELIABILITY_NEGATIVE_SCREEN=1; default 600 audio seconds per condition/mode")
        }
        #if arch(arm64)
        try validateHost()
        let env = ProcessInfo.processInfo.environment
        let seconds = try boundedInteger(env["FLUID_RELIABILITY_SECONDS"], default: 600, range: 60...600)
        let budgetSeconds = try boundedInteger(env["FLUID_RELIABILITY_WALL_SECONDS"], default: 1200, range: 60...1800)
        guard let root = BaselineInputLoader.inputsRoot() else { throw ScreenError.invalidInputs }
        let manifest = try BaselineInputLoader.loadManifest(from: root)
        let manifestHash = try BaselineHashing.sha256Hex(ofFileAt: root.appendingPathComponent("manifest.json"))
        var report = NegativeScreenReport(manifestSHA256: manifestHash, modelRepository: manifest.modelRepository,
                                         requestedAudioSecondsPerConditionMode: seconds, wallBudgetSeconds: budgetSeconds)
        defer { attach(report) }
        var activeManager: AsrManager?
        do {
            report.phase = "artifact_validation"
            let repository = try validateArtifacts(root: root, manifest: manifest)
            // No AsrModels.load/download API: even load(from:) can enter DownloadUtils.
            // Direct CoreML loading has no model retrieval fallback.
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let preprocessorConfig = MLModelConfiguration()
            preprocessorConfig.computeUnits = .cpuOnly
            report.phase = "vocabulary_validation"
            let vocabData = try Data(contentsOf: repository.appendingPathComponent("parakeet_vocab.json"))
            let rawVocab = try JSONDecoder().decode([String: String].self, from: vocabData)
            var vocabulary: [Int: String] = [:]
            for (key, value) in rawVocab {
                guard let index = Int(key), vocabulary[index] == nil else { throw ScreenError.invalidVocabulary }
                vocabulary[index] = value
            }
            guard !vocabulary.isEmpty else { throw ScreenError.invalidVocabulary }
            report.phase = "local_model_load"
            let loadStart = Date()
            let models = AsrModels(
                encoder: try MLModel(contentsOf: repository.appendingPathComponent("Encoder.mlmodelc"), configuration: config),
                preprocessor: try MLModel(contentsOf: repository.appendingPathComponent("Preprocessor.mlmodelc"), configuration: preprocessorConfig),
                decoder: try MLModel(contentsOf: repository.appendingPathComponent("Decoder.mlmodelc"), configuration: config),
                joint: try MLModel(contentsOf: repository.appendingPathComponent("JointDecision.mlmodelc"), configuration: config),
                configuration: config, vocabulary: vocabulary, version: .v2)
            let manager = AsrManager()
            activeManager = manager
            try await manager.initialize(models: models)
            report.modelLoadSeconds = Date().timeIntervalSince(loadStart)
            report.phase = "synthetic_inference"
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(budgetSeconds)
            // One manager, strictly sequential awaits. Pinned AsrManager.transcribe([Float])
            // awaits throwing resetDecoderState before returning (3fd6388, lines 524–548).
            // Noise is the same continuous seeded sequence under either segmentation mode.
            for noise in [false, true] {
                let allSamples = ReliabilitySyntheticInput.samples(count: seconds * 16_000, noise: noise, seed: 0x46565030)
                for segmentSeconds in [60, 3] {
                    var offset = 0
                    for length in ReliabilitySyntheticInput.segmentLengths(totalSeconds: seconds, segmentSeconds: segmentSeconds) {
                        try Task.checkCancellation()
                        guard clock.now < deadline else { throw ScreenError.wallBudgetExceeded }
                        let count = length * 16_000
                        let samples = Array(allSamples[offset..<(offset + count)])
                        let start = clock.now
                        let result = try await manager.transcribe(samples, source: .microphone)
                        let elapsed = start.duration(to: clock.now).components
                        report.runs.append(.init(condition: noise ? "synthetic_uniform_noise_peak_0.001" : "digital_silence",
                                                 mode: segmentSeconds == 60 ? "whole_chunk_60s" : "short_turn_3s",
                                                 startSample: offset, sampleCount: count,
                                                 nonempty: !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                                 whitespaceWordCount: ReliabilitySyntheticInput.wordCount(result.text),
                                                 latencySeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18))
                        offset += count
                    }
                }
            }
            await manager.cleanup()
            activeManager = nil
            report.status = "complete"
            report.phase = "complete"
        } catch {
            if let activeManager { await activeManager.cleanup() }
            // Only error type, never ASR text or potentially sensitive file/error payload.
            report.status = "aborted_\(String(describing: type(of: error)))"
            if let safeError = error as? ScreenError { report.failureCode = String(describing: safeError) }
            throw error
        }
        #else
        throw XCTSkip("requires Apple Silicon")
        #endif
    }

    private func boundedInteger(_ raw: String?, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw else { return fallback }
        guard let value = Int(raw), range.contains(value) else { throw ScreenError.invalidConfiguration }
        return value
    }

    private func validateHost() throws {
        guard Bundle.main.bundleIdentifier == "com.FluidApp.ASRBaselineHost",
              let task = SecTaskCreateFromSelf(nil),
              (SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil) as? Bool) == true
        else { throw ScreenError.unsafeHost }
        for key in ["com.apple.security.network.client", "com.apple.security.network.server", "com.apple.security.device.audio-input"] {
            guard (SecTaskCopyValueForEntitlement(task, key as CFString, nil) as? Bool) != true else { throw ScreenError.unsafeHost }
        }
    }

    private func validateArtifacts(root: URL, manifest: ASRBaselineManifest) throws -> URL {
        guard manifest.modelRepository == "parakeet-tdt-0.6b-v2-coreml", !manifest.artifacts.isEmpty else { throw ScreenError.invalidRepository }
        let paths = manifest.artifacts.map(\.path)
        guard Set(paths).count == paths.count else { throw ScreenError.duplicateArtifactPaths }
        let repository = try BaselinePathSafety.validatedURL(forRelativePath: manifest.modelRepository, under: root)
        for artifact in manifest.artifacts {
            guard artifact.path.hasPrefix(manifest.modelRepository + "/") else { throw ScreenError.invalidArtifactPath }
            let url = try BaselinePathSafety.validatedURL(forRelativePath: artifact.path, under: root)
            guard try BaselineHashing.sha256Hex(ofFileAt: url) == artifact.sha256 else { throw ScreenError.artifactHashMismatch }
        }
        // Reject unmanifested files too: a partial manifest cannot bless an unverified model.
        guard let enumerator = FileManager.default.enumerator(at: repository, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw ScreenError.artifactEnumerationFailed }
        var actual = Set<String>()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw ScreenError.symbolicLinkArtifact }
            if values.isRegularFile == true {
                actual.insert(manifest.modelRepository + "/" + (try ReliabilitySyntheticInput.relativeArtifactPath(url, under: repository)))
            }
        }
        guard actual == Set(paths) else { throw ScreenError.artifactSetMismatch }
        return repository
    }

    private func attach(_ report: NegativeScreenReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { XCTFail("negative screen report encoding failed"); return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "MeetingReliabilityNegativeScreenReport"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

nonisolated private enum ScreenError: Error {
    case invalidInputs, invalidConfiguration, unsafeHost, wallBudgetExceeded
    case invalidRepository, duplicateArtifactPaths, invalidArtifactPath, artifactHashMismatch
    case artifactEnumerationFailed, symbolicLinkArtifact, artifactSetMismatch, invalidVocabulary
}

nonisolated enum ReliabilitySyntheticInput {
    static func relativeArtifactPath(_ child: URL, under root: URL) throws -> String {
        // FileManager may enumerate /private/tmp while resolvingSymlinksInPath returns
        // /tmp. Never trim using the character count of a differently normalized URL.
        let rootParts = BaselinePathSafety.canonical(root).pathComponents
        let childParts = BaselinePathSafety.canonical(child).pathComponents
        guard childParts.count > rootParts.count,
              Array(childParts.prefix(rootParts.count)) == rootParts else { throw ScreenError.invalidArtifactPath }
        return childParts.dropFirst(rootParts.count).joined(separator: "/")
    }
    static func samples(count: Int, noise: Bool, seed: UInt64) -> [Float] {
        guard noise else { return [Float](repeating: 0, count: count) }
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Float(state >> 40) / Float(0xFFFFFF) * 2 - 1) * 0.001
        }
    }
    static func wordCount(_ text: String) -> Int { text.split(whereSeparator: { $0.isWhitespace }).count }
    static func segmentLengths(totalSeconds: Int, segmentSeconds: Int) -> [Int] {
        precondition(totalSeconds >= 0 && segmentSeconds > 0)
        return stride(from: 0, to: totalSeconds, by: segmentSeconds).map { min(segmentSeconds, totalSeconds - $0) }
    }
}

nonisolated private struct NegativeScreenReport: Encodable {
    let schemaVersion = 1
    let kind = "synthetic_negative_asr_screen_not_meeting_pipeline"
    let verdict = "measured_only"
    let resetSemantics = "Pinned AsrManager array transcribe awaits resetDecoderState before successful return; errors abort the screen. Not the streaming EOU decoder."
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let sampleRateHz = 16_000
    let channels = 1
    let seed = "0x46565030; LCG64; top24-bit uniform; peak=0.001 (~-60dBFS)"
    let modelProvenance = "Preexisting host-bundled ASRBaselineInputs; exact artifact-set SHA256 verification against manifest; manifest is integrity provenance, not independent publisher authentication"
    let networkPolicy = "Direct local CoreML constructors; no downloader; sandbox required and network/audio-input entitlements forbidden"
    let scope = "No recorded audio read. No VAD, AEC, diarization, speaker profiles, production provider, or live recognizer. Noise is not AEC residual. Whitespace-delimited word counts, not linguistic token accuracy. Repeated silence is deterministic exposure, not independent statistical trials. No emptiness assertion. Wall budget checked between calls; a non-cooperative CoreML call may exceed it."
    let notTested = ["real AEC residual", "quiet speech recall", "short spoken acknowledgments", "double talk", "playback leakage", "caption reset recovery"]
    let manifestSHA256: String
    let modelRepository: String
    let requestedAudioSecondsPerConditionMode: Int
    let wallBudgetSeconds: Int
    var modelLoadSeconds: Double?
    var status = "in_progress"
    var phase = "initialization"
    var failureCode: String?
    var runs: [Run] = []
    struct Run: Encodable {
        let condition: String
        let mode: String
        let startSample: Int
        let sampleCount: Int
        let nonempty: Bool
        let whitespaceWordCount: Int
        let latencySeconds: Double
        var audioSeconds: Double { Double(sampleCount) / 16_000 }
        enum CodingKeys: CodingKey { case condition, mode, startSample, sampleCount, nonempty, whitespaceWordCount, latencySeconds, audioSeconds }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(condition, forKey: .condition); try c.encode(mode, forKey: .mode)
            try c.encode(startSample, forKey: .startSample); try c.encode(sampleCount, forKey: .sampleCount)
            try c.encode(nonempty, forKey: .nonempty); try c.encode(whitespaceWordCount, forKey: .whitespaceWordCount)
            try c.encode(latencySeconds, forKey: .latencySeconds); try c.encode(audioSeconds, forKey: .audioSeconds)
        }
    }
}
