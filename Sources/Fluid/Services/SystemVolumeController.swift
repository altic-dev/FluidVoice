import CoreAudio
import Foundation

/// A captured snapshot of the system output volume that survives the duck
/// cycle and can be restored exactly. Keeps left/right channel values
/// independent for devices that don't expose a master volume property —
/// otherwise a non-centred balance setup would have one duck cycle
/// permanently flatten its channels to the average.
enum SystemVolumeSnapshot: Equatable {
    case master(Float)
    case channels(left: Float?, right: Float?)

    /// Scalar used as the "from" value of a fade ramp — fades interpolate a
    /// single value, then we restore the exact snapshot at the end so any
    /// per-channel detail comes back precisely.
    var averageScalar: Float {
        switch self {
        case .master(let v):
            return v
        case .channels(let l, let r):
            switch (l, r) {
            case let (l?, r?): return (l + r) / 2
            case let (l?, nil): return l
            case let (nil, r?): return r
            case (nil, nil):   return 0
            }
        }
    }
}

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
    /// available. Used as the "from" value of the duck-down fade ramp.
    static func currentVolume() -> Float? {
        currentSnapshot()?.averageScalar
    }

    /// Captures the current default output device's full volume state for
    /// later exact restoration. Prefers the master scalar, falls back to a
    /// per-channel snapshot for devices that don't expose master volume.
    static func currentSnapshot() -> SystemVolumeSnapshot? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }

        var masterAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(deviceID, &masterAddress) {
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(deviceID, &masterAddress, 0, nil, &size, &volume)
            if status == noErr {
                return .master(volume)
            }
        }

        let left = readChannelVolume(deviceID: deviceID, channel: 1)
        let right = readChannelVolume(deviceID: deviceID, channel: 2)
        if left != nil || right != nil {
            return .channels(left: left, right: right)
        }
        return nil
    }

    /// Sets the default output device's volume to `value` (clamped to `0.0...1.0`).
    /// Writes master if available, falls back to writing channels 1 and 2.
    /// Used by the duck-down fade ramp where balance preservation isn't
    /// meaningful (the duck target is uniform); restore-up uses
    /// `restore(_:)` to re-apply the original per-channel values exactly.
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

    /// Re-applies a snapshot exactly. For master snapshots this writes the
    /// master scalar; for per-channel snapshots this writes the original
    /// left and right values independently, preserving stereo balance that
    /// `setVolume(_:)` would otherwise have flattened.
    @discardableResult
    static func restore(_ snapshot: SystemVolumeSnapshot) -> Bool {
        guard let deviceID = defaultOutputDeviceID() else { return false }

        switch snapshot {
        case .master(let value):
            var masterAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(deviceID, &masterAddress) else { return false }
            var newValue = max(0, min(1, value))
            let size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectSetPropertyData(deviceID, &masterAddress, 0, nil, size, &newValue)
            return status == noErr

        case .channels(let left, let right):
            var anyOK = false
            if let left {
                anyOK = writeChannelVolume(deviceID: deviceID, channel: 1, value: max(0, min(1, left))) || anyOK
            }
            if let right {
                anyOK = writeChannelVolume(deviceID: deviceID, channel: 2, value: max(0, min(1, right))) || anyOK
            }
            return anyOK
        }
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
