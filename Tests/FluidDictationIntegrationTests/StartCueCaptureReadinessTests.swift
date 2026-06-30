@testable import FluidVoice_Debug
import CoreAudio
import XCTest

final class StartCueCaptureReadinessTests: XCTestCase {
    private let configuration = StartCueCaptureReadiness.Configuration(
        stableDelaySeconds: 0.45,
        afterRecoveryDelaySeconds: 0.10,
        timeoutSeconds: 1.75,
        minimumSamples: 2_048
    )

    func testRestartInvalidatesPreviousRecordingSession() {
        var tracker = RecordingSessionTracker()

        let firstSessionID = tracker.beginSession()
        let secondSessionID = tracker.beginSession()

        XCTAssertFalse(tracker.isActive(firstSessionID))
        XCTAssertTrue(tracker.isActive(secondSessionID))

        tracker.clearSession()

        XCTAssertNil(tracker.currentID)
        XCTAssertFalse(tracker.isActive(secondSessionID))
    }

    func testStaleSessionWaiterIsInactiveEvenWhenCaptureIsOtherwiseReady() {
        let evaluation = StartCueCaptureReadiness.evaluate(
            self.snapshot(
                activeSessionID: 2,
                requestedSessionID: 1,
                sampleCount: 4_096,
                engineStartedAt: 9.0
            ),
            configuration: self.configuration
        )

        XCTAssertEqual(evaluation.decision, .inactive)
    }

    func testPostRecoveryReadinessRequiresSamplesAfterRecovery() {
        let waiting = StartCueCaptureReadiness.evaluate(
            self.snapshot(
                sampleCount: 4_096,
                startupRecoveryCompletedAt: 10.0,
                startupRecoveryCompletedSampleCount: 4_096
            ),
            configuration: self.configuration
        )

        XCTAssertEqual(waiting.decision, .wait)
        XCTAssertEqual(waiting.readySampleCount, 0)

        let ready = StartCueCaptureReadiness.evaluate(
            self.snapshot(
                sampleCount: 6_144,
                startupRecoveryCompletedAt: 10.0,
                startupRecoveryCompletedSampleCount: 4_096
            ),
            configuration: self.configuration
        )

        XCTAssertEqual(ready.decision, .ready)
        XCTAssertEqual(ready.readySampleCount, 2_048)
    }

    func testTimeoutFallbackStillRequiresCurrentSessionSamplesAndIdleRouteRecovery() {
        let staleSession = StartCueCaptureReadiness.evaluate(
            self.snapshot(
                activeSessionID: 2,
                requestedSessionID: 1,
                now: 12.0,
                waitStartedAt: 10.0,
                sampleCount: 4_096,
                engineStartedAt: 11.9
            ),
            configuration: self.configuration
        )

        XCTAssertEqual(staleSession.decision, .inactive)

        let activeSessionWithSamples = StartCueCaptureReadiness.evaluate(
            self.snapshot(
                now: 12.0,
                waitStartedAt: 10.0,
                sampleCount: 128,
                engineStartedAt: 11.9
            ),
            configuration: self.configuration
        )

        XCTAssertEqual(activeSessionWithSamples.decision, .timedOut(ready: true))

        let routeRecoveryPending = StartCueCaptureReadiness.evaluate(
            self.snapshot(
                now: 12.0,
                waitStartedAt: 10.0,
                sampleCount: 4_096,
                routeRecoveryIdle: false,
                engineStartedAt: 9.0
            ),
            configuration: self.configuration
        )

        XCTAssertEqual(routeRecoveryPending.decision, .timedOut(ready: false))
    }

    func testBluetoothDeviceDetectionUsesNameFallbackForAggregateRoutes() {
        let airPods = AudioDevice.Device(
            id: AudioObjectID(kAudioObjectUnknown),
            uid: "airpods",
            name: "Jon's AirPods Pro",
            hasInput: true,
            hasOutput: true
        )

        XCTAssertTrue(AudioDevice.isBluetoothDevice(airPods))
    }

    func testBluetoothDeviceDetectionDoesNotFlagOrdinaryUnknownDeviceNames() {
        let builtInMic = AudioDevice.Device(
            id: AudioObjectID(kAudioObjectUnknown),
            uid: "builtin",
            name: "MacBook Pro Microphone",
            hasInput: true,
            hasOutput: false
        )

        XCTAssertFalse(AudioDevice.isBluetoothDevice(builtInMic))
    }

    private func snapshot(
        isRunning: Bool = true,
        activeSessionID: UInt64? = 1,
        requestedSessionID: UInt64 = 1,
        now: TimeInterval = 10.2,
        waitStartedAt: TimeInterval = 10.0,
        sampleCount: Int,
        routeRecoveryIdle: Bool = true,
        startupRecoveryScheduled: Bool = false,
        startupRecoveryCompletedAt: TimeInterval? = nil,
        startupRecoveryCompletedSampleCount: Int? = nil,
        engineStartedAt: TimeInterval? = nil
    ) -> StartCueCaptureReadiness.Snapshot {
        StartCueCaptureReadiness.Snapshot(
            isRunning: isRunning,
            activeSessionID: activeSessionID,
            requestedSessionID: requestedSessionID,
            now: now,
            waitStartedAt: waitStartedAt,
            sampleCount: sampleCount,
            routeRecoveryIdle: routeRecoveryIdle,
            startupRecoveryScheduled: startupRecoveryScheduled,
            startupRecoveryCompletedAt: startupRecoveryCompletedAt,
            startupRecoveryCompletedSampleCount: startupRecoveryCompletedSampleCount,
            engineStartedAt: engineStartedAt
        )
    }
}
