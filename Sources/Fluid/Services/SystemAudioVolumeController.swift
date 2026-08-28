import AudioToolbox
import CoreAudio
import Foundation

protocol SystemAudioVolumeControlling {
    func captureOutputVolume() -> OutputVolumeSnapshot?
    func apply(_ snapshot: OutputVolumeSnapshot) -> SystemAudioVolumeController.ApplyOutcome
    func applyVirtualMainVolume(_ snapshot: OutputVolumeSnapshot) -> Bool
    func reread(_ snapshot: OutputVolumeSnapshot) -> OutputVolumeSnapshot?
}

/// Thin CoreAudio wrapper for reading and adjusting the **default output device's**
/// output volume, used to "duck" (temporarily lower) system audio while dictation
/// is active, as a gentler alternative to fully pausing media.
///
/// Note that CoreAudio's output volume is system-wide: ducking lowers *all* output
/// from the default device, not just a single app's media.
///
/// Volume is captured and restored as an `OutputVolumeSnapshot`, which preserves the
/// **individual per-channel levels** (or the main element). Some output devices
/// expose no settable main volume — only per-channel scalars — and a user may have
/// a non-centered left/right balance that must survive a duck/restore cycle
/// unchanged, so the snapshot records each element rather than a single scalar.
/// When neither the main volume nor the per-channel scalars are settable, it falls back
/// to the HAL's virtual main volume (the control the macOS volume HUD drives).
struct SystemAudioVolumeController: SystemAudioVolumeControlling {
    /// Captures the default output device's current volume so it can later be
    /// restored exactly, preserving per-channel balance.
    ///
    /// - Returns: A snapshot, or `nil` if no volume property is available (e.g. an
    ///   aggregate device).
    func captureOutputVolume() -> OutputVolumeSnapshot? {
        guard let device = self.defaultOutputDevice() else { return nil }

        // Prefer the single main element, but only when it is *settable* — otherwise we
        // could capture a read-only main volume and then fail to restore it on a device
        // whose per-channel volumes are the ones that are actually settable.
        if self.isVolumeSettable(device: device, selector: kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain),
           let mainLevel = self.volume(device: device, selector: kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain)
        {
            return OutputVolumeSnapshot(
                deviceID: device,
                channels: [.init(selector: kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain, volume: mainLevel)]
            )
        }

        // Otherwise capture each settable stereo channel individually so balance is
        // retained — but only when the *whole* preferred pair is capturable. A partial
        // pair would duck one channel and leave the other at full volume, with the
        // all-captured-channels-written check reporting the duck as fully applied.
        let stereo = self.stereoChannels(device: device)
        let channels = stereo.compactMap { element -> OutputVolumeSnapshot.Channel? in
            guard self.isVolumeSettable(device: device, selector: kAudioDevicePropertyVolumeScalar, element: element),
                  let volume = self.volume(device: device, selector: kAudioDevicePropertyVolumeScalar, element: element)
            else { return nil }
            return .init(selector: kAudioDevicePropertyVolumeScalar, element: element, volume: volume)
        }
        if channels.count == stereo.count {
            return OutputVolumeSnapshot(deviceID: device, channels: channels)
        }

        // Last resort: the HAL's *virtual* main volume — the control the macOS volume
        // HUD drives — which CoreAudio synthesizes for devices whose raw volume scalars
        // are not settable (some Bluetooth routes, devices with volume on non-stereo
        // elements). It applies volume while preserving the device's balance itself,
        // so a single-element snapshot is sufficient.
        if self.isVolumeSettable(device: device, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, element: kAudioObjectPropertyElementMain),
           let virtualMain = self.volume(device: device, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, element: kAudioObjectPropertyElementMain)
        {
            return OutputVolumeSnapshot(
                deviceID: device,
                channels: [.init(selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, element: kAudioObjectPropertyElementMain, volume: virtualMain)]
            )
        }

        return nil
    }

    /// Outcome of writing a snapshot's channels back to the device. Partial writes
    /// are surfaced explicitly: treating "one of two channels written" as success
    /// would let a failed restore leave one channel stuck at the ducked level.
    enum ApplyOutcome {
        /// Every captured channel was written.
        case applied
        /// Some channel writes failed — the device is in a mixed state.
        case partial
        /// No channel could be written.
        case failed
    }

    /// Writes every channel captured in `snapshot` back to its recorded level.
    @discardableResult
    func apply(_ snapshot: OutputVolumeSnapshot) -> ApplyOutcome {
        let written = snapshot.channels.filter {
            self.setVolume($0.volume, device: snapshot.deviceID, selector: $0.selector, element: $0.element)
        }.count
        switch written {
        case snapshot.channels.count: return .applied
        case 0: return .failed
        default: return .partial
        }
    }

    /// Sets the HAL virtual main volume on the snapshot's device to the snapshot's
    /// average level — a restore fallback for when raw channel writes fail.
    /// Approximate (the HAL preserves the device's *current* balance, not the
    /// captured one), but far better than leaving one channel ducked.
    func applyVirtualMainVolume(_ snapshot: OutputVolumeSnapshot) -> Bool {
        self.setVolume(
            snapshot.averageLevel,
            device: snapshot.deviceID,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            element: kAudioObjectPropertyElementMain
        )
    }

    /// Re-reads the current levels of the same device and elements captured in
    /// `snapshot`, returning an updated snapshot — used both to learn what the hardware
    /// actually snapped to (volume can be quantized to coarse steps) and to detect
    /// whether the user changed the volume since we set it. Operates on the snapshot's
    /// own device, so it is unaffected if the default output device changes mid-session.
    ///
    /// - Returns: An updated snapshot, or `nil` if a captured element is no longer readable.
    func reread(_ snapshot: OutputVolumeSnapshot) -> OutputVolumeSnapshot? {
        let channels = snapshot.channels.compactMap { channel -> OutputVolumeSnapshot.Channel? in
            guard let volume = self.volume(device: snapshot.deviceID, selector: channel.selector, element: channel.element) else { return nil }
            return .init(selector: channel.selector, element: channel.element, volume: volume)
        }
        guard channels.count == snapshot.channels.count else { return nil }
        return OutputVolumeSnapshot(deviceID: snapshot.deviceID, channels: channels)
    }

    // MARK: - Private CoreAudio helpers

    private func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// The output channel numbers used for stereo, defaulting to `[1, 2]` when the
    /// device doesn't advertise a preferred pair.
    private func stereoChannels(device: AudioDeviceID) -> [UInt32] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return [1, 2] }

        var channels: [UInt32] = [0, 0]
        var size = UInt32(MemoryLayout<UInt32>.size * channels.count)
        let status = channels.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return OSStatus(-1) }
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, base)
        }
        guard status == noErr, channels.allSatisfy({ $0 != 0 }) else { return [1, 2] }
        return channels
    }

    private func volume(device: AudioDeviceID, selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }

        var volume = Float(0)
        var size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return volume
    }

    /// Whether the volume property for `selector`/`element` exists and can be written.
    private func isVolumeSettable(device: AudioDeviceID, selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(device, &address) else { return false }

        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private func setVolume(
        _ volume: Float,
        device: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(device, &address) else { return false }

        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else {
            return false
        }

        var newVolume = max(0.0, min(1.0, volume))
        let size = UInt32(MemoryLayout<Float>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &newVolume) == noErr
    }
}

/// An immutable capture of an output device's volume — either its main element or
/// its individual stereo channels — so a duck can be reverted without losing the
/// device's original per-channel (left/right) balance.
struct OutputVolumeSnapshot {
    struct Channel {
        let selector: AudioObjectPropertySelector
        let element: AudioObjectPropertyElement
        let volume: Float
    }

    let deviceID: AudioDeviceID
    let channels: [Channel]

    /// Average level across the captured channels, used for logging and for
    /// detecting whether the user changed the volume mid-dictation.
    var averageLevel: Float {
        guard !self.channels.isEmpty else { return 0 }
        return self.channels.map(\.volume).reduce(0, +) / Float(self.channels.count)
    }

    /// A copy with every channel scaled by `factor` (clamped to `0.0...1.0`).
    /// Scaling each channel by the same factor lowers the volume while preserving
    /// the device's left/right balance.
    func scaled(by factor: Float) -> OutputVolumeSnapshot {
        OutputVolumeSnapshot(
            deviceID: self.deviceID,
            channels: self.channels.map {
                Channel(selector: $0.selector, element: $0.element, volume: max(0.0, min(1.0, $0.volume * factor)))
            }
        )
    }
}
