@testable import FluidVoice_Debug
import Foundation
import XCTest

private nonisolated struct AssemblerFixtureObserver: MeetingChunkAudioObserving {
    let results: [MeetingAnalysisChunkKey: MeetingChunkObservationResult]

    func observe(
        chunk: MeetingAudioChunk,
        trackID: MeetingAudioTrackID
    ) -> MeetingChunkObservationResult {
        self.results[MeetingAnalysisChunkKey(trackID: trackID, chunkID: chunk.id)]
            ?? .failed(.unreadable, detail: "No fixture observation")
    }
}

/// Stage C2b1 of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md`: the pure assembler. Every fixture
/// builds a real manifest through `MeetingAnalysisManifestBuilder` so units, receipts and gaps are
/// exercised against spans the validator actually proved.
final class MeetingTranscriptAssemblerTests: XCTestCase {
    private let backendID = MeetingBackendID(rawValue: "fixture.assembler")

    // MARK: - Session/manifest fixtures

    private func chunk(
        id: UUID = UUID(),
        sequence: Int,
        start: Double,
        end: Double,
        discontinuities: [MeetingAudioDiscontinuity] = []
    ) -> MeetingAudioChunk {
        MeetingAudioChunk(
            id: id,
            sequence: sequence,
            relativeFilePath: "tracks/chunk-\(sequence).m4a",
            presentationStart: self.mediaTime(start),
            presentationEnd: self.mediaTime(end),
            discontinuities: discontinuities,
            sha256: String(repeating: String((sequence % 9) + 1), count: 64),
            byteCount: 1024,
            finalizationState: .finalized
        )
    }

    private func mediaTime(_ seconds: Double) -> MeetingMediaTime {
        MeetingMediaTime(value: Int64((seconds * 1000).rounded()), timescale: 1000)
    }

    private func era(
        protection: MeetingMicrophoneEchoProtection,
        start: Double,
        deviceUID: String = "mic-a",
        drift: MeetingClockDriftRecord? = nil
    ) -> MeetingCaptureEra {
        MeetingCaptureEra(
            method: .voiceProcessing,
            deviceUID: deviceUID,
            deviceName: deviceUID,
            roleAtElection: .unknown,
            echoProtection: protection,
            startSeconds: start,
            clockDrift: drift
        )
    }

    private func track(
        id: UUID = UUID(),
        kind: MeetingAudioTrackKind,
        chunks: [MeetingAudioChunk],
        captureMethod: MeetingAudioTrackCaptureMethod? = nil,
        // nil requests the fixture default; an empty collection tests explicitly missing data.
        // swiftlint:disable:next discouraged_optional_collection
        eras: [MeetingCaptureEra]? = nil
    ) -> MeetingAudioTrack {
        MeetingAudioTrack(
            id: id,
            kind: kind,
            sourceIdentifier: kind.rawValue,
            sourceDisplayName: kind.rawValue,
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 42,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: chunks,
            captureMethod: captureMethod,
            captureEras: eras
        )
    }

    private func plan(
        mode: MeetingCaptureMode,
        tracks: [MeetingAudioTrack]
    ) -> MeetingBackendPlan {
        let application = mode == .onlineCall
            ? MeetingApplicationIdentity(bundleIdentifier: "fixture.app", displayName: "Fixture")
            : nil
        var session = MeetingSession(
            configuration: MeetingCaptureConfiguration(
                mode: mode,
                title: "Assembler fixture",
                application: application,
                microphone: MeetingMicrophoneIdentity(
                    captureDeviceID: "mic-a",
                    coreAudioUID: "mic-a",
                    displayName: "Mic"
                )
            ),
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 1,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            )
        )
        session.audioTracks = tracks
        let request = MeetingBackendRequest(
            attemptID: UUID(),
            session: session,
            sessionDirectory: FileManager.default.temporaryDirectory,
            configuration: MeetingFinalProcessingConfiguration()
        )
        return MeetingBackendPlan(
            request: request,
            descriptor: MeetingBackendDescriptor(
                id: self.backendID,
                version: "c2b1-test",
                execution: .local,
                supportedLanguageCodes: ["en"],
                supportedTrackKinds: Set(MeetingAudioTrackKind.allCases),
                supportedFinalPrecisions: [.word, .utterance],
                resultContract: .canonicalEvidence,
                knownLimits: []
            )
        )
    }

    private func observed(
        _ chunk: MeetingAudioChunk,
        duration: Double,
        priming: MeetingCodecPriming = .measuredFrames(0)
    ) -> MeetingChunkObservationResult {
        .observed(MeetingChunkObservedAudio(
            byteCount: chunk.byteCount,
            sha256: chunk.sha256,
            decoded: MeetingChunkDecodedFacts(
                sampleRate: 100,
                channelCount: 1,
                frameCount: Int64((duration * 100).rounded()),
                durationSeconds: duration,
                codecPriming: priming,
                processingFormatDescription: "fixture"
            )
        ))
    }

    private func buildManifest(
        plan: MeetingBackendPlan,
        observations: [(MeetingAudioTrackID, MeetingAudioChunk, MeetingChunkObservationResult)]
    ) throws -> MeetingAnalysisManifest {
        try MeetingAnalysisManifestBuilder(
            plan: plan,
            observer: AssemblerFixtureObserver(results: Dictionary(
                uniqueKeysWithValues: observations.map {
                    (MeetingAnalysisChunkKey(trackID: $0.0, chunkID: $0.1.id), $0.2)
                }
            ))
        ).build()
    }

    /// One online microphone chunk, presentation 100..<100+duration>, one admissible era.
    private func onlineMicFixture(
        duration: Double = 10,
        priming: MeetingCodecPriming = .measuredFrames(0),
        drift: MeetingClockDriftRecord? = nil
    ) throws -> (plan: MeetingBackendPlan, manifest: MeetingAnalysisManifest, span: MeetingAnalysisSpan) {
        let chunk = self.chunk(sequence: 0, start: 100, end: 100 + duration)
        let track = self.track(
            kind: .microphone,
            chunks: [chunk],
            eras: [self.era(protection: .voiceProcessed, start: 100, drift: drift)]
        )
        let plan = self.plan(mode: .onlineCall, tracks: [track])
        let manifest = try self.buildManifest(
            plan: plan,
            observations: [(track.id, chunk, self.observed(chunk, duration: duration, priming: priming))]
        )
        let span = try XCTUnwrap(manifest.track(track.id)?.spans.first)
        return (plan, manifest, span)
    }

    private func receipts(
        for manifest: MeetingAnalysisManifest,
        status: MeetingSpanCoverageStatus = .processed
    ) -> [MeetingSpanCoverageReceipt] {
        manifest.allSpans.enumerated().map { index, span in
            MeetingSpanCoverageReceipt(
                id: "receipt-\(index)",
                spanID: span.id,
                analysisStart: span.analysisInterval.start,
                analysisEnd: span.analysisInterval.end,
                status: status
            )
        }
    }

    private func unit(
        id: String,
        span: MeetingAnalysisSpan,
        text: String = "word",
        analysisStart: TimeInterval? = nil,
        analysisEnd: TimeInterval? = nil,
        epoch: MeetingAnalysisEpochID? = nil,
        speaker: MeetingBackendSpeakerAssignment? = nil,
        // nil requests the fixture default; an empty collection tests explicitly missing data.
        // swiftlint:disable:next discouraged_optional_collection
        spanIDs: [String]? = nil,
        confidence: Double? = nil
    ) -> MeetingFinalTextUnit {
        let resolvedEpoch = epoch ?? span.analysisEpochID
        return MeetingFinalTextUnit(
            id: id,
            trackID: span.trackID,
            analysisEpochID: resolvedEpoch,
            precision: .word,
            text: text,
            analysisStart: analysisStart ?? span.analysisInterval.start,
            analysisEnd: analysisEnd ?? span.analysisInterval.end,
            speaker: speaker ?? .assigned(
                MeetingBackendSpeakerToken(analysisEpochID: resolvedEpoch, label: "slot-0")
            ),
            analysisSpanIDs: spanIDs ?? [span.id],
            confidence: confidence
        )
    }

    private func evidence(
        plan: MeetingBackendPlan,
        units: [MeetingFinalTextUnit],
        activity: [MeetingBackendSpeakerActivity] = []
    ) -> MeetingFinalTranscriptEvidence {
        MeetingFinalTranscriptEvidence(
            backendID: plan.backendID,
            attemptID: plan.attemptID,
            units: units,
            speakerActivity: activity
        )
    }

    private func dispositions(
        _ result: MeetingAssemblyResult
    ) -> [String: MeetingTextUnitDispositionRecord] {
        Dictionary(
            result.sidecar.dispositions.map { ($0.unitID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - Deterministic identity

    func testDeterministicIDsAndSpeakerIsolationAcrossTracksAndAttempts() throws {
        let micChunk = self.chunk(sequence: 0, start: 100, end: 110)
        let appChunk = self.chunk(sequence: 0, start: 100, end: 110)
        let mic = self.track(
            kind: .microphone,
            chunks: [micChunk],
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let app = self.track(kind: .applicationAudio, chunks: [appChunk])
        let plan = self.plan(mode: .onlineCall, tracks: [mic, app])
        let manifest = try self.buildManifest(plan: plan, observations: [
            (mic.id, micChunk, self.observed(micChunk, duration: 10)),
            (app.id, appChunk, self.observed(appChunk, duration: 10)),
        ])
        let micSpan = try XCTUnwrap(manifest.track(mic.id)?.spans.first)
        let appSpan = try XCTUnwrap(manifest.track(app.id)?.spans.first)

        // The same backend label on two tracks: the product speakers must never merge.
        let units = [
            self.unit(id: "m-0", span: micSpan, text: "mine", analysisStart: 1, analysisEnd: 2),
            self.unit(id: "a-0", span: appSpan, text: "remote", analysisStart: 1, analysisEnd: 2),
        ]
        let input = MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: units),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["m-0": .notEcho]
        )
        let first = try MeetingTranscriptAssembler().assemble(input)
        let second = try MeetingTranscriptAssembler().assemble(input)
        XCTAssertEqual(first, second)

        XCTAssertEqual(first.speakers.count, 2)
        XCTAssertEqual(Set(first.speakers.map(\.id)).count, 2)
        XCTAssertTrue(first.speakers.allSatisfy { !$0.isLocalUser && $0.identityCandidates.isEmpty })
        XCTAssertEqual(Set(first.speakers.map(\.trackKind)), [.microphone, .applicationAudio])

        let micSegment = try XCTUnwrap(first.segments.first { $0.sourceTrackID == mic.id })
        let appSegment = try XCTUnwrap(first.segments.first { $0.sourceTrackID == app.id })
        XCTAssertNotEqual(micSegment.speakerID, appSegment.speakerID)
        XCTAssertNotNil(micSegment.speakerID)
        XCTAssertNotNil(appSegment.speakerID)
        XCTAssertEqual(micSegment.start.seconds, 1, accuracy: 1e-3)
        XCTAssertEqual(micSegment.end.seconds, 2, accuracy: 1e-3)
    }

    func testSameLabelAcrossEpochsNeverMerges() throws {
        let first = self.chunk(sequence: 0, start: 100, end: 105)
        let second = self.chunk(
            sequence: 1,
            start: 105,
            end: 110,
            discontinuities: [MeetingAudioDiscontinuity(
                kind: .microphoneDisconnected,
                presentationTime: self.mediaTime(105),
                gapSeconds: 0,
                detail: "fixture"
            )]
        )
        let mic = self.track(
            kind: .microphone,
            chunks: [first, second],
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let plan = self.plan(mode: .onlineCall, tracks: [mic])
        let manifest = try self.buildManifest(plan: plan, observations: [
            (mic.id, first, self.observed(first, duration: 5)),
            (mic.id, second, self.observed(second, duration: 5)),
        ])
        let spans = try XCTUnwrap(manifest.track(mic.id)?.spans)
        XCTAssertEqual(spans.count, 2)
        XCTAssertNotEqual(spans[0].analysisEpochID, spans[1].analysisEpochID)

        let units = [
            self.unit(id: "u-0", span: spans[0], analysisStart: 1, analysisEnd: 2),
            self.unit(id: "u-1", span: spans[1], analysisStart: 6, analysisEnd: 7),
        ]
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: units),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["u-0": .notEcho, "u-1": .notEcho]
        ))
        // Same label, same track, different epochs: two speakers, never one.
        XCTAssertEqual(result.speakers.count, 2)
        XCTAssertNotEqual(result.speakers[0].id, result.speakers[1].id)
        XCTAssertEqual(Set(result.speakers.compactMap(\.diarizationClusterID)).count, 2)
        XCTAssertEqual(Set(result.segments.compactMap(\.speakerID)).count, 2)
        let embedding = [Float](repeating: 0.0625, count: 256)
        let profiles = spans.map {
            MeetingSpeakerVoiceProfile(
                token: .init(analysisEpochID: $0.analysisEpochID, label: "slot-0"),
                embeddings: [embedding, embedding]
            )
        }
        let matched = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: MeetingFinalTranscriptEvidence(
                backendID: plan.backendID, attemptID: plan.attemptID, units: units, voiceProfiles: profiles
            ),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["u-0": .notEcho, "u-1": .notEcho]
        ))
        XCTAssertEqual(matched.speakers.count, 1)
        XCTAssertEqual(Set(matched.segments.compactMap(\.speakerID)).count, 1)
        XCTAssertEqual(matched.segments.map(\.text), result.segments.map(\.text))
        XCTAssertEqual(matched.segments.map(\.start), result.segments.map(\.start))
        XCTAssertEqual(matched.coverageGaps, result.coverageGaps)
        XCTAssertEqual(matched.sidecar.speakerIdentityLinks.count, 1)
        let decoded = try JSONDecoder().decode(MeetingResultSidecar.self, from: JSONEncoder().encode(matched.sidecar))
        XCTAssertEqual(try decoded.validated(), matched.sidecar)
    }

    // MARK: - Mapping

    func testAnalysisIntervalMapsThroughSpansExactlyOnceIncludingDrift() throws {
        // An eligible VPIO drift fit: factor 1.00006. The segment must carry exactly one
        // application of that rate — the manifest's transform — never a second correction.
        let drift = MeetingClockDriftRecord(
            cumulativeAbsorbedSeconds: 0.006,
            elapsedValidHostSeconds: 100,
            eligible: true
        )
        let (plan, manifest, span) = try self.onlineMicFixture(drift: drift)
        guard case .appliedOnce = span.timing.deDrift else {
            return XCTFail("fixture must exercise a real de-drift application")
        }
        let transform = span.presentationMapping
        XCTAssertNotEqual(transform.rateRatio, 1)

        let unit = self.unit(id: "u-0", span: span, analysisStart: 1, analysisEnd: 2)
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["u-0": .notEcho]
        ))
        let segment = try XCTUnwrap(result.segments.first)
        let expectedStart = transform.presentationTime(forAnalysisTime: 1)
        let expectedEnd = transform.presentationTime(forAnalysisTime: 2)
        XCTAssertEqual(segment.start.seconds, expectedStart, accuracy: 1e-3)
        XCTAssertEqual(segment.end.seconds, expectedEnd, accuracy: 1e-3)
        XCTAssertEqual(self.dispositions(result)[unit.id]?.disposition, .emitted)
    }

    func testCrossSpanUnitMapsOnceAcrossChunkBoundary() throws {
        let first = self.chunk(sequence: 0, start: 100, end: 105)
        let second = self.chunk(sequence: 1, start: 105, end: 110)
        let mic = self.track(
            kind: .microphone,
            chunks: [first, second],
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let plan = self.plan(mode: .onlineCall, tracks: [mic])
        let manifest = try self.buildManifest(plan: plan, observations: [
            (mic.id, first, self.observed(first, duration: 5)),
            (mic.id, second, self.observed(second, duration: 5)),
        ])
        let spans = try XCTUnwrap(manifest.track(mic.id)?.spans)
        XCTAssertEqual(spans.count, 2)

        let unit = self.unit(
            id: "u-0",
            span: spans[0],
            analysisStart: 4.5,
            analysisEnd: 5.5,
            spanIDs: spans.map(\.id)
        )
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["u-0": .notEcho]
        ))
        let segment = try XCTUnwrap(result.segments.first)
        // Start maps through the first span's transform, end through the last's — once each.
        let expectedStart = spans[0].presentationMapping.presentationTime(forAnalysisTime: 4.5)
        let expectedEnd = spans[1].presentationMapping.presentationTime(forAnalysisTime: 5.5)
        XCTAssertEqual(segment.start.seconds, expectedStart, accuracy: 1e-3)
        XCTAssertEqual(segment.end.seconds, expectedEnd, accuracy: 1e-3)
        XCTAssertEqual(self.dispositions(result)[unit.id]?.disposition, .emitted)
    }

    // MARK: - Quarantine

    func testInvalidTimingAndBrokenSpanProvenanceQuarantineUnits() throws {
        let chunks = (0..<3).map { self.chunk(sequence: $0, start: 100 + 2 * Double($0), end: 102 + 2 * Double($0)) }
        let mic = self.track(
            kind: .microphone,
            chunks: chunks,
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let plan = self.plan(mode: .onlineCall, tracks: [mic])
        let manifest = try self.buildManifest(
            plan: plan,
            observations: chunks.map { (mic.id, $0, self.observed($0, duration: 2)) }
        )
        let spans = try XCTUnwrap(manifest.track(mic.id)?.spans)
        XCTAssertEqual(spans.count, 3)

        let units = [
            self.unit(id: "bad-time", span: spans[0], analysisStart: 2, analysisEnd: 2),
            self.unit(
                id: "skip-span",
                span: spans[0],
                analysisStart: 0.5,
                analysisEnd: 5.5,
                spanIDs: [spans[0].id, spans[2].id]
            ),
            self.unit(id: "out-of-bounds", span: spans[2], analysisStart: 5.5, analysisEnd: 6.5),
            self.unit(id: "bad-confidence", span: spans[1], confidence: 2),
        ]
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: units),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: [:]
        ))
        let ledger = self.dispositions(result)
        XCTAssertEqual(
            ledger["bad-time"]?.reasonCode,
            MeetingUnitQuarantineReason.invalidTiming.rawValue
        )
        XCTAssertEqual(
            ledger["skip-span"]?.reasonCode,
            MeetingUnitQuarantineReason.spansNotContiguousWithinEpoch.rawValue
        )
        XCTAssertEqual(
            ledger["out-of-bounds"]?.reasonCode,
            MeetingUnitQuarantineReason.spansDoNotCoverUnitInterval.rawValue
        )
        XCTAssertEqual(
            ledger["bad-confidence"]?.reasonCode,
            MeetingUnitQuarantineReason.invalidConfidence.rawValue
        )
        XCTAssertTrue(ledger.values.allSatisfy { $0.disposition == .rejectedInvalidTiming })
        // Quarantined units never reach segments, and quarantine needs no echo verdicts.
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertNoThrow(try result.sidecar.validated())
    }

    func testUnitWhoseSpansBelongToAnotherEpochIsQuarantined() throws {
        let first = self.chunk(sequence: 0, start: 100, end: 105)
        let second = self.chunk(
            sequence: 1,
            start: 105,
            end: 110,
            discontinuities: [MeetingAudioDiscontinuity(
                kind: .clockDiscontinuity,
                presentationTime: self.mediaTime(105),
                gapSeconds: nil,
                detail: "fixture"
            )]
        )
        let mic = self.track(
            kind: .microphone,
            chunks: [first, second],
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let plan = self.plan(mode: .onlineCall, tracks: [mic])
        let manifest = try self.buildManifest(plan: plan, observations: [
            (mic.id, first, self.observed(first, duration: 5)),
            (mic.id, second, self.observed(second, duration: 5)),
        ])
        let spans = try XCTUnwrap(manifest.track(mic.id)?.spans)
        XCTAssertEqual(spans.count, 2)

        // Declares epoch 0, points at an epoch-1 span: provenance the assembler cannot honor.
        let unit = self.unit(
            id: "epoch-mismatch",
            span: spans[1],
            analysisStart: 5.5,
            analysisEnd: 6.5,
            epoch: spans[0].analysisEpochID,
            spanIDs: [spans[1].id]
        )
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: self.receipts(for: manifest)
        ))
        let record = try XCTUnwrap(self.dispositions(result)[unit.id])
        XCTAssertEqual(record.disposition, .rejectedInvalidTiming)
        XCTAssertEqual(record.reasonCode, MeetingUnitQuarantineReason.analysisEpochMismatch.rawValue)
        XCTAssertTrue(result.segments.isEmpty)
    }

    // MARK: - Ambiguity and activity

    func testAmbiguousUnitAppearsExactlyOnceUnassigned() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let unit = self.unit(
            id: "u-amb",
            span: span,
            text: "overlapped",
            analysisStart: 1,
            analysisEnd: 2,
            speaker: .ambiguous([
                MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "slot-0"),
                MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "slot-1"),
            ])
        )
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["u-amb": .notEcho]
        ))
        XCTAssertEqual(self.dispositions(result)[unit.id]?.disposition, .ambiguousUnassigned)
        let matching = result.segments.filter { $0.text == "overlapped" }
        XCTAssertEqual(matching.count, 1)
        XCTAssertNil(matching[0].speakerID)
        XCTAssertEqual(matching[0].overlap, .ambiguous)
        XCTAssertEqual(matching[0].attributionState, .overlappingSpeakers)
        // Ambiguity candidates are reported, never resolved into product speakers.
        XCTAssertTrue(result.speakers.isEmpty)
    }

    func testUncertainTimingIsAdmittedAsAmbiguous() throws {
        // Unknown codec priming leaves the span timing-uncertain: the text stays visible but is
        // never confidently assigned to a speaker.
        let (plan, manifest, span) = try self.onlineMicFixture(priming: .unknown(.decoderDidNotReport))
        XCTAssertEqual(span.timing.certainty, .timingUncertain)
        let unit = self.unit(id: "u-0", span: span, analysisStart: 1, analysisEnd: 2)
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["u-0": .notEcho]
        ))
        let record = try XCTUnwrap(self.dispositions(result)[unit.id])
        XCTAssertEqual(record.disposition, .ambiguousUnassigned)
        XCTAssertEqual(record.reasonCode, "timingUncertain")
        let segment = try XCTUnwrap(result.segments.first)
        XCTAssertNil(segment.speakerID)
        // Timing uncertainty is not speaker overlap: the segment carries no cross-speaker overlap
        // marker, only the distinct `timingUncertain` attribution state.
        XCTAssertEqual(segment.overlap, .none)
        XCTAssertEqual(segment.attributionState, .timingUncertain)
        XCTAssertTrue(result.speakers.isEmpty)
    }

    func testUnitOutsideSpeakerActivityIsExcluded() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let activity = [
            MeetingBackendSpeakerActivity(
                token: MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "slot-0"),
                start: 0,
                end: 1
            ),
        ]
        let inside = self.unit(id: "u-in", span: span, text: "inside", analysisStart: 0.2, analysisEnd: 0.8)
        let outside = self.unit(id: "u-out", span: span, text: "outside", analysisStart: 2, analysisEnd: 3)
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [inside, outside], activity: activity),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["u-in": .notEcho, "u-out": .notEcho]
        ))
        let ledger = self.dispositions(result)
        XCTAssertEqual(ledger[inside.id]?.disposition, .emitted)
        XCTAssertEqual(ledger[outside.id]?.disposition, .outsideActivity)
        XCTAssertEqual(result.segments.map(\.text), ["inside"])
    }

    func testSpeakerActivityMustStayInsideItsEpoch() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let unit = self.unit(id: "u-0", span: span, analysisStart: 1, analysisEnd: 2)
        let activity = MeetingBackendSpeakerActivity(
            token: MeetingBackendSpeakerToken(
                analysisEpochID: span.analysisEpochID,
                label: "slot-0"
            ),
            start: 9,
            end: 11
        )
        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit], activity: [activity]),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: [unit.id: .notEcho]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingBackendEvidenceError,
                .activityOutsideEpoch(index: 0)
            )
        }
    }

    // MARK: - Echo

    func testOnlineMicrophoneWithoutEchoVerdictFailsAssembly() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let unit = self.unit(id: "u-0", span: span, analysisStart: 1, analysisEnd: 2)
        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: self.receipts(for: manifest)
        ))) { error in
            XCTAssertEqual(error as? MeetingAssemblyError, .missingEchoVerdict(unitID: "u-0"))
        }
    }

    func testEchoSuppressedMicrophoneIsLedgerOnlyAndApplicationCopyIsRetained() throws {
        let micChunk = self.chunk(sequence: 0, start: 100, end: 110)
        let appChunk = self.chunk(sequence: 0, start: 100, end: 110)
        let mic = self.track(
            kind: .microphone,
            chunks: [micChunk],
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let app = self.track(kind: .applicationAudio, chunks: [appChunk])
        let plan = self.plan(mode: .onlineCall, tracks: [mic, app])
        let manifest = try self.buildManifest(plan: plan, observations: [
            (mic.id, micChunk, self.observed(micChunk, duration: 10)),
            (app.id, appChunk, self.observed(appChunk, duration: 10)),
        ])
        let micSpan = try XCTUnwrap(manifest.track(mic.id)?.spans.first)
        let appSpan = try XCTUnwrap(manifest.track(app.id)?.spans.first)

        let micUnit = self.unit(id: "m-echo", span: micSpan, text: "remote words", analysisStart: 1, analysisEnd: 2)
        let appUnit = self.unit(id: "a-0", span: appSpan, text: "remote words", analysisStart: 1, analysisEnd: 2)
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [micUnit, appUnit]),
            coverageReceipts: self.receipts(for: manifest),
            // The application track is remote evidence and needs no verdict; the microphone copy
            // is suppressed by a real one.
            echoVerdicts: ["m-echo": .echoSuppressed(duplicateOfUnitID: "a-0")]
        ))
        let ledger = self.dispositions(result)
        XCTAssertEqual(ledger[micUnit.id]?.disposition, .echoSuppressed)
        XCTAssertEqual(ledger[appUnit.id]?.disposition, .emitted)
        XCTAssertEqual(result.segments.map(\.text), ["remote words"])
        XCTAssertEqual(result.segments[0].sourceTrackID, app.id)
        // Ledger-only still means ledger: the suppressed mic copy stays in the sidecar.
        XCTAssertTrue(result.sidecar.units.contains { $0.id == micUnit.id })
        XCTAssertEqual(result.speakers.count, 1)
        XCTAssertEqual(result.speakers[0].trackKind, .applicationAudio)
    }

    func testInRoomMicrophoneBypassesEchoAdmission() throws {
        let chunk = self.chunk(sequence: 0, start: 100, end: 110)
        let mic = self.track(
            kind: .microphone,
            chunks: [chunk],
            captureMethod: .avCaptureSession
        )
        let plan = self.plan(mode: .inRoom, tracks: [mic])
        let manifest = try self.buildManifest(
            plan: plan,
            observations: [(mic.id, chunk, self.observed(chunk, duration: 10))]
        )
        let span = try XCTUnwrap(manifest.track(mic.id)?.spans.first)
        let unit = self.unit(id: "u-0", span: span, analysisStart: 1, analysisEnd: 2)
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: self.receipts(for: manifest)
        ))
        XCTAssertEqual(self.dispositions(result)[unit.id]?.disposition, .emitted)
        XCTAssertEqual(result.segments.count, 1)
    }

    func testEchoVerdictForUnknownUnitThrows() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let unit = self.unit(id: "u-0", span: span, analysisStart: 1, analysisEnd: 2)
        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["u-0": .notEcho, "ghost": .notEcho]
        ))) { error in
            XCTAssertEqual(error as? MeetingAssemblyError, .echoVerdictForUnknownUnit(unitID: "ghost"))
        }
    }

    // MARK: - Coverage

    func testExactReceiptTilingAndTruncationGap() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let unit = self.unit(id: "u-0", span: span, analysisStart: 1, analysisEnd: 2)
        let receipts = [
            MeetingSpanCoverageReceipt(
                id: "r-0", spanID: span.id, analysisStart: 0, analysisEnd: 4, status: .processed
            ),
            MeetingSpanCoverageReceipt(
                id: "r-1",
                spanID: span.id,
                analysisStart: 4,
                analysisEnd: 10,
                status: .providerTruncated
            ),
        ]
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: receipts,
            echoVerdicts: ["u-0": .notEcho]
        ))
        XCTAssertFalse(result.isComplete)
        let gap = try XCTUnwrap(result.coverageGaps.first)
        XCTAssertEqual(gap.reason, .providerTruncated)
        XCTAssertEqual(gap.trackID, span.trackID)
        XCTAssertEqual(gap.start, 4, accuracy: 1e-3)
        XCTAssertEqual(gap.end, 10, accuracy: 1e-3)
        // Truncation is a coverage fact, not a text fact: the recognized unit is still emitted.
        XCTAssertEqual(self.dispositions(result)[unit.id]?.disposition, .emitted)
    }

    func testMissingReceiptFailsEvenWhenTextExists() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let unit = self.unit(id: "u-0", span: span, analysisStart: 1, analysisEnd: 2)
        // A span full of recognized text but no receipt: text never implies coverage.
        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: [],
            echoVerdicts: ["u-0": .notEcho]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError, .missingCoverageReceipt(spanID: span.id)
            )
        }
    }

    func testDuplicateUnknownOutOfBoundsAndPartialReceiptsThrow() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let validReceipts = self.receipts(for: manifest)
        let baseEvidence = self.evidence(plan: plan, units: [])

        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: baseEvidence,
            coverageReceipts: validReceipts + [MeetingSpanCoverageReceipt(
                id: "receipt-0", spanID: span.id, analysisStart: 9, analysisEnd: 10, status: .processed
            )]
        ))) { error in
            XCTAssertEqual(error as? MeetingAssemblyError, .duplicateCoverageReceiptID("receipt-0"))
        }

        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: baseEvidence,
            coverageReceipts: [MeetingSpanCoverageReceipt(
                id: "r-x", spanID: "no-such-span", analysisStart: 0, analysisEnd: 1, status: .processed
            )]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError, .unknownCoverageReceiptSpan(spanID: "no-such-span")
            )
        }

        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: baseEvidence,
            coverageReceipts: [MeetingSpanCoverageReceipt(
                id: "r-oob", spanID: span.id, analysisStart: 0, analysisEnd: 99, status: .processed
            )]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError, .coverageReceiptOutOfBounds(receiptID: "r-oob")
            )
        }

        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: baseEvidence,
            coverageReceipts: [
                MeetingSpanCoverageReceipt(
                    id: "r-0", spanID: span.id, analysisStart: 0, analysisEnd: 6, status: .processed
                ),
                MeetingSpanCoverageReceipt(
                    id: "r-1", spanID: span.id, analysisStart: 5, analysisEnd: 10, status: .processed
                ),
            ]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError, .overlappingCoverageReceipts(spanID: span.id)
            )
        }

        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: baseEvidence,
            coverageReceipts: [MeetingSpanCoverageReceipt(
                id: "r-partial", spanID: span.id, analysisStart: 0, analysisEnd: 5, status: .processed
            )]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError, .missingCoverageReceipt(spanID: span.id)
            )
        }

        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: baseEvidence,
            coverageReceipts: [MeetingSpanCoverageReceipt(
                id: "r-flat", spanID: span.id, analysisStart: 5, analysisEnd: 5, status: .processed
            )]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError, .invalidCoverageReceiptInterval(receiptID: "r-flat")
            )
        }
    }

    func testFailedAndSkippedReceiptsSurfaceAsGapsAndSkippedChunks() throws {
        let first = self.chunk(sequence: 0, start: 100, end: 105)
        let second = self.chunk(sequence: 1, start: 105, end: 110)
        let mic = self.track(
            kind: .microphone,
            chunks: [first, second],
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let plan = self.plan(mode: .onlineCall, tracks: [mic])
        let manifest = try self.buildManifest(plan: plan, observations: [
            (mic.id, first, self.observed(first, duration: 5)),
            (mic.id, second, self.observed(second, duration: 5)),
        ])
        let spans = try XCTUnwrap(manifest.track(mic.id)?.spans)
        let receipts = [
            MeetingSpanCoverageReceipt(
                id: "r-0", spanID: spans[0].id, analysisStart: 0, analysisEnd: 5, status: .failed
            ),
            MeetingSpanCoverageReceipt(
                id: "r-1", spanID: spans[1].id, analysisStart: 5, analysisEnd: 10, status: .skipped
            ),
        ]
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: []),
            coverageReceipts: receipts
        ))
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.coverageGaps.map(\.reason), [.processingFailed, .skipped])
        XCTAssertEqual(
            result.skippedChunks,
            [MeetingAnalysisChunkIdentity(trackID: mic.id, chunk: second)]
        )
        XCTAssertTrue(result.segments.isEmpty)
    }

    func testTextCannotEmitFromFailedOrTruncatedReceiptRegion() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let failedUnit = self.unit(
            id: "failed-text", span: span, analysisStart: 1, analysisEnd: 2
        )
        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [failedUnit]),
            coverageReceipts: [MeetingSpanCoverageReceipt(
                id: "failed-receipt",
                spanID: span.id,
                analysisStart: 0,
                analysisEnd: 10,
                status: .failed
            )],
            echoVerdicts: [failedUnit.id: .notEcho]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError,
                .textContradictsCoverage(
                    unitID: failedUnit.id,
                    receiptID: "failed-receipt",
                    status: .failed
                )
            )
        }

        let truncatedUnit = self.unit(
            id: "truncated-text", span: span, analysisStart: 5, analysisEnd: 6
        )
        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [truncatedUnit]),
            coverageReceipts: [
                MeetingSpanCoverageReceipt(
                    id: "processed-prefix",
                    spanID: span.id,
                    analysisStart: 0,
                    analysisEnd: 4,
                    status: .processed
                ),
                MeetingSpanCoverageReceipt(
                    id: "truncated-tail",
                    spanID: span.id,
                    analysisStart: 4,
                    analysisEnd: 10,
                    status: .providerTruncated
                ),
            ],
            echoVerdicts: [truncatedUnit.id: .notEcho]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError,
                .textContradictsCoverage(
                    unitID: truncatedUnit.id,
                    receiptID: "truncated-tail",
                    status: .providerTruncated
                )
            )
        }
    }

    func testManifestGapsSurfaceAsProductCoverageGaps() throws {
        let chunk = self.chunk(sequence: 0, start: 100, end: 110)
        let mic = self.track(
            kind: .microphone,
            chunks: [chunk],
            eras: [
                self.era(protection: .voiceProcessed, start: 100),
                self.era(protection: .unprotected, start: 105),
                self.era(protection: .softwareEchoCancelled, start: 108),
            ]
        )
        let plan = self.plan(mode: .onlineCall, tracks: [mic])
        let manifest = try self.buildManifest(
            plan: plan,
            observations: [(mic.id, chunk, self.observed(chunk, duration: 10))]
        )
        let spans = try XCTUnwrap(manifest.track(mic.id)?.spans)
        let units = spans.enumerated().map { index, span in
            self.unit(id: "u-\(index)", span: span)
        }
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: units),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: Dictionary(uniqueKeysWithValues: units.map { ($0.id, MeetingUnitEchoVerdict.notEcho) })
        ))
        XCTAssertFalse(result.isComplete)
        let inadmissible = try XCTUnwrap(result.coverageGaps.first { $0.reason == .inadmissibleCaptureEra })
        XCTAssertEqual(inadmissible.start, 5, accuracy: 1e-3)
        XCTAssertEqual(inadmissible.end, 8, accuracy: 1e-3)
        // The unprotected era was never analyzed, so both admissible pieces' text is emitted.
        XCTAssertEqual(Set(result.segments.map(\.text)), Set(units.map(\.text)))
    }

    // MARK: - Conservation

    func testEveryInputUnitHasExactlyOneDispositionAndExcludedUnitsNeverAppear() throws {
        let micChunk = self.chunk(sequence: 0, start: 100, end: 110)
        let appChunk = self.chunk(sequence: 0, start: 100, end: 110)
        let mic = self.track(
            kind: .microphone,
            chunks: [micChunk],
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let app = self.track(kind: .applicationAudio, chunks: [appChunk])
        let plan = self.plan(mode: .onlineCall, tracks: [mic, app])
        let manifest = try self.buildManifest(plan: plan, observations: [
            (mic.id, micChunk, self.observed(micChunk, duration: 10)),
            (app.id, appChunk, self.observed(appChunk, duration: 10)),
        ])
        let micSpan = try XCTUnwrap(manifest.track(mic.id)?.spans.first)
        let appSpan = try XCTUnwrap(manifest.track(app.id)?.spans.first)
        let activity = [
            MeetingBackendSpeakerActivity(
                token: MeetingBackendSpeakerToken(analysisEpochID: micSpan.analysisEpochID, label: "slot-0"),
                start: 0,
                end: 5
            ),
        ]

        let units = [
            self.unit(id: "emitted", span: micSpan, text: "kept", analysisStart: 1, analysisEnd: 2),
            self.unit(
                id: "ambiguous",
                span: micSpan,
                text: "fuzzy",
                analysisStart: 1.5,
                analysisEnd: 2.5,
                speaker: .ambiguous([
                    MeetingBackendSpeakerToken(analysisEpochID: micSpan.analysisEpochID, label: "slot-0"),
                    MeetingBackendSpeakerToken(analysisEpochID: micSpan.analysisEpochID, label: "slot-1"),
                ])
            ),
            self.unit(id: "quarantined", span: micSpan, text: "broken", analysisStart: 3, analysisEnd: 3),
            self.unit(id: "echo", span: micSpan, text: "copy", analysisStart: 2, analysisEnd: 3),
            self.unit(id: "inactive", span: micSpan, text: "idle", analysisStart: 7, analysisEnd: 8),
            self.unit(id: "remote", span: appSpan, text: "remote", analysisStart: 1, analysisEnd: 2),
        ]
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: units, activity: activity),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: [
                "emitted": .notEcho,
                "ambiguous": .notEcho,
                "echo": .echoSuppressed(duplicateOfUnitID: "remote"),
                "inactive": .notEcho,
            ]
        ))

        let ledger = self.dispositions(result)
        XCTAssertEqual(Set(ledger.keys), Set(units.map(\.id)))
        XCTAssertEqual(result.sidecar.dispositions.count, units.count)
        XCTAssertEqual(ledger["emitted"]?.disposition, .emitted)
        XCTAssertEqual(ledger["ambiguous"]?.disposition, .ambiguousUnassigned)
        XCTAssertEqual(ledger["quarantined"]?.disposition, .rejectedInvalidTiming)
        XCTAssertEqual(ledger["echo"]?.disposition, .echoSuppressed)
        XCTAssertEqual(ledger["inactive"]?.disposition, .outsideActivity)
        XCTAssertEqual(ledger["remote"]?.disposition, .emitted)
        XCTAssertNoThrow(try result.sidecar.validated())

        // Admitted text renders once each; excluded text never renders at all.
        XCTAssertEqual(
            result.segments.map(\.text).sorted(),
            ["fuzzy", "kept", "remote"]
        )
        XCTAssertEqual(
            Set(result.sidecar.units.map(\.id)),
            Set(units.map(\.id))
        )
    }

    func testExtraReferencedSpanIsQuarantinedAndCannotReportComplete() throws {
        let first = self.chunk(sequence: 0, start: 100, end: 105)
        let second = self.chunk(sequence: 1, start: 105, end: 110)
        let mic = self.track(
            kind: .microphone,
            chunks: [first, second],
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let plan = self.plan(mode: .onlineCall, tracks: [mic])
        let manifest = try self.buildManifest(plan: plan, observations: [
            (mic.id, first, self.observed(first, duration: 5)),
            (mic.id, second, self.observed(second, duration: 5)),
        ])
        let spans = try XCTUnwrap(manifest.track(mic.id)?.spans)
        let unit = self.unit(
            id: "extra-span",
            span: spans[1],
            analysisStart: 5.2,
            analysisEnd: 5.8,
            spanIDs: spans.map(\.id)
        )
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: self.receipts(for: manifest)
        ))
        XCTAssertEqual(
            self.dispositions(result)[unit.id]?.reasonCode,
            MeetingUnitQuarantineReason.spansDoNotCoverUnitInterval.rawValue
        )
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertFalse(result.isComplete)
    }

    func testEchoDuplicateTargetMustExistAndBeApplicationAudio() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let first = self.unit(id: "mic-0", span: span, analysisStart: 1, analysisEnd: 2)
        let second = self.unit(id: "mic-1", span: span, analysisStart: 2, analysisEnd: 3)
        let evidence = self.evidence(plan: plan, units: [first, second])

        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: evidence,
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: [
                first.id: .echoSuppressed(duplicateOfUnitID: "missing"),
                second.id: .notEcho,
            ]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError,
                .echoDuplicateTargetUnknown(unitID: first.id, duplicateID: "missing")
            )
        }

        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: evidence,
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: [
                first.id: .echoSuppressed(duplicateOfUnitID: second.id),
                second.id: .notEcho,
            ]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError,
                .echoDuplicateTargetNotApplicationAudio(unitID: first.id, duplicateID: second.id)
            )
        }
    }

    func testEchoDuplicateTargetMustRemainVisible() throws {
        let micChunk = self.chunk(sequence: 0, start: 100, end: 110)
        let appChunk = self.chunk(sequence: 0, start: 100, end: 110)
        let mic = self.track(
            kind: .microphone,
            chunks: [micChunk],
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let app = self.track(kind: .applicationAudio, chunks: [appChunk])
        let plan = self.plan(mode: .onlineCall, tracks: [mic, app])
        let manifest = try self.buildManifest(plan: plan, observations: [
            (mic.id, micChunk, self.observed(micChunk, duration: 10)),
            (app.id, appChunk, self.observed(appChunk, duration: 10)),
        ])
        let micSpan = try XCTUnwrap(manifest.track(mic.id)?.spans.first)
        let appSpan = try XCTUnwrap(manifest.track(app.id)?.spans.first)
        let micUnit = self.unit(id: "mic", span: micSpan, analysisStart: 1, analysisEnd: 2)
        let invalidApp = self.unit(
            id: "app-invalid",
            span: appSpan,
            analysisStart: 1,
            analysisEnd: 1
        )

        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [micUnit, invalidApp]),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: [
                micUnit.id: .echoSuppressed(duplicateOfUnitID: invalidApp.id),
            ]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError,
                .echoDuplicateTargetNotVisible(unitID: micUnit.id, duplicateID: invalidApp.id)
            )
        }
    }

    func testEpochGenerationChangesProductSpeakerIdentityWithoutChangingOrdinal() throws {
        let chunk = self.chunk(sequence: 0, start: 100, end: 110)
        let mic = self.track(
            kind: .microphone,
            chunks: [chunk],
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let plan = self.plan(mode: .onlineCall, tracks: [mic])
        let observations = [(mic.id, chunk, self.observed(chunk, duration: 10))]
        let firstManifest = try self.buildManifest(plan: plan, observations: observations)
        let key = MeetingAnalysisEpochGenerationKey(trackID: mic.id, ordinal: 0)
        let secondManifest = try MeetingAnalysisManifestBuilder(
            plan: plan,
            observer: AssemblerFixtureObserver(results: [
                MeetingAnalysisChunkKey(trackID: mic.id, chunkID: chunk.id):
                    self.observed(chunk, duration: 10),
            ]),
            epochGenerations: [key: 1]
        ).build()
        let firstSpan = try XCTUnwrap(firstManifest.track(mic.id)?.spans.first)
        let secondSpan = try XCTUnwrap(secondManifest.track(mic.id)?.spans.first)
        XCTAssertEqual(firstSpan.analysisEpochID.ordinal, secondSpan.analysisEpochID.ordinal)
        XCTAssertNotEqual(firstSpan.analysisEpochID.generation, secondSpan.analysisEpochID.generation)

        func speakerID(
            manifest: MeetingAnalysisManifest,
            span: MeetingAnalysisSpan
        ) throws -> UUID {
            let unit = self.unit(id: "same-unit", span: span, analysisStart: 1, analysisEnd: 2)
            let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
                plan: plan,
                manifest: manifest,
                evidence: self.evidence(plan: plan, units: [unit]),
                coverageReceipts: self.receipts(for: manifest),
                echoVerdicts: [unit.id: .notEcho]
            ))
            return try XCTUnwrap(result.speakers.first?.id)
        }
        XCTAssertNotEqual(
            try speakerID(manifest: firstManifest, span: firstSpan),
            try speakerID(manifest: secondManifest, span: secondSpan)
        )
    }

    func testSidecarOrderingIsCanonicalAcrossBackendOrdering() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let a = self.unit(id: "a", span: span, analysisStart: 1, analysisEnd: 2)
        let z = self.unit(id: "z", span: span, analysisStart: 3, analysisEnd: 4)
        let receipts = [
            MeetingSpanCoverageReceipt(
                id: "z-receipt",
                spanID: span.id,
                analysisStart: 5,
                analysisEnd: 10,
                status: .processed
            ),
            MeetingSpanCoverageReceipt(
                id: "a-receipt",
                spanID: span.id,
                analysisStart: 0,
                analysisEnd: 5,
                status: .processed
            ),
        ]
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [z, a]),
            coverageReceipts: receipts,
            echoVerdicts: [a.id: .notEcho, z.id: .notEcho]
        ))
        XCTAssertEqual(result.sidecar.units.map(\.id), ["a", "z"])
        XCTAssertEqual(result.sidecar.dispositions.map(\.unitID), ["a", "z"])
        XCTAssertEqual(result.sidecar.coverageReceipts.map(\.id), ["a-receipt", "z-receipt"])
    }

    func testUnpositionedManifestGapCannotReportComplete() throws {
        let chunk = self.chunk(sequence: 0, start: 100, end: 100)
        let mic = self.track(kind: .microphone, chunks: [chunk], captureMethod: .avCaptureSession)
        let plan = self.plan(mode: .inRoom, tracks: [mic])
        let manifest = try self.buildManifest(plan: plan, observations: [])
        XCTAssertEqual(manifest.allGaps.count, 1)
        XCTAssertNil(manifest.allGaps[0].recordedInterval)

        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: []),
            coverageReceipts: []
        ))
        XCTAssertTrue(result.coverageGaps.isEmpty)
        XCTAssertFalse(result.isComplete)
    }

    // MARK: - Attribution state

    func testNormallyEmittedSegmentsCarryAssignedOrUnassignedAttributionState() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let assignedUnit = self.unit(id: "u-assigned", span: span, text: "clear", analysisStart: 1, analysisEnd: 2)
        let unassignedUnit = self.unit(
            id: "u-unassigned",
            span: span,
            text: "noEvidence",
            analysisStart: 3,
            analysisEnd: 4,
            speaker: .unassigned
        )
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [assignedUnit, unassignedUnit]),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["u-assigned": .notEcho, "u-unassigned": .notEcho]
        ))
        XCTAssertEqual(self.dispositions(result)["u-assigned"]?.disposition, .emitted)
        XCTAssertEqual(self.dispositions(result)["u-unassigned"]?.disposition, .emitted)

        let assignedSegment = try XCTUnwrap(result.segments.first { $0.text == "clear" })
        XCTAssertNotNil(assignedSegment.speakerID)
        XCTAssertEqual(assignedSegment.overlap, .none)
        XCTAssertEqual(assignedSegment.attributionState, .assigned)

        let unassignedSegment = try XCTUnwrap(result.segments.first { $0.text == "noEvidence" })
        XCTAssertNil(unassignedSegment.speakerID)
        XCTAssertEqual(unassignedSegment.overlap, .none)
        XCTAssertEqual(unassignedSegment.attributionState, .unassigned)
    }

    /// `attributionState` must stay optional: a non-optional defaulted property makes the
    /// synthesized decoder require the key, and the store silently drops sessions that fail to
    /// decode.
    func testSegmentWithoutAttributionStateKeyStillDecodes() throws {
        let legacySegmentJSON = """
        {
          "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "start": { "value": 0, "timescale": 1000 },
          "end": { "value": 1000, "timescale": 1000 },
          "sourceTrackID": "3F2504E0-4F89-11D3-9A0C-0305E82C3302",
          "text": "legacy segment",
          "revision": 0,
          "status": "final",
          "overlap": "none",
          "completeness": "complete"
        }
        """
        let segment = try JSONDecoder().decode(
            MeetingTranscriptSegment.self,
            from: Data(legacySegmentJSON.utf8)
        )
        XCTAssertNil(segment.attributionState)
    }
}
