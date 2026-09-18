@testable import FluidVoice_Debug
import CoreAudio
import XCTest

final class AudioTopologyDiagnosticsTests: XCTestCase {
    func testInputAvailabilityRequiresAtLeastOneLiveEnumeratedDevice() {
        XCTAssertFalse(AudioInputAvailabilityPolicy.hasAvailableInput(liveness: []))
        XCTAssertFalse(AudioInputAvailabilityPolicy.hasAvailableInput(liveness: [false, false]))
        XCTAssertTrue(AudioInputAvailabilityPolicy.hasAvailableInput(liveness: [false, true]))
    }

    override func setUp() {
        super.setUp()
        fv_audio_topology_trace_reset()
        fv_audio_topology_trace_set_enabled(true)
    }

    override func tearDown() {
        fv_audio_topology_trace_reset()
        super.tearDown()
    }

    func testDisabledRingDoesNotReserveSequence() {
        fv_audio_topology_trace_set_enabled(false)
        let sequence = Self.record(.callback, objectID: 41)
        XCTAssertEqual(sequence, 0)
        XCTAssertEqual(fv_audio_topology_trace_latest_sequence(), 0)
    }

    func testRingPublishesMonotonicEventsInOrder() {
        let first = Self.record(.listenerRemoveBegin, objectID: 71)
        let second = Self.record(.listenerRemoveEnd, objectID: 71, status: noErr)

        let snapshot = Self.snapshot()
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertEqual(snapshot.latest, 2)
        XCTAssertEqual(snapshot.events.map(\.sequence), [1, 2])
        XCTAssertEqual(snapshot.events.map(\.objectID), [71, 71])
    }

    func testRingWrapRetainsNewestCapacityWithoutReordering() {
        let capacity = Int(fv_audio_topology_trace_capacity())
        for index in 0..<(capacity + 17) {
            _ = Self.record(.callback, objectID: AudioObjectID(index + 1))
        }

        let snapshot = Self.snapshot()
        XCTAssertEqual(snapshot.events.count, capacity)
        XCTAssertEqual(snapshot.events.first?.sequence, 18)
        XCTAssertEqual(snapshot.events.last?.sequence, UInt64(capacity + 17))
        XCTAssertEqual(snapshot.events.map(\.sequence), snapshot.events.map(\.sequence).sorted())
    }

    func testUnmatchedBeginSurvivesSnapshotAndClassifiesPhaseOpen() throws {
        _ = Self.record(.listenerRemoveBegin, objectID: 99)
        let snapshot = Self.snapshot()

        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertTrue(AudioTopologyDiagnostics.hasOpenTopologyPhase(snapshot.events))
        let line = AudioTopologyDiagnostics.jsonLine(for: try XCTUnwrap(snapshot.events.first))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        )
        XCTAssertEqual(object["event"] as? String, "listenerRemoveBegin")
        XCTAssertEqual((object["object_id"] as? NSNumber)?.uint32Value, 99)
        XCTAssertNil(object["device_name"])
        XCTAssertNil(object["device_uid"])
        XCTAssertNil(object["meeting_title"])
    }

    func testEveryBlockingBoundaryClassifiesAsOpenUntilItsMatchingEnd() {
        let pairs: [(AudioTopologyTraceEvent, AudioTopologyTraceEvent)] = [
            (.enumerationBegin, .enumerationEnd),
            (.replaceBegin, .replaceEnd),
            (.listenerAddBegin, .listenerAddEnd),
            (.listenerRemoveBegin, .listenerRemoveEnd),
            (.halQueryBegin, .halQueryEnd),
            (.vpioEnableBegin, .vpioEnableEnd),
            (.audioUnitBindBegin, .audioUnitBindEnd),
            (.enginePrepareBegin, .enginePrepareEnd),
            (.engineStartBegin, .engineStartEnd),
            (.engineStopBegin, .engineStopEnd),
            (.avfDiscoveryBegin, .avfDiscoveryEnd),
            (.avfDefaultBegin, .avfDefaultEnd),
            (.avfAuthorizationBegin, .avfAuthorizationEnd),
            (.recoveryBegin, .recoveryEnd),
            (.phaseBegin, .phaseEnd),
            (.probeCycleBegin, .probeCycleEnd),
            (.callbackBegin, .callbackEnd),
            (.mainHopBegin, .mainHopEnd),
        ]

        for (begin, end) in pairs {
            fv_audio_topology_trace_reset()
            fv_audio_topology_trace_set_enabled(true)
            _ = Self.record(begin, objectID: 17)
            XCTAssertTrue(AudioTopologyDiagnostics.hasOpenTopologyPhase(Self.snapshot().events), "\(begin)")
            _ = Self.record(end, objectID: 17)
            XCTAssertFalse(AudioTopologyDiagnostics.hasOpenTopologyPhase(Self.snapshot().events), "\(end)")
        }
    }

    func testRecoveryCancelCannotCloseAnUnrelatedPhase() {
        _ = Self.record(.phaseBegin, objectID: 17)
        _ = Self.record(.recoveryCancel, objectID: 17)
        XCTAssertTrue(AudioTopologyDiagnostics.hasOpenTopologyPhase(Self.snapshot().events))
    }

    func testDifferentPropertyAddressCannotCloseOpenBoundary() {
        _ = Self.record(.listenerRemoveBegin, objectID: 17, selector: 100)
        _ = Self.record(.listenerRemoveEnd, objectID: 17, selector: 200)
        XCTAssertTrue(AudioTopologyDiagnostics.hasOpenTopologyPhase(Self.snapshot().events))

        _ = Self.record(.listenerRemoveEnd, objectID: 17, selector: 100)
        XCTAssertFalse(AudioTopologyDiagnostics.hasOpenTopologyPhase(Self.snapshot().events))
    }

    func testInterleavedListenerBoundariesRemainOpenUntilBothEnd() {
        _ = Self.record(.listenerRemoveBegin, objectID: 17, selector: 100)
        _ = Self.record(.listenerRemoveBegin, objectID: 17, selector: 200)
        _ = Self.record(.listenerRemoveEnd, objectID: 17, selector: 100)
        XCTAssertTrue(AudioTopologyDiagnostics.hasOpenTopologyPhase(Self.snapshot().events))

        _ = Self.record(.listenerRemoveEnd, objectID: 17, selector: 200)
        XCTAssertFalse(AudioTopologyDiagnostics.hasOpenTopologyPhase(Self.snapshot().events))
    }

    func testMainThreadFlagIsCapturedPerEvent() async throws {
        await MainActor.run {
            _ = Self.record(.callbackBegin, objectID: 101)
        }
        await Task.detached {
            _ = Self.record(.callbackBegin, objectID: 202)
        }.value

        let events = Self.snapshot().events
        XCTAssertEqual(events.first(where: { $0.objectID == 101 })?.isMainThread, 1)
        XCTAssertEqual(events.first(where: { $0.objectID == 202 })?.isMainThread, 0)
    }

    func testClockAnchorContainsBothTimeDomains() throws {
        let line = AudioTopologyDiagnostics.clockAnchorLine(
            continuousTime: 123,
            wallNanoseconds: 456,
            pid: 789
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual((object["continuous_time"] as? NSNumber)?.uint64Value, 123)
        XCTAssertEqual((object["wall_unix_ns"] as? NSNumber)?.uint64Value, 456)
        XCTAssertEqual((object["pid"] as? NSNumber)?.int32Value, 789)
    }

    func testConcurrentProducersAndSnapshotsRemainOrdered() {
        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            _ = Self.record(.callback, objectID: AudioObjectID(index + 1))
            if index.isMultiple(of: 17) { _ = Self.snapshot() }
        }
        let snapshot = Self.snapshot()
        XCTAssertEqual(snapshot.latest, 1_000)
        XCTAssertEqual(snapshot.events.map(\.sequence), snapshot.events.map(\.sequence).sorted())
        XCTAssertEqual(Set(snapshot.events.map(\.sequence)).count, snapshot.events.count)
    }

    func testJSONSchemaContainsOnlyPrivacyAllowlistedKeys() throws {
        _ = Self.record(.topologySnapshot, objectID: 123)
        let event = try XCTUnwrap(Self.snapshot().events.first)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(AudioTopologyDiagnostics.jsonLine(for: event))
            ) as? [String: Any]
        )
        XCTAssertTrue(Set(object.keys).isSubset(of: AudioTopologyDiagnostics.schemaKeys))
    }

    func testStallClassificationAlwaysRecordsDeadHeartbeat() {
        XCTAssertEqual(
            AudioTopologyStallClassification.classify(
                heartbeatAgeSeconds: nil,
                thresholdSeconds: 2,
                topologyPhaseOpen: false
            ),
            .heartbeatMissing
        )
        XCTAssertEqual(
            AudioTopologyStallClassification.classify(
                heartbeatAgeSeconds: 1.9,
                thresholdSeconds: 2,
                topologyPhaseOpen: true
            ),
            .heartbeatHealthy
        )
        XCTAssertEqual(
            AudioTopologyStallClassification.classify(
                heartbeatAgeSeconds: 2,
                thresholdSeconds: 2,
                topologyPhaseOpen: true
            ),
            .heartbeatStalledPhaseOpen
        )
        XCTAssertEqual(
            AudioTopologyStallClassification.classify(
                heartbeatAgeSeconds: 2,
                thresholdSeconds: 2,
                topologyPhaseOpen: false
            ),
            .heartbeatStalledPhaseClosed
        )
    }

    func testConfigurationParsingIsBoundedAndOptIn() {
        let temporary = URL(fileURLWithPath: "/tmp/fv-audio-topology-tests", isDirectory: true)
        XCTAssertEqual(
            AudioTopologyDiagnosticsConfiguration.resolve(
                environment: [:],
                temporaryDirectory: temporary
            ),
            .init(enabled: false, outputDirectory: temporary, stallThresholdSeconds: 2)
        )
        XCTAssertEqual(
            AudioTopologyDiagnosticsConfiguration.resolve(
                environment: [
                    AudioTopologyDiagnosticsConfiguration.enabledKey: "1",
                    AudioTopologyDiagnosticsConfiguration.outputDirectoryKey: "/tmp/custom-trace",
                    AudioTopologyDiagnosticsConfiguration.stallThresholdKey: "0.1",
                ],
                temporaryDirectory: temporary
            ),
            .init(
                enabled: true,
                outputDirectory: URL(fileURLWithPath: "/tmp/custom-trace", isDirectory: true),
                stallThresholdSeconds: 0.5
            )
        )
    }

    func testTransientInputIsolationExcludesOnlyAggregateVirtualAndUnknownTransports() {
        XCTAssertFalse(
            InputLivenessLedgerIsolationPolicy.permitsListenerForTransientIsolation(
                transportType: kAudioDeviceTransportTypeAggregate
            )
        )
        XCTAssertFalse(
            InputLivenessLedgerIsolationPolicy.permitsListenerForTransientIsolation(
                transportType: kAudioDeviceTransportTypeVirtual
            )
        )
        XCTAssertFalse(
            InputLivenessLedgerIsolationPolicy.permitsListenerForTransientIsolation(
                transportType: kAudioDeviceTransportTypeUnknown
            )
        )

        for persistentTransport in [
            kAudioDeviceTransportTypeBuiltIn,
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeBluetoothLE,
            kAudioDeviceTransportTypePCI,
            kAudioDeviceTransportTypeDisplayPort,
            kAudioDeviceTransportTypeHDMI,
        ] {
            XCTAssertTrue(
                InputLivenessLedgerIsolationPolicy.permitsListenerForTransientIsolation(
                    transportType: persistentTransport
                ),
                "Expected persistent transport \(persistentTransport) to retain liveness monitoring"
            )
        }
    }

    func testAggregateInputLivenessLedgerPolicyExcludesOnlyAggregateTransport() {
        XCTAssertFalse(
            AggregateInputLivenessLedgerPolicy.permitsBroadLedgerMembership(
                transportType: kAudioDeviceTransportTypeAggregate
            )
        )

        for retainedTransport in [
            kAudioDeviceTransportTypeVirtual,
            kAudioDeviceTransportTypeUnknown,
            kAudioDeviceTransportTypeBuiltIn,
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeBluetoothLE,
            kAudioDeviceTransportTypePCI,
            kAudioDeviceTransportTypeDisplayPort,
            kAudioDeviceTransportTypeHDMI,
        ] {
            XCTAssertTrue(
                AggregateInputLivenessLedgerPolicy.permitsBroadLedgerMembership(
                    transportType: retainedTransport
                ),
                "Expected non-aggregate transport \(retainedTransport) to retain liveness monitoring"
            )
        }
    }

    func testRetainedAvailabilityRegistrationSurvivesUnchangedTopologyRefresh() {
        let registration = AudioInputAvailabilityListenerIdentity(
            deviceID: 41,
            uid: "input-a",
            epoch: 1,
            lifecycleGeneration: 7
        )

        // Reconciliation generations are deliberately absent from callback validity. An
        // unchanged registration remains current after any number of topology snapshots.
        XCTAssertTrue(
            AudioInputAvailabilityListenerPolicy.callbackIsCurrent(
                captured: registration,
                registered: registration,
                installed: true
            )
        )
    }

    func testFailedOvertakenAvailabilityAddRequestsFreshReconciliation() {
        XCTAssertTrue(
            AudioInputAvailabilityListenerPolicy.shouldRetryStaleCompletion(
                ownsPendingMarker: true,
                installed: true,
                capturedLifecycleGeneration: 3,
                currentLifecycleGeneration: 3,
                capturedUID: "input-a",
                desiredUID: "input-a",
                hasRegistration: false,
                reconciliationIsStale: true
            )
        )
    }

    func testSuccessfulOvertakenAddAfterSameUIDReconnectIsRetriedNotAccepted() {
        // R1 starts an add for N/A. R2 observes absence. R3 observes the same N/A again.
        // The R1 completion is stale even though AudioObjectID and UID match, so production
        // routes it through cleanup and uses this policy to request a new reconciliation.
        XCTAssertFalse(
            AudioInputAvailabilityListenerPolicy.completionCanInstall(
                statusSucceeded: true,
                ownsPendingMarker: true,
                installed: true,
                capturedLifecycleGeneration: 4,
                currentLifecycleGeneration: 4,
                capturedUID: "input-a",
                desiredUID: "input-a",
                reconciliationIsCurrent: false
            )
        )
        XCTAssertTrue(
            AudioInputAvailabilityListenerPolicy.shouldRetryStaleCompletion(
                ownsPendingMarker: true,
                installed: true,
                capturedLifecycleGeneration: 4,
                currentLifecycleGeneration: 4,
                capturedUID: "input-a",
                desiredUID: "input-a",
                hasRegistration: false,
                reconciliationIsStale: true
            )
        )
    }

    func testServiceRestartRejectsOldAvailabilityWorkAndAcceptsNewLifecycle() {
        let old = AudioInputAvailabilityListenerIdentity(
            deviceID: 41,
            uid: "input-a",
            epoch: 4,
            lifecycleGeneration: 8
        )
        let replacement = AudioInputAvailabilityListenerIdentity(
            deviceID: 41,
            uid: "input-a",
            epoch: 5,
            lifecycleGeneration: 9
        )

        XCTAssertFalse(
            AudioInputAvailabilityListenerPolicy.callbackIsCurrent(
                captured: old,
                registered: replacement,
                installed: true
            )
        )
        XCTAssertFalse(
            AudioInputAvailabilityListenerPolicy.shouldRetryStaleCompletion(
                ownsPendingMarker: true,
                installed: true,
                capturedLifecycleGeneration: 8,
                currentLifecycleGeneration: 9,
                capturedUID: "input-a",
                desiredUID: "input-a",
                hasRegistration: false,
                reconciliationIsStale: true
            )
        )
        XCTAssertTrue(
            AudioInputAvailabilityListenerPolicy.callbackIsCurrent(
                captured: replacement,
                registered: replacement,
                installed: true
            )
        )
    }

    func testReusedAudioObjectIDReplacesUIDAndRejectsOldCallback() {
        let old = AudioInputAvailabilityListenerIdentity(
            deviceID: 77,
            uid: "old-uid",
            epoch: 10,
            lifecycleGeneration: 2
        )
        let replacement = AudioInputAvailabilityListenerIdentity(
            deviceID: 77,
            uid: "new-uid",
            epoch: 11,
            lifecycleGeneration: 2
        )

        XCTAssertTrue(
            AudioInputAvailabilityListenerPolicy.registrationNeedsReplacement(
                registeredUID: old.uid,
                desiredUID: replacement.uid
            )
        )
        XCTAssertFalse(
            AudioInputAvailabilityListenerPolicy.callbackIsCurrent(
                captured: old,
                registered: replacement,
                installed: true
            )
        )
        XCTAssertTrue(
            AudioInputAvailabilityListenerPolicy.callbackIsCurrent(
                captured: replacement,
                registered: replacement,
                installed: true
            )
        )
    }

    func testASRHardwareCallbackDuringRegistrationIsLatchedThenHandled() {
        XCTAssertEqual(
            ASRHardwareListenerPolicy.disposition(
                isTerminating: false,
                lifecycleMatches: true,
                isInstalled: false,
                pendingIdentityMatches: true
            ),
            .latchUntilInstalled
        )
        XCTAssertEqual(
            ASRHardwareListenerPolicy.disposition(
                isTerminating: false,
                lifecycleMatches: true,
                isInstalled: true,
                pendingIdentityMatches: false
            ),
            .handle
        )
    }

    func testASRStaleOrFailedRegistrationCallbackIsIgnored() {
        XCTAssertEqual(
            ASRHardwareListenerPolicy.disposition(
                isTerminating: false,
                lifecycleMatches: false,
                isInstalled: false,
                pendingIdentityMatches: true
            ),
            .ignore
        )
        XCTAssertEqual(
            ASRHardwareListenerPolicy.disposition(
                isTerminating: false,
                lifecycleMatches: true,
                isInstalled: false,
                pendingIdentityMatches: false
            ),
            .ignore
        )
    }

    func testASRLivenessResultCannotAffectReplacementDeviceOrLifecycle() {
        XCTAssertFalse(
            ASRHardwareListenerPolicy.selectedDeviceQueryCanApply(
                isTerminating: false,
                capturedLifecycle: 3,
                currentLifecycle: 3,
                capturedEpoch: 8,
                currentEpoch: 10,
                capturedDeviceID: 41,
                currentDeviceID: 52,
                listenerIsInstalled: true
            )
        )
        XCTAssertFalse(
            ASRHardwareListenerPolicy.selectedDeviceQueryCanApply(
                isTerminating: false,
                capturedLifecycle: 3,
                currentLifecycle: 4,
                capturedEpoch: 8,
                currentEpoch: 8,
                capturedDeviceID: 41,
                currentDeviceID: 41,
                listenerIsInstalled: true
            )
        )
        XCTAssertTrue(
            ASRHardwareListenerPolicy.selectedDeviceQueryCanApply(
                isTerminating: false,
                capturedLifecycle: 4,
                currentLifecycle: 4,
                capturedEpoch: 10,
                currentEpoch: 10,
                capturedDeviceID: 52,
                currentDeviceID: 52,
                listenerIsInstalled: true
            )
        )
    }

    func testASRDeviceListQueryUsesLastRequestWins() {
        XCTAssertFalse(
            ASRHardwareListenerPolicy.deviceListQueryCanApply(
                isTerminating: false,
                capturedLifecycle: 4,
                currentLifecycle: 4,
                capturedQueryGeneration: 10,
                currentQueryGeneration: 11
            )
        )
        XCTAssertTrue(
            ASRHardwareListenerPolicy.deviceListQueryCanApply(
                isTerminating: false,
                capturedLifecycle: 4,
                currentLifecycle: 4,
                capturedQueryGeneration: 11,
                currentQueryGeneration: 11
            )
        )
    }

    func testASRDeviceListQueryCannotApplyAfterResetOrTermination() {
        XCTAssertFalse(
            ASRHardwareListenerPolicy.deviceListQueryCanApply(
                isTerminating: false,
                capturedLifecycle: 4,
                currentLifecycle: 5,
                capturedQueryGeneration: 11,
                currentQueryGeneration: 11
            )
        )
        XCTAssertFalse(
            ASRHardwareListenerPolicy.deviceListQueryCanApply(
                isTerminating: true,
                capturedLifecycle: 5,
                currentLifecycle: 5,
                capturedQueryGeneration: 12,
                currentQueryGeneration: 12
            )
        )
    }

    @discardableResult
    private static func record(
        _ event: AudioTopologyTraceEvent,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector = kAudioDevicePropertyDeviceIsAlive,
        status: OSStatus = AudioTopologyDiagnostics.noStatus
    ) -> UInt64 {
        fv_audio_topology_trace_record(
            event.rawValue,
            AudioTopologyTraceOwner.audioHardwareObserver.rawValue,
            objectID,
            selector,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain,
            AudioTopologyTraceQueueRole.mainControl.rawValue,
            AudioTopologyTracePhase.listener.rawValue,
            AudioTopologyTraceTransport.unknown.rawValue,
            status,
            7
        )
    }

    private static func snapshot(after sequence: UInt64 = 0) -> (
        events: [FVAudioTopologyTraceEvent],
        latest: UInt64
    ) {
        AudioTopologyDiagnostics.snapshot(after: sequence)
    }
}
