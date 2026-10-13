import CoreAudio
import Foundation

@MainActor
final class RecordingVolumeDucking {
    static let shared = RecordingVolumeDucking()

    private struct Channel {
        let element: AudioObjectPropertyElement
        let original: Float
        let ducked: Float
    }

    private struct Ownership {
        let sessionID: Int
        let device: AudioObjectID
        let channels: [Channel]
    }

    private var ownership: Ownership?

    func start(sessionID: Int) {
        self.restore()
        let settings = SettingsStore.shared
        guard settings.duckAudioDuringRecording, !settings.pauseMediaDuringTranscription,
              let device = Self.outputDevice() else { return }
        let channels = Self.channels(device: device, target: Float(settings.recordingDuckVolume))
        guard !channels.isEmpty else { return }
        self.ownership = Ownership(sessionID: sessionID, device: device, channels: channels)
        for channel in channels {
            guard Self.setVolume(channel.ducked, device: device, element: channel.element) else {
                self.restore()
                return
            }
        }
    }

    func stop(sessionID: Int) {
        guard self.ownership?.sessionID == sessionID else { return }
        self.restore()
    }

    func restore() {
        guard let ownership = self.ownership else { return }
        self.ownership = nil
        // Restore only the captured device and preserve any manual volume change.
        for channel in ownership.channels {
            guard let current = Self.volume(device: ownership.device, element: channel.element),
                  abs(current - channel.ducked) < 0.005 else { continue }
            if !Self.setVolume(channel.original, device: ownership.device, element: channel.element) {
                DebugLogger.shared.error("Unable to restore recording output volume", source: "RecordingVolumeDucking")
            }
        }
    }

    private static func channels(device: AudioObjectID, target: Float) -> [Channel] {
        let elements: [AudioObjectPropertyElement] = self.volume(device: device, element: kAudioObjectPropertyElementMain) == nil
            ? [1, 2] : [kAudioObjectPropertyElementMain]
        let channels = elements.compactMap { element -> Channel? in
            guard let original = self.volume(device: device, element: element) else { return nil }
            return Channel(element: element, original: original, ducked: min(original, target))
        }
        return channels.count == elements.count ? channels : []
    }

    private static func address(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: element)
    }

    private static func volume(device: AudioObjectID, element: AudioObjectPropertyElement) -> Float? {
        var address = self.address(element)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return nil }
        var volume: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr,
              volume.isFinite, (0...1).contains(volume) else { return nil }
        return volume
    }

    private static func setVolume(_ volume: Float, device: AudioObjectID, element: AudioObjectPropertyElement) -> Bool {
        var address = self.address(element)
        var scalar = volume
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &scalar) == noErr
    }

    private static func outputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }
}
