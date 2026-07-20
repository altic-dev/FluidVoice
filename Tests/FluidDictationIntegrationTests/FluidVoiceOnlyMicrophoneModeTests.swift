import Foundation
import XCTest

@testable import FluidVoice_Debug

/// Covers `.fluidVoiceOnly` microphone mode: FluidVoice captures the preferred microphone through
/// the direct Core Audio path while leaving the macOS default input alone.
///
/// The contract that matters is negative — this mode must never call
/// `setDefaultInputDevice` — so the coordinator is driven with a fake `AudioDeviceManaging` that
/// records every system-default mutation.
@MainActor
final class FluidVoiceOnlyMicrophoneModeTests: XCTestCase {
    private let directCaptureKey = "ExperimentalDirectAudioCaptureEnabled"
    private let modeKey = "MicrophoneSelectionMode"
    private let preferredInputKey = "PreferredInputDeviceUID"

    private let preferredUID = "test-preferred-mic"
    private let systemUID = "test-system-mic"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: self.directCaptureKey)
        UserDefaults.standard.removeObject(forKey: self.modeKey)
        UserDefaults.standard.removeObject(forKey: self.preferredInputKey)
        UserDefaults.standard.removeObject(forKey: "SystemInputDeviceUIDBeforeManual")
        super.tearDown()
    }

    /// Records what the coordinator does to the system default, and reports a device list in which
    /// the preferred microphone is present but is *not* the current default.
    private final class SpyDeviceManager: AudioDeviceManaging {
        let preferred: AudioDevice.Device
        let systemDefault: AudioDevice.Device
        private(set) var setDefaultCalls: [String] = []
        /// Simulates the preferred microphone being unplugged.
        var hidePreferred = false

        init(preferred: AudioDevice.Device, systemDefault: AudioDevice.Device) {
            self.preferred = preferred
            self.systemDefault = systemDefault
        }

        func listInputDevices() -> [AudioDevice.Device] {
            self.hidePreferred ? [self.systemDefault] : [self.systemDefault, self.preferred]
        }

        func defaultInputDevice() -> AudioDevice.Device? {
            self.systemDefault
        }

        @discardableResult
        func setDefaultInputDevice(uid: String) -> Bool {
            self.setDefaultCalls.append(uid)
            return true
        }
    }

    private func makeSpy() -> SpyDeviceManager {
        SpyDeviceManager(
            preferred: AudioDevice.Device(
                id: 2, uid: self.preferredUID, name: "Preferred Mic", hasInput: true, hasOutput: false
            ),
            systemDefault: AudioDevice.Device(
                id: 1, uid: self.systemUID, name: "System Mic", hasInput: true, hasOutput: false
            )
        )
    }

    private func configure(mode: SettingsStore.MicrophoneSelectionMode, directCapture: Bool) {
        UserDefaults.standard.set(directCapture, forKey: self.directCaptureKey)
        UserDefaults.standard.set(mode.rawValue, forKey: self.modeKey)
        UserDefaults.standard.set(self.preferredUID, forKey: self.preferredInputKey)
    }

    // MARK: - The core contract

    func testFluidVoiceOnlyModeNeverTouchesSystemDefault() {
        self.configure(mode: .fluidVoiceOnly, directCapture: true)
        let spy = self.makeSpy()
        let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: spy)

        let result = coordinator.enforcePreferredInput(reason: "test")

        XCTAssertEqual(result, .skippedFluidVoiceOnlyMode)
        XCTAssertTrue(
            spy.setDefaultCalls.isEmpty,
            "FluidVoice-only mode must never change the macOS default input, got: \(spy.setDefaultCalls)"
        )
    }

    func testManualModeStillMovesSystemDefault() {
        self.configure(mode: .manual, directCapture: true)
        let spy = self.makeSpy()
        let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: spy)

        let result = coordinator.enforcePreferredInput(reason: "test")

        XCTAssertEqual(result, .applied(self.preferredUID))
        XCTAssertEqual(spy.setDefaultCalls, [self.preferredUID], "Manual mode is defined by moving the default")
    }

    func testFluidVoiceOnlyModeCapturesPreferredDevice() {
        self.configure(mode: .fluidVoiceOnly, directCapture: true)
        let spy = self.makeSpy()
        let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: spy)

        XCTAssertEqual(
            coordinator.inputDeviceForCapture()?.uid,
            self.preferredUID,
            "Capture must resolve the preferred device even though the system default is different"
        )
    }

    func testSystemModeCapturesSystemDefault() {
        self.configure(mode: .system, directCapture: true)
        let spy = self.makeSpy()
        let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: spy)

        XCTAssertEqual(coordinator.inputDeviceForCapture()?.uid, self.systemUID)
        XCTAssertEqual(coordinator.enforcePreferredInput(reason: "test"), .skippedSystemMode)
        XCTAssertTrue(spy.setDefaultCalls.isEmpty)
    }

    // MARK: - Gating on the direct capture path

    func testFluidVoiceOnlyDegradesToManualWhenDirectCaptureDisabled() {
        self.configure(mode: .fluidVoiceOnly, directCapture: false)

        XCTAssertEqual(
            SettingsStore.shared.microphoneSelectionMode,
            .manual,
            "Per-app capture only exists on the direct path; without it the preference must still be "
                + "honoured via the system default rather than silently ignored"
        )
    }

    func testFluidVoiceOnlyHonoredWhenDirectCaptureEnabled() {
        self.configure(mode: .fluidVoiceOnly, directCapture: true)

        XCTAssertEqual(SettingsStore.shared.microphoneSelectionMode, .fluidVoiceOnly)
    }

    func testDefaultsToSystemModeForBackwardCompatibility() {
        UserDefaults.standard.set(true, forKey: self.directCaptureKey)
        UserDefaults.standard.removeObject(forKey: self.modeKey)

        XCTAssertEqual(SettingsStore.shared.microphoneSelectionMode, .system)
    }

    // MARK: - Preferred microphone unplugged

    /// A spy whose device list does *not* contain the preferred microphone — i.e. it is unplugged.
    private func makeSpyWithoutPreferred() -> SpyDeviceManager {
        let spy = self.makeSpy()
        spy.hidePreferred = true
        return spy
    }

    /// The regression this guards: capture resolution falls back to the macOS default when the
    /// preferred device is gone, which in this mode would silently record the wrong microphone.
    func testDetectsMissingPreferredMicrophone() {
        self.configure(mode: .fluidVoiceOnly, directCapture: true)
        let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: self.makeSpyWithoutPreferred())

        XCTAssertTrue(coordinator.preferredInputIsMissing())
        XCTAssertEqual(
            coordinator.inputDeviceForCapture()?.uid,
            self.systemUID,
            "Resolution still falls back — which is exactly why the recording path must check first"
        )
    }

    func testPresentPreferredMicrophoneIsNotMissing() {
        self.configure(mode: .fluidVoiceOnly, directCapture: true)
        let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: self.makeSpy())

        XCTAssertFalse(coordinator.preferredInputIsMissing())
    }

    /// `.manual` moves the system default rather than binding a device, so it tolerates a
    /// disconnect and must not be blocked by this check.
    func testManualModeToleratesMissingPreferredMicrophone() {
        self.configure(mode: .manual, directCapture: true)
        let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: self.makeSpyWithoutPreferred())

        XCTAssertFalse(coordinator.preferredInputIsMissing())
    }

    func testNoPreferenceIsNotMissing() {
        UserDefaults.standard.set(true, forKey: self.directCaptureKey)
        UserDefaults.standard.set(SettingsStore.MicrophoneSelectionMode.fluidVoiceOnly.rawValue, forKey: self.modeKey)
        UserDefaults.standard.removeObject(forKey: self.preferredInputKey)
        let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: self.makeSpyWithoutPreferred())

        XCTAssertFalse(coordinator.preferredInputIsMissing())
    }

    func testSystemModeIsNeverMissing() {
        self.configure(mode: .system, directCapture: true)
        let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: self.makeSpyWithoutPreferred())

        XCTAssertFalse(coordinator.preferredInputIsMissing())
    }

    // MARK: - Handing the system default back

    /// Leaving `.manual` — the only mode that moves the macOS default — should offer the input the
    /// user had before FluidVoice took it over.
    func testLeavingManualRestoresPreviousSystemInput() {
        self.configure(mode: .system, directCapture: true)

        // system -> manual captures the pre-takeover default…
        SettingsStore.shared.setMicrophoneSelectionMode(
            .manual, currentSystemInputUID: self.systemUID, availableInputUIDs: [self.systemUID, self.preferredUID]
        )
        // …and manual -> FluidVoice-only hands it back.
        let restored = SettingsStore.shared.setMicrophoneSelectionMode(
            .fluidVoiceOnly,
            currentSystemInputUID: self.preferredUID,
            availableInputUIDs: [self.systemUID, self.preferredUID]
        )

        XCTAssertEqual(restored, self.systemUID)
    }

    /// FluidVoice-only mode never moved the default, so leaving it must not "restore" a stale value
    /// over an input device the user changed themselves in the meantime.
    func testLeavingFluidVoiceOnlyDoesNotRestoreStaleSystemInput() {
        self.configure(mode: .system, directCapture: true)
        SettingsStore.shared.setMicrophoneSelectionMode(
            .manual, currentSystemInputUID: self.systemUID, availableInputUIDs: [self.systemUID, self.preferredUID]
        )
        SettingsStore.shared.setMicrophoneSelectionMode(
            .fluidVoiceOnly,
            currentSystemInputUID: self.preferredUID,
            availableInputUIDs: [self.systemUID, self.preferredUID]
        )

        let restored = SettingsStore.shared.setMicrophoneSelectionMode(
            .system, currentSystemInputUID: "user-picked-mic", availableInputUIDs: [self.systemUID, "user-picked-mic"]
        )

        XCTAssertNil(restored, "FluidVoice-only mode left the default alone; nothing to restore")
    }

    /// Round-tripping the FluidVoice-only switch must not leave the system input stuck on
    /// FluidVoice's choice. `.manual` is entered from `.fluidVoiceOnly` here — never from
    /// `.system` — so the pre-manual device has to be captured on that transition too.
    func testFluidVoiceOnlyRoundTripReleasesTheSystemInput() {
        self.configure(mode: .fluidVoiceOnly, directCapture: true)
        let userDefault = "user-own-mic"
        let available: Set<String> = [userDefault, self.preferredUID]

        // fluidVoiceOnly -> manual: the current default is still the user's own, so capture it.
        SettingsStore.shared.setMicrophoneSelectionMode(
            .manual, currentSystemInputUID: userDefault, availableInputUIDs: available
        )
        // manual has since moved the system default onto the preferred mic…
        // …and toggling back must hand the user's own device back.
        let restored = SettingsStore.shared.setMicrophoneSelectionMode(
            .fluidVoiceOnly, currentSystemInputUID: self.preferredUID, availableInputUIDs: available
        )

        XCTAssertEqual(
            restored,
            userDefault,
            "Leaving .manual must return the input the user had before FluidVoice took it over"
        )
    }

    func testEnteringManualRestoresNothing() {
        self.configure(mode: .system, directCapture: true)

        let restored = SettingsStore.shared.setMicrophoneSelectionMode(
            .manual, currentSystemInputUID: self.systemUID, availableInputUIDs: [self.systemUID]
        )

        XCTAssertNil(restored)
    }

    // MARK: - The switch, end to end

    /// The regression found on-device: flipping the FluidVoice-only switch off and back on left the
    /// macOS input stuck on FluidVoice's microphone. Drives the same transition both entry points
    /// use, and asserts on the actual system-default mutations.
    func testTogglingFluidVoiceOnlyOffAndOnReleasesTheSystemInput() {
        self.configure(mode: .fluidVoiceOnly, directCapture: true)
        let spy = self.makeSpy()   // system default = systemUID, preference = preferredUID
        let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: spy)
        let available: Set<String> = [self.systemUID, self.preferredUID]

        // Off: .manual takes the system input over.
        let toManual = coordinator.setFluidVoiceOnly(
            false, currentSystemInputUID: self.systemUID, availableInputUIDs: available
        )
        XCTAssertEqual(toManual, .manual)
        XCTAssertEqual(spy.setDefaultCalls, [self.preferredUID], "manual moves the default onto the preference")

        // Back on: the user's own device must come back.
        let toFluidOnly = coordinator.setFluidVoiceOnly(
            true, currentSystemInputUID: self.preferredUID, availableInputUIDs: available
        )
        XCTAssertEqual(toFluidOnly, .fluidVoiceOnly)
        XCTAssertEqual(
            spy.setDefaultCalls,
            [self.preferredUID, self.systemUID],
            "leaving .manual must hand back the input the user had before"
        )
    }

    /// Independence is only meaningful between the two preferred modes; from `.system` the switch
    /// isn't offered and must be inert.
    func testTogglingFluidVoiceOnlyIsInertFromSystemMode() {
        self.configure(mode: .system, directCapture: true)
        let spy = self.makeSpy()
        let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: spy)

        let result = coordinator.setFluidVoiceOnly(
            true, currentSystemInputUID: self.systemUID, availableInputUIDs: [self.systemUID]
        )

        XCTAssertNil(result)
        XCTAssertEqual(SettingsStore.shared.microphoneSelectionMode, .system)
        XCTAssertTrue(spy.setDefaultCalls.isEmpty)
    }

    /// Entering FluidVoice-only with no stored preference would resolve straight back to the macOS
    /// default and silently record the wrong microphone, so a preference gets seeded.
    func testTogglingFluidVoiceOnlySeedsAPreferenceWhenNoneIsSet() {
        UserDefaults.standard.set(true, forKey: self.directCaptureKey)
        UserDefaults.standard.set(SettingsStore.MicrophoneSelectionMode.manual.rawValue, forKey: self.modeKey)
        UserDefaults.standard.removeObject(forKey: self.preferredInputKey)
        let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: self.makeSpy())

        coordinator.setFluidVoiceOnly(
            true, currentSystemInputUID: self.systemUID, availableInputUIDs: [self.systemUID]
        )

        XCTAssertEqual(
            SettingsStore.shared.preferredInputDeviceUID,
            self.systemUID,
            "FluidVoice-only with an empty preference would capture the system default it claims to avoid"
        )
    }

    // MARK: - Mode properties

    func testBothPreferredModesUsePreferredDevice() {
        XCTAssertFalse(SettingsStore.MicrophoneSelectionMode.system.usesPreferredInputDevice)
        XCTAssertTrue(SettingsStore.MicrophoneSelectionMode.manual.usesPreferredInputDevice)
        XCTAssertTrue(SettingsStore.MicrophoneSelectionMode.fluidVoiceOnly.usesPreferredInputDevice)
    }
}
