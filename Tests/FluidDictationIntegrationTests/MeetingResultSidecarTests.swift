import CryptoKit
@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Stage C1 of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md`: versioned Codable evidence, the
/// disposition/coverage ledger invariants, and the confined atomic sidecar store.
final class MeetingResultSidecarTests: XCTestCase {
    private let backendID = MeetingBackendID(rawValue: "fixture-sidecar-backend")
    private let backendVersion = "test-1"
    private let trackID = UUID()
    private let chunkID = UUID()

    private var epoch: MeetingAnalysisEpochID {
        MeetingAnalysisEpochID(trackID: self.trackID, ordinal: 0)
    }

    private func makeUnit(
        id: String = "u-0",
        text: String = "hello",
        speaker: MeetingBackendSpeakerAssignment? = nil,
        confidence: Double? = nil,
        analysisStart: TimeInterval = 1,
        analysisEnd: TimeInterval = 2,
        analysisSpanIDs: [String]? = nil
    ) -> MeetingFinalTextUnit {
        MeetingFinalTextUnit(
            id: id,
            trackID: self.trackID,
            analysisEpochID: self.epoch,
            precision: .word,
            text: text,
            analysisStart: analysisStart,
            analysisEnd: analysisEnd,
            speaker: speaker ?? .assigned(
                MeetingBackendSpeakerToken(analysisEpochID: self.epoch, label: "slot-0")
            ),
            analysisSpanIDs: analysisSpanIDs ?? ["span-0"],
            confidence: confidence
        )
    }

    private func makeReceipt(
        id: String = "receipt-0",
        spanID: String = "span-0",
        analysisStart: TimeInterval = 0,
        analysisEnd: TimeInterval = 5,
        status: MeetingSpanCoverageStatus = .processed
    ) -> MeetingSpanCoverageReceipt {
        MeetingSpanCoverageReceipt(
            id: id,
            spanID: spanID,
            analysisStart: analysisStart,
            analysisEnd: analysisEnd,
            status: status
        )
    }

    private func makeSidecar(
        attemptID: UUID = UUID(),
        units: [MeetingFinalTextUnit]? = nil,
        dispositions: [MeetingTextUnitDispositionRecord]? = nil,
        receipts: [MeetingSpanCoverageReceipt]? = nil
    ) -> MeetingResultSidecar {
        let resolvedUnits = units ?? [self.makeUnit()]
        let resolvedReceipts = receipts ?? [self.makeReceipt()]
        let spanIDs = Set(resolvedUnits.flatMap(\.analysisSpanIDs) + resolvedReceipts.map(\.spanID))
        return MeetingResultSidecar(
            backendID: self.backendID,
            backendVersion: self.backendVersion,
            attemptID: attemptID,
            analysisManifest: self.makeManifest(attemptID: attemptID, spanIDs: spanIDs),
            units: resolvedUnits,
            dispositions: dispositions ?? resolvedUnits.map {
                MeetingTextUnitDispositionRecord(unitID: $0.id, disposition: .emitted)
            },
            coverageReceipts: resolvedReceipts
        )
    }

    private func makeManifest(
        attemptID: UUID,
        spanIDs: Set<String>
    ) -> MeetingAnalysisManifest {
        let orderedIDs = spanIDs.sorted()
        let era = MeetingCaptureEraIdentity(
            index: 0,
            method: .avCaptureSession,
            deviceUID: "fixture-mic",
            deviceName: "Fixture Mic",
            normalizedStartSeconds: nil,
            echoProtection: .legacyUnclassified,
            aecProvenance: nil,
            clockDrift: nil
        )
        let spans = orderedIDs.enumerated().map { index, id in
            let start = Double(index) * 5
            let end = start + 5
            let chunk = MeetingAudioChunk(
                id: index == 0 ? self.chunkID : UUID(),
                sequence: index,
                relativeFilePath: "tracks/fixture-\(index).caf",
                presentationStart: MeetingMediaTime(value: Int64(start * 1_000), timescale: 1_000),
                presentationEnd: MeetingMediaTime(value: Int64(end * 1_000), timescale: 1_000),
                discontinuities: [],
                sha256: String(repeating: String((index % 9) + 1), count: 64),
                byteCount: 1_024,
                finalizationState: .finalized
            )
            let identity = MeetingAnalysisChunkIdentity(trackID: self.trackID, chunk: chunk)
            let decoded = MeetingChunkDecodedFacts(
                sampleRate: 100,
                channelCount: 1,
                frameCount: 500,
                durationSeconds: 5,
                codecPriming: .measuredFrames(0),
                processingFormatDescription: "fixture"
            )
            return MeetingAnalysisSpan(
                id: id,
                chunk: identity,
                pieceIndex: 0,
                trackKind: .microphone,
                analysisEpochID: self.epoch,
                recordedInterval: MeetingAnalysisInterval(start: start, end: end),
                sourceLocalInterval: MeetingAnalysisInterval(start: 0, end: 5),
                analysisInterval: MeetingAnalysisInterval(start: start, end: end),
                presentationInterval: MeetingAnalysisInterval(start: start, end: end),
                presentationMapping: MeetingAnalysisTimeTransform(
                    hostClockAnchor: 0,
                    rateRatio: 1,
                    offsetSeconds: 0,
                    sampleRateConversionRatio: nil,
                    codecPrimingCompensationSeconds: 0,
                    analysisRemovesGaps: true
                ),
                captureEra: era,
                admission: MeetingSpanAdmission(
                    captureMode: .inRoom,
                    trackKind: .microphone,
                    echoProtection: .legacyUnclassified
                ),
                observed: MeetingChunkObservedAudio(
                    byteCount: identity.storedByteCount,
                    sha256: identity.storedSHA256,
                    decoded: decoded
                ),
                discontinuity: .contiguous,
                timing: MeetingSpanTimingMetadata(
                    certainty: .certain,
                    fitResidualSeconds: 0,
                    residualBoundSeconds: MeetingAnalysisManifestSchema.defaultResidualBoundSeconds,
                    deDrift: .notApplicable
                )
            )
        }
        let epochRecords: [MeetingAnalysisEpochRecord] = spans.isEmpty ? [] : [
            MeetingAnalysisEpochRecord(
                id: self.epoch,
                resetReason: .trackStart,
                spanIDs: spans.map(\.id),
                analysisInterval: MeetingAnalysisInterval(
                    start: 0,
                    end: Double(spans.count) * 5
                )
            ),
        ]
        return MeetingAnalysisManifest(
            backendID: self.backendID,
            backendVersion: self.backendVersion,
            attemptID: attemptID,
            sessionID: UUID(),
            captureMode: .inRoom,
            presentationOriginSeconds: 0,
            analysisSampleRate: nil,
            tracks: [MeetingAnalysisTrackManifest(
                id: self.trackID,
                kind: .microphone,
                spans: spans,
                gaps: [],
                epochs: epochRecords
            )]
        )
    }

    private func makeTempSessionDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    // MARK: - Evidence Codable

    func testEvidenceCodableRoundTripPreservesAllAssignmentShapes() throws {
        let attemptID = UUID()
        let evidence = MeetingFinalTranscriptEvidence(
            backendID: self.backendID,
            attemptID: attemptID,
            units: [
                self.makeUnit(id: "w-0"),
                self.makeUnit(id: "w-1", speaker: .ambiguous([
                    MeetingBackendSpeakerToken(analysisEpochID: self.epoch, label: "slot-0"),
                    MeetingBackendSpeakerToken(analysisEpochID: self.epoch, label: "slot-1"),
                ])),
                self.makeUnit(id: "w-2", speaker: .unassigned, confidence: 0.5),
            ],
            speakerActivity: [
                MeetingBackendSpeakerActivity(
                    token: MeetingBackendSpeakerToken(analysisEpochID: self.epoch, label: "slot-0"),
                    start: 1,
                    end: 2
                ),
            ]
        )
        let data = try self.encode(evidence)
        let decoded = try JSONDecoder().decode(MeetingFinalTranscriptEvidence.self, from: data)
        XCTAssertEqual(decoded, evidence)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            object["schemaVersion"] as? Int, MeetingBackendEvidenceSchema.currentVersion
        )
    }

    func testEvidenceDecodeRejectsUnknownSchemaVersion() throws {
        let evidence = MeetingFinalTranscriptEvidence(
            backendID: self.backendID, attemptID: UUID(), units: [self.makeUnit()]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: self.encode(evidence)) as? [String: Any]
        )
        object["schemaVersion"] = 99
        let mutated = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try JSONDecoder().decode(MeetingFinalTranscriptEvidence.self, from: mutated)
        )
    }

    func testSpeakerAssignmentDecodeIsFailClosedForUnknownKinds() throws {
        let token = MeetingBackendSpeakerToken(analysisEpochID: self.epoch, label: "slot-0")
        let assignedJSON = """
        {"kind":"assigned","token":{"analysisEpochID":{"trackID":"\(
            self.trackID.uuidString
        )","ordinal":0,"generation":0},"label":"slot-0"}}
        """
        XCTAssertEqual(
            try JSONDecoder().decode(
                MeetingBackendSpeakerAssignment.self, from: Data(assignedJSON.utf8)
            ),
            .assigned(token)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                MeetingBackendSpeakerAssignment.self, from: Data(#"{"kind":"unassigned"}"#.utf8)
            ),
            .unassigned
        )

        // An unknown kind or a kind missing its payload must throw, never map to a default.
        for badJSON in [
            #"{"kind":"guessed"}"#,
            #"{"kind":"assigned"}"#,
            #"{"kind":"unassigned","token":{"analysisEpochID":{"trackID":"00000000-0000-0000-0000-000000000000","ordinal":0,"generation":0},"label":"slot-0"}}"#,
            #"{"kind":"ambiguous","token":{"analysisEpochID":{"trackID":"00000000-0000-0000-0000-000000000000","ordinal":0,"generation":0},"label":"slot-0"},"candidates":[]}"#,
        ] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    MeetingBackendSpeakerAssignment.self, from: Data(badJSON.utf8)
                ),
                badJSON
            )
        }

        // Fewer than two candidates may decode structurally, but evidence validation must
        // still reject them — ambiguity is never silently resolved.
        let thinAmbiguity = try JSONDecoder().decode(
            MeetingBackendSpeakerAssignment.self,
            from: Data(#"{"kind":"ambiguous","candidates":[]}"#.utf8)
        )
        guard case let .ambiguous(candidates) = thinAmbiguity else {
            return XCTFail("expected .ambiguous, got \(thinAmbiguity)")
        }
        XCTAssertTrue(candidates.isEmpty)
    }

    func testTextUnitPrecisionDecodeIsFailClosed() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(
            MeetingTextUnitPrecision.self, from: Data(#""syllable""#.utf8)
        ))
    }

    // MARK: - Sidecar ledger invariants

    func testValidSidecarPassesValidation() throws {
        let ambiguousUnit = self.makeUnit(id: "w-amb", speaker: .ambiguous([
            MeetingBackendSpeakerToken(analysisEpochID: self.epoch, label: "slot-0"),
            MeetingBackendSpeakerToken(analysisEpochID: self.epoch, label: "slot-1"),
        ]))
        let sidecar = self.makeSidecar(
            units: [self.makeUnit(id: "w-0"), ambiguousUnit],
            dispositions: [
                MeetingTextUnitDispositionRecord(unitID: "w-0", disposition: .emitted),
                MeetingTextUnitDispositionRecord(
                    unitID: "w-amb", disposition: .ambiguousUnassigned,
                    reasonCode: MeetingUnitDispositionReason.ambiguousSpeaker.rawValue
                ),
            ],
            receipts: [
                self.makeReceipt(id: "receipt-0"),
                self.makeReceipt(
                    id: "receipt-1", spanID: "span-1", analysisStart: 5, analysisEnd: 9,
                    status: .failed
                ),
            ]
        )
        XCTAssertEqual(try sidecar.validated(), sidecar)
    }

    func testSidecarRequiresExactlyOneDispositionPerUnit() throws {
        let twoUnits = [self.makeUnit(id: "w-0"), self.makeUnit(id: "w-1")]

        let missing = self.makeSidecar(
            units: twoUnits,
            dispositions: [MeetingTextUnitDispositionRecord(unitID: "w-0", disposition: .emitted)]
        )
        XCTAssertThrowsError(try missing.validated()) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarError, .missingDisposition(unitID: "w-1")
            )
        }

        let duplicate = self.makeSidecar(
            units: twoUnits,
            dispositions: [
                MeetingTextUnitDispositionRecord(unitID: "w-0", disposition: .emitted),
                MeetingTextUnitDispositionRecord(unitID: "w-0", disposition: .echoSuppressed),
                MeetingTextUnitDispositionRecord(unitID: "w-1", disposition: .emitted),
            ]
        )
        XCTAssertThrowsError(try duplicate.validated()) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarError, .duplicateDisposition(unitID: "w-0")
            )
        }

        let unknown = self.makeSidecar(
            units: twoUnits,
            dispositions: [
                MeetingTextUnitDispositionRecord(unitID: "w-0", disposition: .emitted),
                MeetingTextUnitDispositionRecord(unitID: "w-1", disposition: .emitted),
                MeetingTextUnitDispositionRecord(unitID: "ghost", disposition: .emitted),
            ]
        )
        XCTAssertThrowsError(try unknown.validated()) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarError, .dispositionForUnknownUnit(unitID: "ghost")
            )
        }
    }

    func testSidecarRejectsAmbiguityInconsistencies() throws {
        let ambiguousUnit = self.makeUnit(id: "w-amb", speaker: .ambiguous([
            MeetingBackendSpeakerToken(analysisEpochID: self.epoch, label: "slot-0"),
            MeetingBackendSpeakerToken(analysisEpochID: self.epoch, label: "slot-1"),
        ]))

        let emittedAmbiguous = self.makeSidecar(
            units: [ambiguousUnit],
            dispositions: [
                MeetingTextUnitDispositionRecord(unitID: "w-amb", disposition: .emitted),
            ]
        )
        XCTAssertThrowsError(try emittedAmbiguous.validated()) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarError,
                .emittedDispositionWithAmbiguity(unitID: "w-amb")
            )
        }

        let assignedUnit = self.makeUnit(id: "w-0")
        let ambiguousWithoutCandidates = self.makeSidecar(
            units: [assignedUnit],
            dispositions: [
                MeetingTextUnitDispositionRecord(unitID: "w-0", disposition: .ambiguousUnassigned),
            ]
        )
        XCTAssertThrowsError(try ambiguousWithoutCandidates.validated()) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarError,
                .ambiguousDispositionWithoutCandidates(unitID: "w-0")
            )
        }

        // A resolved-looking unit may still be admitted as unassigned when an earlier stage left
        // it ambiguous (for example uncertain timing) — but only with that reason named.
        let reasonedAmbiguous = self.makeSidecar(
            units: [assignedUnit],
            dispositions: [
                MeetingTextUnitDispositionRecord(
                    unitID: "w-0",
                    disposition: .ambiguousUnassigned,
                    reasonCode: MeetingUnitDispositionReason.timingUncertain.rawValue
                ),
            ]
        )
        XCTAssertNoThrow(try reasonedAmbiguous.validated())

        // Exclusion precedence: an ambiguous unit may still be excluded by an earlier stage.
        let excludedAmbiguous = self.makeSidecar(
            units: [ambiguousUnit],
            dispositions: [
                MeetingTextUnitDispositionRecord(
                    unitID: "w-amb", disposition: .inadmissible,
                    reasonCode: MeetingUnitDispositionReason.inadmissibleCaptureEra.rawValue
                ),
            ]
        )
        XCTAssertNoThrow(try excludedAmbiguous.validated())

        let duplicateToken = MeetingBackendSpeakerToken(
            analysisEpochID: self.epoch,
            label: "slot-0"
        )
        let duplicateCandidates = self.makeSidecar(
            units: [self.makeUnit(id: "w-duplicate", speaker: .ambiguous([
                duplicateToken,
                duplicateToken,
            ]))],
            dispositions: [
                MeetingTextUnitDispositionRecord(
                    unitID: "w-duplicate", disposition: .ambiguousUnassigned
                ),
            ]
        )
        XCTAssertThrowsError(try duplicateCandidates.validated()) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarError,
                .invalidAmbiguity(unitID: "w-duplicate")
            )
        }
    }

    func testSidecarCouplesInvalidTimingToItsQuarantineDisposition() throws {
        let invalidUnit = self.makeUnit(id: "bad-time", analysisStart: 2, analysisEnd: 2)
        let notQuarantined = self.makeSidecar(
            units: [invalidUnit],
            dispositions: [
                MeetingTextUnitDispositionRecord(unitID: invalidUnit.id, disposition: .emitted),
            ]
        )
        XCTAssertThrowsError(try notQuarantined.validated()) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarError,
                .invalidTimingNotRejected(unitID: invalidUnit.id)
            )
        }

        let quarantined = self.makeSidecar(
            units: [invalidUnit],
            dispositions: [
                MeetingTextUnitDispositionRecord(
                    unitID: invalidUnit.id,
                    disposition: .rejectedInvalidTiming,
                    reasonCode: MeetingUnitQuarantineReason.invalidTiming.rawValue
                ),
            ]
        )
        XCTAssertNoThrow(try quarantined.validated())

        // Sound-looking bounds may still be quarantined — but only with the provenance reason
        // named; a bare rejection of a valid-looking unit is never accepted.
        let validButRejected = self.makeSidecar(
            units: [self.makeUnit(id: "valid-time")],
            dispositions: [
                MeetingTextUnitDispositionRecord(
                    unitID: "valid-time", disposition: .rejectedInvalidTiming
                ),
            ]
        )
        XCTAssertThrowsError(try validButRejected.validated()) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarError,
                .rejectedInvalidTimingForValidUnit(unitID: "valid-time")
            )
        }

        let provenanceQuarantined = self.makeSidecar(
            units: [self.makeUnit(id: "cross-span")],
            dispositions: [
                MeetingTextUnitDispositionRecord(
                    unitID: "cross-span",
                    disposition: .rejectedInvalidTiming,
                    reasonCode: MeetingUnitQuarantineReason.spansNotContiguousWithinEpoch.rawValue
                ),
            ]
        )
        XCTAssertNoThrow(try provenanceQuarantined.validated())
    }

    func testSidecarRejectsMalformedUnitProvenanceAndConfidence() throws {
        let noSpans = self.makeSidecar(
            units: [self.makeUnit(id: "no-spans", analysisSpanIDs: [])],
            dispositions: [
                MeetingTextUnitDispositionRecord(unitID: "no-spans", disposition: .emitted),
            ]
        )
        XCTAssertThrowsError(try noSpans.validated()) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarError,
                .missingUnitAnalysisSpans(unitID: "no-spans")
            )
        }

        // Confidence is a value check, so it binds only to units the ledger claims were usable;
        // a quarantined unit may carry the out-of-range value that quarantined it.
        let invalidConfidence = self.makeSidecar(
            units: [self.makeUnit(id: "bad-confidence", confidence: 1.1)],
            dispositions: [
                MeetingTextUnitDispositionRecord(unitID: "bad-confidence", disposition: .emitted),
            ]
        )
        XCTAssertThrowsError(try invalidConfidence.validated()) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarError,
                .invalidConfidence(unitID: "bad-confidence")
            )
        }

        let quarantinedConfidence = self.makeSidecar(
            units: [self.makeUnit(id: "quarantined-confidence", confidence: 1.1)],
            dispositions: [
                MeetingTextUnitDispositionRecord(
                    unitID: "quarantined-confidence",
                    disposition: .rejectedInvalidTiming,
                    reasonCode: MeetingUnitQuarantineReason.invalidConfidence.rawValue
                ),
            ]
        )
        XCTAssertNoThrow(try quarantinedConfidence.validated())

        let duplicateSpans = self.makeSidecar(
            units: [self.makeUnit(
                id: "duplicate-spans",
                analysisSpanIDs: ["span-0", "span-0"]
            )],
            dispositions: [
                MeetingTextUnitDispositionRecord(
                    unitID: "duplicate-spans", disposition: .emitted
                ),
            ]
        )
        XCTAssertThrowsError(try duplicateSpans.validated()) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarError,
                .duplicateUnitAnalysisSpanID(unitID: "duplicate-spans")
            )
        }

        let invalidEpoch = MeetingFinalTextUnit(
            id: "negative-epoch",
            trackID: self.trackID,
            analysisEpochID: MeetingAnalysisEpochID(trackID: self.trackID, ordinal: -1),
            precision: .word,
            text: "hello",
            analysisStart: 1,
            analysisEnd: 2,
            speaker: .unassigned,
            analysisSpanIDs: ["span-0"]
        )
        XCTAssertThrowsError(try self.makeSidecar(
            units: [invalidEpoch],
            dispositions: [
                MeetingTextUnitDispositionRecord(unitID: invalidEpoch.id, disposition: .emitted),
            ]
        ).validated()) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarError,
                .invalidAnalysisEpochOrdinal(unitID: invalidEpoch.id)
            )
        }
    }

    func testSidecarRejectsMalformedCoverageReceipts() throws {
        let invalid = self.makeSidecar(receipts: [
            self.makeReceipt(id: "receipt-bad", analysisStart: 4, analysisEnd: 4),
        ])
        XCTAssertThrowsError(try invalid.validated()) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarError,
                .invalidCoverageInterval(receiptID: "receipt-bad")
            )
        }

        let noSpan = self.makeSidecar(receipts: [
            self.makeReceipt(id: "receipt-orphan", spanID: "  "),
        ])
        XCTAssertThrowsError(try noSpan.validated()) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarError,
                .emptyCoverageReceiptSpanID(receiptID: "receipt-orphan")
            )
        }

        let duplicateIDs = self.makeSidecar(receipts: [
            self.makeReceipt(id: "receipt-0", analysisStart: 0, analysisEnd: 5),
            self.makeReceipt(id: "receipt-0", analysisStart: 5, analysisEnd: 9, status: .failed),
        ])
        XCTAssertThrowsError(try duplicateIDs.validated()) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarError, .duplicateCoverageReceiptID("receipt-0")
            )
        }
    }

    func testSidecarRejectsDuplicateUnitIDs() throws {
        let duplicated = self.makeSidecar(
            units: [self.makeUnit(id: "w-0"), self.makeUnit(id: "w-0")],
            dispositions: [
                MeetingTextUnitDispositionRecord(unitID: "w-0", disposition: .emitted),
            ]
        )
        XCTAssertThrowsError(try duplicated.validated()) { error in
            XCTAssertEqual(error as? MeetingResultSidecarError, .duplicateUnitID("w-0"))
        }
    }

    func testSidecarDecodeRejectsUnknownSchemaVersionAndDispositions() throws {
        let sidecar = self.makeSidecar()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: self.encode(sidecar)) as? [String: Any]
        )
        object["schemaVersion"] = 0
        let mutated = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(MeetingResultSidecar.self, from: mutated))

        var wrongDisposition = try XCTUnwrap(
            JSONSerialization.jsonObject(with: self.encode(sidecar)) as? [String: Any]
        )
        wrongDisposition["dispositions"] = [["unitID": "w-0", "disposition": "published"]]
        let badDisposition = try JSONSerialization.data(withJSONObject: wrongDisposition)
        XCTAssertThrowsError(try JSONDecoder().decode(MeetingResultSidecar.self, from: badDisposition))
    }

    // MARK: - Store

    func testStoreWriteReadRoundTripVerifiesChecksumAndLineage() throws {
        let directory = try self.makeTempSessionDirectory()
        let store = MeetingResultSidecarStore(sessionDirectory: directory)
        let attemptID = UUID()
        let sidecar = self.makeSidecar(attemptID: attemptID)

        let reference = try store.write(sidecar)
        XCTAssertEqual(
            reference.formatVersion,
            MeetingResultSidecarReferenceSchema.currentVersion
        )
        XCTAssertEqual(reference.fileName, MeetingResultSidecarStore.fileName(for: attemptID))

        let url = try store.sidecarURL(for: attemptID)
        XCTAssertEqual(
            url.deletingLastPathComponent().standardizedFileURL,
            directory.standardizedFileURL
        )
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk.count, reference.byteCount)
        let expectedHash = SHA256.hash(data: onDisk).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(reference.sha256, expectedHash)

        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
            as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o600)
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
            as? NSNumber
        XCTAssertEqual(directoryPermissions?.int16Value, 0o700)

        let read = try store.read(
            expectedAttemptID: attemptID,
            expectedBackendID: self.backendID,
            reference: reference
        )
        XCTAssertEqual(read, sidecar)
    }

    func testStoreReadDetectsTampering() throws {
        let directory = try self.makeTempSessionDirectory()
        let store = MeetingResultSidecarStore(sessionDirectory: directory)
        let attemptID = UUID()
        let reference = try store.write(self.makeSidecar(attemptID: attemptID))

        let url = try store.sidecarURL(for: attemptID)
        var tampered = try Data(contentsOf: url)
        tampered[tampered.count - 3] = tampered[tampered.count - 3] ^ 0xff
        try tampered.write(to: url)

        XCTAssertThrowsError(try store.read(
            expectedAttemptID: attemptID,
            expectedBackendID: self.backendID,
            reference: reference
        )) { error in
            guard case MeetingResultSidecarStoreError.checksumMismatch = error else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
        }
    }

    func testStoreReadRejectsWrongAttemptBackendSchemaAndFileName() throws {
        let directory = try self.makeTempSessionDirectory()
        let store = MeetingResultSidecarStore(sessionDirectory: directory)
        let attemptID = UUID()
        let reference = try store.write(self.makeSidecar(attemptID: attemptID))

        XCTAssertThrowsError(try store.read(
            expectedAttemptID: UUID(),
            expectedBackendID: self.backendID,
            reference: reference
        )) { error in
            guard case MeetingResultSidecarStoreError.unexpectedFileName = error else {
                return XCTFail("expected unexpectedFileName, got \(error)")
            }
        }

        XCTAssertThrowsError(try store.read(
            expectedAttemptID: attemptID,
            expectedBackendID: .legacyCompatibility,
            reference: reference
        )) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarStoreError,
                .backendMismatch(expected: .legacyCompatibility, actual: self.backendID)
            )
        }

        let futureReference = MeetingResultSidecarReference(
            formatVersion: 99,
            fileName: reference.fileName,
            sha256: reference.sha256,
            byteCount: reference.byteCount
        )
        XCTAssertThrowsError(try store.read(
            expectedAttemptID: attemptID,
            expectedBackendID: self.backendID,
            reference: futureReference
        )) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarStoreError,
                .unsupportedReferenceFormatVersion(found: 99)
            )
        }

        let renamedReference = MeetingResultSidecarReference(
            formatVersion: reference.formatVersion,
            fileName: "../checkpoint.json",
            sha256: reference.sha256,
            byteCount: reference.byteCount
        )
        XCTAssertThrowsError(try store.read(
            expectedAttemptID: attemptID,
            expectedBackendID: self.backendID,
            reference: renamedReference
        )) { error in
            guard case MeetingResultSidecarStoreError.unexpectedFileName = error else {
                return XCTFail("a reference must never be able to name another file: \(error)")
            }
        }
    }

    func testStoreRejectsInvalidSidecarInsteadOfWriting() throws {
        let directory = try self.makeTempSessionDirectory()
        let store = MeetingResultSidecarStore(sessionDirectory: directory)
        let attemptID = UUID()
        let invalid = self.makeSidecar(
            attemptID: attemptID,
            units: [self.makeUnit(id: "w-0")],
            dispositions: []
        )
        XCTAssertThrowsError(try store.write(invalid)) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarError, .missingDisposition(unitID: "w-0")
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    MeetingResultSidecarStore.fileName(for: attemptID)
                ).path
            )
        )
    }

    func testStorePersistsQuarantinedNonFiniteEvidenceWithoutMakingItValid() throws {
        let directory = try self.makeTempSessionDirectory()
        let store = MeetingResultSidecarStore(sessionDirectory: directory)
        let attemptID = UUID()
        let unit = self.makeUnit(id: "nan-time", analysisStart: .nan, analysisEnd: 2)
        let sidecar = self.makeSidecar(
            attemptID: attemptID,
            units: [unit],
            dispositions: [
                MeetingTextUnitDispositionRecord(
                    unitID: unit.id,
                    disposition: .rejectedInvalidTiming,
                    reasonCode: MeetingUnitQuarantineReason.invalidTiming.rawValue
                ),
            ]
        )

        let reference = try store.write(sidecar)
        let decoded = try store.read(
            expectedAttemptID: attemptID,
            expectedBackendID: self.backendID,
            reference: reference
        )
        XCTAssertTrue(decoded.units[0].analysisStart.isNaN)
        XCTAssertEqual(decoded.dispositions[0].disposition, .rejectedInvalidTiming)
    }

    func testStoreMakesAttemptSidecarImmutableAndAllowsIdempotentJoin() throws {
        let directory = try self.makeTempSessionDirectory()
        let store = MeetingResultSidecarStore(sessionDirectory: directory)
        let attemptID = UUID()
        let original = self.makeSidecar(attemptID: attemptID)
        let originalReference = try store.write(original)

        XCTAssertEqual(try store.write(original), originalReference)

        let changed = self.makeSidecar(
            attemptID: attemptID,
            units: [self.makeUnit(text: "changed")]
        )
        XCTAssertThrowsError(try store.write(changed)) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarStoreError,
                .conflictingExistingSidecar(attemptID: attemptID)
            )
        }
        XCTAssertEqual(
            try store.read(
                expectedAttemptID: attemptID,
                expectedBackendID: self.backendID,
                reference: originalReference
            ),
            original
        )
    }

    func testStoreRejectsPreexistingSidecarSymlinkEscapingSessionDirectory() throws {
        let directory = try self.makeTempSessionDirectory()
        let store = MeetingResultSidecarStore(sessionDirectory: directory)
        let attemptID = UUID()
        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-outside-\(UUID().uuidString).json")
        let sentinel = Data("do-not-overwrite".utf8)
        try sentinel.write(to: outsideURL)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: outsideURL) }
        let linkURL = directory.appendingPathComponent(
            MeetingResultSidecarStore.fileName(for: attemptID)
        )
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: outsideURL
        )

        XCTAssertThrowsError(try store.write(self.makeSidecar(attemptID: attemptID))) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarStoreError,
                .pathEscapesSessionDirectory
            )
        }
        XCTAssertEqual(try Data(contentsOf: outsideURL), sentinel)
    }

    func testSidecarRejectsArbitraryDispositionReasonCodes() throws {
        let unit = self.makeUnit(id: "u-reason")
        let rejected = self.makeSidecar(
            units: [unit],
            dispositions: [
                MeetingTextUnitDispositionRecord(
                    unitID: unit.id,
                    disposition: .rejectedInvalidTiming,
                    reasonCode: "trust-me"
                ),
            ]
        )
        XCTAssertThrowsError(try rejected.validated()) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarError,
                .rejectedInvalidTimingForValidUnit(unitID: unit.id)
            )
        }

        let emitted = self.makeSidecar(
            units: [unit],
            dispositions: [
                MeetingTextUnitDispositionRecord(
                    unitID: unit.id,
                    disposition: .emitted,
                    reasonCode: "unexpected"
                ),
            ]
        )
        XCTAssertThrowsError(try emitted.validated()) { error in
            XCTAssertEqual(
                error as? MeetingResultSidecarError,
                .invalidDispositionReason(unitID: unit.id)
            )
        }
    }
}
