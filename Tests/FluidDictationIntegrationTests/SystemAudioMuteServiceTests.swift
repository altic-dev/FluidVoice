import CoreAudio
@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class SystemAudioMuteServiceTests: XCTestCase {
    func testMutesAudibleDeviceAndRestoresItAfterwards() {
        let (service, controller) = self.makeService(devices: [1: .init(muteSupported: true, uid: "Device-1")])

        service.muteIfAudible()
        XCTAssertTrue(service.isHoldingMute)
        XCTAssertEqual(controller.devices[1]?.isMuted, true)

        service.restoreIfMuted()
        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.devices[1]?.isMuted, false)
    }

    func testLeavesDeviceMutedByTheUserAlone() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, isMuted: true, uid: "Device-2")]
        )

        service.muteIfAudible()
        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.setMuteCallCount, 0)

        // The user's own mute must survive a recording.
        service.restoreIfMuted()
        XCTAssertEqual(controller.devices[1]?.isMuted, true)
        XCTAssertEqual(controller.setMuteCallCount, 0)
    }

    func testFallsBackToZeroingVolumeWhenDeviceHasNoMuteSwitch() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: false, volume: 0.65, uid: "Device-3")]
        )

        service.muteIfAudible()
        XCTAssertTrue(service.isHoldingMute)
        XCTAssertEqual(controller.devices[1]?.volume, 0)

        service.restoreIfMuted()
        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.devices[1]?.volume, 0.65)
    }

    func testLeavesAlreadySilentVolumeAlone() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: false, volume: 0, uid: "Device-4")]
        )

        service.muteIfAudible()
        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.setVolumeCallCount, 0)
    }

    func testRestoreWithoutMuteIsANoOp() {
        let (service, controller) = self.makeService(devices: [1: .init(muteSupported: true, uid: "Device-5")])

        service.restoreIfMuted()

        XCTAssertEqual(controller.setMuteCallCount, 0)
        XCTAssertEqual(controller.setVolumeCallCount, 0)
    }

    func testRepeatedCallsMuteAndRestoreOnlyOnce() {
        let (service, controller) = self.makeService(devices: [1: .init(muteSupported: true, uid: "Device-6")])

        service.muteIfAudible()
        service.muteIfAudible()
        XCTAssertEqual(controller.setMuteCallCount, 1)

        service.restoreIfMuted()
        service.restoreIfMuted()
        XCTAssertEqual(controller.setMuteCallCount, 2)
    }

    func testNoDefaultOutputDeviceLeavesAudioUnchanged() {
        let (service, controller) = self.makeService(devices: [:])

        service.muteIfAudible()

        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.setMuteCallCount, 0)
        XCTAssertEqual(controller.setVolumeCallCount, 0)
    }

    // MARK: - Output Route Changes

    /// Connecting AirPods mid-recording makes a different device audible. Both
    /// must end up silent, and both must be handed back afterwards.
    func testRouteChangeDuringRecordingSilencesTheNewDeviceAndRestoresBoth() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "Device-7"), 2: .init(muteSupported: true, uid: "Device-8")]
        )

        service.muteIfAudible()
        XCTAssertEqual(controller.devices[1]?.isMuted, true)
        XCTAssertEqual(controller.devices[2]?.isMuted, false)

        controller.switchDefaultOutput(to: 2)
        XCTAssertEqual(controller.devices[2]?.isMuted, true)

        service.restoreIfMuted()
        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.devices[1]?.isMuted, false)
        XCTAssertEqual(controller.devices[2]?.isMuted, false)
    }

    func testRouteChangeAfterRestoreLeavesTheNewDeviceAlone() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "Device-9"), 2: .init(muteSupported: true, uid: "Device-10")]
        )

        service.muteIfAudible()
        service.restoreIfMuted()
        XCTAssertFalse(controller.isObservingOutputDevices)

        controller.switchDefaultOutput(to: 2)
        XCTAssertEqual(controller.devices[2]?.isMuted, false)
        XCTAssertFalse(service.isHoldingMute)
    }

    func testObservesOutputDevicesOnlyWhileSilencingOrOwning() {
        let (service, controller) = self.makeService(devices: [1: .init(muteSupported: true, uid: "Device-11")])

        XCTAssertFalse(controller.isObservingOutputDevices)
        service.muteIfAudible()
        XCTAssertTrue(controller.isObservingOutputDevices)
        service.restoreIfMuted()
        XCTAssertFalse(controller.isObservingOutputDevices)
    }

    /// A device that could not be handed back keeps the observer alive, which is
    /// the only way an idle app notices it coming back.
    func testKeepsObservingWhileADeviceIsStillOwned() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "USB-DAC")]
        )

        service.muteIfAudible()
        controller.devices[1]?.isReachable = false
        service.restoreIfMuted()

        XCTAssertTrue(service.isHoldingMute)
        XCTAssertTrue(controller.isObservingOutputDevices)

        controller.devices[1]?.isReachable = true
        service.restoreIfMuted()
        XCTAssertFalse(controller.isObservingOutputDevices)
    }

    /// Plugging the device back in while idle must restore it there and then,
    /// without waiting for another recording.
    func testReconnectWhileIdleRestoresWithoutAnotherRecording() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "USB-DAC")]
        )

        service.muteIfAudible()
        controller.devices[1]?.isReachable = false
        service.restoreIfMuted()
        XCTAssertTrue(service.isHoldingMute)

        // The reconnect notification alone must be enough.
        controller.reconnect(1, as: 42)

        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.devices[42]?.isMuted, false)
        XCTAssertFalse(controller.isObservingOutputDevices)
    }

    /// CoreAudio does not replay a change that predates the listener, so the
    /// observer has to exist before the default output is read. Otherwise a
    /// device that becomes the default in that window stays audible.
    func testRegistersTheObserverBeforeSamplingTheDefaultOutput() throws {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "Speakers")]
        )

        service.muteIfAudible()

        let observed = try XCTUnwrap(controller.operationLog.firstIndex(of: "startObserving"))
        let sampled = try XCTUnwrap(controller.operationLog.firstIndex(of: "readDefaultOutput"))
        XCTAssertLessThan(observed, sampled)
    }

    /// A route change arriving right after the observer is installed is still
    /// handled, even though the first silence is already underway.
    func testRouteChangeImmediatelyAfterStartSilencesTheNewDefault() {
        let (service, controller) = self.makeService(
            devices: [
                1: .init(muteSupported: true, uid: "Speakers"),
                2: .init(muteSupported: true, uid: "AirPods"),
            ]
        )

        service.muteIfAudible()
        controller.switchDefaultOutput(to: 2)

        XCTAssertEqual(controller.devices[1]?.isMuted, true)
        XCTAssertEqual(controller.devices[2]?.isMuted, true)

        service.restoreIfMuted()
        XCTAssertEqual(controller.devices[1]?.isMuted, false)
        XCTAssertEqual(controller.devices[2]?.isMuted, false)
    }

    // MARK: - Failed Restores

    /// A device that cannot be written to during teardown must stay owned, or it
    /// would be left silent with no way back.
    func testFailedRestoreKeepsOwnershipAndRetriesOnTheNextRestore() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "USB-DAC")]
        )

        service.muteIfAudible()
        controller.failWrites = true
        service.restoreIfMuted()

        XCTAssertTrue(service.isHoldingMute)
        XCTAssertEqual(controller.devices[1]?.isMuted, true)

        controller.failWrites = false
        service.restoreIfMuted()

        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.devices[1]?.isMuted, false)
    }

    func testFailedRestoreIsRetriedWhenTheNextRecordingStarts() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "USB-DAC")]
        )

        service.muteIfAudible()
        controller.failWrites = true
        service.restoreIfMuted()
        XCTAssertTrue(service.isHoldingMute)

        controller.failWrites = false
        service.muteIfAudible()
        XCTAssertEqual(controller.devices[1]?.isMuted, true)

        service.restoreIfMuted()
        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.devices[1]?.isMuted, false)
    }

    /// A device unplugged mid-recording reads back as unavailable. Keep it owned
    /// so it is restored once it comes back.
    func testUnreachableDeviceKeepsOwnershipUntilItReturns() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "USB-DAC")]
        )

        service.muteIfAudible()
        controller.devices[1]?.isReachable = false
        service.restoreIfMuted()
        XCTAssertTrue(service.isHoldingMute)

        controller.devices[1]?.isReachable = true
        service.restoreIfMuted()
        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.devices[1]?.isMuted, false)
    }

    /// Unplugging a muted USB or Bluetooth output invalidates its
    /// `AudioObjectID`, and reconnecting the same hardware can produce a
    /// different one. Ownership is keyed by the stable UID so the device is
    /// still restored when it returns.
    func testRestoresDeviceThatReconnectsUnderADifferentDeviceID() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "AirPods-ABC")]
        )

        service.muteIfAudible()
        XCTAssertEqual(controller.devices[1]?.isMuted, true)

        // Unplugged mid-recording: the old id resolves to nothing.
        controller.devices[1]?.isReachable = false
        service.restoreIfMuted()
        XCTAssertTrue(service.isHoldingMute)

        controller.reconnect(1, as: 42)

        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.devices[42]?.isMuted, false)
    }

    /// The same hardware coming back under a new id must not be treated as a
    /// second device to silence.
    func testReconnectedDeviceIsNotSilencedTwice() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "AirPods-ABC")]
        )

        service.muteIfAudible()
        let writesAfterMute = controller.setMuteCallCount

        controller.reconnect(1, as: 42)
        controller.switchDefaultOutput(to: 42)

        XCTAssertEqual(controller.setMuteCallCount, writesAfterMute)
        XCTAssertEqual(controller.devices[42]?.isMuted, true)
    }

    /// Hardware that drops and returns mid-recording can come back with its mute
    /// reset. The ownership entry must not make us skip silencing it again.
    func testReconnectedDeviceThatCameBackAudibleIsSilencedAgain() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "AirPods-ABC")]
        )

        service.muteIfAudible()
        XCTAssertEqual(controller.devices[1]?.isMuted, true)

        // Reconnecting re-enumerates the device, which comes back unmuted.
        controller.reconnect(1, as: 42, isMuted: false)

        XCTAssertEqual(controller.devices[42]?.isMuted, true)

        service.restoreIfMuted()
        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.devices[42]?.isMuted, false)
    }

    /// The same case for the volume fallback: the value handed back must still be
    /// the one the user had before FluidVoice touched the device.
    /// A reconnected device is re-read rather than restored from the value held
    /// before it went away, since that value described the old instance and the
    /// user may have changed the device in between.
    func testReconnectedDeviceIsRecapturedRatherThanRestoredFromAStaleValue() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: false, volume: 0.7, uid: "USB-DAC")]
        )

        service.muteIfAudible()
        XCTAssertEqual(controller.devices[1]?.volume, 0)

        controller.reconnect(1, as: 42, volume: 0.3)
        XCTAssertEqual(controller.devices[42]?.volume, 0)

        service.restoreIfMuted()
        XCTAssertEqual(controller.devices[42]?.volume, 0.3)
    }

    /// Without a UID there is nothing to recognise the device by later, and
    /// CoreAudio can hand its id to different hardware. Releasing ownership is
    /// safer than restoring whatever now answers to that id.
    /// Silencing is a promise to put the device back, which needs a stable
    /// identity. Without a UID there is none, so the output is left alone.
    func testOutputWithoutAUIDIsLeftAlone() {
        let controller = FakeSystemAudioOutputController(devices: [1: .init(muteSupported: true)])
        let service = SystemAudioMuteService(
            outputController: controller,
            retryScheduler: ManualRetryScheduler().schedule
        )

        service.muteIfAudible()

        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.setMuteCallCount, 0)
        XCTAssertEqual(controller.devices[1]?.isMuted, false)
    }

    /// A different device inheriting that id must never be touched.
    func testDoesNotRestoreADifferentDeviceThatInheritsAFreedObjectID() {
        let (service, controller) = self.makeService(devices: [1: .init(muteSupported: true, uid: "Device-13")])

        service.muteIfAudible()
        controller.devices[1]?.isReachable = false
        service.restoreIfMuted()

        // Unrelated hardware, muted by the user, now answers to that id.
        controller.devices[1] = .init(muteSupported: true, isMuted: true, uid: "Device-14")
        service.restoreIfMuted()

        XCTAssertEqual(controller.devices[1]?.isMuted, true)
    }

    /// A device still initialising can reject the write. Claiming ownership
    /// anyway would leave a record for a device that is audible and not ours,
    /// which the next notification would read as the user unmuting it.
    /// A rejected write means the device is not ours, so nothing is recorded for
    /// it. The scheduled retry acquires it once it accepts writes.
    func testRejectedWriteIsNotRecordedAndIsRetried() {
        let retries = ManualRetryScheduler()
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "USB-DAC")],
            retries: retries
        )
        controller.failWrites = true

        service.muteIfAudible()
        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.devices[1]?.isMuted, false)
        XCTAssertEqual(retries.pendingCount, 1)

        controller.failWrites = false
        retries.runPending()

        XCTAssertTrue(service.isHoldingMute)
        XCTAssertEqual(controller.devices[1]?.isMuted, true)
    }

    /// An audible reading on a device we never managed to silence is not the
    /// user taking over, so it must not release ownership.
    /// The retry reads the device again rather than reusing anything from the
    /// failed attempt, so a volume the user picked in between is what gets put
    /// back at teardown.
    func testRetryCapturesTheVolumeTheUserHasNowRatherThanAStaleOne() {
        let retries = ManualRetryScheduler()
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: false, volume: 0.6, uid: "USB-DAC")],
            retries: retries
        )
        controller.failWrites = true

        service.muteIfAudible()
        XCTAssertFalse(service.isHoldingMute)

        // The user picks a different volume before the retry runs.
        controller.failWrites = false
        controller.devices[1]?.volume = 0.4
        retries.runPending()
        XCTAssertEqual(controller.devices[1]?.volume, 0)

        service.restoreIfMuted()
        XCTAssertEqual(controller.devices[1]?.volume, 0.4)
    }

    /// Teardown must not write to a device nothing of ours was applied to.
    /// Teardown must not write to a device that was never silenced.
    func testTeardownLeavesADeviceWeNeverSilencedAlone() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "USB-DAC")]
        )
        controller.failWrites = true

        service.muteIfAudible()
        controller.failWrites = false
        let writesBefore = controller.setMuteCallCount
        service.restoreIfMuted()

        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.setMuteCallCount, writesBefore)
        XCTAssertEqual(controller.devices[1]?.isMuted, false)
    }

    /// A write rejected at the start of a recording must not be forgotten, or
    /// the output stays audible for the whole session with nothing retrying it.
    /// A device change is also an opportunity to re-attempt one that would not
    /// take the write.
    func testRejectedWriteIsRetriedOnADeviceChange() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "Speakers")]
        )
        controller.failWrites = true

        service.muteIfAudible()
        XCTAssertFalse(service.isHoldingMute)

        controller.failWrites = false
        controller.switchDefaultOutput(to: 1)

        XCTAssertTrue(service.isHoldingMute)
        XCTAssertEqual(controller.devices[1]?.isMuted, true)
    }

    /// Teardown must not write to a device whose initial write was rejected,
    /// since nothing of ours was ever applied to it.
    /// An unreadable device is indeterminate rather than silent, so it is
    /// retried rather than passed over.
    func testUnreadableDeviceIsRetriedRatherThanSkipped() {
        let retries = ManualRetryScheduler()
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, isReachable: false, uid: "AirPods")],
            retries: retries
        )

        service.muteIfAudible()
        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(retries.pendingCount, 1)

        controller.devices[1]?.isReachable = true
        retries.runPending()

        XCTAssertTrue(service.isHoldingMute)
        XCTAssertEqual(controller.devices[1]?.isMuted, true)
    }

    /// A device that is not readable yet is indeterminate, not silent, so it
    /// must not be recorded as silenced.
    /// A device that reconnects but is not readable yet must not be recorded as
    /// silenced; it is retried once it answers.
    func testUnreadableReconnectIsRetriedRatherThanRecorded() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "AirPods")]
        )

        service.muteIfAudible()
        // Back under a new id, but not answering property reads yet.
        controller.reconnect(1, as: 42, isMuted: false, isReachable: false)

        // Still held: we hold what to put back and cannot yet tell what the
        // device is doing, so nothing is decided from that.
        XCTAssertTrue(service.isHoldingMute)
        XCTAssertEqual(controller.devices[42]?.isMuted, false)

        controller.devices[42]?.isReachable = true
        controller.switchDefaultOutput(to: 42)

        XCTAssertTrue(service.isHoldingMute)
        XCTAssertEqual(controller.devices[42]?.isMuted, true)
    }

    /// Silence the user creates after our write was rejected is theirs, not
    /// ours, so teardown must not undo it.
    /// Silence the user creates after a rejected write is theirs, so the retry
    /// must leave it alone rather than claim it.
    func testUserSilencingAfterARejectedWriteIsNotClaimed() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "Speakers")]
        )
        controller.failWrites = true
        service.muteIfAudible()
        controller.failWrites = false

        controller.devices[1]?.isMuted = true
        controller.switchDefaultOutput(to: 1)

        let writesBefore = controller.setMuteCallCount
        service.restoreIfMuted()

        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.devices[1]?.isMuted, true)
        XCTAssertEqual(controller.setMuteCallCount, writesBefore)
    }

    /// A reconnect whose disappearance was never observed, because both
    /// notifications arrived together, is still recognised by its new object id.
    func testReconnectIsRecognisedFromTheNewObjectIDAlone() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "AirPods")]
        )

        service.muteIfAudible()
        XCTAssertEqual(controller.devices[1]?.isMuted, true)

        // Swap the device for its reconnected self without ever reporting it
        // absent, which is what a coalesced pair of notifications looks like.
        controller.devices[42] = .init(muteSupported: true, isMuted: false, uid: "AirPods")
        controller.devices.removeValue(forKey: 1)
        controller.switchDefaultOutput(to: 42)

        XCTAssertEqual(controller.devices[42]?.isMuted, true)
        XCTAssertTrue(service.isHoldingMute)
    }

    /// If re-silencing a reconnected device fails, nothing of ours is in effect,
    /// so a silence the user creates afterwards must not be undone at teardown.
    func testUserSilenceAfterAFailedResilenceIsNotUndone() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "AirPods")]
        )

        service.muteIfAudible()
        controller.failWrites = true
        controller.reconnect(1, as: 42, isMuted: false)
        XCTAssertFalse(service.isHoldingMute)

        // The user mutes it themselves afterwards.
        controller.failWrites = false
        controller.devices[42]?.isMuted = true
        let writesBefore = controller.setMuteCallCount
        service.restoreIfMuted()

        XCTAssertEqual(controller.devices[42]?.isMuted, true)
        XCTAssertEqual(controller.setMuteCallCount, writesBefore)
    }

    /// A device that refuses the restore at teardown is re-attempted, since
    /// becoming writable again raises no notification of its own.
    func testFailedRestoreIsRetriedOnItsOwn() {
        let retries = ManualRetryScheduler()
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "USB-DAC")],
            retries: retries
        )

        service.muteIfAudible()
        controller.failWrites = true
        service.restoreIfMuted()

        XCTAssertTrue(service.isHoldingMute)
        XCTAssertEqual(retries.pendingCount, 1)

        controller.failWrites = false
        retries.runPending()

        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.devices[1]?.isMuted, false)
    }

    /// A device that simply will not take the write is not retried forever.
    func testRetriesAreBounded() {
        let retries = ManualRetryScheduler()
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "USB-DAC")],
            retries: retries
        )
        controller.failWrites = true

        service.muteIfAudible()
        for _ in 0..<10 {
            retries.runPending()
        }

        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(retries.pendingCount, 0)
    }

    /// Unmuting and muting again leaves the device looking exactly as we left
    /// it, so a comparison at teardown cannot see it. Watching the device
    /// catches the first change and hands it back there and then.
    func testUserUnmutingAndMutingAgainIsNotUndone() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "Speakers")]
        )

        service.muteIfAudible()
        XCTAssertTrue(service.isHoldingMute)

        controller.changeSilenceState(on: 1, isMuted: false)
        XCTAssertFalse(service.isHoldingMute)

        controller.changeSilenceState(on: 1, isMuted: true)
        let writesBefore = controller.setMuteCallCount
        service.restoreIfMuted()

        XCTAssertEqual(controller.devices[1]?.isMuted, true)
        XCTAssertEqual(controller.setMuteCallCount, writesBefore)
    }

    /// The same round trip on the volume fallback.
    func testUserVolumeRoundTripIsNotUndone() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: false, volume: 0.6, uid: "USB-DAC")]
        )

        service.muteIfAudible()
        XCTAssertTrue(service.isHoldingMute)

        controller.changeSilenceState(on: 1, volume: 0.5)
        XCTAssertFalse(service.isHoldingMute)

        controller.changeSilenceState(on: 1, volume: 0)
        service.restoreIfMuted()

        XCTAssertEqual(controller.devices[1]?.volume, 0)
    }

    /// A device is watched only while it is held.
    func testStopsWatchingADeviceOnceItIsHandedBack() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "Speakers")]
        )

        service.muteIfAudible()
        XCTAssertEqual(controller.silenceStateObservers.count, 1)

        service.restoreIfMuted()
        XCTAssertTrue(controller.silenceStateObservers.isEmpty)
    }

    /// A device that comes back under a new id must be watched at that id, or a
    /// change the user makes on it goes unseen.
    func testWatchesTheReconnectedDeviceAtItsNewID() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "USB-DAC")]
        )

        service.muteIfAudible()
        controller.devices[1]?.isReachable = false
        service.restoreIfMuted()
        XCTAssertTrue(service.isHoldingMute)

        controller.reconnect(1, as: 42, isReachable: false)
        XCTAssertEqual(Array(controller.silenceStateObservers.keys), [42])

        controller.devices[42]?.isReachable = true
        controller.changeSilenceState(on: 42, isMuted: false)
        XCTAssertFalse(service.isHoldingMute)
    }

    /// A restart of the audio service discards every listener, so they have to
    /// be put back and the current output checked again.
    func testReestablishesListenersAfterAnAudioServiceReset() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "Speakers")]
        )

        service.muteIfAudible()
        controller.dropAllObservers()
        XCTAssertFalse(controller.isObservingOutputDevices)

        // The output came back audible while nothing was listening.
        controller.devices[1]?.isMuted = false
        service.reestablishObserversAfterAudioServiceReset()

        XCTAssertTrue(controller.isObservingOutputDevices)
        XCTAssertEqual(controller.devices[1]?.isMuted, true)
    }

    /// A restart has to re-resolve every held device, not just the one that is
    /// currently the default.
    func testResetReresolvesEveryHeldDeviceNotJustTheDefault() {
        let (service, controller) = self.makeService(
            devices: [
                1: .init(muteSupported: true, uid: "Speakers"),
                2: .init(muteSupported: true, uid: "AirPods"),
            ]
        )

        service.muteIfAudible()
        controller.switchDefaultOutput(to: 2)
        XCTAssertEqual(controller.silenceStateObservers.count, 2)

        // The non-default device comes back under a different id across a reset.
        controller.dropAllObservers()
        controller.devices[7] = .init(muteSupported: true, isMuted: true, uid: "Speakers")
        controller.devices.removeValue(forKey: 1)
        service.reestablishObserversAfterAudioServiceReset()

        XCTAssertTrue(controller.silenceStateObservers.keys.contains(7))
        XCTAssertFalse(controller.silenceStateObservers.keys.contains(1))
    }

    // MARK: - Choices Made During A Recording

    /// A volume the user picks during the recording is newer than the one
    /// captured at the start, so restoring must not overwrite it.
    func testUserVolumeChangeDuringRecordingIsNotOverwritten() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: false, volume: 0.4, uid: "Device-15")]
        )

        service.muteIfAudible()
        XCTAssertEqual(controller.devices[1]?.volume, 0)

        controller.devices[1]?.volume = 0.8
        service.restoreIfMuted()

        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.devices[1]?.volume, 0.8)
    }

    func testUserUnmutingDuringRecordingIsRespected() {
        let (service, controller) = self.makeService(devices: [1: .init(muteSupported: true, uid: "Device-16")])

        service.muteIfAudible()
        let writesAfterMute = controller.setMuteCallCount
        controller.devices[1]?.isMuted = false

        service.restoreIfMuted()

        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.setMuteCallCount, writesAfterMute)
    }

    /// Unmuting mid-recording is a deliberate choice. A later device
    /// notification must not be read as a reconnect and undo it.
    func testUserUnmutingDuringRecordingSurvivesADeviceNotification() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: true, uid: "Speakers")]
        )

        service.muteIfAudible()
        let writesAfterMute = controller.setMuteCallCount

        controller.devices[1]?.isMuted = false
        controller.switchDefaultOutput(to: 1)

        XCTAssertEqual(controller.devices[1]?.isMuted, false)
        XCTAssertEqual(controller.setMuteCallCount, writesAfterMute)
        XCTAssertFalse(service.isHoldingMute)
    }

    /// The same for the volume fallback.
    func testUserRaisingVolumeDuringRecordingSurvivesADeviceNotification() {
        let (service, controller) = self.makeService(
            devices: [1: .init(muteSupported: false, volume: 0.6, uid: "USB-DAC")]
        )

        service.muteIfAudible()
        let writesAfterMute = controller.setVolumeCallCount

        controller.devices[1]?.volume = 0.4
        controller.switchDefaultOutput(to: 1)

        XCTAssertEqual(controller.devices[1]?.volume, 0.4)
        XCTAssertEqual(controller.setVolumeCallCount, writesAfterMute)
        XCTAssertFalse(service.isHoldingMute)
    }

    // MARK: - Helpers

    private func makeService(
        devices: [AudioObjectID: FakeSystemAudioOutputController.DeviceState],
        retries: ManualRetryScheduler? = nil
    ) -> (service: SystemAudioMuteService, controller: FakeSystemAudioOutputController) {
        let controller = FakeSystemAudioOutputController(devices: devices)
        let scheduler = retries ?? ManualRetryScheduler()
        let service = SystemAudioMuteService(
            outputController: controller,
            retryScheduler: scheduler.schedule
        )
        return (service, controller)
    }
}

/// Holds scheduled retries so a test can decide when they run.
@MainActor
private final class ManualRetryScheduler {
    private var pending: [@MainActor @Sendable () -> Void] = []

    var pendingCount: Int {
        self.pending.count
    }

    func schedule(after _: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) {
        self.pending.append(action)
    }

    func runPending() {
        let actions = self.pending
        self.pending.removeAll()
        actions.forEach { $0() }
    }
}

@MainActor
private final class FakeSystemAudioOutputController: SystemAudioOutputControlling {
    struct DeviceState {
        var muteSupported: Bool
        var isMuted: Bool = false
        /// `nil` models a device that exposes no volume control either.
        var volume: Float?
        /// `false` models a device that has become unreadable, such as one being
        /// unplugged while a recording tears down.
        var isReachable: Bool = true
        /// `nil` models a device that publishes no UID.
        var uid: String?
    }

    var devices: [AudioObjectID: DeviceState]
    var defaultDeviceID: AudioObjectID?
    var failWrites = false
    private(set) var setMuteCallCount = 0
    private(set) var setVolumeCallCount = 0
    private(set) var isObservingOutputDevices = false
    /// Ordered record of the calls whose relative order matters.
    private(set) var operationLog: [String] = []
    private var onOutputDevicesChange: (@MainActor () -> Void)?
    private(set) var silenceStateObservers: [AudioObjectID: @MainActor () -> Void] = [:]

    init(devices: [AudioObjectID: DeviceState]) {
        self.devices = devices
        self.defaultDeviceID = devices.keys.sorted().first
    }

    /// Simulates the user switching output mid-recording.
    func switchDefaultOutput(to deviceID: AudioObjectID) {
        self.defaultDeviceID = deviceID
        self.onOutputDevicesChange?()
    }

    /// Simulates unplugging a device and reconnecting the same hardware, which
    /// CoreAudio may surface under a different `AudioObjectID` and carrying its
    /// own remembered mute or volume.
    func reconnect(
        _ deviceID: AudioObjectID,
        as newDeviceID: AudioObjectID,
        isMuted: Bool? = nil,
        volume: Float? = nil,
        isReachable: Bool = true
    ) {
        guard var state = self.devices.removeValue(forKey: deviceID) else { return }
        let wasDefault = self.defaultDeviceID == deviceID

        // Unplugging and plugging in are two separate notifications, and the
        // device is genuinely absent in between.
        if wasDefault {
            self.defaultDeviceID = nil
        }
        self.onOutputDevicesChange?()

        state.isReachable = isReachable
        if let isMuted {
            state.isMuted = isMuted
        }
        if let volume {
            state.volume = volume
        }
        self.devices[newDeviceID] = state
        if wasDefault {
            self.defaultDeviceID = newDeviceID
        }
        self.onOutputDevicesChange?()
    }

    func defaultOutputDeviceID() -> AudioObjectID? {
        self.operationLog.append("readDefaultOutput")
        return self.defaultDeviceID
    }

    func deviceUID(for deviceID: AudioObjectID) -> String? {
        self.devices[deviceID]?.uid
    }

    func deviceID(forUID deviceUID: String) -> AudioObjectID? {
        self.devices.first { $0.value.uid == deviceUID }?.key
    }

    func supportsMute(on deviceID: AudioObjectID) -> Bool {
        self.devices[deviceID]?.muteSupported ?? false
    }

    func isMuted(on deviceID: AudioObjectID) -> Bool? {
        guard let device = self.devices[deviceID], device.isReachable else { return nil }
        return device.isMuted
    }

    @discardableResult
    func setMuted(_ muted: Bool, on deviceID: AudioObjectID) -> Bool {
        self.setMuteCallCount += 1
        guard self.canWrite(to: deviceID) else { return false }
        self.devices[deviceID]?.isMuted = muted
        return true
    }

    func volume(on deviceID: AudioObjectID) -> Float? {
        guard let device = self.devices[deviceID], device.isReachable else { return nil }
        return device.volume
    }

    @discardableResult
    func setVolume(_ volume: Float, on deviceID: AudioObjectID) -> Bool {
        self.setVolumeCallCount += 1
        guard self.canWrite(to: deviceID) else { return false }
        self.devices[deviceID]?.volume = volume
        return true
    }

    /// Simulates the user changing a device's mute or volume from elsewhere.
    func changeSilenceState(on deviceID: AudioObjectID, isMuted: Bool? = nil, volume: Float? = nil) {
        if let isMuted {
            self.devices[deviceID]?.isMuted = isMuted
        }
        if let volume {
            self.devices[deviceID]?.volume = volume
        }
        self.silenceStateObservers[deviceID]?()
    }

    func startObservingSilenceState(on deviceID: AudioObjectID, _ onChange: @escaping @MainActor () -> Void) {
        self.silenceStateObservers[deviceID] = onChange
    }

    func stopObservingSilenceState(on deviceID: AudioObjectID) {
        self.silenceStateObservers.removeValue(forKey: deviceID)
    }

    /// Simulates CoreAudio restarting, which discards every listener.
    func dropAllObservers() {
        self.isObservingOutputDevices = false
        self.onOutputDevicesChange = nil
        self.silenceStateObservers.removeAll()
    }

    func startObservingOutputDevices(_ onChange: @escaping @MainActor () -> Void) {
        self.operationLog.append("startObserving")
        self.isObservingOutputDevices = true
        self.onOutputDevicesChange = onChange
    }

    func stopObservingOutputDevices() {
        self.isObservingOutputDevices = false
        self.onOutputDevicesChange = nil
    }

    private func canWrite(to deviceID: AudioObjectID) -> Bool {
        guard self.failWrites == false, let device = self.devices[deviceID] else { return false }
        return device.isReachable
    }
}
