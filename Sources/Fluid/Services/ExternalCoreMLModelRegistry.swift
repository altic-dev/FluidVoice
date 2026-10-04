import CoreML
import FluidAudio
import Foundation

nonisolated enum ExternalCoreMLASRBackend: Sendable {
    case cohereTranscribe
}

nonisolated struct ExternalCoreMLManifestIdentity: Decodable, Sendable {
    let modelID: String
    let sampleRate: Int
    let maxAudioSamples: Int
    let maxAudioSeconds: Double
    let overlapSamples: Int?

    private enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case sampleRate = "sample_rate"
        case maxAudioSamples = "max_audio_samples"
        case maxAudioSeconds = "max_audio_seconds"
        case overlapSamples = "overlap_samples"
    }
}

nonisolated enum ExternalCoreMLArtifactsValidationError: LocalizedError {
    case missingEntries([String])
    case manifestMissing(URL)
    case manifestUnreadable(URL, Error)
    case unexpectedModelID(expected: String, actual: String)
    case unexpectedSampleRate(expected: Int, actual: Int)
    case invalidMaxAudioSeconds(Double)
    case invalidMaxAudioSamples(Int)
    case inconsistentAudioWindow(samples: Int, seconds: Double, sampleRate: Int)
    case invalidOverlapSamples(Int, maxAudioSamples: Int)

    var errorDescription: String? {
        switch self {
        case let .missingEntries(entries):
            return "Missing required files: \(entries.joined(separator: ", "))"
        case let .manifestMissing(url):
            return "Manifest file not found at \(url.path)"
        case let .manifestUnreadable(url, error):
            return "Failed to read manifest at \(url.path): \(error.localizedDescription)"
        case let .unexpectedModelID(expected, actual):
            return "Unexpected model_id '\(actual)'. Expected '\(expected)'."
        case let .unexpectedSampleRate(expected, actual):
            return "Unexpected sample rate \(actual). Expected \(expected)."
        case let .invalidMaxAudioSeconds(seconds):
            return "Invalid max_audio_seconds \(seconds)."
        case let .invalidMaxAudioSamples(samples):
            return "Invalid max_audio_samples \(samples)."
        case let .inconsistentAudioWindow(samples, seconds, sampleRate):
            return "Manifest audio window is inconsistent: \(samples) samples vs \(seconds)s at \(sampleRate) Hz."
        case let .invalidOverlapSamples(overlapSamples, maxAudioSamples):
            return "Invalid overlap_samples \(overlapSamples) for max_audio_samples \(maxAudioSamples)."
        }
    }
}

nonisolated struct ExternalCoreMLASRModelSpec: Sendable {
    private static let bundleStampFileName = ".fluid_artifact_bundle_version"

    let backend: ExternalCoreMLASRBackend
    let artifactFolderHint: String
    let manifestFileName: String
    let frontendFileName: String
    let encoderFileName: String
    let crossKVProjectorFileName: String?
    let decoderFileName: String
    let cachedDecoderFileName: String
    let expectedModelID: String
    let expectedSampleRate: Int
    let computeConfiguration: CohereTranscribeComputeConfiguration
    let sourceURL: URL?
    let repositoryOwner: String?
    let repositoryName: String?
    let repositoryRevision: String
    let artifactBundleVersion: String
    private let maximumAudioWindowSeconds: Double = 60

    var requiredEntries: [String] {
        [
            self.manifestFileName,
            self.frontendFileName,
            self.encoderFileName,
            self.crossKVProjectorFileName,
            self.decoderFileName,
            self.cachedDecoderFileName,
        ]
        .compactMap { $0 }
    }

    func url(for entry: String, in directory: URL) -> URL {
        directory.appendingPathComponent(entry, isDirectory: entry.hasSuffix(".mlpackage"))
    }

    var defaultCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(self.artifactFolderHint, isDirectory: true)
    }

    func validateArtifacts(at directory: URL) -> Bool {
        (try? self.validateArtifactsOrThrow(at: directory)) != nil
    }

    func validatesInstalledArtifacts(at directory: URL) -> Bool {
        guard self.validateArtifacts(at: directory) else { return false }
        return !self.isAppManagedArtifactsDirectory(directory)
            || self.artifactBundleStampMatches(at: directory)
    }

    func isAppManagedArtifactsDirectory(_ directory: URL) -> Bool {
        guard let defaultCacheDirectory = self.defaultCacheDirectory else { return false }
        return directory.standardizedFileURL.path == defaultCacheDirectory.standardizedFileURL.path
    }

    func artifactBundleStampMatches(at directory: URL) -> Bool {
        let stampURL = directory.appendingPathComponent(Self.bundleStampFileName, isDirectory: false)
        guard
            let currentStamp = try? String(contentsOf: stampURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return false
        }
        return currentStamp == self.artifactBundleVersion
    }

    func persistArtifactBundleStamp(at directory: URL) {
        let stampURL = directory.appendingPathComponent(Self.bundleStampFileName, isDirectory: false)
        try? self.artifactBundleVersion.write(to: stampURL, atomically: true, encoding: .utf8)
    }

    func missingEntries(at directory: URL) -> [String] {
        self.requiredEntries.filter { entry in
            let url = self.url(for: entry, in: directory)
            return HuggingFaceModelDownloader.artifactIsComplete(
                at: url,
                isDirectory: entry.hasSuffix(".mlpackage")
            ) == false
        }
    }

    func loadManifest(at directory: URL) throws -> ExternalCoreMLManifestIdentity {
        let manifestURL = self.url(for: self.manifestFileName, in: directory)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ExternalCoreMLArtifactsValidationError.manifestMissing(manifestURL)
        }

        do {
            let data = try Data(contentsOf: manifestURL)
            return try JSONDecoder().decode(ExternalCoreMLManifestIdentity.self, from: data)
        } catch {
            throw ExternalCoreMLArtifactsValidationError.manifestUnreadable(manifestURL, error)
        }
    }

    func validateArtifactsOrThrow(at directory: URL) throws {
        let missingEntries = self.missingEntries(at: directory)
        guard missingEntries.isEmpty else {
            throw ExternalCoreMLArtifactsValidationError.missingEntries(missingEntries)
        }

        let manifest = try self.loadManifest(at: directory)

        guard manifest.modelID == self.expectedModelID else {
            throw ExternalCoreMLArtifactsValidationError.unexpectedModelID(
                expected: self.expectedModelID,
                actual: manifest.modelID
            )
        }

        guard manifest.sampleRate == self.expectedSampleRate else {
            throw ExternalCoreMLArtifactsValidationError.unexpectedSampleRate(
                expected: self.expectedSampleRate,
                actual: manifest.sampleRate
            )
        }

        guard manifest.maxAudioSeconds > 0, manifest.maxAudioSeconds <= self.maximumAudioWindowSeconds else {
            throw ExternalCoreMLArtifactsValidationError.invalidMaxAudioSeconds(manifest.maxAudioSeconds)
        }

        let maximumAudioSamples = Int((Double(self.expectedSampleRate) * self.maximumAudioWindowSeconds).rounded())
        guard manifest.maxAudioSamples > 0, manifest.maxAudioSamples <= maximumAudioSamples else {
            throw ExternalCoreMLArtifactsValidationError.invalidMaxAudioSamples(manifest.maxAudioSamples)
        }

        let expectedSamples = Int((manifest.maxAudioSeconds * Double(manifest.sampleRate)).rounded())
        guard abs(expectedSamples - manifest.maxAudioSamples) <= 1 else {
            throw ExternalCoreMLArtifactsValidationError.inconsistentAudioWindow(
                samples: manifest.maxAudioSamples,
                seconds: manifest.maxAudioSeconds,
                sampleRate: manifest.sampleRate
            )
        }

        if let overlapSamples = manifest.overlapSamples {
            guard overlapSamples >= 0, overlapSamples < manifest.maxAudioSamples else {
                throw ExternalCoreMLArtifactsValidationError.invalidOverlapSamples(
                    overlapSamples,
                    maxAudioSamples: manifest.maxAudioSamples
                )
            }
        }
    }
}

enum ExternalCoreMLModelRegistry {
    static func spec(for model: SettingsStore.SpeechModel) -> ExternalCoreMLASRModelSpec? {
        switch model {
        case .cohereTranscribeSixBit:
            return ExternalCoreMLASRModelSpec(
                backend: .cohereTranscribe,
                artifactFolderHint: "cohere-transcribe-03-2026-CoreML-6bit",
                manifestFileName: "coreml_manifest.json",
                frontendFileName: "cohere_frontend.mlpackage",
                encoderFileName: "cohere_encoder.mlpackage",
                crossKVProjectorFileName: "cohere_cross_kv_projector.mlpackage",
                decoderFileName: "cohere_decoder_fullseq_masked.mlpackage",
                cachedDecoderFileName: "cohere_decoder_cached.mlpackage",
                expectedModelID: "CohereLabs/cohere-transcribe-03-2026",
                expectedSampleRate: 16_000,
                computeConfiguration: .aneSmall,
                sourceURL: URL(string: "https://huggingface.co/BarathwajAnandan/cohere-transcribe-03-2026-CoreML-6bit"),
                repositoryOwner: "BarathwajAnandan",
                repositoryName: "cohere-transcribe-03-2026-CoreML-6bit",
                repositoryRevision: "main",
                artifactBundleVersion: "2026-04-02-cohere-refresh-1"
            )
        default:
            return nil
        }
    }
}

extension SettingsStore.SpeechModel {
    var externalCoreMLSpec: ExternalCoreMLASRModelSpec? {
        ExternalCoreMLModelRegistry.spec(for: self)
    }

    var requiresExternalArtifacts: Bool {
        self.externalCoreMLSpec != nil
    }

    var supportsCustomVocabulary: Bool {
        switch self {
        case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico:
            return true
        default:
            return false
        }
    }
}
