@testable import FluidVoice_Debug
import Foundation
import XCTest

#if arch(arm64)
import FluidAudio

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
            self.turn("Speaker 1", 8.5, 11),
        ])
        XCTAssertEqual(merged.count, 2, "3.5s exceeds the 1.0s default merge gap")
    }

    func testDefaultGapIsPinnedAtOneSecond() {
        let merged = SpeakerDiarizationService.mergeAdjacentTurns([
            self.turn("Speaker 1", 0, 5),
            self.turn("Speaker 1", 6.0, 9),
        ])
        XCTAssertEqual(merged.count, 1, "a gap of exactly the 1.0s default still merges")

        let separated = SpeakerDiarizationService.mergeAdjacentTurns([
            self.turn("Speaker 1", 0, 5),
            self.turn("Speaker 1", 6.1, 9),
        ])
        XCTAssertEqual(separated.count, 2, "1.1s exceeds the 1.0s default merge gap; file transcription keeps this default")
    }

    func testGapExactlyAtTheLimitIsMerged() {
        let merged = SpeakerDiarizationService.mergeAdjacentTurns([
            self.turn("Speaker 1", 0, 5),
            self.turn("Speaker 1", 8.0, 11),
        ], maxGapSeconds: 3.0)
        XCTAssertEqual(merged.count, 1, "a gap of exactly maxGapSeconds still merges")
    }

    /// Real conversational pauses run to a few seconds; meeting processing passes 3.0s
    /// explicitly (MeetingProcessingPipeline.meetingTurnMergeGapSeconds) so a 1.0s gap doesn't
    /// fragment every turn on a live Zoom call and starve the ASR of context.
    func testTypicalConversationalPauseMerges() {
        let merged = SpeakerDiarizationService.mergeAdjacentTurns([
            self.turn("Speaker 1", 0, 5),
            self.turn("Speaker 1", 7.5, 11),
        ], maxGapSeconds: 3.0)
        XCTAssertEqual(merged.count, 1)
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
            startSeconds: 3661,
            endSeconds: 3670,
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

/// Word-timing mapping is meeting-only: `transcribeFinal` never reaches it.
final class FluidAudioProviderWordTimingTests: XCTestCase {
    func testMakeWordTimingsReconstructsWordsFromTokenTimings() {
        let tokenTimings: [TokenTiming] = [
            TokenTiming(token: "▁Hello", tokenId: 1, startTime: 0.0, endTime: 0.4, confidence: 0.9),
            TokenTiming(token: "▁world", tokenId: 2, startTime: 0.5, endTime: 0.9, confidence: 0.9),
        ]

        let words = FluidAudioProvider.makeWordTimings(from: tokenTimings)

        XCTAssertEqual(words.map(\.text), ["Hello", "world"])
        XCTAssertEqual(words.first?.start, 0.0)
        XCTAssertEqual(words.first?.end, 0.4)
        XCTAssertEqual(words.last?.start, 0.5)
        XCTAssertEqual(words.last?.end, 0.9)
    }

    func testMakeWordTimingsEmptyInputProducesNoWords() {
        XCTAssertTrue(FluidAudioProvider.makeWordTimings(from: []).isEmpty)
    }

    /// With boosting active, alignment must be off so no second full ASR pass ever runs.
    func testSupportsWordTimingsDisabledWhileBoostingActive() {
        let provider = FluidAudioProvider(configureWordBoosting: true)
        XCTAssertTrue(provider.supportsWordTimings, "no boosting configured yet: timings should be available")

        provider.setWordBoostingActiveForTesting(true)
        XCTAssertFalse(provider.supportsWordTimings, "boosting active: word alignment must be disabled")

        provider.setWordBoostingActiveForTesting(false)
        XCTAssertTrue(provider.supportsWordTimings)
    }
}

#endif

// MARK: - Transcript exporter tests (kept on MeetingSessionModelTests so the standard
// meeting-suite -only-testing invocation exercises them without an extra class filter).
extension MeetingSessionModelTests {
    private static let allowedExportKeys: Set<String> = [
        "schemaVersion", "title", "languageCode", "startedAt", "endedAt", "durationSeconds",
        "mode", "applicationDisplayName", "speakers", "id", "displayName", "isLocalUser",
        "segments", "startSeconds", "endSeconds", "speakerID", "text", "revision", "status",
        "overlap", "completeness", "isLikelyEcho",
    ]

    private func collectDictionaryKeys(in value: Any, into keys: inout Set<String>) {
        if let dict = value as? [String: Any] {
            for (key, nested) in dict {
                keys.insert(key)
                self.collectDictionaryKeys(in: nested, into: &keys)
            }
        } else if let array = value as? [Any] {
            for element in array {
                self.collectDictionaryKeys(in: element, into: &keys)
            }
        }
    }

    func testTextFormatMatchesTimestampFormatAndUnknownSpeaker() {
        var session = MeetingModelFixture.makeSession()
        var unknownSpeakerSegment = session.transcriptSegments[0]
        unknownSpeakerSegment.id = UUID()
        unknownSpeakerSegment.start = MeetingModelFixture.mediaTime(65)
        unknownSpeakerSegment.end = MeetingModelFixture.mediaTime(70)
        unknownSpeakerSegment.speakerID = nil
        unknownSpeakerSegment.text = "No speaker text"
        // Inserted out of chronological order to prove the exporter sorts by start.
        session.transcriptSegments.insert(unknownSpeakerSegment, at: 0)

        let lines = MeetingTranscriptExporter.text(for: session).components(separatedBy: "\n\n")

        XCTAssertEqual(lines, [
            "[00:04] Speaker 1: Initial provisional text",
            "[01:05] Unknown speaker: No speaker text",
        ])
    }

    /// `isLikelyEcho` must stay optional: a non-optional defaulted property makes the synthesized
    /// decoder require the key, and the store silently drops sessions that fail to decode.
    func testSegmentWithoutEchoKeyStillDecodes() throws {
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
        XCTAssertFalse(segment.isEcho)
        XCTAssertNil(segment.isLikelyEcho)
    }

    func testJSONExportContainsOnlyAllowlistedKeys() throws {
        let session = MeetingModelFixture.makeSession()
        let data = try MeetingTranscriptExporter.json(for: session)
        let json = try JSONSerialization.jsonObject(with: data)

        var keys: Set<String> = []
        self.collectDictionaryKeys(in: json, into: &keys)

        XCTAssertTrue(
            keys.isSubset(of: Self.allowedExportKeys),
            "Unexpected keys leaked into the export: \(keys.subtracting(Self.allowedExportKeys))"
        )
        XCTAssertTrue(keys.contains("schemaVersion"))
        XCTAssertTrue(keys.contains("speakers"))
        XCTAssertTrue(keys.contains("segments"))
    }

    /// Belt-and-suspenders on top of the key-allowlist test above: even with diarization
    /// embeddings/quality and an app/mic identity populated, none of that raw content — not just
    /// its JSON keys — may appear anywhere in the exported bytes.
    func testJSONExportRawBytesNeverContainPrivacySensitiveContent() throws {
        var session = MeetingModelFixture.makeSession()
        session.speakers[0].diarizationEmbedding = [0.998_877, -0.112_233]
        session.speakers[0].diarizationEmbeddingObservationCount = 990_881_774
        session.speakers[0].diarizationQuality = 0.771_122

        let data = try MeetingTranscriptExporter.json(for: session)
        let raw = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(raw.contains("998877"), "diarization embedding values must never leak into the export")
        XCTAssertFalse(raw.contains("112233"), "diarization embedding values must never leak into the export")
        XCTAssertFalse(raw.contains("990881774"), "diarization embedding observation count must never leak into the export")
        XCTAssertFalse(raw.contains("771122"), "diarization quality must never leak into the export")
        XCTAssertFalse(raw.contains("cluster"), "diarization cluster id must never leak into the export")
        XCTAssertFalse(raw.contains("us.zoom.xos"), "the captured application's bundle identifier must never leak into the export")
        XCTAssertFalse(raw.contains("capture-mic"), "the microphone capture device id must never leak into the export")
        XCTAssertFalse(raw.contains("core-audio-mic"), "the microphone Core Audio UID must never leak into the export")
    }

    func testJSONExportOmitsMergedAwaySpeakerAndReflectsCorrectedName() throws {
        var session = MeetingModelFixture.makeSession()
        let targetID = UUID()
        session.speakers.append(MeetingModelFixture.speaker(id: targetID, name: "Speaker 2"))
        try session.mergeSpeakers(MeetingModelFixture.speakerID, into: targetID)

        let data = try MeetingTranscriptExporter.json(for: session)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let speakers = try XCTUnwrap(json["speakers"] as? [[String: Any]])
        let speakerIDs = Set(speakers.compactMap { $0["id"] as? String })

        XCTAssertFalse(speakerIDs.contains(MeetingModelFixture.speakerID.uuidString))
        XCTAssertTrue(speakerIDs.contains(targetID.uuidString))
        XCTAssertTrue(MeetingTranscriptExporter.text(for: session).contains("Speaker 2:"))
    }

    /// Every exported segment's speakerID must resolve through the same alias chain as the
    /// exported speakers array — no JSON segment may reference a speaker absent from `speakers`.
    func testJSONExportSegmentSpeakerIDsAllResolveIntoExportedSpeakers() throws {
        var session = MeetingModelFixture.makeSession()
        let targetID = UUID()
        session.speakers.append(MeetingModelFixture.speaker(id: targetID, name: "Speaker 2"))
        try session.mergeSpeakers(MeetingModelFixture.speakerID, into: targetID)

        let data = try MeetingTranscriptExporter.json(for: session)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let speakers = try XCTUnwrap(json["speakers"] as? [[String: Any]])
        let exportedSpeakerIDs = Set(speakers.compactMap { $0["id"] as? String })
        let segments = try XCTUnwrap(json["segments"] as? [[String: Any]])

        for segment in segments {
            guard let speakerID = segment["speakerID"] as? String else { continue }
            XCTAssertTrue(
                exportedSpeakerIDs.contains(speakerID),
                "segment speakerID \(speakerID) is missing from the exported speakers array"
            )
        }
    }

    func testTextAndJSONExportReflectRenamedSpeaker() throws {
        var session = MeetingModelFixture.makeSession()
        try session.renameSpeaker(id: MeetingModelFixture.speakerID, to: "Erik")

        XCTAssertTrue(MeetingTranscriptExporter.text(for: session).contains("Erik:"))

        let data = try MeetingTranscriptExporter.json(for: session)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let speakers = try XCTUnwrap(json["speakers"] as? [[String: Any]])
        XCTAssertTrue(speakers.contains { ($0["displayName"] as? String) == "Erik" })
    }

    func testDurationAndStartSecondsAreNumericallySane() throws {
        let session = MeetingModelFixture.makeSession()
        let data = try MeetingTranscriptExporter.json(for: session)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let duration = try XCTUnwrap(json["durationSeconds"] as? Double)
        XCTAssertEqual(duration, session.duration, accuracy: 0.001)
        XCTAssertGreaterThan(duration, 0)

        let segments = try XCTUnwrap(json["segments"] as? [[String: Any]])
        let startSeconds = try XCTUnwrap(segments.first?["startSeconds"] as? Double)
        XCTAssertEqual(startSeconds, 4, accuracy: 0.001)
    }

    func testTextExportExcludesEchoByDefaultAndIncludesWithFlag() throws {
        var session = MeetingModelFixture.makeSession()
        var echoSegment = session.transcriptSegments[0]
        echoSegment.id = UUID()
        echoSegment.start = MeetingModelFixture.mediaTime(20)
        echoSegment.end = MeetingModelFixture.mediaTime(24)
        echoSegment.text = "Echoed remote text"
        echoSegment.isLikelyEcho = true
        session.transcriptSegments.append(echoSegment)

        let withoutEchoes = MeetingTranscriptExporter.text(for: session)
        XCTAssertFalse(withoutEchoes.contains("Echoed remote text"))

        let withEchoes = MeetingTranscriptExporter.text(for: session, includeEchoes: true)
        XCTAssertTrue(withEchoes.contains("Echoed remote text"))
    }

    func testJSONExportAlwaysIncludesEchoSegmentsWithFlag() throws {
        var session = MeetingModelFixture.makeSession()
        var echoSegment = session.transcriptSegments[0]
        echoSegment.id = UUID()
        echoSegment.start = MeetingModelFixture.mediaTime(20)
        echoSegment.end = MeetingModelFixture.mediaTime(24)
        echoSegment.text = "Echoed remote text"
        echoSegment.isLikelyEcho = true
        session.transcriptSegments.append(echoSegment)

        let data = try MeetingTranscriptExporter.json(for: session)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let segments = try XCTUnwrap(json["segments"] as? [[String: Any]])

        XCTAssertEqual(segments.count, 2)
        let echoFlags = segments.compactMap { $0["isLikelyEcho"] as? Bool }
        XCTAssertEqual(echoFlags.count, 2, "isLikelyEcho must always be present so the export key set stays stable")
        XCTAssertTrue(echoFlags.contains(true))
        XCTAssertTrue(echoFlags.contains(false))
    }
}

final class MeetingEchoDetectorTests: XCTestCase {
    func testIdenticalTextIsEcho() {
        let text = "It was proactive like sometimes it was just like check on me during the day."
        XCTAssertTrue(MeetingEchoDetector.isLikelyEcho(micText: text, remoteText: text))
    }

    /// The real pair that motivated containment over Jaccard.
    func testRealZoomPairIsEcho() {
        let mic = "It was proactive like sometimes it was just like check on me during the day."
        let remote = "It was proactive, like sometimes the winter like check on me during the day."
        XCTAssertTrue(MeetingEchoDetector.isLikelyEcho(micText: mic, remoteText: remote))
    }

    func testUnrelatedMicTextOverlappingRemoteTextIsNotEcho() {
        let mic = "Let's move the roadmap review to Thursday afternoon instead please."
        let remote = "It was proactive, like sometimes the winter like check on me during the day."
        XCTAssertFalse(MeetingEchoDetector.isLikelyEcho(micText: mic, remoteText: remote))
    }

    func testShortFullyContainedMicLineIsNotEchoBelowMinimumWordFloor() {
        let mic = "check on me"
        let remote = "It was proactive, like sometimes the winter like check on me during the day."
        XCTAssertLessThan(MeetingEchoDetector.normalizedWords(mic).count, MeetingEchoDetector.minimumMicWords)
        XCTAssertEqual(MeetingEchoDetector.containment(micText: mic, remoteText: remote), 1.0)
        XCTAssertFalse(MeetingEchoDetector.isLikelyEcho(micText: mic, remoteText: remote))
    }

    func testEmptyRemoteTextIsNotEcho() {
        let mic = "It was proactive like sometimes it was just like check on me during the day."
        XCTAssertFalse(MeetingEchoDetector.isLikelyEcho(micText: mic, remoteText: ""))
    }

    /// Short genuine speech that happens to share most of its (few) content words with unrelated
    /// remote text must not be flagged — only 2 of 3 mic content words match.
    func testShortGenuineSpeechSharingFewContentWordsIsNotEcho() {
        let mic = "the roadmap timeline works"
        let remote = "roadmap timeline"
        XCTAssertFalse(MeetingEchoDetector.isLikelyEcho(micText: mic, remoteText: remote))
    }
}

final class MeetingTurnSelectionTests: XCTestCase {
    private typealias Turn = (index: Int, turn: String, text: String)

    func testMiddleTurnEmptyKeepsOthersWithOriginalIndices() {
        let turns: [Turn] = [(0, "a", "hello"), (1, "b", ""), (2, "c", "world")]
        let kept = MeetingTurnSelection.keepingNonEmpty(turns)
        XCTAssertEqual(kept?.map(\.index), [0, 2])
        XCTAssertEqual(kept?.map(\.text), ["hello", "world"])
    }

    func testAllEmptyReturnsNil() {
        let turns: [Turn] = [(0, "a", ""), (1, "b", "")]
        XCTAssertNil(MeetingTurnSelection.keepingNonEmpty(turns))
    }

    func testNoneEmptyReturnsUnchanged() {
        let turns: [Turn] = [(0, "a", "hello"), (1, "b", "world")]
        let kept = MeetingTurnSelection.keepingNonEmpty(turns)
        XCTAssertEqual(kept?.map(\.index), [0, 1])
        XCTAssertEqual(kept?.map(\.text), ["hello", "world"])
    }
}

/// F1 regression guard: the 60s whole-chunk fallback segment is too coarse to score for echo
/// containment, so it must never enter the candidate set.
final class MeetingEchoCandidateTextTests: XCTestCase {
    private let applicationTrackID = UUID()
    private let diarizedSpeakerID = UUID()
    private let fallbackSpeakerID = UUID()

    private func segment(speakerID: SessionSpeakerID, start: TimeInterval, end: TimeInterval, text: String) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(
            id: UUID(),
            start: MeetingMediaTime(value: Int64(start * 1000), timescale: 1000),
            end: MeetingMediaTime(value: Int64(end * 1000), timescale: 1000),
            sourceTrackID: self.applicationTrackID,
            speakerID: speakerID,
            text: text,
            revision: 0,
            status: .final,
            overlap: .none,
            completeness: .complete
        )
    }

    func testFallbackSpeakerSegmentIsExcludedFromCandidateSet() {
        let diarized = self.segment(speakerID: self.diarizedSpeakerID, start: 0, end: 5, text: "diarized remote text")
        let fallback = self.segment(speakerID: self.fallbackSpeakerID, start: 0, end: 60, text: "coarse whole chunk fallback text")

        let text = MeetingProcessingPipeline.echoCandidateText(
            segments: [diarized, fallback],
            speakerIDToExclude: self.fallbackSpeakerID,
            applicationTrackID: self.applicationTrackID,
            window: (start: 1, end: 3)
        )

        XCTAssertEqual(text, "diarized remote text")
    }

    func testNilExclusionKeepsAllOverlappingSegments() {
        let diarized = self.segment(speakerID: self.diarizedSpeakerID, start: 0, end: 5, text: "diarized remote text")
        let fallback = self.segment(speakerID: self.fallbackSpeakerID, start: 0, end: 60, text: "coarse whole chunk fallback text")

        let text = MeetingProcessingPipeline.echoCandidateText(
            segments: [diarized, fallback],
            speakerIDToExclude: nil,
            applicationTrackID: self.applicationTrackID,
            window: (start: 1, end: 3)
        )

        XCTAssertTrue(text.contains("diarized remote text"))
        XCTAssertTrue(text.contains("coarse whole chunk fallback text"))
    }
}

final class MeetingSpeakerEmbeddingIndexTests: XCTestCase {
    func testSameVoiceAcrossChunksMatchesStableSpeakerID() {
        let speakerID = UUID()
        var index = MeetingSpeakerEmbeddingIndex()
        index.observe(speakerID: speakerID, embedding: [1, 0, 0], quality: 0.9)

        XCTAssertEqual(index.bestMatch(for: [0.99, 0.01, 0]), speakerID)
    }

    func testDistinctVoiceDoesNotMerge() {
        let speakerID = UUID()
        var index = MeetingSpeakerEmbeddingIndex()
        index.observe(speakerID: speakerID, embedding: [1, 0, 0], quality: 0.9)

        XCTAssertNil(index.bestMatch(for: [0, 1, 0]))
    }

    func testAmbiguousNearestVoicesDoNotMerge() {
        var index = MeetingSpeakerEmbeddingIndex()
        index.observe(speakerID: UUID(), embedding: [1, 0.02, 0], quality: 0.9)
        index.observe(speakerID: UUID(), embedding: [1, -0.02, 0], quality: 0.9)

        XCTAssertNil(index.bestMatch(for: [1, 0, 0]))
    }

    func testChunkLocalOneToOneExclusionPreventsDuplicateAssignment() {
        let speakerID = UUID()
        var index = MeetingSpeakerEmbeddingIndex()
        index.observe(speakerID: speakerID, embedding: [1, 0, 0], quality: 0.9)

        XCTAssertNil(index.bestMatch(for: [1, 0, 0], excluding: [speakerID]))
    }

    func testPersonalMicNeedsOneDominantEmbeddedClusterForYou() {
        let localID = UUID()
        let secondaryID = UUID()
        let selected = MeetingLocalSpeakerEvidenceSelector.candidate(
            cleanDurationByCluster: [localID: 12, secondaryID: 3],
            prototypeSpeakerIDs: [localID, secondaryID]
        )

        XCTAssertEqual(selected, localID)
    }

    func testAmbiguousPersonalMicClustersDoNotSelectYou() {
        let firstID = UUID()
        let secondID = UUID()
        let selected = MeetingLocalSpeakerEvidenceSelector.candidate(
            cleanDurationByCluster: [firstID: 8, secondID: 7],
            prototypeSpeakerIDs: [firstID, secondID]
        )

        XCTAssertNil(selected)
    }

    func testClusterWithoutPositiveEmbeddingEvidenceDoesNotSelectYou() {
        let clusterID = UUID()
        let selected = MeetingLocalSpeakerEvidenceSelector.candidate(
            cleanDurationByCluster: [clusterID: 12],
            prototypeSpeakerIDs: []
        )

        XCTAssertNil(selected)
    }
}

final class MeetingSessionModelTests: XCTestCase {
    func testMeetingRecordingDefaultsRoundTripStableSourceIdentifiers() throws {
        let defaults = MeetingRecordingDefaults(
            isConfigured: true,
            mode: .onlineCall,
            applicationBundleIdentifier: "com.google.Chrome",
            microphoneCaptureDeviceID: "av-device-id",
            microphoneCoreAudioUID: "core-audio-uid",
            microphoneRole: .personal
        )

        let encoded = try JSONEncoder().encode(defaults)
        let decoded = try JSONDecoder().decode(MeetingRecordingDefaults.self, from: encoded)

        XCTAssertEqual(decoded, defaults)
        XCTAssertEqual(decoded.applicationBundleIdentifier, "com.google.Chrome")
        XCTAssertEqual(decoded.microphoneCaptureDeviceID, "av-device-id")
        XCTAssertEqual(decoded.microphoneCoreAudioUID, "core-audio-uid")
    }

    func testUnconfiguredMeetingDefaultsRemainConservative() {
        let defaults = MeetingRecordingDefaults.unconfigured

        XCTAssertFalse(defaults.isConfigured)
        XCTAssertEqual(defaults.mode, .onlineCall)
        XCTAssertEqual(defaults.microphoneRole, .unknown)
        XCTAssertNil(defaults.applicationBundleIdentifier)
        XCTAssertNil(defaults.microphoneCaptureDeviceID)
    }

    func testConfiguredMeetingDefaultsResolveOnlySavedSources() {
        let defaults = MeetingRecordingDefaults(
            isConfigured: true,
            mode: .onlineCall,
            applicationBundleIdentifier: "com.google.Chrome",
            microphoneCaptureDeviceID: "saved-device",
            microphoneCoreAudioUID: "saved-core-audio",
            microphoneRole: .personal
        )
        let applications = [
            MeetingApplicationIdentity(bundleIdentifier: "us.zoom.xos", displayName: "Zoom"),
            MeetingApplicationIdentity(bundleIdentifier: "com.google.Chrome", displayName: "Google Chrome"),
        ]
        let microphones = [
            MeetingMicrophoneIdentity(captureDeviceID: "other-device", displayName: "Other"),
            MeetingMicrophoneIdentity(captureDeviceID: "saved-device", displayName: "Saved"),
        ]

        XCTAssertEqual(defaults.savedApplication(in: applications)?.bundleIdentifier, "com.google.Chrome")
        XCTAssertEqual(defaults.savedMicrophone(in: microphones)?.captureDeviceID, "saved-device")
        XCTAssertNil(defaults.savedApplication(in: [applications[0]]))
        XCTAssertNil(defaults.savedMicrophone(in: [microphones[0]]))
    }

    func testCodableRoundTripPreservesStableMeetingIdentitiesAndTrackRelationships() throws {
        let session = MeetingModelFixture.makeSession()

        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(MeetingSession.self, from: encoded)

        XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded.id, MeetingModelFixture.sessionID)
        XCTAssertEqual(decoded.languageCode, "en")
        XCTAssertEqual(decoded.audioTracks.map(\.kind.rawValue).sorted(), [
            MeetingAudioTrackKind.applicationAudio.rawValue,
            MeetingAudioTrackKind.microphone.rawValue,
        ])
        XCTAssertEqual(decoded.audioTracks.map(\.id), [
            MeetingModelFixture.applicationTrackID,
            MeetingModelFixture.microphoneTrackID,
        ])
        XCTAssertEqual(decoded.audioTracks[0].chunks.map(\.sequence), [0, 1])
        XCTAssertEqual(decoded.audioTracks[0].chunks.map(\.id), [
            MeetingModelFixture.applicationChunk0ID,
            MeetingModelFixture.applicationChunk1ID,
        ])

        let segment = try XCTUnwrap(decoded.transcriptSegments.first)
        XCTAssertEqual(segment.id, MeetingModelFixture.segmentID)
        XCTAssertTrue(decoded.audioTracks.contains { $0.id == segment.sourceTrackID })
        XCTAssertTrue(decoded.speakers.contains { $0.id == segment.speakerID })
        XCTAssertEqual(decoded.processingAttempts.first?.languageCode, "en")
    }

    func testSpeakerRenameChangesOnlyDisplayMetadata() throws {
        var session = MeetingModelFixture.makeSession()
        let originalSegments = session.transcriptSegments
        let originalTrackIDs = session.audioTracks.map(\.id)
        let originalClusterID = session.speakers.first?.diarizationClusterID

        try session.renameSpeaker(id: MeetingModelFixture.speakerID, to: "  Erik  ")

        let speaker = try XCTUnwrap(session.speakers.first)
        XCTAssertEqual(speaker.id, MeetingModelFixture.speakerID)
        XCTAssertEqual(speaker.displayName, "Erik")
        XCTAssertEqual(speaker.diarizationClusterID, originalClusterID)
        XCTAssertEqual(session.transcriptSegments, originalSegments)
        XCTAssertEqual(session.transcriptSegments.map(\.id), [MeetingModelFixture.segmentID])
        XCTAssertEqual(session.audioTracks.map(\.id), originalTrackIDs)
    }

    func testRejectedSpeakerRenamesLeaveSessionIdentityUntouched() {
        var session = MeetingModelFixture.makeSession()
        let originalSpeakers = session.speakers
        let originalSegments = session.transcriptSegments
        let originalUpdatedAt = session.updatedAt

        XCTAssertThrowsError(try session.renameSpeaker(id: MeetingModelFixture.speakerID, to: "  \n  ")) {
            XCTAssertEqual($0 as? MeetingDomainError, .emptySpeakerName)
        }
        XCTAssertThrowsError(try session.renameSpeaker(id: UUID(), to: "Erik")) {
            XCTAssertEqual($0 as? MeetingDomainError, .speakerNotFound)
        }

        XCTAssertEqual(session.speakers, originalSpeakers)
        XCTAssertEqual(session.transcriptSegments, originalSegments)
        XCTAssertEqual(session.updatedAt, originalUpdatedAt)
    }

    func testTranscriptRevisionKeepsStableSegmentAndDomainReferences() {
        var segment = MeetingModelFixture.makeSession().transcriptSegments[0]
        let originalID = segment.id
        let originalTrackID = segment.sourceTrackID
        let originalSpeakerID = segment.speakerID

        segment.text = "Revised final text"
        segment.revision += 1
        segment.status = .final

        XCTAssertEqual(segment.id, originalID)
        XCTAssertEqual(segment.sourceTrackID, originalTrackID)
        XCTAssertEqual(segment.speakerID, originalSpeakerID)
        XCTAssertEqual(segment.revision, 2)
        XCTAssertEqual(segment.status, .final)
    }

    func testCaptureConfigurationPinsEnglishAndSeparatesMicrophoneIdentifiers() {
        let configuration = MeetingCaptureConfiguration(
            mode: .inRoom,
            title: "Room sync",
            microphone: MeetingMicrophoneIdentity(
                captureDeviceID: "avcapture-device-id",
                coreAudioUID: "core-audio-uid",
                displayName: "Studio microphone",
                role: .shared
            ),
            chunkDuration: 5
        )

        XCTAssertEqual(configuration.languageCode, "en")
        XCTAssertEqual(configuration.chunkDuration, 60)
        XCTAssertEqual(configuration.microphone.captureDeviceID, "avcapture-device-id")
        XCTAssertEqual(configuration.microphone.coreAudioUID, "core-audio-uid")
        XCTAssertEqual(configuration.microphone.role, .shared)
        XCTAssertNil(configuration.application)
    }

    func testCaptureConfigurationRejectsInvalidModeSourcesLanguageAndMicrophone() {
        var configuration = MeetingModelFixture.makeOnlineConfiguration()
        XCTAssertNoThrow(try configuration.validate())

        configuration.languageCode = "fr"
        self.assertConfigurationValidationError(.unsupportedLanguage, configuration: configuration)

        configuration = MeetingModelFixture.makeOnlineConfiguration()
        configuration.microphone.captureDeviceID = ""
        self.assertConfigurationValidationError(.missingMicrophone, configuration: configuration)

        configuration = MeetingModelFixture.makeOnlineConfiguration()
        configuration.application = nil
        self.assertConfigurationValidationError(.missingOnlineApplication, configuration: configuration)

        configuration = MeetingModelFixture.makeOnlineConfiguration()
        configuration.mode = .inRoom
        self.assertConfigurationValidationError(.unexpectedInRoomApplication, configuration: configuration)
    }

    func testPersistenceValidationRequiresExpectedUniqueTrackSet() {
        XCTAssertNoThrow(try MeetingModelFixture.makeSession().validateForPersistence())

        self.assertSessionValidationError(.missingMicrophone) {
            $0.selectedMicrophone.captureDeviceID = ""
        }
        self.assertSessionValidationError(.invalidTrackSet) {
            $0.audioTracks.removeLast()
        }
        self.assertSessionValidationError(.duplicateTrackID) {
            $0.audioTracks[1].id = $0.audioTracks[0].id
        }
        self.assertSessionValidationError(.duplicateTrackKind) {
            $0.audioTracks[1].kind = .applicationAudio
        }
    }

    func testPersistenceValidationRequiresOrderedRecoverableChunks() {
        self.assertSessionValidationError(.invalidChunkSequence) {
            $0.audioTracks[0].chunks.reverse()
        }
        self.assertSessionValidationError(.duplicateChunkID) {
            $0.audioTracks[1].chunks[0].id = $0.audioTracks[0].chunks[0].id
        }
        self.assertSessionValidationError(.invalidMediaTimescale) {
            $0.audioTracks[0].chunks[0].presentationStart.timescale = 0
        }
        self.assertSessionValidationError(.invalidTimeRange) {
            $0.audioTracks[0].chunks[0].presentationEnd = MeetingModelFixture.mediaTime(-1)
        }
        self.assertSessionValidationError(.incompleteFinalizedChunk) {
            $0.audioTracks[0].chunks[0].sha256 = ""
        }
    }

    func testPersistenceValidationRequiresUniqueResolvableTranscriptReferences() {
        self.assertSessionValidationError(.duplicateSpeakerID) {
            $0.speakers.append($0.speakers[0])
        }
        self.assertSessionValidationError(.duplicateSegmentID) {
            $0.transcriptSegments.append($0.transcriptSegments[0])
        }
        self.assertSessionValidationError(.missingSegmentTrack) {
            $0.transcriptSegments[0].sourceTrackID = UUID()
        }
        self.assertSessionValidationError(.missingSegmentSpeaker) {
            $0.transcriptSegments[0].speakerID = UUID()
        }
    }

    func testRenameSpeakerAppliesToAllSegmentsViaLookupNotStorage() throws {
        var session = MeetingModelFixture.makeSession()
        var secondSegment = session.transcriptSegments[0]
        secondSegment.id = UUID()
        session.transcriptSegments.append(secondSegment)
        let originalSegmentIDs = session.transcriptSegments.map(\.id)
        let originalSpeakerIDs = session.transcriptSegments.map(\.speakerID)

        try session.renameSpeaker(id: MeetingModelFixture.speakerID, to: "Renamed")

        XCTAssertEqual(session.transcriptSegments.map(\.id), originalSegmentIDs)
        XCTAssertEqual(session.transcriptSegments.map(\.speakerID), originalSpeakerIDs)
        XCTAssertEqual(session.speakers.first(where: { $0.id == MeetingModelFixture.speakerID })?.displayName, "Renamed")
    }

    func testRenameAliasedSpeakerThrows() throws {
        var session = MeetingModelFixture.makeSession()
        let targetID = UUID()
        session.speakers.append(MeetingModelFixture.speaker(id: targetID, name: "Speaker 2"))
        try session.mergeSpeakers(MeetingModelFixture.speakerID, into: targetID)

        XCTAssertThrowsError(try session.renameSpeaker(id: MeetingModelFixture.speakerID, to: "New Name")) {
            XCTAssertEqual($0 as? MeetingDomainError, .speakerNotFound)
        }
    }

    func testReassignSegmentChangesSpeakerAndBumpsRevision() throws {
        var session = MeetingModelFixture.makeSession()
        let targetID = UUID()
        session.speakers.append(MeetingModelFixture.speaker(id: targetID, name: "Speaker 2"))
        let originalSegmentID = session.transcriptSegments[0].id
        let originalRevision = session.transcriptSegments[0].revision

        try session.reassignSegment(id: originalSegmentID, to: targetID)

        let segment = try XCTUnwrap(session.transcriptSegments.first)
        XCTAssertEqual(segment.id, originalSegmentID)
        XCTAssertEqual(segment.speakerID, targetID)
        XCTAssertEqual(segment.revision, originalRevision + 1)
    }

    func testReassignSegmentToSameSpeakerIsNoOp() throws {
        var session = MeetingModelFixture.makeSession()
        let segmentID = session.transcriptSegments[0].id
        let speakerID = try XCTUnwrap(session.transcriptSegments[0].speakerID)
        let originalRevision = session.transcriptSegments[0].revision

        try session.reassignSegment(id: segmentID, to: speakerID)

        XCTAssertEqual(session.transcriptSegments[0].revision, originalRevision)
    }

    func testReassignSegmentThrowsForMissingSegmentOrSpeaker() {
        var session = MeetingModelFixture.makeSession()
        XCTAssertThrowsError(try session.reassignSegment(id: UUID(), to: MeetingModelFixture.speakerID)) {
            XCTAssertEqual($0 as? MeetingDomainError, .segmentNotFound)
        }
        XCTAssertThrowsError(try session.reassignSegment(id: MeetingModelFixture.segmentID, to: UUID())) {
            XCTAssertEqual($0 as? MeetingDomainError, .speakerNotFound)
        }
    }

    func testReassignSegmentToAliasThrows() throws {
        var session = MeetingModelFixture.makeSession()
        let targetID = UUID()
        let aliasID = UUID()
        session.speakers.append(MeetingModelFixture.speaker(id: targetID, name: "Speaker 2"))
        session.speakers.append(MeetingModelFixture.speaker(id: aliasID, name: "Alias", mergedIntoSpeakerID: targetID))

        XCTAssertThrowsError(try session.reassignSegment(id: MeetingModelFixture.segmentID, to: aliasID)) {
            XCTAssertEqual($0 as? MeetingDomainError, .speakerNotFound)
        }
    }

    func testMergeSpeakersMovesSegmentsAndKeepsSourceAsAlias() throws {
        var session = MeetingModelFixture.makeSession()
        let sourceID = MeetingModelFixture.speakerID
        let targetID = UUID()
        session.speakers.append(MeetingModelFixture.speaker(id: targetID, name: "Speaker 2"))
        let segmentID = session.transcriptSegments[0].id
        let originalRevision = session.transcriptSegments[0].revision

        try session.mergeSpeakers(sourceID, into: targetID)

        let movedSegment = try XCTUnwrap(session.transcriptSegments.first(where: { $0.id == segmentID }))
        XCTAssertEqual(movedSegment.speakerID, targetID)
        XCTAssertEqual(movedSegment.revision, originalRevision + 1)
        let source = try XCTUnwrap(session.speakers.first(where: { $0.id == sourceID }))
        XCTAssertEqual(source.mergedIntoSpeakerID, targetID)
        XCTAssertFalse(session.activeSpeakers.contains(where: { $0.id == sourceID }))
        XCTAssertTrue(session.activeSpeakers.contains(where: { $0.id == targetID }))
    }

    func testMergeSpeakerWithItselfThrows() {
        var session = MeetingModelFixture.makeSession()
        XCTAssertThrowsError(try session.mergeSpeakers(MeetingModelFixture.speakerID, into: MeetingModelFixture.speakerID)) {
            XCTAssertEqual($0 as? MeetingDomainError, .cannotMergeSpeakerWithItself)
        }
    }

    func testMergeSpeakersAcrossTracksThrows() throws {
        var session = MeetingModelFixture.makeSession()
        let targetID = UUID()
        session.speakers.append(MeetingModelFixture.speaker(id: targetID, name: "Mic speaker", trackKind: .microphone))

        XCTAssertThrowsError(try session.mergeSpeakers(MeetingModelFixture.speakerID, into: targetID)) {
            XCTAssertEqual($0 as? MeetingDomainError, .cannotMergeSpeakers)
        }
    }

    func testMergeLocalUserSpeakerThrows() throws {
        var session = MeetingModelFixture.makeSession()
        let localID = UUID()
        let targetID = UUID()
        session.speakers.append(MeetingModelFixture.speaker(id: localID, name: "You", isLocalUser: true))
        session.speakers.append(MeetingModelFixture.speaker(id: targetID, name: "Speaker 2"))

        XCTAssertThrowsError(try session.mergeSpeakers(localID, into: targetID)) {
            XCTAssertEqual($0 as? MeetingDomainError, .cannotMergeSpeakers)
        }
        XCTAssertThrowsError(try session.mergeSpeakers(targetID, into: localID)) {
            XCTAssertEqual($0 as? MeetingDomainError, .cannotMergeSpeakers)
        }
    }

    func testProcessingAttemptLanguageMustMatchSessionLanguage() {
        self.assertSessionValidationError(.unsupportedLanguage) {
            $0.processingAttempts[0].languageCode = "fr"
        }
    }

    private func assertConfigurationValidationError(
        _ expected: MeetingModelValidationError,
        configuration: MeetingCaptureConfiguration,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try configuration.validate(), file: file, line: line) {
            XCTAssertEqual($0 as? MeetingModelValidationError, expected, file: file, line: line)
        }
    }

    private func assertSessionValidationError(
        _ expected: MeetingModelValidationError,
        mutating mutate: (inout MeetingSession) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var session = MeetingModelFixture.makeSession()
        mutate(&session)
        XCTAssertThrowsError(try session.validateForPersistence(), file: file, line: line) {
            XCTAssertEqual($0 as? MeetingModelValidationError, expected, file: file, line: line)
        }
    }

    // MARK: - assignWords

    private func word(_ text: String, _ start: Double, _ end: Double) -> ASRWordTiming {
        ASRWordTiming(text: text, start: start, end: end)
    }

    func testAssignWordsEmptyInput() {
        let result = MeetingProcessingPipeline.assignWords([], toTurns: [(index: 0, start: 0, end: 5)])
        XCTAssertTrue(result.byTurn.isEmpty)
        XCTAssertEqual(result.unassigned, 0)
    }

    func testAssignWordsWordFullyInsideATurn() {
        let result = MeetingProcessingPipeline.assignWords(
            [self.word("hello", 1, 2)],
            toTurns: [(index: 0, start: 0, end: 5), (index: 1, start: 5, end: 10)]
        )
        XCTAssertEqual(result.byTurn[0], "hello")
        XCTAssertNil(result.byTurn[1])
        XCTAssertEqual(result.unassigned, 0)
    }

    func testAssignWordsStraddlingBoundaryGoesToMaxOverlapExactlyOnce() {
        let result = MeetingProcessingPipeline.assignWords(
            [self.word("straddle", 4, 8)],
            toTurns: [(index: 0, start: 0, end: 5), (index: 1, start: 5, end: 8)]
        )
        XCTAssertNil(result.byTurn[0])
        XCTAssertEqual(result.byTurn[1], "straddle")
        XCTAssertEqual(result.unassigned, 0)
    }

    func testAssignWordsBoundaryInstantIsNotDoubleAssigned() {
        // Overlaps neither half-open turn, so nearest-turn attachment takes it (lower index wins).
        let result = MeetingProcessingPipeline.assignWords(
            [self.word("tick", 5, 5)],
            toTurns: [(index: 0, start: 0, end: 5), (index: 1, start: 5, end: 10)]
        )
        XCTAssertEqual(result.byTurn[0], "tick")
        XCTAssertNil(result.byTurn[1])
        XCTAssertEqual(result.unassigned, 0)
    }

    func testAssignWordsInGapWithinToleranceAttachesToNearest() {
        let result = MeetingProcessingPipeline.assignWords(
            [self.word("gap", 5.2, 5.3)],
            toTurns: [(index: 0, start: 0, end: 5), (index: 1, start: 5.5, end: 10)],
            nearestTolerance: 0.5
        )
        XCTAssertEqual(result.byTurn[0], "gap")
        XCTAssertNil(result.byTurn[1])
        XCTAssertEqual(result.unassigned, 0)
    }

    func testAssignWordsFarOutsideCountsAsUnassigned() {
        let result = MeetingProcessingPipeline.assignWords(
            [self.word("far", 20, 21)],
            toTurns: [(index: 0, start: 0, end: 5)],
            nearestTolerance: 0.5
        )
        XCTAssertTrue(result.byTurn.isEmpty)
        XCTAssertEqual(result.unassigned, 1)
    }

    func testAssignWordsPreservesChronologicalOrderWithinATurn() {
        let result = MeetingProcessingPipeline.assignWords(
            [self.word("one", 0, 1), self.word("two", 1, 2), self.word("three", 2, 3)],
            toTurns: [(index: 0, start: 0, end: 5)]
        )
        XCTAssertEqual(result.byTurn[0], "one two three")
    }

    // MARK: - Speaker bleed must never be attached to a local turn

    func testWordAttachmentToleranceIsZeroOnTheMicrophoneTrack() {
        XCTAssertEqual(MeetingProcessingPipeline.wordAttachmentTolerance(for: .microphone), 0)
        XCTAssertGreaterThan(MeetingProcessingPipeline.wordAttachmentTolerance(for: .applicationAudio), 0)
    }

    func testMicrophoneToleranceLeavesOutOfTurnWordsUnassignedInsteadOfCreditingTheUser() {
        // Bled 0.3s after the local turn ends: inside the application window, but not the user's.
        let bled = self.word("bleed", 5.3, 5.8)
        let turns = [(index: 0, start: 0.0, end: 5.0)]

        let onMicrophone = MeetingProcessingPipeline.assignWords(
            [self.word("mine", 1, 2), bled],
            toTurns: turns,
            nearestTolerance: MeetingProcessingPipeline.wordAttachmentTolerance(for: .microphone)
        )
        XCTAssertEqual(onMicrophone.byTurn[0], "mine")
        XCTAssertEqual(onMicrophone.unassigned, 1)

        let onApplication = MeetingProcessingPipeline.assignWords(
            [self.word("mine", 1, 2), bled],
            toTurns: turns,
            nearestTolerance: MeetingProcessingPipeline.wordAttachmentTolerance(for: .applicationAudio)
        )
        XCTAssertEqual(onApplication.byTurn[0], "mine bleed", "remote speakers still absorb near-boundary words")
    }

    func testZeroToleranceStillKeepsWordsOverlappingTheirTurn() {
        let result = MeetingProcessingPipeline.assignWords(
            [self.word("straddle", 4.8, 5.4)],
            toTurns: [(index: 0, start: 0, end: 5)],
            nearestTolerance: 0
        )
        XCTAssertEqual(result.byTurn[0], "straddle")
        XCTAssertEqual(result.unassigned, 0)
    }

    // MARK: - Alignment failures fall back, except what the chunk catch classifies on

    func testAlignmentErrorPropagationClassification() {
        XCTAssertTrue(MeetingProcessingPipeline.alignmentErrorMustPropagate(CancellationError()))
        XCTAssertTrue(MeetingProcessingPipeline.alignmentErrorMustPropagate(MeetingProcessingError.audioUnreadable))
        XCTAssertFalse(MeetingProcessingPipeline.alignmentErrorMustPropagate(MeetingProcessingError.modelUnavailable))
        XCTAssertFalse(
            MeetingProcessingPipeline.alignmentErrorMustPropagate(
                NSError(domain: "test", code: 1)
            )
        )
    }

    // MARK: - Aligned-path safety valve

    func testTooManyWordsUnassignedTripsAboveTwentyFivePercent() {
        XCTAssertTrue(MeetingProcessingPipeline.tooManyWordsUnassigned(unassigned: 26, totalWords: 100))
        XCTAssertFalse(MeetingProcessingPipeline.tooManyWordsUnassigned(unassigned: 25, totalWords: 100))
        XCTAssertFalse(MeetingProcessingPipeline.tooManyWordsUnassigned(unassigned: 0, totalWords: 0))
    }
}

private enum MeetingModelFixture {
    static let sessionID = Self.uuid(1)
    static let applicationTrackID = Self.uuid(2)
    static let microphoneTrackID = Self.uuid(3)
    static let applicationChunk0ID = Self.uuid(4)
    static let applicationChunk1ID = Self.uuid(5)
    static let microphoneChunkID = Self.uuid(6)
    static let speakerID = Self.uuid(7)
    static let segmentID = Self.uuid(8)

    static let startedAt = Date(timeIntervalSince1970: 1_750_000_000)
    static let endedAt = Date(timeIntervalSince1970: 1_750_000_012)

    static func makeOnlineConfiguration() -> MeetingCaptureConfiguration {
        MeetingCaptureConfiguration(
            mode: .onlineCall,
            title: "Design sync",
            platform: MeetingPlatformProfile(identifier: "zoom", displayName: "Zoom", version: 1),
            application: MeetingApplicationIdentity(
                bundleIdentifier: "us.zoom.xos",
                processID: 321,
                displayName: "Zoom",
                displayID: 1
            ),
            microphone: MeetingMicrophoneIdentity(
                captureDeviceID: "capture-mic",
                coreAudioUID: "core-audio-mic",
                displayName: "MacBook Microphone",
                role: .personal
            )
        )
    }

    static func makeSession() -> MeetingSession {
        let timebase = MeetingTimebaseMetadata(
            startedHostTime: 42,
            machTimebaseNumerator: 1,
            machTimebaseDenominator: 1,
            firstPresentationTime: self.mediaTime(0)
        )
        var session = MeetingSession(
            id: self.sessionID,
            configuration: self.makeOnlineConfiguration(),
            startedAt: self.startedAt,
            timebase: timebase
        )
        let format = MeetingAudioFormat(codec: "aac", sampleRate: 48_000, channelCount: 1, bitRate: 96_000)
        let health = MeetingTrackHealth(
            status: .stopped,
            lastPresentationTime: self.mediaTime(12),
            lastSampleAt: self.endedAt,
            level: 0,
            droppedSampleCount: 0,
            detail: nil
        )

        session.state = .completed
        session.endedAt = self.endedAt
        session.audioTracks = [
            MeetingAudioTrack(
                id: self.applicationTrackID,
                kind: .applicationAudio,
                sourceIdentifier: "us.zoom.xos",
                sourceDisplayName: "Zoom",
                format: format,
                timebase: timebase,
                health: health,
                chunks: [
                    self.chunk(
                        id: self.applicationChunk0ID,
                        sequence: 0,
                        path: "application/0000.m4a",
                        start: 0,
                        end: 6,
                        checksum: "application-0"
                    ),
                    self.chunk(
                        id: self.applicationChunk1ID,
                        sequence: 1,
                        path: "application/0001.m4a",
                        start: 6,
                        end: 12,
                        checksum: "application-1"
                    ),
                ]
            ),
            MeetingAudioTrack(
                id: self.microphoneTrackID,
                kind: .microphone,
                sourceIdentifier: "capture-mic",
                sourceDisplayName: "MacBook Microphone",
                format: format,
                timebase: timebase,
                health: health,
                chunks: [
                    self.chunk(
                        id: self.microphoneChunkID,
                        sequence: 0,
                        path: "microphone/0000.m4a",
                        start: 0,
                        end: 12,
                        checksum: "microphone-0"
                    ),
                ]
            ),
        ]
        session.speakers = [
            MeetingSessionSpeaker(
                id: self.speakerID,
                displayName: "Speaker 1",
                diarizationClusterID: "cluster-7",
                trackKind: .applicationAudio,
                isLocalUser: false,
                identityCandidates: [
                    MeetingIdentityCandidate(
                        id: Self.uuid(9),
                        displayName: "Erik",
                        source: "manual",
                        rejected: false,
                        confirmedAt: nil
                    ),
                ]
            ),
        ]
        session.transcriptSegments = [
            MeetingTranscriptSegment(
                id: self.segmentID,
                start: self.mediaTime(4),
                end: self.mediaTime(7),
                sourceTrackID: self.applicationTrackID,
                speakerID: self.speakerID,
                text: "Initial provisional text",
                revision: 1,
                status: .provisional,
                overlap: .none,
                completeness: .complete
            ),
        ]
        session.events = [
            MeetingSessionEvent(
                id: Self.uuid(10),
                occurredAt: self.endedAt,
                kind: .sourceRecovered,
                trackID: self.applicationTrackID,
                detail: "Recovered on a chunk boundary"
            ),
        ]
        session.processingAttempts = [
            MeetingProcessingAttempt(
                id: Self.uuid(11),
                startedAt: self.endedAt,
                completedAt: self.endedAt.addingTimeInterval(3),
                stage: .completed,
                pipelineVersion: 1,
                asrProvider: "fixture-asr",
                asrModel: "fixture-model",
                languageCode: "en",
                diarizationModel: "fixture-diarization",
                lastCompletedTrackID: self.microphoneTrackID,
                errorCode: nil
            ),
        ]
        session.retention = MeetingRetentionState(
            audioDeletedAt: nil,
            meetingDeletedAt: nil,
            retainAudioUntil: self.startedAt.addingTimeInterval(7 * 24 * 60 * 60)
        )
        session.updatedAt = self.endedAt.addingTimeInterval(3)
        return session
    }

    static func speaker(
        id: SessionSpeakerID,
        name: String,
        trackKind: MeetingAudioTrackKind = .applicationAudio,
        isLocalUser: Bool = false,
        mergedIntoSpeakerID: SessionSpeakerID? = nil
    ) -> MeetingSessionSpeaker {
        MeetingSessionSpeaker(
            id: id,
            displayName: name,
            diarizationClusterID: nil,
            trackKind: trackKind,
            isLocalUser: isLocalUser,
            identityCandidates: [],
            mergedIntoSpeakerID: mergedIntoSpeakerID
        )
    }

    private static func chunk(
        id: MeetingAudioChunkID,
        sequence: Int,
        path: String,
        start: Int64,
        end: Int64,
        checksum: String
    ) -> MeetingAudioChunk {
        MeetingAudioChunk(
            id: id,
            sequence: sequence,
            relativeFilePath: path,
            presentationStart: self.mediaTime(start),
            presentationEnd: self.mediaTime(end),
            discontinuities: [],
            sha256: checksum,
            byteCount: 1024,
            finalizationState: .finalized
        )
    }

    static func mediaTime(_ seconds: Int64) -> MeetingMediaTime {
        MeetingMediaTime(value: seconds * 48_000, timescale: 48_000)
    }

    private static func uuid(_ finalByte: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, finalByte))
    }
}

@MainActor
final class MeetingSessionCoordinatorTests: XCTestCase {
    func testConcurrentStartCreatesExactlyOneSessionAndCapture() async throws {
        let harness = self.makeHarness(blockStart: true)
        let configuration = MeetingModelFixture.makeOnlineConfiguration()

        let firstStart = Task { @MainActor in
            try await harness.coordinator.startRecording(configuration: configuration)
        }
        await harness.capture.waitForStartCall()

        let duplicateStart = Task { @MainActor in
            try await harness.coordinator.startRecording(configuration: configuration)
        }
        var duplicateWasRejected = false
        do {
            _ = try await duplicateStart.value
            XCTFail("A concurrent Start must not create a second session.")
        } catch let error as MeetingCoordinatorError {
            if case .recordingAlreadyActive = error {
                duplicateWasRejected = true
            } else {
                XCTFail("Expected recordingAlreadyActive, got \(error).")
            }
        } catch {
            XCTFail("Unexpected duplicate Start error: \(error)")
        }

        await harness.capture.resumeStart()
        let session = try await firstStart.value
        let captureSnapshot = await harness.capture.snapshot()
        let storeSnapshot = await harness.store.snapshot()

        XCTAssertTrue(duplicateWasRejected)
        XCTAssertEqual(captureSnapshot.startCallCount, 1)
        XCTAssertEqual(storeSnapshot.createCallCount, 1)
        XCTAssertEqual(harness.arbiter.acquireCallCount, 1)
        XCTAssertEqual(harness.coordinator.state, .recording(session.id))
    }

    func testConcurrentStopJoinsOneFinalizationAndPersistsLegalStateOrder() async throws {
        let harness = self.makeHarness(blockStop: true)
        let configuration = MeetingModelFixture.makeOnlineConfiguration()
        let started = try await harness.coordinator.startRecording(configuration: configuration)

        let firstStop = Task { @MainActor in
            try await harness.coordinator.stopAndTranscribe()
        }
        await harness.capture.waitForStopCall()
        let duplicateStop = Task { @MainActor in
            try await harness.coordinator.stopAndTranscribe()
        }
        await Task.yield()
        await harness.capture.resumeStop()

        let firstResult = try await firstStop.value
        let duplicateResult = try await duplicateStop.value
        let captureSnapshot = await harness.capture.snapshot()
        let storeSnapshot = await harness.store.snapshot()

        XCTAssertEqual(firstResult.id, started.id)
        XCTAssertEqual(duplicateResult.id, firstResult.id)
        XCTAssertEqual(captureSnapshot.stopCallCount, 1)
        XCTAssertEqual(harness.processing.processCallCount, 1)
        XCTAssertEqual(harness.arbiter.releaseCallCount, 1)
        XCTAssertEqual(harness.coordinator.state, .completed(started.id))
        XCTAssertEqual(storeSnapshot.sessions[started.id]?.state, .completed)
        XCTAssertEqual(self.collapsingAdjacentDuplicates(storeSnapshot.persistedStates), [
            .preparing,
            .recording,
            .stopping,
            .processing,
            .completed,
        ])
    }

    func testStaleCaptureEventCannotMutateNewGeneration() async throws {
        let harness = self.makeHarness()
        let firstSession = try await harness.coordinator.startRecording(
            configuration: MeetingModelFixture.makeOnlineConfiguration()
        )
        _ = try await harness.coordinator.stopAndTranscribe()
        let completedBeforeEvent = try XCTUnwrap(harness.coordinator.latestCompletedSession)
        // Completion schedules a background retention sweep; wait for it to release the mutation
        // gate rather than racing it (it would otherwise throw .maintenanceInProgress here).
        for _ in 0..<40 {
            if harness.coordinator.isQuiescent { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let secondSession = try await harness.coordinator.startRecording(
            configuration: MeetingModelFixture.makeOnlineConfiguration()
        )

        await harness.capture.emit(.trackHealth(
            trackID: MeetingModelFixture.applicationTrackID,
            health: MeetingTrackHealth(
                status: .degraded,
                lastPresentationTime: MeetingModelFixture.mediaTime(999),
                lastSampleAt: Date(),
                level: 1,
                droppedSampleCount: 99,
                detail: "stale callback"
            )
        ), handlerIndex: 0)
        await Task.yield()
        await Task.yield()

        let storeSnapshot = await harness.store.snapshot()
        XCTAssertNotEqual(firstSession.id, secondSession.id)
        XCTAssertEqual(harness.coordinator.state, .recording(secondSession.id))
        XCTAssertEqual(harness.coordinator.activeSession?.id, secondSession.id)
        XCTAssertEqual(harness.coordinator.latestCompletedSession, completedBeforeEvent)
        XCTAssertEqual(harness.coordinator.trackHealth[.applicationAudio]?.status, .waiting)
        XCTAssertEqual(storeSnapshot.sessions[firstSession.id]?.state, .completed)
        XCTAssertEqual(storeSnapshot.sessions[secondSession.id]?.state, .recording)
    }

    func testStoppingContinuesWhenPreStopPersistenceFails() async throws {
        let harness = self.makeHarness(failingSaveState: .stopping)
        let started = try await harness.coordinator.startRecording(
            configuration: MeetingModelFixture.makeOnlineConfiguration()
        )

        let completed = try await harness.coordinator.stopAndTranscribe()
        let captureSnapshot = await harness.capture.snapshot()
        let storeSnapshot = await harness.store.snapshot()

        XCTAssertEqual(completed.id, started.id)
        XCTAssertEqual(captureSnapshot.stopCallCount, 1)
        XCTAssertEqual(harness.processing.processCallCount, 1)
        XCTAssertEqual(harness.coordinator.state, .completed(started.id))
        XCTAssertEqual(storeSnapshot.sessions[started.id]?.state, .completed)
        XCTAssertEqual(storeSnapshot.rejectedSaveStates, [.stopping])
    }

    func testPostStartPersistenceFailureStopsCaptureAndReleasesLease() async {
        let harness = self.makeHarness(failingSaveState: .recording)

        do {
            _ = try await harness.coordinator.startRecording(
                configuration: MeetingModelFixture.makeOnlineConfiguration()
            )
            XCTFail("Start must report the persistence failure.")
        } catch let error as MeetingCoordinatorTestError {
            XCTAssertEqual(error, .rejectedSave(.recording))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let captureSnapshot = await harness.capture.snapshot()
        let storeSnapshot = await harness.store.snapshot()
        XCTAssertEqual(captureSnapshot.startCallCount, 1)
        XCTAssertEqual(captureSnapshot.stopCallCount, 1)
        XCTAssertEqual(harness.processing.processCallCount, 0)
        XCTAssertEqual(harness.arbiter.releaseCallCount, 1)
        let recoveredSession = harness.coordinator.activeSession
        XCTAssertNotNil(recoveredSession)
        XCTAssertNotNil(recoveredSession?.endedAt)
        XCTAssertEqual(recoveredSession?.failures.last?.recoverable, true)
        XCTAssertEqual(recoveredSession.flatMap { storeSnapshot.sessions[$0.id] }?.state, .failed)
        XCTAssertEqual(storeSnapshot.rejectedSaveStates, [.recording])
        guard case .failed = harness.coordinator.state else {
            return XCTFail("Coordinator must expose the failed Start after cleanup.")
        }
    }

    func testRecoverableFailedSessionRestoresWithoutLosingFailureState() async throws {
        var failedSession = MeetingModelFixture.makeSession()
        failedSession.state = .failed
        failedSession.failures.append(MeetingSessionFailure(
            id: UUID(),
            occurredAt: Date(),
            domain: .processing,
            code: "fixture.processing",
            message: "Fixture processing failed",
            recoverable: true
        ))

        let store = FakeMeetingSessionStore(failingSaveState: nil)
        await store.seed(failedSession)
        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: FakeMeetingCaptureController(blockStart: false, blockStop: false, failStop: false),
            processing: FakeMeetingProcessingController(),
            audioArbiter: FakeMeetingAudioActivityArbiter()
        )

        await coordinator.ensureRestored()

        XCTAssertEqual(coordinator.activeSession?.id, failedSession.id)
        XCTAssertEqual(coordinator.activeSession?.state, .failed)
        guard case let .failed(id, failure) = coordinator.state else {
            return XCTFail("Recoverable failed session must reopen as failed.")
        }
        XCTAssertEqual(id, failedSession.id)
        XCTAssertEqual(failure.domain, .processing)
    }

    func testFailedStopPreservesRecoverableAudioAndReleasesLease() async throws {
        let harness = self.makeHarness(failStop: true)
        let started = try await harness.coordinator.startRecording(
            configuration: MeetingModelFixture.makeOnlineConfiguration()
        )

        do {
            _ = try await harness.coordinator.stopAndTranscribe()
            XCTFail("Stop must surface the capture failure.")
        } catch {
            XCTAssertTrue(error is MeetingCaptureError)
        }

        let captureSnapshot = await harness.capture.snapshot()
        let storeSnapshot = await harness.store.snapshot()
        XCTAssertEqual(captureSnapshot.stopCallCount, 1)
        XCTAssertEqual(harness.processing.processCallCount, 0)
        XCTAssertEqual(harness.arbiter.releaseCallCount, 1)
        XCTAssertEqual(harness.coordinator.state, .interrupted(started.id))
        XCTAssertEqual(harness.coordinator.activeSession?.id, started.id)
        XCTAssertNotNil(harness.coordinator.activeSession?.endedAt)
        XCTAssertEqual(storeSnapshot.sessions[started.id]?.state, .interrupted)
    }

    func testConcurrentTerminationFinalizesAndReleasesExactlyOnce() async throws {
        let harness = self.makeHarness(blockStop: true)
        let started = try await harness.coordinator.startRecording(
            configuration: MeetingModelFixture.makeOnlineConfiguration()
        )

        let first = Task { @MainActor in await harness.coordinator.shutdownForTermination() }
        await harness.capture.waitForStopCall()
        let second = Task { @MainActor in await harness.coordinator.shutdownForTermination() }
        await Task.yield()
        await harness.capture.resumeStop()
        await first.value
        await second.value

        let captureSnapshot = await harness.capture.snapshot()
        XCTAssertEqual(captureSnapshot.stopCallCount, 1)
        XCTAssertEqual(harness.arbiter.releaseCallCount, 1)
        XCTAssertEqual(harness.coordinator.state, .interrupted(started.id))
        XCTAssertEqual(
            harness.coordinator.activeSession?.events.filter { $0.kind == .appTermination }.count,
            1
        )
    }

    func testUnexpectedCaptureStopFinalizesAndReleasesLease() async throws {
        let harness = self.makeHarness()
        let started = try await harness.coordinator.startRecording(
            configuration: MeetingModelFixture.makeOnlineConfiguration()
        )

        await harness.capture.emit(.interrupted(
            kind: .captureStoppedUnexpectedly,
            trackID: nil,
            detail: "fixture stream ended"
        ))
        await harness.capture.waitForStopCall()
        // coordinator.state flips to .interrupted synchronously in handleCaptureEvent, well before
        // finishUnexpectedStop's async finalize/release runs — poll the actual release instead.
        for _ in 0..<40 {
            if harness.arbiter.releaseCallCount > 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(harness.coordinator.state, .interrupted(started.id))
        XCTAssertEqual(harness.arbiter.releaseCallCount, 1)
        XCTAssertEqual(harness.processing.processCallCount, 0)
    }

    private func makeHarness(
        blockStart: Bool = false,
        blockStop: Bool = false,
        failStop: Bool = false,
        failingSaveState: MeetingSessionState? = nil
    ) -> MeetingCoordinatorHarness {
        let store = FakeMeetingSessionStore(failingSaveState: failingSaveState)
        let capture = FakeMeetingCaptureController(
            blockStart: blockStart,
            blockStop: blockStop,
            failStop: failStop
        )
        let processing = FakeMeetingProcessingController()
        let arbiter = FakeMeetingAudioActivityArbiter()
        return MeetingCoordinatorHarness(
            coordinator: MeetingSessionCoordinator(
                store: store,
                capture: capture,
                processing: processing,
                audioArbiter: arbiter
            ),
            store: store,
            capture: capture,
            processing: processing,
            arbiter: arbiter
        )
    }

    private func collapsingAdjacentDuplicates(_ states: [MeetingSessionState]) -> [MeetingSessionState] {
        states.reduce(into: []) { result, state in
            if result.last != state {
                result.append(state)
            }
        }
    }
}

@MainActor
private struct MeetingCoordinatorHarness {
    let coordinator: MeetingSessionCoordinator
    let store: FakeMeetingSessionStore
    let capture: FakeMeetingCaptureController
    let processing: FakeMeetingProcessingController
    let arbiter: FakeMeetingAudioActivityArbiter
}

private enum MeetingCoordinatorTestError: Error, Equatable {
    case rejectedSave(MeetingSessionState)
}

private actor FakeMeetingSessionStore: MeetingSessionStoring {
    struct Snapshot: Sendable {
        var sessions: [MeetingSessionID: MeetingSession]
        var persistedStates: [MeetingSessionState]
        var rejectedSaveStates: [MeetingSessionState]
        var createCallCount: Int
    }

    private var sessions: [MeetingSessionID: MeetingSession] = [:]
    private var persistedStates: [MeetingSessionState] = []
    private var rejectedSaveStates: [MeetingSessionState] = []
    private var createCallCount = 0
    private var failingSaveState: MeetingSessionState?
    private var tombstonedIDs: Set<MeetingSessionID> = []

    init(failingSaveState: MeetingSessionState?) {
        self.failingSaveState = failingSaveState
    }

    func create(_ session: MeetingSession) throws {
        guard !self.tombstonedIDs.contains(session.id) else {
            throw MeetingSessionStoreError.sessionDeleted
        }
        try session.validateForPersistence()
        self.createCallCount += 1
        self.sessions[session.id] = session
        self.persistedStates.append(session.state)
    }

    func save(_ session: MeetingSession) throws {
        guard !self.tombstonedIDs.contains(session.id) else {
            throw MeetingSessionStoreError.sessionDeleted
        }
        try session.validateForPersistence()
        if self.failingSaveState == session.state {
            self.failingSaveState = nil
            self.rejectedSaveStates.append(session.state)
            throw MeetingCoordinatorTestError.rejectedSave(session.state)
        }
        self.sessions[session.id] = session
        self.persistedStates.append(session.state)
    }

    func delete(id: MeetingSessionID) throws {
        self.tombstonedIDs.insert(id)
        self.sessions.removeValue(forKey: id)
    }

    func deleteAudioFiles(for id: MeetingSessionID) throws {
        guard var session = self.sessions[id] else { return }
        for index in session.audioTracks.indices { session.audioTracks[index].chunks = [] }
        self.sessions[id] = session
    }

    func load(id: MeetingSessionID) -> MeetingSession? {
        self.sessions[id]
    }

    func loadAll() -> [MeetingSession] {
        Array(self.sessions.values)
    }

    func loadRecoverable() -> [MeetingSession] {
        self.sessions.values.filter {
            guard $0.recoveryResolvedAt == nil else { return false }
            switch $0.state {
            case .preparing, .recording, .recordingDegraded, .stopping, .processing, .interrupted:
                return true
            case .failed:
                return $0.failures.last?.recoverable == true &&
                    $0.endedAt != nil &&
                    $0.audioTracks.contains { track in
                        track.chunks.contains {
                            $0.finalizationState == .finalized && $0.byteCount > 0
                        }
                    }
            case .completed:
                return false
            }
        }
    }

    func seed(_ session: MeetingSession) {
        self.sessions[session.id] = session
    }

    func sessionDirectory(for id: MeetingSessionID) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("meeting-coordinator-tests", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func existingSessionDirectory(for id: MeetingSessionID) -> URL? {
        self.sessions[id] != nil ? self.sessionDirectory(for: id) : nil
    }

    func snapshot() -> Snapshot {
        Snapshot(
            sessions: self.sessions,
            persistedStates: self.persistedStates,
            rejectedSaveStates: self.rejectedSaveStates,
            createCallCount: self.createCallCount
        )
    }
}

private actor FakeMeetingCaptureController: MeetingCaptureControlling {
    struct Snapshot: Sendable {
        var startCallCount: Int
        var stopCallCount: Int
        var shutdownCallCount: Int
    }

    private let shouldBlockStart: Bool
    private let shouldBlockStop: Bool
    private let shouldFailStop: Bool
    private var startCallCount = 0
    private var stopCallCount = 0
    private var shutdownCallCount = 0
    private var eventHandlers: [@Sendable (MeetingCaptureEvent) -> Void] = []
    private var startObservers: [CheckedContinuation<Void, Never>] = []
    private var stopObservers: [CheckedContinuation<Void, Never>] = []
    private var blockedStarts: [CheckedContinuation<Void, Never>] = []
    private var blockedStops: [CheckedContinuation<Void, Never>] = []

    init(blockStart: Bool, blockStop: Bool, failStop: Bool) {
        self.shouldBlockStart = blockStart
        self.shouldBlockStop = blockStop
        self.shouldFailStop = failStop
    }

    func start(
        session _: MeetingSession,
        configuration _: MeetingCaptureConfiguration,
        sessionDirectory _: URL,
        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void
    ) async -> MeetingCaptureStartResult {
        self.startCallCount += 1
        self.eventHandlers.append(eventHandler)
        self.startObservers.forEach { $0.resume() }
        self.startObservers = []
        if self.shouldBlockStart {
            await withCheckedContinuation { self.blockedStarts.append($0) }
        }
        return MeetingCaptureStartResult(
            tracks: MeetingCoordinatorFixture.recordingTracks(),
            firstPresentationTime: nil
        )
    }

    func stop(sessionID _: MeetingSessionID) async throws -> MeetingCaptureStopResult {
        self.stopCallCount += 1
        self.stopObservers.forEach { $0.resume() }
        self.stopObservers = []
        if self.shouldBlockStop {
            await withCheckedContinuation { self.blockedStops.append($0) }
        }
        let result = MeetingCaptureStopResult(
            tracks: MeetingModelFixture.makeSession().audioTracks,
            stoppedAt: Date()
        )
        if self.shouldFailStop {
            throw MeetingCaptureError.captureStopFailed("fixture stop failed", partialResult: result)
        }
        return result
    }

    func shutdownForTermination() {
        self.shutdownCallCount += 1
    }

    func waitForStartCall() async {
        if self.startCallCount > 0 { return }
        await withCheckedContinuation { self.startObservers.append($0) }
    }

    func waitForStopCall() async {
        if self.stopCallCount > 0 { return }
        await withCheckedContinuation { self.stopObservers.append($0) }
    }

    func resumeStart() {
        self.blockedStarts.forEach { $0.resume() }
        self.blockedStarts = []
    }

    func resumeStop() {
        self.blockedStops.forEach { $0.resume() }
        self.blockedStops = []
    }

    func emit(_ event: MeetingCaptureEvent, handlerIndex: Int = 0) {
        guard self.eventHandlers.indices.contains(handlerIndex) else { return }
        self.eventHandlers[handlerIndex](event)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            startCallCount: self.startCallCount,
            stopCallCount: self.stopCallCount,
            shutdownCallCount: self.shutdownCallCount
        )
    }
}

@MainActor
private final class FakeMeetingProcessingController: MeetingProcessingControlling {
    private(set) var processCallCount = 0

    func process(
        session _: MeetingSession,
        sessionDirectory _: URL,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void
    ) async throws -> MeetingProcessingResult {
        self.processCallCount += 1
        progress(.saving)
        progress(.identifyingSpeakers)
        progress(.transcribing)
        progress(.finalizing)
        progress(.completed)

        let fixture = MeetingModelFixture.makeSession()
        return MeetingProcessingResult(
            speakers: fixture.speakers,
            segments: fixture.transcriptSegments,
            attempt: MeetingProcessingAttempt(
                id: UUID(),
                startedAt: Date(),
                completedAt: Date(),
                stage: .completed,
                pipelineVersion: 1,
                asrProvider: "test-asr",
                asrModel: "test-model",
                diarizationModel: "test-diarization",
                lastCompletedTrackID: MeetingModelFixture.microphoneTrackID,
                errorCode: nil
            )
        )
    }
}

@MainActor
private final class FakeMeetingAudioActivityArbiter: MeetingAudioActivityArbitrating {
    private(set) var acquireCallCount = 0
    private(set) var releaseCallCount = 0
    private var activeLease: MeetingAudioActivityLease?

    func acquireMeetingCapture() throws -> MeetingAudioActivityLease {
        self.acquireCallCount += 1
        let lease = MeetingAudioActivityLease(id: UUID())
        self.activeLease = lease
        return lease
    }

    func release(_ lease: MeetingAudioActivityLease) {
        guard self.activeLease == lease else { return }
        self.activeLease = nil
        self.releaseCallCount += 1
    }
}

private enum MeetingCoordinatorFixture {
    static func recordingTracks() -> [MeetingAudioTrack] {
        MeetingModelFixture.makeSession().audioTracks.map { track in
            var track = track
            track.format = nil
            track.health = .waiting
            track.chunks = []
            return track
        }
    }
}
