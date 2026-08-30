@testable import FluidVoice_Debug
import CoreAudio
import XCTest

final class AudioTopologyDiagnosticsTests: XCTestCase {
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

    @discardableResult
    private static func record(
        _ event: AudioTopologyTraceEvent,
        objectID: AudioObjectID,
        status: OSStatus = AudioTopologyDiagnostics.noStatus
    ) -> UInt64 {
        fv_audio_topology_trace_record(
            event.rawValue,
            AudioTopologyTraceOwner.audioHardwareObserver.rawValue,
            objectID,
            kAudioDevicePropertyDeviceIsAlive,
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
