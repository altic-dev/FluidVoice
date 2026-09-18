@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Stage E of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md`: the deterministic text/time echo
/// verdict provider. Only online-call microphone units get verdicts, and only against temporally
/// overlapping application units measured by the existing `MeetingEchoDetector`.
@MainActor
final class MeetingTextOverlapEchoVerdictProviderTests: XCTestCase {
    // MARK: - Fixtures

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

    private func makeChunk(sequence: Int, start: Double, end: Double, path: String) -> MeetingAudioChunk {
        MeetingAudioChunk(
            id: UUID(),
            sequence: sequence,
            relativeFilePath: path,
            presentationStart: MeetingMediaTime(value: Int64((start * 1000).rounded()), timescale: 1000),
            presentationEnd: MeetingMediaTime(value: Int64((end * 1000).rounded()), timescale: 1000),
            discontinuities: [],
            sha256: String(repeating: "a", count: 64),
            byteCount: 1024,
            finalizationState: .finalized
        )
    }

    private func makeObserved(_ chunk: MeetingAudioChunk, duration: Double) -> MeetingChunkObservationResult {
        .observed(MeetingChunkObservedAudio(
            byteCount: chunk.byteCount,
            sha256: chunk.sha256,
            decoded: MeetingChunkDecodedFacts(
                sampleRate: 16_000,
                channelCount: 1,
                frameCount: Int64((duration * 16_000).rounded()),
                durationSeconds: duration,
                codecPriming: .measuredFrames(0),
                processingFormatDescription: "fixture"
            )
        ))
    }

    private struct EchoFixture {
        let plan: MeetingBackendPlan
        let manifest: MeetingAnalysisManifest
        let micTrackID: MeetingAudioTrackID
        let appTrackID: MeetingAudioTrackID
        let micEpoch: MeetingAnalysisEpochRecord
        let appEpochs: [MeetingAnalysisEpochRecord]
    }

    /// Online call: mic chunk [100,102) and app chunks [100,102) and [110,112).
    private func makeFixture(mode: MeetingCaptureMode = .onlineCall) throws -> EchoFixture {
        let micChunk = self.makeChunk(sequence: 0, start: 100, end: 102, path: "tracks/microphone/chunk_0.caf")
        let appChunk0 = self.makeChunk(sequence: 0, start: 100, end: 102, path: "tracks/application/chunk_0.caf")
        let appChunk1 = self.makeChunk(sequence: 1, start: 110, end: 112, path: "tracks/application/chunk_1.caf")
        let micTrack = MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "microphone",
            sourceDisplayName: "microphone",
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 7, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: [micChunk],
            captureMethod: .voiceProcessing,
            captureEras: [MeetingCaptureEra(
                method: .voiceProcessing,
                deviceUID: "mic-a",
                deviceName: "mic-a",
                roleAtElection: .unknown,
                echoProtection: .voiceProcessed,
                startSeconds: 100
            )]
        )
        let appTrack = MeetingAudioTrack(
            id: UUID(),
            kind: .applicationAudio,
            sourceIdentifier: "application",
            sourceDisplayName: "application",
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 7, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: [appChunk0, appChunk1],
            captureMethod: .screenCaptureKit
        )
        var session = MeetingSession(
            configuration: MeetingCaptureConfiguration(
                mode: mode,
                title: "Echo fixture",
                application: mode == .onlineCall
                    ? MeetingApplicationIdentity(bundleIdentifier: "fixture.app", displayName: "Fixture")
                    : nil,
                microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic-a", displayName: "Mic")
            ),
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 7, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil
            )
        )
        session.audioTracks = [micTrack, appTrack]
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
        let directory = FileManager.default.temporaryDirectory
        let request = MeetingBackendRequest(
            attemptID: session.processingAttempts.last?.id ?? UUID(),
            session: session,
            sessionDirectory: directory,
            configuration: MeetingFinalProcessingConfiguration(languageCode: "en")
        )
        let plan = MeetingBackendPlan(request: request, descriptor: MeetingParakeetNemotronBackend.descriptor)
        let manifest = try MeetingAnalysisManifestBuilder(
            plan: plan,
            observer: FixtureObserver(results: [
                MeetingAnalysisChunkKey(trackID: micTrack.id, chunkID: micChunk.id): self.makeObserved(micChunk, duration: 2),
                MeetingAnalysisChunkKey(trackID: appTrack.id, chunkID: appChunk0.id): self.makeObserved(appChunk0, duration: 2),
                MeetingAnalysisChunkKey(trackID: appTrack.id, chunkID: appChunk1.id): self.makeObserved(appChunk1, duration: 2),
            ]),
            analysisSampleRate: 16_000
        ).build()
        return EchoFixture(
            plan: plan,
            manifest: manifest,
            micTrackID: micTrack.id,
            appTrackID: appTrack.id,
            micEpoch: try XCTUnwrap(manifest.track(micTrack.id)?.epochs.first),
            appEpochs: try XCTUnwrap(manifest.track(appTrack.id)?.epochs)
        )
    }

    private func unit(
        _ id: String,
        trackID: MeetingAudioTrackID,
        epoch: MeetingAnalysisEpochRecord,
        text: String,
        analysisStart: Double,
        analysisEnd: Double
    ) -> MeetingFinalTextUnit {
        MeetingFinalTextUnit(
            id: id,
            trackID: trackID,
            analysisEpochID: epoch.id,
            precision: .word,
            text: text,
            analysisStart: analysisStart,
            analysisEnd: analysisEnd,
            speaker: .unassigned,
            analysisSpanIDs: epoch.spanIDs
        )
    }

    // MARK: - Verdicts

    func testSuppressesTemporallyOverlappingEchoOnly() async throws {
        let fixture = try self.makeFixture()
        let echoText = "the quick brown fox jumps over the lazy dog"
        let evidence = MeetingFinalTranscriptEvidence(
            backendID: .parakeetNemotron,
            attemptID: fixture.plan.attemptID,
            units: [
                self.unit("app-0", trackID: fixture.appTrackID, epoch: fixture.appEpochs[0], text: echoText, analysisStart: 0.2, analysisEnd: 1.8),
                self.unit("mic-0", trackID: fixture.micTrackID, epoch: fixture.micEpoch, text: echoText, analysisStart: 0.4, analysisEnd: 1.9),
                self.unit("mic-1", trackID: fixture.micTrackID, epoch: fixture.micEpoch, text: "an entirely local remark about lunch", analysisStart: 0.4, analysisEnd: 1.9),
            ]
        )
        let verdicts = try await MeetingTextOverlapEchoVerdictProvider().echoVerdicts(
            for: evidence, manifest: fixture.manifest, plan: fixture.plan
        )
        XCTAssertEqual(verdicts["mic-0"], .echoSuppressed(duplicateOfUnitID: "app-0"))
        XCTAssertEqual(verdicts["mic-1"], .notEcho)
        XCTAssertNil(verdicts["app-0"], "application units need no verdict")
    }

    func testWordPrecisionUsesTemporalPhraseContext() async throws {
        let fixture = try self.makeFixture()
        let words = ["quick", "brown", "fox", "jumps"]
        var units: [MeetingFinalTextUnit] = []
        for (index, word) in words.enumerated() {
            let start = 0.2 + Double(index) * 0.25
            units.append(self.unit(
                "app-word-\(index)", trackID: fixture.appTrackID, epoch: fixture.appEpochs[0],
                text: word, analysisStart: start, analysisEnd: start + 0.2
            ))
            units.append(self.unit(
                "mic-word-\(index)", trackID: fixture.micTrackID, epoch: fixture.micEpoch,
                text: word, analysisStart: start + 0.05, analysisEnd: start + 0.25
            ))
        }
        units.append(self.unit(
            "mic-local", trackID: fixture.micTrackID, epoch: fixture.micEpoch,
            text: "lunch", analysisStart: 1.3, analysisEnd: 1.5
        ))
        let evidence = MeetingFinalTranscriptEvidence(
            backendID: .parakeetNemotron,
            attemptID: fixture.plan.attemptID,
            units: units
        )

        let verdicts = try await MeetingTextOverlapEchoVerdictProvider().echoVerdicts(
            for: evidence, manifest: fixture.manifest, plan: fixture.plan
        )

        for index in words.indices {
            guard case .echoSuppressed? = verdicts["mic-word-\(index)"] else {
                return XCTFail("word-level echo \(index) should be suppressed using phrase context")
            }
        }
        XCTAssertEqual(verdicts["mic-local"], .notEcho)
    }

    func testEchoTextWithoutTemporalOverlapIsNotSuppressed() async throws {
        let fixture = try self.makeFixture()
        let echoText = "the quick brown fox jumps over the lazy dog"
        let farEpoch = fixture.appEpochs[1]
        let evidence = MeetingFinalTranscriptEvidence(
            backendID: .parakeetNemotron,
            attemptID: fixture.plan.attemptID,
            units: [
                // Same words, ten seconds later: text match alone must not suppress.
                self.unit("app-far", trackID: fixture.appTrackID, epoch: farEpoch, text: echoText, analysisStart: farEpoch.analysisInterval.start + 0.2, analysisEnd: farEpoch.analysisInterval.start + 1.8),
                self.unit("mic-0", trackID: fixture.micTrackID, epoch: fixture.micEpoch, text: echoText, analysisStart: 0.4, analysisEnd: 1.9),
            ]
        )
        let verdicts = try await MeetingTextOverlapEchoVerdictProvider().echoVerdicts(
            for: evidence, manifest: fixture.manifest, plan: fixture.plan
        )
        XCTAssertEqual(verdicts["mic-0"], .notEcho)
    }

    func testFutureRemoteRepetitionCannotSuppressEarlierMicrophoneWords() async throws {
        let fixture = try self.makeFixture()
        let words = ["quick", "brown", "fox", "jumps"]
        var units: [MeetingFinalTextUnit] = []
        for (index, word) in words.enumerated() {
            let micStart = 0.05 + Double(index) * 0.15
            let appStart = 1.1 + Double(index) * 0.15
            units.append(self.unit(
                "mic-earlier-\(index)", trackID: fixture.micTrackID, epoch: fixture.micEpoch,
                text: word, analysisStart: micStart, analysisEnd: micStart + 0.1
            ))
            units.append(self.unit(
                "app-later-\(index)", trackID: fixture.appTrackID, epoch: fixture.appEpochs[0],
                text: word, analysisStart: appStart, analysisEnd: appStart + 0.1
            ))
        }
        let evidence = MeetingFinalTranscriptEvidence(
            backendID: .parakeetNemotron,
            attemptID: fixture.plan.attemptID,
            units: units
        )

        let verdicts = try await MeetingTextOverlapEchoVerdictProvider().echoVerdicts(
            for: evidence, manifest: fixture.manifest, plan: fixture.plan
        )

        for index in words.indices {
            XCTAssertEqual(verdicts["mic-earlier-\(index)"], .notEcho)
        }
    }

    func testInRoomSessionNeedsNoVerdicts() async throws {
        let fixture = try self.makeFixture(mode: .inRoom)
        let evidence = MeetingFinalTranscriptEvidence(
            backendID: .parakeetNemotron,
            attemptID: fixture.plan.attemptID,
            units: [
                self.unit("mic-0", trackID: fixture.micTrackID, epoch: fixture.micEpoch, text: "anything", analysisStart: 0.4, analysisEnd: 1.0),
            ]
        )
        let verdicts = try await MeetingTextOverlapEchoVerdictProvider().echoVerdicts(
            for: evidence, manifest: fixture.manifest, plan: fixture.plan
        )
        XCTAssertTrue(verdicts.isEmpty)
    }

    func testQuarantinedUnitsAreSkipped() async throws {
        let fixture = try self.makeFixture()
        var bad = self.unit("mic-bad", trackID: fixture.micTrackID, epoch: fixture.micEpoch, text: "broken", analysisStart: 1.5, analysisEnd: 1.0)
        bad = MeetingFinalTextUnit(
            id: bad.id,
            trackID: bad.trackID,
            analysisEpochID: bad.analysisEpochID,
            precision: bad.precision,
            text: bad.text,
            analysisStart: 1.5,
            analysisEnd: 1.0,
            speaker: bad.speaker,
            analysisSpanIDs: bad.analysisSpanIDs
        )
        let evidence = MeetingFinalTranscriptEvidence(
            backendID: .parakeetNemotron,
            attemptID: fixture.plan.attemptID,
            units: [bad]
        )
        let verdicts = try await MeetingTextOverlapEchoVerdictProvider().echoVerdicts(
            for: evidence, manifest: fixture.manifest, plan: fixture.plan
        )
        XCTAssertTrue(verdicts.isEmpty, "quarantined units get no verdict and no interval arithmetic")
    }

    func testAssemblySuppressesTheEchoAndKeepsTheApplicationCopy() async throws {
        let fixture = try self.makeFixture()
        let echoText = "the quick brown fox jumps over the lazy dog"
        let evidence = MeetingFinalTranscriptEvidence(
            backendID: .parakeetNemotron,
            attemptID: fixture.plan.attemptID,
            units: [
                self.unit("app-0", trackID: fixture.appTrackID, epoch: fixture.appEpochs[0], text: echoText, analysisStart: 0.2, analysisEnd: 1.8),
                self.unit("mic-0", trackID: fixture.micTrackID, epoch: fixture.micEpoch, text: echoText, analysisStart: 0.4, analysisEnd: 1.9),
            ]
        )
        let verdicts = try await MeetingTextOverlapEchoVerdictProvider().echoVerdicts(
            for: evidence, manifest: fixture.manifest, plan: fixture.plan
        )
        let receipts = fixture.manifest.allSpans.map { span in
            MeetingSpanCoverageReceipt(
                id: "receipt:\(span.id)",
                spanID: span.id,
                analysisStart: span.analysisInterval.start,
                analysisEnd: span.analysisInterval.end,
                status: .processed
            )
        }
        let assembly = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: fixture.plan,
            manifest: fixture.manifest,
            evidence: evidence,
            coverageReceipts: receipts,
            echoVerdicts: verdicts
        ))
        let dispositions = Dictionary(
            assembly.sidecar.dispositions.map { ($0.unitID, $0.disposition) },
            uniquingKeysWith: { first, _ in first }
        )
        XCTAssertEqual(dispositions["mic-0"], .echoSuppressed)
        XCTAssertEqual(dispositions["app-0"], .emitted)
        XCTAssertEqual(assembly.segments.map(\.text), [echoText], "the microphone copy is ledger-only")
    }
}
