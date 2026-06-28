import CoreAudio
import Foundation

/// Thin CoreAudio wrapper for reading and adjusting the **default output device's**
/// master output volume.
///
/// This is used to "duck" (temporarily lower) system audio while dictation is
/// active, as a gentler alternative to fully pausing media. Note that CoreAudio's
/// output volume is system-wide: ducking lowers *all* output from the default
/// device, not just a single app's media.
///
/// Volume is expressed as a scalar in the `0.0...1.0` range. Some output devices
/// expose a settable master element (`kAudioObjectPropertyElementMain`), while
/// others only allow per-channel control; both paths are handled here.
struct SystemAudioVolumeController {
    /// Returns the current scalar volume (`0.0...1.0`) of the default output
    /// device, or `nil` if it can't be determined (e.g. an aggregate device or a
    /// device that doesn't expose a volume property).
    func currentOutputVolume() -> Float? {
        guard let device = self.defaultOutputDevice() else { return nil }

        if let master = self.scalarVolume(device: device, element: kAudioObjectPropertyElementMain) {
            return master
        }

        // Fall back to averaging the individual stereo channels.
        let values = self.stereoChannels(device: device)
            .compactMap { self.scalarVolume(device: device, element: $0) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    /// Sets the default output device volume to `volume` (clamped to `0.0...1.0`).
    ///
    /// - Returns: `true` if at least one volume element was successfully written.
    @discardableResult
    func setOutputVolume(_ volume: Float) -> Bool {
        guard let device = self.defaultOutputDevice() else { return false }
        let clamped = max(0.0, min(1.0, volume))

        if self.setScalarVolume(clamped, device: device, element: kAudioObjectPropertyElementMain) {
            return true
        }

        // Fall back to writing each stereo channel individually.
        var didSet = false
        for channel in self.stereoChannels(device: device) {
            if self.setScalarVolume(clamped, device: device, element: channel) {
                didSet = true
            }
        }
        return didSet
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
