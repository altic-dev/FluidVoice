import Combine
import CoreAudio
@testable import FluidVoice_Debug
import Foundation
import XCTest

final class DirectAudioReliabilityTests: XCTestCase {
    func testPipelineCorrelationIsInheritedAndRestoredAcrossConcurrentRequests() async {
        let original = DebugLogger.pipelineID
        let values = await withTaskGroup(of: String?.self, returning: [String?].self) { group in
            for id in ["pipeline-a", "pipeline-b"] {
                group.addTask {
                    await DebugLogger.$pipelineID.withValue(id) {
                        await Task.yield()
                        return await Task { DebugLogger.pipelineID }.value
                    }
                }
            }
            var values: [String?] = []
            for await value in group {
                values.append(value)
            }
            return values
        }
        XCTAssertEqual(Set(values.compactMap { $0 }), ["pipeline-a", "pipeline-b"])
        XCTAssertEqual(DebugLogger.pipelineID, original)
    }

    func testPipelineCorrelationCanCrossDispatchWithoutLeakingToNextWork() async {
        let values: [String?] = await DebugLogger.$pipelineID.withValue("pipeline-a") {
            let captured = DebugLogger.pipelineID
            return await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    let before = DebugLogger.pipelineID
                    let inside = DebugLogger.$pipelineID.withValue(captured) { DebugLogger.pipelineID }
                    let after = DebugLogger.pipelineID
                    continuation.resume(returning: [before, inside, after])
                }
            }
        }
        XCTAssertEqual(values, [nil, "pipeline-a", nil])
    }

    @MainActor
    func testAIStreamPreviewCoalescesBurstIntoOneMainActorUpdate() async {
        var publishedText: [String] = []
        let preview = DictationAIStreamPreviewBuffer(minimumUpdateInterval: 0, initialUpdateDelay: 0) { text in
            publishedText.append(text)
        }

        preview.append("Fluid")
        preview.append("Voice")
        preview.append(" benchmark")
        preview.flush()
        await Task.yield()

        XCTAssertEqual(publishedText, ["FluidVoice benchmark"])
    }

    @MainActor
    func testAIStreamPreviewFlushesShortGenerationWithoutQueuedUIWork() async {
        var publishedText: [String] = []
        let preview = DictationAIStreamPreviewBuffer(minimumUpdateInterval: 60, initialUpdateDelay: 60) { text in
            publishedText.append(text)
        }

        preview.append("Exact output")
        XCTAssertTrue(publishedText.isEmpty)

        preview.flush()
        preview.flush()
        await Task.yield()

        XCTAssertEqual(publishedText, ["Exact output"])
    }

    @MainActor
    func testAIStreamPreviewReturnsToNormalCadenceAfterStartupGrace() async {
        var publishedText: [String] = []
        let preview = DictationAIStreamPreviewBuffer(minimumUpdateInterval: 60, initialUpdateDelay: 0) { text in
            publishedText.append(text)
        }

        preview.append("First")
        await Task.yield()
        preview.append(" second")
        await Task.yield()

        XCTAssertEqual(publishedText, ["First"])
        preview.flush()
        XCTAssertEqual(publishedText, ["First", "First second"])
    }

    @MainActor
    func testCaptureSettledEventDoesNotInvalidateWholeASRService() {
        let service = ASRService()
        var settledEventCount = 0
        var objectChangeCount = 0
        let settledCancellable = service.audioCaptureStateDidSettle.sink {
            settledEventCount += 1
        }
        let objectCancellable = service.objectWillChange.sink {
            objectChangeCount += 1
        }

        service.audioCaptureStateDidSettle.send()

        XCTAssertEqual(settledEventCount, 1)
        XCTAssertEqual(objectChangeCount, 0)
        withExtendedLifetime((settledCancellable, objectCancellable)) {}
    }

    func testStopUIInvalidationGateFinishesExactlyOnce() {
        var gate = ASRStopUIInvalidationGate()

        XCTAssertFalse(gate.isDeferring)
        XCTAssertFalse(gate.finish())
        gate.begin()
        XCTAssertTrue(gate.isDeferring)
        XCTAssertTrue(gate.finish())
        XCTAssertFalse(gate.isDeferring)
        XCTAssertFalse(gate.finish())
    }

    func testStopUIInvalidationGateWaitsForOutputPipelineHold() {
        var gate = ASRStopUIInvalidationGate()

        gate.holdForOutputPipeline()
        gate.begin()

        XCTAssertFalse(gate.finish())
        XCTAssertTrue(gate.isDeferring)
        XCTAssertTrue(gate.releaseOutputPipelineHold())
        XCTAssertFalse(gate.isDeferring)
        XCTAssertFalse(gate.releaseOutputPipelineHold())
    }

    func testStopUIInvalidationGateForceFinishBoundsHeldPipeline() {
        var gate = ASRStopUIInvalidationGate()

        gate.holdForOutputPipeline()
        gate.begin()
        XCTAssertFalse(gate.finish())

        XCTAssertTrue(gate.forceFinish())
        XCTAssertFalse(gate.isDeferring)
        XCTAssertFalse(gate.forceFinish())
    }

    @MainActor
    func testFinalTranscriptionStatusRunsAfterDelay() async {
        var operationCount = 0
        let task = scheduleDeferredMainActorOperation(afterNanoseconds: 0) {
            operationCount += 1
        }

        await task.value

        XCTAssertEqual(operationCount, 1)
    }

    @MainActor
    func testCancelledFinalTranscriptionStatusHasNoSideEffect() async {
        var operationCount = 0
        let task = scheduleDeferredMainActorOperation(afterNanoseconds: 60_000_000_000) {
            operationCount += 1
        }

        task.cancel()
        await task.value

        XCTAssertEqual(operationCount, 0)
    }

    @MainActor
    func testDelayedFinalStatusCannotChangeANewerRecording() async {
        var currentSession = 7
        let stoppingSession = currentSession
        var overlay = "Recording"
        let staleTask = scheduleDeferredMainActorOperation(
            afterNanoseconds: 0,
            shouldRun: { currentSession == stoppingSession }
        ) { overlay = "Transcribing" }
        currentSession = 8
        await staleTask.value
        XCTAssertEqual(overlay, "Recording")

        let currentTask = scheduleDeferredMainActorOperation(
            afterNanoseconds: 0,
            shouldRun: { currentSession == 8 }
        ) { overlay = "Transcribing" }
        await currentTask.value
        XCTAssertEqual(overlay, "Transcribing")
    }

    @MainActor
    func testStalledStreamingDrainIsBoundedWithoutCancellingProvider() async {
        let lifecycle = StreamingTaskLifecycle()
        var providerContinuation: CheckedContinuation<Void, Never>?
        var providerWasCancelled = false
        var completions = 0
        lifecycle.schedule(sessionID: 7, delayNanoseconds: 0) { _ in
            await withCheckedContinuation { providerContinuation = $0 }
            providerWasCancelled = Task.isCancelled
        } completion: { _ in completions += 1 }
        while providerContinuation == nil {
            await Task.yield()
        }

        let completed = await lifecycle.drain(sessionID: 7, timeoutNanoseconds: 1_000_000)
        XCTAssertFalse(completed)
        XCTAssertTrue(lifecycle.hasActiveWork, "Timeout must retain the provider and its incremental state")
        XCTAssertEqual(lifecycle.pendingDrainCount, 0, "Timed-out waiters must be removed")
        XCTAssertEqual(completions, 0)
        XCTAssertFalse(lifecycle.schedule(sessionID: 8, delayNanoseconds: 0) { _ in
            XCTFail("A replacement must not race the stalled provider")
        } completion: { _ in })

        let resumedDrain = Task { @MainActor in
            await lifecycle.drain(sessionID: 7, timeoutNanoseconds: 60_000_000_000)
        }
        await Task.yield()
        providerContinuation?.resume()
        let recovered = await resumedDrain.value
        XCTAssertTrue(recovered)
        XCTAssertFalse(providerWasCancelled)
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(lifecycle.hasActiveWork)
        XCTAssertEqual(lifecycle.pendingDrainCount, 0, "Completion must retire its timer/waiter")
    }

    @MainActor
    func testTimedOutHandoffWakesStartsButKeepsBufferOwnedUntilRecovery() async throws {
        let gate = RecordingBufferHandoffGate()
        let token = try XCTUnwrap(gate.begin())
        var wokeInRecovery = false
        let waitingStart = Task { @MainActor in
            await gate.waitUntilAvailable()
            wokeInRecovery = gate.isRecovering
        }
        while gate.pendingWaiterCount == 0 {
            await Task.yield()
        }
        gate.markTimedOut(token)
        await waitingStart.value
        XCTAssertTrue(wokeInRecovery)
        XCTAssertTrue(gate.isActive)
        XCTAssertNil(gate.begin(), "Timeout must not release the PCM to another capture")
        XCTAssertEqual(gate.pendingWaiterCount, 0)

        let otherGate = RecordingBufferHandoffGate()
        let staleToken = try XCTUnwrap(otherGate.begin())
        gate.complete(staleToken)
        XCTAssertTrue(gate.isRecovering)
        gate.complete(token)
        XCTAssertFalse(gate.isRecovering)
        XCTAssertFalse(gate.isActive)
        let nextToken = try XCTUnwrap(gate.begin())
        gate.markTimedOut(token)
        XCTAssertFalse(gate.isRecovering, "An old timeout cannot affect a fresh recording")
        gate.complete(nextToken)
    }

    @MainActor
    func testStreamingIdleSchedulerCancelsWithoutLaunchingOrActiveDrain() async {
        let lifecycle = StreamingTaskLifecycle()
        var operationStarted = false

        XCTAssertTrue(lifecycle.schedule(
            sessionID: 7,
            delayNanoseconds: 60_000_000_000
        ) { _ in
            operationStarted = true
        } completion: { _ in })
        XCTAssertTrue(lifecycle.hasScheduledIdleWork)

        XCTAssertTrue(lifecycle.cancelScheduler())
        var mainActorSentinelRan = false
        let sentinelTask = Task { @MainActor in
            mainActorSentinelRan = true
        }
        let activeTask = lifecycle.activeTaskToDrain(sessionID: 7)

        XCTAssertNil(activeTask)
        XCTAssertFalse(mainActorSentinelRan, "An idle drain must not yield the main actor")
        await sentinelTask.value
        XCTAssertFalse(operationStarted)
        XCTAssertFalse(lifecycle.hasScheduledIdleWork)
        XCTAssertFalse(lifecycle.hasActiveWork)
    }

    @MainActor
    func testStreamingActiveWorkDrainsWithoutCancellation() async {
        let lifecycle = StreamingTaskLifecycle()
        var operationStarted = false
        var operationWasCancelled = false
        var operationContinuation: CheckedContinuation<Void, Never>?
        var completionCount = 0

        XCTAssertTrue(lifecycle.schedule(
            sessionID: 11,
            delayNanoseconds: 0
        ) { _ in
            operationStarted = true
            await withCheckedContinuation { continuation in
                operationContinuation = continuation
            }
            operationWasCancelled = Task.isCancelled
        } completion: { _ in
            completionCount += 1
        })

        while operationStarted == false {
            await Task.yield()
        }
        XCTAssertTrue(lifecycle.hasActiveWork)
        XCTAssertFalse(lifecycle.cancelScheduler())

        let drainTask = Task { @MainActor in
            await lifecycle.drain(sessionID: 11, timeoutNanoseconds: 60_000_000_000)
        }
        await Task.yield()
        XCTAssertEqual(completionCount, 0)

        operationContinuation?.resume()
        let drainedActiveWork = await drainTask.value
        XCTAssertTrue(drainedActiveWork)

        XCTAssertFalse(operationWasCancelled)
        XCTAssertEqual(completionCount, 1)
        XCTAssertFalse(lifecycle.hasActiveWork)
    }

    func testStreamingWorkStateRejectsStaleProviderAndOperationMutations() throws {
        var state = StreamingTranscriptionWorkState()
        state.beginSession(31)
        let firstOperation = UUID()
        let firstProviderGenerationValue = state.beginOperation(
            sessionID: 31,
            operationID: firstOperation
        )
        let firstProviderGeneration = try XCTUnwrap(firstProviderGenerationValue)
        XCTAssertTrue(state.canPublish(
            sessionID: 31,
            operationID: firstOperation,
            providerGeneration: firstProviderGeneration
        ))

        state.invalidateProvider()
        XCTAssertFalse(state.canPublish(
            sessionID: 31,
            operationID: firstOperation,
            providerGeneration: firstProviderGeneration
        ))
        XCTAssertTrue(state.finishOperation(sessionID: 31, operationID: firstOperation))

        let secondOperation = UUID()
        let secondProviderGeneration = state.beginOperation(
            sessionID: 31,
            operationID: secondOperation
        )
        _ = try XCTUnwrap(secondProviderGeneration)
        XCTAssertFalse(state.finishOperation(sessionID: 31, operationID: firstOperation))
        XCTAssertTrue(state.ownsOperation(sessionID: 31, operationID: secondOperation))

        XCTAssertTrue(state.finishOperation(sessionID: 31, operationID: secondOperation))
        state.endSession(31)
        state.beginSession(32)
        XCTAssertFalse(state.ownsOperation(sessionID: 31, operationID: secondOperation))
    }

    func testStreamingWorkStatePublishesOnlyForRunningCurrentSession() throws {
        var state = StreamingTranscriptionWorkState()
        state.beginSession(41)
        let operationID = UUID()
        let providerGeneration = try XCTUnwrap(state.beginOperation(
            sessionID: 41,
            operationID: operationID
        ))

        XCTAssertTrue(state.canPublishPreview(
            sessionID: 41,
            operationID: operationID,
            providerGeneration: providerGeneration,
            isRunning: true,
            schedulingSessionID: 41
        ))
        XCTAssertFalse(state.canPublishPreview(
            sessionID: 41,
            operationID: operationID,
            providerGeneration: providerGeneration,
            isRunning: false,
            schedulingSessionID: 41
        ))
        XCTAssertFalse(state.canPublishPreview(
            sessionID: 41,
            operationID: operationID,
            providerGeneration: providerGeneration,
            isRunning: true,
            schedulingSessionID: nil
        ))
        XCTAssertFalse(state.canPublishPreview(
            sessionID: 41,
            operationID: operationID,
            providerGeneration: providerGeneration,
            isRunning: true,
            schedulingSessionID: 42
        ))

        state.invalidateProvider()
        XCTAssertFalse(state.canPublishPreview(
            sessionID: 41,
            operationID: operationID,
            providerGeneration: providerGeneration,
            isRunning: true,
            schedulingSessionID: 41
        ))
    }

    @MainActor
    func testStoppedLateStreamingSuccessSkipsPreviewWorkAndStillDrains() async throws {
        let lifecycle = StreamingTaskLifecycle()
        var state = StreamingTranscriptionWorkState()
        state.beginSession(51)
        var isRunning = true
        var schedulingSessionID: Int? = 51
        var operationContinuation: CheckedContinuation<Void, Never>?
        var formatCount = 0
        var publishCount = 0
        var cleanupCount = 0
        var rearmCount = 0

        XCTAssertTrue(lifecycle.schedule(
            sessionID: 51,
            delayNanoseconds: 0
        ) { operationID in
            guard let providerGeneration = state.beginOperation(
                sessionID: 51,
                operationID: operationID
            ) else {
                XCTFail("Expected the late success operation to own the session")
                return
            }
            await withCheckedContinuation { continuation in
                operationContinuation = continuation
            }
            guard state.canPublishPreview(
                sessionID: 51,
                operationID: operationID,
                providerGeneration: providerGeneration,
                isRunning: isRunning,
                schedulingSessionID: schedulingSessionID
            ) else { return }
            formatCount += 1
            publishCount += 1
        } completion: { operationID in
            if state.finishOperation(sessionID: 51, operationID: operationID) {
                cleanupCount += 1
            }
            if isRunning, schedulingSessionID == 51 {
                rearmCount += 1
            }
        })

        while operationContinuation == nil {
            await Task.yield()
        }
        isRunning = false
        schedulingSessionID = nil
        let activeTask = try XCTUnwrap(lifecycle.activeTaskToDrain(sessionID: 51))
        operationContinuation?.resume()
        _ = await activeTask.result

        XCTAssertEqual(formatCount, 0)
        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(rearmCount, 0)
        XCTAssertFalse(lifecycle.hasActiveWork)
    }

    @MainActor
    func testStoppedLateStreamingFailureSkipsFailureMutationAndStillDrains() async throws {
        let lifecycle = StreamingTaskLifecycle()
        var state = StreamingTranscriptionWorkState()
        state.beginSession(52)
        var isRunning = true
        var schedulingSessionID: Int? = 52
        var operationContinuation: CheckedContinuation<Void, Never>?
        var fallbackCount = 0
        var failureMutationCount = 0
        var cleanupCount = 0
        var rearmCount = 0

        XCTAssertTrue(lifecycle.schedule(
            sessionID: 52,
            delayNanoseconds: 0
        ) { operationID in
            guard let providerGeneration = state.beginOperation(
                sessionID: 52,
                operationID: operationID
            ) else {
                XCTFail("Expected the late failure operation to own the session")
                return
            }
            await withCheckedContinuation { continuation in
                operationContinuation = continuation
            }
            guard state.canPublishPreview(
                sessionID: 52,
                operationID: operationID,
                providerGeneration: providerGeneration,
                isRunning: isRunning,
                schedulingSessionID: schedulingSessionID
            ) else { return }
            fallbackCount += 1
            failureMutationCount += 1
        } completion: { operationID in
            if state.finishOperation(sessionID: 52, operationID: operationID) {
                cleanupCount += 1
            }
            if isRunning, schedulingSessionID == 52 {
                rearmCount += 1
            }
        })

        while operationContinuation == nil {
            await Task.yield()
        }
        isRunning = false
        schedulingSessionID = nil
        let activeTask = try XCTUnwrap(lifecycle.activeTaskToDrain(sessionID: 52))
        operationContinuation?.resume()
        _ = await activeTask.result

        XCTAssertEqual(fallbackCount, 0)
        XCTAssertEqual(failureMutationCount, 0)
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(rearmCount, 0)
        XCTAssertFalse(lifecycle.hasActiveWork)
    }

    @MainActor
    func testCancelledPendingStartWakesWithoutCompletingBufferHandoff() async throws {
        let gate = RecordingBufferHandoffGate()
        let token = try XCTUnwrap(gate.begin())
        var waiterReturned = false
        let waiter = Task { @MainActor in
            await gate.waitUntilAvailable()
            waiterReturned = true
        }
        while gate.pendingWaiterCount == 0 {
            await Task.yield()
        }
        XCTAssertFalse(waiterReturned)

        gate.releasePendingWaiters()
        await waiter.value

        XCTAssertTrue(waiterReturned)
        XCTAssertTrue(gate.isActive)
        gate.complete(token)
        XCTAssertFalse(gate.isActive)
    }

    @MainActor
    func testBufferHandoffRejectsStaleCompletionAndReleasesOnOwnerCompletion() async throws {
        let gate = RecordingBufferHandoffGate()
        let ownerToken = try XCTUnwrap(gate.begin())
        let otherGate = RecordingBufferHandoffGate()
        let staleToken = try XCTUnwrap(otherGate.begin())
        var waiterReturned = false
        let waiter = Task { @MainActor in
            await gate.waitUntilAvailable()
            waiterReturned = true
        }
        while gate.pendingWaiterCount == 0 {
            await Task.yield()
        }

        gate.complete(staleToken)
        XCTAssertTrue(gate.isActive)
        XCTAssertFalse(waiterReturned)

        gate.complete(ownerToken)
        await waiter.value
        XCTAssertTrue(waiterReturned)
        XCTAssertFalse(gate.isActive)
    }

    @MainActor
    func testStreamingLifecycleContinuesCadenceAfterOperationCompletion() async {
        let lifecycle = StreamingTaskLifecycle()
        var operationCount = 0
        var completionCount = 0

        XCTAssertTrue(lifecycle.schedule(
            sessionID: 19,
            delayNanoseconds: 0
        ) { _ in
            operationCount += 1
        } completion: { _ in
            completionCount += 1
            _ = lifecycle.schedule(
                sessionID: 19,
                delayNanoseconds: 0
            ) { _ in
                operationCount += 1
            } completion: { _ in
                completionCount += 1
            }
        })

        while completionCount < 2 {
            await Task.yield()
        }
        XCTAssertEqual(operationCount, 2)
        XCTAssertEqual(completionCount, 2)
        XCTAssertFalse(lifecycle.hasScheduledIdleWork)
        XCTAssertFalse(lifecycle.hasActiveWork)
    }

    func testCaptureStoppedCallbackDoesNotReenqueueOnMainActor() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Fluid/Services/ASRService.swift"),
            encoding: .utf8
        )
        let callbackSection = try XCTUnwrap(
            source.components(separatedBy: "capture_stopped_callback_request").last?
                .components(separatedBy: "capture_stopped_callback_return").first
        )

        XCTAssertTrue(callbackSection.contains("onCaptureStopped?()"))
        XCTAssertFalse(callbackSection.contains("await "))
        XCTAssertFalse(callbackSection.contains("Task {"))
    }

    func testNormalOutputDismissesOverlayInPasteDispatchTurn() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Fluid/ContentView.swift"),
            encoding: .utf8
        )
        let normalOutputSection = try XCTUnwrap(
            source.components(separatedBy: "if spokenSendAllowed {").last?
                .components(separatedBy: "if spokenSendRequested, !spokenSendAllowed").first
        )
        let pasteIndex = try XCTUnwrap(normalOutputSection.range(of: "typeOutputPlanToActiveField("))
        let deliveryCompletionIndex = try XCTUnwrap(normalOutputSection.range(of: "completion: { outcome in"))
        let deliveryHandlerIndex = try XCTUnwrap(normalOutputSection.range(of: "self.handleTypingDelivery("))

        XCTAssertLessThan(pasteIndex.lowerBound, deliveryCompletionIndex.lowerBound)
        XCTAssertLessThan(deliveryCompletionIndex.lowerBound, deliveryHandlerIndex.lowerBound)
        let hideIndex = try XCTUnwrap(normalOutputSection.range(of: "self.hideOverlayForDispatchedPaste("))
        XCTAssertLessThan(deliveryHandlerIndex.lowerBound, hideIndex.lowerBound)
        let dispatchHideSection = try XCTUnwrap(source.components(separatedBy: "private func hideOverlayForDispatchedPaste(").last?.components(separatedBy: "private func handleTypingDelivery(").first)
        XCTAssertTrue(dispatchHideSection.contains("reason=paste_dispatched"))
        XCTAssertTrue(dispatchHideSection.contains("self.overlayLifecycleID == lifecycleID"))
        XCTAssertFalse(dispatchHideSection.contains("Task {"))
        XCTAssertFalse(normalOutputSection.contains("Task { @MainActor in"))
        XCTAssertFalse(
            normalOutputSection[pasteIndex.lowerBound..<deliveryHandlerIndex.lowerBound]
                .contains("updateTranscriptionText(\"\")")
        )

        let deliveryHandlerSection = try XCTUnwrap(
            source.components(separatedBy: "private func handleTypingDelivery(").last?
                .components(separatedBy: "private func hideOverlayAfterOutput()").first
        )
        XCTAssertTrue(deliveryHandlerSection.contains("self.overlayLifecycleID == expectedOverlayLifecycleID"))
        XCTAssertTrue(normalOutputSection.contains("shouldHideOverlay: shouldHideOverlayAfterDelivery && spokenSendRequested"))
        XCTAssertTrue(normalOutputSection.contains("shouldHide: shouldHideOverlayAfterDelivery && !spokenSendRequested"))
        XCTAssertTrue(deliveryHandlerSection.contains("guard shouldHideOverlay else { return }"))
        XCTAssertFalse(deliveryHandlerSection.contains("await self.menuBarManager.beginProcessingCompletionAndHideOverlay"))

        let menuBarSource = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Fluid/Services/MenuBarManager.swift"),
            encoding: .utf8
        )
        let completionSection = try XCTUnwrap(
            menuBarSource.components(separatedBy: "func beginProcessingCompletionAndHideOverlay() {").last?
                .components(separatedBy: "func finishProcessingAndHideOverlay() async {").first
        )
        XCTAssertTrue(completionSection.contains("NotchOverlayManager.shared.hideImmediately()"))
        XCTAssertFalse(completionSection.contains("NotchOverlayManager.shared.hide()"))

        let postStopSection = try XCTUnwrap(
            source.components(separatedBy: "let transcribedText = await asr.stop").last?
                .components(separatedBy: "guard transcribedText.trimmingCharacters").first
        )
        XCTAssertFalse(postStopSection.contains("updateTranscriptionText(\"\")"))
    }

    func testSlowAIStatusAndPreviewAreScopedToCurrentOverlayLifecycle() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Fluid/ContentView.swift"),
            encoding: .utf8
        )
        let slowStatusSection = try XCTUnwrap(
            source.components(separatedBy: "private func makeAIProcessingFeedback(").last?
                .components(separatedBy: "private func prepareOverlayForASRStop(").first
        )

        XCTAssertTrue(slowStatusSection.contains("self.overlayLifecycleID == lifecycleID"))
        XCTAssertTrue(slowStatusSection.contains("self.menuBarManager.setProcessing(true)"))
        XCTAssertTrue(slowStatusSection.contains("let streamPreview = DictationAIStreamPreviewBuffer"))

        let stopSection = try XCTUnwrap(
            source.components(separatedBy: "private func stopAndProcessTranscription(").last?
                .components(separatedBy: "private func makeAIProcessingFeedback(").first
        )
        let lifecycleSnapshotIndex = try XCTUnwrap(
            stopSection.range(of: "let expectedOverlayLifecycleID = self.overlayLifecycleID")
        )
        let ASRStopIndex = try XCTUnwrap(stopSection.range(of: "let transcribedText = await asr.stop"))
        XCTAssertLessThan(lifecycleSnapshotIndex.lowerBound, ASRStopIndex.lowerBound)
        XCTAssertEqual(
            stopSection.components(separatedBy: "let expectedOverlayLifecycleID = self.overlayLifecycleID").count,
            2
        )
    }

    func testDictionaryTrackingStartsAfterDeliveryCallbackReturns() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Fluid/Services/TypingService.swift"),
            encoding: .utf8
        )
        let completionSection = try XCTUnwrap(
            source.components(separatedBy: "let completedOutcome = outcome").last?
                .components(separatedBy: "self.log(\"[TypingService] Starting async text insertion process\")").first
        )
        let callbackIndex = try XCTUnwrap(completionSection.range(of: "completion?(completedOutcome)"))
        let trackingIndex = try XCTUnwrap(
            completionSection.range(of: "AutomaticDictionaryCorrectionTracker.shared.beginObservingInsertion")
        )

        XCTAssertLessThan(callbackIndex.lowerBound, trackingIndex.lowerBound)
        XCTAssertTrue(completionSection.contains("completedOutcome.didInsert"))
        XCTAssertTrue(completionSection.contains("dictionary_tracking_scheduled afterDeliveryCallback=true"))
    }

    func testOutputKeepAliveStartsBuiltInOutputForAppleSiliconInternalInput() {
        var startedDevices: [AudioObjectID] = []

        let deviceID = BuiltInOutputKeepAlivePolicy.start(
            inputDeviceID: 100,
            devices: [Self.internalMicrophone, Self.builtInSpeaker(id: 200)],
            isAppleSilicon: true,
            startDevice: {
                startedDevices.append($0)
                return noErr
            }
        )

        XCTAssertEqual(deviceID, 200)
        XCTAssertEqual(startedDevices, [200])
    }

    func testOutputKeepAliveLeavesIntelAndOtherInputsUntouched() {
        let devices = [
            Self.internalMicrophone,
            Self.externalMicrophone,
            Self.builtInSpeaker(id: 200),
        ]
        var startedDevices: [AudioObjectID] = []
        let startDevice: (AudioObjectID) -> OSStatus = {
            startedDevices.append($0)
            return noErr
        }

        XCTAssertNil(BuiltInOutputKeepAlivePolicy.start(
            inputDeviceID: 100,
            devices: devices,
            isAppleSilicon: false,
            startDevice: startDevice
        ))
        XCTAssertNil(BuiltInOutputKeepAlivePolicy.start(
            inputDeviceID: 101,
            devices: devices,
            isAppleSilicon: true,
            startDevice: startDevice
        ))
        XCTAssertTrue(startedDevices.isEmpty)
    }

    func testOutputKeepAliveReturnsNilWhenBuiltInOutputsFailToStart() {
        var startedDevices: [AudioObjectID] = []

        let deviceID = BuiltInOutputKeepAlivePolicy.start(
            inputDeviceID: 100,
            devices: [
                Self.internalMicrophone,
                Self.builtInSpeaker(id: 200),
                Self.builtInSpeaker(id: 201),
            ],
            isAppleSilicon: true,
            startDevice: {
                startedDevices.append($0)
                return kAudioHardwareNotReadyError
            }
        )

        XCTAssertNil(deviceID)
        XCTAssertEqual(startedDevices, [200, 201])
    }

    func testReadinessGatePreservesFirstPCMThatArrivesBeforeWait() async {
        let gate = AudioCaptureReadinessGate()
        gate.arm(sessionID: 41, attemptID: 1)
        gate.signalFirstPCM(sessionID: 41, attemptID: 1)

        let result = await gate.wait(
            sessionID: 41,
            attemptID: 1,
            timeoutNanoseconds: 1_000_000
        )

        XCTAssertEqual(result, .ready)
    }

    func testReadinessGateCancelsWaitAndIgnoresStalePCM() async {
        let gate = AudioCaptureReadinessGate()
        gate.arm(sessionID: 41, attemptID: 1)
        let firstWait = Task {
            await gate.wait(
                sessionID: 41,
                attemptID: 1,
                timeoutNanoseconds: 1_000_000_000
            )
        }
        await Task.yield()
        gate.cancel(sessionID: 41, attemptID: 1)
        let firstResult = await firstWait.value
        XCTAssertEqual(firstResult, .cancelled)

        gate.arm(sessionID: 41, attemptID: 2)
        gate.signalFirstPCM(sessionID: 41, attemptID: 1)
        let staleResult = await gate.wait(
            sessionID: 41,
            attemptID: 1,
            timeoutNanoseconds: 1_000_000
        )
        XCTAssertEqual(staleResult, .staleSession)

        gate.signalFirstPCM(sessionID: 41, attemptID: 2)
        let replacementResult = await gate.wait(
            sessionID: 41,
            attemptID: 2,
            timeoutNanoseconds: 1_000_000
        )
        XCTAssertEqual(replacementResult, .ready)
    }

    func testReadinessGateRearmingCancelsExistingWaiter() async {
        let gate = AudioCaptureReadinessGate()
        gate.arm(sessionID: 41, attemptID: 1)
        let firstWait = Task {
            await gate.wait(
                sessionID: 41,
                attemptID: 1,
                timeoutNanoseconds: 10_000_000_000
            )
        }
        for _ in 0..<100 where !gate.hasRegisteredWaiter(sessionID: 41, attemptID: 1) {
            await Task.yield()
        }
        XCTAssertTrue(gate.hasRegisteredWaiter(sessionID: 41, attemptID: 1))

        gate.arm(sessionID: 41, attemptID: 2)

        let firstResult = await firstWait.value
        XCTAssertEqual(firstResult, .cancelled)
        gate.signalFirstPCM(sessionID: 41, attemptID: 2)
        let replacementResult = await gate.wait(
            sessionID: 41,
            attemptID: 2,
            timeoutNanoseconds: 1_000_000
        )
        XCTAssertEqual(replacementResult, .ready)
    }

    func testReadinessGateTimesOutWithoutPCM() async {
        let gate = AudioCaptureReadinessGate()
        gate.arm(sessionID: 41, attemptID: 1)

        let result = await gate.wait(
            sessionID: 41,
            attemptID: 1,
            timeoutNanoseconds: 1_000_000
        )

        XCTAssertEqual(result, .timedOut)
    }

    func testReadinessWaitRespondsPromptlyToTaskCancellation() async {
        let gate = AudioCaptureReadinessGate()
        gate.arm(sessionID: 41, attemptID: 1)
        let waitTask = Task {
            await gate.wait(
                sessionID: 41,
                attemptID: 1,
                timeoutNanoseconds: 10_000_000_000
            )
        }
        await Task.yield()

        let cancelledAt = ProcessInfo.processInfo.systemUptime
        waitTask.cancel()
        let result = await waitTask.value
        let cancellationMilliseconds =
            (ProcessInfo.processInfo.systemUptime - cancelledAt) * 1000

        XCTAssertEqual(result, .cancelled)
        XCTAssertLessThan(cancellationMilliseconds, 100)
    }

    func testFingerprintMismatchInvalidatesOldCaptureBeforeStartingReplacement() async throws {
        let oldFingerprint = makeFingerprint(sampleRate: 48_000, bufferFrameSize: 512)
        let newFingerprint = makeFingerprint(sampleRate: 24_000, bufferFrameSize: 256)
        let recorder = DirectAudioEventRecorder()
        let factory = FakeDirectAudioInputFactory(
            fingerprints: [oldFingerprint, newFingerprint],
            recorder: recorder
        )
        let fingerprintReader = ScriptedFingerprintReader(
            values: [
                oldFingerprint,
                oldFingerprint,
                oldFingerprint,
                newFingerprint,
                newFingerprint,
                newFingerprint,
                newFingerprint,
            ]
        )
        let controller = DirectCoreAudioLifecycleController(
            packetHandler: { _, _, _, _, _ in },
            inputFactory: { deviceID, _ in
                try factory.make(deviceID: deviceID)
            },
            fingerprintReader: { _ in
                try fingerprintReader.read()
            },
            installsHardwareListeners: false,
            onFormatInvalidated: { _ in }
        )

        _ = try await controller.prepare(
            deviceID: oldFingerprint.deviceID,
            deviceName: "Test microphone",
            reason: "test_prewarm"
        )
        let running = try await controller.start(
            deviceID: oldFingerprint.deviceID,
            deviceName: "Test microphone",
            reason: "test_start"
        )
        await controller.shutdown(reason: "test_complete")

        XCTAssertEqual(running.fingerprint, newFingerprint)
        XCTAssertEqual(
            recorder.events,
            [
                "make:48000",
                "invalidate:48000",
                "make:24000",
                "start:24000",
                "invalidate:24000",
            ]
        )
        XCTAssertFalse(recorder.events.contains("start:48000"))
        XCTAssertTrue(recorder.executedOnlyOffMain)
        XCTAssertEqual(recorder.maximumConcurrentOperations, 1)
    }

    func testPrepareRollsBackWhenPostInstallFingerprintReadFails() async throws {
        let fingerprint = makeFingerprint(sampleRate: 48_000, bufferFrameSize: 512)
        let recorder = DirectAudioEventRecorder()
        let factory = FakeDirectAudioInputFactory(
            fingerprints: [fingerprint],
            recorder: recorder
        )
        let fingerprintReader = ScriptedFingerprintReader(values: [fingerprint])
        let controller = DirectCoreAudioLifecycleController(
            packetHandler: { _, _, _, _, _ in },
            inputFactory: { deviceID, _ in
                try factory.make(deviceID: deviceID)
            },
            fingerprintReader: { _ in
                try fingerprintReader.read()
            },
            installsHardwareListeners: false,
            onFormatInvalidated: { _ in }
        )

        do {
            _ = try await controller.prepare(
                deviceID: fingerprint.deviceID,
                deviceName: "Test microphone",
                reason: "test_prepare_failure"
            )
            XCTFail("Expected the final fingerprint read to fail.")
        } catch {
            XCTAssertEqual(controller.snapshot.phase, .empty)
            XCTAssertEqual(
                recorder.events,
                ["make:48000", "invalidate:48000"]
            )
        }
    }

    func testConcurrentLifecycleCommandsNeverOverlap() async throws {
        let fingerprint = makeFingerprint(sampleRate: 48_000, bufferFrameSize: 512)
        let recorder = DirectAudioEventRecorder(operationDelayMicroseconds: 2000)
        let factory = FakeDirectAudioInputFactory(
            fingerprints: [fingerprint],
            recorder: recorder
        )
        let controller = DirectCoreAudioLifecycleController(
            packetHandler: { _, _, _, _, _ in },
            inputFactory: { deviceID, _ in
                try factory.make(deviceID: deviceID)
            },
            fingerprintReader: { _ in fingerprint },
            installsHardwareListeners: false,
            onFormatInvalidated: { _ in }
        )
        _ = try await controller.prepare(
            deviceID: fingerprint.deviceID,
            deviceName: "Test microphone",
            reason: "test_prepare"
        )

        let commands = (0..<12).map { index in
            Task {
                if index.isMultiple(of: 2) {
                    _ = try? await controller.start(
                        deviceID: fingerprint.deviceID,
                        deviceName: "Test microphone",
                        reason: "concurrent_start"
                    )
                } else {
                    _ = await controller.stop(
                        retainPrepared: true,
                        reason: "concurrent_stop"
                    )
                }
            }
        }
        for command in commands {
            await command.value
        }
        await controller.shutdown(reason: "test_complete")

        XCTAssertTrue(recorder.executedOnlyOffMain)
        XCTAssertEqual(recorder.maximumConcurrentOperations, 1)
    }

    func testStartingRunningInputReusesHardwareWithoutStopOrRestart() async throws {
        let fingerprint = makeFingerprint(sampleRate: 48_000, bufferFrameSize: 512)
        let recorder = DirectAudioEventRecorder()
        let factory = FakeDirectAudioInputFactory(
            fingerprints: [fingerprint],
            recorder: recorder
        )
        let controller = DirectCoreAudioLifecycleController(
            packetHandler: { _, _, _, _, _ in },
            inputFactory: { deviceID, _ in
                try factory.make(deviceID: deviceID)
            },
            fingerprintReader: { _ in fingerprint },
            installsHardwareListeners: false,
            onFormatInvalidated: { _ in }
        )

        _ = try await controller.start(
            deviceID: fingerprint.deviceID,
            deviceName: "Test microphone",
            reason: "preview"
        )
        let reused = try await controller.start(
            deviceID: fingerprint.deviceID,
            deviceName: "Test microphone",
            reason: "dictation_handoff"
        )
        await controller.shutdown(reason: "test_complete")

        XCTAssertEqual(reused.phase, .running)
        XCTAssertEqual(
            recorder.events,
            ["make:48000", "start:48000", "invalidate:48000"]
        )
    }

    func testCancelledStopStillStopsHardwareAndRetainsPreparedInput() async throws {
        let fingerprint = makeFingerprint(sampleRate: 48_000, bufferFrameSize: 512)
        let recorder = DirectAudioEventRecorder(operationDelayMicroseconds: 2000)
        let factory = FakeDirectAudioInputFactory(
            fingerprints: [fingerprint],
            recorder: recorder
        )
        let controller = DirectCoreAudioLifecycleController(
            packetHandler: { _, _, _, _, _ in },
            inputFactory: { deviceID, _ in
                try factory.make(deviceID: deviceID)
            },
            fingerprintReader: { _ in fingerprint },
            installsHardwareListeners: false,
            onFormatInvalidated: { _ in }
        )
        _ = try await controller.start(
            deviceID: fingerprint.deviceID,
            deviceName: "Test microphone",
            reason: "test_start"
        )

        let stopTask = Task {
            await controller.stop(
                retainPrepared: true,
                reason: "cancelled_waiter"
            )
        }
        stopTask.cancel()
        let report = await stopTask.value

        XCTAssertEqual(report.status, noErr)
        XCTAssertTrue(report.retainedPreparedCapture)
        XCTAssertEqual(controller.snapshot.phase, .prepared)
        XCTAssertEqual(recorder.events, ["make:48000", "start:48000", "stop:48000"])
        await controller.shutdown(reason: "test_complete")
    }

    func testSequentialStopStartReusesInputOnlyAfterStopCompletes() async throws {
        let fingerprint = makeFingerprint(sampleRate: 48_000, bufferFrameSize: 512)
        let recorder = DirectAudioEventRecorder(operationDelayMicroseconds: 2000)
        let factory = FakeDirectAudioInputFactory(
            fingerprints: [fingerprint],
            recorder: recorder
        )
        let controller = DirectCoreAudioLifecycleController(
            packetHandler: { _, _, _, _, _ in },
            inputFactory: { deviceID, _ in
                try factory.make(deviceID: deviceID)
            },
            fingerprintReader: { _ in fingerprint },
            installsHardwareListeners: false,
            onFormatInvalidated: { _ in }
        )
        _ = try await controller.start(
            deviceID: fingerprint.deviceID,
            deviceName: "Test microphone",
            reason: "first_start"
        )

        _ = await controller.stop(retainPrepared: true, reason: "first_stop")
        _ = try await controller.start(
            deviceID: fingerprint.deviceID,
            deviceName: "Test microphone",
            reason: "second_start"
        )
        _ = await controller.stop(retainPrepared: true, reason: "second_stop")

        XCTAssertEqual(controller.snapshot.phase, .prepared)
        XCTAssertEqual(
            recorder.events,
            ["make:48000", "start:48000", "stop:48000", "start:48000", "stop:48000"]
        )
        XCTAssertEqual(recorder.maximumConcurrentOperations, 1)
        await controller.shutdown(reason: "test_complete")
    }

    func testFailedStopPoisonsLifecycleAndPreventsReplacement() async throws {
        let fingerprint = makeFingerprint(sampleRate: 48_000, bufferFrameSize: 512)
        let recorder = DirectAudioEventRecorder()
        let input = FailingStopDirectAudioInput(
            fingerprint: fingerprint,
            recorder: recorder
        )
        let controller = DirectCoreAudioLifecycleController(
            packetHandler: { _, _, _, _, _ in },
            inputFactory: { _, _ in input },
            fingerprintReader: { _ in fingerprint },
            installsHardwareListeners: false,
            onFormatInvalidated: { _ in }
        )
        _ = try await controller.start(
            deviceID: fingerprint.deviceID,
            deviceName: "Test microphone",
            reason: "test_start"
        )

        let report = await controller.stop(
            retainPrepared: true,
            reason: "test_stop_failure"
        )

        XCTAssertNotEqual(report.status, noErr)
        XCTAssertFalse(report.retainedPreparedCapture)
        XCTAssertEqual(controller.snapshot.phase, .failed)
        do {
            _ = try await controller.prepare(
                deviceID: fingerprint.deviceID,
                deviceName: "Replacement microphone",
                reason: "must_not_replace"
            )
            XCTFail("A poisoned lifecycle must not create a replacement.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("poisoned"))
        }
        XCTAssertEqual(recorder.events, ["start:48000", "stop_failed", "quarantine"])
    }

    func testFailedReplacementTeardownDoesNotCreateConcurrentInput() async throws {
        let oldFingerprint = makeFingerprint(sampleRate: 48_000, bufferFrameSize: 512)
        let newFingerprint = makeFingerprint(sampleRate: 24_000, bufferFrameSize: 256)
        let recorder = DirectAudioEventRecorder()
        let factory = FailingReplacementFactory(
            fingerprint: oldFingerprint,
            recorder: recorder
        )
        let fingerprintReader = ScriptedFingerprintReader(
            values: [oldFingerprint, oldFingerprint, newFingerprint]
        )
        let controller = DirectCoreAudioLifecycleController(
            packetHandler: { _, _, _, _, _ in },
            inputFactory: { deviceID, _ in
                factory.make(deviceID: deviceID)
            },
            fingerprintReader: { _ in
                try fingerprintReader.read()
            },
            installsHardwareListeners: false,
            onFormatInvalidated: { _ in }
        )

        _ = try await controller.prepare(
            deviceID: oldFingerprint.deviceID,
            deviceName: "Old microphone",
            reason: "test_initial_prepare"
        )

        do {
            _ = try await controller.prepare(
                deviceID: newFingerprint.deviceID,
                deviceName: "Replacement microphone",
                reason: "test_failed_replacement"
            )
            XCTFail("A failed teardown must prevent replacement creation.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("poisoned"))
        }

        XCTAssertEqual(controller.snapshot.phase, .failed)
        XCTAssertEqual(factory.creationCount, 1)
        XCTAssertEqual(recorder.events, ["quarantine"])
    }

    func testDeviceRemovalFailureQuarantinesOldInputAndAllowsReplacement() async throws {
        let oldFingerprint = makeFingerprint(sampleRate: 48_000, bufferFrameSize: 512)
        let newFingerprint = makeFingerprint(sampleRate: 24_000, bufferFrameSize: 256)
        let recorder = DirectAudioEventRecorder()
        let factory = RecoveringAfterStoppedHardwareFactory(
            oldFingerprint: oldFingerprint,
            newFingerprint: newFingerprint,
            recorder: recorder
        )
        let fingerprintReader = ScriptedFingerprintReader(
            values: [oldFingerprint, oldFingerprint, newFingerprint, newFingerprint]
        )
        let controller = DirectCoreAudioLifecycleController(
            packetHandler: { _, _, _, _, _ in },
            inputFactory: { deviceID, _ in
                factory.make(deviceID: deviceID)
            },
            fingerprintReader: { _ in
                try fingerprintReader.read()
            },
            installsHardwareListeners: false,
            onFormatInvalidated: { _ in }
        )

        _ = try await controller.prepare(
            deviceID: oldFingerprint.deviceID,
            deviceName: "Old microphone",
            reason: "test_initial_prepare"
        )
        await controller.invalidate(reason: "teardown_before_notification")
        XCTAssertEqual(controller.snapshot.phase, .failed)
        await controller.simulateStoppedHardwareNotificationForTesting(
            generation: controller.snapshot.generation,
            reason: "device_is_alive"
        )
        let replacement = try await controller.prepare(
            deviceID: newFingerprint.deviceID,
            deviceName: "Replacement microphone",
            reason: "test_recovery"
        )

        XCTAssertEqual(replacement.phase, .prepared)
        XCTAssertEqual(replacement.fingerprint, newFingerprint)
        XCTAssertEqual(factory.creationCount, 2)
        XCTAssertEqual(recorder.events, ["quarantine", "make:24000"])
        await controller.shutdown(reason: "test_complete")
    }

    private static let internalMicrophone = AudioDevice.Device(
        id: 100,
        uid: "BuiltInMicrophoneDevice",
        name: "MacBook Pro Microphone",
        hasInput: true,
        hasOutput: false,
        transportType: kAudioDeviceTransportTypeBuiltIn
    )

    private static let externalMicrophone = AudioDevice.Device(
        id: 101,
        uid: "ExternalMicrophoneDevice",
        name: "USB Microphone",
        hasInput: true,
        hasOutput: false,
        transportType: kAudioDeviceTransportTypeUSB
    )

    private static func builtInSpeaker(id: AudioObjectID) -> AudioDevice.Device {
        AudioDevice.Device(
            id: id,
            uid: "BuiltInSpeakerDevice",
            name: "MacBook Pro Speakers",
            hasInput: false,
            hasOutput: true,
            transportType: kAudioDeviceTransportTypeBuiltIn
        )
    }
}

private nonisolated func makeFingerprint(
    sampleRate: Double,
    bufferFrameSize: UInt32
) -> DirectCoreAudioFormatFingerprint {
    DirectCoreAudioFormatFingerprint(
        deviceID: 7001,
        streamID: 7002,
        virtualFormat: DirectCoreAudioStreamFormatFingerprint(
            AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 32,
                mReserved: 0
            )
        ),
        physicalFormat: nil,
        inputBufferChannels: [1],
        nominalSampleRate: sampleRate,
        bufferFrameSize: bufferFrameSize,
        variableBufferFrameSizeMaximum: nil,
        dataSourceID: nil
    )
}

private final nonisolated class FakeDirectAudioInputFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var fingerprints: [DirectCoreAudioFormatFingerprint]
    private let recorder: DirectAudioEventRecorder

    init(
        fingerprints: [DirectCoreAudioFormatFingerprint],
        recorder: DirectAudioEventRecorder
    ) {
        self.fingerprints = fingerprints
        self.recorder = recorder
    }

    func make(deviceID: AudioObjectID) throws -> any DirectCoreAudioInputControlling {
        try self.lock.withLock {
            guard self.fingerprints.isEmpty == false else {
                throw NSError(
                    domain: "DirectAudioReliabilityTests",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No fake input remains."]
                )
            }
            let fingerprint = self.fingerprints.removeFirst()
            self.recorder.record("make:\(Int(fingerprint.virtualFormat.sampleRate))")
            return FakeDirectAudioInput(
                deviceID: deviceID,
                fingerprint: fingerprint,
                recorder: self.recorder
            )
        }
    }
}

private final nonisolated class ScriptedFingerprintReader: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DirectCoreAudioFormatFingerprint]

    init(values: [DirectCoreAudioFormatFingerprint]) {
        self.values = values
    }

    func read() throws -> DirectCoreAudioFormatFingerprint {
        try self.lock.withLock {
            guard self.values.isEmpty == false else {
                throw NSError(
                    domain: "DirectAudioReliabilityTests",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "No fingerprint remains."]
                )
            }
            return self.values.removeFirst()
        }
    }
}

private final nonisolated class FakeDirectAudioInput:
    DirectCoreAudioInputControlling,
    @unchecked Sendable
{
    let deviceID: AudioObjectID
    let sampleRate: Double
    let hardwareBufferFrameSize: UInt32
    let formatFingerprint: DirectCoreAudioFormatFingerprint

    private let recorder: DirectAudioEventRecorder
    private var running = false

    init(
        deviceID: AudioObjectID,
        fingerprint: DirectCoreAudioFormatFingerprint,
        recorder: DirectAudioEventRecorder
    ) {
        self.deviceID = deviceID
        self.sampleRate = fingerprint.virtualFormat.sampleRate
        self.hardwareBufferFrameSize = fingerprint.bufferFrameSize
        self.formatFingerprint = fingerprint
        self.recorder = recorder
    }

    var isRunning: Bool {
        self.running
    }

    var droppedPacketCount: UInt64 {
        0
    }

    func start() throws {
        self.recorder.perform(
            "start:\(Int(self.sampleRate))"
        ) {
            self.running = true
        }
    }

    func stop() -> OSStatus {
        self.recorder.perform(
            "stop:\(Int(self.sampleRate))"
        ) {
            self.running = false
        }
        return noErr
    }

    func markFormatDirty() {}

    func openPacketGateIfClean() -> Bool {
        true
    }

    func invalidate() -> OSStatus {
        self.recorder.perform(
            "invalidate:\(Int(self.sampleRate))"
        ) {
            self.running = false
        }
        return noErr
    }
}

private final nonisolated class FailingStopDirectAudioInput:
    DirectCoreAudioInputControlling,
    @unchecked Sendable
{
    let deviceID: AudioObjectID
    let sampleRate: Double
    let hardwareBufferFrameSize: UInt32
    let formatFingerprint: DirectCoreAudioFormatFingerprint

    private let recorder: DirectAudioEventRecorder
    private var running = false
    private let failureStatus = OSStatus(-50)

    init(
        fingerprint: DirectCoreAudioFormatFingerprint,
        recorder: DirectAudioEventRecorder
    ) {
        self.deviceID = fingerprint.deviceID
        self.sampleRate = fingerprint.virtualFormat.sampleRate
        self.hardwareBufferFrameSize = fingerprint.bufferFrameSize
        self.formatFingerprint = fingerprint
        self.recorder = recorder
    }

    var isRunning: Bool {
        self.running
    }

    var droppedPacketCount: UInt64 {
        0
    }

    func start() throws {
        self.running = true
        self.recorder.record("start:\(Int(self.sampleRate))")
    }

    func stop() -> OSStatus {
        self.running = false
        self.recorder.record("stop_failed")
        return self.failureStatus
    }

    func markFormatDirty() {}

    func openPacketGateIfClean() -> Bool {
        true
    }

    func invalidate() -> OSStatus {
        self.recorder.record("quarantine")
        return self.failureStatus
    }
}

private final nonisolated class FailingReplacementFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let fingerprint: DirectCoreAudioFormatFingerprint
    private let recorder: DirectAudioEventRecorder
    private var creations = 0

    init(
        fingerprint: DirectCoreAudioFormatFingerprint,
        recorder: DirectAudioEventRecorder
    ) {
        self.fingerprint = fingerprint
        self.recorder = recorder
    }

    var creationCount: Int {
        self.lock.withLock { self.creations }
    }

    func make(deviceID _: AudioObjectID) -> any DirectCoreAudioInputControlling {
        self.lock.withLock {
            self.creations += 1
        }
        return FailingStopDirectAudioInput(
            fingerprint: self.fingerprint,
            recorder: self.recorder
        )
    }
}

private final nonisolated class RecoveringAfterStoppedHardwareFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let oldFingerprint: DirectCoreAudioFormatFingerprint
    private let newFingerprint: DirectCoreAudioFormatFingerprint
    private let recorder: DirectAudioEventRecorder
    private var creations = 0

    init(
        oldFingerprint: DirectCoreAudioFormatFingerprint,
        newFingerprint: DirectCoreAudioFormatFingerprint,
        recorder: DirectAudioEventRecorder
    ) {
        self.oldFingerprint = oldFingerprint
        self.newFingerprint = newFingerprint
        self.recorder = recorder
    }

    var creationCount: Int {
        self.lock.withLock { self.creations }
    }

    func make(deviceID: AudioObjectID) -> any DirectCoreAudioInputControlling {
        let creation = self.lock.withLock {
            self.creations += 1
            return self.creations
        }
        if creation == 1 {
            return FailingStopDirectAudioInput(
                fingerprint: self.oldFingerprint,
                recorder: self.recorder
            )
        }
        self.recorder.record("make:\(Int(self.newFingerprint.virtualFormat.sampleRate))")
        return FakeDirectAudioInput(
            deviceID: deviceID,
            fingerprint: self.newFingerprint,
            recorder: self.recorder
        )
    }
}

private final nonisolated class DirectAudioEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let operationDelayMicroseconds: useconds_t
    private var recordedEvents: [String] = []
    private var operationCount = 0
    private var maximumOperationCount = 0
    private var allOperationsOffMain = true

    init(operationDelayMicroseconds: useconds_t = 0) {
        self.operationDelayMicroseconds = operationDelayMicroseconds
    }

    var events: [String] {
        self.lock.withLock { self.recordedEvents }
    }

    var maximumConcurrentOperations: Int {
        self.lock.withLock { self.maximumOperationCount }
    }

    var executedOnlyOffMain: Bool {
        self.lock.withLock { self.allOperationsOffMain }
    }

    func record(_ event: String) {
        self.lock.withLock {
            self.recordedEvents.append(event)
        }
    }

    func perform(_ event: String, body: () -> Void) {
        self.lock.withLock {
            self.operationCount += 1
            self.maximumOperationCount = max(
                self.maximumOperationCount,
                self.operationCount
            )
            self.allOperationsOffMain = self.allOperationsOffMain && Thread.isMainThread == false
            self.recordedEvents.append(event)
        }
        if self.operationDelayMicroseconds > 0 {
            usleep(self.operationDelayMicroseconds)
        }
        body()
        self.lock.withLock {
            self.operationCount -= 1
        }
    }
}
