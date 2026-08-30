import CoreAudio
@testable import FluidVoice_Debug
import Foundation
import XCTest

final class DirectAudioReliabilityTests: XCTestCase {
    func testOutputKeepAliveTargetsTheBuiltInSpeakerForAppleSiliconInternalInput() {
        XCTAssertEqual(
            BuiltInOutputKeepAlivePolicy.outputDeviceID(
                inputDeviceID: 100,
                devices: [Self.internalMicrophone, Self.builtInSpeaker(id: 200)],
                isAppleSilicon: true,
                isOutputAlive: { _ in true }
            ),
            200
        )
    }

    func testOutputKeepAliveDoesNotAffectOtherInputsOrIntelMacs() {
        let devices = [
            Self.internalMicrophone,
            Self.externalMicrophone,
            Self.builtInSpeaker(id: 200),
        ]

        XCTAssertNil(BuiltInOutputKeepAlivePolicy.outputDeviceID(
            inputDeviceID: 100,
            devices: devices,
            isAppleSilicon: false,
            isOutputAlive: { _ in true }
        ))
        XCTAssertNil(BuiltInOutputKeepAlivePolicy.outputDeviceID(
            inputDeviceID: 101,
            devices: devices,
            isAppleSilicon: true,
            isOutputAlive: { _ in true }
        ))
    }

    func testOutputKeepAliveRejectsAnUnavailableBuiltInSpeaker() {
        XCTAssertNil(BuiltInOutputKeepAlivePolicy.outputDeviceID(
            inputDeviceID: 100,
            devices: [Self.internalMicrophone, Self.builtInSpeaker(id: 200)],
            isAppleSilicon: true,
            isOutputAlive: { _ in false }
        ))
    }

    func testOutputKeepAliveUsesTheCurrentBuiltInSpeaker() {
        XCTAssertEqual(
            BuiltInOutputKeepAlivePolicy.outputDeviceID(
                inputDeviceID: 100,
                devices: [
                    Self.internalMicrophone,
                    Self.builtInSpeaker(id: 200),
                    Self.builtInSpeaker(id: 201),
                ],
                isAppleSilicon: true,
                isOutputAlive: { $0 == 201 }
            ),
            201
        )
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
        await Task.yield()

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
