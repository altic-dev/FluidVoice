import AVFoundation
import CoreAudio
import Foundation

@MainActor
final class TranscriptionSoundPlayer {
    static let shared = TranscriptionSoundPlayer()

    private var players: [String: AVAudioPlayer] = [:]
    private var savedSystemVolume: Float?

    private init() {}

    func playStartSound() {
        let selected = SettingsStore.shared.transcriptionStartSound
        self.play(soundName: selected.soundFileName)
    }

    /// Preview a specific sound at the current volume setting (used in Settings UI).
    func playPreview(sound: SettingsStore.TranscriptionStartSound) {
        self.play(soundName: sound.soundFileName)
    }

    /// Preview current sound at a specific volume (used when slider is released).
    func playPreviewAtVolume(_ volume: Float) {
        let selected = SettingsStore.shared.transcriptionStartSound
        self.play(soundName: selected.soundFileName, overrideVolume: volume)
    }

    private func play(soundName: String, overrideVolume: Float? = nil) {
        guard let url = Bundle.main.url(forResource: soundName, withExtension: "m4a") else {
            DebugLogger.shared.error("Missing sound resource: \(soundName).m4a", source: "TranscriptionSoundPlayer")
            return
        }

        let settings = SettingsStore.shared
        let desiredVolume = overrideVolume ?? settings.transcriptionSoundVolume
        let independent = settings.transcriptionSoundIndependentVolume

        // If independent volume is on, temporarily adjust system volume
        if independent {
            let systemVol = Self.getSystemVolume()
            // Respect mute: if system volume is 0, don't play
            if systemVol <= 0.001 {
                return
            }
            self.savedSystemVolume = systemVol
            Self.setSystemVolume(desiredVolume)
        }

        do {
            let player: AVAudioPlayer
            if let existing = self.players[soundName] {
                player = existing
            } else {
                player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                self.players[soundName] = player
            }

            player.currentTime = 0
            player.volume = independent ? 1.0 : desiredVolume
            player.play()

            // Restore system volume after the sound finishes
            if independent, let savedVol = self.savedSystemVolume {
                let duration = player.duration
                let restoreVolume = savedVol
                DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
                    Self.setSystemVolume(restoreVolume)
                    self.savedSystemVolume = nil
                }
            }
        } catch {
            // Restore system volume on error
            if independent, let savedVol = self.savedSystemVolume {
                Self.setSystemVolume(savedVol)
                self.savedSystemVolume = nil
            }
            DebugLogger.shared.error(
                "Failed to play sound \(soundName).m4a: \(error.localizedDescription)",
                source: "TranscriptionSoundPlayer"
            )
        }
    }

    // MARK: - System Volume Control via CoreAudio

    private static func getDefaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func getSystemVolume() -> Float {
        guard let deviceID = getDefaultOutputDeviceID() else { return 1.0 }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float32 = 1.0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return 1.0 }
        return volume
    }

    private static func setSystemVolume(_ volume: Float) {
        guard let deviceID = getDefaultOutputDeviceID() else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var vol = max(0.0, min(1.0, volume))
        let size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &vol)
    }
}
