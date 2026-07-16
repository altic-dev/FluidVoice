import Foundation
import XCTest

@testable import FluidVoice_Debug

/// Covers the gating rule at the heart of independent input-device mode:
/// `syncAudioDevicesWithSystem` is only user-controllable when Direct Audio
/// Capture is enabled, because per-app selection rides that path. When Direct
/// Audio Capture is off, sync is force-enabled so the AVAudioEngine fallback
/// keeps following the macOS system default (and never attempts the -10851
/// non-default bind).
final class AudioDeviceSyncSettingTests: XCTestCase {
    private let directCaptureKey = "ExperimentalDirectAudioCaptureEnabled"
    private let syncKey = "SyncAudioDevicesWithSystem"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: directCaptureKey)
        UserDefaults.standard.removeObject(forKey: syncKey)
        super.tearDown()
    }

    func testSyncForcedOnWhenDirectCaptureDisabled() {
        UserDefaults.standard.set(false, forKey: directCaptureKey)
        UserDefaults.standard.set(false, forKey: syncKey)

        XCTAssertTrue(
            SettingsStore.shared.syncAudioDevicesWithSystem,
            "Sync must stay enabled when Direct Audio Capture is off, even if the stored value is false"
        )
    }

    func testSyncHonoredWhenDirectCaptureEnabled() {
        UserDefaults.standard.set(true, forKey: directCaptureKey)

        UserDefaults.standard.set(false, forKey: syncKey)
        XCTAssertFalse(
            SettingsStore.shared.syncAudioDevicesWithSystem,
            "With Direct Audio Capture on, the user's stored sync preference should be honored"
        )

        UserDefaults.standard.set(true, forKey: syncKey)
        XCTAssertTrue(SettingsStore.shared.syncAudioDevicesWithSystem)
    }

    func testDefaultsToSyncOnForBackwardCompatibility() {
        UserDefaults.standard.set(true, forKey: directCaptureKey)
        UserDefaults.standard.removeObject(forKey: syncKey)

        XCTAssertTrue(
            SettingsStore.shared.syncAudioDevicesWithSystem,
            "An unset sync preference should default to on (backward compatible with existing behavior)"
        )
    }
}
