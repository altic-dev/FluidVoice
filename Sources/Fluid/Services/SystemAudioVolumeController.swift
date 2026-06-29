import CoreAudio
import Foundation

/// Thin CoreAudio wrapper for reading and adjusting the **default output device's**
/// output volume, used to "duck" (temporarily lower) system audio while dictation
/// is active, as a gentler alternative to fully pausing media.
///
/// Note that CoreAudio's output volume is system-wide: ducking lowers *all* output
/// from the default device, not just a single app's media.
///
/// Volume is captured and restored as an `OutputVolumeSnapshot`, which preserves the
/// **individual per-channel levels** (or the master element). Some output devices
/// expose no settable master volume — only per-channel scalars — and a user may have
/// a non-centered left/right balance that must survive a duck/restore cycle
/// unchanged, so the snapshot records each element rather than a single scalar.
struct SystemAudioVolumeController {
    /// Captures the default output device's current volume so it can later be
    /// restored exactly, preserving per-channel balance.
    ///
    /// - Returns: A snapshot, or `nil` if no volume property is available (e.g. an
    ///   aggregate device).
    func captureOutputVolume() -> OutputVolumeSnapshot? {
        guard let device = self.defaultOutputDevice() else { return nil }

        // Prefer the single master element when the device exposes it.
        if let master = self.scalarVolume(device: device, element: kAudioObjectPropertyElementMain) {
            return OutputVolumeSnapshot(
                deviceID: device,
                channels: [.init(element: kAudioObjectPropertyElementMain, volume: master)]
            )
        }

        // Otherwise capture each stereo channel individually so balance is retained.
        let channels = self.stereoChannels(device: device).compactMap { element -> OutputVolumeSnapshot.Channel? in
            guard let volume = self.scalarVolume(device: device, element: element) else { return nil }
            return .init(element: element, volume: volume)
        }
        guard !channels.isEmpty else { return nil }
        return OutputVolumeSnapshot(deviceID: device, channels: channels)
    }

    /// Writes every channel captured in `snapshot` back to its recorded level.
    ///
    /// - Returns: `true` if at least one channel was successfully written.
    @discardableResult
    func apply(_ snapshot: OutputVolumeSnapshot) -> Bool {
        var didSet = false
        for channel in snapshot.channels {
            if self.setScalarVolume(channel.volume, device: snapshot.deviceID, element: channel.element) {
                didSet = true
            }
        }
        return didSet
    }

    /// Reads the current average level of the same device and elements captured in
    /// `snapshot`, for detecting whether the user changed the volume since we set it.
    func currentAverageLevel(matching snapshot: OutputVolumeSnapshot) -> Float? {
        let values = snapshot.channels.compactMap {
            self.scalarVolume(device: snapshot.deviceID, element: $0.element)
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
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

    private func scalarVolume(device: AudioDeviceID, element: AudioObjectPropertyElement) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
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

    private func setScalarVolume(
        _ volume: Float,
        device: AudioDeviceID,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
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

/// An immutable capture of an output device's volume — either its master element or
/// its individual stereo channels — so a duck can be reverted without losing the
/// device's original per-channel (left/right) balance.
struct OutputVolumeSnapshot {
    fileprivate struct Channel {
        let element: AudioObjectPropertyElement
        let volume: Float
    }

    fileprivate let deviceID: AudioDeviceID
    fileprivate let channels: [Channel]

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
                Channel(element: $0.element, volume: max(0.0, min(1.0, $0.volume * factor)))
            }
        )
    }
}
