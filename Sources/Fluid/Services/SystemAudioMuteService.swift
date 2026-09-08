import AudioToolbox
import CoreAudio
import Foundation

/// Minimal CoreAudio surface used by ``SystemAudioMuteService``.
///
/// Extracted as a protocol so the service can be tested without touching the
/// user's real audio hardware.
@MainActor
protocol SystemAudioOutputControlling {
    func defaultOutputDeviceID() -> AudioObjectID?
    /// `true` when the device exposes a writable mute switch on its main element.
    func supportsMute(on deviceID: AudioObjectID) -> Bool
    func isMuted(on deviceID: AudioObjectID) -> Bool?
    @discardableResult
    func setMuted(_ muted: Bool, on deviceID: AudioObjectID) -> Bool
    func volume(on deviceID: AudioObjectID) -> Float?
    @discardableResult
    func setVolume(_ volume: Float, on deviceID: AudioObjectID) -> Bool
}

/// Silences the default output device while a recording is in progress.
///
/// Unlike ``MediaPlaybackService``, which asks the frontmost Now Playing app to
/// pause, this works for any audio reaching the speakers — including browser
/// tabs, games, and conferencing apps that expose no media controls at all.
///
/// The service only ever reverts its own change: audio the user already
/// silenced stays silenced, and the device muted at the start of a recording is
/// the device restored at the end, even if the default output changed meanwhile.
@MainActor
final class SystemAudioMuteService {
    /// Volumes at or below this are treated as already silent, matching the
    /// audibility check in ``TranscriptionSoundPlayer``.
    private static let silentVolumeThreshold: Float = 0.001

    static let shared = SystemAudioMuteService(outputController: CoreAudioOutputController())

    /// What we changed, and where, so restoring is exact rather than best guess.
    private enum ActiveMute {
        case muteSwitch(deviceID: AudioObjectID)
        case zeroedVolume(deviceID: AudioObjectID, previousVolume: Float)
    }

    private let outputController: any SystemAudioOutputControlling
    private var activeMute: ActiveMute?

    /// Creates an isolated service with an injectable output layer for tests.
    init(outputController: any SystemAudioOutputControlling) {
        self.outputController = outputController
    }

    /// `true` while this service is holding the output device silent.
    var isHoldingMute: Bool {
        self.activeMute != nil
    }

    // MARK: - Public API

    /// Silences the default output device if it is currently audible.
    ///
    /// Does nothing when the output is already silent, so a user who muted their
    /// Mac before recording is not unmuted when the recording ends. Prefers the
    /// device mute switch, which leaves the volume slider untouched, and falls
    /// back to dropping the volume to zero on devices without one.
    func muteIfAudible() {
        guard self.activeMute == nil else {
            DebugLogger.shared.debug(
                "SystemAudioMuteService: Output already muted by this session",
                source: "SystemAudioMuteService"
            )
            return
        }

        guard let deviceID = self.outputController.defaultOutputDeviceID() else {
            DebugLogger.shared.warning(
                "SystemAudioMuteService: No default output device; leaving audio unchanged",
                source: "SystemAudioMuteService"
            )
            return
        }

        if self.outputController.supportsMute(on: deviceID) {
            self.muteUsingMuteSwitch(on: deviceID)
        } else {
            self.muteUsingVolume(on: deviceID)
        }
    }

    /// Restores audio only if this service silenced it.
    ///
    /// Safe to call on any teardown path, including ones where no recording ever
    /// muted anything.
    func restoreIfMuted() {
        guard let activeMute = self.activeMute else { return }

        // Clear ownership first so a failed restore cannot strand the service in
        // a state where it refuses to mute the next recording.
        self.activeMute = nil

        switch activeMute {
        case let .muteSwitch(deviceID):
            let didRestore = self.outputController.setMuted(false, on: deviceID)
            self.logRestore(succeeded: didRestore, description: "unmuted device \(deviceID)")

        case let .zeroedVolume(deviceID, previousVolume):
            let didRestore = self.outputController.setVolume(previousVolume, on: deviceID)
            self.logRestore(
                succeeded: didRestore,
                description: "restored volume \(previousVolume) on device \(deviceID)"
            )
        }
    }

    // MARK: - Muting Strategies

    private func muteUsingMuteSwitch(on deviceID: AudioObjectID) {
        guard let isMuted = self.outputController.isMuted(on: deviceID) else {
            DebugLogger.shared.warning(
                "SystemAudioMuteService: Could not read mute state; leaving audio unchanged",
                source: "SystemAudioMuteService"
            )
            return
        }

        guard isMuted == false else {
            DebugLogger.shared.debug(
                "SystemAudioMuteService: Output already muted by the user, not taking ownership",
                source: "SystemAudioMuteService"
            )
            return
        }

        guard self.outputController.setMuted(true, on: deviceID) else {
            DebugLogger.shared.error(
                "SystemAudioMuteService: Failed to mute device \(deviceID)",
                source: "SystemAudioMuteService"
            )
            return
        }

        self.activeMute = .muteSwitch(deviceID: deviceID)
        DebugLogger.shared.info(
            "SystemAudioMuteService: Muted device \(deviceID) for recording",
            source: "SystemAudioMuteService"
        )
    }

    /// Fallback for outputs with no mute switch, which is common for USB and
    /// HDMI devices. The exact previous volume is restored afterwards.
    private func muteUsingVolume(on deviceID: AudioObjectID) {
        guard let volume = self.outputController.volume(on: deviceID) else {
            DebugLogger.shared.warning(
                "SystemAudioMuteService: Device \(deviceID) exposes neither mute nor volume; leaving audio unchanged",
                source: "SystemAudioMuteService"
            )
            return
        }

        guard volume > Self.silentVolumeThreshold else {
            DebugLogger.shared.debug(
                "SystemAudioMuteService: Output already silent, not taking ownership",
                source: "SystemAudioMuteService"
            )
            return
        }

        guard self.outputController.setVolume(0, on: deviceID) else {
            DebugLogger.shared.error(
                "SystemAudioMuteService: Failed to zero volume on device \(deviceID)",
                source: "SystemAudioMuteService"
            )
            return
        }

        self.activeMute = .zeroedVolume(deviceID: deviceID, previousVolume: volume)
        DebugLogger.shared.info(
            "SystemAudioMuteService: Zeroed volume on device \(deviceID) for recording (was \(volume))",
            source: "SystemAudioMuteService"
        )
    }

    private func logRestore(succeeded: Bool, description: String) {
        if succeeded {
            DebugLogger.shared.info(
                "SystemAudioMuteService: Restored audio after recording (\(description))",
                source: "SystemAudioMuteService"
            )
        } else {
            DebugLogger.shared.error(
                "SystemAudioMuteService: Failed to restore audio after recording (\(description))",
                source: "SystemAudioMuteService"
            )
        }
    }
}

/// Reads and writes the real CoreAudio output device properties.
@MainActor
final class CoreAudioOutputController: SystemAudioOutputControlling {
    func defaultOutputDeviceID() -> AudioObjectID? {
        var address = Self.defaultOutputDeviceAddress
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    func supportsMute(on deviceID: AudioObjectID) -> Bool {
        var address = Self.muteAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var isSettable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        return status == noErr && isSettable.boolValue
    }

    func isMuted(on deviceID: AudioObjectID) -> Bool? {
        var address = Self.muteAddress
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
        guard status == noErr else { return nil }
        return muted != 0
    }

    @discardableResult
    func setMuted(_ muted: Bool, on deviceID: AudioObjectID) -> Bool {
        var address = Self.muteAddress
        var value = UInt32(muted ? 1 : 0)
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        guard status == noErr else {
            DebugLogger.shared.error(
                "CoreAudioOutputController: Failed to set mute: OSStatus \(status)",
                source: "SystemAudioMuteService"
            )
            return false
        }
        return true
    }

    func volume(on deviceID: AudioObjectID) -> Float? {
        var address = Self.volumeAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return volume
    }

    @discardableResult
    func setVolume(_ volume: Float, on deviceID: AudioObjectID) -> Bool {
        var address = Self.volumeAddress
        var value = Float32(max(0, min(1, volume)))
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        guard status == noErr else {
            DebugLogger.shared.error(
                "CoreAudioOutputController: Failed to set volume: OSStatus \(status)",
                source: "SystemAudioMuteService"
            )
            return false
        }
        return true
    }

    // MARK: - Property Addresses

    private static let defaultOutputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
}
