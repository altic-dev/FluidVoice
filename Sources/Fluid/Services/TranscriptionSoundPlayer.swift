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
        guard SettingsStore.shared.enableTranscriptionSounds else { return }
        let selected = SettingsStore.shared.transcriptionStartSound
        guard let soundName = selected.startSoundFileName else { return }
        self.play(soundName: soundName)
    }

    func playStopSound() {
        guard SettingsStore.shared.enableTranscriptionSounds else { return }
        let selected = SettingsStore.shared.transcriptionStartSound
        guard let soundName = selected.stopSoundFileName else { return }
        self.play(soundName: soundName)
    }

    /// Preview a specific sound at the current volume setting (used in Settings UI).
    func playPreview(sound: SettingsStore.TranscriptionStartSound) {
        guard let soundName = sound.startSoundFileName else { return }
        self.play(soundName: soundName)
    }

    /// Preview current sound at a specific volume (used when slider is released).
    func playPreviewAtVolume(_ volume: Float) {
        let selected = SettingsStore.shared.transcriptionStartSound
        guard let soundName = selected.startSoundFileName else { return }
        self.play(soundName: soundName, overrideVolume: volume)
    }

    private func play(soundName: String, overrideVolume: Float? = nil) {
        guard let url = Bundle.main.url(forResource: soundName, withExtension: "m4a") else {
            DebugLogger.shared.error("Missing sound resource: \(soundName).m4a", source: "TranscriptionSoundPlayer")
            return
        }

        let settings = SettingsStore.shared
        let desiredVolume = overrideVolume ?? settings.transcriptionSoundVolume

        if settings.transcriptionSoundIndependentVolume {
            let currentSystemVol = Self.getSystemVolume()
            guard currentSystemVol > 0.001 else { return }
            // Save current system volume and temporarily set it to desired level
            self.savedSystemVolume = currentSystemVol
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
            if settings.transcriptionSoundIndependentVolume {
                player.volume = 1.0
            } else {
                player.volume = desiredVolume
            }
            player.play()

            // Restore system volume after the sound finishes
            if settings.transcriptionSoundIndependentVolume, let saved = self.savedSystemVolume {
                let duration = player.duration
                DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak self] in
                    Self.setSystemVolume(saved)
                    self?.savedSystemVolume = nil
                }
            }
        } catch {
            // Restore system volume on error
            if let saved = self.savedSystemVolume {
                Self.setSystemVolume(saved)
                self.savedSystemVolume = nil
            }
            DebugLogger.shared.error(
                "Failed to play sound \(soundName).m4a: \(error.localizedDescription)",
                source: "TranscriptionSoundPlayer"
            )
        }
    }

    // MARK: - System Volume via CoreAudio

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
            &address,
            0,
            nil,
            &size,
            &deviceID
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
        var vol = Float32(max(0, min(1, volume)))
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &vol)
        if status != noErr {
            DebugLogger.shared.error("Failed to set system volume: OSStatus \(status)", source: "TranscriptionSoundPlayer")
        }
    }
}
