@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
private final class ResidencyTrace {
    var events: [String] = []
    func participant(_ owner: String, loaded: Bool) -> MeetingModelParticipant {
        MeetingModelParticipant(
            owner: owner,
            snapshot: {
                self.events.append("snapshot:\(owner)")
                return loaded ? .init(id: owner, configuration: "original") : nil
            },
            suspend: { self.events.append("unload:\(owner)") },
            restore: { model in self.events.append("restore:\(model.id)") },
            finish: { self.events.append("finish:\(owner)") }
        )
    }
}

@MainActor
private final class ResidencyLatch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if self.open { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    func release() {
        self.open = true
        let pending = self.waiters
        self.waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

@MainActor
final class MeetingModelResidencyTests: XCTestCase {
    func testOnlyOriginallyLoadedModelsRestoreAndAdmissionRemainsClosed() async throws {
        let owner = MeetingModelResidencyCoordinator()
        let trace = ResidencyTrace()
        let value = try await owner.withExclusive(attemptID: UUID(), participants: [
            trace.participant("speech", loaded: true), trace.participant("fluid", loaded: false),
        ]) {
            XCTAssertEqual(owner.phase, .transcription)
            XCTAssertThrowsError(try owner.beginOperation(owner: "fluid", modelID: "selected-only"))
            trace.events.append("meeting")
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(trace.events, [
            "snapshot:speech",
            "snapshot:fluid",
            "unload:speech",
            "unload:fluid",
            "meeting",
            "restore:speech",
            "finish:speech",
            "finish:fluid",
        ])
        XCTAssertEqual(owner.phase, .normal)
        let next = try owner.beginOperation(owner: "fluid", modelID: "user-started")
        owner.endOperation(next)
    }

    func testBusyOrdinaryOperationPreventsAnyUnloading() async throws {
        let owner = MeetingModelResidencyCoordinator()
        let trace = ResidencyTrace()
        let operation = try owner.beginOperation(owner: "fluid", modelID: "running")
        do {
            try await owner.withExclusive(attemptID: UUID(), participants: [trace.participant("speech", loaded: true)]) {
                XCTFail("Meeting must not start during existing work")
            }
            XCTFail("Expected busy")
        } catch { XCTAssertTrue(error is MeetingModelResidencyError) }
        XCTAssertTrue(trace.events.isEmpty)
        owner.endOperation(operation)
    }

    func testVetoCannotAddSelectedButUnloadedModels() async throws {
        let owner = MeetingModelResidencyCoordinator()
        let trace = ResidencyTrace()
        try await owner.withExclusive(attemptID: UUID(), participants: [
            trace.participant("speech", loaded: true), trace.participant("fluid", loaded: false),
        ]) {
            owner.vetoRestoration(owner: "speech")
            owner.vetoRestoration(owner: "new-selection")
        }
        XCTAssertFalse(trace.events.contains(where: { $0.hasPrefix("restore:") }))
        XCTAssertEqual(owner.phase, .normal)
    }

    func testCancelledInferenceDrainsBeforeOneUncancelledRestoration() async throws {
        let owner = MeetingModelResidencyCoordinator()
        let entered = ResidencyLatch()
        let returnFromModel = ResidencyLatch()
        let trace = ResidencyTrace()
        let task = Task {
            try await owner.withExclusive(attemptID: UUID(), participants: [trace.participant("speech", loaded: true)]) {
                entered.release()
                await returnFromModel.wait() // Deliberately non-cooperative model call.
                trace.events.append("model-returned")
            }
        }
        await entered.wait()
        task.cancel()
        XCTAssertTrue(owner.isExclusive)
        XCTAssertFalse(trace.events.contains("restore:speech"))
        returnFromModel.release()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(trace.events.filter { $0 == "restore:speech" }.count, 1)
        XCTAssertLessThan(
            try XCTUnwrap(trace.events.firstIndex(of: "model-returned")),
            try XCTUnwrap(trace.events.firstIndex(of: "restore:speech"))
        )
        XCTAssertFalse(owner.isExclusive)
    }

    func testFailureDuringRestoreDoesNotEraseSuccessOrLeaveGateBusy() async throws {
        let owner = MeetingModelResidencyCoordinator()
        var participant = ResidencyTrace().participant("speech", loaded: true)
        participant = MeetingModelParticipant(
            owner: participant.owner,
            snapshot: participant.snapshot,
            suspend: participant.suspend,
            restore: { _ in throw CocoaError(.fileNoSuchFile) }
        )
        let value = try await owner.withExclusive(attemptID: UUID(), participants: [participant]) { "saved transcript" }
        XCTAssertEqual(value, "saved transcript")
        XCTAssertEqual(owner.restorationErrors.count, 1)
        XCTAssertFalse(owner.isExclusive)
    }

    func testRestorationGrantIsOwnerAndModelSpecificAndExpires() async throws {
        let owner = MeetingModelResidencyCoordinator()
        let attempt = UUID()
        let participant = MeetingModelParticipant(
            owner: "speech",
            snapshot: { .init(id: "v3", configuration: "original") },
            suspend: {},
            restore: { _ in
                XCTAssertThrowsError(try owner.beginOperation(owner: "fluid", modelID: "v3"))
                XCTAssertThrowsError(try owner.beginOperation(owner: "speech", modelID: "v2"))
                let token = try owner.beginOperation(owner: "speech", modelID: "v3")
                owner.endOperation(token)
            }
        )
        try await owner.withExclusive(attemptID: attempt, participants: [participant]) {}
        try MeetingModelContext.$grant.withValue(.init(attempt: attempt, generation: UUID(), owner: "speech", modelID: "v3")) {
            XCTAssertThrowsError(try owner.beginOperation(owner: "speech", modelID: "v3"))
        }
        XCTAssertTrue(owner.restorationErrors.isEmpty)
    }

    func testSecondAttemptCannotStartWhileRestoringAndLateVetoUnloadsAgain() async throws {
        let owner = MeetingModelResidencyCoordinator()
        let entered = ResidencyLatch()
        let finish = ResidencyLatch()
        let trace = ResidencyTrace()
        let participant = MeetingModelParticipant(
            owner: "speech",
            snapshot: { .init(id: "v3", configuration: "original") },
            suspend: { trace.events.append("unload") },
            restore: { _ in entered.release(); await finish.wait() }
        )
        let task = Task { try await owner.withExclusive(attemptID: UUID(), participants: [participant]) {} }
        await entered.wait()
        do { try await owner.withExclusive(attemptID: UUID(), participants: []) {}; XCTFail("Expected busy") } catch {}
        owner.vetoRestoration(owner: "speech")
        finish.release()
        try await task.value
        XCTAssertEqual(trace.events, ["unload", "unload"])
        XCTAssertFalse(owner.isExclusive)
    }

    func testTerminationNeverRestoresAndAdmissionStaysClosed() async throws {
        let owner = MeetingModelResidencyCoordinator()
        let trace = ResidencyTrace()
        try await owner.withExclusive(attemptID: UUID(), participants: [trace.participant("speech", loaded: true)]) {
            owner.beginTermination()
        }
        XCTAssertFalse(trace.events.contains("restore:speech"))
        XCTAssertEqual(owner.phase, .terminating)
        XCTAssertThrowsError(try owner.beginOperation(owner: "speech", modelID: "v3"))
    }

    func testSuspensionFailureRestoresWithoutStartingMeeting() async throws {
        let owner = MeetingModelResidencyCoordinator()
        let trace = ResidencyTrace()
        let failure = MeetingModelParticipant(
            owner: "fluid",
            snapshot: { nil },
            suspend: { throw CocoaError(.fileReadUnknown) },
            restore: { _ in XCTFail("Failed participant must not be restored") }
        )
        do {
            try await owner.withExclusive(attemptID: UUID(), participants: [trace.participant("speech", loaded: true), failure]) { XCTFail("Exclusive work must not run after preparation fails") }
            XCTFail("Expected suspension failure")
        } catch {}
        XCTAssertTrue(trace.events.contains("restore:speech"))
        XCTAssertFalse(owner.isExclusive)
    }
}

private actor SummaryProbe: MeetingPostProcessingProviding, PreparedMeetingPostProcessor {
    nonisolated let providerID = "fixture"
    nonisolated let modelID = "summary-model"
    nonisolated let maximumInputCharacters = 1000
    let failPreparation: Bool
    let failure: String
    private(set) var unloaded = 0
    init(failPreparation: Bool = false, failure: String = "") { self.failPreparation = failPreparation; self.failure = failure }
    func isReady() async throws -> Bool { true }
    func prepare() async throws -> any PreparedMeetingPostProcessor {
        if self.failPreparation { throw CocoaError(.fileReadUnknown) }
        return self
    }

    func generate(_ request: MeetingPostProcessingRequest) async throws -> MeetingPostProcessingOutput {
        if self.failure == "generation" { throw CocoaError(.fileReadUnknown) }
        if self.failure == "cancel" { withUnsafeCurrentTask { $0?.cancel() } }
        return .init(summary: "Summary fixture", sourceSegmentIDs: self.failure == "citations" ? [UUID()] : request.segments.map(\.id))
    }

    func cancelAndUnload() async { self.unloaded += 1 }
}

extension MeetingModelResidencyTests {
    func testSummaryPluginAlwaysUnloadsBeforeRestoringAndFailureKeepsTranscript() async throws {
        for failure in ["", "prepare", "generation", "citations", "cancel"] {
            let fails = !failure.isEmpty
            let owner = MeetingModelResidencyCoordinator()
            let registry = MeetingPostProcessingRegistry(residency: owner)
            let provider = SummaryProbe(failPreparation: failure == "prepare", failure: failure)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let participant = MeetingModelParticipant(
                owner: "speech",
                snapshot: { .init(id: "speech", configuration: "original") },
                suspend: {},
                restore: { _ in
                    let unloaded = await provider.unloaded
                    XCTAssertGreaterThan(unloaded, 0)
                }
            )
            let result = MeetingProcessingResult(speakers: [], segments: [], attempt: .init(
                id: UUID(),
                startedAt: Date(),
                completedAt: Date(),
                stage: .completed,
                pipelineVersion: 13,
                asrProvider: nil,
                asrModel: nil,
                diarizationModel: nil,
                lastCompletedTrackID: nil,
                errorCode: nil
            ))
            let artifact = try await Task {
                try await owner.withExclusive(attemptID: UUID(), participants: [participant], acceptsCompletedCancellation: { $0 != nil }) {
                    await registry.process(sessionID: UUID(), language: "en", result: result, directory: directory, provider: provider)
                }
            }.value
            XCTAssertEqual(artifact?.output != nil, !fails)
            XCTAssertEqual(artifact?.error != nil, fails)
            XCTAssertTrue(owner.restorationErrors.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("summary-\(result.attempt.id.uuidString).json").path))
        }
    }
}

extension MeetingModelResidencyTests {
    func testSnapshotFailureDoesNotReloadModelsThatWereNeverUnloaded() async throws {
        let owner = MeetingModelResidencyCoordinator()
        let trace = ResidencyTrace()
        let failure = MeetingModelParticipant(
            owner: "fluid",
            snapshot: { throw CocoaError(.fileReadUnknown) },
            suspend: { XCTFail("No unloading before all snapshots succeed") },
            restore: { _ in XCTFail("Failed participant must not be restored") }
        )
        do {
            try await owner.withExclusive(attemptID: UUID(), participants: [trace.participant("speech", loaded: true), failure]) { XCTFail("Exclusive work must not run after preparation fails") }
            XCTFail("Expected snapshot failure")
        } catch {}
        XCTAssertEqual(trace.events, ["snapshot:speech", "finish:speech"])
        XCTAssertFalse(owner.isExclusive)
    }

    func testReusedAttemptIDCannotReviveOldGrant() async throws {
        let owner = MeetingModelResidencyCoordinator()
        let attempt = UUID()
        var stale: MeetingModelGrant?
        let first = MeetingModelParticipant(owner: "speech", snapshot: { .init(id: "v3", configuration: "same") }, suspend: {}, restore: { _ in
            stale = MeetingModelContext.grant
        })
        try await owner.withExclusive(attemptID: attempt, participants: [first]) {}
        let second = MeetingModelParticipant(owner: "speech", snapshot: first.snapshot, suspend: {}, restore: { _ in
            try MeetingModelContext.$grant.withValue(stale) {
                XCTAssertThrowsError(try owner.beginOperation(owner: "speech", modelID: "v3"))
            }
        })
        try await owner.withExclusive(attemptID: attempt, participants: [second]) {}
        XCTAssertTrue(owner.restorationErrors.isEmpty)
    }

    func testSummaryRegistrationCannotChangeDuringMeeting() async throws {
        let owner = MeetingModelResidencyCoordinator()
        let registry = MeetingPostProcessingRegistry(residency: owner)
        try registry.register(SummaryProbe())
        try await owner.withExclusive(attemptID: UUID(), participants: []) {
            XCTAssertThrowsError(try registry.register(nil))
            XCTAssertNotNil(registry.provider)
        }
        try registry.register(nil)
        XCTAssertNil(registry.provider)
    }

    func testLegacyGrantCannotLoadFluidAndExpiresBeforeSummary() async throws {
        let owner = MeetingModelResidencyCoordinator()
        try await owner.withExclusive(attemptID: UUID(), participants: []) {
            try await owner.withLegacySpeechModel(modelID: "v3") {
                let token = try owner.beginOperation(owner: "speech", modelID: "v3")
                owner.endOperation(token)
                XCTAssertThrowsError(try owner.beginOperation(owner: "fluid", modelID: "v3"))
                try owner.markSummary()
                XCTAssertThrowsError(try owner.beginOperation(owner: "speech", modelID: "v3"))
            }
        }
    }
}

extension MeetingModelResidencyTests {
    func testCancelledBackgroundEnrollmentKeepsMeetingBlockedUntilModelReturns() async throws {
        let owner = MeetingModelResidencyCoordinator()
        let entered = ResidencyLatch()
        let completed = ResidencyLatch()
        let enrollment = Task {
            try await owner.withBackgroundOperation(owner: "speech", modelID: "parakeet-v3") {
                entered.release()
                await completed.wait() // Model loading/inference need not cooperate with cancellation.
            }
        }
        await entered.wait()
        enrollment.cancel()
        do {
            try await owner.withExclusive(attemptID: UUID(), participants: []) { XCTFail("Still-held encoder must block meeting") }
            XCTFail("Expected busy until the encoder is released")
        } catch { XCTAssertTrue(error is MeetingModelResidencyError) }
        completed.release()
        do { try await enrollment.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        try await owner.withExclusive(attemptID: UUID(), participants: []) {}
        XCTAssertFalse(owner.isExclusive)
    }

    func testBackgroundEnrollmentCannotStartDuringMeetingAndFailureReleasesAdmission() async throws {
        let owner = MeetingModelResidencyCoordinator()
        try await owner.withExclusive(attemptID: UUID(), participants: []) {
            do {
                try await owner.withBackgroundOperation(owner: "speech", modelID: "parakeet-v3") { XCTFail("No background model may load") }
                XCTFail("Expected retryable cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        do {
            try await owner.withBackgroundOperation(owner: "speech", modelID: "parakeet-v3") { throw CocoaError(.fileReadUnknown) }
            XCTFail("Expected model failure")
        } catch { XCTAssertTrue(error is CocoaError) }
        try await owner.withExclusive(attemptID: UUID(), participants: []) {}
    }

    func testUnloadAdmissionAtomicallyVetoesRestoreButIdleUnloadDoesNot() async throws {
        for explicit in [false, true] {
            let owner = MeetingModelResidencyCoordinator()
            let trace = ResidencyTrace()
            try await owner.withExclusive(attemptID: UUID(), participants: [trace.participant("fluid", loaded: true)]) {
                XCTAssertNil(try owner.vetoOrBeginOperation(owner: "fluid", modelID: "fluid", vetoDuringMeeting: explicit))
            }
            XCTAssertEqual(trace.events.contains("restore:fluid"), !explicit)
            let token = try XCTUnwrap(owner.vetoOrBeginOperation(owner: "fluid", modelID: "fluid", vetoDuringMeeting: explicit))
            do {
                try await owner.withExclusive(attemptID: UUID(), participants: []) { XCTFail("Unloading still owns the model") }
                XCTFail("Expected busy")
            } catch { XCTAssertTrue(error is MeetingModelResidencyError) }
            owner.endOperation(token)
            try await owner.withExclusive(attemptID: UUID(), participants: []) {}
        }
    }

    func testUnloadedDictionaryDetectorRemainsUnloadedAcrossMeeting() async throws {
        let detector = DictionaryTrainingEndpointDetector()
        let owner = MeetingModelResidencyCoordinator()
        var restored = false
        let participant = MeetingModelParticipant(
            owner: "dictionary-vad",
            snapshot: { await detector.residencySnapshot() },
            suspend: { await detector.unloadForMeeting() },
            restore: { _ in restored = true }
        )
        try await owner.withExclusive(attemptID: UUID(), participants: [participant]) {}
        let snapshot = await detector.residencySnapshot()
        XCTAssertNil(snapshot)
        XCTAssertFalse(restored, "Selected dictionary features must not load a detector that was not resident")
    }

    func testDictionaryRestoreUnloadsWhenDisabledOrChangedDuringPreparation() async throws {
        for reenable in [false, true] {
            let entered = ResidencyLatch()
            let completed = ResidencyLatch()
            var enabled = true
            var generation = "before-meeting"
            var resident = false
            var unloadCount = 0
            let restore = Task {
                try await DictionaryTrainingEndpointMonitor.prepareIfCurrent(
                    expectedGeneration: "before-meeting",
                    isEnabled: { enabled },
                    generation: { generation },
                    prepare: {
                        entered.release()
                        await completed.wait()
                        resident = true // Simulate a non-cooperative load finishing after disable.
                    },
                    unload: { resident = false; unloadCount += 1 }
                )
            }
            await entered.wait()
            enabled = reenable
            generation = reenable ? "disabled-then-enabled" : "disabled"
            completed.release()
            let restored = try await restore.value
            XCTAssertFalse(restored)
            XCTAssertFalse(resident)
            XCTAssertEqual(unloadCount, 1)
        }
    }

    func testDictionaryRestoreRejectsSnapshotInvalidatedBeforePreparation() async throws {
        let restored = try await DictionaryTrainingEndpointMonitor.prepareIfCurrent(
            expectedGeneration: "before-meeting",
            isEnabled: { true },
            generation: { "disabled-then-enabled" },
            prepare: { XCTFail("A new selection must not revive an old snapshot") },
            unload: { XCTFail("No model was loaded") }
        )
        XCTAssertFalse(restored)
    }

    func testQueuedWarmupsExpireEvenWhenMeetingUsesSameAttemptID() async throws {
        let owner = MeetingModelResidencyCoordinator()
        let before = owner.warmupGeneration
        XCTAssertTrue(owner.canRunWarmup(before))
        try await owner.withExclusive(attemptID: UUID(), participants: []) {
            XCTAssertNil(owner.warmupGeneration)
            XCTAssertFalse(owner.canRunWarmup(before))
            XCTAssertFalse(owner.canRunWarmup(nil))
        }
        XCTAssertFalse(owner.canRunWarmup(before))
        XCTAssertTrue(owner.canRunWarmup(owner.warmupGeneration))
    }
}
