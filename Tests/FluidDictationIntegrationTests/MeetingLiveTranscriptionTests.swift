import AVFoundation
import CoreMedia
@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class MeetingModelPreparationQueueTests: XCTestCase {
    private actor Counter {
        var active = 0
        var maximum = 0
        var completed = 0
        func enter() { self.active += 1; self.maximum = max(self.maximum, self.active) }
        func leave() { self.active -= 1; self.completed += 1 }
    }

    func testConcurrentPreparationsNeverOverlap() async throws {
        let queue = MeetingModelPreparationQueue()
        let counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await queue.run {
                        await counter.enter()
                        try await Task.sleep(nanoseconds: 1_000_000)
                        await counter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let maximum = await counter.maximum
        let completed = await counter.completed
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(completed, 20)
    }

    func testFailureAndCancellationDoNotPoisonNextPreparation() async throws {
        let queue = MeetingModelPreparationQueue()
        let counter = Counter()
        do {
            try await queue.run { throw CancellationError() }
            XCTFail("Expected failure")
        } catch is CancellationError {}
        let cancelled = Task {
            try await Task.sleep(nanoseconds: 10_000_000)
            try await queue.run { await counter.enter() }
        }
        cancelled.cancel()
        _ = await cancelled.result
        try await queue.run { await counter.enter(); await counter.leave() }
        let completed = await counter.completed
        let active = await counter.active
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(active, 0)
    }
}

final class MeetingLiveTimeConversionTests: XCTestCase {
    func testZeroOriginPassesPTSThrough() {
        let pts = CMTime(value: 5, timescale: 1)
        let origin = CMTime(value: 0, timescale: 1)
        XCTAssertEqual(MeetingLiveTimeConversion.sessionSeconds(pts: pts, origin: origin), 5, accuracy: 0.001)
    }

    func testNonZeroOriginSubtracts() {
        let pts = CMTime(value: 7, timescale: 1)
        let origin = CMTime(value: 2, timescale: 1)
        XCTAssertEqual(MeetingLiveTimeConversion.sessionSeconds(pts: pts, origin: origin), 5, accuracy: 0.001)
    }

    func testPTSBeforeOriginClampsToZero() {
        let pts = CMTime(value: 1, timescale: 1)
        let origin = CMTime(value: 4, timescale: 1)
        XCTAssertEqual(MeetingLiveTimeConversion.sessionSeconds(pts: pts, origin: origin), 0, accuracy: 0.001)
    }

    func testInvalidTimesReturnZero() {
        XCTAssertEqual(MeetingLiveTimeConversion.sessionSeconds(pts: .invalid, origin: .zero), 0)
    }

    func testOriginBoxKeepsTheEarliestPTS() {
        let box = MeetingLiveOriginBox()
        XCTAssertEqual(box.establish(CMTime(value: 5, timescale: 1)), CMTime(value: 5, timescale: 1))
        // A later-arriving but earlier PTS (out-of-order tee delivery) still wins.
        XCTAssertEqual(box.establish(CMTime(value: 2, timescale: 1)), CMTime(value: 2, timescale: 1))
        XCTAssertEqual(box.establish(CMTime(value: 9, timescale: 1)), CMTime(value: 2, timescale: 1))
    }
}

final class MeetingLiveTranscriptSnapshotTests: XCTestCase {
    func testDeliveryRejectsStoppedPreviousAndDuplicateSessionUpdates() {
        let generation = UUID()
        var current = MeetingLiveTranscriptSnapshot.empty
        current.revision = 2
        var latest = current
        latest.revision = 3
        latest.availability = .available
        XCTAssertTrue(current.accepts(latest, generation: generation, activeGeneration: generation))
        XCTAssertFalse(current.accepts(current, generation: generation, activeGeneration: generation))
        XCTAssertFalse(current.accepts(.empty, generation: generation, activeGeneration: generation))
        XCTAssertFalse(current.accepts(latest, generation: generation, activeGeneration: nil))
        XCTAssertFalse(MeetingLiveTranscriptSnapshot.empty.accepts(latest, generation: generation, activeGeneration: UUID()))
        XCTAssertEqual(current.revision, 2, "Rejected deliveries do not mutate existing captions")
        XCTAssertNotEqual(current.availability, .available)
    }

    private func utterance(_ speaker: MeetingLiveSpeaker, _ text: String, start: TimeInterval, end: TimeInterval) -> MeetingLiveUtterance {
        MeetingLiveUtterance(id: UUID(), speaker: speaker, text: text, start: start, end: end)
    }

    func testInsertingKeepsUtterancesSortedByStart() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.inserting(self.utterance(.you, "second", start: 5, end: 6))
        snapshot = snapshot.inserting(self.utterance(.them, "first", start: 1, end: 2))
        snapshot = snapshot.inserting(self.utterance(.you, "third", start: 8, end: 9))
        XCTAssertEqual(snapshot.utterances.map(\.text), ["first", "second", "third"])
    }

    /// A later-arriving finalize whose audio started earlier must still sort before an
    /// already-published utterance with a later start — engines finalize independently.
    func testLaterArrivingEarlierStartSortsFirst() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.inserting(self.utterance(.them, "arrived first, starts late", start: 10, end: 12))
        snapshot = snapshot.inserting(self.utterance(.you, "arrived second, starts early", start: 3, end: 4))
        XCTAssertEqual(snapshot.utterances.first?.text, "arrived second, starts early")
    }

    private func partial(_ text: String, id: UUID = UUID(), start: TimeInterval = 0) -> MeetingLivePartial {
        MeetingLivePartial(id: id, text: text, start: start)
    }

    func testGrowingPartialsReplaceRatherThanConcatenate() {
        let id = UUID()
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.settingPartial(self.partial("hel", id: id), for: .you)
        snapshot = snapshot.settingPartial(self.partial("hello", id: id), for: .you)
        snapshot = snapshot.settingPartial(self.partial("hello there", id: id), for: .you)
        XCTAssertEqual(snapshot.partials[.you]?.text, "hello there")
    }

    func testEmptyPartialClearsTheSlot() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.settingPartial(self.partial("hello"), for: .them)
        snapshot = snapshot.settingPartial(nil, for: .them)
        XCTAssertNil(snapshot.partials[.them])
    }

    func testPartialsForEachSpeakerAreIndependent() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.settingPartial(self.partial("you partial"), for: .you)
        snapshot = snapshot.settingPartial(self.partial("them partial"), for: .them)
        XCTAssertEqual(snapshot.partials[.you]?.text, "you partial")
        XCTAssertEqual(snapshot.partials[.them]?.text, "them partial")
    }

    func testStalePartialAfterFinalizeIsDropped() {
        let id = UUID()
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.inserting(self.utterance(.you, "final text", start: 0, end: 1))
        snapshot = snapshot.markingFinalized(id)
        snapshot = snapshot.settingPartial(self.partial("resurrected", id: id), for: .you)
        XCTAssertNil(snapshot.partials[.you])
    }

    func testEchoSuppressionFinalizesTurnWithoutUtterance() {
        let id = UUID()
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.settingPartial(self.partial("in flight", id: id), for: .you)
        snapshot = snapshot.settingPartial(nil, for: .you).markingFinalized(id)
        XCTAssertNil(snapshot.partials[.you])
        XCTAssertTrue(snapshot.utterances.isEmpty)

        let late = snapshot.settingPartial(self.partial("late arrival", id: id), for: .you)
        XCTAssertNil(late.partials[.you], "a partial for an echo-suppressed turn must not resurrect")
    }

    func testFinalizedTurnIDCapEvictsOldestWithoutBreakingRecentDedup() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        var ids: [UUID] = []
        for index in 0..<100 {
            let id = UUID()
            ids.append(id)
            snapshot = snapshot.inserting(self.utterance(.you, "turn \(index)", start: TimeInterval(index), end: TimeInterval(index) + 1))
            snapshot = snapshot.markingFinalized(id)
        }
        let oldest = ids[0]
        let recent = ids[ids.count - 1]
        XCTAssertFalse(snapshot.finalizedTurnIDs.contains(oldest), "cap must evict the oldest id")
        let staleOldPartial = snapshot.settingPartial(self.partial("should not be dropped by cap logic", id: oldest), for: .you)
        XCTAssertNotNil(staleOldPartial.partials[.you], "an evicted id is no longer recognized as stale")

        let staleRecentPartial = snapshot.settingPartial(self.partial("still dropped", id: recent), for: .you)
        XCTAssertNil(staleRecentPartial.partials[.you], "a recently finalized id must still be recognized as stale")
    }
}

final class MeetingLiveBubbleComposerTests: XCTestCase {
    private func utterance(_ speaker: MeetingLiveSpeaker, _ text: String, start: TimeInterval, end: TimeInterval, id: UUID = UUID()) -> MeetingLiveUtterance {
        MeetingLiveUtterance(id: id, speaker: speaker, text: text, start: start, end: end)
    }

    func testFinalizedThenBottomPinnedPartialsOrderedByStart() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.inserting(self.utterance(.you, "hello", start: 0, end: 1))
        snapshot = snapshot.settingPartial(MeetingLivePartial(id: UUID(), text: "them partial", start: 5), for: .them)
        snapshot = snapshot.settingPartial(MeetingLivePartial(id: UUID(), text: "you partial", start: 3), for: .you)

        let rows = MeetingLiveBubbleComposer.rows(for: snapshot)
        XCTAssertEqual(rows.map(\.text), ["hello", "you partial", "them partial"])
        XCTAssertEqual(rows.map(\.isPartial), [false, true, true])
        XCTAssertEqual(rows.map(\.showsLabel), [true, false, true])
    }

    func testShowsLabelIsFalseWhenSpeakerRepeatsAcrossPartial() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.inserting(self.utterance(.you, "first", start: 0, end: 1))
        snapshot = snapshot.settingPartial(MeetingLivePartial(id: UUID(), text: "still talking", start: 2), for: .you)

        let rows = MeetingLiveBubbleComposer.rows(for: snapshot)
        XCTAssertEqual(rows.map(\.showsLabel), [true, false])
    }

    func testSolidifyKeepsRowIdentityStable() {
        let turnID = UUID()
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.settingPartial(MeetingLivePartial(id: turnID, text: "in flight text", start: 0), for: .you)
        let partialRows = MeetingLiveBubbleComposer.rows(for: snapshot)
        XCTAssertEqual(partialRows.first?.id, turnID)
        XCTAssertEqual(partialRows.first?.isPartial, true)

        snapshot = snapshot.inserting(self.utterance(.you, "in flight text finalized", start: 0, end: 2, id: turnID))
            .settingPartial(nil, for: .you)
        let finalRows = MeetingLiveBubbleComposer.rows(for: snapshot)
        XCTAssertEqual(finalRows.first?.id, turnID)
        XCTAssertEqual(finalRows.first?.isPartial, false)
    }
}

final class MeetingLiveBoundedQueueTests: XCTestCase {
    func testEnqueueUnderCapacityNeverDrops() {
        let queue = MeetingLiveBoundedQueue<Int>(capacity: 4)
        for value in 0..<4 {
            XCTAssertFalse(queue.enqueue(value))
        }
        XCTAssertEqual(queue.drainAll(), [0, 1, 2, 3])
    }

    func testSaturationDropsTheOldestElement() {
        let queue = MeetingLiveBoundedQueue<Int>(capacity: 3)
        for value in 0..<3 {
            _ = queue.enqueue(value)
        }
        let dropped = queue.enqueue(3)
        XCTAssertTrue(dropped)
        // 0 was the oldest; it must be gone, newest (3) must be present.
        XCTAssertEqual(queue.drainAll(), [1, 2, 3])
    }

    func testDrainClearsTheQueue() {
        let queue = MeetingLiveBoundedQueue<Int>(capacity: 4)
        _ = queue.enqueue(1)
        _ = queue.drainAll()
        XCTAssertEqual(queue.drainAll(), [])
    }

    func testHeavySaturationNeverGrowsPastCapacity() {
        let queue = MeetingLiveBoundedQueue<Int>(capacity: 4)
        for value in 0..<1000 {
            _ = queue.enqueue(value)
        }
        let drained = queue.drainAll()
        XCTAssertEqual(drained.count, 4)
        XCTAssertEqual(drained, [996, 997, 998, 999])
    }
}

final class MeetingLiveEchoFilterTests: XCTestCase {
    func testMicUtteranceMatchingRecentThemTextIsSuppressed() {
        let them = [
            MeetingLiveUtterance(
                id: UUID(),
                speaker: .them,
                text: "let's push the release to next Tuesday afternoon",
                start: 10,
                end: 14
            ),
        ]
        let recent = MeetingLiveEchoFilter.recentThemText(from: them, before: 15, windowSeconds: 20)
        let shouldSuppress = MeetingLiveEchoFilter.shouldSuppress(
            micText: "let's push the release to next Tuesday afternoon",
            recentThemText: recent
        )
        XCTAssertTrue(shouldSuppress)
    }

    func testGenuineLocalUtteranceIsNotSuppressed() {
        let them = [
            MeetingLiveUtterance(id: UUID(), speaker: .them, text: "let's push the release to next Tuesday", start: 10, end: 14),
        ]
        let recent = MeetingLiveEchoFilter.recentThemText(from: them, before: 15, windowSeconds: 20)
        let shouldSuppress = MeetingLiveEchoFilter.shouldSuppress(
            micText: "I think we should grab lunch after this call",
            recentThemText: recent
        )
        XCTAssertFalse(shouldSuppress)
    }

    func testThemTextOutsideTheWindowIsExcluded() {
        let them = [
            MeetingLiveUtterance(id: UUID(), speaker: .them, text: "let's push the release to next Tuesday afternoon", start: 0, end: 2),
        ]
        let recent = MeetingLiveEchoFilter.recentThemText(from: them, before: 100, windowSeconds: 20)
        XCTAssertTrue(recent.isEmpty)
        XCTAssertFalse(MeetingLiveEchoFilter.shouldSuppress(micText: "let's push the release to next Tuesday afternoon", recentThemText: recent))
    }
}

final class MeetingLiveMemoryGateTests: XCTestCase {
    func testBelowThresholdDisablesLive() {
        let oneGigabyte: UInt64 = 1 * 1024 * 1024 * 1024
        XCTAssertFalse(MeetingLiveTranscriptionCoordinator.isMemorySufficient(physicalMemory: oneGigabyte))
    }

    func testAtOrAboveThresholdAllowsLive() {
        XCTAssertTrue(MeetingLiveTranscriptionCoordinator.isMemorySufficient(
            physicalMemory: MeetingLiveTranscriptionCoordinator.minimumPhysicalMemoryBytes
        ))
        XCTAssertTrue(MeetingLiveTranscriptionCoordinator.isMemorySufficient(physicalMemory: 64 * 1024 * 1024 * 1024))
    }
}

final class MeetingLiveProvisionalContainmentTests: XCTestCase {
    /// Provisional live text must never reach the exporter: it only ever reads `MeetingSession`,
    /// and live utterances are never written into `session.transcriptSegments`.
    func testExportedTranscriptNeverContainsLiveOnlyText() {
        let microphone = MeetingMicrophoneIdentity(captureDeviceID: "mic-1", coreAudioUID: nil, displayName: "Test Mic")
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Standup", microphone: microphone)
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
        var session = MeetingSession(configuration: configuration, timebase: timebase)

        let speakerID = UUID()
        session.speakers = [
            MeetingSessionSpeaker(
                id: speakerID,
                displayName: "Speaker 1",
                diarizationClusterID: nil,
                trackKind: .microphone,
                isLocalUser: true,
                identityCandidates: []
            ),
        ]
        session.transcriptSegments = [
            MeetingTranscriptSegment(
                id: UUID(),
                start: MeetingMediaTime(value: 0, timescale: 1),
                end: MeetingMediaTime(value: 1, timescale: 1),
                sourceTrackID: UUID(),
                speakerID: speakerID,
                text: "FINAL_TRANSCRIPT_TEXT",
                revision: 0,
                status: .final,
                overlap: .none,
                completeness: .complete
            ),
        ]

        // A live snapshot exists in memory alongside the session, as it would during recording,
        // but nothing ever threads it into the exporter or the session's segments.
        let liveSnapshot = MeetingLiveTranscriptSnapshot.empty
            .inserting(MeetingLiveUtterance(id: UUID(), speaker: .you, text: "PROVISIONAL_LIVE_ONLY_TEXT", start: 0, end: 1))
            .settingPartial(MeetingLivePartial(id: UUID(), text: "PROVISIONAL_PARTIAL_ONLY_TEXT", start: 0), for: .them)

        let exported = MeetingTranscriptExporter.text(for: session, includeEchoes: true)
        XCTAssertTrue(exported.contains("FINAL_TRANSCRIPT_TEXT"))
        XCTAssertFalse(exported.contains("PROVISIONAL_LIVE_ONLY_TEXT"))
        XCTAssertFalse(exported.contains("PROVISIONAL_PARTIAL_ONLY_TEXT"))
        XCTAssertFalse(session.transcriptSegments.contains { $0.text.contains("PROVISIONAL") })
        XCTAssertFalse(liveSnapshot.utterances.isEmpty, "sanity: the live snapshot really did hold provisional content")
    }
}

@MainActor
final class MeetingOverlayVisibilityTests: XCTestCase {
    func testVisibleOnlyForRecordingAndRecordingDegraded() {
        let id = MeetingSessionID()
        XCTAssertFalse(MeetingOverlayVisibility.isVisible(for: .idle))
        XCTAssertFalse(MeetingOverlayVisibility.isVisible(for: .preparing(id)))
        XCTAssertTrue(MeetingOverlayVisibility.isVisible(for: .recording(id)))
        XCTAssertTrue(MeetingOverlayVisibility.isVisible(for: .recordingDegraded(id)))
        XCTAssertFalse(MeetingOverlayVisibility.isVisible(for: .stopping(id)))
        XCTAssertFalse(MeetingOverlayVisibility.isVisible(for: .processing(id, .saving)))
        XCTAssertFalse(MeetingOverlayVisibility.isVisible(for: .completed(id)))
        XCTAssertFalse(MeetingOverlayVisibility.isVisible(for: .interrupted(id)))
        XCTAssertFalse(MeetingOverlayVisibility.isVisible(for: .failed(id, MeetingSessionFailure(
            id: UUID(), occurredAt: Date(), domain: .capture, code: "test", message: "test failure", recoverable: true
        ))))
    }
}

#if arch(arm64)
@MainActor
final class MeetingLiveStartupCancellationTests: XCTestCase {
    private actor SuspendedRecognizer: MeetingLiveRecognizer {
        let didBeginInstalling: @Sendable () -> Void
        let didPrepare: @Sendable () -> Void
        private var continuation: CheckedContinuation<Void, Never>?
        private var eouCallback: (@Sendable (String) -> Void)?
        private var partialCallback: (@Sendable (String) -> Void)?
        private(set) var installationCount = 0

        init(didBeginInstalling: @escaping @Sendable () -> Void, didPrepare: @escaping @Sendable () -> Void) {
            self.didBeginInstalling = didBeginInstalling
            self.didPrepare = didPrepare
        }

        func setEouCallback(_ callback: @escaping @Sendable (String) -> Void) async {
            self.eouCallback = callback
            self.installationCount += 1
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.didBeginInstalling()
            }
        }

        func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) async {
            self.partialCallback = callback
        }

        func resumeInstallation() {
            self.continuation?.resume()
            self.continuation = nil
        }

        func emitStaleCallbacks() {
            self.partialCallback?("late partial")
            self.eouCallback?("late final")
        }

        func prepareModels() async throws { self.didPrepare() }
        func appendAudio(_ buffer: AVAudioPCMBuffer) async throws {}
        func processBufferedAudio() async throws {}
        func reset() async {}
    }

    func testStopDuringCallbackInstallationCannotLaunchModelsOrPublish() async {
        let installing = expectation(description: "callback installation suspended")
        let noPrepare = expectation(description: "stopped engine must not load models")
        noPrepare.isInverted = true
        let noPublish = expectation(description: "stopped engine must not publish")
        noPublish.isInverted = true
        let recognizer = SuspendedRecognizer(
            didBeginInstalling: { installing.fulfill() },
            didPrepare: { noPrepare.fulfill() }
        )
        let engine = MeetingLiveTrackEngine(kind: .microphone, recognizer: recognizer)
        await engine.configure(
            onPartial: { _, _, _, _, _ in noPublish.fulfill() },
            onUtterance: { _, _, _, _, _ in noPublish.fulfill() },
            onDegraded: { _, _ in noPublish.fulfill() },
            onReady: { _ in noPublish.fulfill() }
        )
        let starting = Task { await engine.start() }
        await fulfillment(of: [installing], timeout: 2)
        await engine.stop()
        await recognizer.resumeInstallation()
        await starting.value
        await recognizer.emitStaleCallbacks()
        await engine.start() // A delayed coordinator launch cannot restart a stopped engine either.
        await fulfillment(of: [noPrepare, noPublish], timeout: 0.1)
        let installationCount = await recognizer.installationCount
        XCTAssertEqual(installationCount, 1)
        await engine.stop()
    }

    func testUninterruptedStartupStillLoadsAndBecomesReady() async {
        let installing = expectation(description: "installing callbacks")
        let prepared = expectation(description: "models prepared")
        let ready = expectation(description: "captions ready")
        let recognizer = SuspendedRecognizer(
            didBeginInstalling: { installing.fulfill() },
            didPrepare: { prepared.fulfill() }
        )
        let engine = MeetingLiveTrackEngine(kind: .microphone, recognizer: recognizer)
        await engine.configure(
            onPartial: { _, _, _, _, _ in },
            onUtterance: { _, _, _, _, _ in },
            onDegraded: { _, _ in XCTFail("Unexpected degradation") },
            onReady: { _ in ready.fulfill() }
        )
        let starting = Task { await engine.start() }
        await fulfillment(of: [installing], timeout: 2)
        await recognizer.resumeInstallation()
        await starting.value
        await fulfillment(of: [prepared, ready], timeout: 2)
        await engine.stop()
    }

    func testStopBeforeLaunchPreventsCallbackInstallation() async {
        let noInstall = expectation(description: "stopped engine must not install callbacks")
        noInstall.isInverted = true
        let recognizer = SuspendedRecognizer(didBeginInstalling: { noInstall.fulfill() }, didPrepare: {})
        let engine = MeetingLiveTrackEngine(kind: .microphone, recognizer: recognizer)
        await engine.stop()
        let starting = Task { await engine.start() }
        await fulfillment(of: [noInstall], timeout: 0.1)
        // Unblock a regression so a failed assertion cannot leak a suspended task.
        await recognizer.resumeInstallation()
        await starting.value
        await engine.stop()
    }
}
#endif
