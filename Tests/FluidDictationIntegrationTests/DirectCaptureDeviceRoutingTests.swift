import Foundation
import XCTest

@testable import FluidVoice_Debug

/// Replaces `claude_stuff/harness/fvprobe.sh` — which quit and relaunched the live app five times to
/// assert which microphone got bound — with the same assertions run against the real
/// `DirectCoreAudioLifecycleController.resolveDevice`, using a fake device list.
///
/// This is deliberately not a reimplementation of the routing rule: the production `resolveDevice`
/// switch is what runs, so a change to it fails these tests. The two halves the probe covered are
/// split accordingly — `ASRService.directCaptureSelection` decides *what to look for* (covered in
/// `FluidVoiceOnlyMicrophoneModeTests`) and this covers *what that finds* against a device list.
///
/// The "never moves the macOS default input" half of the contract is enforced here by construction:
/// `InputDeviceResolving` has no mutating member, so the capture path cannot move the default even
/// in principle.
final class DirectCaptureDeviceRoutingTests: XCTestCase {
    private let preferredUID = "test-preferred-mic"
    private let defaultUID = "test-default-mic"

    private func device(_ uid: String, _ name: String, id: AudioObjectID) -> AudioDevice.Device {
        AudioDevice.Device(id: id, uid: uid, name: name, hasInput: true, hasOutput: false)
    }

    /// Reports a device list without touching Core Audio. `preferredPresent: false` simulates the
    /// pinned microphone being unplugged.
    private struct FakeResolver: InputDeviceResolving {
        let preferred: AudioDevice.Device?
        let systemDefault: AudioDevice.Device?

        func defaultInputDevice() -> AudioDevice.Device? { self.systemDefault }

        func inputDevice(uid: String) -> AudioDevice.Device? {
            guard let preferred = self.preferred, preferred.uid == uid else { return nil }
            return preferred
        }
    }

    private func makeController(preferredPresent: Bool, defaultPresent: Bool = true) -> DirectCoreAudioLifecycleController {
        let resolver = FakeResolver(
            preferred: preferredPresent ? self.device(self.preferredUID, "Preferred Mic", id: 2) : nil,
            systemDefault: defaultPresent ? self.device(self.defaultUID, "System Mic", id: 1) : nil
        )
        return DirectCoreAudioLifecycleController(
            packetHandler: { _, _, _, _, _ in },
            deviceResolver: resolver,
            installsHardwareListeners: false,
            onFormatInvalidated: { _ in }
        )
    }

    // MARK: - FluidVoice-only: prefer the pinned device, but do not require it

    func testFluidVoiceOnlyBindsThePreferredDeviceWhenPresent() async throws {
        let controller = self.makeController(preferredPresent: true)

        let device = try await controller.resolveDevice(
            selection: .preferredUIDOrDefault(self.preferredUID),
            reason: "test"
        )

        XCTAssertEqual(device.uid, self.preferredUID, "FluidVoice-only must capture the pinned microphone")
    }

    /// The regression that matters: refusing to record when the pinned mic is unplugged is the
    /// behaviour the 7/23 pivot deliberately replaced.
    func testFluidVoiceOnlyFallsBackToTheDefaultWhenThePreferredDeviceIsUnplugged() async throws {
        let controller = self.makeController(preferredPresent: false)

        let device = try await controller.resolveDevice(
            selection: .preferredUIDOrDefault(self.preferredUID),
            reason: "test"
        )

        XCTAssertEqual(device.uid, self.defaultUID, "An absent pinned mic must fall back, not refuse")
    }

    // MARK: - Manual: upstream's behaviour, unchanged by this PR

    func testManualBindsThePreferredDeviceWhenPresent() async throws {
        let controller = self.makeController(preferredPresent: true)

        let device = try await controller.resolveDevice(
            selection: .preferredUID(self.preferredUID),
            reason: "test"
        )

        XCTAssertEqual(device.uid, self.preferredUID)
    }

    func testManualThrowsWhenThePreferredDeviceIsAbsent() async {
        let controller = self.makeController(preferredPresent: false)

        do {
            let device = try await controller.resolveDevice(
                selection: .preferredUID(self.preferredUID),
                reason: "test"
            )
            XCTFail("Expected a throw; got '\(device.uid)'. Manual mode does not silently substitute.")
        } catch {
            // Expected: upstream 1.6.6 fails loudly here rather than falling back.
        }
    }

    // MARK: - System mode

    func testSystemModeBindsTheMacOSDefault() async throws {
        let controller = self.makeController(preferredPresent: true)

        let device = try await controller.resolveDevice(selection: .systemDefault, reason: "test")

        XCTAssertEqual(
            device.uid,
            self.defaultUID,
            "System mode follows the macOS default even while a preference is stored"
        )
    }

    // MARK: - Nothing available

    func testResolutionThrowsWhenNoInputDeviceExistsAtAll() async {
        let controller = self.makeController(preferredPresent: false, defaultPresent: false)

        for selection in [
            DirectCoreAudioDeviceSelection.systemDefault,
            .preferredUID(self.preferredUID),
            .preferredUIDOrDefault(self.preferredUID),
        ] {
            do {
                _ = try await controller.resolveDevice(selection: selection, reason: "test")
                XCTFail("Expected a throw for \(selection) with no devices present")
            } catch {
                // Expected: there is nothing to record from.
            }
        }
    }
}
