import CoreAudio
@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class SystemAudioMuteServiceTests: XCTestCase {
    func testMutesAudibleDeviceAndRestoresItAfterwards() {
        let controller = FakeSystemAudioOutputController(devices: [1: .init(muteSupported: true, isMuted: false)])
        let service = SystemAudioMuteService(outputController: controller)

        service.muteIfAudible()
        XCTAssertTrue(service.isHoldingMute)
        XCTAssertEqual(controller.devices[1]?.isMuted, true)

        service.restoreIfMuted()
        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.devices[1]?.isMuted, false)
    }

    func testLeavesDeviceMutedByTheUserAlone() {
        let controller = FakeSystemAudioOutputController(devices: [1: .init(muteSupported: true, isMuted: true)])
        let service = SystemAudioMuteService(outputController: controller)

        service.muteIfAudible()
        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.setMuteCallCount, 0)

        // The user's own mute must survive a recording.
        service.restoreIfMuted()
        XCTAssertEqual(controller.devices[1]?.isMuted, true)
        XCTAssertEqual(controller.setMuteCallCount, 0)
    }

    func testFallsBackToZeroingVolumeWhenDeviceHasNoMuteSwitch() {
        let controller = FakeSystemAudioOutputController(
            devices: [1: .init(muteSupported: false, volume: 0.65)]
        )
        let service = SystemAudioMuteService(outputController: controller)

        service.muteIfAudible()
        XCTAssertTrue(service.isHoldingMute)
        XCTAssertEqual(controller.devices[1]?.volume, 0)

        service.restoreIfMuted()
        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.devices[1]?.volume, 0.65)
    }

    func testLeavesAlreadySilentVolumeAlone() {
        let controller = FakeSystemAudioOutputController(
            devices: [1: .init(muteSupported: false, volume: 0)]
        )
        let service = SystemAudioMuteService(outputController: controller)

        service.muteIfAudible()
        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.setVolumeCallCount, 0)
    }

    /// Switching output mid-recording must not strand the original device muted.
    func testRestoresTheDeviceItMutedAfterTheDefaultOutputChanges() {
        let controller = FakeSystemAudioOutputController(
            devices: [
                1: .init(muteSupported: true, isMuted: false),
                2: .init(muteSupported: true, isMuted: false),
            ]
        )
        let service = SystemAudioMuteService(outputController: controller)

        service.muteIfAudible()
        XCTAssertEqual(controller.devices[1]?.isMuted, true)

        controller.defaultDeviceID = 2
        service.restoreIfMuted()

        XCTAssertEqual(controller.devices[1]?.isMuted, false)
        XCTAssertEqual(controller.devices[2]?.isMuted, false)
    }

    func testRestoreWithoutMuteIsANoOp() {
        let controller = FakeSystemAudioOutputController(devices: [1: .init(muteSupported: true, isMuted: false)])
        let service = SystemAudioMuteService(outputController: controller)

        service.restoreIfMuted()

        XCTAssertEqual(controller.setMuteCallCount, 0)
        XCTAssertEqual(controller.setVolumeCallCount, 0)
    }

    func testRepeatedCallsMuteAndRestoreOnlyOnce() {
        let controller = FakeSystemAudioOutputController(devices: [1: .init(muteSupported: true, isMuted: false)])
        let service = SystemAudioMuteService(outputController: controller)

        service.muteIfAudible()
        service.muteIfAudible()
        XCTAssertEqual(controller.setMuteCallCount, 1)

        service.restoreIfMuted()
        service.restoreIfMuted()
        XCTAssertEqual(controller.setMuteCallCount, 2)
    }

    func testNoDefaultOutputDeviceLeavesAudioUnchanged() {
        let controller = FakeSystemAudioOutputController(devices: [:])
        controller.defaultDeviceID = nil
        let service = SystemAudioMuteService(outputController: controller)

        service.muteIfAudible()

        XCTAssertFalse(service.isHoldingMute)
        XCTAssertEqual(controller.setMuteCallCount, 0)
        XCTAssertEqual(controller.setVolumeCallCount, 0)
    }

    /// A failed write must not leave the service believing it owns a mute, or it
    /// would refuse to mute every later recording.
    func testFailedMuteDoesNotClaimOwnership() {
        let controller = FakeSystemAudioOutputController(devices: [1: .init(muteSupported: true, isMuted: false)])
        controller.failWrites = true
        let service = SystemAudioMuteService(outputController: controller)

        service.muteIfAudible()
        XCTAssertFalse(service.isHoldingMute)

        controller.failWrites = false
        service.muteIfAudible()
        XCTAssertTrue(service.isHoldingMute)
    }
}

@MainActor
private final class FakeSystemAudioOutputController: SystemAudioOutputControlling {
    struct DeviceState {
        var muteSupported: Bool
        var isMuted: Bool = false
        /// `nil` models a device that exposes no volume control either.
        var volume: Float?
    }

    var devices: [AudioObjectID: DeviceState]
    var defaultDeviceID: AudioObjectID?
    var failWrites = false
    private(set) var setMuteCallCount = 0
    private(set) var setVolumeCallCount = 0

    init(devices: [AudioObjectID: DeviceState]) {
        self.devices = devices
        self.defaultDeviceID = devices.keys.sorted().first
    }

    func defaultOutputDeviceID() -> AudioObjectID? {
        self.defaultDeviceID
    }

    func supportsMute(on deviceID: AudioObjectID) -> Bool {
        self.devices[deviceID]?.muteSupported ?? false
    }

    func isMuted(on deviceID: AudioObjectID) -> Bool? {
        self.devices[deviceID]?.isMuted
    }

    @discardableResult
    func setMuted(_ muted: Bool, on deviceID: AudioObjectID) -> Bool {
        self.setMuteCallCount += 1
        guard self.failWrites == false, self.devices[deviceID] != nil else { return false }
        self.devices[deviceID]?.isMuted = muted
        return true
    }

    func volume(on deviceID: AudioObjectID) -> Float? {
        self.devices[deviceID]?.volume
    }

    @discardableResult
    func setVolume(_ volume: Float, on deviceID: AudioObjectID) -> Bool {
        self.setVolumeCallCount += 1
        guard self.failWrites == false, self.devices[deviceID] != nil else { return false }
        self.devices[deviceID]?.volume = volume
        return true
    }
}
