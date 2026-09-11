import CoreAudio
#if canImport(FluidVoice_Debug)
@testable import FluidVoice_Debug
#else
@testable import AudioRecoveryTestSupport
#endif
import Foundation
import XCTest

final class AudioHardwareRecoveryTests: XCTestCase {
    func testUnreadableLivenessDoesNotAuthorizeUnsafeReplacement() {
        XCTAssertFalse(DirectCoreAudioLifecycleController.hardwareIsKnownStopped(reason: "device_is_alive", deviceIsAlive: nil))
        XCTAssertFalse(DirectCoreAudioLifecycleController.hardwareIsKnownStopped(reason: "device_is_alive", deviceIsAlive: true))
        XCTAssertTrue(DirectCoreAudioLifecycleController.hardwareIsKnownStopped(reason: "device_is_alive", deviceIsAlive: false))
        XCTAssertTrue(DirectCoreAudioLifecycleController.hardwareIsKnownStopped(reason: "io_stopped_abnormally", deviceIsAlive: nil))
        XCTAssertFalse(DirectCoreAudioLifecycleController.hardwareIsKnownStopped(reason: "nominal_sample_rate", deviceIsAlive: nil))
    }

    func testRecoveryQueryCancellationCannotFailOrdinaryStartupDiscovery() async throws {
        let input = RecoveryInput(block: "recovery_query")
        defer { input.release.signal() }
        let controller = DirectCoreAudioLifecycleController(
            packetHandler: { _, _, _, _, _ in },
            inputFactory: { _, _ in input },
            fingerprintReader: { _ in input.formatFingerprint },
            installsHardwareListeners: false,
            deviceSnapshotReader: { refreshLiveness in
                if refreshLiveness { input.perform("recovery_query") }
                return .init(devices: [], defaultInputUID: nil)
            },
            onFormatInvalidated: { _ in }
        )
        let recoveryQuery = Task { try await controller.readDeviceSnapshot(refreshLiveness: true) }
        try await waitForEvent(input, "recovery_query")
        recoveryQuery.cancel()
        _ = try? await recoveryQuery.value
        let began = ProcessInfo.processInfo.systemUptime
        _ = try await controller.readCaptureDeviceSnapshot()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.2)
        XCTAssertFalse(controller.isRecoveringHardware)
        XCTAssertEqual(input.count("start"), 0)
        input.release.signal()
        await controller.shutdown(reason: "test_complete")
    }

    func testRestartWaitCanBeCancelledWithoutTouchingBlockedNativeCall() async throws {
        let input = RecoveryInput(block: "start")
        defer { input.release.signal() }
        let controller = makeRecoveryController(input, timeout: nil)
        let starting = Task { try await controller.start(deviceID: 144, deviceName: "Test", reason: "cancel") }
        try await waitForEvent(input, "start")
        controller.cancelPendingStartup()
        _ = try? await starting.value
        let waiting = Task { await controller.waitForPendingHardwareRetirement() }
        waiting.cancel()
        let available = await waiting.value
        XCTAssertFalse(available)
        XCTAssertEqual(input.count("start"), 1)
        XCTAssertEqual(input.count("invalidate"), 0)
        input.release.signal()
        try await waitForRecovery(controller)
        _ = try await controller.start(deviceID: 144, deviceName: "Test", reason: "safe_restart")
        XCTAssertEqual(input.count("start"), 2)
        await controller.shutdown(reason: "test_complete")
    }

    func testAvailabilityWaitersResumeOnlyAfterCleanupAndCancellationStaysLocal() async throws {
        let input = RecoveryInput(block: "start")
        defer { input.release.signal() }
        let controller = makeRecoveryController(input, timeout: 1)
        let initiallyAvailable = await controller.waitForHardwareAvailability()
        XCTAssertTrue(initiallyAvailable)
        let starting = Task { try await controller.start(deviceID: 144, deviceName: "Test", reason: "waiters") }
        try await waitForEvent(input, "start")
        starting.cancel()
        _ = try? await starting.value
        let waiters = (0..<40).map { _ in Task { await controller.waitForHardwareAvailability() } }
        for waiter in waiters.prefix(20) {
            waiter.cancel()
        }
        for waiter in waiters.prefix(20) {
            let available = await waiter.value
            XCTAssertFalse(available)
        }
        XCTAssertTrue(controller.isRecoveringHardware)
        XCTAssertEqual(input.count("invalidate"), 0)
        input.release.signal()
        for waiter in waiters.suffix(20) {
            let available = await waiter.value
            XCTAssertTrue(available)
        }
        XCTAssertFalse(controller.isRecoveringHardware)
        XCTAssertEqual(input.count("start"), 1)
        await controller.shutdown(reason: "test_complete")
    }

    func testAvailabilityWaitEndsWhenCleanupNeverBecomesSafe() async throws {
        let input = RecoveryInput(block: "start", cleanupFails: true)
        defer { input.release.signal() }
        let controller = makeRecoveryController(input)
        _ = try? await controller.start(deviceID: 144, deviceName: "Test", reason: "unresolved_cleanup")
        input.release.signal()
        let began = ProcessInfo.processInfo.systemUptime
        let available = await controller.waitForHardwareAvailability()
        XCTAssertFalse(available)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.5)
        XCTAssertEqual(input.count("start"), 1)
        XCTAssertTrue(controller.isRecoveringHardware)
        await controller.shutdown(reason: "test_complete")
    }

    func testBlockedStartTimesOutAndDropsLatePacketsUntilCleanupCompletes() async throws {
        let input = RecoveryInput(block: "start")
        defer { input.release.signal() }
        let controller = makeRecoveryController(input)
        let began = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await controller.start(deviceID: 144, deviceName: "Test", reason: "timeout")
            XCTFail("Blocked startup must time out")
        } catch {
            XCTAssertTrue(error is BoundedAudioHardwareQueue.Failure)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1)
        XCTAssertTrue(controller.isRecoveringHardware)
        XCTAssertEqual(controller.snapshot.phase, .failed)
        XCTAssertEqual(input.count("start"), 1)
        input.emit()
        XCTAssertEqual(input.count("delivered"), 0)
        do {
            _ = try await controller.start(deviceID: 144, deviceName: "Test", reason: "retry_while_blocked")
            XCTFail("A second native start must not overlap the blocked one")
        } catch {}
        XCTAssertEqual(input.count("start"), 1)
        input.release.signal()
        try await waitForRecovery(controller)
        XCTAssertEqual(input.count("open"), 0, "A timed-out start must never open its packet gate")
        XCTAssertGreaterThan(input.count("invalidate"), 0)
        input.emit()
        XCTAssertEqual(input.count("delivered"), 0, "Retired packets remain rejected after recovery")
        let retried = try await controller.start(deviceID: 144, deviceName: "Test", reason: "retry_after_cleanup")
        XCTAssertEqual(retried.phase, .running)
        input.emit()
        XCTAssertEqual(input.count("delivered"), 1)
        await controller.shutdown(reason: "test_complete")
    }

    func testPostStartFingerprintTimeoutNeverOpensPacketGate() async throws {
        let input = RecoveryInput(block: "post_start_fingerprint")
        defer { input.release.signal() }
        let controller = makeRecoveryController(input)
        do {
            _ = try await controller.start(deviceID: 144, deviceName: "Test", reason: "blocked_post_start_query")
            XCTFail("Post-start hardware validation must time out")
        } catch {
            XCTAssertTrue(error is BoundedAudioHardwareQueue.Failure)
        }
        XCTAssertEqual(input.count("start"), 1)
        input.emit()
        XCTAssertEqual(input.count("delivered"), 0)
        input.release.signal()
        try await waitForRecovery(controller)
        XCTAssertEqual(input.count("open"), 0)
        XCTAssertFalse(input.isRunning)
        await controller.shutdown(reason: "test_complete")
    }

    func testDeviceQueryTimeoutDoesNotStopRecordingOrDropItsAudio() async throws {
        let input = RecoveryInput(block: "query")
        defer { input.release.signal() }
        let controller = DirectCoreAudioLifecycleController(
            packetHandler: { _, _, _, _, _ in input.record("delivered") },
            inputFactory: { _, handler in input.setHandler(handler); return input },
            fingerprintReader: { _ in input.formatFingerprint },
            installsHardwareListeners: false,
            operationTimeout: 0.08,
            deviceSnapshotReader: { _ in
                input.perform("query")
                return .init(devices: [], defaultInputUID: nil)
            },
            onFormatInvalidated: { _ in }
        )
        _ = try await controller.start(deviceID: 144, deviceName: "Test", reason: "recording")
        do {
            _ = try await controller.readDeviceSnapshot()
            XCTFail("Device enumeration must time out")
        } catch {
            XCTAssertTrue(error is BoundedAudioHardwareQueue.Failure)
        }
        XCTAssertEqual(controller.snapshot.phase, .running)
        XCTAssertFalse(controller.isRecoveringHardware)
        XCTAssertEqual(input.count("stop"), 0)
        XCTAssertEqual(input.count("invalidate"), 0)
        input.emit()
        XCTAssertEqual(input.count("delivered"), 1)
        input.release.signal()
        await controller.shutdown(reason: "test_complete")
    }

    func testExplicitCancellationAndShutdownReturnBeforeNativeStartDoes() async throws {
        let input = RecoveryInput(block: "start")
        defer { input.release.signal() }
        let controller = makeRecoveryController(input, timeout: 1)
        let starting = Task {
            try await controller.start(deviceID: 144, deviceName: "Test", reason: "cancel")
        }
        try await waitForEvent(input, "start")
        controller.cancelPendingStartup()
        let began = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await starting.value
            XCTFail("Cancelled startup must not report success")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await controller.shutdown(reason: "quit_while_starting")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.5)
        XCTAssertEqual(input.count("invalidate"), 0, "Do not tear down a native call concurrently")
        input.release.signal()
        try await waitForRecovery(controller)
        XCTAssertEqual(controller.snapshot.phase, .shutDown)
        XCTAssertEqual(input.count("open"), 0)
        do {
            _ = try await controller.start(deviceID: 144, deviceName: "Test", reason: "after_quit")
            XCTFail("Late completion must not undo shutdown")
        } catch {}
        XCTAssertEqual(input.count("start"), 1)
    }

    func testTaskCancellationWakesCallerAndPreservesSerializedCleanup() async throws {
        let input = RecoveryInput(block: "start")
        defer { input.release.signal() }
        let controller = makeRecoveryController(input, timeout: 1)
        let starting = Task {
            try await controller.start(deviceID: 144, deviceName: "Test", reason: "task_cancel")
        }
        try await waitForEvent(input, "start")
        starting.cancel()
        do {
            _ = try await starting.value
            XCTFail("Task cancellation must wake the caller")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(input.count("invalidate"), 0)
        input.release.signal()
        try await waitForRecovery(controller)
        XCTAssertGreaterThan(input.count("invalidate"), 0)
        XCTAssertEqual(input.count("open"), 0)
        await controller.shutdown(reason: "test_complete")
    }

    func testBlockedPreparationIsAlsoBoundedAndLateInputIsDestroyed() async throws {
        let input = RecoveryInput(block: "prepare")
        defer { input.release.signal() }
        let controller = makeRecoveryController(input)
        do {
            _ = try await controller.prepare(deviceID: 144, deviceName: "Test", reason: "blocked_prepare")
            XCTFail("Preparation must also have a deadline")
        } catch {
            XCTAssertTrue(error is BoundedAudioHardwareQueue.Failure)
        }
        XCTAssertEqual(input.count("start"), 0)
        input.release.signal()
        try await waitForRecovery(controller)
        XCTAssertGreaterThan(input.count("invalidate"), 0)
        XCTAssertEqual(input.count("start"), 0)
        await controller.shutdown(reason: "test_complete")
    }

    func testBlockedStopReturnsFailureWithoutStartingReplacementHardware() async throws {
        let input = RecoveryInput(block: "stop")
        defer { input.release.signal() }
        let controller = makeRecoveryController(input)
        _ = try await controller.start(deviceID: 144, deviceName: "Test", reason: "before_stop")
        let result = await controller.stop(retainPrepared: true, reason: "blocked_stop")
        XCTAssertNotEqual(result.status, noErr)
        XCTAssertFalse(result.retainedPreparedCapture)
        XCTAssertTrue(controller.isRecoveringHardware)
        input.emit()
        XCTAssertEqual(input.count("delivered"), 0)
        input.release.signal()
        try await waitForRecovery(controller)
        XCTAssertEqual(input.count("start"), 1)
        XCTAssertFalse(controller.snapshot.isPrepared)
        await controller.shutdown(reason: "test_complete")
    }

    func testFailedCleanupKeepsHardwareUnavailable() async throws {
        let input = RecoveryInput(block: "start", cleanupFails: true)
        defer { input.release.signal() }
        let controller = makeRecoveryController(input)
        _ = try? await controller.start(deviceID: 144, deviceName: "Test", reason: "timeout")
        input.release.signal()
        try await waitForEvent(input, "invalidate")
        // A query must fail promptly even if cleanup cannot safely release the IOProc.
        do {
            _ = try await controller.prepare(deviceID: 144, deviceName: "Test", reason: "unsafe_retry")
            XCTFail("Failed teardown must not create replacement hardware")
        } catch {}
        XCTAssertTrue(controller.isRecoveringHardware)
        XCTAssertEqual(input.count("prepare"), 1)
        await controller.shutdown(reason: "test_complete")
    }

    func testCancelledQueuedStartNeverCallsHardwareLater() async throws {
        let input = RecoveryInput(block: "prepare")
        defer { input.release.signal() }
        let controller = makeRecoveryController(input, timeout: 1)
        let preparing = Task {
            try await controller.prepare(deviceID: 144, deviceName: "Test", reason: "prewarm")
        }
        try await waitForEvent(input, "prepare")
        let starting = Task {
            try await controller.start(deviceID: 144, deviceName: "Test", reason: "queued_start")
        }
        starting.cancel()
        _ = try? await starting.value
        input.release.signal()
        _ = try? await preparing.value
        try await waitForRecovery(controller)
        XCTAssertEqual(input.count("start"), 0)
        await controller.shutdown(reason: "test_complete")
    }

    func testPropertyListenerUsesRegisteredDeviceRatherThanAddressCount() {
        let input = RecoveryInput()
        let listener = DirectCoreAudioLifecycleController.makeDevicePropertyListener(objectID: 144) { objectID in
            input.record("device_\(objectID)")
        }
        var addresses = [
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain),
        ]
        addresses.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            listener(1, base)
            listener(2, base)
        }
        XCTAssertEqual(input.count("device_144"), 2)
        XCTAssertEqual(input.count("device_1"), 0)
        XCTAssertEqual(input.count("device_2"), 0)
    }
}

final class MonitorTopologyRecoveryTests: XCTestCase {
    func testHealthyTopologyChangeDoesNotQueryLivenessOrInterruptCapture() async throws {
        let input = RecoveryInput()
        let probe = FailedDeviceLivenessProbe()
        let controller = makeRecoveryController(input, timeout: nil, deviceLivenessReader: { probe.read($0) })
        _ = try await controller.start(deviceID: 144, deviceName: "Healthy", reason: "recording")
        for _ in 0..<100 { controller.noteHardwareTopologyChanged() }
        try await waitForTopologyCheck(controller)
        input.emit()
        XCTAssertTrue(probe.deviceIDs.isEmpty)
        XCTAssertEqual(controller.snapshot.phase, .running)
        XCTAssertEqual(input.count("stop"), 0)
        XCTAssertEqual(input.count("invalidate"), 0)
        XCTAssertEqual(input.count("delivered"), 1)
        await controller.shutdown(reason: "test_complete")
    }

    func testGlobalTopologyRemovalClearsFailedCleanupAndAllowsNextRecording() async throws {
        let input = RecoveryInput(block: "start", cleanupFails: true)
        let probe = FailedDeviceLivenessProbe()
        let controller = makeRecoveryController(input, deviceLivenessReader: { probe.read($0) })
        defer { input.release.signal() }
        _ = try? await controller.start(deviceID: 144, deviceName: "Removed", reason: "failed_start")
        input.release.signal()
        try await waitForFailedCleanup(controller)
        try await waitForTopologyCheck(controller)
        XCTAssertTrue(controller.isRecoveringHardware)
        XCTAssertEqual(probe.deviceIDs, [144])

        // This is the actual entry point used by the global HAL device-list
        // listener, after invalidate() has removed all per-device listeners.
        probe.setAlive(false)
        controller.noteHardwareTopologyChanged()
        try await waitForTopologyCheck(controller)
        XCTAssertFalse(controller.isRecoveringHardware)
        let replacement = try await controller.start(deviceID: 144, deviceName: "Replacement", reason: "next_recording")
        input.emit()
        XCTAssertEqual(replacement.phase, .running)
        XCTAssertEqual(input.count("delivered"), 1)
        await controller.shutdown(reason: "test_complete")
    }

    func testUnrelatedTopologyAndUnknownLivenessKeepFailedCleanupBlocked() async throws {
        let input = RecoveryInput(block: "start", cleanupFails: true)
        let probe = FailedDeviceLivenessProbe()
        let controller = makeRecoveryController(input, deviceLivenessReader: { probe.read($0) })
        defer { input.release.signal() }
        _ = try? await controller.start(deviceID: 144, deviceName: "Still connected", reason: "failed_start")
        input.release.signal()
        try await waitForFailedCleanup(controller)
        try await waitForTopologyCheck(controller)
        for alive in [true, nil] as [Bool?] {
            probe.setAlive(alive)
            for _ in 0..<100 { controller.noteHardwareTopologyChanged() }
            try await waitForTopologyCheck(controller)
            XCTAssertTrue(controller.isRecoveringHardware)
            XCTAssertEqual(input.count("prepare"), 1)
            XCTAssertEqual(input.count("delivered"), 0)
        }
        XCTAssertTrue(probe.deviceIDs.allSatisfy { $0 == 144 })
        XCTAssertLessThan(probe.deviceIDs.count, 10, "Coalesce event bursts instead of querying once per notification")
        await controller.shutdown(reason: "test_complete")
    }

    func testRemovalDuringBlockedNativeWorkWaitsForItsCleanup() async throws {
        let input = RecoveryInput(block: "start", cleanupFails: true)
        let probe = FailedDeviceLivenessProbe(alive: false)
        let controller = makeRecoveryController(input, deviceLivenessReader: { probe.read($0) })
        defer { input.release.signal() }
        _ = try? await controller.start(deviceID: 144, deviceName: "Removed", reason: "failed_start")
        for _ in 0..<100 { controller.noteHardwareTopologyChanged() }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(controller.isRecoveringHardware)
        XCTAssertTrue(probe.deviceIDs.isEmpty, "Do not check or unlock while native startup owns capture")
        XCTAssertEqual(input.count("invalidate"), 0)
        XCTAssertEqual(input.count("prepare"), 1)
        input.release.signal()
        try await waitForRecovery(controller)
        XCTAssertEqual(input.count("invalidate"), 1)
        XCTAssertEqual(probe.deviceIDs, [144])
        await controller.shutdown(reason: "test_complete")
    }

    func testRemovalDuringLivenessQueryRechecksTheLatestTopology() async throws {
        let input = RecoveryInput(block: "start", cleanupFails: true)
        let probe = FailedDeviceLivenessProbe()
        let controller = makeRecoveryController(input, timeout: 1, deviceLivenessReader: { probe.read($0) })
        defer { input.release.signal(); probe.release.signal() }
        let starting = Task { try await controller.start(deviceID: 144, deviceName: "Old", reason: "old_start") }
        try await waitForEvent(input, "start")
        starting.cancel()
        _ = try? await starting.value
        input.release.signal()
        try await waitForFailedCleanup(controller)
        try await waitForTopologyCheck(controller)
        probe.blockNextRead(alive: true)
        controller.noteHardwareTopologyChanged()
        try await probe.waitForReadCount(2)
        probe.setAlive(false)
        controller.noteHardwareTopologyChanged()
        probe.release.signal()
        try await waitForRecovery(controller)
        try await waitForTopologyCheck(controller)
        XCTAssertEqual(probe.deviceIDs.count, 3, "Recheck after the in-flight query returns an older snapshot")
        XCTAssertEqual(controller.snapshot.phase, .empty)
        XCTAssertEqual(input.count("prepare"), 1)
        await controller.shutdown(reason: "test_complete")
    }

    func testLateLivenessResultCannotClearOrStopNewCapture() async throws {
        let input = RecoveryInput(block: "start", cleanupFails: true)
        let probe = FailedDeviceLivenessProbe()
        let controller = makeRecoveryController(input, timeout: 1, deviceLivenessReader: { probe.read($0) })
        defer { input.release.signal(); probe.release.signal() }
        let starting = Task { try await controller.start(deviceID: 144, deviceName: "Old", reason: "old_start") }
        try await waitForEvent(input, "start")
        starting.cancel()
        _ = try? await starting.value
        input.release.signal()
        try await waitForFailedCleanup(controller)
        try await waitForTopologyCheck(controller)
        let oldGeneration = controller.snapshot.generation
        probe.blockNextRead(alive: false)
        controller.noteHardwareTopologyChanged()
        try await probe.waitForReadCount(2)
        // A valid per-device signal wins the race and admits a new generation.
        await controller.simulateStoppedHardwareNotificationForTesting(generation: oldGeneration, reason: "device_is_alive")
        let replacement = try await controller.start(deviceID: 144, deviceName: "New", reason: "replacement")
        probe.release.signal()
        try await waitForTopologyCheck(controller)
        input.emit()
        XCTAssertGreaterThan(replacement.generation, oldGeneration)
        XCTAssertEqual(controller.snapshot.phase, .running)
        XCTAssertEqual(input.count("invalidate"), 1)
        XCTAssertEqual(input.count("delivered"), 1)
        await controller.shutdown(reason: "test_complete")
    }

    func testBlockedTopologyQueryDoesNotUnlockAndShutdownCannotBeReversed() async throws {
        let input = RecoveryInput(block: "start", cleanupFails: true)
        let probe = FailedDeviceLivenessProbe()
        let controller = makeRecoveryController(input, deviceLivenessReader: { probe.read($0) })
        defer { input.release.signal(); probe.release.signal() }
        _ = try? await controller.start(deviceID: 144, deviceName: "Old", reason: "failed_start")
        input.release.signal()
        try await waitForFailedCleanup(controller)
        try await waitForTopologyCheck(controller)
        probe.blockNextRead(alive: false)
        controller.noteHardwareTopologyChanged()
        try await probe.waitForReadCount(2)
        try await waitForTopologyCheck(controller)
        XCTAssertTrue(controller.isRecoveringHardware, "Timed-out liveness is unknown, not proof of removal")
        await controller.shutdown(reason: "test_complete")
        probe.release.signal()
        controller.noteHardwareTopologyChanged()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(controller.isRecoveringHardware)
        XCTAssertEqual(input.count("prepare"), 1)
        XCTAssertEqual(input.count("delivered"), 0)
    }

    func testDisplayTopologyChangeRefreshesUnchangedPreparedInputOnlyOnce() async throws {
        let input = RecoveryInput()
        let controller = makeDefaultRecoveryController(input)
        let old = try await controller.prepare(deviceID: 144, deviceName: "Test", reason: "before_display")
        for _ in 0..<100 {
            controller.noteHardwareTopologyChanged()
        }
        // Even a prewarm during topology churn is refreshed at actual demand.
        _ = try await controller.prepare(deviceID: 144, deviceName: "Test", reason: "idle_prewarm")
        XCTAssertEqual(input.count("invalidate"), 0)
        let fresh = try await controller.start(deviceID: 144, deviceName: "Test", reason: "after_display")
        XCTAssertGreaterThan(fresh.generation, old.generation)
        XCTAssertEqual(input.count("prepare"), 2)
        XCTAssertEqual(input.count("invalidate"), 1)
        input.emit()
        XCTAssertEqual(input.count("delivered"), 1)
        _ = await controller.stop(retainPrepared: true, reason: "stop")
        let reused = try await controller.start(deviceID: 144, deviceName: "Test", reason: "ordinary_next_start")
        XCTAssertEqual(reused.generation, fresh.generation)
        XCTAssertEqual(input.count("prepare"), 2)
        XCTAssertEqual(input.count("invalidate"), 1)
        await controller.shutdown(reason: "test_complete")
    }

    func testDisplayChangeDoesNotInterruptRunningAudioButRefreshesAfterStop() async throws {
        let input = RecoveryInput()
        let controller = makeDefaultRecoveryController(input)
        let running = try await controller.start(deviceID: 144, deviceName: "Test", reason: "running")
        controller.noteHardwareTopologyChanged()
        input.emit()
        XCTAssertEqual(input.count("delivered"), 1)
        XCTAssertEqual(input.count("stop"), 0)
        XCTAssertEqual(input.count("invalidate"), 0)
        XCTAssertEqual(controller.snapshot.phase, .running)
        _ = await controller.stop(retainPrepared: true, reason: "user_stop")
        let fresh = try await controller.start(deviceID: 144, deviceName: "Test", reason: "next_start")
        XCTAssertGreaterThan(fresh.generation, running.generation)
        await controller.shutdown(reason: "test_complete")
    }

    func testRunningPreviewHandoffDoesNotDiscardOpeningAudioAfterDisplayChange() async throws {
        let input = RecoveryInput()
        let controller = makeDefaultRecoveryController(input)
        let preview = try await controller.start(deviceID: 144, deviceName: "Test", reason: "preview")
        controller.noteHardwareTopologyChanged()
        let handoff = try await controller.start(deviceID: 144, deviceName: "Test", reason: "handoff")
        input.emit()
        XCTAssertEqual(handoff.generation, preview.generation)
        XCTAssertEqual(input.count("start"), 1)
        XCTAssertEqual(input.count("stop"), 0)
        XCTAssertEqual(input.count("invalidate"), 0)
        XCTAssertEqual(input.count("delivered"), 1)
        _ = await controller.stop(retainPrepared: true, reason: "handoff_recording_stopped")
        let next = try await controller.start(deviceID: 144, deviceName: "Test", reason: "after_handoff")
        XCTAssertGreaterThan(next.generation, handoff.generation, "Handoff must preserve the pending topology rebuild")
        XCTAssertEqual(input.count("invalidate"), 1)
        XCTAssertEqual(input.count("start"), 2)
        await controller.shutdown(reason: "test_complete")
    }

    func testCancelledStartupDiscoveryReturnsWhileHALIsBlockedAndLeavesCaptureAlone() async throws {
        let input = RecoveryInput(block: "query")
        defer { input.release.signal() }
        let controller = DirectCoreAudioLifecycleController(
            packetHandler: { _, _, _, _, _ in input.record("delivered") },
            inputFactory: { _, handler in input.setHandler(handler); return input },
            fingerprintReader: { _ in input.formatFingerprint },
            installsHardwareListeners: false,
            deviceSnapshotReader: { _ in input.perform("query"); return .init(devices: [], defaultInputUID: nil) },
            onFormatInvalidated: { _ in }
        )
        _ = try await controller.start(deviceID: 144, deviceName: "Test", reason: "existing_capture")
        let query = Task { try await controller.readCaptureDeviceSnapshot() }
        try await waitForEvent(input, "query")
        let began = ProcessInfo.processInfo.systemUptime
        query.cancel()
        do { _ = try await query.value; XCTFail("Cancelled discovery must fail") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.2)
        input.emit()
        XCTAssertEqual(input.count("delivered"), 1)
        XCTAssertEqual(input.count("invalidate"), 0)
        XCTAssertFalse(controller.isRecoveringHardware)
        do { _ = try await controller.readCaptureDeviceSnapshot(); XCTFail("Do not pile up blocked queries") } catch { XCTAssertTrue(error is BoundedAudioHardwareQueue.Failure) }
        XCTAssertEqual(input.count("query"), 1)
        input.release.signal()
        await controller.shutdown(reason: "test_complete")
    }

    func testFailedHardwareRetirementWaitHasDeadlineWithoutStartingReplacement() async throws {
        let input = RecoveryInput(block: "start")
        defer { input.release.signal() }
        let controller = makeRecoveryController(input, timeout: 0.08)
        _ = try? await controller.start(deviceID: 144, deviceName: "Test", reason: "blocked")
        let began = ProcessInfo.processInfo.systemUptime
        let available = await controller.waitForPendingHardwareRetirement()
        XCTAssertFalse(available)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.5)
        XCTAssertEqual(input.count("start"), 1)
        XCTAssertEqual(input.count("invalidate"), 0)
        input.release.signal()
        try await waitForRecovery(controller)
        await controller.shutdown(reason: "test_complete")
    }

    func testAbnormalStopReleasesBlockedStartOnceAndRejectsLateGenerationEvents() async throws {
        let input = RecoveryInput(block: "start")
        defer { input.release.signal() }
        let controller = DirectCoreAudioLifecycleController(
            packetHandler: { _, _, _, _, _ in input.record("delivered") },
            inputFactory: { _, handler in input.setHandler(handler); return input },
            fingerprintReader: { _ in input.formatFingerprint },
            installsHardwareListeners: false,
            onFormatInvalidated: { _ in input.record("notification") }
        )
        let starting = Task { try await controller.start(deviceID: 144, deviceName: "Test", reason: "blocked") }
        try await waitForEvent(input, "start")
        let generation = controller.snapshot.generation
        let began = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 {
            controller.simulateAbnormalStopNotificationForTesting(generation: generation)
        }
        do { _ = try await starting.value; XCTFail("Known failed startup must release its caller") } catch { XCTAssertTrue(error is BoundedAudioHardwareQueue.Failure) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.2)
        XCTAssertEqual(input.count("notification"), 1)
        XCTAssertEqual(input.count("invalidate"), 0, "Native startup still owns the resources")
        XCTAssertEqual(input.count("open"), 0)
        _ = try? await controller.start(deviceID: 144, deviceName: "Test", reason: "unsafe_retry")
        XCTAssertEqual(input.count("start"), 1)
        input.release.signal()
        try await waitForRecovery(controller)
        let fresh = try await controller.start(deviceID: 144, deviceName: "Test", reason: "safe_retry")
        XCTAssertGreaterThan(fresh.generation, generation)
        controller.simulateAbnormalStopNotificationForTesting(generation: generation)
        XCTAssertEqual(input.count("notification"), 1)
        XCTAssertEqual(controller.snapshot.phase, .running)
        input.emit()
        XCTAssertEqual(input.count("delivered"), 1)
        await controller.shutdown(reason: "test_complete")
    }
}

/// This same class is also run against the original controller for comparison.
final class NormalAudioCaptureCompatibilityTests: XCTestCase {
    func testHealthySlowNativeStartsAtFiveAndTenSecondsSucceed() async throws {
        for delay in [5.2, 10.0] {
            let input = RecoveryInput(delays: ["start": delay])
            let controller = makeDefaultRecoveryController(input)
            let started = try await controller.start(deviceID: 144, deviceName: "Test", reason: "healthy_slow")
            XCTAssertEqual(started.phase, .running)
            XCTAssertEqual(input.count("open"), 1)
            XCTAssertEqual(input.count("invalidate"), 0)
            input.emit()
            XCTAssertEqual(input.count("delivered"), 1)
            await controller.shutdown(reason: "test_complete")
        }
    }

    func testHealthySlowPostStartFingerprintStillSucceeds() async throws {
        let input = RecoveryInput(delays: ["post_start_fingerprint": 5.2])
        let controller = makeDefaultRecoveryController(input)
        let started = try await controller.start(deviceID: 144, deviceName: "Test", reason: "healthy_slow_fingerprint")
        XCTAssertEqual(started.phase, .running)
        XCTAssertEqual(input.count("open"), 1)
        XCTAssertEqual(input.count("invalidate"), 0)
        await controller.shutdown(reason: "test_complete")
    }

    func testHealthySlowStopStillRetainsPreparedInput() async throws {
        let input = RecoveryInput(delays: ["stop": 5.2])
        let controller = makeDefaultRecoveryController(input)
        _ = try await controller.start(deviceID: 144, deviceName: "Test", reason: "before_slow_stop")
        let stopped = await controller.stop(retainPrepared: true, reason: "normal_slow_stop")
        XCTAssertEqual(stopped.status, noErr)
        XCTAssertTrue(stopped.retainedPreparedCapture)
        XCTAssertEqual(input.count("invalidate"), 0)
        await controller.shutdown(reason: "test_complete")
    }

    func testFiftyHealthyPreparedStartStopCyclesRetainOneInput() async throws {
        let input = RecoveryInput()
        let controller = makeDefaultRecoveryController(input)
        _ = try await controller.prepare(deviceID: 144, deviceName: "Test", reason: "prewarm")
        for cycle in 1...50 {
            let started = try await controller.start(deviceID: 144, deviceName: "Test", reason: "normal_start")
            XCTAssertEqual(started.phase, .running)
            input.emit()
            XCTAssertEqual(input.count("delivered"), cycle)
            let stopped = await controller.stop(retainPrepared: true, reason: "normal_stop")
            XCTAssertEqual(stopped.status, noErr)
            XCTAssertTrue(stopped.retainedPreparedCapture)
            XCTAssertFalse(input.isRunning)
        }
        XCTAssertEqual(input.count("prepare"), 1)
        XCTAssertEqual(input.count("start"), 50)
        XCTAssertEqual(input.count("stop"), 50)
        XCTAssertEqual(input.count("invalidate"), 0)
        await controller.shutdown(reason: "test_complete")
    }
}

private func makeDefaultRecoveryController(_ input: RecoveryInput) -> DirectCoreAudioLifecycleController {
    DirectCoreAudioLifecycleController(
        packetHandler: { _, _, _, _, _ in input.record("delivered") },
        inputFactory: { _, handler in input.perform("prepare"); input.setHandler(handler); return input },
        fingerprintReader: { _ in
            if input.isRunning { input.perform("post_start_fingerprint") }
            return input.formatFingerprint
        },
        installsHardwareListeners: false,
        onFormatInvalidated: { _ in }
    )
}

private func makeRecoveryController(
    _ input: RecoveryInput,
    timeout: TimeInterval? = 0.08,
    deviceLivenessReader: @escaping @Sendable (AudioObjectID) -> Bool? = { _ in true }
) -> DirectCoreAudioLifecycleController {
    DirectCoreAudioLifecycleController(
        packetHandler: { _, _, _, _, _ in input.record("delivered") },
        inputFactory: { _, handler in
            input.perform("prepare")
            input.setHandler(handler)
            return input
        },
        fingerprintReader: { _ in
            if input.isRunning { input.perform("post_start_fingerprint") }
            return input.formatFingerprint
        },
        installsHardwareListeners: false,
        operationTimeout: timeout,
        deviceLivenessReader: deviceLivenessReader,
        onFormatInvalidated: { _ in }
    )
}

private func waitForRecovery(_ controller: DirectCoreAudioLifecycleController) async throws {
    for _ in 0..<1000 {
        if controller.isRecoveringHardware == false { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Serialized recovery did not finish after releasing native hardware")
}

private func waitForEvent(_ input: RecoveryInput, _ event: String) async throws {
    for _ in 0..<1000 {
        if input.count(event) > 0 { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Native operation did not enter: \(event)")
}

private final nonisolated class RecoveryInput: DirectCoreAudioInputControlling, @unchecked Sendable {
    let deviceID: AudioObjectID
    let sampleRate: Double = 48_000
    let hardwareBufferFrameSize: UInt32 = 512
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let blockedOperation: String?
    private let cleanupFails: Bool
    private let delays: [String: TimeInterval]
    private let automaticPCM: Bool
    private var events: [String: Int] = [:]
    private var running = false
    private var handler: DirectCoreAudioPacketHandler?

    init(deviceID: AudioObjectID = 144, block: String? = nil, cleanupFails: Bool = false, delays: [String: TimeInterval] = [:], automaticPCM: Bool = false) {
        self.deviceID = deviceID
        self.blockedOperation = block
        self.cleanupFails = cleanupFails
        self.delays = delays
        self.automaticPCM = automaticPCM
    }

    var formatFingerprint: DirectCoreAudioFormatFingerprint {
        DirectCoreAudioFormatFingerprint(
            deviceID: self.deviceID,
            streamID: self.deviceID + 1,
            virtualFormat: DirectCoreAudioStreamFormatFingerprint(AudioStreamBasicDescription(
                mSampleRate: 48_000,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 32,
                mReserved: 0
            )),
            physicalFormat: nil,
            inputBufferChannels: [1],
            nominalSampleRate: 48_000,
            bufferFrameSize: 512,
            variableBufferFrameSizeMaximum: nil,
            dataSourceID: nil
        )
    }

    var isRunning: Bool { self.lock.withLock { self.running } }
    var droppedPacketCount: UInt64 { 0 }
    func count(_ event: String) -> Int { self.lock.withLock { self.events[event, default: 0] } }
    func record(_ event: String) { self.lock.withLock { self.events[event, default: 0] += 1 } }
    func setHandler(_ handler: @escaping DirectCoreAudioPacketHandler) { self.lock.withLock { self.handler = handler } }

    func perform(_ event: String) {
        let count = self.lock.withLock {
            self.events[event, default: 0] += 1
            return self.events[event, default: 0]
        }
        if event == self.blockedOperation, count == 1 {
            // A broken watchdog fails the timing assertions without hanging the test runner.
            _ = self.release.wait(timeout: .now() + 3)
        }
        if let delay = self.delays[event] { Thread.sleep(forTimeInterval: delay) }
    }

    func start() throws {
        self.perform("start")
        self.lock.withLock { self.running = true }
    }

    func stop() -> OSStatus {
        self.perform("stop")
        self.lock.withLock { self.running = false }
        return noErr
    }

    func invalidate() -> OSStatus {
        self.perform("invalidate")
        self.lock.withLock { self.running = false }
        return self.cleanupFails ? kAudioHardwareUnspecifiedError : noErr
    }

    func markFormatDirty() {}
    func openPacketGateIfClean() -> Bool {
        self.record("open")
        if self.automaticPCM { self.emit() }
        return true
    }

    func emit() {
        let handler = self.lock.withLock { self.handler }
        let samples = [Float](repeating: 0.5, count: 48)
        samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            handler?(baseAddress, buffer.count, 48_000, 0, 0)
        }
    }
}

#if canImport(FluidVoice_Debug)
final class AudioRouteRecoveryIntegrationTests: XCTestCase {
    @MainActor
    func testStartupTriesNewMicrophoneMissingFromDeviceCache() async throws {
        try await withASRRecoveryFixture(queryDelay: 0) { fixture in
            await fixture.service.stopWithoutTranscription()
            fixture.service.micStatus = .authorized
            fixture.hardware.enableNewFallback()
            let outcome = await fixture.service.start(forDictionaryTraining: true)
            XCTAssertEqual(outcome, .started)
            XCTAssertTrue(fixture.service.isRunning)
            XCTAssertEqual(fixture.controller.snapshot.deviceID, 300)
            XCTAssertEqual(fixture.hardware.resolutionAttempts, [100, 100, 300])
            XCTAssertEqual(fixture.hardware.startCount(deviceID: 300), 1)
            fixture.assertSettingsPreserved()
            await fixture.service.stopWithoutTranscription()
        }
    }

    @MainActor
    func testActiveRecoveryTriesNewMicrophoneMissingFromDeviceCache() async throws {
        try await withASRRecoveryFixture(queryDelay: 0) { fixture in
            fixture.hardware.enableNewFallback()
            fixture.service.triggerAudioRouteRecoveryForTesting()
            try await fixture.waitForRecoveryAttempt()
            XCTAssertEqual(fixture.controller.snapshot.deviceID, 300)
            XCTAssertEqual(fixture.hardware.resolutionAttempts, [100, 100, 300])
            XCTAssertEqual(fixture.hardware.startCount(deviceID: 300), 1)
            fixture.assertSessionPreserved()
        }
    }

    @MainActor
    func testFreshSnapshotBudgetStopsAfterAllStartupInputsFail() async throws {
        try await withASRRecoveryFixture(queryDelay: 0) { fixture in
            await fixture.service.stopWithoutTranscription()
            fixture.service.micStatus = .authorized
            fixture.hardware.enableNewFallback(fails: true)
            let outcome = await fixture.service.start(forDictionaryTraining: true)
            XCTAssertEqual(outcome, .failed)
            XCTAssertFalse(fixture.service.isRunning)
            XCTAssertFalse(fixture.service.isStarting)
            XCTAssertTrue(fixture.service.showError)
            XCTAssertEqual(fixture.hardware.resolutionAttempts, [100, 100, 300])
            XCTAssertEqual(fixture.hardware.startCount(deviceID: 300), 0)
            fixture.assertSettingsPreserved()
        }
    }

    @MainActor
    func testFreshSnapshotBudgetStopsAfterAllRecoveryInputsFail() async throws {
        try await withASRRecoveryFixture(queryDelay: 0) { fixture in
            fixture.hardware.enableNewFallback(fails: true)
            fixture.service.triggerAudioRouteRecoveryForTesting()
            try await fixture.waitForRecoveryAttempt()
            XCTAssertFalse(fixture.service.isRunning)
            XCTAssertFalse(fixture.service.audioRouteRecoveryStateForTesting.acceptingPCM)
            XCTAssertTrue(fixture.service.showError)
            XCTAssertEqual(fixture.hardware.resolutionAttempts, [100, 100, 300])
            XCTAssertEqual(fixture.hardware.startCount(deviceID: 300), 0)
            fixture.assertSettingsPreserved()
        }
    }

    @MainActor
    func testFailedRecoveryCancelsWaitingRetryAndResumesMediaBeforeNativeCleanup() async throws {
        try await withASRRecoveryFixture(queryDelay: 0, builtInStartDelay: 0.8) { fixture in
            await fixture.service.stopWithoutTranscription()
            fixture.service.micStatus = .authorized
            let first = Task { await fixture.service.start(forDictionaryTraining: true) }
            try await fixture.waitForBuiltInStartCount(1)
            await fixture.service.cancelPendingAudioCaptureStart(reason: "injected_user_cancel")
            let firstOutcome = await first.value
            XCTAssertEqual(firstOutcome, .failed)
            XCTAssertTrue(fixture.controller.isRecoveringHardware)

            let transport = RecoveryMediaTransport()
            let media = MediaPlaybackService(transport: transport, settle: {})
            fixture.service.useMediaPlaybackForTesting(media)
            SettingsStore.shared.pauseMediaDuringTranscription = true
            let retry = Task { await fixture.service.start(forDictionaryTraining: true) }
            for _ in 0..<200 {
                if await transport.commands == [.pause] { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            await media.waitUntilSettled()
            let paused = await transport.commands
            XCTAssertEqual(paused, [.pause])
            XCTAssertTrue(fixture.service.isStarting)
            var failurePresentations = 0
            let observation = fixture.service.audioCaptureFailurePresented.sink {
                failurePresentations += 1
                XCTAssertTrue(fixture.service.showError)
                XCTAssertEqual(fixture.service.errorTitle, "Recording Stopped")
            }
            defer { observation.cancel() }
            let began = ProcessInfo.processInfo.systemUptime
            await fixture.service.failAudioRouteRecoveryForTesting()
            let retryOutcome = await retry.value
            await media.waitUntilSettled()
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            print("MONITOR_RECOVERY_TEST failed_recovery_release_ms=\(elapsed * 1000)")
            XCTAssertLessThan(elapsed, 0.2)
            XCTAssertEqual(retryOutcome, .failed)
            XCTAssertFalse(fixture.service.isStarting)
            XCTAssertFalse(fixture.service.isRunning)
            XCTAssertTrue(fixture.service.showError)
            XCTAssertEqual(failurePresentations, 1)
            XCTAssertTrue(fixture.controller.isRecoveringHardware)
            XCTAssertEqual(fixture.hardware.startCount(deviceID: 100), 1)
            let resumed = await transport.commands
            XCTAssertEqual(resumed, [.pause, .play])
            try await waitForRecovery(fixture.controller)
            let afterDrain = await transport.commands
            XCTAssertEqual(afterDrain, [.pause, .play], "Late cleanup must not change playback or restart recording")
            XCTAssertFalse(fixture.service.isRunning)
            fixture.assertSettingsPreserved()
        }
    }

    @MainActor
    func testStaleRecoveryFailureCannotStopNewRecordingOrResumeItsMedia() async throws {
        try await withASRRecoveryFixture(queryDelay: 0) { fixture in
            await fixture.service.stopWithoutTranscription()
            fixture.service.micStatus = .authorized
            let transport = RecoveryMediaTransport()
            let media = MediaPlaybackService(transport: transport, settle: {})
            fixture.service.useMediaPlaybackForTesting(media)
            SettingsStore.shared.pauseMediaDuringTranscription = true
            let outcome = await fixture.service.start(forDictionaryTraining: true)
            XCTAssertEqual(outcome, .started)
            await media.waitUntilSettled()
            var failurePresentations = 0
            let observation = fixture.service.audioCaptureFailurePresented.sink { failurePresentations += 1 }
            defer { observation.cancel() }
            await fixture.service.failAudioRouteRecoveryForTesting(stale: true)
            await media.waitUntilSettled()
            XCTAssertTrue(fixture.service.isRunning)
            XCTAssertFalse(fixture.service.showError)
            XCTAssertEqual(failurePresentations, 0)
            let commands = await transport.commands
            XCTAssertEqual(commands, [.pause])
            await fixture.service.stopWithoutTranscription()
            await media.waitUntilSettled()
            let stopped = await transport.commands
            XCTAssertEqual(stopped, [.pause, .play])
            fixture.assertSettingsPreserved()
        }
    }

    @MainActor
    func testCancelDuringSlowStartupDiscoveryKeepsMainThreadResponsive() async throws {
        try await withASRRecoveryFixture(queryDelay: 0.6) { fixture in
            await fixture.service.stopWithoutTranscription()
            fixture.service.micStatus = .authorized
            var failurePresentations = 0
            let observation = fixture.service.audioCaptureFailurePresented.sink { failurePresentations += 1 }
            defer { observation.cancel() }
            let starting = Task { await fixture.service.start(forDictionaryTraining: true) }
            for _ in 0..<200 {
                if fixture.hardware.queryCount > 0 { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertEqual(fixture.hardware.queryCount, 1)
            let began = ProcessInfo.processInfo.systemUptime
            await fixture.service.cancelPendingAudioCaptureStart(reason: "cancel_during_device_query")
            let outcome = await starting.value
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            print("MONITOR_RECOVERY_TEST cancelled_discovery_release_ms=\(elapsed * 1000)")
            XCTAssertLessThan(elapsed, 0.2)
            XCTAssertEqual(outcome, .failed)
            XCTAssertFalse(fixture.service.isStarting)
            XCTAssertFalse(fixture.service.isRunning)
            XCTAssertFalse(fixture.service.showError)
            XCTAssertEqual(failurePresentations, 0)
            try await Task.sleep(nanoseconds: 650_000_000)
            XCTAssertEqual(fixture.hardware.startCount(deviceID: 100), 0)
            fixture.assertSettingsPreserved()
        }
    }

    @MainActor
    func testCancellingCallerTaskCancelsNativeStartupAndStaysQuiet() async throws {
        try await withASRRecoveryFixture(queryDelay: 0, builtInStartDelay: 0.15) { fixture in
            await fixture.service.stopWithoutTranscription()
            fixture.service.micStatus = .authorized
            let starting = Task { await fixture.service.start(forDictionaryTraining: true) }
            try await fixture.waitForBuiltInStartCount(1)
            starting.cancel()
            let outcome = await starting.value
            XCTAssertEqual(outcome, .failed)
            try await Task.sleep(nanoseconds: 250_000_000)
            XCTAssertFalse(fixture.service.isRunning)
            XCTAssertFalse(fixture.service.isStarting)
            XCTAssertFalse(fixture.service.showError)
            XCTAssertEqual(fixture.hardware.startCount(deviceID: 100), 1)
            fixture.assertSettingsPreserved()
        }
    }

    @MainActor
    func testTwentyEarlyCancelsNeverStartRecordingAfterCancelReturns() async throws {
        try await withASRRecoveryFixture(queryDelay: 0, builtInStartDelay: 0.01) { fixture in
            await fixture.service.stopWithoutTranscription()
            fixture.service.micStatus = .authorized
            for _ in 0..<20 {
                let starting = Task { await fixture.service.start(forDictionaryTraining: true) }
                for _ in 0..<1000 {
                    if fixture.service.isStarting { break }
                    await Task.yield()
                }
                XCTAssertTrue(fixture.service.isStarting)
                await fixture.service.stopWithoutTranscription()
                _ = await starting.value
                let startsAtCancel = fixture.hardware.startCount(deviceID: 100)
                try await Task.sleep(nanoseconds: 20_000_000)
                XCTAssertFalse(fixture.service.isRunning)
                XCTAssertFalse(fixture.service.isStarting)
                XCTAssertFalse(fixture.service.showError)
                XCTAssertEqual(fixture.hardware.startCount(deviceID: 100), startsAtCancel)
            }
            fixture.assertSettingsPreserved()
        }
    }

    @MainActor
    func testTwentyOrdinaryStartsAndStopsKeepRecoveryIdle() async throws {
        try await withASRRecoveryFixture(queryDelay: 0) { fixture in
            await fixture.service.stopWithoutTranscription()
            fixture.service.micStatus = .authorized
            for _ in 0..<20 {
                let outcome = await fixture.service.start(forDictionaryTraining: true)
                XCTAssertEqual(outcome, .started)
                XCTAssertTrue(fixture.service.isRunning)
                XCTAssertFalse(fixture.service.audioRouteRecoveryStateForTesting.pending)
                var stoppedCallbacks = 0
                _ = await fixture.service.stop(onCaptureStopped: { stoppedCallbacks += 1 }, forDictionaryTraining: true)
                XCTAssertEqual(stoppedCallbacks, 1)
                XCTAssertFalse(fixture.service.isRunning)
                XCTAssertFalse(fixture.service.isStarting)
                XCTAssertFalse(fixture.service.showError)
                fixture.assertSettingsPreserved()
            }
            XCTAssertEqual(fixture.hardware.startCount(deviceID: 100), 20)
        }
    }

    @MainActor
    func testOrdinarySlowStartBeyondFiveSecondsStillReachesFirstPCM() async throws {
        try await withASRRecoveryFixture(queryDelay: 0, builtInStartDelay: 5.2) { fixture in
            await fixture.service.stopWithoutTranscription()
            fixture.service.micStatus = .authorized
            let outcome = await fixture.service.start(forDictionaryTraining: true)
            XCTAssertEqual(outcome, .started)
            XCTAssertTrue(fixture.service.isRunning)
            XCTAssertTrue(fixture.service.audioRouteRecoveryStateForTesting.acceptingPCM)
            XCTAssertFalse(fixture.service.showError)
            XCTAssertEqual(fixture.hardware.startCount(deviceID: 100), 1)
            fixture.assertSettingsPreserved()
            await fixture.service.stopWithoutTranscription()
        }
    }

    @MainActor
    func testCancelThenImmediateRestartWaitsForSafeCleanupAndSucceeds() async throws {
        try await withASRRecoveryFixture(queryDelay: 0, builtInStartDelay: 0.65) { fixture in
            await fixture.service.stopWithoutTranscription()
            fixture.service.micStatus = .authorized
            let first = Task { await fixture.service.start(forDictionaryTraining: true) }
            try await fixture.waitForBuiltInStartCount(1)
            let began = ProcessInfo.processInfo.systemUptime
            await fixture.service.stopWithoutTranscription()
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.3)
            let firstResult = await first.value
            XCTAssertEqual(firstResult, .failed)
            let secondResult = await fixture.service.start(forDictionaryTraining: true)
            XCTAssertEqual(secondResult, .started)
            XCTAssertEqual(fixture.hardware.startCount(deviceID: 100), 2)
            XCTAssertFalse(fixture.service.showError)
            fixture.assertSettingsPreserved()
            await fixture.service.stopWithoutTranscription()
        }
    }

    @MainActor
    func testCancellingImmediateRestartWaitDoesNotStartLater() async throws {
        try await withASRRecoveryFixture(queryDelay: 0, builtInStartDelay: 0.65) { fixture in
            await fixture.service.stopWithoutTranscription()
            fixture.service.micStatus = .authorized
            let first = Task { await fixture.service.start(forDictionaryTraining: true) }
            try await fixture.waitForBuiltInStartCount(1)
            await fixture.service.stopWithoutTranscription()
            _ = await first.value
            let second = Task { await fixture.service.start(forDictionaryTraining: true) }
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertTrue(fixture.service.isStarting)
            let began = ProcessInfo.processInfo.systemUptime
            await fixture.service.stopWithoutTranscription()
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.3)
            let secondResult = await second.value
            XCTAssertEqual(secondResult, .failed)
            try await Task.sleep(nanoseconds: 800_000_000)
            XCTAssertFalse(fixture.service.isRunning)
            XCTAssertFalse(fixture.service.isStarting)
            XCTAssertFalse(fixture.service.showError)
            XCTAssertEqual(fixture.hardware.startCount(deviceID: 100), 1)
            fixture.assertSettingsPreserved()
        }
    }

    @MainActor
    func testDelayedScanRecoversWithoutChangingRecordedAudioOrSettings() async throws {
        try await withASRRecoveryFixture(queryDelay: 0.12) { fixture in
            fixture.service.triggerAudioRouteRecoveryForTesting()
            try await fixture.waitForBuiltInRecovery()
            fixture.assertSessionPreserved()
        }
    }

    @MainActor
    func testTransientScanFailureRetriesWithoutAbandoningRecording() async throws {
        try await withASRRecoveryFixture(queryDelay: 0.12, queryFailures: 1) { fixture in
            fixture.service.triggerAudioRouteRecoveryForTesting()
            try await fixture.waitForBuiltInRecovery()
            fixture.assertSessionPreserved()
            XCTAssertGreaterThanOrEqual(fixture.hardware.queryCount, 2)
        }
    }

    @MainActor
    func testCancelDuringDelayedScanNeverRestartsAfterQueryCompletes() async throws {
        try await withASRRecoveryFixture(queryDelay: 0.65) { fixture in
            fixture.service.triggerAudioRouteRecoveryForTesting()
            for _ in 0..<500 {
                if fixture.hardware.queryCount > 0 { break }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            XCTAssertGreaterThan(fixture.hardware.queryCount, 0)
            await fixture.service.stopWithoutTranscription()
            try await Task.sleep(nanoseconds: 800_000_000)
            XCTAssertFalse(fixture.service.isRunning)
            XCTAssertFalse(fixture.service.audioRouteRecoveryStateForTesting.pending)
            XCTAssertEqual(fixture.hardware.startCount(deviceID: 100), 0)
            XCTAssertEqual(fixture.service.audioRouteRecoveryStateForTesting.samples, [])
            fixture.assertSettingsPreserved()
        }
    }

    @MainActor
    func testTimedOutScanWaitsForQueryCleanupThenRetriesSuccessfully() async throws {
        try await withASRRecoveryFixture(queryDelay: 0, operationTimeout: 0.4, firstQueryDelay: 0.6) { fixture in
            fixture.service.triggerAudioRouteRecoveryForTesting()
            try await fixture.waitForBuiltInRecovery()
            fixture.assertSessionPreserved()
            XCTAssertGreaterThanOrEqual(fixture.hardware.queryCount, 2)
            XCTAssertEqual(fixture.hardware.startCount(deviceID: 100), 1)
            XCTAssertFalse(fixture.service.showError)
        }
    }

    @MainActor
    func testRepeatedScanFailureStopsWithErrorInsteadOfRemainingSilentlyPaused() async throws {
        try await withASRRecoveryFixture(queryDelay: 0.02, queryFailures: 100) { fixture in
            fixture.service.triggerAudioRouteRecoveryForTesting()
            for _ in 0..<1500 {
                if fixture.service.showError { break }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            XCTAssertFalse(fixture.service.isRunning)
            XCTAssertFalse(fixture.service.audioRouteRecoveryStateForTesting.pending)
            XCTAssertFalse(fixture.service.audioRouteRecoveryStateForTesting.acceptingPCM)
            XCTAssertTrue(fixture.service.showError)
            XCTAssertEqual(fixture.hardware.queryCount, 2)
            XCTAssertEqual(fixture.hardware.startCount(deviceID: 100), 0)
            fixture.assertSettingsPreserved()
        }
    }

    @MainActor
    func testEventDuringDelayedCleanupAutomaticallyRecoversAfterCleanup() async throws {
        try await withASRRecoveryFixture(queryDelay: 0, externalStopDelay: 0.9, operationTimeout: 0.4) { fixture in
            _ = await fixture.controller.stop(retainPrepared: false, reason: "injected_delayed_cleanup")
            XCTAssertTrue(fixture.controller.isRecoveringHardware)
            fixture.service.triggerAudioRouteRecoveryForTesting()
            try await fixture.waitForBuiltInRecovery()
            fixture.assertSessionPreserved()
            XCTAssertEqual(fixture.hardware.startCount(deviceID: 100), 1)
        }
    }

    @MainActor
    func testCancelDuringCleanupWaitNeverStartsReplacement() async throws {
        try await withASRRecoveryFixture(queryDelay: 0, externalStopDelay: 0.85, operationTimeout: 0.4) { fixture in
            _ = await fixture.controller.stop(retainPrepared: false, reason: "injected_delayed_cleanup")
            fixture.service.triggerAudioRouteRecoveryForTesting()
            try await Task.sleep(nanoseconds: 330_000_000)
            await fixture.service.stopWithoutTranscription()
            try await Task.sleep(nanoseconds: 700_000_000)
            XCTAssertFalse(fixture.service.isRunning)
            XCTAssertFalse(fixture.service.audioRouteRecoveryStateForTesting.pending)
            XCTAssertFalse(fixture.service.showError)
            XCTAssertEqual(fixture.hardware.startCount(deviceID: 100), 0)
            fixture.assertSettingsPreserved()
        }
    }

    @MainActor
    func testNewEventDuringDelayedScanRetainsLatestRecoveryOnly() async throws {
        try await withASRRecoveryFixture(queryDelay: 0.18) { fixture in
            fixture.service.triggerAudioRouteRecoveryForTesting()
            for _ in 0..<500 {
                if fixture.hardware.queryCount > 0 { break }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            for _ in 0..<20 {
                fixture.service.triggerAudioRouteRecoveryForTesting()
            }
            try await fixture.waitForBuiltInRecovery()
            fixture.assertSessionPreserved()
            XCTAssertEqual(fixture.hardware.startCount(deviceID: 100), 1)
            XCTAssertFalse(fixture.service.showError)
        }
    }

    @MainActor
    func testHealthyCaptureWithoutRouteChangeDoesNoRecoveryWork() async throws {
        try await withASRRecoveryFixture(queryDelay: 0) { fixture in
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertEqual(fixture.hardware.queryCount, 0)
            XCTAssertEqual(fixture.hardware.startCount(deviceID: 200), 1)
            XCTAssertEqual(fixture.hardware.startCount(deviceID: 100), 0)
            XCTAssertEqual(fixture.controller.snapshot.phase, .running)
            XCTAssertTrue(fixture.service.audioRouteRecoveryStateForTesting.acceptingPCM)
            fixture.assertSessionPreserved()
        }
    }
}

@MainActor
private func withASRRecoveryFixture(
    queryDelay: TimeInterval,
    queryFailures: Int = 0,
    externalStopDelay: TimeInterval = 0,
    operationTimeout: TimeInterval? = nil,
    firstQueryDelay: TimeInterval? = nil,
    builtInStartDelay: TimeInterval = 0,
    _ body: (ASRRecoveryFixture) async throws -> Void
) async throws {
    // The hosted app also performs its normal startup device reconciliation.
    // Seed those existing inputs below the fake pair so that unrelated startup
    // discovery cannot masquerade as a recovery-induced preference change.
    let query = DirectCoreAudioLifecycleController(packetHandler: { _, _, _, _, _ in }, onFormatInvalidated: { _ in })
    let liveInputs = try await query.readDeviceSnapshot().devices.filter(\.hasInput)
    let fixture = ASRRecoveryFixture(
        queryDelay: queryDelay,
        queryFailures: queryFailures,
        liveInputs: liveInputs,
        externalStopDelay: externalStopDelay,
        operationTimeout: operationTimeout,
        firstQueryDelay: firstQueryDelay,
        builtInStartDelay: builtInStartDelay
    )
    defer { fixture.restoreSettings() }
    do {
        try await fixture.start()
        try await body(fixture)
    } catch {
        await fixture.service.finishAudioRouteRecoveryTest()
        throw error
    }
    await fixture.service.finishAudioRouteRecoveryTest()
}

@MainActor
private final class ASRRecoveryFixture {
    let service: ASRService
    let controller: DirectCoreAudioLifecycleController
    let hardware: ASRRecoveryHardware
    private let restore: () -> Void
    private let outputUID: String?
    private let modelID: String
    private let providerID: String
    private let expectedPriority: [String]
    private let prefix: [Float] = [0.125, 0.25, 0.375]

    init(queryDelay: TimeInterval, queryFailures: Int, liveInputs: [AudioDevice.Device], externalStopDelay: TimeInterval, operationTimeout: TimeInterval?, firstQueryDelay: TimeInterval?, builtInStartDelay: TimeInterval) {
        let settings = SettingsStore.shared
        let priority = settings.microphonePriority
        let preferred = settings.preferredInputDeviceUID
        let suppressed = settings.suppressedMicrophoneUIDs
        let version = settings.microphoneSelectionMigrationVersion
        let alerts = settings.showMicrophoneChangeAlerts
        let pauseMedia = settings.pauseMediaDuringTranscription
        self.restore = {
            settings.microphonePriority = priority
            settings.preferredInputDeviceUID = preferred
            settings.suppressedMicrophoneUIDs = suppressed
            settings.microphoneSelectionMigrationVersion = version
            settings.showMicrophoneChangeAlerts = alerts
            settings.pauseMediaDuringTranscription = pauseMedia
        }
        settings.microphoneSelectionMigrationVersion = 4
        settings.microphonePriority = [
            .init(uid: "recovery-test-external", name: "Test External"),
            .init(uid: "recovery-test-built-in", name: "Test Built-in"),
        ] + liveInputs.map { .init(uid: $0.uid, name: $0.name) }
        settings.preferredInputDeviceUID = "recovery-test-external"
        settings.suppressedMicrophoneUIDs = []
        settings.showMicrophoneChangeAlerts = false
        settings.pauseMediaDuringTranscription = false
        self.expectedPriority = settings.microphonePriority.map(\.uid)
        self.outputUID = settings.preferredOutputDeviceUID
        self.modelID = settings.selectedSpeechModel.rawValue
        self.providerID = settings.selectedProviderID
        let service = ASRService()
        self.service = service
        let hardware = ASRRecoveryHardware(queryDelay: queryDelay, queryFailures: queryFailures, externalStopDelay: externalStopDelay, firstQueryDelay: firstQueryDelay, builtInStartDelay: builtInStartDelay)
        self.hardware = hardware
        self.controller = DirectCoreAudioLifecycleController(
            packetHandler: service.recoveryPacketHandlerForTesting,
            inputFactory: { id, handler in hardware.makeInput(id, handler: handler) },
            fingerprintReader: { RecoveryInput(deviceID: $0).formatFingerprint },
            installsHardwareListeners: false,
            operationTimeout: operationTimeout,
            deviceSnapshotReader: { refreshLiveness in try hardware.snapshot(refreshLiveness: refreshLiveness) },
            deviceResolver: { try hardware.resolve($0) },
            onFormatInvalidated: { _ in }
        )
    }

    func start() async throws {
        _ = try await self.controller.start(deviceID: 200, deviceName: "Test External", reason: "test_existing_capture")
        self.service.configureAudioRouteRecoveryForTesting(
            controller: self.controller, devices: [self.hardware.builtIn], initialSamples: self.prefix
        )
        self.service.partialTranscription = "words already captured"
    }

    func waitForRecoveryAttempt() async throws {
        for _ in 0..<1500 {
            let state = self.service.audioRouteRecoveryStateForTesting
            if state.pending == false, state.recovering == false { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Recovery retry budget did not finish")
    }

    func waitForBuiltInStartCount(_ count: Int) async throws {
        for _ in 0..<1000 {
            if self.hardware.startCount(deviceID: 100) >= count { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Expected built-in native start count \(count)")
    }

    func waitForBuiltInRecovery() async throws {
        for _ in 0..<1500 {
            let state = self.service.audioRouteRecoveryStateForTesting
            if self.controller.snapshot.deviceID == 100, self.controller.snapshot.phase == .running,
               state.pending == false, state.recovering == false
            { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let state = self.service.audioRouteRecoveryStateForTesting
        XCTFail("Recovery did not finish: running=\(self.service.isRunning) acceptingPCM=\(state.acceptingPCM) pending=\(state.pending) phase=\(self.controller.snapshot.phase)")
    }

    func assertSessionPreserved() {
        XCTAssertTrue(self.service.isRunning)
        XCTAssertTrue(self.service.audioRouteRecoveryStateForTesting.acceptingPCM)
        XCTAssertEqual(Array(self.service.audioRouteRecoveryStateForTesting.samples.prefix(self.prefix.count)), self.prefix)
        XCTAssertEqual(self.service.partialTranscription, "words already captured")
        self.assertSettingsPreserved()
    }

    func assertSettingsPreserved() {
        XCTAssertEqual(SettingsStore.shared.microphonePriority.map(\.uid), self.expectedPriority)
        XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "recovery-test-external")
        XCTAssertEqual(SettingsStore.shared.preferredOutputDeviceUID, self.outputUID)
        XCTAssertEqual(SettingsStore.shared.selectedSpeechModel.rawValue, self.modelID)
        XCTAssertEqual(SettingsStore.shared.selectedProviderID, self.providerID)
    }

    func restoreSettings() { self.restore() }
}

private actor RecoveryMediaTransport: MediaPlaybackTransport {
    private var playing = true
    private(set) var commands: [MediaPlaybackCommand] = []

    func query() async -> MediaPlaybackQueryResult {
        .snapshot(MediaPlaybackSnapshot(bundleIdentifier: "test.player", processID: 1, title: "Test item", isPlaying: self.playing))
    }

    func send(_ command: MediaPlaybackCommand) async -> MediaPlaybackCommandResult {
        self.commands.append(command)
        self.playing = command == .play
        return .helperCompleted
    }
}

private final nonisolated class ASRRecoveryHardware: @unchecked Sendable {
    private let newFallback = AudioDevice.Device(id: 300, uid: "recovery-test-new", name: "New microphone", hasInput: true, hasOutput: false)
    private var newFallbackEnabled = false
    private var newFallbackFails = false
    private var resolutions: [AudioObjectID] = []

    var resolutionAttempts: [AudioObjectID] { self.lock.withLock { self.resolutions } }

    func enableNewFallback(fails: Bool = false) {
        self.lock.withLock { self.newFallbackEnabled = true; self.newFallbackFails = fails }
    }

    func resolve(_ selection: DirectCoreAudioDeviceSelection) throws -> AudioDevice.Device? {
        try self.lock.withLock {
            let device: AudioDevice.Device?
            switch selection {
            case .systemDefault: device = self.builtIn
            case let .preferredUID(uid):
                device = uid == self.builtIn.uid ? self.builtIn : (uid == self.newFallback.uid ? self.newFallback : nil)
            }
            guard let device else { return nil }
            self.resolutions.append(device.id)
            if self.newFallbackEnabled, device.id == 100 || self.newFallbackFails {
                throw NSError(domain: "InjectedMicrophoneStartFailure", code: 1)
            }
            return device
        }
    }

    let builtIn = AudioDevice.Device(id: 100, uid: "recovery-test-built-in", name: "Test Built-in", hasInput: true, hasOutput: false)
    private let lock = NSLock()
    private let queryDelay: TimeInterval
    private let builtInStartDelay: TimeInterval
    private let externalStopDelay: TimeInterval
    private let firstQueryDelay: TimeInterval?
    private var queryFailures: Int
    private var queries = 0
    private var inputs: [RecoveryInput] = []

    init(queryDelay: TimeInterval, queryFailures: Int, externalStopDelay: TimeInterval, firstQueryDelay: TimeInterval?, builtInStartDelay: TimeInterval) {
        self.builtInStartDelay = builtInStartDelay
        self.firstQueryDelay = firstQueryDelay
        self.externalStopDelay = externalStopDelay
        self.queryDelay = queryDelay
        self.queryFailures = queryFailures
    }

    var queryCount: Int { self.lock.withLock { self.queries } }
    func startCount(deviceID: AudioObjectID) -> Int {
        self.lock.withLock { self.inputs.filter { $0.deviceID == deviceID }.reduce(0) { $0 + $1.count("start") } }
    }

    func makeInput(_ id: AudioObjectID, handler: @escaping DirectCoreAudioPacketHandler) -> RecoveryInput {
        let input = RecoveryInput(deviceID: id, delays: id == 200 ? ["stop": self.externalStopDelay] : ["start": self.builtInStartDelay], automaticPCM: true)
        input.setHandler(handler)
        self.lock.withLock { self.inputs.append(input) }
        return input
    }

    func snapshot(refreshLiveness: Bool) throws -> DirectCoreAudioLifecycleController.DeviceSnapshot {
        let fail = self.lock.withLock {
            self.queries += 1
            let fail = self.queryFailures > 0
            self.queryFailures = max(0, self.queryFailures - 1)
            return fail
        }
        let delay = self.lock.withLock { self.queries == 1 ? (self.firstQueryDelay ?? self.queryDelay) : self.queryDelay }
        Thread.sleep(forTimeInterval: delay)
        if fail { throw NSError(domain: "InjectedDeviceScan", code: 1) }
        // The event cache/reconciliation still knows one input; the newer
        // capture-selection snapshot already contains the connected fallback.
        let inputs = self.lock.withLock {
            self.newFallbackEnabled && refreshLiveness == false ? [self.builtIn, self.newFallback] : [self.builtIn]
        }
        return .init(devices: inputs, defaultInputUID: self.builtIn.uid)
    }
}
#endif

/// Injected timing and device changes; these tests never open a physical mic.
final class AudioHardwareAdversarialTests: XCTestCase {
    func testFortyDelayedExternalToBuiltInSwitchesRejectOldDeviceEventsAndPCM() async throws {
        let fleet = RecoveryFleet()
        let controller = fleet.makeController()
        for cycle in 0..<40 {
            let externalID = AudioObjectID(200 + cycle)
            let external = try await controller.start(deviceID: externalID, deviceName: "External", reason: "adversarial_external")
            let oldInput = try XCTUnwrap(fleet.latest)
            oldInput.emit()
            await controller.simulateStoppedHardwareNotificationForTesting(generation: external.generation, reason: "device_is_alive")
            let replacement = try await controller.start(deviceID: 100, deviceName: "Built-in", reason: "adversarial_fallback")
            XCTAssertEqual(replacement.deviceID, 100)
            XCTAssertEqual(replacement.phase, .running)
            let delivered = fleet.deliveryCount
            oldInput.emit()
            // Delayed/duplicate unplug notifications must not retire the new mic.
            for _ in 0..<4 {
                await controller.simulateStoppedHardwareNotificationForTesting(generation: external.generation, reason: "device_is_alive")
            }
            XCTAssertEqual(fleet.deliveryCount, delivered)
            XCTAssertEqual(controller.snapshot.generation, replacement.generation)
            XCTAssertEqual(controller.snapshot.phase, .running)
            try XCTUnwrap(fleet.latest).emit()
            XCTAssertEqual(fleet.deliveryCount, delivered + 1)
            XCTAssertEqual(fleet.runningCount, 1)
        }
        await controller.shutdown(reason: "test_complete")
        XCTAssertEqual(fleet.runningCount, 0)
    }

    func testThirtyCancelledDelayedStartsRemainRetryableAfterCleanup() async throws {
        for _ in 0..<30 {
            let input = RecoveryInput(block: "start", delays: ["invalidate": 0.006])
            let controller = makeRecoveryController(input, timeout: 1)
            let start = Task { try await controller.start(deviceID: 144, deviceName: "External", reason: "cancel_race") }
            try await waitForEvent(input, "start")
            start.cancel()
            _ = await start.result
            XCTAssertTrue(controller.isRecoveringHardware)
            input.emit()
            XCTAssertEqual(input.count("delivered"), 0)
            input.release.signal()
            try await waitForRecovery(controller)
            XCTAssertEqual(input.count("open"), 0)
            let retry = try await controller.start(deviceID: 144, deviceName: "Built-in", reason: "after_cancel_cleanup")
            XCTAssertEqual(retry.phase, .running)
            await controller.shutdown(reason: "test_complete")
            XCTAssertFalse(input.isRunning)
        }
    }

    func testDelayedCleanupRejectsReplacementUntilOldInputIsRetired() async throws {
        let input = RecoveryInput(block: "invalidate")
        defer { input.release.signal() }
        let controller = makeRecoveryController(input, timeout: 0.08)
        _ = try await controller.start(deviceID: 144, deviceName: "External", reason: "before_unplug")
        await controller.invalidate(reason: "unplug")
        XCTAssertTrue(controller.isRecoveringHardware)
        input.emit()
        XCTAssertEqual(input.count("delivered"), 0)
        do {
            _ = try await controller.start(deviceID: 144, deviceName: "Built-in", reason: "during_cleanup")
            XCTFail("Replacement must not overlap unresolved native cleanup")
        } catch {}
        XCTAssertEqual(input.count("start"), 1)
        input.release.signal()
        try await waitForRecovery(controller)
        _ = try await controller.start(deviceID: 144, deviceName: "Built-in", reason: "after_cleanup")
        XCTAssertEqual(input.count("start"), 2)
        await controller.shutdown(reason: "test_complete")
    }

    func testEightyDeadlineRacesNeverDeliverAudioAfterFailedStartup() async throws {
        var successes = 0
        var failures = 0
        for iteration in 0..<80 {
            let delays: [TimeInterval] = [0.002, 0.009, 0.01, 0.012, 0.02]
            let input = RecoveryInput(delays: ["start": delays[iteration % delays.count]])
            let controller = makeRecoveryController(input, timeout: 0.01)
            do {
                _ = try await controller.start(deviceID: 144, deviceName: "Delayed", reason: "deadline_race")
                successes += 1
                input.emit()
                XCTAssertEqual(input.count("delivered"), 1)
            } catch {
                failures += 1
                input.emit()
                XCTAssertEqual(input.count("delivered"), 0)
                try await waitForRecovery(controller)
                input.emit()
                XCTAssertEqual(input.count("delivered"), 0)
            }
            await controller.shutdown(reason: "test_complete")
        }
        XCTAssertGreaterThan(successes, 0)
        XCTAssertGreaterThan(failures, 0)
        print("ADVERSARIAL deadline races: successes=\(successes) failures=\(failures)")
    }

    func testLateDeviceGoneNotificationRestoresReplacementAfterTimedOutFailedCleanup() async throws {
        // Desired behavior. This deliberately exposes any permanent timeout latch
        // that disagrees with the existing safe late-device-removal recovery path.
        let input = RecoveryInput(block: "start", cleanupFails: true)
        defer { input.release.signal() }
        let controller = makeRecoveryController(input)
        do {
            _ = try await controller.start(deviceID: 144, deviceName: "Removed", reason: "timeout_then_removed")
            XCTFail("Injected blocked start must time out")
        } catch {}
        let generation = controller.snapshot.generation
        input.release.signal()
        // Wait for the actual cleanup-failed gate, not just entry into invalidate().
        // Sending removal before cleanup finishes takes a different, healthy path.
        var cleanupFinished = false
        for _ in 0..<1000 {
            do {
                _ = try await controller.prepare(deviceID: 144, deviceName: "Probe", reason: "wait_for_failed_cleanup")
            } catch BoundedAudioHardwareQueue.Failure.cleanupFailed {
                cleanupFinished = true
                break
            } catch {}
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(cleanupFinished)
        await controller.simulateStoppedHardwareNotificationForTesting(generation: generation &- 1, reason: "device_is_alive")
        XCTAssertTrue(controller.isRecoveringHardware, "An old device notification must not clear the current failed generation")
        await controller.simulateStoppedHardwareNotificationForTesting(generation: generation, reason: "device_is_alive")
        XCTAssertFalse(controller.isRecoveringHardware, "Known-stopped old hardware must not leave the timeout gate permanently unavailable")
        do {
            _ = try await controller.prepare(deviceID: 144, deviceName: "Replacement", reason: "late_removal_recovery")
        } catch {
            XCTFail("Safe replacement is still rejected after late device removal: \(error)")
        }
        await controller.shutdown(reason: "test_complete")
    }
}

private final nonisolated class RecoveryFleet: @unchecked Sendable {
    private let lock = NSLock()
    private var inputs: [RecoveryInput] = []
    private var delivered = 0

    var latest: RecoveryInput? { self.lock.withLock { self.inputs.last } }
    var deliveryCount: Int { self.lock.withLock { self.delivered } }
    var runningCount: Int { self.lock.withLock { self.inputs.filter(\.isRunning).count } }

    func makeController() -> DirectCoreAudioLifecycleController {
        DirectCoreAudioLifecycleController(
            packetHandler: { [self] _, _, _, _, _ in self.lock.withLock { self.delivered += 1 } },
            inputFactory: { [self] deviceID, handler in
                let input = RecoveryInput(deviceID: deviceID, delays: ["start": 0.001, "invalidate": 0.001])
                input.setHandler(handler)
                self.lock.withLock { self.inputs.append(input) }
                return input
            },
            fingerprintReader: { RecoveryInput(deviceID: $0).formatFingerprint },
            installsHardwareListeners: false,
            operationTimeout: 1,
            onFormatInvalidated: { _ in }
        )
    }
}

private final nonisolated class FailedDeviceLivenessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var alive: Bool?
    private var shouldBlock = false
    private var ids: [AudioObjectID] = []
    let release = DispatchSemaphore(value: 0)

    init(alive: Bool? = true) { self.alive = alive }
    var deviceIDs: [AudioObjectID] { self.lock.withLock { self.ids } }
    func setAlive(_ alive: Bool?) { self.lock.withLock { self.alive = alive } }
    func blockNextRead(alive: Bool?) {
        self.lock.withLock { self.alive = alive; self.shouldBlock = true }
    }

    func read(_ id: AudioObjectID) -> Bool? {
        let state = self.lock.withLock {
            self.ids.append(id)
            let state = (self.alive, self.shouldBlock)
            self.shouldBlock = false
            return state
        }
        if state.1 { _ = self.release.wait(timeout: .now() + 3) }
        return state.0
    }

    func waitForReadCount(_ count: Int) async throws {
        for _ in 0..<1000 {
            if self.deviceIDs.count >= count { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Failed-device liveness query did not run")
    }
}

private func waitForTopologyCheck(_ controller: DirectCoreAudioLifecycleController) async throws {
    for _ in 0..<1000 {
        if controller.isTopologyRecoveryCheckPendingForTesting == false { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Topology recovery did not finish within its bounded query window")
}

private func waitForFailedCleanup(_ controller: DirectCoreAudioLifecycleController) async throws {
    for _ in 0..<1000 {
        do {
            _ = try await controller.prepare(deviceID: 144, deviceName: "Probe", reason: "wait_for_failed_cleanup")
        } catch BoundedAudioHardwareQueue.Failure.cleanupFailed {
            return
        } catch {}
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Serialized cleanup did not publish its failed state")
}
