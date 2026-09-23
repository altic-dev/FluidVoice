import AVFoundation
import CryptoKit
@testable import FluidVoice_Debug
import Foundation
import XCTest

private nonisolated struct ManifestFixtureObserver: MeetingChunkAudioObserving {
    let results: [MeetingAnalysisChunkKey: MeetingChunkObservationResult]

    func observe(
        chunk: MeetingAudioChunk,
        trackID: MeetingAudioTrackID
    ) -> MeetingChunkObservationResult {
        self.results[MeetingAnalysisChunkKey(trackID: trackID, chunkID: chunk.id)]
            ?? .failed(.unreadable, detail: "No fixture observation")
    }
}

@MainActor
final class MeetingAnalysisManifestTests: XCTestCase {
    private let backendID = MeetingBackendID(rawValue: "fixture.analysis-manifest")

    func testOptInSavedRecordingManifestWithoutChangingSession() throws {
        guard let path = ProcessInfo.processInfo.environment["FLUIDVOICE_MEETING_MANIFEST_SESSION"] else {
            throw XCTSkip("Set FLUIDVOICE_MEETING_MANIFEST_SESSION for read-only real-recording validation.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let sessionURL = directory.appendingPathComponent("session.json")
        let original = try Data(contentsOf: sessionURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(MeetingSession.self, from: original)
        let request = MeetingBackendRequest(
            attemptID: UUID(),
            session: session,
            sessionDirectory: directory,
            configuration: MeetingFinalProcessingConfiguration()
        )
        let plan = MeetingBackendPlan(request: request, descriptor: MeetingParakeetNemotronBackend.descriptor)
        let manifest = try MeetingAnalysisManifestBuilder(
            plan: plan, observer: MeetingChunkAudioObserver(sessionDirectory: directory), analysisSampleRate: 16_000
        ).build()
        for track in manifest.tracks {
            print("MEETING_MANIFEST_REAL track=\(track.kind.rawValue) epochs=\(track.epochs.count) gaps=\(track.gaps.count)")
            for gap in track.gaps where gap.reason == .decodedAudioExhausted {
                if let interval = gap.recordedInterval,
                   let span = track.spans.first(where: { $0.chunk == gap.chunk })
                {
                    XCTAssertGreaterThan(interval.duration, 2 / span.observed.decoded.sampleRate)
                }
            }
        }
        XCTAssertEqual(try Data(contentsOf: sessionURL), original)
    }

    private func chunk(
        id: UUID = UUID(),
        sequence: Int,
        start: Double,
        end: Double,
        path: String? = nil,
        discontinuities: [MeetingAudioDiscontinuity] = [],
        sha256: String? = nil,
        byteCount: Int64 = 1024
    ) -> MeetingAudioChunk {
        MeetingAudioChunk(
            id: id,
            sequence: sequence,
            relativeFilePath: path ?? "tracks/chunk-\(sequence).m4a",
            presentationStart: self.mediaTime(start),
            presentationEnd: self.mediaTime(end),
            discontinuities: discontinuities,
            sha256: sha256 ?? String(repeating: String((sequence % 9) + 1), count: 64),
            byteCount: byteCount,
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
        method: MeetingAudioTrackCaptureMethod = .voiceProcessing,
        drift: MeetingClockDriftRecord? = nil
    ) -> MeetingCaptureEra {
        MeetingCaptureEra(
            method: method,
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
        eras: [MeetingCaptureEra]? = nil,
        hostClock: UInt64 = 42
    ) -> MeetingAudioTrack {
        MeetingAudioTrack(
            id: id,
            kind: kind,
            sourceIdentifier: kind.rawValue,
            sourceDisplayName: kind.rawValue,
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: hostClock,
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
                title: "Manifest fixture",
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
                version: "c2a-test",
                execution: .local,
                supportedLanguageCodes: ["en"],
                supportedTrackKinds: Set(MeetingAudioTrackKind.allCases),
                supportedFinalPrecisions: [.word],
                resultContract: .canonicalEvidence,
                knownLimits: []
            )
        )
    }

    private func observed(
        _ chunk: MeetingAudioChunk,
        duration: Double,
        sampleRate: Double = 100,
        priming: MeetingCodecPriming = .unknown(.decoderDidNotReport)
    ) -> MeetingChunkObservationResult {
        .observed(MeetingChunkObservedAudio(
            byteCount: chunk.byteCount,
            sha256: chunk.sha256,
            decoded: MeetingChunkDecodedFacts(
                sampleRate: sampleRate,
                channelCount: 1,
                frameCount: Int64((duration * sampleRate).rounded()),
                durationSeconds: duration,
                codecPriming: priming,
                processingFormatDescription: "fixture"
            )
        ))
    }

    private func observer(
        _ entries: [(MeetingAudioTrackID, MeetingAudioChunk, MeetingChunkObservationResult)]
    ) -> ManifestFixtureObserver {
        ManifestFixtureObserver(results: Dictionary(
            uniqueKeysWithValues: entries.map {
                (MeetingAnalysisChunkKey(trackID: $0.0, chunkID: $0.1.id), $0.2)
            }
        ))
    }

    private func replacing(
        _ manifest: MeetingAnalysisManifest,
        origin: Double? = nil,
        // nil requests the fixture default; an empty collection tests explicitly missing data.
        // swiftlint:disable:next discouraged_optional_collection
        tracks: [MeetingAnalysisTrackManifest]? = nil
    ) -> MeetingAnalysisManifest {
        MeetingAnalysisManifest(
            backendID: manifest.backendID,
            backendVersion: manifest.backendVersion,
            attemptID: manifest.attemptID,
            sessionID: manifest.sessionID,
            captureMode: manifest.captureMode,
            presentationOriginSeconds: origin ?? manifest.presentationOriginSeconds,
            analysisSampleRate: manifest.analysisSampleRate,
            residualBoundSeconds: manifest.residualBoundSeconds,
            tracks: tracks ?? manifest.tracks
        )
    }

    func testCodecPrimingLegacyAssociatedValueShapeAndPCMRepresentation() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let legacyUnknown = try decoder.decode(
            MeetingCodecPriming.self,
            from: Data(#"{"unknown":{"_0":"decoderDidNotReport"}}"#.utf8)
        )
        XCTAssertEqual(legacyUnknown, .unknown(.decoderDidNotReport))
        let legacyMeasured = try decoder.decode(
            MeetingCodecPriming.self,
            from: Data(#"{"measuredFrames":{"_0":0}}"#.utf8)
        )
        XCTAssertEqual(legacyMeasured, .measuredFrames(0))
        let pcm = MeetingCodecPriming.notApplicable(.linearPCMFloat32CAFV1)
        let encoded = try encoder.encode(pcm)
        XCTAssertEqual(
            // JSONEncoder fixture bytes are UTF-8; retain nonoptional decoding for assertions.
            // swiftlint:disable:next optional_data_string_conversion
            String(decoding: encoded, as: UTF8.self),
            #"{"notApplicable":{"_0":"linearPCMFloat32CAFV1"}}"#
        )
        XCTAssertEqual(try decoder.decode(MeetingCodecPriming.self, from: encoded), pcm)
        XCTAssertEqual(
            try decoder.decode(MeetingCodecPriming.self, from: encoder.encode(legacyUnknown)),
            legacyUnknown
        )
    }

    func testInRoomChunkBuildsOneAdmissibleUncertainSpan() throws {
        let chunk = self.chunk(sequence: 0, start: 100, end: 110)
        let track = self.track(kind: .microphone, chunks: [chunk], captureMethod: .avCaptureSession)
        let plan = self.plan(mode: .inRoom, tracks: [track])
        let manifest = try MeetingAnalysisManifestBuilder(
            plan: plan,
            observer: self.observer([(track.id, chunk, self.observed(chunk, duration: 10))]),
            analysisSampleRate: 16_000
        ).build()

        XCTAssertEqual(manifest.presentationOriginSeconds, 100)
        let builtTrack = try XCTUnwrap(manifest.track(track.id))
        XCTAssertTrue(builtTrack.gaps.isEmpty)
        let span = try XCTUnwrap(builtTrack.spans.only)
        XCTAssertEqual(span.recordedInterval, MeetingAnalysisInterval(start: 0, end: 10))
        XCTAssertEqual(span.sourceLocalInterval, MeetingAnalysisInterval(start: 0, end: 10))
        XCTAssertEqual(span.analysisInterval, MeetingAnalysisInterval(start: 0, end: 10))
        XCTAssertEqual(span.admission.rationale, .inRoomMicrophone)
        XCTAssertEqual(span.timing.certainty, .timingUncertain)
        XCTAssertNil(span.presentationMapping.codecPrimingCompensationSeconds)
        XCTAssertEqual(span.presentationMapping.sampleRateConversionRatio, 100 / 16_000)
        XCTAssertEqual(builtTrack.epochs.map(\.resetReason), [.trackStart])
    }

    func testOnlineTracksStaySeparateAndMixedMicErasTileChunk() throws {
        let appChunk = self.chunk(sequence: 0, start: 100, end: 110)
        let micChunk = self.chunk(sequence: 0, start: 100, end: 110)
        let app = self.track(kind: .applicationAudio, chunks: [appChunk])
        let mic = self.track(
            kind: .microphone,
            chunks: [micChunk],
            eras: [
                self.era(protection: .voiceProcessed, start: 0),
                self.era(protection: .unprotected, start: 105),
                self.era(protection: .softwareEchoCancelled, start: 108),
            ]
        )
        let plan = self.plan(mode: .onlineCall, tracks: [app, mic])
        let manifest = try MeetingAnalysisManifestBuilder(
            plan: plan,
            observer: self.observer([
                (app.id, appChunk, self.observed(appChunk, duration: 10)),
                (mic.id, micChunk, self.observed(micChunk, duration: 10)),
            ])
        ).build()

        let appManifest = try XCTUnwrap(manifest.track(app.id))
        XCTAssertEqual(appManifest.spans.count, 1)
        XCTAssertTrue(appManifest.gaps.isEmpty)
        XCTAssertEqual(appManifest.spans[0].admission.rationale, .applicationAudio)

        let micManifest = try XCTUnwrap(manifest.track(mic.id))
        XCTAssertEqual(micManifest.spans.map(\.recordedInterval), [
            MeetingAnalysisInterval(start: 0, end: 5),
            MeetingAnalysisInterval(start: 8, end: 10),
        ])
        XCTAssertEqual(micManifest.gaps.compactMap(\.recordedInterval), [
            MeetingAnalysisInterval(start: 5, end: 8),
        ])
        XCTAssertEqual(micManifest.gaps.map(\.reason), [.inadmissibleCaptureEra])
        XCTAssertEqual(micManifest.spans.map(\.analysisInterval), [
            MeetingAnalysisInterval(start: 0, end: 5),
            MeetingAnalysisInterval(start: 5, end: 7),
        ])
        XCTAssertEqual(micManifest.epochs.map(\.resetReason), [.trackStart, .inadmissibleCaptureEra])
        XCTAssertNotEqual(appManifest.spans[0].analysisEpochID.trackID, micManifest.spans[0].analysisEpochID.trackID)
    }

    func testSafeDeviceChangeAndRecordedDiscontinuityResetEpochs() throws {
        let first = self.chunk(sequence: 0, start: 100, end: 105)
        let second = self.chunk(
            sequence: 1,
            start: 105,
            end: 110,
            discontinuities: [MeetingAudioDiscontinuity(
                kind: .microphoneChanged,
                presentationTime: self.mediaTime(105),
                gapSeconds: 0,
                detail: "fixture"
            )]
        )
        let track = self.track(
            kind: .microphone,
            chunks: [first, second],
            eras: [
                self.era(protection: .voiceProcessed, start: 0, deviceUID: "mic-a"),
                self.era(protection: .voiceProcessed, start: 105, deviceUID: "mic-b"),
            ]
        )
        let plan = self.plan(mode: .onlineCall, tracks: [track])
        let manifest = try MeetingAnalysisManifestBuilder(
            plan: plan,
            observer: self.observer([
                (track.id, first, self.observed(first, duration: 5, priming: .measuredFrames(0))),
                (track.id, second, self.observed(second, duration: 5, priming: .measuredFrames(0))),
            ])
        ).build()
        let epochs = try XCTUnwrap(manifest.track(track.id)).epochs
        XCTAssertEqual(epochs.count, 2)
        XCTAssertEqual(epochs[0].resetReason, .trackStart)
        XCTAssertEqual(epochs[1].resetReason, .microphoneDeviceChanged)
    }

    func testMidChunkDiscontinuitySplitsPieceAndResetsEpoch() throws {
        let chunk = self.chunk(
            sequence: 0,
            start: 100,
            end: 110,
            discontinuities: [MeetingAudioDiscontinuity(
                kind: .clockDiscontinuity,
                presentationTime: self.mediaTime(104),
                gapSeconds: nil,
                detail: "mid-chunk"
            )]
        )
        let track = self.track(kind: .microphone, chunks: [chunk], eras: [
            self.era(protection: .voiceProcessed, start: 0),
        ])
        let plan = self.plan(mode: .onlineCall, tracks: [track])
        let manifest = try MeetingAnalysisManifestBuilder(
            plan: plan,
            observer: self.observer([(track.id, chunk, self.observed(chunk, duration: 10))])
        ).build()
        let result = try XCTUnwrap(manifest.track(track.id))
        XCTAssertEqual(result.spans.map(\.recordedInterval), [
            MeetingAnalysisInterval(start: 0, end: 4),
            MeetingAnalysisInterval(start: 4, end: 10),
        ])
        XCTAssertEqual(result.epochs.map(\.resetReason), [.trackStart, .chunkDiscontinuity])
    }

    func testObservationFailuresBecomeTypedGapsAndResetFollowingAudio() throws {
        let first = self.chunk(sequence: 0, start: 0, end: 2)
        let missing = self.chunk(sequence: 1, start: 2, end: 4)
        let third = self.chunk(sequence: 2, start: 4, end: 6)
        let track = self.track(kind: .microphone, chunks: [first, missing, third], eras: [
            self.era(protection: .voiceProcessed, start: 0),
        ])
        let plan = self.plan(mode: .onlineCall, tracks: [track])
        let manifest = try MeetingAnalysisManifestBuilder(
            plan: plan,
            observer: self.observer([
                (track.id, first, self.observed(first, duration: 2)),
                (track.id, missing, .failed(.fileMissing, detail: "gone")),
                (track.id, third, self.observed(third, duration: 2)),
            ])
        ).build()
        let result = try XCTUnwrap(manifest.track(track.id))
        XCTAssertEqual(result.gaps.map(\.reason), [.chunkFileMissing])
        XCTAssertEqual(result.epochs.map(\.resetReason), [.trackStart, .missingOrUnreadableAudio])
    }

    func testShortDecodedAudioProducesBackedSpanAndExplicitTrailingGap() throws {
        let chunk = self.chunk(sequence: 0, start: 10, end: 20)
        let track = self.track(kind: .microphone, chunks: [chunk], eras: [
            self.era(protection: .voiceProcessed, start: 0),
        ])
        let plan = self.plan(mode: .onlineCall, tracks: [track])
        let manifest = try MeetingAnalysisManifestBuilder(
            plan: plan,
            observer: self.observer([(track.id, chunk, self.observed(chunk, duration: 6))])
        ).build()
        let result = try XCTUnwrap(manifest.track(track.id))
        XCTAssertEqual(result.spans.map(\.recordedInterval), [MeetingAnalysisInterval(start: 0, end: 6)])
        XCTAssertEqual(result.gaps.compactMap(\.recordedInterval), [MeetingAnalysisInterval(start: 6, end: 10)])
        XCTAssertEqual(result.gaps.map(\.reason), [.decodedAudioExhausted])
    }

    func testTwoSampleTimestampTailPreservesSpeakerEpochWithoutInventingAudio() throws {
        for sampleRate in [16_000.0, 44_100.0, 48_000.0, 96_000.0] {
            for missingSamples in [0.5, 1.0, 2.0, 2.5, 3.0] {
                let firstEnd = 60 + missingSamples / sampleRate
                var first = self.chunk(sequence: 0, start: 0, end: firstEnd)
                first.presentationEnd = MeetingMediaTime(
                    value: Int64((firstEnd * 1_000_000_000).rounded()), timescale: 1_000_000_000
                )
                var second = self.chunk(sequence: 1, start: firstEnd, end: firstEnd + 60)
                second.presentationStart = first.presentationEnd
                second.presentationEnd = MeetingMediaTime(
                    value: first.presentationEnd.value + 60_000_000_000, timescale: 1_000_000_000
                )
                let track = self.track(kind: .applicationAudio, chunks: [first, second])
                let plan = self.plan(mode: .onlineCall, tracks: [track])
                let manifest = try MeetingAnalysisManifestBuilder(
                    plan: plan,
                    observer: self.observer([
                        (track.id, first, self.observed(first, duration: 60, sampleRate: sampleRate)),
                        (track.id, second, self.observed(second, duration: 60, sampleRate: sampleRate)),
                    ])
                ).build()
                _ = try manifest.validated(against: plan)
                let result = try XCTUnwrap(manifest.track(track.id))
                let tolerated = missingSamples <= 2
                XCTAssertEqual(result.epochs.count, tolerated ? 1 : 2, "\(sampleRate) Hz, \(missingSamples) samples")
                XCTAssertEqual(result.gaps.count, tolerated ? 0 : 1)
                XCTAssertEqual(result.spans[0].sourceLocalInterval.end, 60, accuracy: 1e-9)
                XCTAssertEqual(result.spans[0].analysisInterval.duration, 60, accuracy: 1e-9)
                XCTAssertEqual(result.spans[0].presentationInterval.end, 60, accuracy: 1e-9)
                XCTAssertEqual(result.spans[1].recordedInterval.start, firstEnd, accuracy: 1e-9)
                if !tolerated {
                    XCTAssertEqual(result.epochs.last?.resetReason, .missingOrUnreadableAudio)
                    XCTAssertEqual(result.gaps.first?.reason, .decodedAudioExhausted)
                }
            }
        }
    }

    func testTailToleranceDoesNotHideRealCaptureDiscontinuity() throws {
        var first = self.chunk(sequence: 0, start: 0, end: 60)
        first.presentationEnd = MeetingMediaTime(value: 60_000_015_000, timescale: 1_000_000_000)
        var second = self.chunk(sequence: 1, start: 60, end: 120, discontinuities: [
            MeetingAudioDiscontinuity(kind: .clockDiscontinuity, presentationTime: nil, gapSeconds: nil, detail: "restart"),
        ])
        second.presentationStart = first.presentationEnd
        second.presentationEnd = MeetingMediaTime(value: 120_000_015_000, timescale: 1_000_000_000)
        let track = self.track(kind: .applicationAudio, chunks: [first, second])
        let plan = self.plan(mode: .onlineCall, tracks: [track])
        let manifest = try MeetingAnalysisManifestBuilder(
            plan: plan,
            observer: self.observer([
                (track.id, first, self.observed(first, duration: 60, sampleRate: 48_000)),
                (track.id, second, self.observed(second, duration: 60, sampleRate: 48_000)),
            ])
        ).build()
        let result = try XCTUnwrap(manifest.track(track.id))
        XCTAssertTrue(result.gaps.isEmpty)
        XCTAssertEqual(result.epochs.map(\.resetReason), [.trackStart, .chunkDiscontinuity])
    }

    func testValidatorRejectsOriginChunkIdentityAndCoverageMutations() throws {
        let chunk = self.chunk(sequence: 0, start: 100, end: 110)
        let track = self.track(kind: .microphone, chunks: [chunk])
        let plan = self.plan(mode: .inRoom, tracks: [track])
        let manifest = try MeetingAnalysisManifestBuilder(
            plan: plan,
            observer: self.observer([(track.id, chunk, self.observed(chunk, duration: 10))])
        ).build()

        XCTAssertThrowsError(try self.replacing(manifest, origin: 99).validated(against: plan)) { error in
            guard case .presentationOriginMismatch = error as? MeetingAnalysisManifestError else {
                return XCTFail("Expected presentationOriginMismatch, got \(error)")
            }
        }

        let builtTrack = try XCTUnwrap(manifest.track(track.id))
        let span = try XCTUnwrap(builtTrack.spans.only)
        let changedIdentity = MeetingAnalysisChunkIdentity(
            trackID: span.chunk.trackID,
            chunk: MeetingAudioChunk(
                id: span.chunk.chunkID,
                sequence: span.chunk.sequence,
                relativeFilePath: "different.m4a",
                presentationStart: chunk.presentationStart,
                presentationEnd: chunk.presentationEnd,
                discontinuities: chunk.discontinuities,
                sha256: span.chunk.storedSHA256,
                byteCount: span.chunk.storedByteCount,
                finalizationState: .finalized
            )
        )
        let changedSpan = MeetingAnalysisSpan(
            id: span.id,
            chunk: changedIdentity,
            pieceIndex: span.pieceIndex,
            trackKind: span.trackKind,
            analysisEpochID: span.analysisEpochID,
            recordedInterval: span.recordedInterval,
            sourceLocalInterval: span.sourceLocalInterval,
            analysisInterval: span.analysisInterval,
            presentationInterval: span.presentationInterval,
            presentationMapping: span.presentationMapping,
            captureEra: span.captureEra,
            admission: span.admission,
            observed: span.observed,
            discontinuity: span.discontinuity,
            timing: span.timing
        )
        let changedTrack = MeetingAnalysisTrackManifest(
            id: builtTrack.id,
            kind: builtTrack.kind,
            spans: [changedSpan],
            gaps: builtTrack.gaps,
            epochs: builtTrack.epochs
        )
        XCTAssertThrowsError(try self.replacing(manifest, tracks: [changedTrack]).validated(against: plan)) { error in
            guard case .chunkIdentityDisagreesWithPlan = error as? MeetingAnalysisManifestError else {
                return XCTFail("Expected chunkIdentityDisagreesWithPlan, got \(error)")
            }
        }

        let uncoveredTrack = MeetingAnalysisTrackManifest(
            id: builtTrack.id,
            kind: builtTrack.kind,
            spans: [],
            gaps: [],
            epochs: []
        )
        XCTAssertThrowsError(try self.replacing(manifest, tracks: [uncoveredTrack]).validated(against: plan)) { error in
            guard case .plannedChunkUncovered = error as? MeetingAnalysisManifestError else {
                return XCTFail("Expected plannedChunkUncovered, got \(error)")
            }
        }
    }

    func testProductionObserverRejectsEscapesMutationsAndUnreadableFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-observer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("chunk.bin")
        let bytes = Data("not audio".utf8)
        try bytes.write(to: file)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let observer = MeetingChunkAudioObserver(sessionDirectory: root)

        let validIdentity = self.chunk(
            sequence: 0,
            start: 0,
            end: 1,
            path: "chunk.bin",
            sha256: digest,
            byteCount: Int64(bytes.count)
        )
        XCTAssertEqualFailure(observer.observe(chunk: validIdentity, trackID: UUID()), .unreadable)

        var changedBytes = validIdentity
        changedBytes.byteCount += 1
        XCTAssertEqualFailure(observer.observe(chunk: changedBytes, trackID: UUID()), .byteCountChanged)

        var changedHash = validIdentity
        changedHash.sha256 = String(repeating: "0", count: 64)
        XCTAssertEqualFailure(observer.observe(chunk: changedHash, trackID: UUID()), .hashChanged)

        var escaping = validIdentity
        escaping.relativeFilePath = "../chunk.bin"
        XCTAssertEqualFailure(observer.observe(chunk: escaping, trackID: UUID()), .pathRejected)

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-outside-\(UUID().uuidString)")
        try bytes.write(to: outside)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        var linked = validIdentity
        linked.relativeFilePath = "link.bin"
        XCTAssertEqualFailure(observer.observe(chunk: linked, trackID: UUID()), .pathRejected)
    }

    func testProductionObserverReadsActualAudioAndLeavesPrimingUnknown() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("chunk.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
            buffer.frameLength = 1600
            try file.write(from: buffer)
        }
        let bytes = try Data(contentsOf: url)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let chunk = self.chunk(
            sequence: 0,
            start: 0,
            end: 0.1,
            path: "chunk.caf",
            sha256: digest,
            byteCount: Int64(bytes.count)
        )

        let result = MeetingChunkAudioObserver(sessionDirectory: root)
            .observe(chunk: chunk, trackID: UUID())
        guard case let .observed(observed) = result else {
            return XCTFail("Expected observed audio, got \(result)")
        }
        XCTAssertEqual(observed.decoded.sampleRate, 16_000)
        XCTAssertEqual(observed.decoded.frameCount, 1600)
        XCTAssertEqual(observed.decoded.durationSeconds, 0.1, accuracy: 1e-9)
        XCTAssertEqual(observed.decoded.codecPriming, .unknown(.decoderDidNotReport))
    }

    func testProductionObserverUsesReadyPCMAssetAndMarksPrimingNotApplicable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-pcm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let pcmURL = root.appendingPathComponent("analysis/chunk-0.caf")
        try FileManager.default.createDirectory(at: pcmURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ))
        let file = try AVAudioFile(
            forWriting: pcmURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: true
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buffer.frameLength = 1600
        try file.write(from: buffer)
        let bytes = try Data(contentsOf: pcmURL)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let attributes = try FileManager.default.attributesOfItem(atPath: pcmURL.path)
        let asset = MeetingAudioAsset(
            role: .captureAnalysis,
            encoding: .linearPCMFloat32CAFV1,
            presence: .ready,
            relativeFilePath: "analysis/chunk-0.caf",
            byteCount: Int64((attributes[.size] as? NSNumber)?.intValue ?? 0),
            sha256: digest,
            sampleRate: 16_000,
            channelCount: 1,
            frameCount: 1600
        )
        let chunk = MeetingAudioChunk(
            id: UUID(),
            sequence: 0,
            relativeFilePath: "archive/chunk-0.m4a",
            presentationStart: self.mediaTime(0),
            presentationEnd: self.mediaTime(0.1),
            discontinuities: [],
            sha256: String(repeating: "a", count: 64),
            byteCount: 1,
            finalizationState: .finalized,
            audioSchemaVersion: 2,
            captureAnalysisAsset: asset
        )
        let result = MeetingChunkAudioObserver(sessionDirectory: root)
            .observe(chunk: chunk, trackID: UUID())
        guard case let .observed(observed) = result else {
            return XCTFail("Expected verified PCM asset, got \(result)")
        }
        XCTAssertEqual(observed.byteCount, asset.byteCount)
        XCTAssertEqual(observed.sha256, digest)
        XCTAssertEqual(observed.decoded.frameCount, 1600)
        XCTAssertEqual(observed.decoded.codecPriming, .notApplicable(.linearPCMFloat32CAFV1))
        XCTAssertTrue(observed.decoded.codecPriming.isKnown)
        let identity = MeetingAnalysisChunkIdentity(trackID: UUID(), chunk: chunk)
        XCTAssertEqual(identity.relativeFilePath, asset.relativeFilePath)
        XCTAssertEqual(identity.storedByteCount, asset.byteCount)
        XCTAssertEqual(identity.storedSHA256, digest)
    }
}

private extension Collection {
    var only: Element? {
        self.count == 1 ? self.first : nil
    }
}

private func XCTAssertEqualFailure(
    _ result: MeetingChunkObservationResult,
    _ expected: MeetingChunkObservationFailure,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case let .failed(actual, _) = result else {
        return XCTFail("Expected failure \(expected), got \(result)", file: file, line: line)
    }
    XCTAssertEqual(actual, expected, file: file, line: line)
}
