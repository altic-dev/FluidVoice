import CoreMedia
@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Stage C2b2 of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md`: the wired canonical path —
/// manifest built under the pipeline's serialization lease, handed to the backend, assembled with
/// product echo verdicts, persisted as a verified result sidecar, and published by the
/// coordinator only inside the session save that precedes checkpoint removal.
///
/// No fixture writes real audio: the manifest builder's observation boundary is faked per chunk,
/// and fixture backends derive their evidence from the manifest they are handed, so every unit,
/// receipt and span reference is one the validator actually proved.
@MainActor
final class MeetingCanonicalPipelineTests: XCTestCase {
    private static let canonicalBackendID = MeetingBackendID(rawValue: "fixture.canonical-c2b2")

    // MARK: - Fixtures

    private actor Latch {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            if self.isOpen { return }
            await withCheckedContinuation { self.waiters.append($0) }
        }

        func open() {
            self.isOpen = true
            let parked = self.waiters
            self.waiters.removeAll()
            for continuation in parked {
                continuation.resume()
            }
        }
    }

    private struct FixtureObserver: MeetingChunkAudioObserving {
        let results: [MeetingAnalysisChunkKey: MeetingChunkObservationResult]

        func observe(
            chunk: MeetingAudioChunk,
            trackID: MeetingAudioTrackID
        ) -> MeetingChunkObservationResult {
            self.results[MeetingAnalysisChunkKey(trackID: trackID, chunkID: chunk.id)]
                ?? .failed(.unreadable, detail: "no fixture observation")
        }
    }

    private final class RecordingObserver: MeetingChunkAudioObserving, @unchecked Sendable {
        private(set) var callCount = 0

        func observe(
            chunk: MeetingAudioChunk,
            trackID: MeetingAudioTrackID
        ) -> MeetingChunkObservationResult {
            self.callCount += 1
            return .failed(.unreadable, detail: "must not be called on this path")
        }
    }

    private final class FixtureEchoProvider: MeetingUnitEchoVerdictProviding, @unchecked Sendable {
        var verdicts: [String: MeetingUnitEchoVerdict]
        var gate: Latch?
        var onInvoked: (() -> Void)?
        private(set) var callCount = 0

        init(verdicts: [String: MeetingUnitEchoVerdict] = [:]) {
            self.verdicts = verdicts
        }

        func echoVerdicts(
            for _: MeetingFinalTranscriptEvidence,
            manifest _: MeetingAnalysisManifest,
            plan _: MeetingBackendPlan
        ) async throws -> [String: MeetingUnitEchoVerdict] {
            self.callCount += 1
            self.onInvoked?()
            if let gate { await gate.wait() }
            return self.verdicts
        }
    }

    private final class CanonicalFixtureBackend: MeetingTranscriptionBackend {
        let descriptor: MeetingBackendDescriptor
        private let makeBundle: @MainActor (MeetingBackendPlan, MeetingAnalysisManifest) throws -> MeetingCanonicalResultBundle
        var gate: Latch?
        var onEnterExecute: (() -> Void)?
        private(set) var executeCallCount = 0
        private(set) var receivedManifest: MeetingAnalysisManifest??

        init(
            version: String = "c2b2-test",
            makeBundle: @escaping @MainActor (MeetingBackendPlan, MeetingAnalysisManifest) throws -> MeetingCanonicalResultBundle
        ) {
            self.descriptor = MeetingBackendDescriptor(
                id: MeetingCanonicalPipelineTests.canonicalBackendID,
                version: version,
                execution: .local,
                supportedLanguageCodes: ["en"],
                supportedTrackKinds: Set(MeetingAudioTrackKind.allCases),
                supportedFinalPrecisions: [.word],
                resultContract: .canonicalEvidence,
                knownLimits: ["Fixture only; performs no inference."]
            )
            self.makeBundle = makeBundle
        }

        func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
            MeetingBackendPlan(request: request, descriptor: self.descriptor)
        }

        func execute(
            plan: MeetingBackendPlan,
            manifest: MeetingAnalysisManifest?,
            progress: @escaping @MainActor (MeetingProcessingStage) -> Void
        ) async throws -> MeetingBackendOutcome {
            self.executeCallCount += 1
            self.receivedManifest = manifest
            self.onEnterExecute?()
            if let gate { await gate.wait() }
            guard let manifest else {
                throw MeetingBackendError.outcomeContractMismatch(
                    backend: self.descriptor.id, declared: .canonicalEvidence
                )
            }
            return try .canonicalEvidence(self.makeBundle(plan, manifest))
        }
    }

    private func makeChunk(sequence: Int, start: Double, end: Double) -> MeetingAudioChunk {
        MeetingAudioChunk(
            id: UUID(),
            sequence: sequence,
            relativeFilePath: "tracks/microphone/chunk_\(sequence).caf",
            presentationStart: MeetingMediaTime(value: Int64((start * 1000).rounded()), timescale: 1000),
            presentationEnd: MeetingMediaTime(value: Int64((end * 1000).rounded()), timescale: 1000),
            discontinuities: [],
            sha256: String(repeating: "a", count: 64),
            byteCount: 1024,
            finalizationState: .finalized
        )
    }

    private func makeObserved(
        _ chunk: MeetingAudioChunk,
        duration: Double
    ) -> MeetingChunkObservationResult {
        .observed(MeetingChunkObservedAudio(
            byteCount: chunk.byteCount,
            sha256: chunk.sha256,
            decoded: MeetingChunkDecodedFacts(
                sampleRate: 100,
                channelCount: 1,
                frameCount: Int64((duration * 100).rounded()),
                durationSeconds: duration,
                codecPriming: .measuredFrames(0),
                processingFormatDescription: "fixture"
            )
        ))
    }

    private func makeMicTrack(chunks: [MeetingAudioChunk], eraStart: Double) -> MeetingAudioTrack {
        MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "microphone",
            sourceDisplayName: "microphone",
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 7,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: chunks,
            captureMethod: .voiceProcessing,
            captureEras: [MeetingCaptureEra(
                method: .voiceProcessing,
                deviceUID: "mic-a",
                deviceName: "mic-a",
                roleAtElection: .unknown,
                echoProtection: .voiceProcessed,
                startSeconds: eraStart
            )]
        )
    }

    private func makeSession(
        mode: MeetingCaptureMode,
        tracks: [MeetingAudioTrack],
        openAttempt: Bool = true
    ) -> MeetingSession {
        var session = MeetingSession(
            configuration: MeetingCaptureConfiguration(
                mode: mode,
                title: "Canonical fixture",
                application: mode == .onlineCall
                    ? MeetingApplicationIdentity(bundleIdentifier: "fixture.app", displayName: "Fixture")
                    : nil,
                microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic-a", displayName: "Mic")
            ),
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 7,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            )
        )
        session.audioTracks = tracks
        if openAttempt {
            session.processingAttempts = [MeetingProcessingAttempt(
                id: UUID(),
                startedAt: Date(timeIntervalSinceNow: -30),
                completedAt: nil,
                stage: .pending,
                pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
                asrProvider: nil,
                asrModel: nil,
                diarizationModel: nil,
                lastCompletedTrackID: nil,
                errorCode: nil
            )]
        }
        return session
    }

    private func makeInRoomFixture() -> (
        session: MeetingSession,
        track: MeetingAudioTrack,
        chunk: MeetingAudioChunk
    ) {
        let chunk = self.makeChunk(sequence: 0, start: 100, end: 110)
        let track = self.makeMicTrack(chunks: [chunk], eraStart: 100)
        return (self.makeSession(mode: .inRoom, tracks: [track]), track, chunk)
    }

    /// Deterministic bundle derived from the manifest the pipeline handed over: one word per
    /// admissible span, one processed receipt tiling each span.
    private func standardBundle(
        plan: MeetingBackendPlan,
        manifest: MeetingAnalysisManifest,
        text: String = "hello"
    ) -> MeetingCanonicalResultBundle {
        let receipts = manifest.allSpans.enumerated().map { index, span in
            MeetingSpanCoverageReceipt(
                id: "receipt-\(index)",
                spanID: span.id,
                analysisStart: span.analysisInterval.start,
                analysisEnd: span.analysisInterval.end,
                status: .processed
            )
        }
        let units = manifest.allSpans.enumerated().map { index, span in
            MeetingFinalTextUnit(
                id: "unit-\(index)",
                trackID: span.trackID,
                analysisEpochID: span.analysisEpochID,
                precision: .word,
                text: text,
                analysisStart: span.analysisInterval.start,
                analysisEnd: span.analysisInterval.end,
                speaker: .assigned(MeetingBackendSpeakerToken(
                    analysisEpochID: span.analysisEpochID, label: "slot-0"
                )),
                analysisSpanIDs: [span.id]
            )
        }
        return MeetingCanonicalResultBundle(
            evidence: MeetingFinalTranscriptEvidence(
                backendID: plan.backendID,
                attemptID: plan.attemptID,
                units: units
            ),
            coverageReceipts: receipts
        )
    }

    private func makeCanonicalPipeline(
        backend: CanonicalFixtureBackend,
        observer: any MeetingChunkAudioObserving,
        echoProvider: (any MeetingUnitEchoVerdictProviding)? = nil,
        probe: ((MeetingResultSidecarReference) -> Void)? = nil
    ) -> MeetingProcessingPipeline {
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.canonicalBackendID)
        registry.register(Self.canonicalBackendID) { _ in backend }
        return MeetingProcessingPipeline(
            asrServiceProvider: {
                XCTFail("Canonical dispatch must not reach ASR readiness")
                return ASRService()
            },
            managesModelResidency: false,
            serializationGate: MeetingProcessingSerializationGate(),
            backendRegistry: registry,
            backendID: nil,
            chunkObserver: observer,
            echoVerdictProvider: echoProvider,
            canonicalSidecarVerifiedProbe: probe
        )
    }

    private func makeTempSessionDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("canonical-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func sidecarFiles(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(".sidecar.json") }) ?? []
    }

    // MARK: - Legacy isolation

    func testLegacyBackendBuildsNoManifestWritesNoSidecarAndReturnsUnchangedResult() async throws {
        let fixture = self.makeInRoomFixture()
        let directory = try self.makeTempSessionDirectory()
        let observer = RecordingObserver()
        let echoProvider = FixtureEchoProvider()
        let expected = MeetingProcessingResult(
            speakers: [],
            segments: [MeetingTranscriptSegment(
                id: UUID(),
                start: MeetingMediaTime(value: 100_000, timescale: 1000),
                end: MeetingMediaTime(value: 101_000, timescale: 1000),
                sourceTrackID: fixture.track.id,
                speakerID: nil,
                text: "legacy",
                revision: 0,
                status: .final,
                overlap: .none,
                completeness: .complete
            )],
            attempt: MeetingProcessingAttempt(
                id: UUID(),
                startedAt: Date(),
                completedAt: Date(),
                stage: .completed,
                pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
                asrProvider: "legacy-fixture",
                asrModel: "legacy-fixture",
                diarizationModel: nil,
                lastCompletedTrackID: nil,
                errorCode: nil
            )
        )

        final class LegacyFixtureBackend: MeetingTranscriptionBackend {
            let descriptor = MeetingBackendDescriptor(
                id: MeetingCanonicalPipelineTests.canonicalBackendID,
                version: "legacy-fixture",
                execution: .local,
                supportedLanguageCodes: ["en"],
                supportedTrackKinds: Set(MeetingAudioTrackKind.allCases),
                supportedFinalPrecisions: [.utterance],
                resultContract: .legacyResult,
                knownLimits: []
            )
            let result: MeetingProcessingResult
            private(set) var receivedManifest: MeetingAnalysisManifest??

            init(result: MeetingProcessingResult) {
                self.result = result
            }

            func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
                MeetingBackendPlan(request: request, descriptor: self.descriptor)
            }

            func execute(
                plan: MeetingBackendPlan,
                manifest: MeetingAnalysisManifest?,
                progress: @escaping @MainActor (MeetingProcessingStage) -> Void
            ) async throws -> MeetingBackendOutcome {
                self.receivedManifest = manifest
                return .legacyCompatibility(self.result)
            }
        }
        let backend = LegacyFixtureBackend(result: expected)
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.canonicalBackendID)
        registry.register(Self.canonicalBackendID) { _ in backend }
        let pipeline = MeetingProcessingPipeline(
            asrServiceProvider: {
                XCTFail("Legacy fixture must not load ASR")
                return ASRService()
            },
            managesModelResidency: false,
            serializationGate: MeetingProcessingSerializationGate(),
            backendRegistry: registry,
            backendID: nil,
            chunkObserver: observer,
            echoVerdictProvider: echoProvider
        )

        let result = try await pipeline.process(
            session: fixture.session,
            sessionDirectory: directory,
            progress: { _ in }
        )

        XCTAssertEqual(observer.callCount, 0, "the legacy path must not observe chunks for a manifest")
        XCTAssertEqual(echoProvider.callCount, 0, "the legacy path must not request echo verdicts")
        XCTAssertNil(backend.receivedManifest ?? nil, "the legacy backend receives no manifest")
        XCTAssertTrue(self.sidecarFiles(in: directory).isEmpty, "the legacy path writes no sidecar")
        XCTAssertNil(result.resultSidecarReference)
        XCTAssertEqual(result.segments.map(\.text), ["legacy"])
        XCTAssertEqual(result.attempt.id, expected.attempt.id)
        XCTAssertNil(result.attempt.backendID)
        XCTAssertNil(result.attempt.backendVersion)
    }

    // MARK: - Canonical success and retry

    private func orderedWordResult(attemptID: UUID, words: [(text: String, start: Double, end: Double)]) async throws -> MeetingProcessingResult {
        let fixture = self.makeInRoomFixture()
        var session = fixture.session
        session.processingAttempts[session.processingAttempts.count - 1].id = attemptID
        let backend = CanonicalFixtureBackend { plan, manifest in
            let standard = self.standardBundle(plan: plan, manifest: manifest)
            let span = try XCTUnwrap(manifest.allSpans.first)
            let units = words.enumerated().map { index, word in
                MeetingFinalTextUnit(
                    id: "unit:\(plan.attemptID.uuidString):\(index)", trackID: span.trackID,
                    analysisEpochID: span.analysisEpochID, precision: .word, text: word.text,
                    analysisStart: span.analysisInterval.start + word.start,
                    analysisEnd: span.analysisInterval.start + word.end,
                    speaker: .assigned(.init(analysisEpochID: span.analysisEpochID, label: "slot-0")),
                    analysisSpanIDs: [span.id]
                )
            }
            return MeetingCanonicalResultBundle(
                evidence: .init(backendID: plan.backendID, attemptID: plan.attemptID, units: units),
                coverageReceipts: standard.coverageReceipts
            )
        }
        let pipeline = self.makeCanonicalPipeline(
            backend: backend,
            observer: FixtureObserver(results: [
                MeetingAnalysisChunkKey(trackID: fixture.track.id, chunkID: fixture.chunk.id):
                    self.makeObserved(fixture.chunk, duration: 10),
            ])
        )
        return try await pipeline.process(session: session, sessionDirectory: self.makeTempSessionDirectory(), progress: { _ in })
    }

    func testEqualTimestampWordsPreserveSourceOrderAcrossAttemptIDs() async throws {
        // More than ten units also catches a lexical unit-ID sort (10 before 2).
        let words = (0..<12).map { (text: "word\($0)", start: 0.0, end: 0.2) }
        for ordinal in 1...4 {
            let attemptID = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", ordinal)))
            let result = try await self.orderedWordResult(attemptID: attemptID, words: words)
            XCTAssertEqual(result.segments.count, 1)
            XCTAssertEqual(result.segments.first?.text, words.map(\.text).joined(separator: " "))
        }
    }

    func testDifferentTimestampWordsRemainChronologicalDespiteSourceOrder() async throws {
        let result = try await self.orderedWordResult(attemptID: UUID(), words: [
            (text: "third", start: 0.4, end: 0.6),
            (text: "first", start: 0.0, end: 0.2),
            (text: "second", start: 0.2, end: 0.4),
        ])
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments.first?.text, "first second third")
    }

    private actor CheckpointFailureSummaryProvider: MeetingPostProcessingProviding {
        nonisolated let providerID = "checkpoint-fixture"
        nonisolated let modelID = "summary-fixture"
        nonisolated let maximumInputCharacters = 100_000
        let cancelsDuringReadiness: Bool
        private(set) var readinessCalls = 0
        private(set) var preparationCalls = 0
        private(set) var unloadCalls = 0

        init(cancelsDuringReadiness: Bool = false) {
            self.cancelsDuringReadiness = cancelsDuringReadiness
        }

        func isReady() async throws -> Bool {
            self.readinessCalls += 1
            if self.cancelsDuringReadiness { withUnsafeCurrentTask { $0?.cancel() } }
            return true
        }

        func prepare() async throws -> any PreparedMeetingPostProcessor {
            self.preparationCalls += 1
            throw MeetingPostProcessingError.notReady
        }

        func cancelAndUnload() async { self.unloadCalls += 1 }
    }

    func testCancellationDuringSummaryReadinessSkipsPreparationAndCleansUp() async throws {
        let fixture = self.makeInRoomFixture()
        let directory = try self.makeTempSessionDirectory()
        let backend = CanonicalFixtureBackend { plan, manifest in
            self.standardBundle(plan: plan, manifest: manifest)
        }
        let pipeline = self.makeCanonicalPipeline(
            backend: backend,
            observer: FixtureObserver(results: [
                MeetingAnalysisChunkKey(trackID: fixture.track.id, chunkID: fixture.chunk.id):
                    self.makeObserved(fixture.chunk, duration: 10),
            ])
        )
        let transcript = try await pipeline.process(session: fixture.session, sessionDirectory: directory, progress: { _ in })
        let owner = MeetingModelResidencyCoordinator()
        let registry = MeetingPostProcessingRegistry(residency: owner)
        let provider = CheckpointFailureSummaryProvider(cancelsDuringReadiness: true)
        let artifact = try await Task {
            try await owner.withExclusive(attemptID: transcript.attempt.id, participants: [], acceptsCompletedCancellation: { $0 != nil }) {
                await registry.process(
                    sessionID: fixture.session.id, language: "en", result: transcript,
                    directory: directory, provider: provider
                )
            }
        }.value
        XCTAssertNil(artifact?.output)
        XCTAssertNotNil(artifact?.error)
        XCTAssertEqual(artifact?.attemptID, transcript.attempt.id)
        let readinessCalls = await provider.readinessCalls
        let preparationCalls = await provider.preparationCalls
        let unloadCalls = await provider.unloadCalls
        XCTAssertEqual(readinessCalls, 1)
        XCTAssertEqual(preparationCalls, 0, "Cancellation during readiness must not load the summary model")
        XCTAssertEqual(unloadCalls, 1)
        XCTAssertFalse(owner.isExclusive)
        XCTAssertFalse(Task.isCancelled, "Fixture cancellation must stay inside its child task")
    }

    func testSummaryCheckpointFailurePreservesCanonicalTranscriptAndSkipsModelLoad() async throws {
        let fixture = self.makeInRoomFixture()
        let directory = try self.makeTempSessionDirectory()
        let backend = CanonicalFixtureBackend { plan, manifest in
            self.standardBundle(plan: plan, manifest: manifest)
        }
        let pipeline = self.makeCanonicalPipeline(
            backend: backend,
            observer: FixtureObserver(results: [
                MeetingAnalysisChunkKey(trackID: fixture.track.id, chunkID: fixture.chunk.id):
                    self.makeObserved(fixture.chunk, duration: 10),
            ])
        )
        let transcript = try await pipeline.process(session: fixture.session, sessionDirectory: directory, progress: { _ in })
        XCTAssertFalse(transcript.segments.isEmpty)
        let checkpointURL = directory.appendingPathComponent("transcript-\(transcript.attempt.id.uuidString).json")
        try FileManager.default.createDirectory(at: checkpointURL, withIntermediateDirectories: false)
        let owner = MeetingModelResidencyCoordinator()
        let registry = MeetingPostProcessingRegistry(residency: owner)
        let provider = CheckpointFailureSummaryProvider()
        let result = try await owner.withExclusive(attemptID: transcript.attempt.id, participants: []) {
            var result = transcript
            result.postProcessing = await registry.process(
                sessionID: fixture.session.id, language: "en", result: result,
                directory: directory, provider: provider
            )
            return result
        }
        XCTAssertEqual(result.segments, transcript.segments)
        XCTAssertEqual(result.resultSidecarReference, transcript.resultSidecarReference)
        XCTAssertEqual(result.postProcessing?.attemptID, transcript.attempt.id)
        XCTAssertEqual(result.postProcessing?.error, MeetingPostProcessingError.checkpointFailed.localizedDescription)
        XCTAssertNil(result.postProcessing?.output)
        let readinessCalls = await provider.readinessCalls
        let preparationCalls = await provider.preparationCalls
        XCTAssertEqual(readinessCalls, 0)
        XCTAssertEqual(preparationCalls, 0)
        XCTAssertFalse(owner.isExclusive)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("summary-\(transcript.attempt.id.uuidString).json").path
        ))
    }

    func testCanonicalInRoomSuccessPublishesOnlyAfterVerifiedSidecar() async throws {
        let fixture = self.makeInRoomFixture()
        let directory = try self.makeTempSessionDirectory()
        let openAttemptID = try XCTUnwrap(fixture.session.processingAttempts.last?.id)
        let echoProvider = FixtureEchoProvider()
        let backend = CanonicalFixtureBackend { plan, manifest in
            self.standardBundle(plan: plan, manifest: manifest)
        }
        let pipeline = self.makeCanonicalPipeline(
            backend: backend,
            observer: FixtureObserver(results: [
                MeetingAnalysisChunkKey(trackID: fixture.track.id, chunkID: fixture.chunk.id):
                    self.makeObserved(fixture.chunk, duration: 10),
            ]),
            echoProvider: echoProvider
        )

        let result = try await pipeline.process(
            session: fixture.session,
            sessionDirectory: directory,
            progress: { _ in }
        )

        // The backend received the product-owned manifest built from its own frozen plan.
        let manifest = try XCTUnwrap(backend.receivedManifest ?? nil)
        XCTAssertEqual(manifest.attemptID, openAttemptID)
        XCTAssertEqual(manifest.allSpans.count, 1)
        XCTAssertEqual(echoProvider.callCount, 1, "the pipeline obtains verdicts from the provider")

        // The open attempt was reused and finalized with backend/config lineage, not renumbered.
        XCTAssertEqual(result.attempt.id, openAttemptID)
        XCTAssertEqual(result.attempt.startedAt, fixture.session.processingAttempts.last?.startedAt)
        XCTAssertEqual(result.attempt.stage, .completed)
        XCTAssertNotNil(result.attempt.completedAt)
        XCTAssertEqual(result.attempt.backendID, Self.canonicalBackendID.rawValue)
        XCTAssertEqual(result.attempt.backendVersion, "c2b2-test")
        XCTAssertEqual(result.attempt.asrModel, MeetingFinalProcessingConfiguration.defaultASRModel)
        XCTAssertEqual(result.attempt.languageCode, "en")

        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.speakers.count, 1)
        XCTAssertFalse(result.speakers[0].isLocalUser)
        XCTAssertTrue(result.coverageGaps.isEmpty)
        XCTAssertTrue(result.skippedChunkIDs.isEmpty)

        // Publication carries a reference whose content verifies on disk right now.
        let reference = try XCTUnwrap(result.resultSidecarReference)
        let sidecar = try MeetingResultSidecarStore(sessionDirectory: directory).read(
            expectedAttemptID: openAttemptID,
            expectedBackendID: Self.canonicalBackendID,
            reference: reference
        )
        XCTAssertEqual(sidecar.units.map(\.id), ["unit-0"])
        XCTAssertEqual(sidecar.dispositions.map(\.disposition), [.emitted])
        XCTAssertEqual(sidecar.coverageReceipts.count, 1)
        XCTAssertEqual(self.sidecarFiles(in: directory).count, 1)
    }

    func testCanonicalByteIdenticalRetryJoinsExistingSidecar() async throws {
        let fixture = self.makeInRoomFixture()
        let directory = try self.makeTempSessionDirectory()
        let observer = FixtureObserver(results: [
            MeetingAnalysisChunkKey(trackID: fixture.track.id, chunkID: fixture.chunk.id):
                self.makeObserved(fixture.chunk, duration: 10),
        ])
        let backend = CanonicalFixtureBackend { plan, manifest in
            self.standardBundle(plan: plan, manifest: manifest)
        }
        let pipeline = self.makeCanonicalPipeline(
            backend: backend, observer: observer
        )

        let first = try await pipeline.process(
            session: fixture.session, sessionDirectory: directory, progress: { _ in }
        )
        let fileURL = try XCTUnwrap(self.sidecarFiles(in: directory).first)
        let firstBytes = try Data(contentsOf: fileURL)

        // Same session value, same still-open attempt: the retry's output is byte-identical, so
        // the store joins the existing immutable sidecar instead of rewriting it.
        let second = try await pipeline.process(
            session: fixture.session, sessionDirectory: directory, progress: { _ in }
        )

        XCTAssertEqual(second.resultSidecarReference, first.resultSidecarReference)
        XCTAssertEqual(self.sidecarFiles(in: directory).count, 1)
        XCTAssertEqual(try Data(contentsOf: fileURL), firstBytes)
    }

    func testCanonicalConflictingSameAttemptOutputPreservesFirstSidecar() async throws {
        let fixture = self.makeInRoomFixture()
        let directory = try self.makeTempSessionDirectory()
        let observer = FixtureObserver(results: [
            MeetingAnalysisChunkKey(trackID: fixture.track.id, chunkID: fixture.chunk.id):
                self.makeObserved(fixture.chunk, duration: 10),
        ])
        let backend = CanonicalFixtureBackend { plan, manifest in
            self.standardBundle(plan: plan, manifest: manifest)
        }
        let pipeline = self.makeCanonicalPipeline(
            backend: backend, observer: observer
        )
        _ = try await pipeline.process(
            session: fixture.session, sessionDirectory: directory, progress: { _ in }
        )
        let fileURL = try XCTUnwrap(self.sidecarFiles(in: directory).first)
        let firstBytes = try Data(contentsOf: fileURL)

        // Same attempt, different output: never overwrite the immutable first result.
        let conflicting = CanonicalFixtureBackend { plan, manifest in
            self.standardBundle(plan: plan, manifest: manifest, text: "changed")
        }
        let conflictPipeline = self.makeCanonicalPipeline(
            backend: conflicting, observer: observer
        )
        do {
            _ = try await conflictPipeline.process(
                session: fixture.session, sessionDirectory: directory, progress: { _ in }
            )
            XCTFail("Divergent output under the same attempt must be a typed conflict")
        } catch {
            let openAttemptID = try XCTUnwrap(fixture.session.processingAttempts.last?.id)
            XCTAssertEqual(
                error as? MeetingResultSidecarStoreError,
                .conflictingExistingSidecar(attemptID: openAttemptID)
            )
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), firstBytes, "the first sidecar is preserved")
        XCTAssertEqual(self.sidecarFiles(in: directory).count, 1)
    }

    // MARK: - Fail-closed echo evidence

    func testCanonicalOnlineMicrophoneWithoutEchoVerdictsFailsWithoutPublication() async throws {
        let chunk = self.makeChunk(sequence: 0, start: 100, end: 110)
        let track = self.makeMicTrack(chunks: [chunk], eraStart: 100)
        let session = self.makeSession(mode: .onlineCall, tracks: [track])
        let directory = try self.makeTempSessionDirectory()
        let backend = CanonicalFixtureBackend { plan, manifest in
            self.standardBundle(plan: plan, manifest: manifest)
        }
        // No provider injected: the default is fail-closed and supplies no verdicts.
        let pipeline = self.makeCanonicalPipeline(
            backend: backend,
            observer: FixtureObserver(results: [
                MeetingAnalysisChunkKey(trackID: track.id, chunkID: chunk.id):
                    self.makeObserved(chunk, duration: 10),
            ])
        )

        do {
            _ = try await pipeline.process(
                session: session, sessionDirectory: directory, progress: { _ in }
            )
            XCTFail("Online microphone text without echo evidence must not assemble")
        } catch {
            XCTAssertEqual(
                error as? MeetingAssemblyError,
                .missingEchoVerdict(unitID: "unit-0")
            )
        }
        XCTAssertTrue(
            self.sidecarFiles(in: directory).isEmpty,
            "a failed assembly publishes no sidecar"
        )
    }

    // MARK: - Cancellation boundaries

    func testCancellationAfterBackendReturnSuppressesCanonicalPublication() async throws {
        let fixture = self.makeInRoomFixture()
        let directory = try self.makeTempSessionDirectory()
        let entered = Latch()
        let gate = Latch()
        let backend = CanonicalFixtureBackend { plan, manifest in
            self.standardBundle(plan: plan, manifest: manifest)
        }
        backend.gate = gate
        backend.onEnterExecute = { Task { await entered.open() } }
        let pipeline = self.makeCanonicalPipeline(
            backend: backend,
            observer: FixtureObserver(results: [
                MeetingAnalysisChunkKey(trackID: fixture.track.id, chunkID: fixture.chunk.id):
                    self.makeObserved(fixture.chunk, duration: 10),
            ])
        )

        let task = Task {
            try await pipeline.process(
                session: fixture.session, sessionDirectory: directory, progress: { _ in }
            )
        }
        await entered.wait()
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("A non-cooperative backend's late success must be suppressed")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(self.sidecarFiles(in: directory).isEmpty)
    }

    func testCancellationAfterEchoVerdictsSuppressesCanonicalPublication() async throws {
        let fixture = self.makeInRoomFixture()
        let directory = try self.makeTempSessionDirectory()
        let entered = Latch()
        let gate = Latch()
        let echoProvider = FixtureEchoProvider()
        echoProvider.gate = gate
        echoProvider.onInvoked = { Task { await entered.open() } }
        let backend = CanonicalFixtureBackend { plan, manifest in
            self.standardBundle(plan: plan, manifest: manifest)
        }
        let pipeline = self.makeCanonicalPipeline(
            backend: backend,
            observer: FixtureObserver(results: [
                MeetingAnalysisChunkKey(trackID: fixture.track.id, chunkID: fixture.chunk.id):
                    self.makeObserved(fixture.chunk, duration: 10),
            ]),
            echoProvider: echoProvider
        )

        let task = Task {
            try await pipeline.process(
                session: fixture.session, sessionDirectory: directory, progress: { _ in }
            )
        }
        await entered.wait()
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("Cancellation after verdicts must suppress publication")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(self.sidecarFiles(in: directory).isEmpty)
    }

    func testCancellationAfterSidecarWriteSuppressesPublicationAndRetryJoins() async throws {
        let fixture = self.makeInRoomFixture()
        let directory = try self.makeTempSessionDirectory()
        let observer = FixtureObserver(results: [
            MeetingAnalysisChunkKey(trackID: fixture.track.id, chunkID: fixture.chunk.id):
                self.makeObserved(fixture.chunk, duration: 10),
        ])
        let backend = CanonicalFixtureBackend { plan, manifest in
            self.standardBundle(plan: plan, manifest: manifest)
        }
        let cancelBox = CancelBox()
        let pipeline = self.makeCanonicalPipeline(
            backend: backend,
            observer: observer,
            probe: { _ in cancelBox.cancel() }
        )

        let task = Task {
            try await pipeline.process(
                session: fixture.session, sessionDirectory: directory, progress: { _ in }
            )
        }
        cancelBox.cancel = { task.cancel() }
        do {
            _ = try await task.value
            XCTFail("Cancellation after the verified sidecar must suppress publication")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }

        // The verified sidecar stays on disk, unreferenced, and is never deleted silently.
        let fileURL = try XCTUnwrap(self.sidecarFiles(in: directory).first)
        let firstBytes = try Data(contentsOf: fileURL)

        // A byte-identical retry of the same open attempt joins it.
        cancelBox.cancel = {}
        let retry = try await pipeline.process(
            session: fixture.session, sessionDirectory: directory, progress: { _ in }
        )
        XCTAssertNotNil(retry.resultSidecarReference)
        XCTAssertEqual(self.sidecarFiles(in: directory).count, 1)
        XCTAssertEqual(try Data(contentsOf: fileURL), firstBytes)
    }

    // MARK: - Gap reasons and session schema

    func testCoverageGapReasonsMapOneToOneWithoutRelabeling() {
        let expected: [MeetingAssemblyCoverageGapReason: MeetingTranscriptCoverageGapReason] = [
            .inadmissibleCaptureEra: .inadmissibleCaptureEra,
            .missingOrUnreadableAudio: .missingOrUnreadableAudio,
            .processingFailed: .processingFailed,
            .skipped: .processingSkipped,
            .providerTruncated: .providerTruncated,
            .excludedUnitIncompleteCoverage: .excludedUnitIncompleteCoverage,
        ]
        XCTAssertEqual(
            Set(MeetingAssemblyCoverageGapReason.allCases),
            Set(expected.keys),
            "every assembly reason needs an explicit product mapping"
        )
        for (assemblyReason, productReason) in expected {
            XCTAssertEqual(
                MeetingProcessingPipeline.productCoverageGapReason(for: assemblyReason),
                productReason
            )
        }
        // Only an excluded capture era may wear the pre-existing unprotected-microphone label.
        let mapped = Set(expected.values)
        XCTAssertEqual(mapped.count, expected.count)
    }

    func testOldSessionJSONDecodesNilSidecarReferenceAndNewReferenceRoundTrips() throws {
        let fixture = self.makeInRoomFixture()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Sessions written before canonical publication carry no key at all.
        let data = try encoder.encode(fixture.session)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["resultSidecarReference"])
        let legacyDecoded = try decoder.decode(MeetingSession.self, from: data)
        XCTAssertNil(legacyDecoded.resultSidecarReference)

        var published = fixture.session
        published.resultSidecarReference = MeetingResultSidecarReference(
            formatVersion: MeetingResultSidecarReferenceSchema.currentVersion,
            fileName: "result-\(UUID().uuidString).sidecar.json",
            sha256: String(repeating: "b", count: 64),
            byteCount: 128
        )
        let roundTrip = try decoder.decode(
            MeetingSession.self,
            from: encoder.encode(published)
        )
        XCTAssertEqual(roundTrip.resultSidecarReference, published.resultSidecarReference)
    }

    // MARK: - Coordinator publication transaction

    private actor RecordingSessionStore: MeetingSessionStoring {
        struct SaveFailure: Error {}
        private let wrapped: MeetingSessionStore
        private(set) var saves: [(state: MeetingSessionState, checkpointExisted: Bool, persisted: Bool)] = []
        private var failCompletedSaves = false

        init(wrapping wrapped: MeetingSessionStore) {
            self.wrapped = wrapped
        }

        func setFailCompletedSaves(_ value: Bool) {
            self.failCompletedSaves = value
        }

        func create(_ session: MeetingSession) async throws {
            try await self.wrapped.create(session)
        }

        func save(_ session: MeetingSession) async throws {
            let directory = try await self.wrapped.sessionDirectory(for: session.id)
            let checkpointExisted = FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("checkpoint.json").path
            )
            if self.failCompletedSaves, session.state == .completed {
                self.saves.append((session.state, checkpointExisted, false))
                throw SaveFailure()
            }
            self.saves.append((session.state, checkpointExisted, true))
            try await self.wrapped.save(session)
        }

        func load(id: MeetingSessionID) async throws -> MeetingSession? {
            try await self.wrapped.load(id: id)
        }

        func loadAll() async throws -> [MeetingSession] {
            try await self.wrapped.loadAll()
        }

        func loadRecoverable() async throws -> [MeetingSession] {
            try await self.wrapped.loadRecoverable()
        }

        func sessionDirectory(for id: MeetingSessionID) async throws -> URL {
            try await self.wrapped.sessionDirectory(for: id)
        }

        func existingSessionDirectory(for id: MeetingSessionID) async throws -> URL? {
            try await self.wrapped.existingSessionDirectory(for: id)
        }

        func delete(id: MeetingSessionID) async throws {
            try await self.wrapped.delete(id: id)
        }

        func deleteAudioFiles(for id: MeetingSessionID) async throws {
            try await self.wrapped.deleteAudioFiles(for: id)
        }
    }

    private final class StubCapture: MeetingCaptureControlling, @unchecked Sendable {
        func preflightPermissions() async throws {}

        func start(
            session _: MeetingSession,
            configuration _: MeetingCaptureConfiguration,
            sessionDirectory _: URL,
            eventHandler _: @escaping @Sendable (MeetingCaptureEvent) -> Void,
            liveAudioHandler _: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?
        ) async throws -> MeetingCaptureStartResult {
            MeetingCaptureStartResult(tracks: [], firstPresentationTime: nil)
        }

        func stop(sessionID _: MeetingSessionID) async throws -> MeetingCaptureStopResult {
            MeetingCaptureStopResult(tracks: [], stoppedAt: Date())
        }

        func shutdownForTermination() async {}
    }

    private final class StubArbiter: MeetingAudioActivityArbitrating {
        func acquireMeetingCapture() async throws -> MeetingAudioActivityLease {
            MeetingAudioActivityLease(id: UUID())
        }

        func release(_: MeetingAudioActivityLease) async {}
    }

    private final class SummaryDecoratingPipeline: MeetingProcessingControlling {
        let wrapped: any MeetingProcessingControlling

        init(wrapped: any MeetingProcessingControlling) { self.wrapped = wrapped }

        func process(
            session: MeetingSession,
            sessionDirectory: URL,
            progress: @escaping @MainActor (MeetingProcessingStage) -> Void
        ) async throws -> MeetingProcessingResult {
            var result = try await self.wrapped.process(
                session: session, sessionDirectory: sessionDirectory, progress: progress
            )
            result.postProcessing = MeetingPostProcessingArtifact(
                attemptID: result.attempt.id, transcriptHash: "new-transcript", providerID: "fixture",
                modelID: "fixture-summary", output: .init(summary: "New summary", sourceSegmentIDs: result.segments.map(\.id)),
                error: nil
            )
            return result
        }
    }

    func testCoordinatorSaveFailurePreservesSidecarAndCheckpointThenRetryPublishes() async throws {
        let chunk = self.makeChunk(sequence: 0, start: 100, end: 110)
        let track = self.makeMicTrack(chunks: [chunk], eraStart: 100)
        var session = self.makeSession(mode: .inRoom, tracks: [track], openAttempt: false)
        session.state = .interrupted
        session.endedAt = Date()
        session.recoveryResolvedAt = Date()
        let originalSummary = MeetingPostProcessingArtifact(
            attemptID: UUID(), transcriptHash: "old-transcript", providerID: "fixture",
            modelID: "fixture-summary", output: .init(summary: "Old summary", sourceSegmentIDs: []), error: nil
        )
        session.postProcessing = originalSummary

        let root = try self.makeTempSessionDirectory()
            .appendingPathComponent("meetings", isDirectory: true)
        let recording = RecordingSessionStore(wrapping: MeetingSessionStore(rootDirectory: root))
        try await recording.create(session)
        let directory = try await recording.sessionDirectory(for: session.id)
        let checkpointURL = directory.appendingPathComponent("checkpoint.json")
        try Data("checkpoint".utf8).write(to: checkpointURL)

        let backend = CanonicalFixtureBackend { plan, manifest in
            self.standardBundle(plan: plan, manifest: manifest)
        }
        let coordinator = MeetingSessionCoordinator(
            store: recording,
            capture: StubCapture(),
            processing: SummaryDecoratingPipeline(wrapped: self.makeCanonicalPipeline(
                backend: backend,
                observer: FixtureObserver(results: [
                    MeetingAnalysisChunkKey(trackID: track.id, chunkID: chunk.id):
                        self.makeObserved(chunk, duration: 10),
                ])
            )),
            audioArbiter: StubArbiter()
        )

        // First attempt: the pipeline writes and verifies the sidecar, then the session save
        // fails. Nothing may be published, and the sidecar, checkpoint and source stay intact.
        await recording.setFailCompletedSaves(true)
        do {
            _ = try await coordinator.retryProcessing(sessionID: session.id)
            XCTFail("A failed publication save must surface as a processing failure")
        } catch {
            guard error is RecordingSessionStore.SaveFailure else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        guard case .failed = coordinator.state else {
            return XCTFail("Expected failed state, got \(coordinator.state)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpointURL.path))
        let firstSidecarURL = try XCTUnwrap(self.sidecarFiles(in: directory).first)
        let firstSidecarBytes = try Data(contentsOf: firstSidecarURL)
        let failedRunSaves = await recording.saves
        XCTAssertFalse(
            failedRunSaves.contains { $0.state == .completed && $0.persisted },
            "a failed save must not publish a completed session"
        )
        let savedAfterFailure = try await recording.load(id: session.id)
        XCTAssertEqual(
            savedAfterFailure?.postProcessing,
            originalSummary,
            "Rolling back a transcript must also roll back its summary"
        )
        XCTAssertEqual(savedAfterFailure?.transcriptSegments, session.transcriptSegments)
        XCTAssertEqual(coordinator.activeSession?.postProcessing, originalSummary)

        // Retry: a fresh attempt publishes; the completed-state save still observed the
        // checkpoint on disk, proving the save ran before checkpoint removal.
        await recording.setFailCompletedSaves(false)
        let published = try await coordinator.retryProcessing(sessionID: session.id)
        guard case .completed = coordinator.state else {
            return XCTFail("Expected completed state, got \(coordinator.state)")
        }
        let reference = try XCTUnwrap(published.resultSidecarReference)
        let publishedAttempt = try XCTUnwrap(published.processingAttempts.last {
            $0.backendID == Self.canonicalBackendID.rawValue
        })
        XCTAssertEqual(published.postProcessing?.attemptID, publishedAttempt.id)
        XCTAssertEqual(published.postProcessing?.output?.summary, "New summary")
        let savedAfterRetry = try await recording.load(id: session.id)
        XCTAssertEqual(savedAfterRetry?.postProcessing, published.postProcessing)
        let verified = try MeetingResultSidecarStore(sessionDirectory: directory).read(
            expectedAttemptID: publishedAttempt.id,
            expectedBackendID: Self.canonicalBackendID,
            reference: reference
        )
        XCTAssertEqual(verified.units.map(\.id), ["unit-0"])

        let allSaves = await recording.saves
        XCTAssertTrue(
            allSaves.contains { $0.state == .completed && $0.persisted && $0.checkpointExisted },
            "the session save must run before the checkpoint is removed"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: checkpointURL.path),
            "the checkpoint is removed once publication succeeded"
        )

        // The earlier attempt's unreferenced sidecar was never overwritten or deleted.
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstSidecarURL.path))
        XCTAssertEqual(try Data(contentsOf: firstSidecarURL), firstSidecarBytes)
    }
}

/// Mutable cancellation target the sidecar-verified probe can fire from inside the pipeline task.
private final class CancelBox: @unchecked Sendable {
    var cancel: () -> Void = {}
}
