#if arch(arm64)
import FluidAudio
#endif
@testable import FluidASRBaselineHost
import AppKit
import AVFoundation
import CryptoKit
import Darwin
import XCTest

/// Opt-in paired ASR provider baseline: legacy dictation config vs meeting config, both pinned
/// to Parakeet TDT v2 with every enhancement explicitly disabled. This is a synthetic
/// provider-only comparison of two equivalent explicit configurations — it is NOT the real
/// meeting diarization pipeline, NOT the S2-ownership memory gate, and NOT legacy default
/// (settings-driven) behavior. Runs only with FLUID_ASR_RUN_BENCHMARK=1 on arm64 under the
/// sandboxed `com.FluidApp.ASRBaselineHost` host; reports attach to the xcresult as
/// `ASRBaselineReport` (public.json, keepAlways) after every completed run and on abort.
@MainActor
final class PairedASRBaselineTests: XCTestCase {
    private static let pinnedFixtureSHA256 = "9fad783fa5e6398d095bf94883b5cf6ecb133c0c38480b790ce8c2903a818dde"
    private static let hostBundleIdentifier = "com.FluidApp.ASRBaselineHost"
    private static let pairRoundCount = 5
    private static let deallocBudget = Duration.seconds(2)

    private var partialReport: ASRBaselineReport?

    // MARK: - Always-on pure validation tests

    func testUnsafeRelativePathsAreRejected() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let rejected = ["/etc/passwd", "../escape", "a/../b", "a//b", "./x", "~/x", "a\\b", ""]
        for path in rejected {
            XCTAssertThrowsError(
                try BaselinePathSafety.validatedURL(forRelativePath: path, under: root),
                "expected rejection for \(path.debugDescription)"
            )
        }
        XCTAssertNoThrow(
            try BaselinePathSafety.validatedURL(
                forRelativePath: "parakeet-tdt-0.6b-v2-coreml/vocabulary.json",
                under: root
            )
        )
    }

    func testSymlinkEscapeIsRejected() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("baseline-symlink-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("link", isDirectory: true),
            withDestinationURL: root.deletingLastPathComponent()
        )
        XCTAssertThrowsError(
            try BaselinePathSafety.validatedURL(forRelativePath: "link/x.bin", under: root)
        )
    }

    func testBundledFixtureMatchesPinnedHashWhenAvailable() throws {
        guard let root = BaselineInputLoader.inputsRoot(),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path)
        else {
            throw XCTSkip("ASRBaselineInputs is not bundled with this host")
        }
        let canonicalRoot = BaselinePathSafety.canonical(root)
        let manifest = try BaselineInputLoader.loadManifest(from: canonicalRoot)
        let fixtureURL = try BaselinePathSafety.validatedURL(
            forRelativePath: manifest.fixture.path,
            under: canonicalRoot
        )
        let hash = try BaselineHashing.sha256Hex(ofFileAt: fixtureURL)
        XCTAssertEqual(hash, manifest.fixture.sha256)
        XCTAssertEqual(hash, Self.pinnedFixtureSHA256)
    }

    func testBundledFixtureDecodesToPinnedPCMWhenAvailable() throws {
        guard let root = BaselineInputLoader.inputsRoot(),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path)
        else {
            throw XCTSkip("ASRBaselineInputs is not bundled with this host")
        }
        let canonicalRoot = BaselinePathSafety.canonical(root)
        let manifest = try BaselineInputLoader.loadManifest(from: canonicalRoot)
        let fixtureURL = try BaselinePathSafety.validatedURL(
            forRelativePath: manifest.fixture.path,
            under: canonicalRoot
        )
        let hash = try BaselineHashing.sha256Hex(ofFileAt: fixtureURL)
        XCTAssertEqual(hash, Self.pinnedFixtureSHA256)
        let samples = try BaselineAudioLoader.loadMono16kInt16Samples(from: fixtureURL)
        XCTAssertEqual(samples.count, 1_200_000, "75s at 16kHz must decode to exactly 1.2M samples")
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        XCTAssertGreaterThan(energy, 0, "pinned fixture must contain non-silent audio")
    }

    // MARK: - Opt-in paired benchmark

    func testPairedFluidAudioProviderBaseline() async throws {
        #if arch(arm64)
        guard ProcessInfo.processInfo.environment["FLUID_ASR_RUN_BENCHMARK"] == "1" else {
            throw XCTSkip("opt-in: set FLUID_ASR_RUN_BENCHMARK=1 to run the paired ASR baseline")
        }
        do {
            try await self.runPairedBenchmark()
        } catch {
            // A cancel mid-await finishes the current non-cooperative await, unwinds the run
            // frame (releasing the provider), then lands here; attach whatever was recorded.
            if var report = self.partialReport {
                report.note = "aborted: \(error)"
                self.attachReport(report)
            } else {
                self.attachDiagnosticJSON(note: "aborted before report initialization: \(error)")
            }
            throw error
        }
        #else
        throw XCTSkip("paired ASR baseline requires Apple Silicon")
        #endif
    }

    #if arch(arm64)
    private func runPairedBenchmark() async throws {
        try self.validateSandboxEnvironment()
        let canonicalHome = BaselinePathSafety.canonical(
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        )
        let cacheDirectory = AsrModels.defaultCacheDirectory(for: .v2)
        guard BaselinePathSafety.isStrictDescendant(cacheDirectory, of: canonicalHome) else {
            throw BaselineInputError.sandboxEnvironment("model cache directory escapes container home")
        }

        guard let inputsRoot = BaselineInputLoader.inputsRoot(),
              FileManager.default.fileExists(atPath: inputsRoot.path)
        else {
            throw BaselineInputError.missingInputsRoot
        }
        let canonicalInputsRoot = BaselinePathSafety.canonical(inputsRoot)
        let manifest = try BaselineInputLoader.loadManifest(from: canonicalInputsRoot)
        // Attach diagnostics from this point on; earlier failures fall back to a minimal note.
        self.partialReport = ASRBaselineReport(
            schemaVersion: 1,
            testKind: "paired-fluidaudio-provider-baseline",
            syntheticScope: "synthetic provider-only run of two explicit equivalent configs; not meeting diarization, not the S2-ownership memory gate, not legacy default settings behavior",
            policy: "legacy=modelOverride:parakeetTDTv2,wordBoosting:off,unifiedFinal:off,pronunciation:off,customDictionary:[]; meeting=MeetingFinalProcessingConfiguration() fixed all-disabled policy",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            modelRepository: manifest.modelRepository,
            fixtureSHA256: manifest.fixture.sha256,
            fixtureSampleRateHz: manifest.fixture.sampleRateHz,
            fixtureChannels: manifest.fixture.channels,
            fixtureDurationSeconds: manifest.fixture.durationSeconds,
            runs: [],
            comparisons: [],
            note: "in-progress"
        )
        guard manifest.modelRepository == "parakeet-tdt-0.6b-v2-coreml",
              manifest.modelRepository == cacheDirectory.lastPathComponent
        else {
            throw BaselineInputError.invalidManifest("modelRepository=\(manifest.modelRepository)")
        }
        guard !manifest.artifacts.isEmpty else {
            throw BaselineInputError.invalidManifest("artifacts empty")
        }
        let artifactPaths = manifest.artifacts.map(\.path)
        guard Set(artifactPaths).count == artifactPaths.count else {
            throw BaselineInputError.invalidManifest("duplicate artifact paths")
        }
        guard manifest.artifacts.allSatisfy({ Self.isHex64($0.sha256) }) else {
            throw BaselineInputError.invalidManifest("artifact sha256 must be 64 hex characters")
        }

        // Fixture hash first: nothing is copied or prepared before the pinned audio is proven.
        let fixtureURL = try BaselinePathSafety.validatedURL(
            forRelativePath: manifest.fixture.path,
            under: canonicalInputsRoot
        )
        let fixtureHash = try BaselineHashing.sha256Hex(ofFileAt: fixtureURL)
        guard fixtureHash == manifest.fixture.sha256, fixtureHash == Self.pinnedFixtureSHA256 else {
            throw BaselineInputError.hashMismatch("fixture \(manifest.fixture.path)")
        }
        guard manifest.fixture.sampleRateHz == 16_000,
              manifest.fixture.channels == 1,
              abs(manifest.fixture.durationSeconds - 75.0) < 0.5
        else {
            throw BaselineInputError.fixtureMetadataMismatch(
                "rate=\(manifest.fixture.sampleRateHz) channels=\(manifest.fixture.channels) duration=\(manifest.fixture.durationSeconds)"
            )
        }

        var sourceArtifacts: [(relativePath: String, url: URL, sha256: String)] = []
        for artifact in manifest.artifacts {
            let firstComponent = artifact.path.split(separator: "/").first.map(String.init)
            guard firstComponent == manifest.modelRepository else {
                throw BaselineInputError.unsafeRelativePath(artifact.path)
            }
            let url = try BaselinePathSafety.validatedURL(forRelativePath: artifact.path, under: canonicalInputsRoot)
            sourceArtifacts.append((artifact.path, url, artifact.sha256))
        }
        for artifact in sourceArtifacts {
            let hash = try BaselineHashing.sha256Hex(ofFileAt: artifact.url)
            guard hash == artifact.sha256 else {
                throw BaselineInputError.hashMismatch("source \(artifact.relativePath)")
            }
        }

        // Verify-or-copy into the container cache. A mismatched existing copy fails loudly and
        // is never deleted by this test; extra files in an existing copy are tolerated.
        let fileManager = FileManager.default
        let modelsRoot = cacheDirectory.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
            let bundledRepository = canonicalInputsRoot.appendingPathComponent(
                manifest.modelRepository,
                isDirectory: true
            )
            guard BaselinePathSafety.isStrictDescendant(bundledRepository, of: canonicalInputsRoot) else {
                throw BaselineInputError.unsafeRelativePath(manifest.modelRepository)
            }
            try fileManager.copyItem(at: bundledRepository, to: cacheDirectory)
        }
        for artifact in manifest.artifacts {
            let cachedURL = try BaselinePathSafety.validatedURL(forRelativePath: artifact.path, under: modelsRoot)
            guard fileManager.fileExists(atPath: cachedURL.path) else {
                throw BaselineInputError.hashMismatch("cache missing \(artifact.path)")
            }
            let hash = try BaselineHashing.sha256Hex(ofFileAt: cachedURL)
            guard hash == artifact.sha256 else {
                throw BaselineInputError.hashMismatch("cache \(artifact.path)")
            }
        }

        let samples = try BaselineAudioLoader.loadMono16kInt16Samples(from: fixtureURL)
        let decodedSeconds = Double(samples.count) / 16_000
        guard !samples.isEmpty, abs(decodedSeconds - manifest.fixture.durationSeconds) < 1.0 else {
            throw BaselineInputError.fixtureMetadataMismatch("decoded \(decodedSeconds)s")
        }

        for round in 0..<Self.pairRoundCount {
            try Task.checkCancellation()
            let order: [BaselineArm] = round.isMultiple(of: 2) ? [.legacy, .meeting] : [.meeting, .legacy]
            var roundRecords: [BaselineArm: ASRBaselineReport.RunRecord] = [:]
            for (orderIndex, arm) in order.enumerated() {
                var (record, box) = try await self.runArm(
                    arm,
                    orderIndex: orderIndex,
                    round: round,
                    samples: samples
                )
                // Providers must never overlap: gate the next arm on this provider's dealloc.
                record.providerDeallocated = try await self.waitForProviderDealloc(box, budget: Self.deallocBudget)
                record.memoryAfterDeallocWait = try TaskMemorySnapshot.capture()
                self.partialReport?.runs.append(record)
                if let report = self.partialReport {
                    self.attachReport(report)
                }
                print(Self.progressLine(for: record))
                guard record.providerDeallocated else {
                    throw BaselineInputError.providerDidNotDeallocate
                }
                roundRecords[arm] = record
                try Task.checkCancellation()
            }
            if let legacy = roundRecords[.legacy], let meeting = roundRecords[.meeting] {
                self.partialReport?.comparisons.append(
                    Self.compare(legacy: legacy, meeting: meeting, round: round)
                )
            }
        }
        self.partialReport?.note = "complete"
        if let report = self.partialReport {
            self.attachReport(report)
        }
    }

    /// Run-scoped: the provider is created, used, and left to die inside this frame; only plain
    /// value copies (no provider or ASR-library references) cross the return boundary.
    private func runArm(
        _ arm: BaselineArm,
        orderIndex: Int,
        round: Int,
        samples: [Float]
    ) async throws -> (ASRBaselineReport.RunRecord, WeakProviderBox) {
        try Task.checkCancellation()
        let box = WeakProviderBox()
        let sampler = MemoryPeakSampler()
        let before = try TaskMemorySnapshot.capture()
        try sampler.start()
        defer { sampler.stopAndJoin() }

        let provider: FluidAudioProvider
        switch arm {
        case .legacy:
            provider = FluidAudioProvider(
                modelOverride: .parakeetTDTv2,
                configureWordBoosting: false,
                enhancementOptions: FluidAudioProviderEnhancementOptions(
                    experimentalUnifiedFinalEnabled: false,
                    pronunciationMatchingEnabled: false,
                    customDictionaryEntries: []
                )
            )
        case .meeting:
            provider = try FluidAudioProvider(meetingConfiguration: MeetingFinalProcessingConfiguration())
        }
        box.provider = provider
        guard provider.modelsExistOnDisk() else {
            throw BaselineInputError.modelsMissingOnDisk
        }

        let clock = ContinuousClock()
        let prepareStart = clock.now
        try await provider.prepare()
        try Task.checkCancellation()
        let inferenceStart = clock.now
        let outcome = try await provider.transcribeWithWordTimings(samples)
        try Task.checkCancellation()
        let inferenceEnd = clock.now

        guard sampler.stopAndJoin() else {
            throw BaselineInputError.memorySamplerDidNotStop
        }
        try sampler.checkCaptureError()
        let after = try TaskMemorySnapshot.capture()

        let transcript = outcome.result.text
        let words = outcome.words
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !words.isEmpty else {
            throw BaselineInputError.emptyTranscription(arm.rawValue)
        }
        var previousStart = -Double.infinity
        for word in words {
            guard word.start.isFinite, word.end.isFinite,
                  word.start <= word.end, word.start >= previousStart
            else {
                throw BaselineInputError.invalidWordTimings(arm.rawValue)
            }
            previousStart = word.start
        }

        let record = ASRBaselineReport.RunRecord(
            round: round,
            orderInRound: orderIndex,
            arm: arm.rawValue,
            prepareSeconds: Self.seconds(from: prepareStart, to: inferenceStart),
            inferenceSeconds: Self.seconds(from: inferenceStart, to: inferenceEnd),
            memoryBefore: before,
            memoryPeakDuringRun: sampler.peak,
            memoryAfterReturn: after,
            memoryAfterDeallocWait: nil,
            providerDeallocated: false,
            transcript: transcript,
            words: words.map {
                ASRBaselineReport.WordRecord(text: $0.text, start: $0.start, end: $0.end)
            }
        )
        return (record, box)
    }
    #endif

    private func validateSandboxEnvironment() throws {
        guard Bundle.main.bundleIdentifier == Self.hostBundleIdentifier else {
            throw BaselineInputError.sandboxEnvironment(
                "host bundle id=\(Bundle.main.bundleIdentifier ?? "nil")"
            )
        }
        if let application = NSApp {
            guard application.delegate == nil else {
                throw BaselineInputError.sandboxEnvironment("host must not install an app delegate")
            }
            guard application.windows.isEmpty else {
                throw BaselineInputError.sandboxEnvironment("host must not create windows")
            }
        }
        let canonicalHome = BaselinePathSafety.canonical(
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        )
        let containerMarker = ["Library", "Containers", Self.hostBundleIdentifier, "Data"]
        guard Self.containsContiguous(canonicalHome.pathComponents, marker: containerMarker) else {
            throw BaselineInputError.sandboxEnvironment(
                "home is not the \(Self.hostBundleIdentifier) container Data directory"
            )
        }
    }

    /// Bounded poll on an unstructured (uncancelled) task; caller re-checks cancellation after cleanup, before any leak error.
    private func waitForProviderDealloc(_ box: WeakProviderBox, budget: Duration) async throws -> Bool {
        let deallocated = await Task { @MainActor in
            let clock = ContinuousClock()
            let deadline = clock.now + budget
            while box.provider != nil, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return box.provider == nil
        }.value
        try Task.checkCancellation()
        return deallocated
    }

    private static func compare(
        legacy: ASRBaselineReport.RunRecord,
        meeting: ASRBaselineReport.RunRecord,
        round: Int
    ) -> ASRBaselineReport.PairComparison {
        var maxStartDelta = 0.0
        var maxEndDelta = 0.0
        for (legacyWord, meetingWord) in zip(legacy.words, meeting.words) {
            maxStartDelta = max(maxStartDelta, abs(legacyWord.start - meetingWord.start))
            maxEndDelta = max(maxEndDelta, abs(legacyWord.end - meetingWord.end))
        }
        return ASRBaselineReport.PairComparison(
            round: round,
            transcriptMatches: legacy.transcript == meeting.transcript,
            wordTextsMatch: legacy.words.map(\.text) == meeting.words.map(\.text),
            legacyWordCount: legacy.words.count,
            meetingWordCount: meeting.words.count,
            maxWordStartDeltaSeconds: maxStartDelta,
            maxWordEndDeltaSeconds: maxEndDelta
        )
    }

    private static func progressLine(for record: ASRBaselineReport.RunRecord) -> String {
        let peakResidentMB = Double(record.memoryPeakDuringRun.residentBytes) / 1_048_576
        let peakFootprintMB = Double(record.memoryPeakDuringRun.footprintBytes) / 1_048_576
        return String(
            format: "ASR_BASELINE round=%d/%d arm=%@ order=%d prepare=%.3fs inference=%.3fs peakRSS=%.0fMB peakFootprint=%.0fMB deallocated=%@",
            record.round + 1,
            Self.pairRoundCount,
            record.arm,
            record.orderInRound,
            record.prepareSeconds,
            record.inferenceSeconds,
            peakResidentMB,
            peakFootprintMB,
            record.providerDeallocated ? "yes" : "no"
        )
    }

    private static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let duration = end - start
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func containsContiguous(_ components: [String], marker: [String]) -> Bool {
        guard !marker.isEmpty, marker.count <= components.count else { return false }
        for start in 0...(components.count - marker.count)
        where components[start..<(start + marker.count)].elementsEqual(marker) {
            return true
        }
        return false
    }

    private static func isHex64(_ string: String) -> Bool {
        string.count == 64 && string.allSatisfy(\.isHexDigit)
    }

    private func attachReport(_ report: ASRBaselineReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.lifetime = .keepAlways
        attachment.name = "ASRBaselineReport"
        self.add(attachment)
    }

    /// Fallback attachment for failures before `partialReport` exists.
    private func attachDiagnosticJSON(note: String) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["note": note],
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.lifetime = .keepAlways
        attachment.name = "ASRBaselineReport"
        self.add(attachment)
    }
}

nonisolated enum BaselineArm: String, Sendable {
    case legacy
    case meeting
}

/// Local to the benchmark driver; proves the provider frame released before the next arm starts.
final class WeakProviderBox {
    weak var provider: AnyObject?
}

nonisolated enum BaselineInputError: Error, Equatable {
    case missingInputsRoot
    case invalidManifest(String)
    case unsafeRelativePath(String)
    case hashMismatch(String)
    case fixtureMetadataMismatch(String)
    case sandboxEnvironment(String)
    case unsupportedFixtureFormat(String)
    case modelsMissingOnDisk
    case providerDidNotDeallocate
    case memoryQueryFailed(String)
    case memorySamplerDidNotStop
    case emptyTranscription(String)
    case invalidWordTimings(String)
}

extension BaselineInputError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingInputsRoot:
            return "ASRBaselineInputs not found in host bundle resources"
        case .invalidManifest(let detail):
            return "invalid manifest.json: \(detail)"
        case .unsafeRelativePath(let path):
            return "unsafe relative path: \(path)"
        case .hashMismatch(let label):
            return "sha256 mismatch: \(label)"
        case .fixtureMetadataMismatch(let detail):
            return "fixture metadata mismatch: \(detail)"
        case .sandboxEnvironment(let detail):
            return "sandbox environment check failed: \(detail)"
        case .unsupportedFixtureFormat(let detail):
            return "unsupported fixture format: \(detail)"
        case .modelsMissingOnDisk:
            return "model cache incomplete before prepare"
        case .providerDidNotDeallocate:
            return "provider still alive after the 2s dealloc budget"
        case .memoryQueryFailed(let detail):
            return "memory query failed: \(detail)"
        case .memorySamplerDidNotStop:
            return "memory peak sampler failed to join within the 2s deadline"
        case .emptyTranscription(let arm):
            return "empty transcript or word timings: \(arm)"
        case .invalidWordTimings(let arm):
            return "non-finite or unordered word timings: \(arm)"
        }
    }
}

nonisolated struct ASRBaselineManifest: Codable, Sendable, Equatable {
    struct Fixture: Codable, Sendable, Equatable {
        var path: String
        var sha256: String
        var sampleRateHz: Int
        var channels: Int
        var durationSeconds: Double
    }

    struct Artifact: Codable, Sendable, Equatable {
        var path: String
        var sha256: String
    }

    var schemaVersion: Int
    var modelRepository: String
    var fixture: Fixture
    var artifacts: [Artifact]
}

nonisolated struct TaskMemorySnapshot: Codable, Sendable {
    var residentBytes: UInt64
    var footprintBytes: UInt64

    /// Throws on task_info failure: a silently zeroed snapshot reads as a valid 0.
    static func capture() throws -> TaskMemorySnapshot {
        var basicInfo = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<integer_t>.stride
        )
        let basicResult = withUnsafeMutablePointer(to: &basicInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &basicCount)
            }
        }
        guard basicResult == KERN_SUCCESS else {
            throw BaselineInputError.memoryQueryFailed("MACH_TASK_BASIC_INFO kern_return=\(basicResult)")
        }

        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let vmResult = withUnsafeMutablePointer(to: &vmInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &vmCount)
            }
        }
        guard vmResult == KERN_SUCCESS else {
            throw BaselineInputError.memoryQueryFailed("TASK_VM_INFO kern_return=\(vmResult)")
        }
        return TaskMemorySnapshot(residentBytes: basicInfo.resident_size, footprintBytes: vmInfo.phys_footprint)
    }
}

nonisolated struct ASRBaselineReport: Codable, Sendable {
    struct WordRecord: Codable, Sendable, Equatable {
        var text: String
        var start: Double
        var end: Double
    }

    struct RunRecord: Codable, Sendable {
        var round: Int
        var orderInRound: Int
        var arm: String
        var prepareSeconds: Double
        var inferenceSeconds: Double
        var memoryBefore: TaskMemorySnapshot
        var memoryPeakDuringRun: TaskMemorySnapshot
        var memoryAfterReturn: TaskMemorySnapshot
        var memoryAfterDeallocWait: TaskMemorySnapshot?
        var providerDeallocated: Bool
        var transcript: String
        var words: [WordRecord]
    }

    struct PairComparison: Codable, Sendable {
        var round: Int
        var transcriptMatches: Bool
        var wordTextsMatch: Bool
        var legacyWordCount: Int
        var meetingWordCount: Int
        var maxWordStartDeltaSeconds: Double
        var maxWordEndDeltaSeconds: Double
    }

    var schemaVersion: Int
    var testKind: String
    var syntheticScope: String
    var policy: String
    var timestamp: String
    var modelRepository: String
    var fixtureSHA256: String
    var fixtureSampleRateHz: Int
    var fixtureChannels: Int
    var fixtureDurationSeconds: Double
    var runs: [RunRecord]
    var comparisons: [PairComparison]
    var note: String
}

/// NSLock + dedicated Thread so peak sampling never depends on the cooperative pool. Peak
/// between 5ms polls is approximate; Core ML caches may outlive the provider without leaking.
final class MemoryPeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peakResidentBytes: UInt64 = 0
    private var peakFootprintBytes: UInt64 = 0
    private var stopRequested = false
    private var firstCaptureError: Error?
    private var worker: Thread?
    private let completion = DispatchGroup()
    private static let joinTimeout: DispatchTimeInterval = .seconds(2)

    /// Seeds the peak with a valid snapshot so a pre-first-poll read never reports a fake 0.
    func start() throws {
        let seed = try TaskMemorySnapshot.capture()
        self.lock.lock()
        self.peakResidentBytes = seed.residentBytes
        self.peakFootprintBytes = seed.footprintBytes
        self.stopRequested = false
        self.firstCaptureError = nil
        self.lock.unlock()
        self.completion.enter()
        let thread = Thread { [self] in
            defer { self.completion.leave() }
            while !self.consumeStopRequest() {
                do {
                    let sample = try TaskMemorySnapshot.capture()
                    self.lock.lock()
                    self.peakResidentBytes = max(self.peakResidentBytes, sample.residentBytes)
                    self.peakFootprintBytes = max(self.peakFootprintBytes, sample.footprintBytes)
                    self.lock.unlock()
                } catch {
                    self.lock.lock()
                    if self.firstCaptureError == nil {
                        self.firstCaptureError = error
                    }
                    self.lock.unlock()
                    break
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        thread.name = "asr-baseline-memory-peak"
        thread.qualityOfService = .utility
        self.lock.lock()
        self.worker = thread
        self.lock.unlock()
        thread.start()
    }

    /// Real-deadline join on the worker's completion group; idempotent. False = caller must fail the run.
    @discardableResult
    func stopAndJoin() -> Bool {
        self.lock.lock()
        self.stopRequested = true
        let worker = self.worker
        self.lock.unlock()
        guard worker != nil else { return true }
        let joined = self.completion.wait(timeout: .now() + Self.joinTimeout) == .success
        guard joined else { return false }
        self.lock.lock()
        self.worker = nil
        self.lock.unlock()
        return true
    }

    /// Rethrows the first poll error recorded by the worker, if any; call after a joined stop.
    func checkCaptureError() throws {
        self.lock.lock()
        let error = self.firstCaptureError
        self.lock.unlock()
        if let error {
            throw error
        }
    }

    var peak: TaskMemorySnapshot {
        self.lock.lock()
        defer { self.lock.unlock() }
        return TaskMemorySnapshot(
            residentBytes: self.peakResidentBytes,
            footprintBytes: self.peakFootprintBytes
        )
    }

    private func consumeStopRequest() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.stopRequested
    }
}

nonisolated enum BaselinePathSafety {
    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Component-wise containment: raw string prefixes accept sibling names like `X-evil`.
    static func isStrictDescendant(_ child: URL, of ancestor: URL) -> Bool {
        let ancestorComponents = self.canonical(ancestor).pathComponents
        let childComponents = self.canonical(child).pathComponents
        guard ancestorComponents.count < childComponents.count else { return false }
        return Array(childComponents.prefix(ancestorComponents.count)) == ancestorComponents
    }

    static func validatedURL(forRelativePath relativePath: String, under root: URL) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasPrefix("~"),
              !relativePath.contains("\\")
        else {
            throw BaselineInputError.unsafeRelativePath(relativePath)
        }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw BaselineInputError.unsafeRelativePath(relativePath)
        }
        let canonicalRoot = self.canonical(root)
        let rootPath = canonicalRoot.path
        var currentPath = rootPath
        for part in parts {
            currentPath = (currentPath as NSString).appendingPathComponent(String(part))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: currentPath)) != nil {
                throw BaselineInputError.unsafeRelativePath(relativePath)
            }
            currentPath = (currentPath as NSString).standardizingPath
            guard currentPath == rootPath || currentPath.hasPrefix(rootPath + "/") else {
                throw BaselineInputError.unsafeRelativePath(relativePath)
            }
        }
        let resolved = self.canonical(URL(fileURLWithPath: currentPath))
        guard self.isStrictDescendant(resolved, of: canonicalRoot) else {
            throw BaselineInputError.unsafeRelativePath(relativePath)
        }
        return resolved
    }
}

nonisolated enum BaselineHashing {
    /// Streams in 1 MiB chunks; the artifact set includes multi-hundred-MB model files.
    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum BaselineInputLoader {
    static func inputsRoot() -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("ASRBaselineInputs", isDirectory: true)
    }

    static func loadManifest(from root: URL) throws -> ASRBaselineManifest {
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ASRBaselineManifest.self, from: data)
        guard manifest.schemaVersion == 1 else {
            throw BaselineInputError.invalidManifest("schemaVersion=\(manifest.schemaVersion)")
        }
        return manifest
    }
}

nonisolated enum BaselineAudioLoader {
    static func loadMono16kInt16Samples(from url: URL) throws -> [Float] {
        // forReading: alone defaults to float32 processing even for an int16 WAV.
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        let format = file.processingFormat
        guard format.channelCount == 1,
              format.sampleRate == 16_000,
              format.commonFormat == .pcmFormatInt16
        else {
            throw BaselineInputError.unsupportedFixtureFormat("\(format)")
        }
        let declaredFrames = file.length
        guard declaredFrames > 0 else {
            throw BaselineInputError.unsupportedFixtureFormat("empty audio file")
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(declaredFrames))
        let scale = Float(1.0 / 32768.0)
        var consumed: AVAudioFramePosition = 0
        while consumed < declaredFrames {
            let remaining = declaredFrames - consumed
            let chunkSize = min(AVAudioFrameCount(remaining), 1_048_576)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
                throw BaselineInputError.unsupportedFixtureFormat("buffer allocation failed")
            }
            try file.read(into: buffer)
            let framesRead = AVAudioFramePosition(buffer.frameLength)
            guard framesRead > 0 else {
                throw BaselineInputError.unsupportedFixtureFormat(
                    "premature EOF at \(consumed)/\(declaredFrames) frames"
                )
            }
            guard let channelData = buffer.int16ChannelData else {
                throw BaselineInputError.unsupportedFixtureFormat("no int16 channel data")
            }
            for index in 0..<Int(framesRead) {
                samples.append(Float(channelData[0][index]) * scale)
            }
            consumed += framesRead
        }
        guard consumed == declaredFrames, samples.count == declaredFrames else {
            throw BaselineInputError.fixtureMetadataMismatch(
                "decoded \(consumed) frames, expected \(declaredFrames)"
            )
        }
        return samples
    }
}
