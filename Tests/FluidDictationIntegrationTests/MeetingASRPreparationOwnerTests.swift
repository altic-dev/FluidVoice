#if FLUID_ASR_BASELINE_TESTS
@testable import FluidASRBaselineHost
#else
@testable import FluidVoice_Debug
#endif
import Foundation
import XCTest

private enum PreparationTestError: Error {
    case prepareFailed
    case retireFailed
}

/// Bounded rendezvous for orchestration tests. Waiters park on a continuation until `open()`;
/// cancellation of a waiter never resumes it, which is exactly how a non-cooperative
/// provider hook behaves under task cancellation.
private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(open: Bool = false) {
        self.isOpen = open
    }

    var opened: Bool {
        self.lock.withLock { self.isOpen }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = self.lock.withLock { () -> Bool in
                if self.isOpen { return true }
                self.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let pending = self.lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            self.isOpen = true
            let pending = self.waiters
            self.waiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume() }
    }

    func reset() {
        self.lock.withLock { self.isOpen = false }
    }
}

private final class OrchestrationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []

    var events: [String] {
        self.lock.withLock { self.recordedEvents }
    }

    func record(_ event: String) {
        self.lock.withLock { self.recordedEvents.append(event) }
    }

    func count(of event: String) -> Int {
        self.lock.withLock { self.recordedEvents.filter { $0 == event }.count }
    }
}

private final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        self.lock.withLock { self.flag }
    }

    func set(_ value: Bool) {
        self.lock.withLock { self.flag = value }
    }
}

private final class LeaseRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var activeLeases: [ASRActivityLease] = []

    func activate(_ lease: ASRActivityLease) {
        self.lock.withLock { self.activeLeases.append(lease) }
    }

    func deactivateAll() {
        self.lock.withLock { self.activeLeases.removeAll() }
    }

    func isActive(_ lease: ASRActivityLease) -> Bool {
        self.lock.withLock { self.activeLeases.contains(lease) }
    }
}

private final class DrainHook: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?

    func set(_ handler: (() -> Void)?) {
        self.lock.withLock { self.handler = handler }
    }

    func fire() {
        self.lock.withLock { self.handler }?()
    }
}

/// Proves orchestration only: call order, call counts, gating. It says nothing about real
/// CoreML model loading or deallocation, which remain the production closures' job.
private final class FakeMeetingTranscriptionProvider: TranscriptionProvider, @unchecked Sendable {
    let name = "FakeMeetingProvider"

    private let lock = NSLock()
    private var ready = false
    private var prepareCallCount = 0
    private var gate: ContinuationGate?
    private var error: Error?
    private var enteredHook: (@Sendable () -> Void)?
    private var progressHandler: ((ModelPreparationProgress) -> Void)?

    var isAvailable: Bool { true }

    var isReady: Bool {
        self.lock.withLock { self.ready }
    }

    var prepareCalls: Int {
        self.lock.withLock { self.prepareCallCount }
    }

    var lastProgressHandler: ((ModelPreparationProgress) -> Void)? {
        self.lock.withLock { self.progressHandler }
    }

    func blockPrepare(on gate: ContinuationGate) {
        self.lock.withLock { self.gate = gate }
    }

    func failPrepare(with error: Error?) {
        self.lock.withLock { self.error = error }
    }

    func onPrepareEntered(_ hook: (@Sendable () -> Void)?) {
        self.lock.withLock { self.enteredHook = hook }
    }

    func openPrepareGate() {
        self.lock.withLock { self.gate }?.open()
    }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        let entered = self.lock.withLock { () -> (@Sendable () -> Void)? in
            self.prepareCallCount += 1
            self.progressHandler = progressHandler
            return self.enteredHook
        }
        entered?()
        let gate = self.lock.withLock { self.gate }
        if let gate { await gate.wait() }
        if let error = self.lock.withLock({ self.error }) { throw error }
        self.lock.withLock { self.ready = true }
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        ASRTranscriptionResult(text: "")
    }
}

private final class DeallocationProvider: TranscriptionProvider, @unchecked Sendable {
    let name = "DeallocationProvider"
    let probe: TestFlag

    init(probe: TestFlag) {
        self.probe = probe
    }

    deinit {
        self.probe.set(true)
    }

    var isAvailable: Bool { true }
    var isReady: Bool { true }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {}

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        ASRTranscriptionResult(text: "")
    }
}

/// Bounded observation that never owns or cancels the operation being observed. Tests open
/// their gates and join their task handles after observation, so non-cooperative hooks cannot
/// strand a throwing timeout task-group child.
@MainActor
private func waitUntilCondition(
    timeoutNanoseconds: UInt64 = 5_000_000_000,
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while !condition() {
        if DispatchTime.now().uptimeNanoseconds >= deadline { return false }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return true
}

@MainActor
final class MeetingASRPreparationOwnerTests: XCTestCase {
    @MainActor private final class Harness {
        let recorder = OrchestrationRecorder()
        let registry = LeaseRegistry()
        let provider = FakeMeetingTranscriptionProvider()
        let userDownloadInProgress = TestFlag()
        let retireGate = ContinuationGate(open: true)
        let retireEntered = ContinuationGate()
        let failRetire = TestFlag()
        let drainGate = ContinuationGate(open: true)
        let drainHook = DrainHook()
        let owner: MeetingASRPreparationOwner

        init() {
            let recorder = self.recorder
            let registry = self.registry
            let provider = self.provider
            let userDownloadInProgress = self.userDownloadInProgress
            let retireGate = self.retireGate
            let retireEntered = self.retireEntered
            let failRetire = self.failRetire
            let drainGate = self.drainGate
            let drainHook = self.drainHook
            self.owner = MeetingASRPreparationOwner(
                isActiveLease: { lease in registry.isActive(lease) },
                isUserDownloadInProgress: { userDownloadInProgress.value },
                retireDictationResources: { _ in
                    recorder.record("retire")
                    retireEntered.open()
                    await retireGate.wait()
                    if failRetire.value { throw PreparationTestError.retireFailed }
                },
                makeProvider: { _ in
                    recorder.record("factory")
                    return provider
                },
                prepareProvider: { preparedProvider, _, progressHandler in
                    let identity = preparedProvider as AnyObject === provider
                    recorder.record(identity ? "prepare" : "prepare:wrongProvider")
                    try await provider.prepare(progressHandler: progressHandler)
                },
                drainExecutor: { _ in
                    recorder.record("drain")
                    drainHook.fire()
                    await drainGate.wait()
                }
            )
        }

        func openAllGates() {
            self.retireGate.open()
            self.provider.openPrepareGate()
            self.drainGate.open()
        }
    }

    private func makeHarness() -> Harness {
        let harness = Harness()
        self.addTeardownBlock { @MainActor in
            harness.openAllGates()
            if let token = harness.owner.currentClaimToken {
                await harness.owner.release(token)
            }
        }
        return harness
    }

    private func makeLease(activity: ASRExclusiveActivity = .meeting) -> ASRActivityLease {
        ASRActivityLease(id: UUID(), activity: activity)
    }

    private func installSecondWaiterAcknowledgement(
        on owner: MeetingASRPreparationOwner
    ) -> ContinuationGate {
        let secondWaiterEntered = ContinuationGate()
#if DEBUG
        let waiters = OrchestrationRecorder()
        owner.didBeginWaitingForTesting = {
            waiters.record("waiting")
            if waiters.count(of: "waiting") == 2 {
                secondWaiterEntered.open()
            }
        }
#endif
        return secondWaiterEntered
    }

    func testRejectsInvalidLeaseBeforeAnyMutationOrDependencyCall() async {
        let harness = self.makeHarness()
        let lease = self.makeLease()

        do {
            _ = try await harness.owner.prepare(
                lease: lease, attemptID: UUID(), configuration: MeetingFinalProcessingConfiguration()
            )
            XCTFail("Expected invalid lease rejection")
        } catch let error as MeetingASRPreparationError {
            XCTAssertEqual(error, .invalidActivityLease)
        } catch {
            XCTFail("Expected MeetingASRPreparationError, got \(error)")
        }

        // A lease the registry accepts but for the wrong activity is also rejected.
        let dictationLease = self.makeLease(activity: .dictation)
        harness.registry.activate(dictationLease)
        do {
            _ = try await harness.owner.prepare(
                lease: dictationLease, attemptID: UUID(), configuration: MeetingFinalProcessingConfiguration()
            )
            XCTFail("Expected invalid lease rejection for non-meeting activity")
        } catch let error as MeetingASRPreparationError {
            XCTAssertEqual(error, .invalidActivityLease)
        } catch {
            XCTFail("Expected MeetingASRPreparationError, got \(error)")
        }

        XCTAssertTrue(harness.recorder.events.isEmpty)
        XCTAssertFalse(harness.owner.isClaimed)
        XCTAssertFalse(harness.owner.isDraining)
        XCTAssertEqual(harness.provider.prepareCalls, 0)
    }

    func testRejectsUnsupportedFixedPolicyBeforeAnyMutationOrDependencyCall() async {
        let harness = self.makeHarness()
        let lease = self.makeLease()
        harness.registry.activate(lease)

        do {
            _ = try await harness.owner.prepare(
                lease: lease,
                attemptID: UUID(),
                configuration: MeetingFinalProcessingConfiguration(languageCode: "de")
            )
            XCTFail("Expected unsupported policy rejection")
        } catch let error as MeetingProviderOptionsError {
            XCTAssertEqual(error, .unsupportedLanguageCode("de"))
        } catch {
            XCTFail("Expected MeetingProviderOptionsError, got \(error)")
        }

        do {
            _ = try await harness.owner.prepare(
                lease: lease,
                attemptID: UUID(),
                configuration: MeetingFinalProcessingConfiguration(vocabularyBoostingEnabled: true)
            )
            XCTFail("Expected unsupported policy rejection")
        } catch let error as MeetingProviderOptionsError {
            XCTAssertEqual(error, .unsupportedFeature("vocabularyBoosting"))
        } catch {
            XCTFail("Expected MeetingProviderOptionsError, got \(error)")
        }

        XCTAssertTrue(harness.recorder.events.isEmpty)
        XCTAssertFalse(harness.owner.isClaimed)
        XCTAssertEqual(harness.provider.prepareCalls, 0)
    }

    func testRejectsUserDownloadInProgressBeforeAnyMutationOrDependencyCall() async {
        let harness = self.makeHarness()
        let lease = self.makeLease()
        harness.registry.activate(lease)
        harness.userDownloadInProgress.set(true)

        do {
            _ = try await harness.owner.prepare(
                lease: lease, attemptID: UUID(), configuration: MeetingFinalProcessingConfiguration()
            )
            XCTFail("Expected user-download rejection")
        } catch let error as MeetingASRPreparationError {
            XCTAssertEqual(error, .userModelDownloadInProgress)
        } catch {
            XCTFail("Expected MeetingASRPreparationError, got \(error)")
        }

        XCTAssertTrue(harness.recorder.events.isEmpty)
        XCTAssertFalse(harness.owner.isClaimed)
        XCTAssertEqual(harness.provider.prepareCalls, 0)
    }

    func testPreCancelledPrepareRejectsWithoutMutationOrDependencyCall() async {
        let harness = self.makeHarness()
        let lease = self.makeLease()
        harness.registry.activate(lease)

        let task = Task { @MainActor in
            try await harness.owner.prepare(
                lease: lease, attemptID: UUID(), configuration: MeetingFinalProcessingConfiguration()
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected pre-cancelled prepare to throw")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertTrue(harness.recorder.events.isEmpty)
        XCTAssertFalse(harness.owner.isClaimed)
        XCTAssertEqual(harness.provider.prepareCalls, 0)
    }

    func testSuccessfulPrepareRetiresBuildsPreparesInOrderAndStaysClaimed() async throws {
        let harness = self.makeHarness()
        let lease = self.makeLease()
        harness.registry.activate(lease)
        let attempt = UUID()
        let configuration = MeetingFinalProcessingConfiguration()

        let first = try await harness.owner.prepare(
            lease: lease, attemptID: attempt, configuration: configuration
        )

        XCTAssertEqual(harness.recorder.events, ["retire", "factory", "prepare"])
        XCTAssertTrue(harness.owner.isClaimed)
        XCTAssertFalse(harness.owner.isDraining)
        XCTAssertTrue(harness.provider.isReady)

        // A repeated identical request returns the ready slot without redoing any work.
        let second = try await harness.owner.prepare(
            lease: lease, attemptID: attempt, configuration: configuration
        )
        XCTAssertTrue(first as AnyObject === second as AnyObject)
        XCTAssertEqual(harness.recorder.events, ["retire", "factory", "prepare"])
        XCTAssertEqual(harness.provider.prepareCalls, 1)
        XCTAssertTrue(harness.owner.isClaimed)
    }

    func testSameLeaseAttemptAndConfigurationJoinsSingleFlight() async throws {
        let harness = self.makeHarness()
        let lease = self.makeLease()
        harness.registry.activate(lease)
        let attempt = UUID()
        let configuration = MeetingFinalProcessingConfiguration()
        let providerGate = ContinuationGate()
        let entered = ContinuationGate()
        harness.provider.blockPrepare(on: providerGate)
        harness.provider.onPrepareEntered { entered.open() }

        let first = Task { @MainActor in
            let provider = try await harness.owner.prepare(
                lease: lease, attemptID: attempt, configuration: configuration
            )
            return ObjectIdentifier(provider as AnyObject)
        }
        let enteredObserved = await waitUntilCondition { entered.opened }
        XCTAssertTrue(enteredObserved)

        let second = Task { @MainActor in
            let provider = try await harness.owner.prepare(
                lease: lease, attemptID: attempt, configuration: configuration
            )
            return ObjectIdentifier(provider as AnyObject)
        }
        XCTAssertTrue(harness.owner.isClaimed)

        providerGate.open()
        let firstID = try await first.value
        let secondID = try await second.value

        XCTAssertEqual(firstID, secondID)
        XCTAssertEqual(harness.provider.prepareCalls, 1)
        XCTAssertEqual(harness.recorder.count(of: "retire"), 1)
        XCTAssertEqual(harness.recorder.count(of: "factory"), 1)
        XCTAssertTrue(harness.owner.isClaimed)
    }

    func testDifferentRequestFailsBusyWithoutCancellingInFlightPreparation() async throws {
        let harness = self.makeHarness()
        let lease = self.makeLease()
        harness.registry.activate(lease)
        let attempt = UUID()
        let configuration = MeetingFinalProcessingConfiguration()
        let providerGate = ContinuationGate()
        let entered = ContinuationGate()
        harness.provider.blockPrepare(on: providerGate)
        harness.provider.onPrepareEntered { entered.open() }

        let first = Task { @MainActor in
            try await harness.owner.prepare(
                lease: lease, attemptID: attempt, configuration: configuration
            )
        }
        let enteredObserved = await waitUntilCondition { entered.opened }
        XCTAssertTrue(enteredObserved)

        let otherLease = self.makeLease()
        harness.registry.activate(otherLease)
        let busyAttempts: [(ASRActivityLease, UUID, MeetingFinalProcessingConfiguration)] = [
            (lease, UUID(), configuration),
            (lease, attempt, MeetingFinalProcessingConfiguration(pipelineVersion: configuration.pipelineVersion + 1)),
            (otherLease, attempt, configuration),
        ]
        for (busyLease, busyAttempt, busyConfiguration) in busyAttempts {
            do {
                _ = try await harness.owner.prepare(
                    lease: busyLease, attemptID: busyAttempt, configuration: busyConfiguration
                )
                XCTFail("Expected busy rejection for a different request")
            } catch let error as MeetingASRPreparationError {
                XCTAssertEqual(error, .preparationInProgress)
            } catch {
                XCTFail("Expected MeetingASRPreparationError, got \(error)")
            }
        }

        // The rejections must not have disturbed the in-flight preparation.
        providerGate.open()
        _ = try await first.value
        XCTAssertEqual(harness.provider.prepareCalls, 1)
        XCTAssertEqual(harness.recorder.events, ["retire", "factory", "prepare"])
        XCTAssertTrue(harness.owner.isClaimed)

        // A different request is still busy against the ready slot; the identical request
        // returns it without new work.
        do {
            _ = try await harness.owner.prepare(
                lease: lease, attemptID: UUID(), configuration: configuration
            )
            XCTFail("Expected busy rejection against the ready slot")
        } catch let error as MeetingASRPreparationError {
            XCTAssertEqual(error, .preparationInProgress)
        } catch {
            XCTFail("Expected MeetingASRPreparationError, got \(error)")
        }
        _ = try await harness.owner.prepare(lease: lease, attemptID: attempt, configuration: configuration)
        XCTAssertEqual(harness.provider.prepareCalls, 1)
        XCTAssertTrue(harness.owner.isClaimed)
    }

    func testCancellationStaysClaimedUntilNonCooperativePrepareAndDrainFinish() async throws {
        let harness = self.makeHarness()
        let lease = self.makeLease()
        harness.registry.activate(lease)
        let providerGate = ContinuationGate()
        let entered = ContinuationGate()
        let attemptID = UUID()
        harness.provider.blockPrepare(on: providerGate)
        harness.provider.onPrepareEntered { entered.open() }

        let preparation = Task { @MainActor in
            try await harness.owner.prepare(
                lease: lease, attemptID: attemptID, configuration: MeetingFinalProcessingConfiguration()
            )
        }
        let enteredObserved = await waitUntilCondition { entered.opened }
        XCTAssertTrue(enteredObserved)

        preparation.cancel()
        // The fake hook ignores cancellation, so until it returns the claim must stay and
        // the executor drain must not have run.
        XCTAssertTrue(harness.owner.isClaimed)
        XCTAssertFalse(harness.owner.isDraining)
        XCTAssertEqual(harness.recorder.count(of: "drain"), 0)

        providerGate.open()
        do {
            _ = try await preparation.value
            XCTFail("Expected cancelled preparation to throw")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertEqual(harness.recorder.events, ["retire", "factory", "prepare", "drain"])
        XCTAssertFalse(harness.owner.isClaimed)
        XCTAssertFalse(harness.owner.isDraining)
    }

    func testFailedPrepareDrainsExecutorBeforeClearingClaimAndAllowsRetry() async throws {
        let harness = self.makeHarness()
        let lease = self.makeLease()
        harness.registry.activate(lease)
        let configuration = MeetingFinalProcessingConfiguration()
        harness.provider.failPrepare(with: PreparationTestError.prepareFailed)

        do {
            _ = try await harness.owner.prepare(
                lease: lease, attemptID: UUID(), configuration: configuration
            )
            XCTFail("Expected preparation failure")
        } catch PreparationTestError.prepareFailed {
        } catch {
            XCTFail("Expected PreparationTestError, got \(error)")
        }

        XCTAssertEqual(harness.recorder.events, ["retire", "factory", "prepare", "drain"])
        XCTAssertFalse(harness.owner.isClaimed)
        XCTAssertFalse(harness.owner.isDraining)

        harness.provider.failPrepare(with: nil)
        _ = try await harness.owner.prepare(
            lease: lease, attemptID: UUID(), configuration: configuration
        )
        XCTAssertEqual(
            harness.recorder.events,
            ["retire", "factory", "prepare", "drain", "retire", "factory", "prepare"]
        )
        XCTAssertEqual(harness.provider.prepareCalls, 2)
        XCTAssertTrue(harness.owner.isClaimed)
    }

    func testRetirementCancellationInvalidationAndFailureNeverReachFactory() async throws {
        do {
            let harness = self.makeHarness()
            let lease = self.makeLease()
            harness.registry.activate(lease)
            harness.retireGate.reset()
            let preparation = Task { @MainActor in
                try await harness.owner.prepare(
                    lease: lease, attemptID: UUID(), configuration: MeetingFinalProcessingConfiguration()
                )
            }
            let observed = await waitUntilCondition { harness.retireEntered.opened }
            XCTAssertTrue(observed)
            preparation.cancel()
            XCTAssertTrue(harness.owner.isClaimed)
            harness.retireGate.open()
            do {
                _ = try await preparation.value
                XCTFail("Expected retirement cancellation")
            } catch is CancellationError {
            }
            XCTAssertEqual(harness.recorder.count(of: "factory"), 0)
            XCTAssertEqual(harness.recorder.count(of: "drain"), 1)
            XCTAssertFalse(harness.owner.isClaimed)
        }

        do {
            let harness = self.makeHarness()
            let lease = self.makeLease()
            harness.registry.activate(lease)
            harness.retireGate.reset()
            let preparation = Task { @MainActor in
                try await harness.owner.prepare(
                    lease: lease, attemptID: UUID(), configuration: MeetingFinalProcessingConfiguration()
                )
            }
            let observed = await waitUntilCondition { harness.retireEntered.opened }
            XCTAssertTrue(observed)
            harness.registry.deactivateAll()
            harness.retireGate.open()
            do {
                _ = try await preparation.value
                XCTFail("Expected invalid-lease cancellation")
            } catch is CancellationError {
            }
            XCTAssertEqual(harness.recorder.count(of: "factory"), 0)
            XCTAssertEqual(harness.recorder.count(of: "drain"), 1)
            XCTAssertFalse(harness.owner.isClaimed)
        }

        do {
            let harness = self.makeHarness()
            let lease = self.makeLease()
            harness.registry.activate(lease)
            harness.failRetire.set(true)
            do {
                _ = try await harness.owner.prepare(
                    lease: lease, attemptID: UUID(), configuration: MeetingFinalProcessingConfiguration()
                )
                XCTFail("Expected retirement failure")
            } catch PreparationTestError.retireFailed {
            }
            XCTAssertEqual(harness.recorder.events, ["retire", "drain"])
            XCTAssertFalse(harness.owner.isClaimed)
        }
    }

    func testReleaseAndPreparationFailureShareExactlyOneDrain() async throws {
        let harness = self.makeHarness()
        let lease = self.makeLease()
        harness.registry.activate(lease)
        let entered = ContinuationGate()
        let providerGate = ContinuationGate()
        harness.provider.blockPrepare(on: providerGate)
        harness.provider.onPrepareEntered { entered.open() }
        harness.provider.failPrepare(with: PreparationTestError.prepareFailed)
        let preparation = Task { @MainActor in
            try await harness.owner.prepare(
                lease: lease, attemptID: UUID(), configuration: MeetingFinalProcessingConfiguration()
            )
        }
        let enteredObserved = await waitUntilCondition { entered.opened }
        XCTAssertTrue(enteredObserved)
        let token = try XCTUnwrap(harness.owner.currentClaimToken)
        harness.drainGate.reset()
        let release = Task { @MainActor in await harness.owner.release(token) }
        providerGate.open()
        let drainObserved = await waitUntilCondition { harness.recorder.count(of: "drain") == 1 }
        XCTAssertTrue(drainObserved)
        XCTAssertEqual(harness.recorder.count(of: "drain"), 1)
        harness.drainGate.open()
        do {
            _ = try await preparation.value
            XCTFail("Expected preparation failure")
        } catch PreparationTestError.prepareFailed {
        }
        await release.value
        XCTAssertFalse(harness.owner.isClaimed)
    }

    func testOldTokenCannotReleaseRepeatedSameLeaseAttempt() async throws {
        let harness = self.makeHarness()
        let lease = self.makeLease()
        harness.registry.activate(lease)
        let attempt = UUID()
        _ = try await harness.owner.prepare(
            lease: lease, attemptID: attempt, configuration: MeetingFinalProcessingConfiguration()
        )
        let oldToken = try XCTUnwrap(harness.owner.currentClaimToken)
        await harness.owner.release(oldToken)
        _ = try await harness.owner.prepare(
            lease: lease, attemptID: attempt, configuration: MeetingFinalProcessingConfiguration()
        )
        let newToken = try XCTUnwrap(harness.owner.currentClaimToken)
        await harness.owner.release(oldToken)
        XCTAssertTrue(harness.owner.isClaimed)
        XCTAssertEqual(harness.recorder.count(of: "drain"), 1)
        await harness.owner.release(newToken)
        XCTAssertFalse(harness.owner.isClaimed)
        XCTAssertEqual(harness.recorder.count(of: "drain"), 2)
    }

    func testJoinedWaiterCancellationCancelsSingleFlightAndSharesDrain() async throws {
        let harness = self.makeHarness()
        let lease = self.makeLease()
        harness.registry.activate(lease)
        let attemptID = UUID()
        let providerGate = ContinuationGate()
        let entered = ContinuationGate()
        harness.provider.blockPrepare(on: providerGate)
        harness.provider.onPrepareEntered { entered.open() }
        let secondWaiterEntered = self.installSecondWaiterAcknowledgement(on: harness.owner)
#if !DEBUG
        let secondStarted = ContinuationGate()
#endif
        let first = Task { @MainActor in
            try await harness.owner.prepare(
                lease: lease, attemptID: attemptID, configuration: MeetingFinalProcessingConfiguration()
            )
        }
        let enteredObserved = await waitUntilCondition { entered.opened }
        XCTAssertTrue(enteredObserved)
        let second = Task { @MainActor in
#if !DEBUG
            secondStarted.open()
#endif
            return try await harness.owner.prepare(
                lease: lease, attemptID: attemptID, configuration: MeetingFinalProcessingConfiguration()
            )
        }
        // Both waiters join the same exact operation; cancellation of one cancels the shared worker.
#if DEBUG
        let secondObserved = await waitUntilCondition { secondWaiterEntered.opened }
#else
        let secondObserved = await waitUntilCondition { secondStarted.opened }
#endif
        XCTAssertTrue(secondObserved)
        second.cancel()
        providerGate.open()
        do {
            _ = try await first.value
            XCTFail("Expected the first joined waiter to observe cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError from first waiter, got \(error)")
        }
        do {
            _ = try await second.value
            XCTFail("Expected the cancelled joined waiter to throw")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError from second waiter, got \(error)")
        }
        XCTAssertEqual(harness.recorder.count(of: "drain"), 1)
        XCTAssertFalse(harness.owner.isClaimed)
    }

#if DEBUG
    func testReadyTransitionCancelsJoinedWaiterBeforeEitherCanReturn() async throws {
        var joinedWaiter: Task<any TranscriptionProvider, Error>?
        let harness = self.makeHarness()
        harness.owner.didMarkReadyForTesting = {
            joinedWaiter?.cancel()
        }
        let lease = self.makeLease()
        harness.registry.activate(lease)
        let attemptID = UUID()
        let providerGate = ContinuationGate()
        let entered = ContinuationGate()
        harness.provider.blockPrepare(on: providerGate)
        harness.provider.onPrepareEntered { entered.open() }
        let secondWaiterEntered = self.installSecondWaiterAcknowledgement(on: harness.owner)
#if !DEBUG
        let secondStarted = ContinuationGate()
#endif

        let first = Task { @MainActor in
            try await harness.owner.prepare(
                lease: lease, attemptID: attemptID, configuration: MeetingFinalProcessingConfiguration()
            )
        }
        let enteredObserved = await waitUntilCondition { entered.opened }
        XCTAssertTrue(enteredObserved)
        let second = Task { @MainActor in
#if !DEBUG
            secondStarted.open()
#endif
            return try await harness.owner.prepare(
                lease: lease, attemptID: attemptID, configuration: MeetingFinalProcessingConfiguration()
            )
        }
        joinedWaiter = second
#if DEBUG
        let secondObserved = await waitUntilCondition { secondWaiterEntered.opened }
#else
        let secondObserved = await waitUntilCondition { secondStarted.opened }
#endif
        XCTAssertTrue(secondObserved)
        providerGate.open()

        do {
            _ = try await first.value
            XCTFail("Expected first waiter to observe shared-worker cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError from first waiter, got \(error)")
        }
        do {
            _ = try await second.value
            XCTFail("Expected joined waiter cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError from joined waiter, got \(error)")
        }
        XCTAssertEqual(harness.recorder.count(of: "drain"), 1)
        XCTAssertFalse(harness.owner.isClaimed)
        joinedWaiter = nil
    }
#endif

    func testProgressHopsToMainActorAndStaleEventsAreDroppedAfterReleaseAndLeaseChange() async throws {
        let harness = self.makeHarness()
        let lease = self.makeLease()
        harness.registry.activate(lease)
        let providerGate = ContinuationGate()
        let entered = ContinuationGate()
        harness.provider.blockPrepare(on: providerGate)
        harness.provider.onPrepareEntered { entered.open() }

        let deliveries = OrchestrationRecorder()
        let expectedProgress = [
            "progress:preparingDownload:-1.0",
            "progress:downloading:0.5",
            "progress:optimizing:-1.0",
            "progress:loading:-1.0",
        ]
        let allProgressDelivered = self.expectation(description: "all progress phases delivered on the main actor")
        let progress: (ModelPreparationProgress) -> Void = { update in
            XCTAssertTrue(Thread.isMainThread)
            deliveries.record("progress:\(update.phase):\(update.fractionCompleted ?? -1)")
            if deliveries.events.count == expectedProgress.count {
                allProgressDelivered.fulfill()
            }
        }

        let preparation = Task { @MainActor in
            try await harness.owner.prepare(
                lease: lease,
                attemptID: UUID(),
                configuration: MeetingFinalProcessingConfiguration(),
                progress: progress
            )
        }
        let enteredObserved = await waitUntilCondition { entered.opened }
        XCTAssertTrue(enteredObserved)

        let handler = try XCTUnwrap(harness.provider.lastProgressHandler)
        DispatchQueue.global().async {
            handler(.preparingDownload)
            handler(.downloading(0.5))
            handler(.optimizing)
            handler(.loading)
        }
        await fulfillment(of: [allProgressDelivered], timeout: 2)
        XCTAssertEqual(deliveries.events, expectedProgress)

        providerGate.open()
        _ = try await preparation.value
        let token = try XCTUnwrap(harness.owner.currentClaimToken)

        // A late provider callback after readiness is stale even before release begins.
        let staleAfterReady = self.expectation(description: "no delivery after ready")
        staleAfterReady.isInverted = true
        DispatchQueue.global().async { handler(.downloading(0.6)) }
        await fulfillment(of: [staleAfterReady], timeout: 0.3)

        // Draining suppresses callbacks while the exact claim remains visible.
        harness.drainGate.reset()
        let drainEntered = ContinuationGate()
        harness.drainHook.set { drainEntered.open() }
        let release = Task { @MainActor in await harness.owner.release(token) }
        let drainObserved = await waitUntilCondition { drainEntered.opened }
        XCTAssertTrue(drainObserved)
        let staleDuringDrain = self.expectation(description: "no delivery while draining")
        staleDuringDrain.isInverted = true
        DispatchQueue.global().async { handler(.downloading(0.7)) }
        await fulfillment(of: [staleDuringDrain], timeout: 0.3)
        harness.drainGate.open()
        await release.value
        XCTAssertFalse(harness.owner.isClaimed)

        // After release the old handler is stale and must be dropped.
        let staleAfterRelease = self.expectation(description: "no delivery after release")
        staleAfterRelease.isInverted = true
        DispatchQueue.global().async { handler(.downloading(0.75)) }
        await fulfillment(of: [staleAfterRelease], timeout: 0.3)
        XCTAssertEqual(deliveries.events, expectedProgress)

        // After a different lease owns a fresh slot the old handler is still stale.
        let newLease = self.makeLease()
        harness.registry.activate(newLease)
        _ = try await harness.owner.prepare(
            lease: newLease, attemptID: UUID(), configuration: MeetingFinalProcessingConfiguration()
        )
        let staleAfterLeaseChange = self.expectation(description: "no delivery after lease change")
        staleAfterLeaseChange.isInverted = true
        DispatchQueue.global().async { handler(.downloading(0.9)) }
        await fulfillment(of: [staleAfterLeaseChange], timeout: 0.3)
        XCTAssertEqual(deliveries.events, expectedProgress)
    }

    func testProgressIsSuppressedAfterCancellationAndLeaseInvalidation() async throws {
        do {
            let harness = self.makeHarness()
            let lease = self.makeLease()
            harness.registry.activate(lease)
            let providerGate = ContinuationGate()
            let entered = ContinuationGate()
            harness.provider.blockPrepare(on: providerGate)
            harness.provider.onPrepareEntered { entered.open() }
            let deliveries = OrchestrationRecorder()
            let preparation = Task { @MainActor in
                try await harness.owner.prepare(
                    lease: lease,
                    attemptID: UUID(),
                    configuration: MeetingFinalProcessingConfiguration(),
                    progress: { _ in deliveries.record("cancelled") }
                )
            }
            let enteredObserved = await waitUntilCondition { entered.opened }
            XCTAssertTrue(enteredObserved)
            let handler = try XCTUnwrap(harness.provider.lastProgressHandler)
            preparation.cancel()
            let stale = self.expectation(description: "no progress after cancellation")
            stale.isInverted = true
            DispatchQueue.global().async { handler(.downloading(0.8)) }
            await fulfillment(of: [stale], timeout: 0.3)
            providerGate.open()
            do {
                _ = try await preparation.value
                XCTFail("Expected cancelled preparation")
            } catch is CancellationError {
            }
            XCTAssertTrue(deliveries.events.isEmpty)
        }

        do {
            let harness = self.makeHarness()
            let lease = self.makeLease()
            harness.registry.activate(lease)
            let providerGate = ContinuationGate()
            let entered = ContinuationGate()
            harness.provider.blockPrepare(on: providerGate)
            harness.provider.onPrepareEntered { entered.open() }
            let deliveries = OrchestrationRecorder()
            let preparation = Task { @MainActor in
                try await harness.owner.prepare(
                    lease: lease,
                    attemptID: UUID(),
                    configuration: MeetingFinalProcessingConfiguration(),
                    progress: { _ in deliveries.record("invalid") }
                )
            }
            let enteredObserved = await waitUntilCondition { entered.opened }
            XCTAssertTrue(enteredObserved)
            let handler = try XCTUnwrap(harness.provider.lastProgressHandler)
            harness.registry.deactivateAll()
            let stale = self.expectation(description: "no progress after invalidation")
            stale.isInverted = true
            DispatchQueue.global().async { handler(.downloading(0.9)) }
            await fulfillment(of: [stale], timeout: 0.3)
            providerGate.open()
            do {
                _ = try await preparation.value
                XCTFail("Expected invalidated preparation")
            } catch is CancellationError {
            }
            XCTAssertTrue(deliveries.events.isEmpty)
        }
    }

    func testReleaseJoinsSingleDrainAndRejectsNewPreparesUntilDrainCompletes() async throws {
        let harness = self.makeHarness()
        let lease = self.makeLease()
        harness.registry.activate(lease)
        let attempt = UUID()
        let configuration = MeetingFinalProcessingConfiguration()
        _ = try await harness.owner.prepare(lease: lease, attemptID: attempt, configuration: configuration)
        XCTAssertTrue(harness.owner.isClaimed)

        harness.drainGate.reset()
        let drainEntered = ContinuationGate()
        harness.drainHook.set { drainEntered.open() }

        let token = try XCTUnwrap(harness.owner.currentClaimToken)
        let firstRelease = Task { @MainActor in
            await harness.owner.release(token)
        }
        let drainObserved = await waitUntilCondition { drainEntered.opened }
        XCTAssertTrue(drainObserved)
        XCTAssertTrue(harness.owner.isClaimed)
        XCTAssertTrue(harness.owner.isDraining)

        // No new prepare may start while the drain is blocked, not even the same request.
        for blockedAttempt in [attempt, UUID()] {
            do {
                _ = try await harness.owner.prepare(
                    lease: lease, attemptID: blockedAttempt, configuration: configuration
                )
                XCTFail("Expected busy rejection during drain")
            } catch let error as MeetingASRPreparationError {
                XCTAssertEqual(error, .preparationInProgress)
            } catch {
                XCTFail("Expected MeetingASRPreparationError, got \(error)")
            }
        }

        // A second release joins the same drain instead of starting another one.
        let secondRelease = Task { @MainActor in
            await harness.owner.release(token)
        }
        XCTAssertEqual(harness.recorder.count(of: "drain"), 1)

        harness.drainGate.open()
        await firstRelease.value
        await secondRelease.value
        XCTAssertFalse(harness.owner.isClaimed)
        XCTAssertFalse(harness.owner.isDraining)
        XCTAssertEqual(harness.recorder.count(of: "drain"), 1)

        // Once the drain finished, a fresh preparation may claim the slot again.
        _ = try await harness.owner.prepare(
            lease: lease, attemptID: UUID(), configuration: configuration
        )
        XCTAssertTrue(harness.owner.isClaimed)
        XCTAssertEqual(harness.recorder.count(of: "drain"), 1)
    }

    func testReleaseWithoutMatchingClaimIsNoOp() async throws {
        let harness = self.makeHarness()

        await harness.owner.release(
            MeetingASRPreparationClaimToken(lease: self.makeLease(), operationID: UUID())
        )
        XCTAssertFalse(harness.owner.isClaimed)
        XCTAssertTrue(harness.recorder.events.isEmpty)

        let lease = self.makeLease()
        harness.registry.activate(lease)
        _ = try await harness.owner.prepare(
            lease: lease, attemptID: UUID(), configuration: MeetingFinalProcessingConfiguration()
        )

        await harness.owner.release(
            MeetingASRPreparationClaimToken(lease: self.makeLease(), operationID: UUID())
        )
        XCTAssertTrue(harness.owner.isClaimed)
        XCTAssertEqual(harness.recorder.count(of: "drain"), 0)

        await harness.owner.release(try XCTUnwrap(harness.owner.currentClaimToken))
        XCTAssertFalse(harness.owner.isClaimed)
        XCTAssertEqual(harness.recorder.count(of: "drain"), 1)
    }

    func testSuccessfulWorkerTaskDoesNotRetainProviderResultAfterRelease() async throws {
        let probe = TestFlag()
        let lease = self.makeLease()
        let registry = LeaseRegistry()
        registry.activate(lease)
        let providerGate = ContinuationGate()
        let providerEntered = ContinuationGate()
        let owner = MeetingASRPreparationOwner(
            isActiveLease: { registry.isActive($0) },
            isUserDownloadInProgress: { false },
            retireDictationResources: { _ in },
            makeProvider: { _ in DeallocationProvider(probe: probe) },
            prepareProvider: { provider, _, progress in
                providerEntered.open()
                await providerGate.wait()
                try await provider.prepare(progressHandler: progress)
            },
            drainExecutor: { _ in }
        )
        let secondWaiterEntered = self.installSecondWaiterAcknowledgement(on: owner)
#if !DEBUG
        let secondStarted = ContinuationGate()
#endif
        self.addTeardownBlock { @MainActor in
            providerGate.open()
            if let token = owner.currentClaimToken {
                await owner.release(token)
            }
        }

        let attemptID = UUID()
        let first = Task { @MainActor in
            do {
                _ = try await owner.prepare(
                    lease: lease, attemptID: attemptID, configuration: MeetingFinalProcessingConfiguration()
                )
                return true
            } catch {
                return false
            }
        }
        let enteredObserved = await waitUntilCondition { providerEntered.opened }
        XCTAssertTrue(enteredObserved)
        let second = Task { @MainActor in
#if !DEBUG
            secondStarted.open()
#endif
            do {
                _ = try await owner.prepare(
                    lease: lease, attemptID: attemptID, configuration: MeetingFinalProcessingConfiguration()
                )
                return true
            } catch {
                return false
            }
        }
#if DEBUG
        let secondObserved = await waitUntilCondition { secondWaiterEntered.opened }
#else
        let secondObserved = await waitUntilCondition { secondStarted.opened }
#endif
        XCTAssertTrue(secondObserved)
        providerGate.open()
        let firstSucceeded = await first.value
        let secondSucceeded = await second.value
        XCTAssertTrue(firstSucceeded)
        XCTAssertTrue(secondSucceeded)
        let token = try XCTUnwrap(owner.currentClaimToken)
        await owner.release(token)
        XCTAssertTrue(probe.value)
    }
}

#if DEBUG
private enum ScopeBodyTestError: Error {
    case bodyFailed
}

/// Exercises `ASRService.withPreparedMeetingASR` with the real scope code and the real owner
/// driven by fake dependency closures (injected through the DEBUG owner seam), plus the real
/// production retirement path. No test loads or downloads real ASR models. The seam exists
/// only in DEBUG builds, so the whole suite compiles out of release-config baseline builds.
@MainActor
final class ASRServiceMeetingASRScopeTests: XCTestCase {
    @MainActor private final class Harness {
        let service = ASRService()
        let recorder = OrchestrationRecorder()
        let registry = LeaseRegistry()
        let provider = FakeMeetingTranscriptionProvider()
        let userDownloadInProgress = TestFlag()
        let retireGate = ContinuationGate(open: true)
        let retireEntered = ContinuationGate()
        let drainGate = ContinuationGate(open: true)
        let drainHook = DrainHook()
        let owner: MeetingASRPreparationOwner

        init() {
            let recorder = self.recorder
            let registry = self.registry
            let provider = self.provider
            let userDownloadInProgress = self.userDownloadInProgress
            let retireGate = self.retireGate
            let retireEntered = self.retireEntered
            let drainGate = self.drainGate
            let drainHook = self.drainHook
            self.owner = MeetingASRPreparationOwner(
                isActiveLease: { lease in registry.isActive(lease) },
                isUserDownloadInProgress: { userDownloadInProgress.value },
                retireDictationResources: { _ in
                    recorder.record("retire")
                    retireEntered.open()
                    await retireGate.wait()
                },
                makeProvider: { configuration in
                    // The fingerprint proves the scope passes the configuration through untouched.
                    recorder.record("factory:\(configuration.identityFingerprint)")
                    return provider
                },
                prepareProvider: { preparedProvider, _, progressHandler in
                    let identity = preparedProvider as AnyObject === provider
                    recorder.record(identity ? "prepare" : "prepare:wrongProvider")
                    try await provider.prepare(progressHandler: progressHandler)
                },
                drainExecutor: { _ in
                    recorder.record("drain")
                    drainHook.fire()
                    await drainGate.wait()
                }
            )
            self.service.meetingASRPreparationOwnerForTesting = self.owner
        }

        func openAllGates() {
            self.retireGate.open()
            self.provider.openPrepareGate()
            self.drainGate.open()
        }

        func acquireMeetingLease() throws -> ASRActivityLease {
            let lease = try self.service.acquireExclusiveActivity(.meeting)
            self.registry.activate(lease)
            return lease
        }
    }

    private func makeHarness() -> Harness {
        let harness = Harness()
        self.addTeardownBlock { @MainActor in
            harness.openAllGates()
            if let token = harness.owner.currentClaimToken {
                await harness.owner.release(token)
            }
        }
        return harness
    }

    func testScopeRejectsWithoutActiveMeetingLease() async throws {
        let harness = self.makeHarness()

        do {
            _ = try await harness.service.withPreparedMeetingASR(
                attemptID: UUID(), configuration: MeetingFinalProcessingConfiguration()
            ) { _ in "ran" }
            XCTFail("Expected invalid lease rejection without an active lease")
        } catch let error as MeetingASRPreparationError {
            XCTAssertEqual(error, .invalidActivityLease)
        } catch {
            XCTFail("Expected MeetingASRPreparationError, got \(error)")
        }

        let dictationLease = try harness.service.acquireExclusiveActivity(.dictation)
        do {
            _ = try await harness.service.withPreparedMeetingASR(
                attemptID: UUID(), configuration: MeetingFinalProcessingConfiguration()
            ) { _ in "ran" }
            XCTFail("Expected invalid lease rejection for a dictation lease")
        } catch let error as MeetingASRPreparationError {
            XCTAssertEqual(error, .invalidActivityLease)
        } catch {
            XCTFail("Expected MeetingASRPreparationError, got \(error)")
        }
        harness.service.releaseExclusiveActivity(dictationLease)

        XCTAssertTrue(harness.recorder.events.isEmpty)
        XCTAssertFalse(harness.owner.isClaimed)
        XCTAssertEqual(harness.provider.prepareCalls, 0)
    }

    func testScopeSuccessPassesConfigurationThroughAndDrainsInOrder() async throws {
        let harness = self.makeHarness()
        let lease = try harness.acquireMeetingLease()
        let configuration = MeetingFinalProcessingConfiguration(diarizationFingerprint: "scope-test")

        let result = try await harness.service.withPreparedMeetingASR(
            attemptID: UUID(), configuration: configuration
        ) { provider in
            XCTAssertTrue(provider as AnyObject === harness.provider as AnyObject)
            return 42
        }

        XCTAssertEqual(result, 42)
        XCTAssertEqual(
            harness.recorder.events,
            ["retire", "factory:\(configuration.identityFingerprint)", "prepare", "drain"]
        )
        XCTAssertFalse(harness.owner.isClaimed)
        XCTAssertFalse(harness.owner.isDraining)

        // The scope never releases the caller's lease.
        XCTAssertThrowsError(try harness.service.acquireExclusiveActivity(.dictation)) { error in
            guard let activityError = error as? ASRActivityError,
                  case .activityInProgress(.meeting) = activityError
            else {
                return XCTFail("Expected meeting activity to still own the lease, got \(error)")
            }
        }
        harness.service.releaseExclusiveActivity(lease)
        let dictationLease = try harness.service.acquireExclusiveActivity(.dictation)
        harness.service.releaseExclusiveActivity(dictationLease)
    }

    func testScopeBodyErrorDrainsAndRethrowsAndClearsScope() async throws {
        let harness = self.makeHarness()
        _ = try harness.acquireMeetingLease()

        do {
            _ = try await harness.service.withPreparedMeetingASR(
                attemptID: UUID(), configuration: MeetingFinalProcessingConfiguration()
            ) { _ -> Int in
                throw ScopeBodyTestError.bodyFailed
            }
            XCTFail("Expected the body error to propagate")
        } catch ScopeBodyTestError.bodyFailed {
        } catch {
            XCTFail("Expected ScopeBodyTestError, got \(error)")
        }

        XCTAssertEqual(harness.recorder.events.last, "drain")
        XCTAssertFalse(harness.owner.isClaimed)

        // The scope cleared: a fresh scope prepares and runs again.
        let second = try await harness.service.withPreparedMeetingASR(
            attemptID: UUID(), configuration: MeetingFinalProcessingConfiguration()
        ) { _ in "second" }
        XCTAssertEqual(second, "second")
        XCTAssertEqual(harness.provider.prepareCalls, 2)
        XCTAssertEqual(harness.recorder.count(of: "drain"), 2)
        XCTAssertFalse(harness.owner.isClaimed)
    }

    func testScopeRejectsConcurrentCallerWhileBodyRuns() async throws {
        let harness = self.makeHarness()
        _ = try harness.acquireMeetingLease()
        let attemptID = UUID()
        let configuration = MeetingFinalProcessingConfiguration()
        let bodyEntered = ContinuationGate()
        let finishBody = ContinuationGate()

        let first = Task { @MainActor in
            try await harness.service.withPreparedMeetingASR(
                attemptID: attemptID, configuration: configuration
            ) { _ in
                bodyEntered.open()
                await finishBody.wait()
                return "first"
            }
        }
        let enteredObserved = await waitUntilCondition { bodyEntered.opened }
        XCTAssertTrue(enteredObserved)

        // Same attempt and configuration: the scope guard rejects before the owner could join.
        do {
            _ = try await harness.service.withPreparedMeetingASR(
                attemptID: attemptID, configuration: configuration
            ) { _ in "second" }
            XCTFail("Expected concurrent scope rejection")
        } catch let error as MeetingASRPreparationError {
            XCTAssertEqual(error, .preparationInProgress)
        } catch {
            XCTFail("Expected MeetingASRPreparationError, got \(error)")
        }
        XCTAssertEqual(harness.provider.prepareCalls, 1)

        finishBody.open()
        let firstResult = try await first.value
        XCTAssertEqual(firstResult, "first")
        XCTAssertEqual(harness.recorder.count(of: "drain"), 1)
        XCTAssertFalse(harness.owner.isClaimed)
    }

    func testScopeCancellationWithNonCooperativePrepareDrainsBeforeReturning() async throws {
        let harness = self.makeHarness()
        _ = try harness.acquireMeetingLease()
        let providerGate = ContinuationGate()
        let entered = ContinuationGate()
        harness.provider.blockPrepare(on: providerGate)
        harness.provider.onPrepareEntered { entered.open() }

        let scope = Task { @MainActor in
            try await harness.service.withPreparedMeetingASR(
                attemptID: UUID(), configuration: MeetingFinalProcessingConfiguration()
            ) { _ in "unreachable" }
        }
        let enteredObserved = await waitUntilCondition { entered.opened }
        XCTAssertTrue(enteredObserved)

        scope.cancel()
        // The fake prepare ignores cancellation: the claim stays until it returns.
        XCTAssertTrue(harness.owner.isClaimed)
        XCTAssertEqual(harness.recorder.count(of: "drain"), 0)

        providerGate.open()
        do {
            _ = try await scope.value
            XCTFail("Expected cancelled scope to throw")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(harness.recorder.count(of: "retire"), 1)
        XCTAssertEqual(harness.recorder.count(of: "drain"), 1)
        XCTAssertFalse(harness.owner.isClaimed)
        XCTAssertFalse(harness.owner.isDraining)
    }

    func testScopeCancellationDuringNonCooperativeBodySuppressesLateSuccess() async throws {
        let harness = self.makeHarness()
        _ = try harness.acquireMeetingLease()
        let bodyEntered = ContinuationGate()
        let finishBody = ContinuationGate()

        let scope = Task { @MainActor in
            try await harness.service.withPreparedMeetingASR(
                attemptID: UUID(), configuration: MeetingFinalProcessingConfiguration()
            ) { _ in
                bodyEntered.open()
                // Deliberately ignores cancellation until the test releases it.
                await finishBody.wait()
                return "late success"
            }
        }
        let enteredObserved = await waitUntilCondition { bodyEntered.opened }
        XCTAssertTrue(enteredObserved)

        scope.cancel()
        XCTAssertTrue(harness.owner.isClaimed)
        XCTAssertEqual(harness.recorder.count(of: "drain"), 0)

        finishBody.open()
        do {
            _ = try await scope.value
            XCTFail("Expected cancellation to suppress the body's late success")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertEqual(harness.recorder.count(of: "drain"), 1)
        XCTAssertFalse(harness.owner.isClaimed)
        XCTAssertFalse(harness.owner.isDraining)
    }

    func testTerminationCancelsAndJoinsNonCooperativeScopeBodyBeforeReleasingClaim() async throws {
        let harness = self.makeHarness()
        _ = try harness.acquireMeetingLease()
        let bodyEntered = ContinuationGate()
        let bodyCancellationObserved = ContinuationGate()
        let finishBody = ContinuationGate()
        let shutdownFinished = TestFlag()

        let scope = Task { @MainActor in
            try await harness.service.withPreparedMeetingASR(
                attemptID: UUID(), configuration: MeetingFinalProcessingConfiguration()
            ) { _ in
                bodyEntered.open()
                return await withTaskCancellationHandler {
                    await finishBody.wait()
                    return "late success"
                } onCancel: {
                    bodyCancellationObserved.open()
                }
            }
        }
        let didEnterBody = await waitUntilCondition { bodyEntered.opened }
        XCTAssertTrue(didEnterBody)

        let shutdown = Task { @MainActor in
            await harness.service.shutdownForTermination()
            shutdownFinished.set(true)
        }
        let didObserveCancellation = await waitUntilCondition { bodyCancellationObserved.opened }
        XCTAssertTrue(didObserveCancellation)

        // Cancellation was delivered, but shutdown remains joined to the deliberately
        // non-cooperative body and cannot clear its model claim early.
        XCTAssertFalse(shutdownFinished.value)
        XCTAssertTrue(harness.owner.isClaimed)

        finishBody.open()
        do {
            _ = try await scope.value
            XCTFail("Expected termination cancellation to suppress late success")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        await shutdown.value

        XCTAssertTrue(shutdownFinished.value)
        XCTAssertEqual(harness.recorder.count(of: "drain"), 1)
        XCTAssertFalse(harness.owner.isClaimed)
        XCTAssertFalse(harness.owner.isDraining)
    }

    func testLeaseReleaseRequestedDuringScopeDefersUntilJoinedDrain() async throws {
        let harness = self.makeHarness()
        let lease = try harness.acquireMeetingLease()
        let bodyEntered = ContinuationGate()
        let finishBody = ContinuationGate()

        let scope = Task { @MainActor in
            try await harness.service.withPreparedMeetingASR(
                attemptID: UUID(), configuration: MeetingFinalProcessingConfiguration()
            ) { _ in
                bodyEntered.open()
                await finishBody.wait()
                return "done"
            }
        }
        let enteredObserved = await waitUntilCondition { bodyEntered.opened }
        XCTAssertTrue(enteredObserved)

        // A mid-scope release request (as the meeting handback performs) must not hand
        // ownership to dictation while the scope owns the provider and executor.
        harness.service.releaseExclusiveActivity(lease)
        XCTAssertThrowsError(try harness.service.acquireExclusiveActivity(.dictation)) { error in
            guard let activityError = error as? ASRActivityError,
                  case .activityInProgress(.meeting) = activityError
            else {
                return XCTFail("Expected the meeting lease to survive mid-scope, got \(error)")
            }
        }
        XCTAssertTrue(harness.owner.isClaimed)

        finishBody.open()
        let result = try await scope.value
        XCTAssertEqual(result, "done")
        XCTAssertEqual(harness.recorder.count(of: "drain"), 1)

        // After the joined drain the deferred release flushed exactly that lease.
        let dictationLease = try harness.service.acquireExclusiveActivity(.dictation)
        harness.service.releaseExclusiveActivity(dictationLease)
        XCTAssertFalse(harness.owner.isClaimed)
    }

    func testMeetingTranscriptionEntryPointsRunWithinScopeAndUnclaimedLegacyPath() async throws {
        let harness = self.makeHarness()
        _ = try harness.acquireMeetingLease()
        let samples = [Float](repeating: 0, count: 16_000)

        let scopedText = try await harness.service.withPreparedMeetingASR(
            attemptID: UUID(), configuration: MeetingFinalProcessingConfiguration()
        ) { provider in
            try await harness.service.transcribeMeetingSamples(
                samples, provider: provider, languageCode: "en"
            ).text
        }
        XCTAssertEqual(scopedText, "")
        XCTAssertEqual(harness.recorder.count(of: "drain"), 1)

        // Unclaimed legacy meeting transcription still runs without any scope.
        let legacy = try await harness.service.transcribeMeetingSamples(
            samples, provider: harness.provider, languageCode: "en"
        )
        XCTAssertEqual(legacy.text, "")
    }

    func testRetireDictationResourcesRequiresExactLeaseAndDropsCachedProviders() async throws {
        let service = ASRService()
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = originalModel }
        settings.selectedSpeechModel = .parakeetTDT

        let lease = try service.acquireExclusiveActivity(.meeting)
        defer { service.releaseExclusiveActivity(lease) }
        let cached = service.fileTranscriptionProvider
        let cachedID = ObjectIdentifier(cached as AnyObject)

        // A stale or foreign meeting lease must not retire anything.
        let foreignLease = ASRActivityLease(id: UUID(), activity: .meeting)
        do {
            try await service.retireDictationASRResourcesForMeeting(lease: foreignLease)
            XCTFail("Expected stale lease rejection")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(ObjectIdentifier(service.fileTranscriptionProvider as AnyObject), cachedID)

        try await service.retireDictationASRResourcesForMeeting(lease: lease)
        XCTAssertFalse(service.isAsrReady)
        let recreated = service.fileTranscriptionProvider
        XCTAssertNotEqual(ObjectIdentifier(recreated as AnyObject), cachedID)
    }

    func testMeetingProviderConstructionIgnoresDictationPreferences() throws {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalBoosting = settings.vocabularyBoostingEnabled
        defer {
            settings.selectedSpeechModel = originalModel
            settings.vocabularyBoostingEnabled = originalBoosting
        }
        // Dictation preferences differ from the fixed meeting policy on every axis.
        settings.selectedSpeechModel = .parakeetTDT
        settings.vocabularyBoostingEnabled = true

        let provider = try FluidAudioProvider(meetingConfiguration: MeetingFinalProcessingConfiguration())
        XCTAssertEqual(provider.modelOverride, .parakeetTDTv2)
        #if DEBUG
            let options = provider.effectiveEnhancementOptionsForTesting
            XCTAssertFalse(options.experimentalUnifiedFinalEnabled)
            XCTAssertFalse(options.pronunciationMatchingEnabled)
            XCTAssertTrue(options.customDictionaryEntries.isEmpty)
        #endif
        // Dictation selection is untouched by meeting provider construction.
        XCTAssertEqual(settings.selectedSpeechModel, .parakeetTDT)
    }

    func testDictationReadinessAndDownloadsRejectedWhileScopeClaimed() async throws {
        let harness = self.makeHarness()
        _ = try harness.acquireMeetingLease()
        let bodyEntered = ContinuationGate()
        let finishBody = ContinuationGate()

        let scope = Task { @MainActor in
            try await harness.service.withPreparedMeetingASR(
                attemptID: UUID(), configuration: MeetingFinalProcessingConfiguration()
            ) { _ in
                bodyEntered.open()
                await finishBody.wait()
                return "done"
            }
        }
        let enteredObserved = await waitUntilCondition { bodyEntered.opened }
        XCTAssertTrue(enteredObserved)

        do {
            try await harness.service.ensureAsrReady()
            XCTFail("Expected ensureAsrReady rejection while the scope is claimed")
        } catch let error as MeetingASRPreparationError {
            XCTAssertEqual(error, .preparationInProgress)
        } catch {
            XCTFail("Expected MeetingASRPreparationError, got \(error)")
        }
        do {
            try await harness.service.downloadModel(.whisperBase, progressHandler: nil)
            XCTFail("Expected download rejection while the scope is claimed")
        } catch let error as MeetingASRPreparationError {
            XCTAssertEqual(error, .preparationInProgress)
        } catch {
            XCTFail("Expected MeetingASRPreparationError, got \(error)")
        }

        finishBody.open()
        _ = try await scope.value
        XCTAssertFalse(harness.owner.isClaimed)
    }
}
#endif
