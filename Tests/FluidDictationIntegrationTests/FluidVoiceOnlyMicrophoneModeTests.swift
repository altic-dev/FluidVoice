import Foundation
import XCTest

@testable import FluidVoice_Debug

/// Covers `.fluidVoiceOnly` microphone mode: FluidVoice captures the preferred microphone through
/// the direct Core Audio path while leaving the macOS default input alone. When that microphone is
/// unavailable it falls back to the system default (still without moving it) rather than refusing.
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

    // MARK: - Preferred microphone unplugged: fall back to the default

    /// A spy whose device list does *not* contain the preferred microphone — i.e. it is unplugged.
    private func makeSpyWithoutPreferred() -> SpyDeviceManager {
        let spy = self.makeSpy()
        spy.hidePreferred = true
        return spy
    }

    /// The behaviour this locks in: when the pinned microphone is unplugged, capture resolves to the
    /// macOS default and records *that* — dictation keeps working rather than refusing. The recording
    /// path compares the resolved device against the preference and announces the substitution.
    func testFallsBackToDefaultWhenPreferredMicrophoneUnplugged() {
        self.configure(mode: .fluidVoiceOnly, directCapture: true)
        let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: self.makeSpyWithoutPreferred())

        XCTAssertEqual(
            coordinator.inputDeviceForCapture()?.uid,
            self.systemUID,
            "An unplugged preferred mic must fall back to the system default, not stop recording"
        )
    }

    /// When the pinned microphone is present, capture resolves to it (not the default), so there is
    /// no substitution to announce.
    func testUsesPreferredMicrophoneWhenPresent() {
        self.configure(mode: .fluidVoiceOnly, directCapture: true)
        let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: self.makeSpy())

        XCTAssertEqual(coordinator.inputDeviceForCapture()?.uid, self.preferredUID)
    }

    /// `.manual` moves the system default rather than binding a device, so a disconnect leaves it on
    /// whatever the default now is — it too resolves to the default rather than refusing.
    func testManualModeFallsBackToDefaultWhenPreferredMicrophoneUnplugged() {
        self.configure(mode: .manual, directCapture: true)
        let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: self.makeSpyWithoutPreferred())

        XCTAssertEqual(coordinator.inputDeviceForCapture()?.uid, self.systemUID)
    }

    /// With no preference recorded, capture resolves to the system default regardless of mode.
    func testResolvesToDefaultWhenNoPreferenceRecorded() {
        UserDefaults.standard.set(true, forKey: self.directCaptureKey)
        UserDefaults.standard.set(SettingsStore.MicrophoneSelectionMode.fluidVoiceOnly.rawValue, forKey: self.modeKey)
        UserDefaults.standard.removeObject(forKey: self.preferredInputKey)
        let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: self.makeSpyWithoutPreferred())

        XCTAssertEqual(coordinator.inputDeviceForCapture()?.uid, self.systemUID)
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

    // MARK: - The announcement state machine across a sequence of recordings

    /// The rules only mean anything in sequence, which is what the stored record exists for. Each
    /// step here is one recording start.
    func testFallbackIsAnnouncedOncePerSubstitutionAcrossRecordings() {
        var announcer = ASRService.PreferredMicrophoneFallbackAnnouncer()
        let fallback = self.device(self.systemUID, "System Mic")
        let preferred = self.device(self.preferredUID, "Preferred Mic")

        func recording(_ device: AudioDevice.Device) -> ASRService.PreferredMicrophoneFallbackAnnouncer.Action {
            announcer.announcementNeeded(
                mode: .fluidVoiceOnly, preferredUID: self.preferredUID, recording: device
            )
        }

        XCTAssertEqual(recording(fallback), .announce("System Mic"), "first fallback: tell the user")
        XCTAssertEqual(recording(fallback), .doNothing, "same fallback again: stay quiet")
        XCTAssertEqual(recording(fallback), .doNothing, "and again")
        XCTAssertEqual(
            recording(preferred),
            .withdraw,
            "preferred mic is back: retract the banner, which claims it is still unavailable"
        )
        XCTAssertEqual(
            recording(fallback),
            .announce("System Mic"),
            "dropped out again: this is a new substitution and must be announced afresh"
        )
    }

    /// Without this the app would fire a removal on every ordinary recording, since the common case
    /// (using the preferred device, nothing ever announced) also resolves to "say nothing".
    func testNothingIsWithdrawnWhenNothingWasEverAnnounced() {
        var announcer = ASRService.PreferredMicrophoneFallbackAnnouncer()

        XCTAssertEqual(
            announcer.announcementNeeded(
                mode: .fluidVoiceOnly,
                preferredUID: self.preferredUID,
                recording: self.device(self.preferredUID, "Preferred Mic")
            ),
            .doNothing
        )
    }

    /// Guards the subtle half of the contract: staying quiet on a repeat must NOT clear the record,
    /// or every second recording would re-announce the same substitution.
    func testStayingQuietOnARepeatDoesNotClearTheRecord() {
        var announcer = ASRService.PreferredMicrophoneFallbackAnnouncer()
        let fallback = self.device(self.systemUID, "System Mic")

        _ = announcer.announcementNeeded(
            mode: .fluidVoiceOnly, preferredUID: self.preferredUID, recording: fallback
        )
        _ = announcer.announcementNeeded(
            mode: .fluidVoiceOnly, preferredUID: self.preferredUID, recording: fallback
        )

        XCTAssertEqual(
            announcer.lastAnnouncedFallbackDeviceUID,
            self.systemUID,
            "A quiet repeat still remembers what was announced"
        )
    }

    func testReturningToThePreferredDeviceClearsTheRecordSoALaterFallbackSpeaks() {
        var announcer = ASRService.PreferredMicrophoneFallbackAnnouncer()

        _ = announcer.announcementNeeded(
            mode: .fluidVoiceOnly,
            preferredUID: self.preferredUID,
            recording: self.device(self.systemUID, "System Mic")
        )
        _ = announcer.announcementNeeded(
            mode: .fluidVoiceOnly,
            preferredUID: self.preferredUID,
            recording: self.device(self.preferredUID, "Preferred Mic")
        )

        XCTAssertNil(announcer.lastAnnouncedFallbackDeviceUID)
    }

    // MARK: - The stored mode survives the read-time downgrade

    /// `.fluidVoiceOnly` is kept on disk while direct capture is off so re-enabling restores it.
    /// Anything that persists the mode onward has to read the stored value, or the downgrade
    /// becomes permanent — a backup taken in this state would silently demote the user to `.manual`.
    func testStoredModeKeepsFluidVoiceOnlyWhileTheEffectiveModeDegrades() {
        self.configure(mode: .fluidVoiceOnly, directCapture: false)

        XCTAssertEqual(
            SettingsStore.shared.microphoneSelectionMode,
            .manual,
            "Behaviour degrades while the direct path is off"
        )
        XCTAssertEqual(
            SettingsStore.shared.storedMicrophoneSelectionMode,
            .fluidVoiceOnly,
            "…but the preference itself is preserved"
        )
    }

    func testBackupPreservesALatentFluidVoiceOnlyPreference() {
        self.configure(mode: .fluidVoiceOnly, directCapture: false)

        XCTAssertEqual(
            SettingsStore.shared.makeBackupPayload().microphoneSelectionMode,
            .fluidVoiceOnly,
            "A backup taken while Faster Recording Start is off must not bake in the downgrade"
        )
    }

    func testStoredModeMatchesTheEffectiveModeWhenDirectCaptureIsOn() {
        self.configure(mode: .fluidVoiceOnly, directCapture: true)

        XCTAssertEqual(SettingsStore.shared.microphoneSelectionMode, .fluidVoiceOnly)
        XCTAssertEqual(SettingsStore.shared.storedMicrophoneSelectionMode, .fluidVoiceOnly)
    }

    // MARK: - Direct-capture device selection

    /// The direct path picks its device from the mode alone, separately from the coordinator. A mode
    /// routed to the wrong branch here does not fail — it records the wrong microphone while the UI
    /// still names the preferred one — so pin the mapping rather than trusting it to stay correct
    /// across changes to the capture path.
    func testFluidVoiceOnlySelectsThePreferredDeviceAndToleratesItsAbsence() {
        XCTAssertEqual(
            ASRService.directCaptureSelection(mode: .fluidVoiceOnly, preferredUID: self.preferredUID),
            .preferredUIDOrDefault(self.preferredUID),
            "FluidVoice-only must bind the preferred UID, and must not refuse when it is unplugged"
        )
    }

    func testManualSelectsThePreferredDeviceAndSystemFollowsTheDefault() {
        XCTAssertEqual(
            ASRService.directCaptureSelection(mode: .manual, preferredUID: self.preferredUID),
            .preferredUID(self.preferredUID)
        )
        XCTAssertEqual(
            ASRService.directCaptureSelection(mode: .system, preferredUID: self.preferredUID),
            .systemDefault,
            "System mode follows the macOS default even when a preference is stored"
        )
    }

    // MARK: - The fallback announcement

    private func device(_ uid: String, _ name: String) -> AudioDevice.Device {
        AudioDevice.Device(id: 9, uid: uid, name: name, hasInput: true, hasOutput: false)
    }

    private func announcement(
        recording uid: String,
        named name: String = "Fallback Mic",
        lastAnnounced: String? = nil,
        mode: SettingsStore.MicrophoneSelectionMode = .fluidVoiceOnly
    ) -> ASRService.PreferredMicrophoneFallbackAnnouncement {
        ASRService.preferredMicrophoneFallbackAnnouncement(
            mode: mode,
            preferredUID: self.preferredUID,
            recording: self.device(uid, name),
            lastAnnouncedFallbackDeviceUID: lastAnnounced
        )
    }

    func testRecordingThePreferredDeviceAnnouncesNothing() {
        XCTAssertEqual(self.announcement(recording: self.preferredUID), .none)
    }

    func testRecordingSomethingElseAnnouncesTheDeviceActuallyBeingRecorded() {
        XCTAssertEqual(
            self.announcement(recording: self.systemUID, named: "System Mic"),
            .announce(deviceUID: self.systemUID, deviceName: "System Mic"),
            "The notification must name the fallback device, not the preference it replaced"
        )
    }

    func testTheSameFallbackIsNotAnnouncedTwice() {
        XCTAssertEqual(
            self.announcement(recording: self.systemUID, lastAnnounced: self.systemUID),
            .alreadyAnnounced,
            "Re-announcing every recording would make the notification noise"
        )
    }

    func testADifferentFallbackDeviceAnnouncesAfresh() {
        XCTAssertEqual(
            self.announcement(recording: "third-mic", named: "Third Mic", lastAnnounced: self.systemUID),
            .announce(deviceUID: "third-mic", deviceName: "Third Mic"),
            "Falling back to a *different* device is a new substitution the user has not been told about"
        )
    }

    /// The reset is what makes a later fallback announce again: `.none` clears the record, so
    /// unplug -> announce -> replug -> unplug announces a second time rather than staying silent.
    func testReturningToThePreferredDeviceClearsTheAnnouncementRecord() {
        XCTAssertEqual(
            self.announcement(recording: self.preferredUID, lastAnnounced: self.systemUID),
            .none
        )
    }

    func testOtherModesNeverAnnounce() {
        for mode in [SettingsStore.MicrophoneSelectionMode.manual, .system] {
            XCTAssertEqual(
                self.announcement(recording: self.systemUID, mode: mode),
                .none,
                "\(mode) does not promise to capture a pinned device, so a fallback is not a substitution"
            )
        }
    }

    func testNoPreferenceOrNoDeviceAnnouncesNothing() {
        XCTAssertEqual(
            ASRService.preferredMicrophoneFallbackAnnouncement(
                mode: .fluidVoiceOnly,
                preferredUID: nil,
                recording: self.device(self.systemUID, "System Mic"),
                lastAnnouncedFallbackDeviceUID: nil
            ),
            .none
        )
        XCTAssertEqual(
            ASRService.preferredMicrophoneFallbackAnnouncement(
                mode: .fluidVoiceOnly,
                preferredUID: self.preferredUID,
                recording: nil,
                lastAnnouncedFallbackDeviceUID: nil
            ),
            .none,
            "No resolved device means nothing was recorded to announce"
        )
    }

    func testAnEmptyPreferenceFallsBackToTheSystemDefaultInEveryMode() {
        for mode in [
            SettingsStore.MicrophoneSelectionMode.system,
            .manual,
            .fluidVoiceOnly,
        ] {
            XCTAssertEqual(
                ASRService.directCaptureSelection(mode: mode, preferredUID: nil),
                .systemDefault,
                "\(mode) with no preference must not bind an empty UID"
            )
            XCTAssertEqual(
                ASRService.directCaptureSelection(mode: mode, preferredUID: ""),
                .systemDefault,
                "\(mode) with an empty preference must not bind an empty UID"
            )
        }
    }
}
