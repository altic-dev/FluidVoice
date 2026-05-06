import CoreAudio
import Foundation

/// Reads and writes the default output device's volume via CoreAudio's
/// `AudioObjectGetPropertyData` / `AudioObjectSetPropertyData`.
///
/// macOS doesn't expose per-app output volume in any stable public API, so
/// adjusting the system output level is the closest equivalent. Side effect:
/// notification dings and other system sounds duck along with media for the
/// duration. That's intentional — the user is dictating, they don't want
/// surprises through the speakers.
///
/// CoreAudio's `AudioObject*` APIs are thread-safe, so this enum is callable
/// from any actor or detached task — useful for background fade ramps.
enum SystemVolumeController {
    /// Returns the current default output device's master scalar volume in
    /// `0.0...1.0`, or `nil` if the device or master volume property isn't
    /// available (some devices only expose per-channel volume).
    static func currentVolume() -> Float? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(deviceID, &address) {
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
            if status == noErr {
                return volume
            }
        }

        // Fall back to averaging channels 1 and 2 if master isn't exposed.
        let left = readChannelVolume(deviceID: deviceID, channel: 1)
        let right = readChannelVolume(deviceID: deviceID, channel: 2)
        switch (left, right) {
        case let (l?, r?): return (l + r) / 2
        case let (l?, nil): return l
        case let (nil, r?): return r
        default: return nil
        }
    }

    /// Sets the default output device's volume to `value` (clamped to `0.0...1.0`).
    /// Writes master if available, falls back to writing channels 1 and 2.
    @discardableResult
    static func setVolume(_ value: Float) -> Bool {
        guard let deviceID = defaultOutputDeviceID() else { return false }
        let clamped = max(0, min(1, value))

        var masterAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(deviceID, &masterAddress) {
            var newValue = clamped
            let size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectSetPropertyData(deviceID, &masterAddress, 0, nil, size, &newValue)
            if status == noErr { return true }
        }

        let leftOK = writeChannelVolume(deviceID: deviceID, channel: 1, value: clamped)
        let rightOK = writeChannelVolume(deviceID: deviceID, channel: 2, value: clamped)
        return leftOK || rightOK
    }

    // MARK: - Private

    private static func defaultOutputDeviceID() -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return (status == noErr && deviceID != kAudioObjectUnknown) ? deviceID : nil
    }

    private static func readChannelVolume(deviceID: AudioObjectID, channel: UInt32) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    private static func writeChannelVolume(deviceID: AudioObjectID, channel: UInt32, value: Float) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var newValue = value
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &newValue)
        return status == noErr
    }
}
