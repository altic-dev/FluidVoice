import AVFoundation
import CoreAudio
import Foundation

final class TranscriptionSoundPlayer {
    static let shared = TranscriptionSoundPlayer()

    private let playbackQueue = DispatchQueue(label: "app.fluidvoice.transcription-sounds", qos: .userInteractive)
    private var players: [String: AVAudioPlayer] = [:]
    private var savedSystemVolume: Float?

    /// Ducking-precedence decision captured when the start cue plays, reused by the
    /// stop cue so both cues of one session behave consistently even if the user
    /// toggles the ducking setting mid-dictation.
    private var sessionDuckingPrecedence: Bool?

    private init() {}

    func playStartSound() {
        self.sessionDuckingPrecedence = nil
        let settings = SettingsStore.shared
        guard settings.enableTranscriptionSounds else { return }
        let selected = settings.transcriptionStartSound
        guard let soundName = selected.startSoundFileName else { return }
        let duckingPrecedence = self.duckingOwnsSystemVolume(settings)
        self.sessionDuckingPrecedence = duckingPrecedence
        self.play(
            soundName: soundName,
            desiredVolume: settings.transcriptionSoundVolume,
            independentVolume: settings.transcriptionSoundIndependentVolume && !duckingPrecedence
        )
    }

    func playStopSound() {
        let sessionDuckingPrecedence = self.sessionDuckingPrecedence
        self.sessionDuckingPrecedence = nil
        let settings = SettingsStore.shared
        guard settings.enableTranscriptionSounds else { return }
        let selected = settings.transcriptionStartSound
        guard let soundName = selected.stopSoundFileName else { return }
        // Reuse the decision captured at session start: the ducking revert is keyed to
        // what MediaPlaybackService actually did when the session began, so a settings
        // toggle mid-dictation must not re-enable the cue's system-volume override here.
        let duckingPrecedence = sessionDuckingPrecedence ?? self.duckingOwnsSystemVolume(settings)
        self.play(
            soundName: soundName,
            desiredVolume: settings.transcriptionSoundVolume,
            independentVolume: settings.transcriptionSoundIndependentVolume && !duckingPrecedence
        )
    }

    /// Preview a specific sound at the current volume setting (used in Settings UI).
    func playPreview(sound: SettingsStore.TranscriptionStartSound) {
        guard let soundName = sound.startSoundFileName else { return }
        let settings = SettingsStore.shared
        self.play(
            soundName: soundName,
            desiredVolume: settings.transcriptionSoundVolume,
            independentVolume: settings.transcriptionSoundIndependentVolume
        )
    }

    /// Preview current sound at a specific volume (used when slider is released).
    func playPreviewAtVolume(_ volume: Float) {
        let selected = SettingsStore.shared.transcriptionStartSound
        guard let soundName = selected.startSoundFileName else { return }
        self.play(
            soundName: soundName,
            desiredVolume: volume,
            independentVolume: SettingsStore.shared.transcriptionSoundIndependentVolume
        )
    }

    /// When "lower volume instead of pausing" (ducking) is enabled, MediaPlaybackService
    /// owns the system output volume for the duration of a dictation session. The cue's
    /// independent-volume mode also temporarily sets and *asynchronously* restores the
    /// system volume, and the two would race: a late cue restore can undo the duck at
    /// session start, or overwrite the final restore and leave the Mac stuck at the ducked
    /// level. So for the session start/stop cues, ducking takes precedence — the cue plays
    /// at its own player volume and leaves the system volume alone. The decision is
    /// captured at start-cue time (see `sessionDuckingPrecedence`) so a mid-dictation
    /// settings toggle can't hand the stop cue back the system volume while a duck is
    /// still active. Settings previews never run during a session, so they always honor
    /// the independent-volume setting.
    private func duckingOwnsSystemVolume(_ settings: SettingsStore) -> Bool {
        settings.pauseMediaDuringTranscription && settings.duckMediaInsteadOfPausing
    }

    private func play(
        soundName: String,
        desiredVolume: Float,
        independentVolume: Bool
    ) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        DebugLogger.shared.benchmark(
            "APP_BENCH",
            message: "sound_play_request sound=\(soundName)",
            source: "AppBenchmark"
        )

        guard let url = Bundle.main.url(forResource: soundName, withExtension: "m4a") else {
            DebugLogger.shared.error("Missing sound resource: \(soundName).m4a", source: "TranscriptionSoundPlayer")
            return
        }

        self.playbackQueue.async { [weak self] in
            self?.playOnPlaybackQueue(
                soundName: soundName,
                url: url,
                desiredVolume: desiredVolume,
                independentVolume: independentVolume,
                startedAt: startedAt
            )
        }
    }

    private func playOnPlaybackQueue(
        soundName: String,
        url: URL,
        desiredVolume: Float,
        independentVolume: Bool,
        startedAt: TimeInterval
    ) {
        if independentVolume {
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
            if independentVolume {
                player.volume = 1.0
            } else {
                player.volume = desiredVolume
            }
            player.play()
            DebugLogger.shared.benchmark(
                "APP_BENCH",
                message: "sound_play_dispatched sound=\(soundName) elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded()))",
                source: "AppBenchmark"
            )

            // Restore system volume after the sound finishes
            if independentVolume, let saved = self.savedSystemVolume {
                let duration = player.duration
                self.playbackQueue.asyncAfter(deadline: .now() + duration + 0.05) { [weak self] in
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
