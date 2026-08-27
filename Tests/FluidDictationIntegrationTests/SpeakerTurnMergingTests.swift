@testable import FluidVoice_Debug
import XCTest

#if arch(arm64)

// `mergeAdjacentTurns` joins consecutive turns from the same speaker across short pauses.
// When clustering collapses to one label, that intentionally produces one longer segment;
// the tests below pin down both the merge rules and that interaction.

final class SpeakerTurnMergingTests: XCTestCase {
    private typealias Turn = SpeakerDiarizationService.SpeakerTurn

    private func turn(_ speaker: String, _ start: Double, _ end: Double) -> Turn {
        Turn(speakerLabel: speaker, startSeconds: start, endSeconds: end)
    }

    func testEmptyInput() {
        XCTAssertTrue(SpeakerDiarizationService.mergeAdjacentTurns([]).isEmpty)
    }

    func testSingleTurnIsUnchanged() {
        let input = [self.turn("Speaker 1", 0, 5)]
        let merged = SpeakerDiarizationService.mergeAdjacentTurns(input)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].startSeconds, 0)
        XCTAssertEqual(merged[0].endSeconds, 5)
    }

    func testSameSpeakerAcrossShortGapIsMerged() {
        let merged = SpeakerDiarizationService.mergeAdjacentTurns([
            self.turn("Speaker 1", 0, 5),
            self.turn("Speaker 1", 5.5, 9),
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].endSeconds, 9)
    }

    func testSameSpeakerAcrossLongGapStaysSeparate() {
        let merged = SpeakerDiarizationService.mergeAdjacentTurns([
            self.turn("Speaker 1", 0, 5),
            self.turn("Speaker 1", 6.5, 9),
        ])
        XCTAssertEqual(merged.count, 2, "1.5s exceeds the 1.0s merge gap")
    }

    func testGapExactlyAtTheLimitIsMerged() {
        let merged = SpeakerDiarizationService.mergeAdjacentTurns([
            self.turn("Speaker 1", 0, 5),
            self.turn("Speaker 1", 6.0, 9),
        ])
        XCTAssertEqual(merged.count, 1, "a gap of exactly maxGapSeconds still merges")
    }

    func testDifferentSpeakersAreNeverMerged() {
        let merged = SpeakerDiarizationService.mergeAdjacentTurns([
            self.turn("Speaker 1", 0, 5),
            self.turn("Speaker 2", 5.1, 9),
        ])
        XCTAssertEqual(merged.count, 2)
    }

    /// The coupling itself: identical labels plus short pauses collapse a rapid exchange into
    /// one long block. With correct labels the same input stays separated.
    func testCollapsedLabelsWeldDialogueIntoOneSegment() {
        let rapidExchange: [(Double, Double)] = [
            (0, 3), (3.4, 6), (6.3, 9), (9.5, 12), (12.4, 15),
        ]

        let allOneSpeaker = rapidExchange.map { self.turn("Speaker 1", $0.0, $0.1) }
        let collapsed = SpeakerDiarizationService.mergeAdjacentTurns(allOneSpeaker)
        XCTAssertEqual(collapsed.count, 1, "one label + short pauses = one block")
        XCTAssertEqual(collapsed[0].durationSeconds, 15, accuracy: 0.001)

        let alternating = rapidExchange.enumerated().map {
            self.turn($0.offset % 2 == 0 ? "Speaker 1" : "Speaker 2", $0.element.0, $0.element.1)
        }
        let kept = SpeakerDiarizationService.mergeAdjacentTurns(alternating)
        XCTAssertEqual(kept.count, 5, "correct labels keep the exchange separated")
    }

    /// Regression: diarization segments can overlap at boundaries. A later
    /// same-speaker turn that ends inside the accumulated turn used to overwrite
    /// `endSeconds` with its own (earlier) end, dropping the trailing audio.
    func testOverlappingSameSpeakerTurnDoesNotShrinkMergedRange() {
        let merged = SpeakerDiarizationService.mergeAdjacentTurns([
            self.turn("Speaker 1", 0, 10),
            self.turn("Speaker 1", 5, 8),
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].startSeconds, 0)
        XCTAssertEqual(merged[0].endSeconds, 10, "a contained turn must not shrink the merged range")
    }

    /// A turn ending exactly at the accumulated end is the normal adjacent case
    /// and must still extend (or hold) the range to that boundary.
    func testTouchingSameSpeakerTurnExtendsToEnd() {
        let merged = SpeakerDiarizationService.mergeAdjacentTurns([
            self.turn("Speaker 1", 0, 10),
            self.turn("Speaker 1", 9.5, 12),
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].endSeconds, 12)
    }

    func testOverlongRunIsCappedNotMergedIndefinitely() {
        var turns: [Turn] = []
        var t = 0.0
        while t < 25 * 60 {
            turns.append(self.turn("Speaker 1", t, t + 30))
            t += 30.5
        }
        let merged = SpeakerDiarizationService.mergeAdjacentTurns(turns)
        XCTAssertGreaterThan(merged.count, 1, "a run longer than the 20-minute cap must be split")
        for segment in merged {
            XCTAssertLessThanOrEqual(segment.durationSeconds, 20 * 60 + 60)
        }
    }
}

final class SpeakerTranscriptSegmentTests: XCTestCase {
    func testPlainTextIncludesMinuteTimestamp() {
        let segment = SpeakerTranscriptSegment(
            speaker: "Speaker 1",
            startSeconds: 65.9,
            endSeconds: 70,
            text: "Hello"
        )

        XCTAssertEqual(segment.plainText, "[1:05] Speaker 1: Hello")
    }

    func testPlainTextIncludesHourTimestamp() {
        let segment = SpeakerTranscriptSegment(
            speaker: "Speaker 2",
            startSeconds: 3_661,
            endSeconds: 3_670,
            text: "Still here"
        )

        XCTAssertEqual(segment.plainText, "[1:01:01] Speaker 2: Still here")
    }
}

final class SpeakerLabeledTranscriptionPolicyTests: XCTestCase {
    private enum StubError: Error {
        case failed
    }

    func testEmptyLaterChunkKeepsEarlierTextAndRecordsOnlyTheMissingRange() async {
        let ranges = [
            SpeakerTranscriptGap(startSeconds: 0, endSeconds: 1_200),
            SpeakerTranscriptGap(startSeconds: 1_200, endSeconds: 1_205),
        ]

        let result = await SpeakerLabeledTranscriptionPolicy.transcribeChunks(ranges) { range in
            if range.startSeconds == 0 {
                return SpeakerChunkTranscription(text: "Recognized first chunk", confidence: 0.8)
            }
            return SpeakerChunkTranscription(text: "", confidence: 0.1)
        }

        XCTAssertEqual(result.text, "Recognized first chunk")
        XCTAssertEqual(result.confidence, 0.8, accuracy: 0.0001)
        XCTAssertEqual(result.gaps, [ranges[1]])
    }

    func testWhitespaceOnlyChunksAreGapsAndConfidenceUsesRecognizedChunksOnly() async {
        let ranges = [
            SpeakerTranscriptGap(startSeconds: 0, endSeconds: 0.4),
            SpeakerTranscriptGap(startSeconds: 0.4, endSeconds: 4),
            SpeakerTranscriptGap(startSeconds: 4, endSeconds: 4.6),
            SpeakerTranscriptGap(startSeconds: 4.6, endSeconds: 8),
        ]
        let responses = [
            SpeakerChunkTranscription(text: "  \n", confidence: 0.1),
            SpeakerChunkTranscription(text: "First", confidence: 0.6),
            SpeakerChunkTranscription(text: "\t", confidence: 0.2),
            SpeakerChunkTranscription(text: "Second", confidence: 1.0),
        ]
        var index = 0

        let result = await SpeakerLabeledTranscriptionPolicy.transcribeChunks(ranges) { _ in
            defer { index += 1 }
            return responses[index]
        }

        XCTAssertEqual(result.text, "First Second")
        XCTAssertEqual(result.confidence, 0.8, accuracy: 0.0001)
        XCTAssertEqual(result.gaps, [ranges[0], ranges[2]])
    }

    func testEmptyChunksAtBeginningAndEndKeepMiddleText() async {
        let ranges = [
            SpeakerTranscriptGap(startSeconds: 0, endSeconds: 0.2),
            SpeakerTranscriptGap(startSeconds: 0.2, endSeconds: 9.8),
            SpeakerTranscriptGap(startSeconds: 9.8, endSeconds: 10),
        ]
        let responses: [SpeakerChunkTranscription?] = [
            nil,
            SpeakerChunkTranscription(text: "Recognized middle", confidence: 0.75),
            SpeakerChunkTranscription(text: "", confidence: 0.2),
        ]
        var index = 0

        let result = await SpeakerLabeledTranscriptionPolicy.transcribeChunks(ranges) { _ in
            defer { index += 1 }
            return responses[index]
        }

        XCTAssertEqual(result.text, "Recognized middle")
        XCTAssertEqual(result.confidence, 0.75, accuracy: 0.0001)
        XCTAssertEqual(result.gaps, [ranges[0], ranges[2]])
    }

    func testAllEmptyChunksProduceOnlyGaps() async {
        let ranges = [
            SpeakerTranscriptGap(startSeconds: 0, endSeconds: 1),
            SpeakerTranscriptGap(startSeconds: 1, endSeconds: 2),
        ]

        let result = await SpeakerLabeledTranscriptionPolicy.transcribeChunks(ranges) { _ in
            nil
        }

        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.confidence, 0)
        XCTAssertEqual(result.gaps, ranges)
    }

    func testProviderErrorStillAbortsAfterEarlierSuccess() async {
        let ranges = [
            SpeakerTranscriptGap(startSeconds: 0, endSeconds: 1),
            SpeakerTranscriptGap(startSeconds: 1, endSeconds: 2),
        ]
        var index = 0

        do {
            _ = try await SpeakerLabeledTranscriptionPolicy.transcribeChunks(ranges) { _ in
                defer { index += 1 }
                if index == 0 {
                    return SpeakerChunkTranscription(text: "First", confidence: 0.9)
                }
                throw StubError.failed
            }
            XCTFail("A genuine provider error must fall back to the full-file transcript")
        } catch {
            XCTAssertTrue(error is StubError)
        }
    }

    func testMaterialityAcceptsExactLimits() {
        let gaps = (0..<10).map { index in
            SpeakerTranscriptGap(startSeconds: Double(index) * 3, endSeconds: Double(index + 1) * 3)
        }

        XCTAssertTrue(SpeakerLabeledTranscriptionPolicy.shouldKeepSpeakerLabels(
            hasRecognizedText: true,
            gaps: gaps,
            diarizedDurationSeconds: 3_000
        ))
    }

    func testMaterialityAcceptsSmallGapAboveThreeSecondsWhenTotalIsNegligible() {
        XCTAssertTrue(SpeakerLabeledTranscriptionPolicy.shouldKeepSpeakerLabels(
            hasRecognizedText: true,
            gaps: [SpeakerTranscriptGap(startSeconds: 10, endSeconds: 13.311)],
            diarizedDurationSeconds: 10_000
        ))
    }

    func testMaterialityRejectsOneGapLongerThanFiveSeconds() {
        XCTAssertFalse(SpeakerLabeledTranscriptionPolicy.shouldKeepSpeakerLabels(
            hasRecognizedText: true,
            gaps: [SpeakerTranscriptGap(startSeconds: 10, endSeconds: 15.001)],
            diarizedDurationSeconds: 10_000
        ))
    }

    func testMaterialityAcceptsOneGapAtFiveSecondLimit() {
        XCTAssertTrue(SpeakerLabeledTranscriptionPolicy.shouldKeepSpeakerLabels(
            hasRecognizedText: true,
            gaps: [SpeakerTranscriptGap(startSeconds: 10, endSeconds: 15)],
            diarizedDurationSeconds: 10_000
        ))
    }

    func testMaterialityRejectsMoreThanOnePercentOmitted() {
        let gaps = [
            SpeakerTranscriptGap(startSeconds: 0, endSeconds: 2.6),
            SpeakerTranscriptGap(startSeconds: 10, endSeconds: 12.6),
            SpeakerTranscriptGap(startSeconds: 20, endSeconds: 22.6),
            SpeakerTranscriptGap(startSeconds: 30, endSeconds: 32.6),
        ]

        XCTAssertFalse(SpeakerLabeledTranscriptionPolicy.shouldKeepSpeakerLabels(
            hasRecognizedText: true,
            gaps: gaps,
            diarizedDurationSeconds: 1_000
        ))
    }

    func testMaterialityCapsTotalAllowanceAtThirtySeconds() {
        let gaps = (0..<11).map { index in
            SpeakerTranscriptGap(startSeconds: Double(index) * 4, endSeconds: Double(index) * 4 + 3)
        }

        XCTAssertFalse(SpeakerLabeledTranscriptionPolicy.shouldKeepSpeakerLabels(
            hasRecognizedText: true,
            gaps: gaps,
            diarizedDurationSeconds: 20_000
        ))
    }

    func testMaterialityRejectsAllEmptyTranscriptEvenWithoutGaps() {
        XCTAssertFalse(SpeakerLabeledTranscriptionPolicy.shouldKeepSpeakerLabels(
            hasRecognizedText: false,
            gaps: [],
            diarizedDurationSeconds: 60
        ))
    }

    func testCoverageReportsTheEvidenceUsedByTheFallbackDecision() {
        let gaps = [
            SpeakerTranscriptGap(startSeconds: 10, endSeconds: 11.5),
            SpeakerTranscriptGap(startSeconds: 20, endSeconds: 24.25),
        ]

        let coverage = SpeakerLabeledTranscriptionPolicy.coverage(
            gaps: gaps,
            diarizedDurationSeconds: 200
        )

        XCTAssertEqual(coverage.gapCount, 2)
        XCTAssertEqual(coverage.skippedDurationSeconds, 5.75, accuracy: 0.0001)
        XCTAssertEqual(coverage.maxGapDurationSeconds, 4.25, accuracy: 0.0001)
        XCTAssertEqual(coverage.diarizedDurationSeconds, 200, accuracy: 0.0001)
        XCTAssertEqual(coverage.skippedRatio, 0.02875, accuracy: 0.000001)
    }

    func testFallbackDiagnosticNamesMissingRecognizedTextInsteadOfOmittedAudio() {
        let description = SpeakerLabeledTranscriptionPolicy.fallbackDiagnostic(
            hasRecognizedText: false,
            gaps: [],
            diarizedDurationSeconds: 100
        )

        XCTAssertEqual(description, "Speaker labeling produced no recognized text")
    }

    func testSpeakerLabelingNoticeNamesSkippedCountAndDuration() {
        let gaps = [
            SpeakerTranscriptGap(startSeconds: 10, endSeconds: 10.4),
            SpeakerTranscriptGap(startSeconds: 20, endSeconds: 21),
        ]

        XCTAssertEqual(
            SpeakerLabeledTranscriptionPolicy.limitationNotice(for: gaps),
            "Speaker labels were kept, but 2 short audio sections totaling 1.4 seconds produced no text."
        )
    }

    func testResultRoundTripsPersistentSpeakerLabelingDetails() throws {
        let gaps = [SpeakerTranscriptGap(startSeconds: 10, endSeconds: 10.4)]
        let result = TranscriptionResult(
            text: "[0:00] Speaker 1: Hello",
            confidence: 0.9,
            duration: 120,
            processingTime: 3,
            fileName: "meeting.m4a",
            speakerSegments: [
                SpeakerTranscriptSegment(
                    speaker: "Speaker 1",
                    startSeconds: 0,
                    endSeconds: 5,
                    text: "Hello"
                ),
            ],
            speakerLabelingNotice: "One short section was omitted.",
            speakerLabelingGaps: gaps
        )

        let decoded = try JSONDecoder().decode(
            TranscriptionResult.self,
            from: JSONEncoder().encode(result)
        )

        XCTAssertEqual(decoded.speakerLabelingNotice, "One short section was omitted.")
        XCTAssertEqual(decoded.speakerLabelingGaps, gaps)
        XCTAssertTrue(decoded.textExport.contains("Speaker labeling: One short section was omitted."))
        XCTAssertTrue(decoded.textExport.contains("Unlabeled audio ranges: 0:10.0-0:10.4"))
    }

    func testOlderResultWithoutSpeakerLabelingDetailsStillDecodes() throws {
        struct LegacyResult: Encodable {
            let text = "Hello"
            let confidence: Float = 0.9
            let duration: TimeInterval = 5
            let processingTime: TimeInterval = 1
            let fileName = "old.wav"
            let timestamp = Date(timeIntervalSince1970: 1_000)
        }

        let decoded = try JSONDecoder().decode(
            TranscriptionResult.self,
            from: JSONEncoder().encode(LegacyResult())
        )

        XCTAssertNil(decoded.speakerLabelingNotice)
        XCTAssertTrue(decoded.speakerLabelingGaps.isEmpty)
    }

    func testHistoryEntryKeepsSpeakerLabelingDetails() {
        let gaps = [SpeakerTranscriptGap(startSeconds: 1, endSeconds: 1.2)]
        let result = TranscriptionResult(
            text: "Hello",
            confidence: 0.9,
            duration: 5,
            processingTime: 1,
            fileName: "meeting.wav",
            speakerLabelingNotice: "A short section was omitted.",
            speakerLabelingGaps: gaps
        )

        let restored = FileTranscriptionEntry(from: result).toTranscriptionResult()

        XCTAssertEqual(restored.speakerLabelingNotice, result.speakerLabelingNotice)
        XCTAssertEqual(restored.speakerLabelingGaps, gaps)
    }

    func testOlderHistoryEntryWithoutSpeakerLabelingDetailsStillDecodes() throws {
        struct LegacyEntry: Encodable {
            let id = UUID()
            let timestamp = Date(timeIntervalSince1970: 1_000)
            let fileName = "old.wav"
            let duration: TimeInterval = 5
            let processingTime: TimeInterval = 1
            let confidence: Float = 0.9
            let text = "Hello"
        }

        let decoded = try JSONDecoder().decode(
            FileTranscriptionEntry.self,
            from: JSONEncoder().encode(LegacyEntry())
        )

        XCTAssertNil(decoded.speakerLabelingNotice)
        XCTAssertTrue(decoded.speakerLabelingGaps.isEmpty)
    }

    func testTinyEmptyTurnKeepsNeighboringSpeakerSegmentsInOrder() {
        let emptyGap = SpeakerTranscriptGap(startSeconds: 500, endSeconds: 501)
        let turns = [
            SpeakerRecognizedTurn(
                speaker: "Speaker 1",
                startSeconds: 0,
                endSeconds: 500,
                transcription: SpeakerTurnTranscription(text: "First", confidence: 0.8, gaps: [])
            ),
            SpeakerRecognizedTurn(
                speaker: "Speaker 2",
                startSeconds: 500,
                endSeconds: 501,
                transcription: SpeakerTurnTranscription(text: "", confidence: 0, gaps: [emptyGap])
            ),
            SpeakerRecognizedTurn(
                speaker: "Speaker 3",
                startSeconds: 501,
                endSeconds: 1_001,
                transcription: SpeakerTurnTranscription(text: "Last", confidence: 1, gaps: [])
            ),
        ]

        let result = SpeakerLabeledTranscriptionPolicy.assembleTurns(turns)

        XCTAssertEqual(result?.segments.map(\.speaker), ["Speaker 1", "Speaker 3"])
        XCTAssertEqual(result?.segments.map(\.text), ["First", "Last"])
        XCTAssertEqual(result?.confidence ?? 0, 0.9, accuracy: 0.0001)
        XCTAssertEqual(result?.gaps, [emptyGap])
        XCTAssertNotNil(result?.notice)
    }

    func testMaterialEmptyTurnRejectsLabeledTranscript() {
        let materialGap = SpeakerTranscriptGap(startSeconds: 500, endSeconds: 506)
        let turns = [
            SpeakerRecognizedTurn(
                speaker: "Speaker 1",
                startSeconds: 0,
                endSeconds: 500,
                transcription: SpeakerTurnTranscription(text: "First", confidence: 0.8, gaps: [])
            ),
            SpeakerRecognizedTurn(
                speaker: "Speaker 2",
                startSeconds: 500,
                endSeconds: 506,
                transcription: SpeakerTurnTranscription(text: "", confidence: 0, gaps: [materialGap])
            ),
            SpeakerRecognizedTurn(
                speaker: "Speaker 3",
                startSeconds: 506,
                endSeconds: 1_006,
                transcription: SpeakerTurnTranscription(text: "Last", confidence: 1, gaps: [])
            ),
        ]

        XCTAssertNil(SpeakerLabeledTranscriptionPolicy.assembleTurns(turns))
    }
}

#endif
