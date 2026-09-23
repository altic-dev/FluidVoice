import AVFoundation
@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Milestone E of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md`: the composite
/// Parakeet TDT v2 + Nemotron-3 backend. The runtime is faked (no CoreML here); the
/// materializer and pipeline integration tests use real WAV files on disk.
@MainActor
final class MeetingParakeetNemotronBackendTests: XCTestCase {
    // MARK: - Session fixtures

    private func makeChunk(
        sequence: Int,
        start: Double,
        end: Double,
        path: String = "tracks/microphone/chunk_0.caf",
        sha256: String = String(repeating: "a", count: 64),
        byteCount: Int64 = 1024
    ) -> MeetingAudioChunk {
        MeetingAudioChunk(
            id: UUID(),
            sequence: sequence,
            relativeFilePath: path,
            presentationStart: MeetingMediaTime(value: Int64((start * 1000).rounded()), timescale: 1000),
            presentationEnd: MeetingMediaTime(value: Int64((end * 1000).rounded()), timescale: 1000),
            discontinuities: [],
            sha256: sha256,
            byteCount: byteCount,
            finalizationState: .finalized
        )
    }

    private func makeObserved(
        _ chunk: MeetingAudioChunk,
        duration: Double,
        sampleRate: Double = 16_000
    ) -> MeetingChunkObservationResult {
        .observed(MeetingChunkObservedAudio(
            byteCount: chunk.captureAnalysisAsset?.byteCount ?? chunk.byteCount,
            sha256: chunk.captureAnalysisAsset?.sha256 ?? chunk.sha256,
            decoded: MeetingChunkDecodedFacts(
                sampleRate: sampleRate,
                channelCount: 1,
                frameCount: Int64((duration * sampleRate).rounded()),
                durationSeconds: duration,
                codecPriming: chunk.captureAnalysisAsset == nil
                    ? .measuredFrames(0)
                    : .notApplicable(.linearPCMFloat32CAFV1),
                processingFormatDescription: "fixture"
            )
        ))
    }

    private func makePCMChunk(sequence: Int, start: Double, end: Double) -> MeetingAudioChunk {
        let duration = end - start
        let asset = MeetingAudioAsset(
            role: .captureAnalysis,
            encoding: .linearPCMFloat32CAFV1,
            presence: .ready,
            relativeFilePath: "tracks/microphone/analysis-\(sequence).caf",
            byteCount: Int64((duration * 16_000 * 4).rounded()) + 1,
            sha256: String(repeating: "b", count: 64),
            sampleRate: 16_000,
            channelCount: 1,
            frameCount: Int64((duration * 16_000).rounded())
        )
        return MeetingAudioChunk(
            id: UUID(),
            sequence: sequence,
            relativeFilePath: "tracks/microphone/archive-\(sequence).m4a",
            presentationStart: MeetingMediaTime(value: Int64((start * 1000).rounded()), timescale: 1000),
            presentationEnd: MeetingMediaTime(value: Int64((end * 1000).rounded()), timescale: 1000),
            discontinuities: [],
            sha256: String(repeating: "a", count: 64),
            byteCount: 1,
            finalizationState: .finalized,
            audioSchemaVersion: 2,
            captureAnalysisAsset: asset
        )
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

    private func makeAppTrack(chunks: [MeetingAudioChunk]) -> MeetingAudioTrack {
        MeetingAudioTrack(
            id: UUID(),
            kind: .applicationAudio,
            sourceIdentifier: "application",
            sourceDisplayName: "application",
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 7,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: chunks,
            captureMethod: .screenCaptureKit
        )
    }

    private func makeSession(
        mode: MeetingCaptureMode,
        tracks: [MeetingAudioTrack],
        languageCode: String = "en"
    ) -> MeetingSession {
        var session = MeetingSession(
            configuration: MeetingCaptureConfiguration(
                mode: mode,
                title: "Composite fixture",
                languageCode: languageCode,
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
        return session
    }

    private func makeRequest(
        session: MeetingSession,
        directory: URL,
        configuration: MeetingFinalProcessingConfiguration = MeetingFinalProcessingConfiguration(languageCode: "en")
    ) -> MeetingBackendRequest {
        MeetingBackendRequest(
            attemptID: session.processingAttempts.last?.id ?? UUID(),
            session: session,
            sessionDirectory: directory,
            configuration: configuration
        )
    }

    private func makeBackend(
        runtime: FakeRuntime,
        materializer: FakeMaterializer = FakeMaterializer(),
        locator: any MeetingNemotronModelLocating = StubModelLocator()
    ) -> MeetingParakeetNemotronBackend {
        MeetingParakeetNemotronBackend(
            runtimeFactory: { _ in runtime },
            modelLocator: locator,
            materializer: materializer
        )
    }

    private func makeTempSessionDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("composite-backend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeManifest(
        plan: MeetingBackendPlan,
        observations: [MeetingAnalysisChunkKey: MeetingChunkObservationResult]
    ) throws -> MeetingAnalysisManifest {
        try MeetingAnalysisManifestBuilder(
            plan: plan,
            observer: FixtureObserver(results: observations),
            analysisSampleRate: 16_000
        ).build()
    }

    /// Two mic chunks separated by a presentation gap (two epochs) plus one app chunk (one epoch).
    private struct TwoEpochFixture {
        let session: MeetingSession
        let micTrack: MeetingAudioTrack
        let appTrack: MeetingAudioTrack
        let chunks: [MeetingAudioChunk]
        let observations: [MeetingAnalysisChunkKey: MeetingChunkObservationResult]
    }

    private func makeTwoEpochFixture(mode: MeetingCaptureMode = .onlineCall) -> TwoEpochFixture {
        let micChunk0 = self.makeChunk(sequence: 0, start: 100, end: 102, path: "tracks/microphone/chunk_0.caf")
        let micChunk1 = self.makeChunk(sequence: 1, start: 105, end: 107, path: "tracks/microphone/chunk_1.caf")
        let appChunk = self.makeChunk(sequence: 0, start: 100, end: 102, path: "tracks/application/chunk_0.caf")
        let micTrack = self.makeMicTrack(chunks: [micChunk0, micChunk1], eraStart: 100)
        let appTrack = self.makeAppTrack(chunks: [appChunk])
        let session = self.makeSession(mode: mode, tracks: [micTrack, appTrack])
        var observations: [MeetingAnalysisChunkKey: MeetingChunkObservationResult] = [:]
        observations[MeetingAnalysisChunkKey(trackID: micTrack.id, chunkID: micChunk0.id)] = self.makeObserved(micChunk0, duration: 2)
        observations[MeetingAnalysisChunkKey(trackID: micTrack.id, chunkID: micChunk1.id)] = self.makeObserved(micChunk1, duration: 2)
        observations[MeetingAnalysisChunkKey(trackID: appTrack.id, chunkID: appChunk.id)] = self.makeObserved(appChunk, duration: 2)
        return TwoEpochFixture(
            session: session,
            micTrack: micTrack,
            appTrack: appTrack,
            chunks: [micChunk0, micChunk1, appChunk],
            observations: observations
        )
    }

    // MARK: - Registry selection

    func testRegistryUsesCompositeDefaultAndKeepsLegacyRegistered() throws {
        let registry = MeetingTranscriptionBackendRegistry.makeDefault()
        XCTAssertEqual(registry.defaultBackendID, .productionDefault)
        XCTAssertTrue(registry.contains(.parakeetNemotron))
        XCTAssertTrue(registry.contains(.legacyCompatibility))

        let runtime = FakeRuntime()
        let context = MeetingBackendHostContext(
            legacyExecutor: { _, _ in throw MeetingBackendError.unknownBackend(.legacyCompatibility) },
            parakeetNemotronRuntimeFactory: { _ in runtime }
        )
        let backend = try registry.makeBackend(id: .parakeetNemotron, context: context)
        XCTAssertEqual(backend.descriptor.id, .parakeetNemotron)
        XCTAssertEqual(backend.descriptor.resultContract, .canonicalEvidence)
        XCTAssertEqual(backend.descriptor.supportedFinalPrecisions, [.word, .utterance])
        XCTAssertEqual(backend.descriptor.supportedTrackKinds, Set(MeetingAudioTrackKind.allCases))
        XCTAssertEqual(backend.descriptor.supportedLanguageCodes, ["en"])
        XCTAssertEqual(backend.descriptor.execution, .local)
        XCTAssertEqual(backend.descriptor.analysisSampleRate, 16_000)

        let selectedDefault = try registry.makeBackend(id: registry.defaultBackendID, context: context)
        XCTAssertEqual(selectedDefault.descriptor.id, .parakeetNemotron)
    }

    // MARK: - Canonical turn merge (chronological fold)

    private func canonicalSegment(
        id: UUID = UUID(),
        trackID: UUID,
        start: Double,
        end: Double,
        speakerID: UUID?,
        text: String,
        overlap: MeetingTranscriptOverlap = .none,
        status: MeetingTranscriptStatus = .final,
        completeness: MeetingTranscriptCompleteness = .complete,
        isLikelyEcho: Bool? = nil
    ) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(
            id: id,
            start: MeetingMediaTime(value: Int64((start * 1000).rounded()), timescale: 1000),
            end: MeetingMediaTime(value: Int64((end * 1000).rounded()), timescale: 1000),
            sourceTrackID: trackID,
            speakerID: speakerID,
            text: text,
            revision: 0,
            status: status,
            overlap: overlap,
            completeness: completeness,
            isLikelyEcho: isLikelyEcho
        )
    }

    func testCanonicalProductPublicationMergesWordEvidenceIntoTurns() {
        let trackID = UUID()
        let speakerID = UUID()
        let input = [
            self.canonicalSegment(trackID: trackID, start: 0, end: 0.2, speakerID: speakerID, text: "Hello"),
            self.canonicalSegment(trackID: trackID, start: 0.21, end: 0.25, speakerID: speakerID, text: ","),
            self.canonicalSegment(trackID: trackID, start: 0.3, end: 0.6, speakerID: speakerID, text: "world"),
            self.canonicalSegment(trackID: trackID, start: 0.4, end: 0.7, speakerID: UUID(), text: "Other"),
        ]

        let first = MeetingProcessingPipeline.mergeCanonicalSegments(input)
        let second = MeetingProcessingPipeline.mergeCanonicalSegments(input)

        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.first { $0.speakerID == speakerID }?.text, "Hello, world")
        XCTAssertEqual(first.map(\.id), second.map(\.id), "merged turn IDs are deterministic")
    }

    func testCanonicalMergeKeepsABAAsThreeTurnsInsteadOfBridgingAcrossB() {
        let trackID = UUID()
        let speakerA = UUID()
        let speakerB = UUID()
        // A ends at 1.0, B runs 1.2-1.5, A resumes 1.6-2.0. The two A segments are within the
        // 3s gap/30s duration bounds of each other, but B sits chronologically between them on
        // the same track, so they must not bridge across it.
        let input = [
            self.canonicalSegment(trackID: trackID, start: 0, end: 1.0, speakerID: speakerA, text: "First"),
            self.canonicalSegment(trackID: trackID, start: 1.2, end: 1.5, speakerID: speakerB, text: "Interject"),
            self.canonicalSegment(trackID: trackID, start: 1.6, end: 2.0, speakerID: speakerA, text: "Second"),
        ]

        let turns = MeetingProcessingPipeline.mergeCanonicalSegments(input)

        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns.map(\.text), ["First", "Interject", "Second"])
        XCTAssertEqual(turns.map(\.speakerID), [speakerA, speakerB, speakerA])
    }

    func testCanonicalMergeKeepsAAmbiguousAAsThreeTurns() {
        let trackID = UUID()
        let speakerA = UUID()
        // The ambiguous segment has no resolved speaker and a different overlap state, so its
        // key differs from both surrounding A segments even though all three are on one track.
        let input = [
            self.canonicalSegment(trackID: trackID, start: 0, end: 1.0, speakerID: speakerA, text: "First"),
            self.canonicalSegment(
                trackID: trackID, start: 1.1, end: 1.4, speakerID: nil, text: "Maybe", overlap: .ambiguous
            ),
            self.canonicalSegment(trackID: trackID, start: 1.5, end: 2.0, speakerID: speakerA, text: "Second"),
        ]

        let turns = MeetingProcessingPipeline.mergeCanonicalSegments(input)

        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns.map(\.text), ["First", "Maybe", "Second"])
        XCTAssertEqual(turns.map(\.overlap), [.none, .ambiguous, .none])
    }

    func testCanonicalMergeCombinesAdjacentSameKeySegments() {
        let trackID = UUID()
        let speakerA = UUID()
        let input = [
            self.canonicalSegment(trackID: trackID, start: 0, end: 1.0, speakerID: speakerA, text: "First"),
            self.canonicalSegment(trackID: trackID, start: 1.5, end: 2.0, speakerID: speakerA, text: "Second"),
        ]

        let turns = MeetingProcessingPipeline.mergeCanonicalSegments(input)

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.text, "First Second")
        XCTAssertEqual(turns.first?.end.seconds ?? -1, 2.0, accuracy: 0.0001)
    }

    func testCanonicalMergeRespectsMaximumGapBoundary() {
        let trackID = UUID()
        let speakerA = UUID()
        let gap = MeetingProcessingPipeline.canonicalTurnMergeGapSeconds
        let withinBound = [
            self.canonicalSegment(trackID: trackID, start: 0, end: 1.0, speakerID: speakerA, text: "First"),
            self.canonicalSegment(
                trackID: trackID, start: 1.0 + gap, end: 1.0 + gap + 0.5, speakerID: speakerA, text: "Second"
            ),
        ]
        let beyondBound = [
            self.canonicalSegment(trackID: trackID, start: 0, end: 1.0, speakerID: speakerA, text: "First"),
            self.canonicalSegment(
                trackID: trackID,
                start: 1.0 + gap + 0.01,
                end: 1.0 + gap + 0.51,
                speakerID: speakerA,
                text: "Second"
            ),
        ]

        XCTAssertEqual(
            MeetingProcessingPipeline.mergeCanonicalSegments(withinBound).count,
            1,
            "a gap exactly at the named maximum still merges"
        )
        XCTAssertEqual(
            MeetingProcessingPipeline.mergeCanonicalSegments(beyondBound).count,
            2,
            "a gap past the named maximum starts a new turn"
        )
    }

    func testCanonicalMergeRespectsMaximumDurationBoundary() {
        let trackID = UUID()
        let speakerA = UUID()
        let maxDuration = MeetingProcessingPipeline.canonicalTurnMaximumDurationSeconds
        let withinBound = [
            self.canonicalSegment(trackID: trackID, start: 0, end: 1.0, speakerID: speakerA, text: "First"),
            self.canonicalSegment(
                trackID: trackID, start: 1.5, end: maxDuration, speakerID: speakerA, text: "Second"
            ),
        ]
        let beyondBound = [
            self.canonicalSegment(trackID: trackID, start: 0, end: 1.0, speakerID: speakerA, text: "First"),
            self.canonicalSegment(
                trackID: trackID, start: 1.5, end: maxDuration + 0.01, speakerID: speakerA, text: "Second"
            ),
        ]

        XCTAssertEqual(
            MeetingProcessingPipeline.mergeCanonicalSegments(withinBound).count,
            1,
            "a combined duration exactly at the named maximum still merges"
        )
        XCTAssertEqual(
            MeetingProcessingPipeline.mergeCanonicalSegments(beyondBound).count,
            2,
            "a combined duration past the named maximum starts a new turn even with no gap"
        )
    }

    func testCanonicalMergeOrdersTurnsDeterministicallyAcrossTracks() {
        let trackA = UUID()
        let trackB = UUID()
        // Two tracks whose turns interleave in time; publication must be sorted globally by
        // (start, end, sourceTrackID, id), independent of input order. Each segment on a track
        // gets a distinct speaker so none of them merge with each other — this test is about
        // publication order, not turn merging.
        let shuffled = [
            self.canonicalSegment(trackID: trackB, start: 0.5, end: 1.0, speakerID: UUID(), text: "B-second"),
            self.canonicalSegment(trackID: trackA, start: 0, end: 0.4, speakerID: UUID(), text: "A-first"),
            self.canonicalSegment(trackID: trackA, start: 1.2, end: 1.6, speakerID: UUID(), text: "A-second"),
            self.canonicalSegment(trackID: trackB, start: 0, end: 0.3, speakerID: UUID(), text: "B-first"),
        ]

        let first = MeetingProcessingPipeline.mergeCanonicalSegments(shuffled)
        let second = MeetingProcessingPipeline.mergeCanonicalSegments(shuffled.shuffled())
        let expectedIDs = shuffled.sorted {
            ($0.start, $0.end, $0.sourceTrackID.uuidString, $0.id.uuidString)
                < ($1.start, $1.end, $1.sourceTrackID.uuidString, $1.id.uuidString)
        }.map(\.id)

        XCTAssertEqual(first.map(\.id), expectedIDs, "global order uses the documented stable sort key")
        XCTAssertEqual(first.map(\.id), second.map(\.id), "turn IDs are deterministic regardless of input order")
    }

    func testCanonicalMergeNeverCombinesAcrossTracksEvenWithSameSpeakerID() {
        let trackA = UUID()
        let trackB = UUID()
        let speakerID = UUID()
        let turns = MeetingProcessingPipeline.mergeCanonicalSegments([
            self.canonicalSegment(trackID: trackA, start: 0, end: 1, speakerID: speakerID, text: "A"),
            self.canonicalSegment(trackID: trackB, start: 1, end: 2, speakerID: speakerID, text: "B"),
        ])

        XCTAssertEqual(turns.count, 2, "track provenance is a hard merge boundary")
        XCTAssertEqual(Set(turns.map(\.sourceTrackID)), [trackA, trackB])
    }

    // MARK: - Plan validation

    func testPlanRejectsMissingModelUnsupportedLanguageAndUnsupportedOptions() async throws {
        let fixture = self.makeTwoEpochFixture()
        let directory = try self.makeTempSessionDirectory()

        let missingLocator = StubModelLocator(
            error: MeetingNemotronModelReadinessError.modelNotInstalled(path: "/tmp/none.mlpackage")
        )
        let unreadyBackend = self.makeBackend(runtime: FakeRuntime(), locator: missingLocator)
        XCTAssertThrowsError(try unreadyBackend.plan(self.makeRequest(session: fixture.session, directory: directory))) {
            XCTAssertEqual(
                $0 as? MeetingNemotronModelReadinessError,
                .modelNotInstalled(path: "/tmp/none.mlpackage")
            )
        }

        let german = self.makeSession(
            mode: .inRoom,
            tracks: [self.makeMicTrack(chunks: [self.makeChunk(sequence: 0, start: 0, end: 1)], eraStart: 0)],
            languageCode: "de"
        )
        let backend = self.makeBackend(runtime: FakeRuntime())
        XCTAssertThrowsError(try backend.plan(self.makeRequest(session: german, directory: directory))) {
            XCTAssertEqual(
                $0 as? MeetingBackendError,
                .unsupportedLanguage(backend: .parakeetNemotron, languageCode: "de")
            )
        }

        var boosted = MeetingFinalProcessingConfiguration(languageCode: "en")
        boosted = MeetingFinalProcessingConfiguration(
            asrModel: boosted.asrModel,
            languageCode: boosted.languageCode,
            vocabularyBoostingEnabled: true,
            pronunciationMatchingEnabled: boosted.pronunciationMatchingEnabled,
            customDictionaryRewritingEnabled: boosted.customDictionaryRewritingEnabled,
            experimentalUnifiedFinalEnabled: boosted.experimentalUnifiedFinalEnabled,
            diarizationFingerprint: boosted.diarizationFingerprint,
            pipelineVersion: boosted.pipelineVersion
        )
        XCTAssertThrowsError(try backend.plan(self.makeRequest(
            session: fixture.session,
            directory: directory,
            configuration: boosted
        ))) {
            XCTAssertEqual($0 as? MeetingProviderOptionsError, .unsupportedFeature("vocabularyBoosting"))
        }

        let plan = try backend.plan(self.makeRequest(session: fixture.session, directory: directory))
        XCTAssertEqual(plan.resultContract, .canonicalEvidence)
        XCTAssertEqual(plan.declaredFinalPrecisions, [.word, .utterance])
        XCTAssertEqual(Set(plan.chunkIDsByTrackID.keys), [fixture.micTrack.id, fixture.appTrack.id])
    }

    func testExecuteRechecksTheExactArtifactFrozenDuringPlan() async throws {
        let fixture = self.makeTwoEpochFixture()
        let locator = StubModelLocator()
        let runtime = FakeRuntime()
        let backend = self.makeBackend(runtime: runtime, locator: locator)
        let plan = try backend.plan(self.makeRequest(
            session: fixture.session,
            directory: self.makeTempSessionDirectory()
        ))
        let manifest = try self.makeManifest(plan: plan, observations: fixture.observations)
        locator.error = MeetingNemotronModelReadinessError.artifactChanged(
            path: StubModelLocator.artifact.packageURL.path
        )

        await XCTAssertAsyncThrowsError(
            try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        ) { error in
            XCTAssertEqual(
                error as? MeetingNemotronModelReadinessError,
                .artifactChanged(path: StubModelLocator.artifact.packageURL.path)
            )
        }
        XCTAssertEqual(runtime.diarizationScopeCount, 0)
    }

    // MARK: - Host request binding

    /// A fixture backend that asks the host for a runtime against a rewritten request.
    private final class RuntimeStealingBackend: MeetingTranscriptionBackend {
        let descriptor = MeetingBackendDescriptor(
            id: MeetingBackendID(rawValue: "fixture.runtime-stealer"),
            version: "test",
            execution: .local,
            supportedLanguageCodes: ["en"],
            supportedTrackKinds: Set(MeetingAudioTrackKind.allCases),
            supportedFinalPrecisions: [.word],
            resultContract: .canonicalEvidence,
            knownLimits: []
        )
        private let factory: MeetingParakeetNemotronRuntimeFactory

        init(factory: @escaping MeetingParakeetNemotronRuntimeFactory) {
            self.factory = factory
        }

        func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
            MeetingBackendPlan(request: request, descriptor: self.descriptor)
        }

        func execute(
            plan: MeetingBackendPlan,
            manifest _: MeetingAnalysisManifest?,
            progress _: @escaping @MainActor (MeetingProcessingStage) -> Void
        ) async throws -> MeetingBackendOutcome {
            let rewritten = MeetingBackendRequest(
                attemptID: UUID(),
                session: plan.request.session,
                sessionDirectory: plan.request.sessionDirectory,
                configuration: plan.request.configuration
            )
            _ = try self.factory(rewritten)
            throw MeetingBackendError.unknownBackend(self.descriptor.id)
        }
    }

    func testHostBindsRuntimeFactoryToTheFrozenRequest() async throws {
        let fixture = self.makeTwoEpochFixture()
        let directory = try self.makeTempSessionDirectory()
        let openAttemptID = try XCTUnwrap(fixture.session.processingAttempts.last?.id)

        final class RuntimeSpy {
            var requests: [MeetingBackendRequest] = []
        }
        let spy = RuntimeSpy()
        let runtime = FakeRuntime()

        let stealerID = MeetingBackendID(rawValue: "fixture.runtime-stealer")
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: stealerID)
        registry.register(stealerID) { context in
            RuntimeStealingBackend(factory: context.parakeetNemotronRuntimeFactory)
        }
        let stealingPipeline = MeetingProcessingPipeline(
            asrServiceProvider: {
                XCTFail("Canonical dispatch must not reach ASR readiness")
                return ASRService()
            },
            managesModelResidency: false,
            serializationGate: MeetingProcessingSerializationGate(),
            backendRegistry: registry,
            chunkObserver: FixtureObserver(results: fixture.observations),
            meetingRuntimeFactory: { request in
                spy.requests.append(request)
                return runtime
            }
        )
        await XCTAssertAsyncThrowsError(
            try await stealingPipeline.process(session: fixture.session, sessionDirectory: directory) { _ in }
        ) { error in
            XCTAssertEqual(
                error as? MeetingBackendError,
                .hostCapabilityRequestMismatch(backend: stealerID)
            )
        }
        XCTAssertTrue(spy.requests.isEmpty, "a mismatched request must be refused before the factory runs")

        // And the composite backend, which passes its frozen plan's request, gets the runtime.
        let materializer = FakeMaterializer()
        let compositeRegistry = MeetingTranscriptionBackendRegistry(defaultBackendID: .parakeetNemotron)
        compositeRegistry.register(.parakeetNemotron) { context in
            MeetingParakeetNemotronBackend(
                runtimeFactory: context.parakeetNemotronRuntimeFactory,
                modelLocator: StubModelLocator(),
                materializer: materializer
            )
        }
        let pipeline = MeetingProcessingPipeline(
            asrServiceProvider: {
                XCTFail("Canonical dispatch must not reach ASR readiness")
                return ASRService()
            },
            managesModelResidency: false,
            serializationGate: MeetingProcessingSerializationGate(),
            backendRegistry: compositeRegistry,
            chunkObserver: FixtureObserver(results: fixture.observations),
            meetingRuntimeFactory: { request in
                spy.requests.append(request)
                return runtime
            }
        )
        runtime.asrSession.responses = [
            .init(text: "", words: []), .init(text: "", words: []), .init(text: "", words: []),
        ]
        let result = try await pipeline.process(
            session: fixture.session,
            sessionDirectory: directory,
            progress: { _ in }
        )
        XCTAssertEqual(spy.requests.count, 1)
        XCTAssertEqual(spy.requests.first?.attemptID, openAttemptID)
        XCTAssertEqual(spy.requests.first?.session.id, fixture.session.id)
        XCTAssertEqual(spy.requests.first?.sessionDirectory, directory)
        XCTAssertEqual(spy.requests.first?.configuration, MeetingFinalProcessingConfiguration(languageCode: "en"))
        XCTAssertEqual(result.attempt.backendID, MeetingBackendID.parakeetNemotron.rawValue)
    }

    func testCompositeProcessingPreparesDiarizationModelBeforePlanning() async throws {
        let fixture = self.makeTwoEpochFixture()
        let directory = try self.makeTempSessionDirectory()
        struct DownloadFailed: Error {}
        final class Spy {
            var preparations = 0
            var runtimes = 0
        }
        let spy = Spy()
        // Planning would throw `modelNotInstalled`; seeing the download error instead proves the
        // model is prepared before planning, and a failed preparation stops the attempt.
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: .parakeetNemotron)
        registry.register(.parakeetNemotron) { context in
            MeetingParakeetNemotronBackend(
                runtimeFactory: context.parakeetNemotronRuntimeFactory,
                modelLocator: StubModelLocator(error: MeetingNemotronModelReadinessError.modelNotInstalled(path: "/tmp/missing")),
                materializer: FakeMaterializer()
            )
        }
        let pipeline = MeetingProcessingPipeline(
            asrServiceProvider: {
                XCTFail("Canonical dispatch must not reach ASR readiness")
                return ASRService()
            },
            managesModelResidency: false,
            serializationGate: MeetingProcessingSerializationGate(),
            backendRegistry: registry,
            chunkObserver: FixtureObserver(results: fixture.observations),
            meetingRuntimeFactory: { _ in
                spy.runtimes += 1
                return FakeRuntime()
            },
            prepareDiarizationModel: {
                spy.preparations += 1
                throw DownloadFailed()
            }
        )
        await XCTAssertAsyncThrowsError(
            try await pipeline.process(session: fixture.session, sessionDirectory: directory) { _ in }
        ) { error in
            XCTAssertTrue(error is DownloadFailed, "expected the download error, got \(error)")
        }
        XCTAssertEqual(spy.preparations, 1)
        XCTAssertEqual(spy.runtimes, 0, "no model runtime may be created without the model")
    }

    // MARK: - Epoch isolation and unit assignment

    private func plannedManifest(
        fixture: TwoEpochFixture,
        runtime: FakeRuntime,
        materializer: FakeMaterializer = FakeMaterializer()
    ) async throws -> (backend: MeetingParakeetNemotronBackend, plan: MeetingBackendPlan, manifest: MeetingAnalysisManifest) {
        let directory = try self.makeTempSessionDirectory()
        let backend = self.makeBackend(runtime: runtime, materializer: materializer)
        let plan = try backend.plan(self.makeRequest(session: fixture.session, directory: directory))
        let manifest = try self.makeManifest(plan: plan, observations: fixture.observations)
        return (backend, plan, manifest)
    }

    private func executeComposite(
        fixture: TwoEpochFixture,
        runtime: FakeRuntime,
        materializer: FakeMaterializer = FakeMaterializer()
    ) async throws -> (bundle: MeetingCanonicalResultBundle, manifest: MeetingAnalysisManifest, plan: MeetingBackendPlan) {
        let (backend, plan, manifest) = try await self.plannedManifest(
            fixture: fixture, runtime: runtime, materializer: materializer
        )
        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else {
            XCTFail("composite must return canonical evidence")
            throw MeetingBackendError.outcomeContractMismatch(backend: .parakeetNemotron, declared: .canonicalEvidence)
        }
        return (bundle, manifest, plan)
    }

    func testOneDiarizerStatePerTrackKeepsSlotsAcrossEpochs() async throws {
        let fixture = self.makeTwoEpochFixture()
        let runtime = FakeRuntime()
        runtime.voiceError = NSError(domain: "voice-model-test", code: 1)
        let (backend, plan, manifest) = try await self.plannedManifest(fixture: fixture, runtime: runtime)
        let micEpochs = try XCTUnwrap(manifest.track(fixture.micTrack.id)?.epochs)
        let appEpochs = try XCTUnwrap(manifest.track(fixture.appTrack.id)?.epochs)
        XCTAssertEqual(micEpochs.count, 2, "the 3-second chunk gap must reset the mic epoch")
        XCTAssertEqual(appEpochs.count, 1)

        // One stream per track: mic epoch 0 (2 s), 0.5 s of joining silence, mic epoch 1 (2 s).
        runtime.diarizerFactory.segmentsByEpoch = [
            micEpochs[0].id: [
                MeetingNemotronSpeakerSegment(slotIndex: 0, start: 0.2, end: 1.0),
                MeetingNemotronSpeakerSegment(slotIndex: 0, start: 2.5, end: 3.5),
            ],
            appEpochs[0].id: [MeetingNemotronSpeakerSegment(slotIndex: 0, start: 0.0, end: 2.0)],
        ]
        runtime.asrSession.responses = [
            .init(text: "hello", words: [ASRWordTiming(text: "hello", start: 0.3, end: 0.6)]),
            .init(text: "world", words: [ASRWordTiming(text: "world", start: 0.1, end: 0.5)]),
            .init(text: "remote", words: [ASRWordTiming(text: "remote", start: 0.5, end: 1.0)]),
        ]
        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else {
            XCTFail("composite must return canonical evidence")
            throw MeetingBackendError.outcomeContractMismatch(backend: .parakeetNemotron, declared: .canonicalEvidence)
        }

        XCTAssertEqual(
            runtime.diarizerFactory.createdEpochs,
            [micEpochs[0].id, appEpochs[0].id],
            "one diarizer state per track, keyed by its first epoch"
        )
        XCTAssertEqual(
            runtime.diarizerFactory.diarizedSampleCounts,
            [2 * 16_000 + 8000 + 2 * 16_000, 2 * 16_000],
            "a track's epochs are diarized as one stream joined by 0.5 s of silence"
        )
        XCTAssertEqual(runtime.diarizationScopeCount, 1, "one Nemotron residency per attempt")
        XCTAssertEqual(runtime.asrAttemptIDs.count, 1, "the voice encoder is not needed and never runs")
        XCTAssertEqual(runtime.asrSession.callSampleCounts.count, 3)
        XCTAssertTrue(bundle.coverageReceipts.allSatisfy { $0.status == .processed })

        let unitsByText = Dictionary(bundle.evidence.units.map { ($0.text, $0) }, uniquingKeysWith: { first, _ in first })
        guard case let .assigned(helloToken) = try XCTUnwrap(unitsByText["hello"]).speaker,
              case let .assigned(worldToken) = try XCTUnwrap(unitsByText["world"]).speaker,
              case let .assigned(remoteToken) = try XCTUnwrap(unitsByText["remote"]).speaker
        else {
            return XCTFail("every word overlaps one slot")
        }
        XCTAssertEqual(helloToken, .init(analysisEpochID: micEpochs[0].id, label: "slot-0"))
        XCTAssertEqual(
            worldToken,
            .init(analysisEpochID: micEpochs[1].id, label: "slot-0"),
            "a segment after the join maps back into the second epoch's own time"
        )
        XCTAssertEqual(remoteToken, .init(analysisEpochID: appEpochs[0].id, label: "slot-0"))
        XCTAssertTrue(bundle.evidence.speakerSlotsContinueAcrossEpochs)
        XCTAssertTrue(bundle.evidence.voiceProfiles.isEmpty)

        let verdicts = try await MeetingTextOverlapEchoVerdictProvider().echoVerdicts(
            for: bundle.evidence,
            manifest: manifest,
            plan: plan
        )
        let assembled = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: bundle.evidence,
            coverageReceipts: bundle.coverageReceipts,
            echoVerdicts: verdicts
        ))
        let speakerByText = Dictionary(
            assembled.segments.map { ($0.text, $0.speakerID) }, uniquingKeysWith: { first, _ in first }
        )
        XCTAssertNotNil(speakerByText["hello"] ?? nil)
        XCTAssertEqual(speakerByText["hello"], speakerByText["world"], "the same voice keeps one name across the reset")
        XCTAssertNotEqual(speakerByText["hello"], speakerByText["remote"], "tracks never merge")
        XCTAssertEqual(assembled.speakers.filter { $0.trackKind == .microphone }.count, 1)
        XCTAssertEqual(assembled.speakers.filter { $0.trackKind == .applicationAudio }.count, 1)
        XCTAssertEqual(assembled.sidecar.speakerIdentityLinks.count, 1)
    }

    func testPCMFirstEpochMaterializesOnceForBothModelPhases() async throws {
        let chunk = self.makePCMChunk(sequence: 0, start: 100, end: 101)
        let track = self.makeMicTrack(chunks: [chunk], eraStart: 100)
        let session = self.makeSession(mode: .inRoom, tracks: [track])
        let runtime = FakeRuntime()
        let materializer = FakeMaterializer()
        let backend = self.makeBackend(runtime: runtime, materializer: materializer)
        let plan = try backend.plan(self.makeRequest(
            session: session,
            directory: self.makeTempSessionDirectory()
        ))
        let manifest = try self.makeManifest(plan: plan, observations: [
            MeetingAnalysisChunkKey(trackID: track.id, chunkID: chunk.id): self.makeObserved(chunk, duration: 1),
        ])
        let epoch = try XCTUnwrap(manifest.track(track.id)?.epochs.first)
        runtime.diarizerFactory.segmentsByEpoch[epoch.id] = [
            MeetingNemotronSpeakerSegment(slotIndex: 0, start: 0.1, end: 0.4),
        ]
        runtime.asrSession.responses = [
            .init(text: "pcm", words: [ASRWordTiming(text: "pcm", start: 0.2, end: 0.3)]),
        ]
        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else {
            return XCTFail("composite must return canonical evidence")
        }
        XCTAssertEqual(materializer.materializedEpochs, [epoch.id], "PCM is materialized once and shared")
        XCTAssertEqual(runtime.asrSession.callSampleCounts, [16_000])
        XCTAssertEqual(bundle.evidence.units.map(\.text), ["pcm"])
    }

    func testWordSlotAmbiguityAndUnassigned() async throws {
        let chunk = self.makeChunk(sequence: 0, start: 100, end: 104)
        let track = self.makeMicTrack(chunks: [chunk], eraStart: 100)
        let session = self.makeSession(mode: .inRoom, tracks: [track])
        let directory = try self.makeTempSessionDirectory()
        let runtime = FakeRuntime()
        let backend = self.makeBackend(runtime: runtime)
        let request = self.makeRequest(session: session, directory: directory)
        let plan = try backend.plan(request)
        let manifest = try self.makeManifest(
            plan: plan,
            observations: [MeetingAnalysisChunkKey(trackID: track.id, chunkID: chunk.id): self.makeObserved(chunk, duration: 4)]
        )
        let epoch = try XCTUnwrap(manifest.track(track.id)?.epochs.first)
        runtime.diarizerFactory.segmentsByEpoch = [
            epoch.id: [
                MeetingNemotronSpeakerSegment(slotIndex: 0, start: 0.0, end: 2.0),
                MeetingNemotronSpeakerSegment(slotIndex: 1, start: 1.0, end: 3.0),
            ],
        ]
        runtime.asrSession.responses = [
            .init(text: "a b c", words: [
                ASRWordTiming(text: "a", start: 0.2, end: 0.6),
                ASRWordTiming(text: "b", start: 1.2, end: 1.6),
                ASRWordTiming(text: "c", start: 3.2, end: 3.6),
            ]),
        ]

        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else {
            return XCTFail("composite must return canonical evidence")
        }
        let unitsByText = Dictionary(bundle.evidence.units.map { ($0.text, $0) }, uniquingKeysWith: { first, _ in first })

        guard case let .assigned(tokenA) = try XCTUnwrap(unitsByText["a"]).speaker else {
            return XCTFail("word a overlaps only slot 0")
        }
        XCTAssertEqual(tokenA.label, "slot-0")

        guard case let .assigned(tokenB) = try XCTUnwrap(unitsByText["b"]).speaker else {
            return XCTFail("word b should inherit the continuing incumbent in the handoff pass")
        }
        XCTAssertEqual(tokenB.label, "slot-0")

        guard case .unassigned = try XCTUnwrap(unitsByText["c"]).speaker else {
            return XCTFail("word c overlaps no activity")
        }

        // Assembly keeps the resolved handoff on the existing product speaker.
        let assembly = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: bundle.evidence,
            coverageReceipts: bundle.coverageReceipts
        ))
        XCTAssertEqual(assembly.segments.map(\.text), ["a", "b"])
        XCTAssertEqual(assembly.speakers.count, 1, "only the unambiguous assigned slot mints a speaker")
        let resolved = try XCTUnwrap(assembly.sidecar.dispositions.first { $0.unitID == unitsByText["b"]?.id })
        XCTAssertEqual(resolved.disposition, .emitted)
        let outside = try XCTUnwrap(assembly.sidecar.dispositions.first { $0.unitID == unitsByText["c"]?.id })
        XCTAssertEqual(outside.disposition, .outsideActivity)
    }

    func testCoverageUnionDoesNotDoubleCountDuplicateSpeakerIntervals() {
        let (slot0, slot1) = self.attributionTokens()
        let activity = [
            MeetingBackendSpeakerActivity(token: slot0, start: 0, end: 0.4),
            MeetingBackendSpeakerActivity(token: slot0, start: 0, end: 0.4),
            MeetingBackendSpeakerActivity(token: slot1, start: 0, end: 0.1),
        ]

        guard case let .ambiguous(tokens) = MeetingParakeetNemotronBackend.assignment(
            start: 0, end: 1, activity: activity, allowDominance: true
        ) else { return XCTFail("unioned 40% versus 10% coverage must not become an 80% dominant assignment") }
        XCTAssertEqual(tokens.map(\.label), ["slot-0", "slot-1"])
    }

    func testAllCandidatesAtOrBelowScaledFloorAreUnassigned() {
        let (slot0, slot1) = self.attributionTokens()
        let decision = MeetingParakeetNemotronBackend.assignment(
            start: 0,
            end: 1,
            activity: [
                MeetingBackendSpeakerActivity(token: slot0, start: 0, end: 0.08),
                MeetingBackendSpeakerActivity(token: slot1, start: 0.92, end: 1),
            ],
            allowDominance: true
        )
        guard case .unassigned = decision else { return XCTFail("sub-frame evidence must not assign a speaker") }
    }

    func testSoleAboveFloorCandidateAssigns() {
        let (slot0, slot1) = self.attributionTokens()
        let decision = MeetingParakeetNemotronBackend.assignment(
            start: 0,
            end: 1,
            activity: [
                MeetingBackendSpeakerActivity(token: slot0, start: 0, end: 0.2),
                MeetingBackendSpeakerActivity(token: slot1, start: 0.95, end: 1),
            ],
            allowDominance: true
        )
        guard case let .assigned(token) = decision else { return XCTFail("the sole significant speaker must assign") }
        XCTAssertEqual(token, slot0)
    }

    func testShortWordDoesNotDiscardEightyMillisecondRunnerUp() {
        let (slot0, slot1) = self.attributionTokens()
        let decision = MeetingParakeetNemotronBackend.assignment(
            start: 0,
            end: 0.15,
            activity: [
                MeetingBackendSpeakerActivity(token: slot0, start: 0, end: 0.15),
                MeetingBackendSpeakerActivity(token: slot1, start: 0.07, end: 0.15),
            ],
            allowDominance: true
        )
        guard case let .ambiguous(tokens) = decision else {
            return XCTFail("80ms is material evidence inside a 150ms word")
        }
        XCTAssertEqual(tokens.map(\.label), ["slot-0", "slot-1"])
    }

    func testSixtyFortyAndFullOverlapRemainAmbiguousWithDeterministicOrder() {
        let (slot0, slot1) = self.attributionTokens()
        for activity in [
            [
                MeetingBackendSpeakerActivity(token: slot0, start: 0, end: 0.6),
                MeetingBackendSpeakerActivity(token: slot1, start: 0.6, end: 1),
            ],
            [
                MeetingBackendSpeakerActivity(token: slot1, start: 0, end: 1),
                MeetingBackendSpeakerActivity(token: slot0, start: 0, end: 1),
            ],
        ] {
            guard case let .ambiguous(tokens) = MeetingParakeetNemotronBackend.assignment(
                start: 0, end: 1, activity: activity, allowDominance: true
            ) else { return XCTFail("material two-speaker coverage must remain ambiguous") }
            XCTAssertEqual(tokens.map(\.label), ["slot-0", "slot-1"])
        }
    }

    func testClearLeaderAndExactDominanceBoundaryAssign() {
        let (slot0, slot1) = self.attributionTokens()
        for leaderEnd in [0.8, 0.5] {
            let runnerEnd = leaderEnd == 0.5 ? 0.2 : 0.15
            let decision = MeetingParakeetNemotronBackend.assignment(
                start: 0,
                end: 1,
                activity: [
                    MeetingBackendSpeakerActivity(token: slot0, start: 0, end: leaderEnd),
                    MeetingBackendSpeakerActivity(token: slot1, start: 0, end: runnerEnd),
                ],
                allowDominance: true
            )
            guard case let .assigned(token) = decision else {
                return XCTFail("coverage at or beyond every named dominance boundary must assign")
            }
            XCTAssertEqual(token, slot0)
        }
    }

    func testClearPluralityBelowHalfRemainsConservativelyAmbiguous() {
        let (slot0, slot1) = self.attributionTokens()
        let decision = MeetingParakeetNemotronBackend.assignment(
            start: 0,
            end: 1,
            activity: [
                MeetingBackendSpeakerActivity(token: slot0, start: 0, end: 0.45),
                MeetingBackendSpeakerActivity(token: slot1, start: 0, end: 0.10),
            ],
            allowDominance: true
        )
        guard case let .ambiguous(tokens) = decision else {
            return XCTFail("a plurality below the explicit 50% coverage floor must not become confident")
        }
        XCTAssertEqual(tokens.map(\.label), ["slot-0", "slot-1"])
    }

    func testUtteranceFallbackNeverUsesDominanceAcrossTwoSignificantSpeakers() {
        let (slot0, slot1) = self.attributionTokens()
        let decision = MeetingParakeetNemotronBackend.assignment(
            start: 0,
            end: 1,
            activity: [
                MeetingBackendSpeakerActivity(token: slot0, start: 0, end: 0.8),
                MeetingBackendSpeakerActivity(token: slot1, start: 0, end: 0.15),
            ],
            allowDominance: false
        )
        guard case let .ambiguous(tokens) = decision else {
            return XCTFail("epoch-covering utterance timing is too coarse for dominance")
        }
        XCTAssertEqual(tokens.map(\.label), ["slot-0", "slot-1"])
    }

    func testHandoffAssignsNewEntrantWhoseActivityStartsWithShortWord() {
        let (slot0, slot1) = self.attributionTokens()
        let decision = MeetingParakeetNemotronBackend.handoffAssignment(
            .ambiguous([slot0, slot1]),
            start: 1,
            end: 1.4,
            activity: [
                MeetingBackendSpeakerActivity(token: slot0, start: 0, end: 1.4),
                MeetingBackendSpeakerActivity(token: slot1, start: 1, end: 1.4),
            ],
            previousAssignedWord: (slot0, 0.95)
        )
        guard case let .assigned(token) = decision else { return XCTFail("new onset should win the handoff") }
        XCTAssertEqual(token, slot1)
    }

    func testHandoffKeepsIncumbentWhenOtherSpeakerDidNotStartAtBoundary() {
        let (slot0, slot1) = self.attributionTokens()
        let decision = MeetingParakeetNemotronBackend.handoffAssignment(
            .ambiguous([slot0, slot1]),
            start: 1,
            end: 1.4,
            activity: [
                MeetingBackendSpeakerActivity(token: slot0, start: 0, end: 1.4),
                MeetingBackendSpeakerActivity(token: slot1, start: 0.2, end: 1.4),
            ],
            previousAssignedWord: (slot0, 0.95)
        )
        guard case let .assigned(token) = decision else { return XCTFail("continuing incumbent should own the word") }
        XCTAssertEqual(token, slot0)
    }

    func testHandoffVetoesMissingContextLongWordsLargeGapsAndMoreThanTwoCandidates() {
        let (slot0, slot1) = self.attributionTokens()
        let epoch = slot0.analysisEpochID
        let slot2 = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-2")
        let activity = [
            MeetingBackendSpeakerActivity(token: slot0, start: 0, end: 2),
            MeetingBackendSpeakerActivity(token: slot1, start: 1, end: 2),
            MeetingBackendSpeakerActivity(token: slot2, start: 1, end: 2),
        ]

        for (assignment, start, end, previous) in [
            (MeetingBackendSpeakerAssignment.ambiguous([slot0, slot1]), 1.0, 1.4, nil),
            (.ambiguous([slot0, slot1]), 1.0, 2.0, (token: slot0, end: 0.95)),
            (.ambiguous([slot0, slot1]), 1.0, 1.4, (token: slot0, end: 0.0)),
            (.ambiguous([slot0, slot1, slot2]), 1.0, 1.4, (token: slot0, end: 0.95)),
        ] {
            guard case .ambiguous = MeetingParakeetNemotronBackend.handoffAssignment(
                assignment,
                start: start,
                end: end,
                activity: activity,
                previousAssignedWord: previous
            ) else { return XCTFail("handoff veto must preserve ambiguity") }
        }
    }

    private func attributionTokens() -> (MeetingBackendSpeakerToken, MeetingBackendSpeakerToken) {
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        return (
            MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-0"),
            MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-1")
        )
    }

    func testProviderAndDiarizerTimesMapThroughActualSpanSampleRanges() async throws {
        let chunk0 = self.makeChunk(sequence: 0, start: 100, end: 101, path: "tracks/microphone/chunk_0.caf")
        let chunk1 = self.makeChunk(sequence: 1, start: 101, end: 102, path: "tracks/microphone/chunk_1.caf")
        let track = self.makeMicTrack(chunks: [chunk0, chunk1], eraStart: 100)
        let session = self.makeSession(mode: .inRoom, tracks: [track])
        let runtime = FakeRuntime()
        let materializer = FakeMaterializer()
        let backend = self.makeBackend(runtime: runtime, materializer: materializer)
        let plan = try backend.plan(self.makeRequest(
            session: session,
            directory: self.makeTempSessionDirectory()
        ))
        let manifest = try self.makeManifest(plan: plan, observations: [
            MeetingAnalysisChunkKey(trackID: track.id, chunkID: chunk0.id): self.makeObserved(chunk0, duration: 1),
            MeetingAnalysisChunkKey(trackID: track.id, chunkID: chunk1.id): self.makeObserved(chunk1, duration: 1),
        ])
        let trackManifest = try XCTUnwrap(manifest.track(track.id))
        let epoch = try XCTUnwrap(trackManifest.epochs.first)
        XCTAssertEqual(epoch.spanIDs.count, 2)

        // Deliberately make the first one-second manifest span occupy only 0.5 seconds of the
        // materialized buffer. A local time of 0.6 seconds must therefore map into span 2.
        materializer.customSpanSampleCounts[epoch.id] = [8000, 16_000]
        runtime.diarizerFactory.segmentsByEpoch[epoch.id] = [
            MeetingNemotronSpeakerSegment(slotIndex: 3, start: 0.55, end: 0.75),
        ]
        runtime.asrSession.responses = [
            .init(text: "mapped", words: [ASRWordTiming(text: "mapped", start: 0.6, end: 0.7)]),
        ]

        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else {
            return XCTFail("composite must return canonical evidence")
        }
        let unit = try XCTUnwrap(bundle.evidence.units.first)
        XCTAssertEqual(unit.analysisStart, 1.1, accuracy: 1e-6)
        XCTAssertEqual(unit.analysisEnd, 1.2, accuracy: 1e-6)
        XCTAssertEqual(unit.analysisSpanIDs, [epoch.spanIDs[1]])
        guard case let .assigned(token) = unit.speaker else {
            return XCTFail("mapped diarizer activity should assign the word")
        }
        XCTAssertEqual(token.label, "slot-3")
    }

    // MARK: - Receipts and partial failure

    func testEpochFailureMarksItsSpansFailedAndContinues() async throws {
        let fixture = self.makeTwoEpochFixture()
        let runtime = FakeRuntime()
        runtime.diarizerFactory.segmentsByEpoch = [:]
        runtime.asrSession.responses = [
            .init(text: "fine", words: [ASRWordTiming(text: "fine", start: 0.2, end: 0.4)]),
            .init(text: "ignored", words: [ASRWordTiming(text: "ignored", start: 0.2, end: 0.4)]),
            .init(text: "remote", words: [ASRWordTiming(text: "remote", start: 0.2, end: 0.4)]),
        ]
        runtime.asrSession.failingCallIndices = [1]

        let (bundle, manifest, plan) = try await self.executeComposite(fixture: fixture, runtime: runtime)
        let micEpochs = try XCTUnwrap(manifest.track(fixture.micTrack.id)?.epochs)
        let appEpochs = try XCTUnwrap(manifest.track(fixture.appTrack.id)?.epochs)

        let receiptsBySpan = Dictionary(
            bundle.coverageReceipts.map { ($0.spanID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        XCTAssertEqual(bundle.coverageReceipts.count, manifest.allSpans.count, "every admissible span is tiled")
        for span in manifest.allSpans {
            let receipt = try XCTUnwrap(receiptsBySpan[span.id])
            XCTAssertEqual(receipt.analysisStart, span.analysisInterval.start, accuracy: 1e-9)
            XCTAssertEqual(receipt.analysisEnd, span.analysisInterval.end, accuracy: 1e-9)
            if span.analysisEpochID == micEpochs[1].id {
                XCTAssertEqual(receipt.status, .failed)
                XCTAssertEqual(receipt.reasonCode, "asrFailed")
            } else {
                XCTAssertEqual(receipt.status, .processed)
            }
        }
        XCTAssertEqual(Set(bundle.evidence.units.map(\.analysisEpochID)), [micEpochs[0].id, appEpochs[0].id])

        // The partial bundle still assembles; the failed epoch becomes visible coverage gaps.
        let verdicts = try await MeetingTextOverlapEchoVerdictProvider().echoVerdicts(
            for: bundle.evidence,
            manifest: manifest,
            plan: plan
        )
        let assembly = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: bundle.evidence,
            coverageReceipts: bundle.coverageReceipts,
            echoVerdicts: verdicts
        ))
        XCTAssertFalse(assembly.isComplete)
        XCTAssertEqual(assembly.coverageGaps.filter { $0.reason == .processingFailed }.count, 1)
    }

    func testDiarizationFailureSkipsASRForThatTrackOnly() async throws {
        let fixture = self.makeTwoEpochFixture()
        let runtime = FakeRuntime()
        let directory = try self.makeTempSessionDirectory()
        let backend = self.makeBackend(runtime: runtime)
        let request = self.makeRequest(session: fixture.session, directory: directory)
        let plan = try backend.plan(request)
        let manifest = try self.makeManifest(plan: plan, observations: fixture.observations)
        let micEpochs = try XCTUnwrap(manifest.track(fixture.micTrack.id)?.epochs)
        // The mic track is one diarizer stream, so its failure covers both of its epochs.
        runtime.diarizerFactory.failingEpochs = [micEpochs[0].id]
        runtime.asrSession.responses = [
            .init(text: "remote", words: [ASRWordTiming(text: "remote", start: 0.1, end: 0.3)]),
        ]

        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else {
            return XCTFail("composite must return canonical evidence")
        }
        XCTAssertEqual(runtime.asrSession.callSampleCounts.count, 1, "only the healthy track is transcribed")
        let failedReceipts = bundle.coverageReceipts.filter { $0.status == .failed }
        XCTAssertEqual(Set(failedReceipts.map(\.spanID)), Set(micEpochs.flatMap(\.spanIDs)))
        XCTAssertTrue(failedReceipts.allSatisfy { $0.reasonCode == "diarizationFailed" })
        XCTAssertEqual(Set(bundle.evidence.units.map(\.text)), ["remote"])
    }

    // MARK: - Utterance fallback

    func testTextWithoutWordTimingsEmitsOneEpochCoveringUtterance() async throws {
        let chunk = self.makeChunk(sequence: 0, start: 100, end: 103)
        let track = self.makeMicTrack(chunks: [chunk], eraStart: 100)
        let session = self.makeSession(mode: .inRoom, tracks: [track])
        let directory = try self.makeTempSessionDirectory()
        let runtime = FakeRuntime()
        let backend = self.makeBackend(runtime: runtime)
        let request = self.makeRequest(session: session, directory: directory)
        let plan = try backend.plan(request)
        let manifest = try self.makeManifest(
            plan: plan,
            observations: [MeetingAnalysisChunkKey(trackID: track.id, chunkID: chunk.id): self.makeObserved(chunk, duration: 3)]
        )
        let epoch = try XCTUnwrap(manifest.track(track.id)?.epochs.first)
        runtime.diarizerFactory.segmentsByEpoch = [
            epoch.id: [MeetingNemotronSpeakerSegment(slotIndex: 2, start: 0.0, end: 3.0)],
        ]
        runtime.asrSession.responses = [.init(text: "hello there", words: [])]

        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else {
            return XCTFail("composite must return canonical evidence")
        }
        let unit = try XCTUnwrap(bundle.evidence.units.first)
        XCTAssertEqual(bundle.evidence.units.count, 1)
        XCTAssertEqual(unit.precision, .utterance)
        XCTAssertEqual(unit.analysisStart, epoch.analysisInterval.start, accuracy: 1e-9)
        XCTAssertEqual(unit.analysisEnd, epoch.analysisInterval.end, accuracy: 1e-9)
        XCTAssertEqual(unit.analysisSpanIDs, epoch.spanIDs)
        guard case let .assigned(token) = unit.speaker else {
            return XCTFail("the epoch-covering utterance takes the epoch's activity")
        }
        XCTAssertEqual(token.label, "slot-2")

        // Assembly accepts it as-is: no synthetic words exist.
        _ = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: bundle.evidence,
            coverageReceipts: bundle.coverageReceipts
        ))
    }

    func testProcessedEpochWithNoTextIsValid() async throws {
        let fixture = self.makeTwoEpochFixture()
        let runtime = FakeRuntime()
        runtime.asrSession.responses = [
            .init(text: "  ", words: []), .init(text: "", words: []), .init(text: "", words: []),
        ]
        let (bundle, manifest, _) = try await self.executeComposite(fixture: fixture, runtime: runtime)
        XCTAssertTrue(bundle.evidence.units.isEmpty)
        XCTAssertEqual(bundle.coverageReceipts.count, manifest.allSpans.count)
        XCTAssertTrue(bundle.coverageReceipts.allSatisfy { $0.status == .processed })
    }

    // MARK: - Cancellation

    func testCancellationPropagatesOutOfExecute() async throws {
        let fixture = self.makeTwoEpochFixture()
        let runtime = FakeRuntime()
        let latch = Latch()
        runtime.asrSession.latch = latch
        let entered = LockedFlag()
        runtime.asrSession.onCall = { entered.set() }

        let directory = try self.makeTempSessionDirectory()
        let backend = self.makeBackend(runtime: runtime)
        let request = self.makeRequest(session: fixture.session, directory: directory)
        let plan = try backend.plan(request)
        let manifest = try self.makeManifest(plan: plan, observations: fixture.observations)

        let task = Task { @MainActor in
            try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        }
        let deadline = Date().addingTimeInterval(5)
        while !entered.value, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(entered.value, "the ASR phase must have started")
        task.cancel()
        await latch.open()
        await XCTAssertAsyncThrowsError(try await task.value) { error in
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }

    func testProviderCancellationIsNotAFailedReceipt() async throws {
        let fixture = self.makeTwoEpochFixture()
        let runtime = FakeRuntime()
        runtime.asrSession.responses = [
            .init(text: "fine", words: [ASRWordTiming(text: "fine", start: 0.2, end: 0.4)]),
        ]
        runtime.asrSession.cancellationCallIndices = [1]

        let directory = try self.makeTempSessionDirectory()
        let backend = self.makeBackend(runtime: runtime)
        let request = self.makeRequest(session: fixture.session, directory: directory)
        let plan = try backend.plan(request)
        let manifest = try self.makeManifest(plan: plan, observations: fixture.observations)
        await XCTAssertAsyncThrowsError(
            try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        ) { error in
            XCTAssertTrue(error is CancellationError, "cancellation propagates; got \(error)")
        }
    }

    // MARK: - Helpers
}

// MARK: - Fakes

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

private final nonisolated class FakeDiarizerFactory: MeetingNemotronDiarizerFactory, @unchecked Sendable {
    struct Session: MeetingNemotronDiarizerSession {
        let factory: FakeDiarizerFactory
        let segments: [MeetingNemotronSpeakerSegment]
        func diarize(samples: [Float]) async throws -> [MeetingNemotronSpeakerSegment] {
            self.factory.diarizedSampleCounts.append(samples.count)
            return self.segments
        }
    }

    var segmentsByEpoch: [MeetingAnalysisEpochID: [MeetingNemotronSpeakerSegment]] = [:]
    var failingEpochs: Set<MeetingAnalysisEpochID> = []
    private(set) var createdEpochs: [MeetingAnalysisEpochID] = []
    private(set) var diarizedSampleCounts: [Int] = []

    func makeDiarizer(epoch: MeetingAnalysisEpochID) async throws -> any MeetingNemotronDiarizerSession {
        self.createdEpochs.append(epoch)
        if self.failingEpochs.contains(epoch) {
            throw MeetingEpochMaterializationError.unreadable(spanID: "fake-diarizer-failure")
        }
        return Session(factory: self, segments: self.segmentsByEpoch[epoch] ?? [])
    }
}

private final nonisolated class FakeASRSession: MeetingParakeetASRSession, @unchecked Sendable {
    struct Response {
        let text: String
        let words: [ASRWordTiming]
    }

    var responses: [Response] = []
    var failingCallIndices: Set<Int> = []
    var cancellationCallIndices: Set<Int> = []
    var latch: Latch?
    var onCall: (() -> Void)?
    private(set) var callSampleCounts: [Int] = []

    func transcribeWithTimings(
        _ samples: [Float]
    ) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
        let index = self.callSampleCounts.count
        self.callSampleCounts.append(samples.count)
        self.onCall?()
        if let latch { await latch.wait() }
        if self.cancellationCallIndices.contains(index) { throw CancellationError() }
        if self.failingCallIndices.contains(index) {
            throw MeetingEpochMaterializationError.unreadable(spanID: "fake-asr-failure")
        }
        let response = index < self.responses.count ? self.responses[index] : Response(text: "", words: [])
        return (await ASRTranscriptionResult(text: response.text), response.words)
    }
}

private final nonisolated class FakeRuntime: MeetingParakeetNemotronRunning, @unchecked Sendable {
    let diarizerFactory = FakeDiarizerFactory()
    let asrSession = FakeASRSession()
    var voiceProfiles: [MeetingSpeakerVoiceProfile] = []
    var voiceError: Error?
    private(set) var diarizationScopeCount = 0
    private(set) var asrAttemptIDs: [UUID] = []
    private(set) var asrConfigurations: [MeetingFinalProcessingConfiguration] = []

    func speakerVoiceProfiles(samples _: [MeetingSpeakerVoiceSamples]) async throws -> [MeetingSpeakerVoiceProfile] {
        if let voiceError { throw voiceError }
        return self.voiceProfiles
    }

    func withNemotronDiarization(
        artifact _: MeetingNemotronModelArtifact,
        _ body: nonisolated(nonsending) @escaping @Sendable (any MeetingNemotronDiarizerFactory) async throws -> MeetingNemotronPhaseResult
    ) async throws -> MeetingNemotronPhaseResult {
        self.diarizationScopeCount += 1
        return try await body(self.diarizerFactory)
    }

    func withPreparedASR(
        attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration,
        body: nonisolated(nonsending) @escaping @Sendable (any MeetingParakeetASRSession) async throws -> MeetingParakeetPhaseResult
    ) async throws -> MeetingParakeetPhaseResult {
        self.asrAttemptIDs.append(attemptID)
        self.asrConfigurations.append(configuration)
        return try await body(self.asrSession)
    }
}

private final nonisolated class FakeMaterializer: MeetingEpochAudioMaterializing, @unchecked Sendable {
    var failingEpochs: Set<MeetingAnalysisEpochID> = []
    var customSpanSampleCounts: [MeetingAnalysisEpochID: [Int]] = [:]
    private(set) var materializedEpochs: [MeetingAnalysisEpochID] = []

    func materialize(
        epoch: MeetingAnalysisEpochRecord,
        track: MeetingAnalysisTrackManifest,
        manifest _: MeetingAnalysisManifest,
        sessionDirectory _: URL
    ) async throws -> MeetingMaterializedEpoch {
        self.materializedEpochs.append(epoch.id)
        if self.failingEpochs.contains(epoch.id) {
            throw MeetingEpochMaterializationError.unreadable(spanID: epoch.spanIDs.first ?? "?")
        }
        var cursor = 0
        var ranges: [MeetingMaterializedSpanSamples] = []
        for (index, spanID) in epoch.spanIDs.enumerated() {
            guard let span = track.spans.first(where: { $0.id == spanID }) else { continue }
            let count: Int
            if let configured = self.customSpanSampleCounts[epoch.id], configured.indices.contains(index) {
                count = max(1, configured[index])
            } else {
                count = max(1, Int((span.analysisInterval.duration * 16_000).rounded()))
            }
            ranges.append(MeetingMaterializedSpanSamples(spanID: spanID, sampleRange: cursor..<(cursor + count)))
            cursor += count
        }
        return MeetingMaterializedEpoch(
            epochID: epoch.id,
            samples: [Float](repeating: 0, count: cursor),
            sampleRate: 16_000,
            spanSamples: ranges
        )
    }
}

private final nonisolated class StubModelLocator: MeetingNemotronModelLocating, @unchecked Sendable {
    var error: (any Error)?
    static let artifact = MeetingNemotronModelArtifact(
        packageURL: URL(fileURLWithPath: "/tmp/stub-nemotron.mlpackage"),
        totalByteCount: 1,
        fileCount: 1,
        manifestSHA256: "stub",
        entryMetadataSHA256: "stub"
    )

    init(error: (any Error)? = nil) {
        self.error = error
    }

    func locate() throws -> MeetingNemotronModelArtifact {
        if let error { throw error }
        return Self.artifact
    }

    func recheck(_ artifact: MeetingNemotronModelArtifact) throws -> MeetingNemotronModelArtifact {
        if let error { throw error }
        return artifact
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        self.lock.withLock { self.flag }
    }

    func set() {
        self.lock.withLock { self.flag = true }
    }
}

/// Small async assert helper so throwing closures read like XCTAssertThrowsError.
private func XCTAssertAsyncThrowsError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown. \(message)", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
